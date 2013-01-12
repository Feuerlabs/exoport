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
%%%    Start wrapper
%%% @end
%%% Created : 24 May 2012 by Tony Rogvall <tony@rogvall.se>

-module(exoport).

-export([start/0, start/1,
	 start_rpc_server/0]).

-export([rpc_auth_options/0]).

-export([ping/0,
	 rpc/3,
	 notify/3,
	 configure/1, configure/2,
	 reload_conf/0]).

-include_lib("bert/include/bert.hrl").
-include_lib("lager/include/log.hrl").

-define(ACCESS_FILE,"rpc_access.conf").

%% helper when starting from command line
start() ->
    start([]).

start(Opts) ->
    Apps = [crypto, public_key, exo, bert, kvdb, exoport],
    [application:load(A) || A <- Apps],
    lists:foreach(fun({config, Cfg}) ->
			  configure(Cfg, false);
		     ({K, V}) ->
			  application:set_env(exoport, K, V);
		     ({A, K, V}) ->
			  case lists:member(A, Apps) of
			      true -> application:set_env(A, K, V);
			      false ->
				  error({not_allowed, [set_env, {A,K,V}]})
			  end
		  end, Opts),
    [application:start(A) || A <- Apps],
    ok.

rpc_auth_options() ->
    case application:get_env(exoport, auth) of
	{ok, Opts} ->
	    Opts;
	undefined ->
	    false
    end.

ping() ->
    rpc(exodm_rpc, ping, []).

rpc(M, F, A) ->
    case application:get_env(exoport, exodm_address) of
	{ok, {Host, Port}} ->
	    nice_bert_rpc:call_host(Host, Port, [tcp], M, F, A);
	_ ->
	    {error, no_address}
    end.

notify(Module, Method, Info) ->
    RPC = {exodm_rpc, notification, [Module, Method, Info]},
    exoport_rpc:queue_rpc(RPC, {exoport_rpc, log_notify_result}).

configure(FileOrOpts) ->
    configure(FileOrOpts, _Reload = true).

configure(FileOrOpts, Reload) when is_boolean(Reload) ->
    io:fwrite("configure(~p, ~p)~n", [FileOrOpts, Reload]),
    case consult_config(FileOrOpts) of
	{ok, Terms} ->
	    io:fwrite("config Terms = ~p~n", [Terms]),
	    config_exodm_addr(Terms),
	    config_device_id(Terms),
	    application:set_env(exoport, config, FileOrOpts),
	    if Reload ->
		    reload_conf();
	       true ->
		    ok
	    end;
	Error ->
	    io:fwrite("configure(...) -> ~p~n", [Error]),
	    Error
    end.

consult_config([T|_] = Config) when is_tuple(T) ->
    {ok, Config};
consult_config({script, File}) ->
    file:script(File);
consult_config([I|_] = File) when is_integer(I) ->
    file:consult(File).


reload_conf() ->
    supervisor:terminate_child(exoport_sup, bert_rpc_exec),
    supervisor:restart_child(exoport_sup, bert_rpc_exec).

config_exodm_addr(Opts) ->
    Host = alt_opt([exodm_host, host], Opts, "localhost"),
    Port = alt_opt([exodm_port, port], Opts, 9900),
    application:set_env(exoport, exodm_address, {Host, Port}),
    true.

config_device_id(Opts) ->
    case alt_opt([device_id, 'device-id'], Opts) of
	undefined ->
	    false;
	ID ->
	    Ck = alt_opt([ckey, 'client-key'], Opts, 0),
	    Sk = alt_opt([skey, 'server-key'], Opts, 0),
	    application:set_env(bert, reuse_mode, client),
	    application:set_env(
	      bert, auth, [
			   {id, to_binary(ID)},
			   {client, [
                                     {id, to_binary(ID)},
				     {keys, {uint64(Ck), uint64(Sk)}},
				     {mod, bert_challenge}
				    ]}
			  ]),
	    true
    end.

to_binary(B) when is_binary(B) ->
    B;
to_binary(L) when is_list(L) ->
    list_to_binary(L).

uint64(I) when is_integer(I), I >= 0 ->
    <<I:64>>;
uint64(L) when is_list(L) ->
    <<(list_to_integer(L)):64>>;
uint64(<<_:64>> = Bin) ->
    Bin.


start_rpc_server() ->
    error_logger:info_msg("~p: start_rpc_server: pid = ~p\n",
                          [?MODULE, self()]),
    case application:get_env(exoport, config) of
	{ok, Cfg} ->
	    io:fwrite("Preset exoport config: ~p~n", [Cfg]),
	    configure(Cfg, false);
	undefined ->
	    ok
    end,
    {ok, Access} = load_access(),
    %% NewOpts = [{access, Access} | lists:keydelete(access, 1, Opts)],
    io:fwrite("All Env = ~p~n", [application:get_all_env(exoport)]),
    BertPort = opt_env(bert_port, ?BERT_PORT),
    io:fwrite("BertPort = ~p~n", [BertPort]),
    BertReuse = case application:get_env(bert, reuse_mode) of
                    {ok, Mode} ->
                        Mode;
                    _ ->
                        none
                end,
    BertAuth = case application:get_env(bert, auth) of
                   {ok, AuthOpts} when is_list(AuthOpts) ->
                       AuthOpts;
                   _ -> false
               end,
    NewOpts = [{access, Access}, {port, BertPort},
               {exo, [{reuse_mode, BertReuse},
                      {auth, BertAuth}]}],
    error_logger:info_msg("~p: About to start bert_rpc_exec~n"
			  "Opts = ~p~n", [?MODULE, NewOpts]),
    bert_rpc_exec:start_link(NewOpts).

load_access() ->
    case application:get_env(exoport, access) of
        {ok, {file, F}} ->
            load_access(F);
        undefined ->
            load_access(?ACCESS_FILE);
        {ok, []} ->
            {ok, []};
        {ok, [_|_] = Access} when is_tuple(hd(Access)) ->
            {ok, Access}
    end.


load_access(FileName) ->
    Dir = code:priv_dir(exoport),
    File = filename:join(Dir, FileName),
    case filelib:is_regular(File) of
	true ->
            file:consult(File);
	false ->
            error_logger:error_msg("~p: access: File ~p not found.\n",
                                  [?MODULE, File]),
            {ok, []}
    end.

opt_env(K, Default) ->
    case application:get_env(K) of
        {ok, Val} ->
            Val;
        undefined ->
            Default
    end.

alt_opt(Keys, Opts) ->
    alt_opt(Keys, Opts, undefined).

alt_opt([H|T], Opts, Default) ->
    case lists:keyfind(H, 1, Opts) of
	{_, Val} ->
	    Val;
	false ->
	    alt_opt(T, Opts, Default)
    end;
alt_opt([], _, Default) ->
    Default.

