-module(kura_sqlite_orm_list).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"lists".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = name, type = string},
        #kura_field{name = nicknames, type = {array, string}},
        #kura_field{name = scores, type = {array, integer}}
    ].
