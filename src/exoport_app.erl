%%% -*- erlang-indent-level: 4; indent-tabs-mode: nil -*-
%%% Copyright (c) 2012 Feuerlabs, Inc.
%%%
%%% @author Malotte W L�nne <malotte@malotte.net>
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
-export([start/2, stop/1]).

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

%%--------------------------------------------------------------------
%% @doc
%% Stops the application.
%%
%% @end
%%--------------------------------------------------------------------
-spec stop(State::term()) -> ok | {error, Error::term()}.

stop(_State) ->
    exit(stopped).
