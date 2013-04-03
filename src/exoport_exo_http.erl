-module(exoport_exo_http).
-export([instance/1,
	 handle_body/4,
	 json_rpc/1,
	 json_rpc/2]).

-include_lib("exo/include/exo_http.hrl").
-include_lib("lager/include/log.hrl").


instance(Opts) ->
    Port = opt(port, Opts, 8800),
    Args = case opt(appmod, Opts, ?MODULE) of
	       AppMod when is_atom(AppMod) -> [AppMod];
	       {App, St} -> [{App, St}]
	   end,
    Child = {exo_http, {exo_http_server, start_link,
			[Port, [{request_handler,
				 {?MODULE, handle_body, Args}}]]},
	     permanent, 5000, worker, [exo_http_server]},
    exoport_sup:add_children([Child]).

handle_body(Socket, Request, Body, AppMod) ->
    Url = Request#http_request.uri,
    io:fwrite("Request Url = ~p~nBody = ~p~n", [Url, Body]),
    if Request#http_request.method == 'POST' ->
	    try decode_json(Body) of
		{call, Id, _Method, _Args} = Call ->
		    case call_appmod(AppMod, json_rpc, Call) of
			{ok, Reply} ->
			    success_response(Socket, Id, Reply);
			ok ->
			    ok;
			{error, Error} ->
			    error_response(Socket, Id, Error)
		    end;
		{notification, _Method, _Args} = Notif ->
		    call_appmod(AppMod, json_rpc, Notif),
		    exo_http_server:response(Socket, undefined, 200, "OK", "");
		{error, _} ->
		    error_response(Socket, parse_error)
	    catch
		error:_ ->
		    exo_http_server:response(Socket, undefined, 501,
					     "Internal Error",
					     "Internal Error")
	    end;
       true ->
	    exo_http_server:response(Socket, undefined, 404, "Not Found",
				     "Object not found")
    end.

call_appmod({AppMod, St}, Fun, Body) ->
    AppMod:Fun(Body, St);
call_appmod(AppMod, Fun, Body) when is_atom(AppMod) ->
    try AppMod:Fun(Body)
    catch
	error:R ->
	    io:fwrite("call_appmod(~p, ~p, ~p) crashed: ~p~n"
		      "Trace = ~p~n", [AppMod, Fun, Body, R,
				       erlang:get_stacktrace()]),
	    {error, internal_error}
    end.

%% Validated RPC
handle_rpc(CB, Mod, Method, Args, Meta) ->
    case CB of
	[] ->
	    io:fwrite("Validated RPC: ~s:~s(~p, ~p)~n",
		      [Mod, Method, Args, Meta]),
	    {ok, "ok"};
	_ ->
	    try call_cb_rpc(CB, Mod, Method, Args, Meta) of
		{ok, Result} ->
		    case validate_rpc_result(Result, Mod, Method) of
			{ok, JSON} ->
			    {ok, JSON};
			{error, Reason} ->
			    {error, Reason}
		    end;
		{error, _} = CallErr ->
		    CallErr
	    catch
		error:Crash ->
		    ?error("rpc callback CRASH: ~p~n~p~n",
			   [Crash, erlang:get_stacktrace()]),
		    {error, internal_error}
	    end
    end.

call_cb_rpc(CBMod, Mod, Method, Args, Meta) when is_atom(CBMod) ->
    CBMod:handle_rpc(Mod, Method, Args, Meta);
call_cb_rpc({CBMod, St}, Mod, Method, Args, Meta) ->
    CBMod:handle_rpc(Mod, Method, Args, Meta, St).


json_rpc(Req) ->
    json_rpc(Req, []).

json_rpc({call, _Id, Method, {struct, Args}}, CB) ->
    case re:split(Method, ":", [{return, list}]) of
	[ModS, FunS] ->
	    try Mod = list_to_existing_atom("yang_spec_" ++ ModS),
		 case Mod:rpc(list_to_binary(FunS)) of
		     error ->
			 {error, method_not_found};
		     {rpc, _, _, Data} ->
			 {input,_,_,InputElems} = lists:keyfind(input,1,Data),
			 try yang_json:validate_rpc_request(
			       InputElems, Args) of
			     {ok, Elems, Meta} ->
				 handle_rpc(CB, list_to_binary(ModS),
					    list_to_binary(FunS),
					    Elems, Meta);
			     {error, _Reason} ->
				 {error, parse_error}
			 catch
			     error:E ->
				 io:fwrite("Validation crash~n"
					   "error:~p, ~p~n",
					   [E, erlang:get_stacktrace()]),
				 {error, invalid_request}
			 end
		 end
	    catch
		error:_ ->
		    {error, method_not_found}
	    end;
	_ ->
	    {error, method_not_found}
    end.

validate_rpc_result(Result, Mod, Method) ->
    ErlMod = list_to_existing_atom("yang_spec_" ++ binary_to_list(Mod)),
    case ErlMod:rpc(Method) of
	{rpc, _, _, Data} ->
	    %% This really should be FIXed; output is not mandatory
	    {output, _, _, Elems} = lists:keyfind(output, 1, Data),
	    JSON = data_to_json(Elems, [], Result),
	    {ok, {struct, JSON}};
	error ->
	    {error, method_not_found}
    end.

