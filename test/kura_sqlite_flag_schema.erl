-module(kura_sqlite_flag_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"flags".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = active, type = boolean},
        #kura_field{name = day, type = date},
        #kura_field{name = at, type = utc_datetime}
    ].
