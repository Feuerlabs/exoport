-module(exoport_dispatcher).
-behaviour(gen_server).

-export([check_queue/2]).
-export([attempt_dispatch/3,
	 attempt_dispatch/4]).
-export([start_link/3]).
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

-record(st, {tab, mod,
	     queues = dict:new(),
	     pids = dict:new(),
	     pending = sets:new(),
	     jobs_queue = default}).

-include_lib("lager/include/log.hrl").

-spec check_queue(kvdb:tab_name(),
		  kvdb:queue_name()) -> pid() | {pending, pid()}.
check_queue(Tab, Q) ->
    ?debug("check_queue(~p, ~p)~n", [Tab, Q]),
    call(Tab, {check_queue, Q}).

attempt_dispatch(Db, Tab, Q) ->
    attempt_dispatch(Db, Tab, Q, false).

attempt_dispatch(Db, Tab, Q, Reply) when is_boolean(Reply) ->
    call(Tab, {attempt_dispatch, Q, Db, Reply}).

call(Tab0, Req) ->
    try
    Tab = kvdb_lib:table_name(Tab0),
    case gproc:where({n,l, {?MODULE, Tab}}) of
	undefined ->
	    error(noproc);
	Pid when is_pid(Pid) ->
	    gen_server:call(Pid, Req)
    end
    catch
	error:Reason ->
	    ?error("Crash in ~p:call(~p, ~p): ~p~n", [?MODULE,Tab0,Req,Reason]),
	    error(Reason)
    end.

start_link(Tab0, M, JobQ) ->
    Tab = kvdb_lib:table_name(Tab0),
    gen_server:start_link(?MODULE, {Tab, M, JobQ}, []).

init({Tab0, M, JobQ} = Arg) ->
    Tab = kvdb_lib:table_name(Tab0),
    gproc:reg({n, l, {?MODULE, Tab}}),
    try
	ok = kvdb_conf:add_table(Tab, [{type, fifo},
				       {encoding, {raw,sext,sext}}]),
	kvdb_schema_events:notify_all_queues(kvdb:db(kvdb_conf), Tab),
	?debug("checking queues in ~p~n", [Tab]),
	St = check_queues(kvdb:first_queue(kvdb_conf, Tab),
			  #st{tab = Tab, mod = M,
			      jobs_queue = JobQ}),
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
    {_, St1} = spawn_dispatcher(Q, St),
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
		  case sets:is_element(Q, Pending) of
		      true ->
			  {_, NewSt} =
			      spawn_dispatcher(
				Q, St#st{pids = dict:erase(Pid, Pids),
					 queues = dict:erase(Q, Qs),
					 pending = sets:del_element(
						     Q, Pending)}),
			  NewSt;
		      false ->
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
handle_call({attempt_dispatch, Q, Db, Reply}, From, #st{queues = Qs} = St) ->
    case dict:find(Q, Qs) of
	error ->
	    DbArg = if Reply -> Db;
		       true -> kvdb:db_name(Db)
		    end,
	    {Pid, St1} = spawn_dispatcher(Q, DbArg, From, Reply, St),
	    {reply, {ok, Pid}, St1};
	{ok, CurPid} ->
	    {_, St1} = mark_pending(CurPid, Q, St),
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
	    spawn_dispatcher(Q, St);
	{ok, CurPid} ->
	    mark_pending(CurPid, Q, St)
    end.

mark_pending(CurPid, Q, #st{pending = Pending} = St) ->
    {{pending, CurPid},
     St#st{pending = case sets:is_element(Q, Pending) of
			 true -> Pending;
			 false -> sets:add_element(Q, Pending)
		     end}}.

spawn_dispatcher(Q, St) ->
    spawn_dispatcher(Q, kvdb_conf, undefined, false, St).

spawn_dispatcher(Q, Db, From, Reply, #st{tab = Tab, pids = Pids, queues = Qs,
					 jobs_queue = JobsQ} = St) ->
    {Pid, _} = spawn_monitor(
		 fun() ->
			 run_dispatcher(JobsQ, Db, Tab, Q, From, Reply)
		 end),
    {Pid, St#st{pids = dict:store(Pid, Q, Pids),
		queues = dict:store(Q, Pid, Qs)}}.

