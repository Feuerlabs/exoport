%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2012 Feuerlabs, Inc. All rights reserved.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%% @author Malotte W Lönne <malotte@malotte.net>
%%% @doc
%%%    Exoport gsms server
%%% Created : June 2013 by Malotte W Lönne
%%% @end
-module(exoport_gsms).
-behaviour(gen_server).

-include_lib("lager/include/log.hrl").
-include_lib("gsms/include/gsms.hrl").
-include("exoport.hrl").

%% api
-export([start_link/1, 
	 stop/0]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).

-import(proplists, [get_value/3]).

-define(SERVER, ?MODULE). 
-define(EXODM_RE, 
	"^EXODM-RPC:((sms|gprs|none)(,(sms|gprs|none))*)*:"
	  "[\\s]*[A-Za-z0-9/\+]*(=|==)?$").


%% for dialyzer
-type start_options()::{linked, TrueOrFalse::boolean()} |
		       {ppp_up_timeout, PppUp::timeout()} |
		       {ppp_idle_timeout, PppIdle::timeout()}.

%% loop data
-record(ctx,
	{
	  state = init  ::atom(),
	  connection_state ::connection_state(),
	  anumbers = [] ::list(string()),
	  filter = ""   ::string(),
	  ppp = false   ::boolean(),
	  provider = "" ::string(),
	  request       ::term(),
	  wait_for      ::atom(),
	  ppp_up_timeout::timeout(),
	  ppp_down_timeout::timeout(),
	  ppp_idle_timeout::timeout(),
	  gsms_ref      ::reference()
	}).

%% testing
-export([start/0,
	 dump/0]).
-compile(export_all).  %%% REMOVE !!!!

%%%===================================================================
%%% API
%%%===================================================================
%%--------------------------------------------------------------------
%% @doc
%% Starts the server.
%% Loads configuration from File.
%% @end
%%--------------------------------------------------------------------
-spec start_link(Opts::list(start_options())) -> 
			{ok, Pid::pid()} | 
			ignore | 
			{error, Error::term()}.

start_link(Opts) ->
    lager:info("~p: start_link: start options = ~p\n", [?MODULE, Opts]),
    F =	case get_value(linked,Opts,true) of
	    true -> start_link;
	    false -> start
	end,
    
    gen_server:F({local, ?SERVER}, ?MODULE, Opts, []).


%%--------------------------------------------------------------------
%% @doc
%% Stops the server.
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok | {error, Error::term()}.

stop() ->
    gen_server:call(?SERVER, stop).


%% Test functions
%% @private
start() ->
    application:start(uart),
    application:start(gsms),
    application:start(netlink),
    application:start(pppd_mgr).

%% @private
dump() ->
    gen_server:call(?SERVER, dump).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @end
%%--------------------------------------------------------------------
-spec init(Opts::list(start_options())) -> 
		  {ok, Ctx::#ctx{}} |
		  {stop, Reason::term()}.

init(Opts) ->
    lager:info("~p: init: opts = ~p,\n pid = ~p\n", [?MODULE, Opts, self()]),
    {ok, ConnectionState} = exoport_server:session_state_subscribe(),
    case init_gsms() of
	{ok, Ctx} ->
	    case init_ppp(Opts, Ctx) of
		{ok, PppCtx} ->
		    {ok, PppCtx#ctx {state = up,
				     connection_state = ConnectionState}};
		{error, Reason} ->
	    {stop, Reason}
	    end;
	{error, Reason} ->
	    {stop, Reason}
    end.

