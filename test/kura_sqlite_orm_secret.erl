-module(kura_sqlite_orm_secret).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, redact/0]).

table() -> ~"secrets".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = label, type = string},
        #kura_field{name = pin, type = string},
        #kura_field{name = raw, type = binary, column = ~"raw_bytes"},
        #kura_field{name = token, type = {encrypted, string}},
        #kura_field{name = ssn, type = {encrypted, string, #{mode => deterministic}}}
    ].

redact() -> [pin].
