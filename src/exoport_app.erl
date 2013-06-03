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
-module(exoport_app).

-behaviour(application).

%% Application callbacks
-export([start/2,
	 start_phase/3,
	 stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================
%%--------------------------------------------------------------------
%% @doc
%% Starts the application.<br/>
%% Arguments are ignored, instead the options for the application server are 
%% retreived from the application environment (sys.config).
%%
%% @end
%%--------------------------------------------------------------------
-spec start(StartType:: normal | 
			{takeover, Node::atom()} | 
			{failover, Node::atom()}, 
	    StartArgs::term()) -> 
		   {ok, Pid::pid()} |
		   {ok, Pid::pid(), State::term()} |
		   {error, Reason::term()}.


start(_StartType, _StartArgs) ->
    error_logger:info_msg("~p: start: arguments ignored.\n", [?MODULE]),
    Env = case application:get_all_env(exoport) of
	       undefined -> [];
	       O -> O
	   end,
    exoport_sup:start_link(Env).

start_phase(start_http, _, _) ->
    exoport_http:instance(),
    ok;
start_phase(load_yang_specs, _, _) ->
    load_yang_specs(),
    ok;
start_phase(auto_connect, _, _) ->
    exoport_server:maybe_connect(),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% Stops the application.
%%
%% @end
%%--------------------------------------------------------------------
-spec stop(State::term()) -> ok | {error, Error::term()}.

stop(_State) ->
    exit(stopped).


load_yang_specs() ->
    Mods = setup:find_env_vars(yang_spec_modules),
    lists:foreach(
      fun({_AppName, Paths} = P) ->
	      io:fwrite("Yang spec module path: ~p~n", [P]),
	      apply_paths(Paths)
      end, Mods).

apply_paths([{Dir, FilePath}|Ps]) ->
    Files = filelib:wildcard(FilePath, Dir),
    lists:foreach(
      fun(F) ->
	      case filename:extension(F) of
		  ".beam" ->
		      File = filename:join(Dir, filename:basename(F, ".beam")),
		      LoadRes = code:load_abs(File),
		      io:fwrite("LoadRes (~s.beam): ~p~n", [File, LoadRes]);
		  _ ->
		      io:fwrite("Skipping ~s~n", [F])
	      end
      end, Files),
    apply_paths(Ps);
apply_paths([]) ->
    ok.

