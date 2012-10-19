-module(exoport_exodm).

-export([subscribe/1,
	 unsubscribe/0]).
-export([push_config/2]).

-include_lib("kvdb/include/kvdb_conf.hrl").
-define(EVENT(Op, Name), {Op, Name}).


subscribe(all) ->
    gproc_ps:subscribe_cond(?MODULE, [{ ?EVENT('_','_'), [], [true] }]);
subscribe(Pairs) when is_list(Pairs) ->
    Spec = lists:map(fun({Op, Name}) ->
			     [{ ?EVENT(Op, Name), [], [true] }]
		     end, Pairs),
    gproc_ps:subscribe_cond(l, ?MODULE, Spec).

unsubscribe() ->
    gproc_ps:unsubscribe(l, ?MODULE).

publish(Op, Name) ->
    gproc_ps:publish_cond(l, ?MODULE, ?EVENT(Op, Name)).

push_config(Name, Tree) ->
    kvdb_conf:transaction(
      fun(_) ->
	      Tab = kvdb_lib:table_name(Name),
	      case kvdb:info({Tab, type}) of
		  undefined ->
		      kvdb_conf:add_table(Tab, []);
		  set ->
		      ok
	      end,
	      kvdb_conf:write_tree(Name, Tree)
      end),
    publish(push_config, Name).
