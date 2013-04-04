-module(exoport_dispatcher).
-behaviour(gen_server).

-export([check_queue/0, check_queue/2]).
-export([attempt_dispatch/0,
	 attempt_dispatch/1,
	 attempt_dispatch/3,
	 attempt_dispatch/4]).
-export([start_link/0, start_link/2]).
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

-record(st, {tab, mod,
	     queues = dict:new(),
	     pids = dict:new(),
	     pending = dict:new()}).

-include_lib("lager/include/log.hrl").

-spec check_queue(kvdb:tab_name(),
		  kvdb:queue_name()) -> pid() | {pending, pid()}.

default_tab() ->
    exoport.

default_mod() ->
    exoport_rpc.

check_queue() ->
    check_queue(default_tab(), default_mod()).

check_queue(Tab, Q) ->
    ?debug("check_queue(~p, ~p)~n", [Tab, Q]),
    call(Tab, {check_queue, Q}).

attempt_dispatch() ->
    attempt_dispatch(kvdb_conf:instance()).

attempt_dispatch(Db) ->
    attempt_dispatch(Db, default_tab(), default_mod()).

attempt_dispatch(Db, Tab, Q) ->
    attempt_dispatch(Db, Tab, Q, false).

attempt_dispatch(Db, Tab, Q, DoReply) when is_boolean(DoReply) ->
    call(Tab, {attempt_dispatch, Q, Db, DoReply}).

call(Tab0, Req) ->
    Tab = kvdb_lib:table_name(Tab0),
    case gproc:where({n,l, {?MODULE, Tab}}) of
	undefined ->
	    error(noproc);
	Pid when is_pid(Pid) ->
	    gen_server:call(Pid, Req)
    end.

start_link() ->
    start_link(default_tab(), default_mod()).

start_link(Tab0, M) ->
    Tab = kvdb_lib:table_name(Tab0),
    gen_server:start_link(?MODULE, {Tab, M}, []).

init({Tab0, M} = Arg) ->
    Tab = kvdb_lib:table_name(Tab0),
    gproc:reg({n, l, {?MODULE, Tab}}),
    try
	ok = kvdb_conf:add_table(Tab, [{type, fifo},
				       {encoding, {raw,sext,sext}}]),
	kvdb_schema_events:notify_all_queues(kvdb:db(kvdb_conf), Tab),
	?debug("checking queues in ~p~n", [Tab]),
	St = check_queues(kvdb:first_queue(kvdb_conf, Tab),
			  #st{tab = Tab, mod = M}),
	{ok, St}
    catch
	error:E ->
	    ?error("*** ERROR: ~p:init(~p)~n"
		   "  E = ~p~n"
		   "  Trace = ~p~n",
		   [?MODULE, Arg, E, erlang:get_stacktrace()]),
	    error(E)
    end.

check_queues({ok, Q}, #st{tab = Tab} = St) ->
    ?debug("queue ~p in ~p not empty~n", [Q, Tab]),
    {_, St1} = spawn_dispatcher(Q, [], St),
    check_queues(kvdb:next_queue(kvdb_conf, Tab, Q), St1);
check_queues(done, St) ->
    St.


handle_info({gproc_ps_event,
	     {kvdb, kvdb_conf, Tab, queue_status}, {Q, not_empty}},
	    #st{tab = Tab} = St) ->
    ?debug("queue ~p in ~p not empty~n", [Q, Tab]),
    {_, St1} = check_queue_(Q, St),
    {noreply, St1};
handle_info({'DOWN', _, _, Pid, _}, #st{pids = Pids, queues = Qs,
					pending = Pending} = St) ->
    St1 = case dict:find(Pid, Pids) of
	      {ok, Q} ->
		  case dict:find(Q, Pending) of
		      {ok, ReplyTo} ->
			  {_, NewSt} =
			      spawn_dispatcher(
				Q, ReplyTo,
				St#st{pids = dict:erase(Pid, Pids),
				      queues = dict:erase(Q, Qs),
				      pending = dict:erase(Q, Pending)}),
			  NewSt;
		      error ->
			  St#st{pids = dict:erase(Pid, Pids),
				queues = dict:erase(Q, Qs)}
		  end;
	      _ ->
		  St
	  end,
    {noreply, St1};
handle_info(_Msg, St) ->
    ?debug("~p got ~p~n", [?MODULE, _Msg]),
    {noreply, St}.

handle_call({check_queue, Q}, _From, St) ->
    {Res, St1} = check_queue_(Q, St),
    {reply, Res, St1};
