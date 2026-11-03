-module(kura_sqlite_smoke_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

smoke_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"DDL emit uses SQLite types", fun ddl_emit_sqlite/0},
            {"INSERT ... ON CONFLICT DO UPDATE", fun on_conflict_upsert/0},
            {"boolean round-trips as 0/1", fun boolean_roundtrip/0},
            {"jsonb stored as TEXT, decoded back to map", fun jsonb_roundtrip/0},
            {"encrypted column emits BLOB", fun encrypted_ddl_blob/0},
            {"encrypted value round-trips through a BLOB column", fun encrypted_roundtrip/0},
            {"NULL encrypted value reads back as undefined", fun encrypted_null_reads_undefined/0},
            {"bulk writes report the rows they changed", fun bulk_writes_report_rows_changed/0},
            {"aggregate over no rows is null", fun aggregate_over_no_rows_is_null/0},
            {"boolean and date values are stored as SQLite stores them",
                fun boolean_and_date_storage/0},
            {"a boolean filter matches by 1/0 or true/false", fun boolean_filters/0},
            {"a date or datetime filter matches the stored text", fun date_filters/0},
            {"the 1.1 boolean repair turns stored 'true'/'false' into 1/0",
                fun boolean_text_repair/0}
        ]
    end}.

-define(REPO, kura_sqlite_smoke_repo).

setup() ->
    {ok, _} = application:ensure_all_started(crypto),
    application:set_env(kura, repos, #{
        ?REPO => #{
            dialect => kura_dialect_sqlite,
            pool => kura_sqlite_smoke_pool,
            pool_module => kura_pool_sqlite,
            driver_module => kura_driver_sqlite
        }
    }),
    application:set_env(kura, dialect, kura_dialect_sqlite),
    application:set_env(kura, encryption, #{
        active => 1, keys => [{1, base64:encode(crypto:strong_rand_bytes(32))}]
    }),
    Name = kura_sqlite_smoke_pool,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 1}),
    Name.

teardown(Name) ->
    application:unset_env(kura, repos),
    application:unset_env(kura, dialect),
    application:unset_env(kura, encryption),
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

encrypted_ddl_blob() ->
    ?assertEqual(
        kura_dialect_sqlite:column_type(binary),
        kura_dialect_sqlite:column_type({encrypted, string})
    ),
    SQL = kura_migrator:compile_operation(
        ?REPO,
        {create_table, ~"vault", [
            #kura_column{name = id, type = id, primary_key = true, nullable = false},
            #kura_column{name = secret, type = {encrypted, string}}
        ]}
    ),
    ?assert(binary:match(SQL, ~"\"secret\" BLOB") =/= nomatch).

encrypted_roundtrip() ->
    %% Cipher is framed nonce/tag/ciphertext; a BLOB column must preserve it
    %% byte-for-byte through the driver's bind/step path so decrypt succeeds.
    Name = kura_sqlite_smoke_pool,
    Plain = ~"pii@example.com",
    {ok, Cipher} = kura_types:dump({encrypted, string}, Plain),
    ?assert(is_binary(Cipher)),
    ?assertNotEqual(Plain, Cipher),
    DDL = kura_migrator:compile_operation(
        ?REPO,
        {create_table, ~"vault2", [
            #kura_column{name = id, type = id, primary_key = true, nullable = false},
            #kura_column{name = secret, type = {encrypted, string}}
        ]}
    ),
    {ok, Conn, Tk} = kura_pool_sqlite:checkout(Name, #{}),
    try
        ok = esqlite3:exec(Conn, DDL),
        #{num_rows := 1} = kura_driver_sqlite:query_on(
            Conn, ~"INSERT INTO \"vault2\" (secret) VALUES (?1)", [Cipher], #{}
        ),
        #{rows := [#{secret := Stored}]} = kura_driver_sqlite:query_on(
            Conn, ~"SELECT secret FROM \"vault2\"", [], #{}
        ),
        ?assertEqual(Cipher, Stored),
        ?assertEqual({ok, Plain}, kura_types:load({encrypted, string}, Stored))
    after
        kura_pool_sqlite:checkin(Name, Tk)
    end.

encrypted_null_reads_undefined() ->
    ok = vault_table(),
    {ok, 2} = kura_repo_worker:insert_all(?REPO, kura_sqlite_vault_schema, [
        #{secret => ~"kept", note => ~"a"},
        #{secret => undefined, note => undefined}
    ]),
    Rows = kura_repo_worker:all(
        ?REPO, kura_query:order_by(kura_query:from(kura_sqlite_vault_schema), [{id, asc}])
    ),
    ?assertMatch(
        {ok, [
            #{secret := ~"kept", note := ~"a"},
            #{secret := undefined, note := undefined}
        ]},
        Rows
    ).

bulk_writes_report_rows_changed() ->
    ok = vault_table(),
    Entries = [#{note => N} || N <- [~"a", ~"b", ~"c"]],
    ?assertEqual({ok, 3}, kura_repo_worker:insert_all(?REPO, kura_sqlite_vault_schema, Entries)),
    Vault = kura_query:from(kura_sqlite_vault_schema),
    ?assertEqual(
        {ok, 2},
        kura_repo_worker:update_all(
            ?REPO, kura_query:where(Vault, {note, in, [~"a", ~"b"]}), #{note => ~"z"}
        )
    ),
    ?assertEqual(
        {ok, 0},
        kura_repo_worker:update_all(?REPO, kura_query:where(Vault, {note, ~"none"}), #{
            note => ~"y"
        })
    ),
    ?assertEqual(
        {ok, 2}, kura_repo_worker:delete_all(?REPO, kura_query:where(Vault, {note, ~"z"}))
    ),
    ?assertEqual({ok, 1}, kura_repo_worker:delete_all(?REPO, Vault)),
    ?assertEqual({ok, 0}, kura_repo_worker:delete_all(?REPO, Vault)).

