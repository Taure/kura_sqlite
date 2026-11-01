-module(kura_sqlite_owner_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"owners".

fields() ->
    [
        #kura_field{name = owner_id, type = id, primary_key = true, nullable = false},
        #kura_field{name = label, type = string}
    ].
