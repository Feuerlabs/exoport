%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2012 Feuerlabs, Inc. All rights reserved.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%% -*- erlang-indent-level: 4; indent-tabs-mode: nil -*-
%%% Copyright (c) 2012 Feuerlabs, Inc.
%%%
%%% @author Malotte W Lönne <malotte@malotte.net>
%%% @copyright (C) 2012, Fueuerlabs, Inc
%%% @doc
%%%    Wrapper for bert ??
%%%
%%% Created :  14 May Ulf Wiger
%%% @end
%%%-------------------------------------------------------------------
-module(exoport_sup).

-behaviour(supervisor).

%% API
-export([start_link/1,
	 stop/1,
	 add_children/1]).

%% Supervisor callbacks
-export([init/1]).

-record(conf, {id, gconf, docroot, sconf}).

%% ===================================================================
%% API functions
%% ===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor. <br/>
%% Arguments are sent on to the supervisor.
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link(Args::list(term())) ->
			{ok, Pid::pid()} |
			ignore |
			{error, Error::term()}.

start_link(Args) ->
    error_logger:info_msg("~p: start_link: args = ~p\n", [?MODULE, Args]),
    case supervisor:start_link({local, ?MODULE}, ?MODULE, Args) of
	{ok, Pid} ->
	    {ok, Pid, {normal, Args}};
	Error ->
	    error_logger:error_msg("~p: start_link: Failed to start process, "
				   "reason ~p\n",  [?MODULE, Error]),
	    Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% Stops the supervisor.
%%
%% @end
%%--------------------------------------------------------------------
-spec stop(StartArgs::list(term())) -> ok | {error, Error::term()}.

stop(_StartArgs) ->
    exit(stopped).


%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
init(_Args) ->
    {ok, { {one_for_one, 5, 10},
	   [{exoport_dispatcher, {exoport_dispatcher, start_link,
				  [exoport, exoport_rpc, exoport_rpc]},
	     permanent, 5000, worker, [exoport_dispatcher]},
	    {exoport_server, {exoport_server, start_link, []},
	     permanent, 5000, worker, [exoport_server]},
	    {bert_rpc_exec, {exoport, start_rpc_server, []},
	     permanent, 5000, worker, [bert_rpc_exec]}] } }.


add_children(ChildSpecs) ->
    [ok(supervisor:start_child(?MODULE, Ch)) || Ch <- ChildSpecs],
    ok.

ok({ok, _}) -> ok;
ok({ok, _, _}) -> ok;
ok(Other) ->
    error(Other).
