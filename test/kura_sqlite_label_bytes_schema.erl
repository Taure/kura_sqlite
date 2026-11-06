-module(kura_sqlite_label_bytes_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"labels".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = label, type = binary}
    ].
