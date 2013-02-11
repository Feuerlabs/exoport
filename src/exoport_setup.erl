-module(exoport_setup).

-export([start_db/0,
	 create_tables/0,
	 initial_data/0]).

start_db() ->
    kvdb:start().

create_tables() ->
    ok.

initial_data() ->
    ok.
