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
    Opts = case application:get_env(options) of
	       undefined -> [];
	       {ok, O} -> O
	   end,
    Args = [{options, Opts}],
    exoport_sup:start_link(Args).

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
      fun({_AppName, Pats} = P) ->
	      io:fwrite("Yang spec module pat: ~p~n", [P]),
	      apply_pats(Pats)
      end, Mods).

apply_pats([{Dir, FilePat}|Ps]) ->
    Files = filelib:wildcard(FilePat, Dir),
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
    apply_pats(Ps);
apply_pats([]) ->
    ok.

