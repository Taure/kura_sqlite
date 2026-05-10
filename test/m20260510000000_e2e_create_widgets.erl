-module(m20260510000000_e2e_create_widgets).
-behaviour(kura_migration).

-include_lib("kura/include/kura.hrl").

-export([up/0, down/0]).

up() ->
    [
        {create_table, ~"widgets", [
            #kura_column{name = id, type = id, primary_key = true, nullable = false},
            #kura_column{name = name, type = string, nullable = false},
            #kura_column{name = active, type = boolean, default = true},
            #kura_column{name = data, type = jsonb}
        ]}
    ].

down() ->
    [{drop_table, ~"widgets"}].
