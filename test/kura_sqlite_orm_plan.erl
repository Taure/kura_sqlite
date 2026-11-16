-module(kura_sqlite_orm_plan).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, tenant_scoped/0]).

table() -> ~"plans".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = name, type = string}
    ].

tenant_scoped() -> false.
