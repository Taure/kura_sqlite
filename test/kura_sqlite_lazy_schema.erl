-module(kura_sqlite_lazy_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"vault".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = digest, type = {custom, kura_sqlite_bytes_type}}
    ].