run_dispatcher(JobsQ, Db, Tab, Q, From, Reply) ->
    try
	timer:sleep(500),
	dispatch(Db, Tab, Q, JobsQ, From, Reply)
    catch
	Type:Exception ->
	    ?error("Dispatch thread exception: ~p:~p~n~p~n",
		   [Type, Exception, erlang:get_stacktrace()])
    end.



dispatch(Db, Tab, Q, JobsQ, From, Reply) ->
    ?debug("dispatch(~p, ~p)~n", [Tab, Q]),
    try
	case exodm_rpc_handler:device_sessions(Q) of
	    [_|_] = Sessions ->
		pop_and_dispatch(From, Reply, Db, Tab, Q, JobsQ, Sessions);
	    [] ->
		done(From, Reply)
	end
    catch
	error:Reason ->
	    ?error("ERROR in ~p:dispatch(): ~p~n~p~n",
		   [?MODULE,Reason, erlang:get_stacktrace()])
    end.

pop_and_dispatch(_, false, Db, Tab, Q, JobsQ, Sessions) ->
    kvdb:transaction(
      Db,
      fun(Db1) ->
	      until_done(Db1, Tab, Q, JobsQ, Sessions)
	   end);
pop_and_dispatch(From, Reply, Db, Tab, Q, JobsQ, Sessions) ->
    case kvdb:in_transaction(
	   Db,
	   fun(Db1) ->
		   pop_and_dispatch_(From, Reply, Db1, Tab, Q, JobsQ, Sessions)
	   end) of
	done ->
	    done;
	next ->
	    kvdb:transaction(
	      kvdb_conf,
	      fun(Db1) ->
		      until_done(Db1, Tab, Q, JobsQ, Sessions)
	      end)
    end.

until_done(Db, Tab, Q, JobsQ, Sessions) ->
    case pop_and_dispatch_(undefined, false, Db, Tab, Q, JobsQ, Sessions) of
	done -> done;
	next -> until_done(Db, Tab, Q, JobsQ, Sessions)
    end.

done({Pid, _}, true) ->
    Pid ! {self(), ?MODULE, done},
    done;
done(_, _) ->
    done.


%% The first time, we may be popping the queue from within a transaction
%% store, and need to ack to the transaction master that we're done. Note that
%% *we* delete the object if successful, so the master may be committing an
%% empty set (which is ok).
pop_and_dispatch_(From, Reply, Db, Tab, Q, JobsQ, Sessions) ->
    ?debug("pop_and_dispatch_(~p, ~p, ~p, ~p, ~p)~n",
	   [Db, Tab, Q, Sessions, From]),
    jobs:run(
      JobsQ, fun() ->
		     pop_and_dispatch_run_(From, Reply, Db, Tab, Q, Sessions)
	     end).

pop_and_dispatch_run_(From, Reply, Db, Tab, Q, Sessions) ->
    case kvdb:pop(Db, Tab, Q) of
	done ->
	    done(From, Reply);
	{ok, {_, Env, Req} = Entry} ->
	    ?debug("POP: Entry = ~p~n", [Entry]),
	    set_user(Env, Db),
	    {AID, DID} = exodm_db_device:dec_ext_key(Q),
	    Protocol = exodm_db_device:protocol(AID, DID),
	    case lists:keyfind(Protocol, 2, Sessions) of
		{Pid, _} ->
		    Mod = exodm_rpc_protocol:module(Protocol),
		    ?debug("Calling ~p:dispatch(~p, ~p, ~p, ~p)~n",
			   [Mod, Env, AID, DID, Pid]),
		    case Mod:dispatch(Tab, Req, Env, AID,
				      exodm_db:decode_id(DID), Pid) of
			error ->
			    done(From, Reply);
			_Result ->
			    done(From, Reply),
			    next
		    end;
		false ->
		    ?error("No matching protocol session for ~p (~p)~n"
			   "Entry now blocking queue~n",
			   [Entry, Sessions]),
		    done(From, Reply)
	    end
    end.


set_user(Env, Db) ->
    {_, UID} = lists:keyfind(user, 1, Env),
    exodm_db_session:logout(),
    exodm_db_session:set_auth_as_user(UID, Db).
