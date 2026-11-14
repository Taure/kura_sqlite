-module(kura_sqlite_orm_address).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"_embedded".

fields() ->
    [
        #kura_field{name = street, type = string},
        #kura_field{name = city, type = string}
    ].
