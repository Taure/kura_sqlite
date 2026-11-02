-module(kura_sqlite_bytes_type).
-behaviour(kura_type).

-export([cast/1, dump/1, load/1, pg_type/0, sqlite_type/0]).

cast(V) -> {ok, V}.
dump(V) -> {ok, V}.
load(V) -> {ok, V}.
pg_type() -> ~"BYTEA".
sqlite_type() -> ~"BLOB".
