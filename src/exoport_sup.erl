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

-include_lib("bert/src/bert.hrl").

%% API
-export([start_link/1,
        stop/1]).

%% Supervisor callbacks
-export([init/1]).

-define(ACCESS_FILE,"rpc_access.conf").


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
init(Args) ->
    error_logger:info_msg("~p: init: args = ~p,\n pid = ~p\n",
                          [?MODULE, Args, self()]),
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
    I = bert_rpc_exec,
    BertRpc = {I, {I, start_link, [NewOpts]}, permanent, 5000, worker, [I]},
 
    error_logger:info_msg("~p: About to start ~p\n", [?MODULE,BertRpc]),
    {ok, { {one_for_one, 5, 10}, [BertRpc]} }.


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
