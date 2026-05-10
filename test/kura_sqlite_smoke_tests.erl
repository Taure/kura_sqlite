-module(kura_sqlite_smoke_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

smoke_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"DDL emit uses SQLite types", fun ddl_emit_sqlite/0},
            {"INSERT ... ON CONFLICT DO UPDATE", fun on_conflict_upsert/0},
            {"boolean round-trips as 0/1", fun boolean_roundtrip/0},
            {"jsonb stored as TEXT, decoded back to map", fun jsonb_roundtrip/0}
        ]
    end}.

-define(REPO, kura_sqlite_smoke_repo).

setup() ->
    application:set_env(kura, repos, #{?REPO => #{dialect => kura_dialect_sqlite}}),
    application:set_env(kura, dialect, kura_dialect_sqlite),
    Name = kura_sqlite_smoke_pool,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 1}),
    Name.

teardown(Name) ->
    application:unset_env(kura, repos),
    application:unset_env(kura, dialect),
    kura_pool_sqlite:stop_pool(Name).

ddl_emit_sqlite() ->
    SQL = kura_migrator:compile_operation(
        ?REPO,
        {create_table, ~"items", [
            #kura_column{name = id, type = id, primary_key = true, nullable = false},
            #kura_column{name = name, type = string, nullable = false},
            #kura_column{name = active, type = boolean, default = true},
            #kura_column{name = data, type = jsonb}
        ]}
    ),
    ?assert(binary:match(SQL, ~"\"id\" INTEGER PRIMARY KEY NOT NULL") =/= nomatch),
    ?assert(binary:match(SQL, ~"\"name\" TEXT NOT NULL") =/= nomatch),
    ?assert(binary:match(SQL, ~"\"active\" INTEGER DEFAULT 1") =/= nomatch),
    ?assert(binary:match(SQL, ~"\"data\" TEXT") =/= nomatch).

on_conflict_upsert() ->
    Name = kura_sqlite_smoke_pool,
    DDL = kura_migrator:compile_operation(
        ?REPO,
        {create_table, ~"upserts", [
            #kura_column{name = key, type = string, primary_key = true, nullable = false},
            #kura_column{name = count, type = integer, default = 0}
        ]}
    ),
    {ok, Conn, Tk} = kura_pool_sqlite:checkout(Name, #{}),
    try
        ok = esqlite3:exec(Conn, DDL),
        ok = esqlite3:exec(
            Conn,
            ~"INSERT INTO \"upserts\" (key, count) VALUES ('k', 1) ON CONFLICT (key) DO UPDATE SET count = excluded.count + 1"
        ),
        ok = esqlite3:exec(
            Conn,
            ~"INSERT INTO \"upserts\" (key, count) VALUES ('k', 1) ON CONFLICT (key) DO UPDATE SET count = excluded.count + 1"
        ),
        Rows = esqlite3:q(Conn, ~"SELECT count FROM \"upserts\" WHERE key = 'k'", []),
        ?assertEqual([[2]], Rows)
    after
        kura_pool_sqlite:checkin(Name, Tk)
    end.

boolean_roundtrip() ->
    %% SQLite stores booleans as INTEGER 0/1; kura_types:cast handles
    %% the read side. Verify the encoded default and the cast.
    ?assertEqual(~"1", kura_dialect_sqlite:format_default(true)),
    ?assertEqual(~"0", kura_dialect_sqlite:format_default(false)),
    ?assertEqual({ok, true}, kura_types:cast(boolean, 1)),
    ?assertEqual({ok, false}, kura_types:cast(boolean, 0)).

jsonb_roundtrip() ->
    %% jsonb defaults render as text, decode back via kura_types:cast.
    Expected = #{~"a" => 1},
    ?assertEqual(<<"'{\"a\":1}'">>, kura_dialect_sqlite:format_default(#{a => 1})),
    ?assertEqual({ok, Expected}, kura_types:cast(jsonb, ~"{\"a\":1}")).