vault_table() ->
    DDL = kura_migrator:compile_operation(
        ?REPO,
        {create_table, ~"vault_rows", [
            #kura_column{name = id, type = id, primary_key = true, nullable = false},
            #kura_column{name = secret, type = {encrypted, string}},
            #kura_column{name = note, type = string}
        ]}
    ),
    #{} = kura_db:query(?REPO, ~"DROP TABLE IF EXISTS vault_rows", []),
    #{} = kura_db:query(?REPO, DDL, []),
    ok.

aggregate_over_no_rows_is_null() ->
    ok = vault_table(),
    Vault = kura_query:from(kura_sqlite_vault_schema),
    ?assertEqual({ok, null}, kura_repo_worker:aggregate(?REPO, Vault, {sum, id})),
    ?assertEqual({ok, null}, kura_repo_worker:aggregate(?REPO, Vault, {max, id})),
    ?assertEqual({ok, null}, kura_repo_worker:aggregate(?REPO, Vault, {min, id})),
    ?assertEqual({ok, null}, kura_repo_worker:aggregate(?REPO, Vault, {avg, id})),
    ?assertEqual({ok, 0}, kura_repo_worker:aggregate(?REPO, Vault, {sum, id}, 0)),
    ?assertEqual({ok, 0}, kura_repo_worker:count(?REPO, Vault)).

flag_table() ->
    DDL = kura_migrator:compile_operation(
        ?REPO,
        {create_table, ~"flags", [
            #kura_column{name = id, type = id, primary_key = true, nullable = false},
            #kura_column{name = active, type = boolean},
            #kura_column{name = day, type = date},
            #kura_column{name = at, type = utc_datetime}
        ]}
    ),
    #{} = kura_db:query(?REPO, ~"DROP TABLE IF EXISTS flags", []),
    #{} = kura_db:query(?REPO, DDL, []),
    {ok, 2} = kura_repo_worker:insert_all(?REPO, kura_sqlite_flag_schema, [
        #{active => true, day => {2024, 1, 2}, at => {{2024, 1, 2}, {1, 0, 0}}},
        #{active => false, day => {2024, 1, 3}, at => {{2024, 1, 3}, {1, 0, 0}}}
    ]),
    ok.

flag_ids(Condition) ->
    Q = kura_query:where(kura_query:from(kura_sqlite_flag_schema), Condition),
    {ok, Rows} = kura_repo_worker:all(?REPO, kura_query:select(Q, [id])),
    lists:sort([Id || #{id := Id} <- Rows]).

boolean_and_date_storage() ->
    ok = flag_table(),
    ?assertMatch(
        {ok, [
            #{active := 1, day := ~"2024-01-02", at := ~"2024-01-02 01:00:00"},
            #{active := 0, day := ~"2024-01-03", at := ~"2024-01-03 01:00:00"}
        ]},
        kura_repo_worker:query(?REPO, ~"SELECT active, day, at FROM flags ORDER BY id", [])
    ).

boolean_filters() ->
    ok = flag_table(),
    Cases = [
        {{active, true}, [1]},
        {{active, ~"1"}, [1]},
        {{active, false}, [2]},
        {{active, '=', true}, [1]},
        {{active, '!=', ~"1"}, [2]},
        {{active, '!=', true}, [2]},
        {{active, not_in, [~"1"]}, [2]},
        {{active, not_in, [true]}, [2]},
        {{active, in, [true]}, [1]},
        {{'not', {active, ~"1"}}, [2]},
        {{'not', {active, true}}, [2]}
    ],
    [?assertEqual({C, Ids}, {C, flag_ids(C)}) || {C, Ids} <- Cases].

date_filters() ->
    ok = flag_table(),
    Cases = [
        {{day, {2024, 1, 2}}, [1]},
        {{day, ~"2024-01-02"}, [1]},
        {{day, '>', {2024, 1, 2}}, [2]},
        {{day, between, {{2024, 1, 1}, {2024, 1, 3}}}, [1, 2]},
        {{day, in, [{2024, 1, 3}]}, [2]},
        {{at, {{2024, 1, 2}, {1, 0, 0}}}, [1]},
        {{at, '>=', {{2024, 1, 2}, {1, 0, 1}}}, [2]}
    ],
    [?assertEqual({C, Ids}, {C, flag_ids(C)}) || {C, Ids} <- Cases].

%% kura_sqlite 1.1 bound true and false as the text 'true' and 'false', which
%% an INTEGER column keeps as TEXT. The README's upgrade note gives this repair.
boolean_text_repair() ->
    ok = flag_table(),
    {ok, _} = kura_repo_worker:query(
        ?REPO, ~"INSERT INTO flags (id, active) VALUES (3, 'true'), (4, 'false')", []
    ),
    ?assertEqual([1], flag_ids({active, true})),
    {ok, _} = kura_repo_worker:query(
        ?REPO,
        ~"UPDATE \"flags\" SET \"active\" = (\"active\" = 'true') WHERE typeof(\"active\") = 'text'",
        []
    ),
    ?assertMatch(
        {ok, [
            #{id := 1, active := 1, t := ~"integer"},
            #{id := 2, active := 0, t := ~"integer"},
            #{id := 3, active := 1, t := ~"integer"},
            #{id := 4, active := 0, t := ~"integer"}
        ]},
        kura_repo_worker:query(
            ?REPO, ~"SELECT id, active, typeof(active) AS t FROM flags ORDER BY id", []
        )
    ),
    ?assertEqual([1, 3], flag_ids({active, true})),
    ?assertEqual([2, 4], flag_ids({active, false})).
