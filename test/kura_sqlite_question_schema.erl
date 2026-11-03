-module(kura_sqlite_question_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"questions".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = 'secret?', type = {encrypted, string}},
        #kura_field{name = 'data?', type = binary}
    ].
