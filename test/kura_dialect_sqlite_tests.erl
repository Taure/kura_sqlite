-module(kura_dialect_sqlite_tests).
-include_lib("eunit/include/eunit.hrl").

%%----------------------------------------------------------------------
%% swap_placeholders/1
%%----------------------------------------------------------------------

swap_replaces_dollar_with_question_mark_test() ->
    ?assertEqual(<<"SELECT ?1, ?2">>, kura_dialect_sqlite:swap_placeholders(<<"SELECT $1, $2">>)).

swap_handles_iodata_input_test() ->
    ?assertEqual(
        <<"WHERE ?1 = ?2">>, kura_dialect_sqlite:swap_placeholders([~"WHERE ", ~"$1 = $2"])
    ).

swap_no_placeholders_unchanged_test() ->
    ?assertEqual(<<"SELECT 1">>, kura_dialect_sqlite:swap_placeholders(<<"SELECT 1">>)).

swap_double_digit_placeholder_test() ->
    ?assertEqual(
        <<"SELECT ?12, ?34">>, kura_dialect_sqlite:swap_placeholders(<<"SELECT $12, $34">>)
    ).

%%----------------------------------------------------------------------
%% column_type/1: SQLite type mapping
%%----------------------------------------------------------------------

column_type_basics_test_() ->
    [
        ?_assertEqual(~"INTEGER", kura_dialect_sqlite:column_type(id)),
        ?_assertEqual(~"INTEGER", kura_dialect_sqlite:column_type(integer)),
        ?_assertEqual(~"INTEGER", kura_dialect_sqlite:column_type(boolean)),
        ?_assertEqual(~"REAL", kura_dialect_sqlite:column_type(float)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(string)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(text)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(uuid)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(jsonb)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type(utc_datetime)),
        ?_assertEqual(~"BLOB", kura_dialect_sqlite:column_type(binary)),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type({enum, [a, b]})),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type({array, integer}))
    ].

%%----------------------------------------------------------------------
%% format_default/1: SQLite-flavoured default literals
%%----------------------------------------------------------------------

