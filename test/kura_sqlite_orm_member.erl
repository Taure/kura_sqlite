-module(kura_sqlite_orm_member).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, indexes/0]).

table() -> ~"team members".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = org_id, type = integer},
        #kura_field{name = handle, type = string, column = ~"user handle"},
        #kura_field{name = slug, type = string},
        #kura_field{name = level, type = integer},
        #kura_field{name = author_id, type = integer}
    ].

indexes() ->
    [{[org_id, slug], #{unique => true}}].
