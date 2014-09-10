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
-include("exoport.hrl").

-export([start/0, 
	 start/1, 
	 start/2,
	 start_rpc_server/0]).

-export([rpc_auth_options/0,
	 access/0]).

-export([ping/0,
	 rpc/3,
	 notify/3,
	 disconnect/0,
	 configure/1, configure/2,
	 reload_conf/0]).

-export([get_env_var/2]).

-include_lib("bert/include/bert.hrl").
-include("log.hrl").

-define(ACCESS_FILE,"rpc_access.conf").

-define(ENV_VAR_PREFIX,"EXO_").

%% helper when starting from command line
start() ->
    start([]).

start(Opts) ->
    application:load(exoport),
    Apps = 
	case {application:get_env(exoport, gsms),
	      application:get_env(exoport, ppp_provider)} of
	    {{ok, true}, {ok, _Provider}} ->
		[crypto, asn1, public_key, exo, bert, gproc, kvdb,
		 uart, gsms, netlink, pppd_mgr, exoport];
	    {{ok, true}, _} -> 
		[crypto, asn1, public_key, exo, bert, gproc, kvdb,
		 uart, gsms, exoport];
	    _ -> 
		[crypto, asn1, public_key, exo, bert, gproc, kvdb, exoport]
	end,
    ?dbg("apps needed ~p.\n", [Apps]),
    start(Opts, Apps).
    

start(Opts, Apps) ->
    [application:load(A) || A <- Apps],
    lists:foreach(fun({config, Cfg}) ->
			  configure(Cfg, false);
		     ({K, V}) ->
			  application:set_env(exoport, K, V);
		     ({A, K, V}) ->
			  case lists:member(A, Apps) of
			      true -> application:set_env(A, K, V);
			      false ->
				  erlang:error({not_allowed, [set_env, {A,K,V}]})
			  end
		  end, Opts),
    [started(application:start(A),A) || A <- Apps],
    ok.

started(ok, A) ->
    ?dbg("Starting app ~p.\n", [A]),
    ok;
started({error, {already_started,_}},_) ->
    ok;
started(Other, A) ->
    ?ee("Failed starting app ~p, reason ~p.\n", [A, Other]),
    erlang:error({Other, [{application, A}]}).



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
    lager:debug("rpc: M = ~p, F = ~p, A = ~p.", [M, F, A]),
    exoport_server:rpc(M, F, A).
%% rpc(M, F, A) ->
%%     case application:get_env(exoport, exodm_address) of
%% 	{ok, {Host, Port}} ->
%% 	    nice_bert_rpc:call_host(Host, Port, [tcp], M, F, A);
%% 	_ ->
%% 	    {error, no_address}
%%     end.

notify(Module, Method, Info) ->
    RPC = {exodm_rpc, notification, [Module, Method, Info]},
    exoport_rpc:queue_rpc(RPC, {exoport_rpc, log_notify_result}).

disconnect() ->
    exoport_server:disconnect().


configure(FileOrOpts) ->
    configure(FileOrOpts, _Reload = true).

configure(FileOrOpts, Reload) when is_boolean(Reload) ->
    io:fwrite("configure(~p, ~p)~n", [FileOrOpts, Reload]),
    EnvTerms = get_env_var("EXO_", os:getenv()),
    io:fwrite("environ(~p)~n", [EnvTerms]),
    case consult_config(FileOrOpts) of
	{ok, CfgTerms} ->
	    Terms = lists:keymerge(1, CfgTerms, EnvTerms),
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

%% If the environment variable in Var starts with MatchPrefix, return
%% a new key-val element with the extracted variable and recursively
%% call self with T.
%% Each element added to the list will be stripped of its prefix and
%% converted to lowercase
get_env_var(MatchPrefix, [ Var | T]) ->
    EqInd = string:chr(Var, $=),
    PrefixLen = string:len(MatchPrefix),
    case string:equal(string:to_lower(string:substr(Var, 1, PrefixLen)), string:to_lower(MatchPrefix)) of
	true ->
	    [ { list_to_atom(string:to_lower(string:substr(Var, PrefixLen + 1, EqInd - PrefixLen - 1))),
		string:substr(Var, EqInd + 1) } ] ++ get_env_var(MatchPrefix, T);
	_ -> get_env_var(MatchPrefix, T)
    end;

get_env_var(_MatchPrefix, []) ->
    [].