handle_call({attempt_dispatch, Q, Db, DoReply},
	    From, #st{queues = Qs} = St) ->
    case dict:find(Q, Qs) of
	error ->
	    {DbArg, Reply} = if DoReply -> {Db, [From]};
				true -> {kvdb:db_name(Db), []}
			     end,
	    {Pid, St1} = spawn_dispatcher(Q, DbArg, Reply, St),
	    {reply, {ok, Pid}, St1};
	{ok, CurPid} ->
	    {_, St1} = mark_pending(CurPid, Q, From, St),
	    {reply, pending, St1}
    end;
handle_call(_, _, St) ->
    {noreply, St}.

handle_cast(_, St) -> {noreply, St}.

terminate(_, _) -> ok.
code_change(_, St, _) -> {ok, St}.


check_queue_(Q, #st{queues = Qs} = St) ->
    case dict:find(Q, Qs) of
	error ->
	    spawn_dispatcher(Q, [], St);
	{ok, CurPid} ->
	    mark_pending(CurPid, Q, false, St)
    end.

mark_pending(CurPid, Q, Reply, #st{pending = Pending} = St) ->
    P1 = case Reply of
	     false ->
		 case dict:find(Q, Pending) of
		     {ok, _} -> Pending;
		     error   -> dict:store(Q, [], Pending)
		 end;
	     From ->
		 dict:append(Q, From, Pending)
	 end,
    {{pending, CurPid}, St#st{pending = P1}}.

spawn_dispatcher(Q, Reply, St) ->
    spawn_dispatcher(Q, kvdb_conf, Reply, St).

spawn_dispatcher(Q, Db, Reply, #st{tab = Tab, pids = Pids,
				   queues = Qs} = St) ->
    {Pid, _} = spawn_monitor(
		 fun() ->
			 run_dispatcher(Db, Tab, Q, Reply)
		 end),
    {Pid, St#st{pids = dict:store(Pid, Q, Pids),
		queues = dict:store(Q, Pid, Qs)}}.

run_dispatcher(Db, Tab, Q, Reply) ->
    try
	timer:sleep(500),
	dispatch(Db, Tab, Q, Reply)
    catch
	Type:Exception ->
	    ?error("Dispatch thread exception: ~p:~p~n~p~n",
		   [Type, Exception, erlang:get_stacktrace()])
    end.



dispatch(Db, Tab, Q, Reply) ->
    ?debug("dispatch(~p, ~p)~n", [Tab, Q]),
    try
	case exoport_server:session_active() of
	    true ->
		pop_and_dispatch(Reply, Db, Tab, Q);
	    false ->
		done(Reply)
	end
    catch
	error:Reason ->
	    ?error("ERROR in ~p:dispatch(): ~p~n~p~n",
		   [?MODULE,Reason, erlang:get_stacktrace()])
    end.

pop_and_dispatch(false, Db, Tab, Q) ->
    kvdb:transaction(
      Db,
      fun(Db1) ->
	      until_done(Db1, Tab, Q)
	   end);
pop_and_dispatch(Reply, Db, Tab, Q) ->
    case kvdb:in_transaction(
	   Db,
	   fun(Db1) ->
		   pop_and_dispatch_(Reply, Db1, Tab, Q)
	   end) of
	done ->
	    done;
	next ->
	    kvdb:transaction(
	      kvdb_conf,
	      fun(Db1) ->
		      until_done(Db1, Tab, Q)
	      end)
    end.

until_done(Db, Tab, Q) ->
    case pop_and_dispatch_([], Db, Tab, Q) of
	done -> done;
	next -> until_done(Db, Tab, Q)
    end.

done([]) ->
    done;
done(ReplyTo) ->
    [Pid ! {self(), ?MODULE, done} || {Pid,_} <- ReplyTo],
    done.


%% The first time, we may be popping the queue from within a transaction
%% store, and need to ack to the transaction master that we're done. Note that
%% *we* delete the object if successful, so the master may be committing an
%% empty set (which is ok).
pop_and_dispatch_(Reply, Db, Tab, Q) ->
    ?debug("pop_and_dispatch_(~p, ~p, ~p)~n",
	   [Db, Tab, Q]),
    case kvdb:peek(Db, Tab, Q) of
	done ->
	    done(Reply);
	{ok, QK, {_, Env, RPC} = Entry} ->
	    ?debug("PEEK: Entry = ~p~n", [Entry]),
	    case exoport_rpc:dispatch(RPC, Env) of
		error ->
		    done(Reply);
		_Result ->
		    ?debug("Valid result (~p); deleting queue object~n",
			   [_Result]),
		    _DeleteRes = kvdb:queue_delete(Db, Tab, QK),
		    ?debug("Delete (~p) -> ~p~n", [QK, _DeleteRes]),
		    next
	    end
    end.