success_response(Socket, Id, Reply) ->
    JSON = {struct, [{"jsonrpc", "2.0"},
		     {"id", Id},
		     {"result", Reply}]},
    exo_http_server:response(Socket, undefined, 200, "OK",
			     exo_json:encode(JSON),
			     [{content_type, "application/json"}]).

error_response(Socket, Error) ->
    %% No Id available
    JSON = {struct, [{"jsonrpc", "2.0"},
		     {"error", {struct,
				[{"code", json_error_code(Error)},
				 {"message", json_error_msg(Error)}]}}]},
    Body = list_to_binary(exo_json:encode(JSON)),
    exo_http_server:response(Socket, undefined, 200, "OK", Body,
			     [{content_type, "application/json"}]).

error_response(Socket, Id, Error) ->
    JSON = {struct, [{"jsonrpc", "2.0"},
		     {"id", Id},
		     {"error", {struct,
				[{"code", json_error_code(Error)},
				 {"message", json_error_msg(Error)}]}}]},
    Body = list_to_binary(exo_json:encode(JSON)),
    exo_http_server:response(Socket, undefined, 200, "OK", Body,
			     [{content_type, "application/json"}]).

decode_json(Body) ->
    try exo_json:decode_string(binary_to_list(Body)) of
	{ok, {struct,Elems}} ->
	    case [opt(K,Elems,undefined) || K <- ["jsonrpc","id",
						  "method", "params"]] of
		["2.0",undefined,Method,Params]
		  when Method =/= undefined,
		       Params =/= undefined ->
		    {notification, Method, Params};
		["2.0",Id,Method,Params]
		  when Id=/=undefined,
		       Method=/=undefined,
		       Params =/= undefined ->
		    {call, Id, Method, Params};
		_ ->
		    {error, invalid}
	    end
    catch
	error:_ ->
	    {error, parse_error}
    end.

json_error_code(parse_error     )  -> -32700;
json_error_code(invalid_request )  -> -32600;
json_error_code(method_not_found)  -> -32601;
json_error_code(invalid_params  )  -> -32602;
json_error_code(internal_error  )  -> -32603;
json_error_code(_) -> -32603. % internal error


json_error_msg(-32700) -> "parse error";
json_error_msg(-32600) -> "invalid request";
json_error_msg(-32601) -> "method not found";
json_error_msg(-32602) -> "invalid params";
json_error_msg(-32603) -> "internal error";
json_error_msg(Code) when Code >= -32099, Code =< -32000 -> "server error";
json_error_msg(_) -> "json error".

opt(K, L, Def) ->
    case lists:keyfind(K, 1, L) of
	{_, V} -> V;
	false  -> Def
    end.


%%
data_to_json(Elems, Env, Data) ->
    ?debug("data_to_json(~p, ~p, ~p)~n", [Elems, Env, Data]),
    case find_leaf(<<"rpc-status-string">>, Elems) of
        false ->
            yang_json:data_to_json(Elems, Env, Data);
        _Leaf ->
            case keyfind(<<"rpc-status-string">>, Data) of
                false ->
                    case keyfind(<<"rpc-status">>, Data) of
                        false ->
                            yang_json:data_to_json(Elems, Env, Data);
                        Status ->
                            case enum_descr(find_leaf(<<"rpc-status">>, Elems),
                                            to_binary(element(2, Status))) of
                                false ->
                                    yang_json:data_to_json(Elems, Env, Data);
                                Descr ->
                                    yang_json:data_to_json(
                                      Elems, Env,
                                      [{<<"rpc-status-string">>, Descr}|Data])
                            end
                    end;
                _ ->
                    yang_json:data_to_json(Elems, Env, Data)
            end
    end.

enum_descr(false, _) -> false;
enum_descr({leaf, _, _, I}, V) ->
    case lists:keyfind(type, 1, I) of
        {_, _, <<"enumeration">>, I1} ->
            enum_descr_(I1, V);
        _ ->
            false
    end.

%% Assume rpc-status can be either the numeric value or the description.
enum_descr_([{enum,_,V,I}|_], V) ->
    case lists:keyfind(description,1,I) of
        {_, _, Descr, _} -> Descr;
        false -> V
    end;
enum_descr_([{enum,_,D,I}|T], V) ->
    case lists:keyfind(value, 1, I) of
        {_, _, V, _} ->
            case lists:keyfind(description,1,I) of
                {_, _, Descr, _} -> Descr;
                false -> D
            end;
        _ ->
            enum_descr_(T, V)
    end;
enum_descr_([_|T], V) ->
    enum_descr_(T, V);
enum_descr_([], _) ->
    false.



find_leaf(K, [{leaf,_,K,_} = L|_]) -> L;
find_leaf(K, [_|T]) -> find_leaf(K, T);
find_leaf(_, []) -> false.

keyfind(A, [H|T]) when is_tuple(H) ->
    K = element(1, H),
    case comp(A,K) of
        true ->
            H;
        false ->
            keyfind(A, T)
    end;
keyfind(_, []) ->
    false.

comp(A, A) -> true;
comp(A, B) when is_binary(A), is_list(B) ->
    binary_to_list(A) == B;
comp(A, B) when is_binary(A), is_atom(B) ->
    A == atom_to_binary(B, latin1);
comp(_, _) ->
    false.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).
