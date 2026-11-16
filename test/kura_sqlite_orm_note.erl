-module(kura_sqlite_orm_note).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"notes".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = org_id, type = integer, nullable = false},
        #kura_field{name = body, type = string}
    ].
