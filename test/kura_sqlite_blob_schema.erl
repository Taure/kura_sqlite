-module(kura_sqlite_blob_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"vault".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = name, type = string},
        #kura_field{name = data, type = binary},
        #kura_field{name = secret, type = {encrypted, string}},
        #kura_field{name = digest, type = {custom, kura_sqlite_bytes_type}},
        #kura_field{name = tag, type = {custom, kura_sqlite_text_type}}
    ].
