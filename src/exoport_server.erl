%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2012 Feuerlabs, Inc. All rights reserved.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%% @doc
%%%    Server for serializing device-to-server RPCs
%%% @end
-module(exoport_server).
-behavior(gen_server).

-export([rpc/3,
	 session_active/0,
	 connect/0,
	 maybe_connect/0,
	 disconnect/0]).

-export([start_link/0,
	 init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

-record(st, {session = undefined,
	     auto_connect = true}).

-include_lib("lager/include/log.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

rpc(M, F, A) ->
    case gen_server:call(?MODULE, {call, M, F, A}, infinity) of
	{ok, Result} ->
	    Result;
	{error, _} = Error ->
	    Error
    end.

session_active() ->
    gen_server:call(?MODULE, session_active).

connect() ->
    gen_server:call(?MODULE, connect, infinity).

maybe_connect() ->
    gen_server:call(?MODULE, maybe_connect, infinity).

disconnect() ->
    gen_server:call(?MODULE, disconnect, infinity).

init(_) ->
    error_logger:info_msg("~p: init: pid = ~p", [?MODULE, self()]),
    St0 = #st{},
    Auto = case application:get_env(exoport, auto_connect) of
	       {ok, B} when is_boolean(B) ->
		   B;
	       undefined ->
		   St0#st.auto_connect
	   end,
    {ok, St0#st{auto_connect = Auto}}.

%% maybe_connect(#st{auto_connect = true} = St) ->
%%     connect_(St);
%% maybe_connect(St) ->
%%     St.

handle_call(connect, _From, St) ->
    %% should perhaps reply something indicating how it went... FIXME
    {reply, ok, connect_(St)};
handle_call(maybe_connect, _From, #st{session = Session,
				      auto_connect = Auto} = St) ->
    case {Session, Auto} of
	{undefined, yes} ->
	    {reply, true, connect_(St)};
	{undefined, false} ->
	    {reply, no, St};
	{_, _} ->
	    {reply, already_connected, St}
    end;
handle_call({call, M, F, A}, _From, St) ->
    {Reply, St1} = try rpc_(M, F, A, St)
		   catch
		       error:Reason ->
			   {{error, Reason}, St}
		   end,
    {reply, Reply, St1};
handle_call(disconnect, _, #st{session = Session} = St) ->
    Res = case Session of
	      {Host, Port} ->
		  nice_bert_rpc:disconnect(Host, Port, [tcp]);
	      undefined ->
		  {error, no_session}
	  end,
    {reply, Res, St#st{session = undefined}};
handle_call(session_active, _, #st{session = S} = St) ->
    {reply, S =/= undefined, St};
handle_call(_, _, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(_, St) ->
    {noreply, St}.

handle_info(_, St) ->
    {noreply, St}.

terminate(_, _) ->
    ok.

code_change(_, St, _) ->
    {ok, St}.

rpc_(M, F, A, #st{auto_connect = Auto} = St) ->
    rpc_(M, F, A, St, Auto).

rpc_(_M, _F, _A, #st{session = undefined} = St, false) ->
    {{error, no_session}, St};
rpc_(M, F, A, #st{session = undefined} = St, true) ->
    case call_rpc_(exodm_rpc, ping, [], St) of
	{{ok, {reply, pong, []}} = PingRes, St1} ->
	    Result =
		case {M,F,A} of
		    {exodm_rpc, ping, []} ->
			{PingRes, St1};
		    _ ->
			call_rpc_(M, F, A, St1)
		end,
	    check_queue(),
	    Result;
	Other ->
	    ?error("Unexpected: ~p~n", [Other]),
	    {{error, no_session}, St}
    end;
rpc_(M, F, A, #st{session = Session} = St, _) when Session =/= undefined ->
    call_rpc_(M, F, A, St).


connect_(St) ->
    case call_rpc_(exodm_rpc, ping, [], St) of
	{{ok, {reply, pong, []}}, St1} ->
	    ?debug("connected~n", []),
	    check_queue(),
	    ?debug("queue checked~n", []),
	    St1;
	_ ->
	    St
    end.

call_rpc_(M, F, A, #st{session = Session0} = St) ->
    {Host, Port} =
	Session = case Session0 of
		      undefined ->
			  case application:get_env(exoport, exodm_address) of
			      {ok, {_, _} = S} -> S;
			      _ -> error(no_address)
			  end;
		      {_, _} ->
			  Session0
		  end,
    St1 = St#st{session = Session},
    Res = {ok, nice_bert_rpc:call_host(Host, Port, [tcp], M, F, A)},
    ?debug("Res = ~p~n", [Res]),
    {Res, St1}.


check_queue() ->
    exoport_dispatcher:check_queue(exoport, rpc).
