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

-export([rpc/3]).

-export([start_link/0,
	 init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

-record(st, {}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

rpc(M, F, A) ->
    case gen_server:call(?MODULE, {call, M, F, A}, infinity) of
	{ok, Result} ->
	    Result;
	{error, Reason} ->
	    error(Reason)
    end.

init(_) ->
    {ok, #st{}}.

handle_call({call, M, F, A}, _From, St) ->
    Reply = try rpc_(M, F, A)
	    catch
		error:Reason ->
		    {error, Reason}
	    end,
    {reply, Reply, St};
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

rpc_(M, F, A) ->
    case application:get_env(exoport, exodm_address) of
	{ok, {Host, Port}} ->
	    {ok, nice_bert_rpc:call_host(Host, Port, [tcp], M, F, A)};
	_ ->
	    {error, no_address}
    end.

