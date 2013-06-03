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

-define(SERVER, ?MODULE). 
-define(EXODM_RE, "^EXODM-RPC: ([0-9A-Fa-f] [0-9A-Fa-f])*").

-define(dbg(Format, Args),
	lager:debug("~s(~p): " ++ Format, [?MODULE, self() | Args])).

%% for dialyzer
-type start_options()::{linked, TrueOrFalse::boolean()}.

%% loop data
-record(ctx,
	{
	  state = init ::atom(),
	  anumbers = [] ::list(string()),
	  ref::reference()
	}).

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
    F =	case proplists:get_value(linked,Opts,true) of
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
-spec init(Args::list(start_options())) -> 
		  {ok, Ctx::#ctx{}} |
		  {stop, Reason::term()}.

init(Args) ->
    lager:info("~p: init: args = ~p,\n pid = ~p\n", [?MODULE, Args, self()]),
    Anums = case application:get_env(exoport, anumbers) of
	       undefined -> [];
	       A -> A
	   end,
    Filter = create_filter(Anums),
    Ref = gsms_router:subscribe(Filter),
    {ok, #ctx {state = up, ref = Ref, anumbers = Anums}}.

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

handle_call(dump, _From, 
	    Ctx=#ctx {state = State, anumbers = Anums, ref = Ref}) ->
    io:format("Ctx: State = ~p, Anums = ~p, GsmsRef = ~p", 
	      [State, Anums, Ref]),
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
	{gsms, Ref::reference(), Msg::string()}.

-spec handle_info(Info::info(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}} |
			 {noreply, Ctx::#ctx{}, Timeout::timeout()} |
			 {stop, Reason::term(), Ctx::#ctx{}}.

handle_info({gsms, _Ref, #gsms_deliver_pdu {ud = Msg, addr = Addr}} = _Info, 
	    Ctx) ->
    ?dbg("handle_info: ~p", [_Info]),
    %% Check ref ??
    
    case string:tokens(Msg, ":") of
	["EXODM-RPC:", ReplyMethods, Call] -> 
	    Reply = execute_call(Call),
	    reply(Reply, ReplyMethods, Addr);
	_ ->
	    ?dbg("handle_info: gsms, illegal msg ~p", [Msg]),
	    do_nothing
    end,
    {noreply, Ctx};

handle_info(_Info, Ctx) ->
    ?dbg("handle_info: unknown info ~p", [_Info]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
-spec terminate(Reason::term(), Ctx::#ctx{}) -> 
		       no_return().

terminate(_Reason, _Ctx=#ctx {state = State, ref = Ref}) ->
    ?dbg("terminate: terminating in state ~p, reason = ~p",
	 [State, _Reason]),
    gsms_router:unsubscribe(Ref),
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
execute_call(Call) ->
    try 
	MFA = {M, F, A} = bert:to_term(Call),
	?dbg("execute_call: ~p", [MFA]),
	bert:to_binary(apply(M,F,A))
    catch
	error:Error ->
	    ?error("CRASH: ~p; ~p~n", [Error, erlang:get_stacktrace()]),
	    bert:to_binary({error, illegal_call})
    end.

%%--------------------------------------------------------------------
reply(Reply, MethodsString, Addr) ->
    Methods = [list_to_atom(M) || M <- string:tokens(MethodsString, ",")],
    reply_all(Reply, Methods, Addr).
    
reply_all(_Reply, [],  _Addr) ->
    ?dbg("reply: no one to reply to", []);
reply_all(Reply, [Method | Methods], Addr) ->
    case reply_one(Reply, Method, Addr) of 
	ok -> 
	    ?dbg("reply: sent using ~p", [Method]),
	    ok;
	{error, Error} ->
	    ?dbg("reply: failed using ~p, reason ~p", 
		 [Method, Error]),
	    reply_all(Reply, Methods, Addr)
    end.
	    
reply_one(Reply, sms, Addr) ->
    gsms_router:send([{anumber, Addr}], Reply);
reply_one(Reply, gprs, _Addr) ->
    %%
    ok.
