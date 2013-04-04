%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2012 Feuerlabs, Inc. All rights reserved.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
-module(exoport_rpc).

-export([queue_rpc/2,
	 ignore/3]).
-export([dispatch/2]).

-include_lib("lager/include/log.hrl").


queue_rpc({_,_,_} = RPC, {_,_} = ReturnHook) ->
    queue_rpc(RPC, ReturnHook, []).

queue_rpc({_,_,_} = RPC, {_,_} = ReturnHook, Env) when is_list(Env) ->
    kvdb:push(kvdb_conf, exoport, rpc,
	      {1, [{on_return, ReturnHook}|Env], RPC}),
    exoport_dispatcher:check_queue().

%% @spec ignore(Reply, RPC, Env) -> ok
%% @doc Dummy return hook; to use when return value is to be ignored.
%% @end
ignore(Reply, RPC, _Env) ->
    io:fwrite("Ignoring return hook~n"
	      "RPC = ~p; Reply = ~p~n", [RPC, Reply]),
    ok.

dispatch({M, F, A} = RPC, Env) ->
    try
	case exoport:rpc(M, F, A) of
	    {reply, Reply, []} ->
		?debug("Reply: rpc(~p, ~p, ~p) -> ~p~n", [M,F,A,Reply]),
		case lists:keyfind(on_return, 1, Env) of
		    {_, {Mr,Fr}} ->
			Result = Mr:Fr(Reply, RPC, Env),
			?debug("ReturnHook ~p:~p(~p, ~p) -> ~p~n",
			       [Mr,Fr,Reply,RPC,Result]),
			ok;
		    false ->
			ok
		end;
	    Other ->
		?debug("Unexpected reply from rpc(~p,~p,~p): ~p~n",
		       [M, F, A, Other]),
		error
	end
    catch
	error:Error ->
	    ?error("CRASH: ~p; ~p~n", [Error, erlang:get_stacktrace()]),
	    error
    end.