consult_config(environment) ->
    {ok, []};
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
    case application:get_env(exoport, exodm_address) of
	undefined ->
	    Host = alt_opt([exodm_host, host, exo_host], Opts, "localhost"),
	    Port = alt_opt([exodm_port, port, exo_port], Opts, 9900),
	    application:set_env(exoport, exodm_address, {Host, Port});
	{ok, {_Host, Port}} when is_integer(Port) ->
	    ok %% do not touch sys.config
    end.

config_device_id(Opts) ->
    DeviceID = alt_opt([device_id, 'device-id'], Opts, undefined),
    Account = alt_opt([account], Opts, undefined),
    DeviceKey = alt_opt([ckey, 'client-key', 'device-key', 'device_key', 'client_key'], Opts, undefined),
    ServerKey = alt_opt([skey, 'server-key', 'server_key'], Opts, undefined),

    io:format("DeviceID(~p)~n", [DeviceID]),
    io:format("Account(~p)~n", [Account]),
    io:format("DeviceKey(~p)~n", [DeviceKey]),
    io:format("ServerKey(~p)~n", [ServerKey]),

    if
	DeviceID =:= undefined -> false;
	Account =:= undefined -> false;
	DeviceKey =:= undefined -> false;
	ServerKey =:= undefined -> false;
	true ->
	    InternalDeviceID = enc_device_key(Account, DeviceID),
	    %% InternalDeviceID = to_binary("*" ++ Account ++ "*" ++ DeviceID),
	    application:set_env(bert, reuse_mode, client),
	    application:set_env(
	      bert, auth, [
			   {id, InternalDeviceID},
			   {client, [
                                     {id, InternalDeviceID},
				     {keys, {uint64(DeviceKey), uint64(ServerKey)}},
				     {mod, bert_challenge}
				    ]}
			  ]),
	    true
    end.

enc_device_key(AName0, ID0) ->
    AName = to_binary(AName0),
    ID = to_binary(ID0),
    Del = pick_delimiter(<<AName/binary, ID/binary>>),
    <<Del, AName/binary, Del, ID/binary>>.

pick_delimiter(Bin) ->
    Dels = delimiters(),
    S = binary_to_list(Bin),
    case lists:dropwhile(fun(D) -> lists:member(D, S) end, Dels) of
    %% case [D || D <- Dels, not lists:member(D, S)] of
	[D|_] ->
	    D;
	[] ->
	    erlang:error(cannot_pick_delimiter)
    end.

delimiters() ->
    "*=#_-/&+!%^:;.,()[]{}'`<>\\\$".



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
    ?ei("~p: start_rpc_server: pid = ~p", [?MODULE, self()]),
    case application:get_env(exoport, config) of
	{ok, Cfg} ->
	    io:fwrite("Preset exoport config: ~p~n", [Cfg]),
	    configure(Cfg, false);
	undefined ->
	    io:fwrite("No exoport config file given. Will use environment", []),
	    configure(environment, false)
    end,
    Args = rpc_server_args(),
    ?ei("~p: About to start bert_rpc_exec. ~nArgs = ~p~n", [?MODULE, Args]),
    bert_rpc_exec:start_link(Args).

rpc_server_args() ->
    {ok, Access} = access(),
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
    [{access, Access}, 
     {port, BertPort},
     {exo, [{reuse_mode, BertReuse},
	    {auth, BertAuth}]}].


%%--------------------------------------------------------------------
%% @doc
%% Returns the access rights for exoport.
%% @end
%%--------------------------------------------------------------------
-spec access() -> {ok, term()}.
		    
access() ->
    case application:get_env(exoport, access) of
        {ok, {file, F}} ->
            access(F);
        undefined ->
            access(?ACCESS_FILE);
        {ok, []} ->
            {ok, []};
        {ok, [_|_] = Access} when is_tuple(hd(Access)) ->
            {ok, Access}
    end.


access(FileName) ->
    Dir = code:priv_dir(exoport),
    File = filename:join(Dir, FileName),
    case filelib:is_regular(File) of
	true ->
            file:consult(File);
	false ->
            ?ee("~p: access: File ~p not found.", [?MODULE, File]),
            {ok, []}
    end.

opt_env(K, Default) ->
    case application:get_env(bert, K) of
        {ok, Val} ->
            Val;
        undefined ->
            Default
    end.

alt_opt([H|T], Opts, Default) ->
    case lists:keyfind(H, 1, Opts) of
	{_, Val} ->
	    Val;
	false ->
	    alt_opt(T, Opts, Default)
    end;
alt_opt([], _, Default) ->
    Default.

