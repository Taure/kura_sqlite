-module(kura_sqlite_blob_SUITE).
-moduledoc """
Values of byte-typed fields (`binary`, `{encrypted, _}`) are stored with
the BLOB storage class and found again by queries that bind them, while
text fields stay TEXT (Taure/kura#141).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    insert_stores_byte_fields_as_blob/1,
    equality_on_a_blob_column_matches/1,
    comparisons_on_a_blob_column_match/1,
    update_stores_blob/1,
    update_all_stores_blob_and_matches/1,
    insert_all_stores_blob/1,
    delete_all_matches_a_blob/1,
    text_rows_converted_with_cast_match/1,
    first_query_on_an_unloaded_custom_type_casts/1,
    unique_text_and_blob_duplicate_is_found_and_resolved/1,
    exclusion_on_a_joined_blob_column_matches/1
]).

-define(REPO, kura_sqlite_blob_test_repo).
-define(SCHEMA, kura_sqlite_blob_schema).
-define(CONVERT, ~"UPDATE vault SET data = CAST(data AS BLOB) WHERE typeof(data) = 'text'").
-define(BYTES, <<0, 255, 254, 128, $a, 0, 192, 193>>).

all() ->
    [
        insert_stores_byte_fields_as_blob,
        equality_on_a_blob_column_matches,
        comparisons_on_a_blob_column_match,
        update_stores_blob,
        update_all_stores_blob_and_matches,
        insert_all_stores_blob,
        delete_all_matches_a_blob,
        text_rows_converted_with_cast_match,
        first_query_on_an_unloaded_custom_type_casts,
        unique_text_and_blob_duplicate_is_found_and_resolved,
        exclusion_on_a_joined_blob_column_matches
    ].

init_per_suite(Config) ->
    {module, _} = code:ensure_loaded(kura_backend_sqlite),
    application:set_env(kura, repos, #{
        ?REPO => #{backend => kura_backend_sqlite, database => <<":memory:">>, pool_size => 1}
    }),
    application:set_env(kura, ensure_database, false),
    application:set_env(kura, encryption, #{
        active => 1, keys => [{1, base64:encode(crypto:strong_rand_bytes(32))}]
    }),
    {ok, _} = application:ensure_all_started(kura),
    Config.

end_per_suite(_Config) ->
    kura_pool_sqlite:stop_pool(?REPO),
    application:stop(kura),
    application:unset_env(kura, repos),
    application:unset_env(kura, ensure_database),
    application:unset_env(kura, encryption),
    ok.

init_per_testcase(_Case, Config) ->
    #{} = kura_db:query(
        ?REPO,
        ~"CREATE TABLE vault (id INTEGER PRIMARY KEY, name TEXT, data BLOB, secret BLOB, digest BLOB)",
        []
    ),
    Config.

end_per_testcase(_Case, _Config) ->
    #{} = kura_db:query(?REPO, ~"DROP TABLE vault", []),
    ok.

insert_stores_byte_fields_as_blob(_Config) ->
    {ok, #{id := Id}} = insert(#{name => ~"n", data => ?BYTES, secret => ~"pii@example.com"}),
    ?assertEqual(
        [#{name => ~"text", data => ~"blob", secret => ~"blob"}], storage_classes()
    ),
    {ok, Row} = kura_repo_worker:get(?REPO, ?SCHEMA, Id),
    ?assertMatch(#{name := ~"n", data := ?BYTES, secret := ~"pii@example.com"}, Row).

equality_on_a_blob_column_matches(_Config) ->
    {ok, #{id := Id}} = insert(#{name => ~"n", data => ?BYTES}),
    {ok, _} = insert(#{name => ~"other", data => ~"other"}),
    Q = kura_query:where(kura_query:from(?SCHEMA), {data, ?BYTES}),
    ?assertMatch({ok, [#{id := Id}]}, kura_repo_worker:all(?REPO, Q)),
    ?assertMatch({ok, [#{id := Id}]}, kura_repo_worker:all(?REPO, Q)),
    ?assertMatch({ok, #{id := Id}}, kura_repo_worker:get_by(?REPO, ?SCHEMA, [{data, ?BYTES}])),
    ?assertMatch(
        {ok, [#{id := Id}]},
        kura_repo_worker:all(?REPO, kura_query:where(kura_query:from(?SCHEMA), {name, ~"n"}))
    ).

comparisons_on_a_blob_column_match(_Config) ->
    {ok, #{id := Id}} = insert(#{name => ~"n", data => ?BYTES}),
    {ok, #{id := Other}} = insert(#{name => ~"other", data => ~"other"}),
    ?assertEqual([Id], ids({data, in, [?BYTES, ~"missing"]})),
    ?assertEqual([Other], ids({data, not_in, [?BYTES]})),
    ?assertEqual([Other], ids({data, '!=', ?BYTES})),
    ?assertEqual([Id], ids({data, between, {<<0>>, <<0, 255, 255>>}})),
    ?assertEqual([Id], ids({[id, data], in, [{Id, ?BYTES}, {Other, ?BYTES}]})).

update_stores_blob(_Config) ->
    {ok, Row} = insert(#{name => ~"n", data => ~"before"}),
    CS = kura_changeset:cast(?SCHEMA, Row, #{data => ?BYTES}, [data]),
    {ok, #{data := ?BYTES}} = kura_repo_worker:update(?REPO, CS),
    ?assertEqual([#{name => ~"text", data => ~"blob", secret => ~"blob"}], storage_classes()).

update_all_stores_blob_and_matches(_Config) ->
    {ok, _} = insert(#{name => ~"n", data => ~"before"}),
    Q = kura_query:where(kura_query:from(?SCHEMA), {data, ~"before"}),
    {ok, _} = kura_repo_worker:update_all(?REPO, Q, #{data => ?BYTES}),
    ?assertEqual([#{name => ~"text", data => ~"blob", secret => ~"blob"}], storage_classes()),
    ?assertMatch([_], ids({data, ?BYTES})).

insert_all_stores_blob(_Config) ->
    {ok, _} = kura_repo_worker:insert_all(?REPO, ?SCHEMA, [
        #{name => ~"a", data => ?BYTES, secret => ~"s"},
        #{name => ~"b", data => ~"b", secret => ~"s"}
    ]),
    ?assertEqual(
        [#{name => ~"text", data => ~"blob", secret => ~"blob"} || _ <- [a, b]], storage_classes()
    ).

delete_all_matches_a_blob(_Config) ->
    {ok, _} = insert(#{name => ~"n", data => ?BYTES}),
    {ok, _} = insert(#{name => ~"other", data => ~"other"}),
    Q = kura_query:where(kura_query:from(?SCHEMA), {data, ?BYTES}),
    {ok, _} = kura_repo_worker:delete_all(?REPO, Q),
    ?assertMatch([_], ids({name, ~"other"})).

%% Rows written before byte fields were bound as BLOB hold TEXT, which a
%% BLOB parameter never equals. The README's conversion makes them match.
text_rows_converted_with_cast_match(_Config) ->
    #{} = kura_db:query(?REPO, ~"INSERT INTO vault (name, data, secret) VALUES ('n', ?1, ?2)", [
        ?BYTES, {blob, element(2, kura_types:dump({encrypted, string}, ~"s"))}
    ]),
    ?assertEqual([], ids({data, ?BYTES})),
    #{} = kura_db:query(?REPO, ?CONVERT, []),
    ?assertEqual([#{name => ~"text", data => ~"blob", secret => ~"blob"}], storage_classes()),
    ?assertMatch([_], ids({data, ?BYTES})).

%% A NULL encrypted column cannot be read back yet, so every row has a secret.
%% The first compile of a query is cached, so a custom type module that is
%% not loaded yet must still be seen as BLOB.
first_query_on_an_unloaded_custom_type_casts(_Config) ->
    #{} = kura_db:query(?REPO, ~"INSERT INTO vault (digest) VALUES (?1)", [{blob, ?BYTES}]),
    _ = code:purge(kura_sqlite_bytes_type),
    true = code:delete(kura_sqlite_bytes_type),
    _ = code:purge(kura_sqlite_bytes_type),
    false = code:is_loaded(kura_sqlite_bytes_type),
    Q = kura_query:where(kura_query:from(kura_sqlite_lazy_schema), {digest, ?BYTES}),
    ?assertMatch({ok, [_]}, kura_repo_worker:all(?REPO, Q)),
    ?assertMatch({ok, [_]}, kura_repo_worker:all(?REPO, Q)).

%% A UNIQUE index treats TEXT and BLOB as different values, so an upsert
%% written before the conversion adds a second row and the conversion then
%% fails. The README's query lists the pair.
unique_text_and_blob_duplicate_is_found_and_resolved(_Config) ->
    #{} = kura_db:query(?REPO, ~"CREATE UNIQUE INDEX vault_data ON vault (data)", []),
    #{} = kura_db:query(?REPO, ~"INSERT INTO vault (name, data) VALUES ('old', ?1)", [?BYTES]),
    CS = kura_changeset:cast(?SCHEMA, #{}, #{name => ~"new", data => ?BYTES, secret => ~"s"}, [
        name, data, secret
    ]),
    {ok, _} = kura_repo_worker:insert(?REPO, CS, #{on_conflict => {data, nothing}}),
    ?assertMatch(#{rows := [_, _]}, kura_db:query(?REPO, ~"SELECT id FROM vault", [])),
    ?assertMatch({error, _}, kura_db:query(?REPO, ?CONVERT, [])),
    #{rows := [#{text_row := TextRow, blob_row := _}]} = kura_db:query(
        ?REPO,
        ~"""
        SELECT old.rowid AS text_row, new.rowid AS blob_row
        FROM vault AS old
        JOIN vault AS new ON new.data = CAST(old.data AS BLOB)
        WHERE typeof(old.data) = 'text' AND typeof(new.data) = 'blob'
        """,
        []
    ),
    #{} = kura_db:query(?REPO, ~"DELETE FROM vault WHERE rowid = ?1", [TextRow]),
    #{} = kura_db:query(?REPO, ?CONVERT, []),
    ?assertMatch({ok, [#{name := ~"new"}]}, kura_repo_worker:all(?REPO, where({data, ?BYTES}))).

%% A where-field is not qualified by its table, so a byte column of a joined
%% schema is cast like one of the `from` schema.
exclusion_on_a_joined_blob_column_matches(_Config) ->
    #{} = kura_db:query(
        ?REPO, ~"CREATE TABLE owners (owner_id INTEGER PRIMARY KEY, label TEXT)", []
    ),
    try
        #{} = kura_db:query(?REPO, ~"INSERT INTO owners VALUES (1, 'revoked'), (2, 'good')", []),
        {ok, #{id := 1}} = insert(#{id => 1, name => ~"n", data => ?BYTES}),
        {ok, #{id := 2}} = insert(#{id => 2, name => ~"n", data => ~"other"}),
        Joined = kura_query:join(
            kura_query:from(kura_sqlite_owner_schema), inner, ?SCHEMA, {owner_id, id}
        ),
        Labels = fun(Condition) ->
            {ok, Rows} = kura_repo_worker:all(?REPO, kura_query:where(Joined, Condition)),
            [Label || #{label := Label} <- Rows]
        end,
        ?assertEqual([~"good"], Labels({data, '!=', ?BYTES})),
        ?assertEqual([~"good"], Labels({data, not_in, [?BYTES]})),
        ?assertEqual([~"good"], Labels({'not', {data, ?BYTES}})),
        ?assertEqual([~"revoked"], Labels({data, ?BYTES}))
    after
        #{} = kura_db:query(?REPO, ~"DROP TABLE owners", [])
    end.

where(Condition) ->
    kura_query:where(kura_query:from(?SCHEMA), Condition).

insert(Params0) ->
    Params = maps:merge(#{secret => ~"s"}, Params0),
    kura_repo_worker:insert(?REPO, kura_changeset:cast(?SCHEMA, #{}, Params, maps:keys(Params))).

ids(Condition) ->
    {ok, Rows} = kura_repo_worker:all(
        ?REPO,
        kura_query:order_by(kura_query:where(kura_query:from(?SCHEMA), Condition), [{id, asc}])
    ),
    [Id || #{id := Id} <- Rows].

storage_classes() ->
    #{rows := Rows} = kura_db:query(
        ?REPO,
        ~"SELECT typeof(name) AS name, typeof(data) AS data, typeof(secret) AS secret FROM vault ORDER BY id",
        []
    ),
    Rows.
