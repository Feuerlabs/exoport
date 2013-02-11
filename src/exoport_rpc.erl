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

-export([queue_rpc/2]).
-export([dispatch/1]).

-include_lib("lager/include/log.hrl").


queue_rpc({_,_,_} = RPC, {_,_} = ReturnHook) ->
    kvdb:push(kvdb_conf, exoport, rpc, {1, [{on_return, ReturnHook}], RPC}),
    exoport_dispatcher:check_queue(exoport).

dispatch(Queue) ->
    case kvdb:pop(kvdb_conf, Queue) of
	{ok, {_, Env, {M,F,A} = RPC} = Entry} ->
	    ?debug("POP: Entry = ~p~n", [Entry]),
	    case exoport:rpc(M, F, A) of
		{reply, Reply, []} ->
		    ?debug("Reply: rpc(~p, ~p, ~p) -> ~p~n", [M,F,A,Reply]),
		    case lists:keyfind(on_return, Env) of
			{Mr,Fr} ->
			    Result = Mr:Fr(Reply, RPC),
			    ?debug("ReturnHook ~p:~p(~p, ~p) -> ~p~n",
				   [Mr,Fr,Reply,RPC,Result]),
			    ok;
			false ->
			    ok
		    end;
		Other ->
		    ?debug("Unexpected reply from rpc(~p,~p,~p): ~p~n",
			   [M, F, A, Other])
	    end;
	done ->
	    ?debug("POP: done~n", []),
	    ok
    end.