init_gsms() ->	
    case verify_apps_started([uart, gsms]) of
	ok ->
	    Anums = case application:get_env(exoport, anumbers) of
			undefined -> [];
			{ok, A} -> A
		    end,
	    ?dbg("init: A numbers ~p",[Anums]),
	    Filter = create_filter(Anums),
	    ?dbg("init: filter ~p",[Filter]),
	    {ok, start_gsms(#ctx {anumbers = Anums, filter = Filter})};
	E ->
	    ?ee("Not possible to start ~p, reason ~p.", [?MODULE, E]),
	    E
    end.

init_ppp(_Opts, Ctx) ->
    case application:get_env(exoport, ppp_provider) of
	undefined -> 
	    {ok, Ctx};
	{ok, Provider} -> 
	    %% If provider is given the applications must have been started
	    case verify_apps_started([netlink, pppd_mgr]) of
		ok -> 
		    ok = pppd_mgr:subscribe(),
		    %% Or from Opts ??
		    PppUp = pppd_mgr:ppp_parameter(ppp_on_time),
		    PppDown = pppd_mgr:ppp_parameter(ppp_off_time),
		    PppIdle = pppd_mgr:ppp_parameter(ppp_idle_time),

		    {ok, Ctx#ctx {ppp = true,
				  provider = Provider,
				  ppp_up_timeout = PppUp,
				  ppp_down_timeout = PppDown,
				  ppp_idle_timeout = PppIdle}};
		E -> 
		    ?ee("Not possible to start ~p, reason ~p.", [?MODULE, E]),
		    E
	    end
    end.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages.
%% Request can be the following:
%% <ul>
%% <li> dump - Writes loop data to standard out (for debugging).</li>
%% <li> stop - Stops the application.</li>
%% </ul>
%%
%% @end
%%--------------------------------------------------------------------
-type call_request()::
	dump |
	stop.

-spec handle_call(Request::call_request(), From::{pid(), Tag::term()}, 
		  Ctx::#ctx{}) ->
			 {reply, Reply::term(), Ctx::#ctx{}} |
			 {noreply, Ctx::#ctx{}} |
			 {stop, Reason::atom(), Reply::term(), Ctx::#ctx{}}.

handle_call(dump, _From, Ctx=#ctx {state = State, 
				   connection_state = CState,
				   anumbers = Anums, 
				   filter = Filter,
				   provider = Provider,
				   ppp = Ppp,
				   gsms_ref = Ref}) ->
    io:format("Ctx: State ~p, ConnectionState ~p, Anums ~p,~n"
	      "Filter ~w,~n Provider ~p, Ppp ~p, GsmsRef ~p~n", 
	      [State, CState, Anums, Filter, Provider, Ppp, Ref]),
    {reply, ok, Ctx};

handle_call(stop, _From, Ctx) ->
    ?dbg("stop:",[]),
    {stop, normal, ok, Ctx};

handle_call(_Request, _From, Ctx) ->
    ?dbg("handle_call: unknown request ~p", [_Request]),
    {reply, {error, bad_call}, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages.
%%
%% @end
%%--------------------------------------------------------------------
-type cast_msg()::
	term().

-spec handle_cast(Msg::cast_msg(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}} |
			 {stop, Reason::term(), Ctx::#ctx{}}.

handle_cast(_Msg, Ctx) ->
    ?dbg("handle_cast: unknown msg ~p", [_Msg]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages.
%% 
%% @end
%%--------------------------------------------------------------------
-type info()::
	up |
	down |
	{gsms, Ref::reference(), Msg::string()} |
	{session_state, ConnectionState::connection_state()} |
	ppp_up_timeout |
	ppp_idle_timeout.

-spec handle_info(Info::info(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}} |
			 {noreply, Ctx::#ctx{}, Timeout::timeout()} |
			 {stop, Reason::term(), Ctx::#ctx{}}.

handle_info({gsms, Ref, Pdu} = _Info, 
	    Ctx=#ctx {gsms_ref = Ref, ppp = Ppp}) ->
    ?dbg("handle_info: ~p", [_Info]),
    case handle_sms(Pdu) of
	{connect, Request} -> 
	    NewCtx = case Ppp of
			 false -> connect_and_exec(Request), Ctx;
			 true -> gsms_to_ppp(Request, Ctx)
		     end,
	    {noreply, NewCtx};
	ok -> {noreply, Ctx}
    end;

handle_info({gsms, UnknownRef, _Pdu} = _Info, Ctx) ->
    ?dbg("handle_info: info ~p from unknown ref ~p, ignored.", 
	 [_Info, UnknownRef]),
    {noreply, Ctx};

handle_info(up, Ctx=#ctx {request = undefined}) ->
    ?dbg("handle_info: ppp up, no request, ignore??"),
    %% Or should we deactivate ppp ???
    {noreply, Ctx};

handle_info(up, Ctx=#ctx {request = Request, wait_for = up}) ->
    ?dbg("handle_info: ppp up, connect to exodm"),
    connect_and_exec(Request),
    {noreply, Ctx#ctx {request = undefined, wait_for = undefined}};

handle_info(up, Ctx) ->
    ?dbg("handle_info: ppp up, unexpected, ignore ??"),
    {noreply, Ctx};

handle_info(down, Ctx=#ctx {wait_for = down}) ->
    ?dbg("handle_info: ppp down, start gsms"),
    exoport:disconnect(),
    {noreply, start_gsms(Ctx#ctx {wait_for = undefined})};

handle_info(down, Ctx) ->
    ?dbg("handle_info: ppp down, unexpected, ignore ??"),
    %% Or should we start gsms ???
    {noreply, Ctx};

handle_info({session_state, ConnectionState}, 
	    Ctx=#ctx {connection_state = ConnectionState}) ->
    ?dbg("handle_info: old connection state ~p ??", [ConnectionState]),
    {noreply, Ctx};

handle_info({session_state, active}, 
	    Ctx=#ctx {connection_state = inactive, 
		      ppp = false}) ->
    ?dbg("handle_info: new connection state active when no ppp"),
    %% This is presumably only a test case when running on host
    %% so use an arbitary timeout good for testing
    erlang:send_after(60000, self(), ppp_idle_timeout),
    {noreply, stop_gsms(Ctx#ctx {connection_state = active})};

handle_info({session_state, active}, 
	    Ctx=#ctx {connection_state = inactive, 
		      ppp_idle_timeout = PppIdle}) ->
    ?dbg("handle_info: new connection state active, stop gsms"),
    erlang:send_after(PppIdle, self(), ppp_idle_timeout),
    {noreply, stop_gsms(Ctx#ctx {connection_state = active})};

handle_info({session_state, inactive}, 
	    Ctx=#ctx {connection_state = active, 
		      ppp = false}) ->
    ?dbg("handle_info: new connection state inactive when no ppp"),
    {noreply, start_gsms(Ctx#ctx {connection_state = inactive})};

handle_info({session_state, inactive}, 
	    Ctx=#ctx {connection_state = active}) ->
    ?dbg("handle_info: new connection state inactive, start gsms"),
    {noreply, start_gsms(Ctx#ctx {connection_state = inactive})};

handle_info(ppp_up_timeout, Ctx=#ctx {request = Request}) ->
    ?dbg("handle_info: ppp up timeout, try again"),
    {noreply, gsms_to_ppp(Request, Ctx)};

handle_info(ppp_idle_timeout, Ctx) ->
    ?dbg("handle_info: ppp idle timeout, take down ppp ???"),
    {noreply, ppp_to_gsms(Ctx)};

handle_info(ppp_down_timeout, Ctx) ->
    ?dbg("handle_info: ppp down timeout, try again"),
    {noreply, ppp_to_gsms(Ctx)};

handle_info(_Info, Ctx) ->
    ?dbg("handle_info: unknown info ~p", [_Info]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
-spec terminate(Reason::term(), Ctx::#ctx{}) -> 
		       no_return().

terminate(_Reason, #ctx {state = State, gsms_ref = Ref, ppp = Ppp}) ->
    ?dbg("terminate: terminating in state ~p, reason = ~p",
	 [State, _Reason]),
    gsms_router:unsubscribe(Ref),
    exoport_server:session_state_unsubscribe(),
    if Ppp -> pppd_mgr:unsubscribe();
       true -> do_nothing
    end,
    ok.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process ctx when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn::term(), Ctx::#ctx{}, Extra::term()) -> 
			 {ok, NewCtx::#ctx{}}.

code_change(_OldVsn, Ctx, _Extra) ->
    ?dbg("code_change: old version ~p", [_OldVsn]),
    {ok, Ctx}.


%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
create_filter(Anums) ->
    AFilter = 
	lists:foldl(
	  fun(Anum, []) when is_list(Anum) -> 
		  {anumber, Anum};
	     (Anum, Acc) when is_list(Anum) -> 
		  {'or', {anumber, Anum}, Acc};
	     (_, Acc)->
		  Acc
	  end,
	  [], Anums),
    [{reg_exp, ?EXODM_RE}, AFilter].
    

%%--------------------------------------------------------------------
handle_sms(#gsms_deliver_pdu {ud = Msg, addr = Addr}) ->
    case string:tokens(Msg, ":") of
	["EXODM-RPC", ReplyMethods, Call] -> 
	    handle_request(decode(string:strip(Call)), 
			string:strip(ReplyMethods), 
			Addr);
	["EXODM-RPC", Call] -> 
	    %% default
	    handle_request(decode(string:strip(Call)), 
			   "none", Addr);
	    
	_ ->
	    ?dbg("handle_info: gsms, illegal msg ~p", [Msg]),
	    ok
    end.
    

handle_request(Request, MethodsString, Addr) ->
    Methods = [list_to_atom(string:strip(M)) || 
		  M <- string:tokens(MethodsString, ",")],
    exec_req(Request, Methods, Addr).
    
exec_req(_Request, [],  _Addr) ->
    ?dbg("request: no one to reply to");
exec_req(Request, [Method | Methods], Addr) ->
    case exec_req1(Request, Method, Addr) of 
	ok -> 
	    ok;
	{connect, Request} = C ->
	    C;
	{error, Error} ->
	    ?dbg("request: failed using ~p, reason ~p", 
		 [Method, Error]),
	    %% Try next method
	    exec_req(Request, Methods, Addr)
    end.
	    
exec_req1(Request, sms, Addr) ->
    ?dbg("request: sms"),
    Reply = try_exec(Request, external),
    ?dbg("request: reply ~p", [bert:to_term(Reply)]),
    case gsms_router:send([{addr, Addr}], "EXODM-RET:" ++ encode(Reply)) of
	{ok, _Ref} -> ok;
	E -> E
    end;
exec_req1(Request, gprs, _Addr) ->
    ?dbg("request: gprs"),
    case exoport_server:session_active() of
	true -> 
	    %% Exec now if we are connected
	    ?dbg("request: connected"),
	    try_exec(Request, internal), %% Result??
	    ok;
	_ -> 
	    ?dbg("request: connect"),
	    {connect, Request}
    end;
exec_req1(Request, none, _Addr) ->
    ?dbg("request: don't reply"),
    %%%try_exec(Request, external),
    %% FIXME !!!!
    exec_req1(Request, gprs, _Addr),
    ok;
exec_req1(_Request, Unknown, _Addr) ->
    ?dbg("request: unknown method ~p", [Unknown]),
    {error, unknown_method}.


try_exec(no_request, external) ->
    ok;
try_exec(Request, ReplyMethod) ->
    try exec(Request, ReplyMethod) of
	Result -> Result
    catch
	error:Error ->
	    ?error("CRASH: ~p; ~p~n", [Error, erlang:get_stacktrace()]),
	    bert:to_binary({error, illegal_call})
    end.

exec(Request, ExtOrInt) ->
    DecodedReq = bert:to_term(Request),
    ?dbg("request: ~p", [DecodedReq]),
    bert:to_binary(bert_rpc_exec:request(DecodedReq, ExtOrInt)).


gsms_to_ppp(Request, Ctx=#ctx {provider = Provider,
			       ppp = true,
			       ppp_idle_timeout = PppIdle,
			       ppp_up_timeout = PppUp}) ->
    %% Tear down sms so gprs can be acivated
    ?dbg("gsms_to_ppp: stop gsms"),
    exoport:disconnect(),
    NoGsmsCtx = stop_gsms(Ctx),
    NewCtx = case pppd_mgr:on(Provider) of
		 ok -> 
		     ?dbg("gsms_to_ppp: wait for ppp up"),
		     NoGsmsCtx#ctx {request = Request, wait_for = up};
		 {error,ealready} ->
		     ?dbg("gsms_to_ppp: ppp up, exec ~p", [Request]),
		     try_exec(Request, internal), %% Check result ??
		     NoGsmsCtx#ctx {request = undefined};
		 {error,ebusy} = _E->
		     %% Wait and try again ??
		     ?dbg("gsms_to_ppp: busy, retry"),
		     erlang:send_after(PppUp, self(), ppp_up_timeout),
		     NoGsmsCtx#ctx {request = Request}
	     end,
    %% Supervise ppp link to restart gsms when needed
    erlang:send_after(PppIdle, self(), ppp_idle_timeout),
    NewCtx.

ppp_to_gsms(Ctx=#ctx {ppp = false}) ->
    %% No ppp (idle timeout case)
    start_gsms(Ctx);
ppp_to_gsms(Ctx=#ctx {ppp_down_timeout = PppDown}) ->
    case pppd_mgr:off() of
	ok -> 
	    ?dbg("ppp_to_gsms: wait for ppp down"),
	    erlang:send_after(PppDown, self(), ppp_down_timeout),
	    Ctx#ctx {wait_for = down};
	{error,not_running} ->
	    %% Already down, activate gsms now
	    ?dbg("ppp_to_gsms: ppp down, start gsms"),
	    exoport:disconnect(),
	    start_gsms(Ctx)
    end.

connect_and_exec(Request) ->
    exoport_server:connect(),
    try_exec(Request, internal). %% Result ??

start_gsms(Ctx=#ctx {filter = Filter}) ->
    application:start(gsms),
    {ok, Ref} = gsms_router:subscribe(Filter),
    Ctx#ctx {gsms_ref = Ref}.

stop_gsms(Ctx) ->
    %% gsms_router:unsubscribe(Ref), not needed ??
    application:stop(gsms),
    Ctx#ctx {gsms_ref = undefined}.
     
decode(String) ->
    base64:decode(String).
    %% from_hex(String).

encode(Bin) when is_binary(Bin) ->
    binary_to_list(base64:encode(Bin));
    %% to_hex(Bin);
encode(List) when is_list(List) ->
    encode(list_to_binary(List));
encode(Int) when is_integer(Int) ->
    encode(erlang:integer_to_list(Int, 16)).

   
from_hex(String) when is_list(String) ->
    << << (erlang:list_to_integer([H], 16)):4 >> || H <- String >>.

to_hex(Bin) when is_binary(Bin) ->
    [element(I+1,{$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,
		  $a,$b,$c,$d,$e,$f}) || <<I:4>> <= Bin].

verify_apps_started([]) ->
    ok;
verify_apps_started([App | Apps]) ->
    case verify_app_started(App) of
	ok -> verify_apps_started(Apps);
	E -> E
    end.
	    
verify_app_started(App) ->
    case get(on_host) of
	true -> 
	    ok;
	_Other -> 
	    case lists:keymember(App, 1, application:which_applications()) of
		true ->
		    ok;
		false ->
		    {error, list_to_atom(atom_to_list(App) ++ "_not_runnning")}
	    end
    end.

