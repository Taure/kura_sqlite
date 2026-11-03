-module(kura_sqlite_plain_secret_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"plain_rows".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = owner_id, type = integer},
        #kura_field{name = secret, type = string},
        #kura_field{name = token, type = {encrypted, string}}
    ].
