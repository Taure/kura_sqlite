-module(kura_sqlite_vector_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"vector_items".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = content, type = text},
        #kura_field{name = embedding, type = {vector, 3}}
    ].
