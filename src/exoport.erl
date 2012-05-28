%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2012, Tony Rogvall
%%% @doc
%%%    Start wrapper
%%% @end
%%% Created : 24 May 2012 by Tony Rogvall <tony@rogvall.se>

-module(exoport).

-export([start/0]).

-export([rpc_auth_options/0]).

-export([ping/0,
	 configure/1,
	 reload_conf/0]).

%% helper when starting from command line
start() ->
    application:start(bert),
    application:start(exoport).

rpc_auth_options() ->
    case application:get_env(exoport, auth) of
	{ok, Opts} ->
	    Opts;
	undefined ->
	    false
    end.

ping() ->
    case application:get_env(exoport, exodm_address) of
	{ok, {Host, Port}} ->
	    nice_bert_rpc:call_host(Host, Port, [tcp], exodm_rpc, ping, []);
	_ ->
	    {error, no_address}
    end.

configure(File) ->
    case file:consult(File) of
	{ok, Terms} ->
	    config_exodm_addr(Terms),
	    config_device_id(Terms),
	    reload_conf();
	Error ->
	    Error
    end.

reload_conf() ->
    supervisor:restart_child(export_sup, bert_rpc_exec).

config_exodm_addr(Opts) ->
    Host = proplists:get_value(exodm_host, Opts, "localhost"),
    Port = proplists:get_value(exodm_port, Opts, 9900),
    application:set_env(exoport, exodm_address, {Host, Port}),
    true.

config_device_id(Opts) ->
    case proplists:get_value(device_id, Opts) of
	undefined ->
	    false;
	ID ->
	    Ck = proplists:get_value(ckey, Opts),
	    Sk = proplists:get_value(skey, Opts),
	    application:set_env(bert, reuse_mode, client),
	    application:set_env(
	      bert, auth, [
			   {id, to_binary(ID)},
			   {client, [
				     {keys, {Ck, Sk}},
				     {mod, bert_challenge}
				    ]}
			  ]),
	    true
    end.

to_binary(B) when is_binary(B) ->
    B;
to_binary(L) when is_list(L) ->
    list_to_binary(L).
