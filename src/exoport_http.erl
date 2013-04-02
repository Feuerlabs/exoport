-module(exoport_http).

-compile(export_all).

%% -include_lib("lager/include/log.hrl").
-define(debug(Fmt, As), io:fwrite("~p: " ++ Fmt, [?MODULE|As])).

-record(conf, {gconf, sconf}).

instance() ->
    case application:get_env(yaws_http) of
	{ok, Opts} ->
	    Gconf = gconf(Opts),
	    Sconf = sconf(Opts),
	    {_, Id} = lists:keyfind(id, 1, Gconf),
	    {_, LogDir} = lists:keyfind(log_dir, 1, Gconf),
	    {_, DocRoot} = lists:keyfind(docroot, 1, Gconf),
	    setup:verify_dir(LogDir),
	    setup:verify_dir(DocRoot),
            {ok, SC, GC, ChildSpecs} =
                yaws_api:embedded_start_conf(DocRoot, Sconf, Gconf, Id),
            ?debug("Yaws:~n"
                   "  SC = ~p~n"
                   "  GC = ~p~n"
                   "  ChildSpecs = ~p~n", [SC, GC, ChildSpecs]),
            exoport_sup:add_children(ChildSpecs),
            yaws_api:setconf(GC, SC);
	undefined ->
	    ok
    end.

yaws_conf(Opts) ->
    #conf{
           gconf = gconf(Opts),
	   sconf = sconf(Opts)
         }.

id() -> "EXOPORT".
docroot() -> filename:join(setup:home(), "www").

opt(K, Opts, Def) ->
    case lists:keyfind(K, 1, Opts) of
	{_, V} -> V;
	false  -> if is_function(Def, 0) -> Def();
		     true -> Def
		  end
    end.

sconf(Opts) ->
    opt(sconf, Opts, fun() -> default_sconf(Opts) end).

gconf(Opts) ->
    opt(gconf, Opts, fun() -> default_gconf(Opts) end).

default_sconf(Opts) ->
    SC0 = [{id, id()},
	   {appmods, [{"", exoport_yaws_appmod}]},
	   {port, 8800},
	   {listen, {127,0,0,1}}
	  ],
    apply_options(Opts, SC0, sconf_opts() -- gconf_opts()).

default_gconf(Opts) ->
    LogDir = opt(logdir, Opts, filename:join(setup:log_dir(), "yaws")),
    Id = opt(id, Opts, id()),
    Docroot = opt(docroot, Opts, docroot()),
    GC0 = [
	   {id, Id},
	   {docroot, Docroot},
	   {log_dir, LogDir},
	   {ebin_dir, [Docroot]},
	   {include_dir, [Docroot]}
	  ],
    apply_options(Opts, GC0, gconf_opts()).


apply_options(Opts, Conf, Valid) ->
    lists:foldl(
      fun({K, _} = Opt, Acc) ->
	      lists:keystore(K, 1, Acc, Opt)
      end, Conf, [O || {K,_} = O <- Opts, lists:member(K, Valid)]).

gconf_opts() ->
    [yaws_dir, trace, flags, logdir, ebin_dir, runmods, keepalive_timeout,
     keepalive_maxuses, max_num_cached_files, max_num_cached_bytes,
     max_size_cached_file, max_connections, process_options,
     large_file_chunk_size, mnesia_dir, log_wrap_size, cache_refresh_secs,
     include_dir, phpexe, yaws, id, enable_soap, soap_srv_mods, ysession_mod,
     acceptor_pool_size, mime_types_info].

sconf_opts() ->
    [port, flags, redirect_map, rhost, rmethod, docroot, xtra_docroots,
     listen, servername, yaws, ets, ssl, authdirs, partial_post_size,
     appmods, expires, errormod_401, errormod_404, errormod_crash,
     arg_rewrite_mod, logger_mod, opaque, start_mod, allowed_scripts,
     tilde_allowed_scripts, index_files, revproxy, soptions, extra_cgi_vars,
     stats, fcgi_app_server, php_handler, shaper, deflate_options,
     mime_types_info, dispatchmod].
