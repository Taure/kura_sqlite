-module(kura_sqlite_lookup_schema).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, encrypted/2]).

table() -> ~"lookups".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = name, type = string},
        #kura_field{name = token, type = encrypted(string, #{mode => deterministic})},
        #kura_field{name = 'code?', type = encrypted(binary, #{mode => deterministic})},
        #kura_field{name = tags, type = {array, {encrypted, string}}},
        #kura_field{name = secret, type = encrypted(string, #{mode => deterministic})}
    ].

%% {encrypted, Inner, Opts} is not a kura_types:kura_type() before kura#219.
-spec encrypted(kura_types:kura_type(), term()) -> dynamic().
encrypted(Inner, Opts) ->
    {encrypted, Inner, Opts}.
