%% -*- erlang-indent-level: 4; indent-tabs-mode: nil -*-
%% Copyright (c) 2012 Feuerlabs, Inc.
%%
-module(exoport_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    exoport_sup:start_link().

stop(_State) ->
    ok.