format_default_test_() ->
    [
        ?_assertEqual(~"42", kura_dialect_sqlite:format_default(42)),
        ?_assertEqual(~"1", kura_dialect_sqlite:format_default(true)),
        ?_assertEqual(~"0", kura_dialect_sqlite:format_default(false)),
        ?_assertEqual(<<"'hello'">>, kura_dialect_sqlite:format_default(<<"hello">>)),
        ?_assertEqual(<<"'{\"a\":1}'">>, kura_dialect_sqlite:format_default(#{a => 1}))
    ].

%%----------------------------------------------------------------------
%% Behaviour declaration
%%----------------------------------------------------------------------

declares_kura_dialect_behaviour_test() ->
    Attrs = kura_dialect_sqlite:module_info(attributes),
    Behaviours = lists:append([V || {behaviour, V} <- Attrs] ++ [V || {behavior, V} <- Attrs]),
    ?assert(lists:member(kura_dialect, Behaviours)).

%%----------------------------------------------------------------------
%% composite primary/foreign keys (delegated to kura_dialect_pg, then
%% placeholders swapped to SQLite style)
%%----------------------------------------------------------------------

composite_update_test() ->
    {SQL, Params} = kura_dialect_sqlite:update(
        kura_sqlite_composite_schema,
        [role],
        #{role => ~"admin"},
        [{org_id, ~"o"}, {user_id, ~"u"}]
    ),
    ?assertNotEqual(
        nomatch,
        binary:match(iolist_to_binary(SQL), ~"WHERE \"org_id\" = ?2 AND \"user_id\" = ?3")
    ),
    ?assertEqual([~"admin", ~"o", ~"u"], Params).

composite_delete_test() ->
    {SQL, Params} = kura_dialect_sqlite:delete(
        kura_sqlite_composite_schema, [{org_id, ~"o"}, {user_id, ~"u"}]
    ),
    ?assertNotEqual(
        nomatch,
        binary:match(iolist_to_binary(SQL), ~"WHERE \"org_id\" = ?1 AND \"user_id\" = ?2")
    ),
    ?assertEqual([~"o", ~"u"], Params).

composite_in_to_sql_test() ->
    Q = kura_query:where(
        kura_query:from(kura_sqlite_composite_schema),
        {[org_id, user_id], in, [{~"o1", ~"u1"}, {~"o2", ~"u2"}]}
    ),
    {SQL, Params} = kura_dialect_sqlite:to_sql(Q),
    ?assertNotEqual(
        nomatch,
        binary:match(iolist_to_binary(SQL), ~"(\"org_id\", \"user_id\") IN ((?1, ?2), (?3, ?4))")
    ),
    ?assertEqual([~"o1", ~"u1", ~"o2", ~"u2"], Params).

composite_delete_roundtrip_test() ->
    {ok, _} = application:ensure_all_started(esqlite),
    Name = kura_sqlite_composite_pool,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 1}),
    {ok, Conn, Tk} = kura_pool_sqlite:checkout(Name, #{}),
    try
        ok = esqlite3:exec(
            Conn,
            ~"CREATE TABLE memberships (org_id TEXT, user_id TEXT, role TEXT, PRIMARY KEY (org_id, user_id))"
        ),
        ok = esqlite3:exec(
            Conn, ~"INSERT INTO memberships VALUES ('o','u','admin'),('o2','u2','member')"
        ),
        {SQL, Params} = kura_dialect_sqlite:delete(
            kura_sqlite_composite_schema, [{org_id, ~"o"}, {user_id, ~"u"}]
        ),
        %% RETURNING * -> use q; the composite key binds ?1, ?2
        _ = esqlite3:q(Conn, iolist_to_binary(SQL), Params),
        ?assertEqual([[1]], esqlite3:q(Conn, ~"SELECT COUNT(*) FROM memberships", [])),
        ?assertEqual([[~"o2"]], esqlite3:q(Conn, ~"SELECT org_id FROM memberships", []))
    after
        kura_pool_sqlite:checkin(Name, Tk),
        kura_pool_sqlite:stop_pool(Name)
    end.

%%----------------------------------------------------------------------
%% Byte fields bind as BLOB (Taure/kura#141)
%%----------------------------------------------------------------------

-define(BLOB_SCHEMA, kura_sqlite_blob_schema).

insert_wraps_byte_fields_test() ->
    {_SQL, Params} = kura_dialect_sqlite:insert(
        ?BLOB_SCHEMA, [name, data, secret], #{name => ~"n", data => ~"d", secret => ~"s"}
    ),
    ?assertEqual([~"n", {blob, ~"d"}, {blob, ~"s"}], Params).

insert_leaves_null_byte_field_test() ->
    {_SQL, Params} = kura_dialect_sqlite:insert(?BLOB_SCHEMA, [data], #{data => null}),
    ?assertEqual([null], Params).

insert_into_table_name_is_untouched_test() ->
    {_SQL, Params} = kura_dialect_sqlite:insert(vault, [data], #{data => ~"d"}),
    ?assertEqual([~"d"], Params).

upsert_wraps_conflict_values_test() ->
    {_SQL, Params} = kura_dialect_sqlite:insert(
        ?BLOB_SCHEMA, [id, data], #{id => 1, data => ~"d"}, #{on_conflict => {id, replace_all}}
    ),
    ?assertEqual([1, {blob, ~"d"}, {blob, ~"d"}], Params).

update_wraps_changes_and_keys_test() ->
    {_SQL, Params} = kura_dialect_sqlite:update(
        ?BLOB_SCHEMA, [data, name], #{data => ~"d", name => ~"n"}, [{data, ~"k"}]
    ),
    ?assertEqual([{blob, ~"d"}, ~"n", {blob, ~"k"}], Params).

delete_wraps_keys_test() ->
    {_SQL, Params} = kura_dialect_sqlite:delete(?BLOB_SCHEMA, [{data, ~"k"}, {id, 1}]),
    ?assertEqual([{blob, ~"k"}, 1], Params).

insert_all_wraps_every_row_test() ->
    {_SQL, Params} = kura_dialect_sqlite:insert_all(
        ?BLOB_SCHEMA, [name, data], [#{name => ~"a", data => ~"1"}, #{name => ~"b", data => ~"2"}]
    ),
    ?assertEqual([~"a", {blob, ~"1"}, ~"b", {blob, ~"2"}], Params).

update_all_wraps_set_values_test() ->
    Q = kura_query:where(kura_query:from(?BLOB_SCHEMA), {name, ~"n"}),
    {SQL, Params} = kura_dialect_sqlite:update_all(Q, #{data => ~"d"}),
    ?assertEqual(<<"UPDATE \"vault\" SET \"data\" = ?1 WHERE \"name\" = ?2">>, SQL),
    ?assertEqual([{blob, ~"d"}, ~"n"], Params).

where_on_byte_field_casts_placeholder_test_() ->
    Cases = [
        {{data, ~"d"}, <<"\"data\" = CAST(?1 AS BLOB)">>, [~"d"]},
        {{data, '=', ~"d"}, <<"\"data\" = CAST(?1 AS BLOB)">>, [~"d"]},
        {{data, '!=', ~"d"}, <<"\"data\" != CAST(?1 AS BLOB)">>, [~"d"]},
        {{data, '>=', ~"d"}, <<"\"data\" >= CAST(?1 AS BLOB)">>, [~"d"]},
        {{data, in, [~"a", ~"b"]}, <<"\"data\" IN (CAST(?1 AS BLOB), CAST(?2 AS BLOB))">>, [
            ~"a", ~"b"
        ]},
        {{data, not_in, [~"a"]}, <<"\"data\" NOT IN (CAST(?1 AS BLOB))">>, [~"a"]},
        {
            {data, between, {~"a", ~"b"}},
            <<"\"data\" BETWEEN CAST(?1 AS BLOB) AND CAST(?2 AS BLOB)">>,
            [~"a", ~"b"]
        },
        {
            {[id, data], in, [{1, ~"a"}, {2, ~"b"}]},
            <<"(\"id\", \"data\") IN ((?1, CAST(?2 AS BLOB)), (?3, CAST(?4 AS BLOB)))">>,
            [
                1, ~"a", 2, ~"b"
            ]
        },
        {
            {'or', [{data, ~"a"}, {name, ~"n"}]},
            <<"(\"data\" = CAST(?1 AS BLOB) OR \"name\" = ?2)">>,
            [~"a", ~"n"]
        },
        {{'not', {data, ~"a"}}, <<"NOT (\"data\" = CAST(?1 AS BLOB))">>, [~"a"]}
    ],
    [
        ?_assertEqual({Where, Params}, where_sql(Condition))
     || {Condition, Where, Params} <- Cases
    ].

where_on_text_field_is_untouched_test() ->
    ?assertEqual({<<"\"name\" = ?1">>, [~"n"]}, where_sql({name, ~"n"})).

where_unary_on_byte_field_is_untouched_test() ->
    ?assertEqual({<<"\"data\" IS NULL">>, []}, where_sql({data, is_nil})).

where_in_subquery_casts_inner_query_test() ->
    Sub = kura_query:where(kura_query:select(kura_query:from(?BLOB_SCHEMA), [id]), {data, ~"d"}),
    Q = kura_query:where(kura_query:from(?BLOB_SCHEMA), {id, in, {subquery, Sub}}),
    {SQL, Params} = kura_dialect_sqlite:to_sql(Q),
    ?assertNotEqual(
        nomatch, binary:match(iolist_to_binary(SQL), ~"WHERE \"data\" = CAST(?1 AS BLOB))")
    ),
    ?assertEqual([~"d"], Params).

delete_all_casts_where_test() ->
    Q = kura_query:where(kura_query:from(?BLOB_SCHEMA), {data, ~"d"}),
    ?assertEqual(
        {<<"DELETE FROM \"vault\" WHERE \"data\" = CAST(?1 AS BLOB)">>, [~"d"]},
        kura_dialect_sqlite:delete_all(Q)
    ).

where_sql(Condition) ->
    Q = kura_query:where(kura_query:from(?BLOB_SCHEMA), Condition),
    {SQL, Params} = kura_dialect_sqlite:to_sql(Q),
    [_, Where] = binary:split(iolist_to_binary(SQL), ~" WHERE "),
    {Where, Params}.

utf16_database_keeps_inserted_bytes_test() ->
    {ok, _} = application:ensure_all_started(esqlite),
    {ok, Conn} = esqlite3:open(":memory:"),
    try
        ok = esqlite3:exec(Conn, ~"PRAGMA encoding = 'UTF-16'"),
        ok = esqlite3:exec(Conn, ~"CREATE TABLE vault (id INTEGER PRIMARY KEY, data BLOB)"),
        Bytes = <<0, 255, 254, 128, $a, 192>>,
        {SQL, Params} = kura_dialect_sqlite:insert(?BLOB_SCHEMA, [data], #{data => Bytes}),
        ?assertMatch(
            #{rows := [#{data := Bytes}]}, kura_driver_sqlite:query_on(Conn, SQL, Params, #{})
        ),
        #{rows := [#{data := AsText}]} = kura_driver_sqlite:query_on(
            Conn, ~"INSERT INTO vault (data) VALUES (?1) RETURNING data", [Bytes], #{}
        ),
        ?assertNotEqual(Bytes, AsText)
    after
        esqlite3:close(Conn)
    end.

custom_blob_type_is_wrapped_test() ->
    {_SQL, Params} = kura_dialect_sqlite:insert(
        ?BLOB_SCHEMA, [digest, tag], #{digest => ~"d", tag => ~"t"}
    ),
    ?assertEqual([{blob, ~"d"}, ~"t"], Params).

insert_into_non_schema_module_is_untouched_test() ->
    {_SQL, Params} = kura_dialect_sqlite:insert(lists, [data], #{data => ~"d"}),
    ?assertEqual([~"d"], Params).

insert_all_with_opts_wraps_every_row_test() ->
    {_SQL, Params} = kura_dialect_sqlite:insert_all(
        ?BLOB_SCHEMA, [data], [#{data => ~"1"}, #{data => ~"2"}], #{returning => true}
    ),
    ?assertEqual([{blob, ~"1"}, {blob, ~"2"}], Params).

where_and_on_byte_field_casts_test() ->
    ?assertEqual(
        {<<"(\"data\" = CAST(?1 AS BLOB) AND \"name\" = ?2)">>, [~"a", ~"n"]},
        where_sql({'and', [{data, ~"a"}, {name, ~"n"}]})
    ).

where_exists_casts_inner_query_test() ->
    Sub = kura_query:where(kura_query:from(?BLOB_SCHEMA), {data, ~"d"}),
    {SQL, Params} = kura_dialect_sqlite:to_sql(
        kura_query:where(kura_query:from(?BLOB_SCHEMA), {not_exists, {subquery, Sub}})
    ),
    ?assertNotEqual(
        nomatch, binary:match(iolist_to_binary(SQL), ~"WHERE \"data\" = CAST(?1 AS BLOB))")
    ),
    ?assertEqual([~"d"], Params).

where_row_in_without_byte_field_is_untouched_test() ->
    ?assertEqual(
        {<<"(\"id\", \"name\") IN ((?1, ?2))">>, [1, ~"n"]},
        where_sql({[id, name], in, [{1, ~"n"}]})
    ).

where_row_in_with_wrong_arity_is_left_to_kura_test() ->
    Q = kura_query:where(kura_query:from(?BLOB_SCHEMA), {[id, data], in, [{1, ~"a"}, {1}]}),
    ?assertEqual(
        compiled(fun() ->
            {SQL, Params} = kura_dialect_pg:to_sql(Q),
            {kura_dialect_sqlite:swap_placeholders(SQL), Params}
        end),
        compiled(fun() -> kura_dialect_sqlite:to_sql(Q) end)
    ).

compiled(Compile) ->
    try Compile() of
        {SQL, Params} -> {iolist_to_binary(SQL), Params}
    catch
        error:Reason -> {error, Reason}
    end.

to_sql_from_casts_and_numbers_from_start_test() ->
    Q = kura_query:where(kura_query:from(?BLOB_SCHEMA), {data, ~"d"}),
    {SQL, Params, Next} = kura_dialect_sqlite:to_sql_from(Q, 3),
    ?assertNotEqual(nomatch, binary:match(iolist_to_binary(SQL), ~"\"data\" = CAST(?3 AS BLOB)")),
    ?assertEqual({[~"d"], 4}, {Params, Next}).

where_exists_casts_test() ->
    Sub = kura_query:where(kura_query:from(?BLOB_SCHEMA), {data, ~"d"}),
    {SQL, _} = kura_dialect_sqlite:to_sql(
        kura_query:where(kura_query:from(?BLOB_SCHEMA), {exists, {subquery, Sub}})
    ),
    ?assertNotEqual(nomatch, binary:match(iolist_to_binary(SQL), ~"CAST(?1 AS BLOB)")).

cte_and_union_cast_test() ->
    Byte = kura_query:where(kura_query:from(?BLOB_SCHEMA), {data, ~"d"}),
    Q = kura_query:union(kura_query:with_cte(Byte, ~"c", Byte), Byte),
    {SQL, Params} = kura_dialect_sqlite:to_sql(Q),
    Casts = binary:matches(iolist_to_binary(SQL), ~"AS BLOB)"),
    ?assertEqual({3, [~"d", ~"d", ~"d"]}, {length(Casts), Params}).

column_type_loads_an_unloaded_custom_type_test() ->
    unload(kura_sqlite_bytes_type),
    ?assertEqual(~"BLOB", kura_dialect_sqlite:column_type({custom, kura_sqlite_bytes_type})).

unload(Mod) ->
    _ = code:purge(Mod),
    _ = code:delete(Mod),
    _ = code:purge(Mod),
    ?assertNot(code:is_loaded(Mod)).

where_unsupported_operator_on_byte_field_raises_test_() ->
    [
        ?_assertError(
            {kura_sqlite, {unsupported_blob_condition, data, matches}},
            where_sql({data, matches, ~"d"})
        ),
        ?_assertError(
            {kura_sqlite, {unsupported_blob_condition, data, between}},
            where_sql({data, between, ~"d"})
        ),
        ?_assertError(
            {kura_sqlite, {unsupported_blob_condition, data, contains}},
            where_sql({data, contains, ~"d"})
        )
    ].

where_unsupported_operator_on_text_field_is_untouched_test() ->
    ?assertEqual({<<"\"name\" LIKE ?1">>, [~"n%"]}, where_sql({name, like, ~"n%"})).

where_left_alone_on_byte_field_test_() ->
    [
        ?_assertEqual({<<"\"data\" LIKE ?1">>, [~"d%"]}, where_sql({data, like, ~"d%"})),
        ?_assertEqual({<<"\"data\" ILIKE ?1">>, [~"d%"]}, where_sql({data, ilike, ~"d%"})),
        ?_assertEqual({<<"\"data\" IS NOT NULL">>, []}, where_sql({data, is_not_nil})),
        ?_assertEqual({<<"\"data\" IN ()">>, []}, where_sql({data, in, []})),
        ?_assertEqual({<<"\"data\" NOT IN ()">>, []}, where_sql({data, not_in, []}))
    ].

where_atom_value_on_byte_field_binds_test() ->
    ?assertEqual({<<"\"data\" = CAST(?1 AS BLOB)">>, [nil]}, where_sql({data, nil})).

where_fragment_is_untouched_test() ->
    ?assertEqual(
        {<<"length(data) > ?1">>, [3]}, where_sql({fragment, ~"length(data) > ?", [3]})
    ).

byte_fields_are_cached_per_schema_test() ->
    Key = {kura_dialect_sqlite, blob_fields, ?BLOB_SCHEMA},
    _ = persistent_term:erase(Key),
    {_, _} = kura_dialect_sqlite:insert(?BLOB_SCHEMA, [data], #{data => ~"d"}),
    ?assertMatch(#{data := _, digest := _, secret := _}, persistent_term:get(Key)),
    ?assertEqual(3, map_size(cached_blob_fields(Key))),
    persistent_term:put(Key, #{}),
    try
        {_, Params} = kura_dialect_sqlite:insert(?BLOB_SCHEMA, [data], #{data => ~"d"}),
        ?assertEqual([~"d"], Params)
    after
        persistent_term:erase(Key)
    end.

cached_blob_fields(Key) ->
    case persistent_term:get(Key) of
        Blobs when is_map(Blobs) -> Blobs
    end.
