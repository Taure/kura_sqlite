-module(kura_dialect_sqlite_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

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
        ?_assertMatch(<<"BLOB", _/binary>>, kura_dialect_sqlite:column_type(binary)),
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

where_on_joined_byte_field_casts_placeholder_test_() ->
    Joined = kura_query:join(
        kura_query:from(kura_sqlite_owner_schema), inner, ?BLOB_SCHEMA, {owner_id, id}
    ),
    Cases = [
        {{data, '!=', ~"d"}, <<"\"data\" != CAST(?1 AS BLOB)">>},
        {{data, not_in, [~"d"]}, <<"\"data\" NOT IN (CAST(?1 AS BLOB))">>},
        {{'not', {data, ~"d"}}, <<"NOT (\"data\" = CAST(?1 AS BLOB))">>},
        {{label, ~"d"}, <<"\"label\" = ?1">>}
    ],
    [
        ?_assertEqual({Where, [~"d"]}, where_sql(Joined, Condition))
     || {Condition, Where} <- Cases
    ].

where_on_byte_field_of_a_table_joined_by_name_is_untouched_test() ->
    Joined = kura_query:join(
        kura_query:from(kura_sqlite_owner_schema), inner, vault, {owner_id, id}
    ),
    ?assertEqual({<<"\"data\" != ?1">>, [~"d"]}, where_sql(Joined, {data, '!=', ~"d"})).

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
    where_sql(kura_query:from(?BLOB_SCHEMA), Condition).

where_sql(Query, Condition) ->
    {SQL, Params} = kura_dialect_sqlite:to_sql(kura_query:where(Query, Condition)),
    [_, Where] = binary:split(iolist_to_binary(SQL), ~" WHERE "),
    {Where, Params}.

%% kura refuses an encrypted field in kura_query:where/2. Setting the record
%% field directly reaches the dialect's own refusal behind it.
unchecked_where_sql(Query = #kura_query{wheres = Wheres}, Condition) ->
    kura_dialect_sqlite:to_sql(Query#kura_query{wheres = Wheres ++ [Condition]}).

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
    ?assertEqual(
        kura_dialect_sqlite:column_type(binary),
        kura_dialect_sqlite:column_type({custom, kura_sqlite_bytes_type})
    ).

blob_checks_constrain_byte_columns_test_() ->
    Blob = kura_dialect_sqlite:column_type(binary),
    Check = fun(Column) ->
        <<"BLOB CHECK (typeof(", Column/binary, ") IN ('blob', 'null'))">>
    end,
    Cases = [
        {
            <<"CREATE TABLE \"t\" (\"id\" INTEGER, \"data\" ", Blob/binary, " NOT NULL)">>,
            <<"CREATE TABLE \"t\" (\"id\" INTEGER, \"data\" ", (Check(~"\"data\""))/binary,
                " NOT NULL)">>
        },
        {
            <<"CREATE TABLE \"t\" (\"a\" ", Blob/binary, ", \"b\" ", Blob/binary, ")">>,
            <<"CREATE TABLE \"t\" (\"a\" ", (Check(~"\"a\""))/binary, ", \"b\" ",
                (Check(~"\"b\""))/binary, ")">>
        },
        {
            <<"ALTER TABLE \"t\" ADD COLUMN \"x\"\"y\" ", Blob/binary>>,
            <<"ALTER TABLE \"t\" ADD COLUMN \"x\"\"y\" ", (Check(~"\"x\"\"y\""))/binary>>
        },
        {
            <<"CREATE TABLE \"t\" (\"\"\"q\" ", Blob/binary, ")">>,
            <<"CREATE TABLE \"t\" (\"\"\"q\" ", (Check(~"\"\"\"q\""))/binary, ")">>
        },
        {
            <<"CREATE TABLE \"t\" (\"a?\" ", Blob/binary, ")">>,
            <<"CREATE TABLE \"t\" (\"a?\" ", Blob/binary, ")">>
        },
        {
            <<"CREATE TABLE \"t\" (\"a\" TEXT DEFAULT '\"x\" ", Blob/binary, "')">>,
            <<"CREATE TABLE \"t\" (\"a\" TEXT DEFAULT '\"x\" ", Blob/binary, "')">>
        },
        {
            <<"CREATE TABLE \"t\" (\"a\" TEXT DEFAULT 'it''s', \"b\" ", Blob/binary, ")">>,
            <<"CREATE TABLE \"t\" (\"a\" TEXT DEFAULT 'it''s', \"b\" ", (Check(~"\"b\""))/binary,
                ")">>
        },
        {~"CREATE TABLE \"t\" (\"data\" BLOB)", ~"CREATE TABLE \"t\" (\"data\" BLOB)"}
    ],
    [?_assertEqual({ok, Out}, kura_dialect_sqlite:blob_checks(In)) || {In, Out} <- Cases].

blob_checks_store_a_byte_column_default_as_blob_test_() ->
    Blob = kura_dialect_sqlite:column_type(binary),
    Check = ~"BLOB CHECK (typeof(\"d\") IN ('blob', 'null'))",
    Cases = [
        {~" NOT NULL DEFAULT 'abc')", ~" NOT NULL DEFAULT X'616263')"},
        {
            ~" PRIMARY KEY NOT NULL DEFAULT 'a''b', \"e\" TEXT DEFAULT 'x')",
            ~" PRIMARY KEY NOT NULL DEFAULT X'612762', \"e\" TEXT DEFAULT 'x')"
        },
        {~" DEFAULT ''", ~" DEFAULT X''"},
        {
            ~" DEFAULT -1.5e+00 REFERENCES \"o\"(\"id\"))",
            ~" DEFAULT X'2D312E35652B3030' REFERENCES \"o\"(\"id\"))"
        }
    ],
    [
        ?_assertEqual(
            {ok, <<"CREATE TABLE \"t\" (\"d\" ", Check/binary, Out/binary>>},
            kura_dialect_sqlite:blob_checks(
                <<"CREATE TABLE \"t\" (\"d\" ", Blob/binary, In/binary>>
            )
        )
     || {In, Out} <- Cases
    ].

blob_checks_refuse_a_default_they_cannot_read_test_() ->
    Blob = kura_dialect_sqlite:column_type(binary),
    [
        ?_assertEqual(
            {error, unrecognised_blob_default},
            kura_dialect_sqlite:blob_checks(
                <<"CREATE TABLE \"t\" (\"d\" ", Blob/binary, In/binary>>
            )
        )
     || In <- [~" DEFAULT 'abc", ~" DEFAULT x'00')", ~" DEFAULT (1))"]
    ].

blob_checks_leave_the_default_of_a_placeholder_column_test() ->
    Blob = kura_dialect_sqlite:column_type(binary),
    SQL = <<"CREATE TABLE \"t\" (\"d?\" ", Blob/binary, " DEFAULT 'abc')">>,
    ?assertEqual({ok, SQL}, kura_dialect_sqlite:blob_checks(SQL)).

%% A byte column whose name the rewrite cannot find would be left without its
%% CHECK, so the statement is refused.
blob_checks_refuse_a_marker_without_a_column_name_test_() ->
    Blob = kura_dialect_sqlite:column_type(binary),
    [
        ?_assertEqual({error, unrecognised_blob_column}, kura_dialect_sqlite:blob_checks(SQL))
     || SQL <- [
            <<"ALTER TABLE \"t\" ALTER COLUMN \"c\" TYPE ", Blob/binary>>,
            <<"CREATE TABLE t (c ", Blob/binary, ")">>,
            <<"CREATE TABLE \"t\" (\"c\"", Blob/binary, ")">>,
            Blob
        ]
    ].

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

%% Ciphertext under a fresh nonce never equals another, so a condition on an
%% encrypted field matches nothing useful and would send the plaintext along
%% with the query.
where_on_encrypted_field_raises_test_() ->
    Sub = kura_query:select(kura_query:from(?BLOB_SCHEMA), [secret]),
    Conditions = [
        {secret, ~"pii"},
        {secret, '=', ~"pii"},
        {secret, '!=', ~"pii"},
        {secret, '>', ~"pii"},
        {secret, like, ~"pii%"},
        {secret, matches, ~"pii"},
        {secret, in, [~"pii"]},
        {secret, in, []},
        {secret, not_in, [~"pii"]},
        {secret, in, {subquery, Sub}},
        {secret, between, {~"a", ~"z"}},
        {[id, secret], in, [{1, ~"pii"}]},
        {[id, secret], in, [{1}]},
        {'not', {secret, '=', ~"pii"}},
        {'and', [{name, ~"n"}, {'or', [{secret, ~"pii"}]}]}
    ],
    Q = kura_query:from(?BLOB_SCHEMA),
    lists:append([
        [
            ?_assertError(
                {kura, {encrypted_field_in_where, secret}}, where_sql(Condition)
            ),
            ?_assertError(
                {kura_sqlite, {encrypted_field_in_where, secret}},
                unchecked_where_sql(Q, Condition)
            )
        ]
     || Condition <- Conditions
    ]).

having_on_encrypted_field_raises_test() ->
    Q = (kura_query:from(?BLOB_SCHEMA))#kura_query{
        group_bys = [secret], havings = [{secret, '=', ~"pii"}]
    },
    ?assertError(
        {kura_sqlite, {encrypted_field_in_where, secret}}, kura_dialect_sqlite:to_sql(Q)
    ).

where_on_joined_encrypted_field_raises_test() ->
    Joined = kura_query:join(
        kura_query:from(kura_sqlite_owner_schema), inner, ?BLOB_SCHEMA, {owner_id, id}
    ),
    ?assertError(
        {kura, {encrypted_field_in_where, secret}}, where_sql(Joined, {secret, ~"pii"})
    ),
    ?assertError(
        {kura_sqlite, {encrypted_field_in_where, secret}},
        unchecked_where_sql(Joined, {secret, ~"pii"})
    ).

where_on_encrypted_field_named_with_a_placeholder_raises_test() ->
    Q = kura_query:from(kura_sqlite_question_schema),
    ?assertError(
        {kura, {encrypted_field_in_where, 'secret?'}}, where_sql(Q, {'secret?', ~"pii"})
    ),
    ?assertError(
        {kura_sqlite, {encrypted_field_in_where, 'secret?'}},
        unchecked_where_sql(Q, {'secret?', ~"pii"})
    ).

insert_binds_encrypted_field_named_with_a_placeholder_as_blob_test() ->
    {_SQL, Params} = kura_dialect_sqlite:insert(
        kura_sqlite_question_schema, ['secret?', 'data?'], #{'secret?' => ~"s", 'data?' => ~"d"}
    ),
    ?assertEqual([{blob, ~"s"}, ~"d"], Params).

where_unary_on_encrypted_field_is_untouched_test_() ->
    [
        ?_assertEqual({<<"\"secret\" IS NULL">>, []}, where_sql({secret, is_nil})),
        ?_assertEqual({<<"\"secret\" IS NOT NULL">>, []}, where_sql({secret, is_not_nil}))
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
    Types = kura_schema:field_types(?BLOB_SCHEMA),
    ?assertMatch({Types, #{data := _, digest := _, secret := _}}, persistent_term:get(Key)),
    ?assertEqual(3, map_size(cached_blob_fields(Key))),
    persistent_term:put(Key, {Types, #{}}),
    try
        {_, Params} = kura_dialect_sqlite:insert(?BLOB_SCHEMA, [data], #{data => ~"d"}),
        ?assertEqual([~"d"], Params)
    after
        persistent_term:erase(Key)
    end.

%% kura_schema:forget/1 drops kura's cached field types; a cache entry
%% computed from other field types is recomputed.
byte_fields_follow_changed_field_types_test() ->
    Key = {kura_dialect_sqlite, blob_fields, ?BLOB_SCHEMA},
    persistent_term:put(Key, {#{data => string}, #{}}),
    try
        {_, Params} = kura_dialect_sqlite:insert(?BLOB_SCHEMA, [data], #{data => ~"d"}),
        ?assertEqual([{blob, ~"d"}], Params),
        ?assertEqual(3, map_size(cached_blob_fields(Key)))
    after
        persistent_term:erase(Key)
    end.

module_without_fields_is_not_a_schema_test() ->
    Key = {kura_dialect_sqlite, blob_fields, kura_sqlite_table_only},
    {_, Params} = kura_dialect_sqlite:insert(kura_sqlite_table_only, [data], #{data => ~"d"}),
    ?assertEqual([~"d"], Params),
    ?assertEqual(undefined, persistent_term:get(Key, undefined)).

non_schema_lookup_is_not_cached_test() ->
    Key = {kura_dialect_sqlite, blob_fields, kura_sqlite_not_yet_a_schema},
    {_, _} = kura_dialect_sqlite:insert(kura_sqlite_not_yet_a_schema, [data], #{data => ~"d"}),
    ?assertEqual(undefined, persistent_term:get(Key, undefined)).

cached_blob_fields(Key) ->
    case persistent_term:get(Key) of
        {_Types, Blobs} when is_map(Blobs) -> Blobs
    end.

%%----------------------------------------------------------------------
%% Every encrypted form, and deterministic lookups (Taure/kura#219)
%%----------------------------------------------------------------------

-define(LOOKUP_SCHEMA, kura_sqlite_lookup_schema).
-define(DETERMINISTIC, ?LOOKUP_SCHEMA:encrypted(string, #{mode => deterministic})).

encrypted_forms_are_blob_columns_test_() ->
    Blob = kura_dialect_sqlite:column_type(binary),
    [
        ?_assertEqual(Blob, kura_dialect_sqlite:column_type({encrypted, string})),
        ?_assertEqual(Blob, kura_dialect_sqlite:column_type(?DETERMINISTIC)),
        ?_assertEqual(Blob, kura_dialect_sqlite:column_type(?LOOKUP_SCHEMA:encrypted(binary, #{}))),
        ?_assertEqual(
            Blob, kura_dialect_sqlite:column_type(?LOOKUP_SCHEMA:encrypted(string, not_options))
        ),
        ?_assertEqual(~"TEXT", kura_dialect_sqlite:column_type({array, {encrypted, string}})),
        ?_assertError({case_clause, none}, kura_dialect_sqlite:column_type(vector))
    ].

encrypted_form_column_refuses_text_test() ->
    Column = kura_dialect_sqlite:column_type(?DETERMINISTIC),
    ?assertEqual(
        {ok, ~"CREATE TABLE \"t\" (\"token\" BLOB CHECK (typeof(\"token\") IN ('blob', 'null')))"},
        kura_dialect_sqlite:blob_checks(<<"CREATE TABLE \"t\" (\"token\" ", Column/binary, ")">>)
    ).

where_lookup_on_byte_field_casts_every_frame_test_() ->
    Cases = [
        {
            {secret, encrypted_in, [~"f1", ~"f2"]},
            <<"\"secret\" IN (CAST(?1 AS BLOB), CAST(?2 AS BLOB))">>,
            [~"f1", ~"f2"]
        },
        {{secret, encrypted_in, [~"f1"]}, <<"\"secret\" IN (CAST(?1 AS BLOB))">>, [~"f1"]},
        {
            {secret, encrypted_not_in, [~"f1", ~"f2"]},
            <<"\"secret\" NOT IN (CAST(?1 AS BLOB), CAST(?2 AS BLOB))">>,
            [~"f1", ~"f2"]
        },
        {{data, encrypted_in, [~"f1"]}, <<"\"data\" IN (CAST(?1 AS BLOB))">>, [~"f1"]},
        {{secret, encrypted_in, []}, <<"\"secret\" IN ()">>, []},
        {
            {'not', {secret, encrypted_in, [~"f1"]}},
            <<"NOT (\"secret\" IN (CAST(?1 AS BLOB)))">>,
            [~"f1"]
        },
        {
            {'and', [{name, ~"n"}, {'or', [{secret, encrypted_not_in, [~"f1"]}]}]},
            <<"(\"name\" = ?1 AND (\"secret\" NOT IN (CAST(?2 AS BLOB))))">>,
            [~"n", ~"f1"]
        }
    ],
    [
        ?_assertEqual({Where, Params}, unchecked_where(kura_query:from(?BLOB_SCHEMA), Condition))
     || {Condition, Where, Params} <- Cases
    ].

where_lookup_on_joined_byte_field_casts_test() ->
    Joined = kura_query:join(
        kura_query:from(kura_sqlite_owner_schema), inner, ?BLOB_SCHEMA, {owner_id, id}
    ),
    ?assertEqual(
        {<<"\"secret\" NOT IN (CAST(?1 AS BLOB))">>, [~"f1"]},
        unchecked_where(Joined, {secret, encrypted_not_in, [~"f1"]})
    ).

having_lookup_on_byte_field_casts_test() ->
    Q = (kura_query:from(?BLOB_SCHEMA))#kura_query{
        group_bys = [secret], havings = [{secret, encrypted_in, [~"f1"]}]
    },
    {SQL, Params} = kura_dialect_sqlite:to_sql(Q),
    [_, Having] = binary:split(iolist_to_binary(SQL), ~" HAVING "),
    ?assertEqual({<<"\"secret\" IN (CAST(?1 AS BLOB))">>, [~"f1"]}, {Having, Params}).

where_lookup_that_cannot_be_cast_raises_test_() ->
    Q = kura_query:from(?BLOB_SCHEMA),
    [
        ?_assertError(
            {kura_sqlite, {unsupported_blob_condition, name, encrypted_in}},
            unchecked_where(Q, {name, encrypted_in, [~"f1"]})
        ),
        ?_assertError(
            {kura_sqlite, {unsupported_blob_condition, secret, encrypted_not_in}},
            unchecked_where(kura_query:from(vault), {secret, encrypted_not_in, [~"f1"]})
        ),
        ?_assertError(
            {kura_sqlite, {unsupported_blob_condition, 'secret?', encrypted_in}},
            unchecked_where(
                kura_query:from(kura_sqlite_question_schema), {'secret?', encrypted_in, [~"f1"]}
            )
        ),
        ?_assertError(
            {kura_sqlite, {encrypted_field_in_where, secret}},
            unchecked_where(Q, {secret, encrypted_in, ~"f1"})
        )
    ].

where_lookup_matches_stored_frames_test() ->
    {ok, _} = application:ensure_all_started(esqlite),
    {ok, Conn} = esqlite3:open(":memory:"),
    try
        ok = esqlite3:exec(
            Conn,
            ~"CREATE TABLE vault (id INTEGER PRIMARY KEY, name TEXT, data BLOB, secret BLOB, digest BLOB, tag TEXT)"
        ),
        Frames = [<<0, 255, 254, 128, $a, 192>>, <<1, 2, 3>>, <<"plain">>],
        _ = [
            kura_driver_sqlite:query_on(Conn, SQL, Params, #{})
         || Frame <- Frames,
            {SQL, Params} <- [
                kura_dialect_sqlite:insert(?BLOB_SCHEMA, [secret], #{secret => Frame})
            ]
        ],
        Ids = fun(Condition) ->
            Q = kura_query:select(kura_query:from(?BLOB_SCHEMA), [id]),
            {SQL, Params} = unchecked_where_sql(kura_query:order_by(Q, [{id, asc}]), Condition),
            #{rows := Rows} = kura_driver_sqlite:query_on(Conn, SQL, Params, #{}),
            [Id || #{id := Id} <- Rows]
        end,
        ?assertEqual(
            [1, 3], Ids({secret, encrypted_in, [<<0, 255, 254, 128, $a, 192>>, ~"plain"]})
        ),
        ?assertEqual(
            [2], Ids({secret, encrypted_not_in, [<<0, 255, 254, 128, $a, 192>>, ~"plain"]})
        )
    after
        esqlite3:close(Conn)
    end.

%% A kura without {encrypted, Inner, Opts} refuses the schema when it is
%% first read, so its field types are put in kura's cache, as kura#219
%% reads them.
three_tuple_schema_test_() ->
    {setup, fun read_lookup_schema/0, fun forget_lookup_schema/1, fun(_) ->
        three_tuple_schema_tests()
    end}.

read_lookup_schema() ->
    Key = {kura_schema, field_types, ?LOOKUP_SCHEMA},
    try kura_schema:field_types(?LOOKUP_SCHEMA) of
        #{} -> read
    catch
        error:{kura, {unsupported_encrypted_type, ?LOOKUP_SCHEMA, _}} ->
            persistent_term:put(
                Key,
                #{
                    Field => Type
                 || #kura_field{name = Field, type = Type} <- ?LOOKUP_SCHEMA:fields()
                }
            ),
            {seeded, Key}
    end.

forget_lookup_schema(Read) ->
    _ = persistent_term:erase({kura_dialect_sqlite, blob_fields, ?LOOKUP_SCHEMA}),
    case Read of
        {seeded, Key} -> _ = persistent_term:erase(Key);
        read -> ok
    end,
    ok.

three_tuple_schema_tests() ->
    Q = kura_query:from(?LOOKUP_SCHEMA),
    Values = #{name => ~"n", token => ~"t", 'code?' => ~"c", tags => [~"x"]},
    Fields = [name, token, 'code?', tags],
    [
        ?_assertEqual(
            [~"n", {blob, ~"t"}, {blob, ~"c"}, [~"x"]],
            element(2, kura_dialect_sqlite:insert(?LOOKUP_SCHEMA, Fields, Values))
        ),
        ?_assertEqual(
            [~"n", {blob, ~"t"}, {blob, ~"c"}, [~"x"]],
            element(2, kura_dialect_sqlite:insert_all(?LOOKUP_SCHEMA, Fields, [Values]))
        ),
        ?_assertEqual(
            [{blob, ~"t"}, {blob, ~"k"}],
            element(
                2,
                kura_dialect_sqlite:update(?LOOKUP_SCHEMA, [token], #{token => ~"t"}, [
                    {token, ~"k"}
                ])
            )
        ),
        ?_assertEqual(
            [{blob, ~"k"}], element(2, kura_dialect_sqlite:delete(?LOOKUP_SCHEMA, [{token, ~"k"}]))
        ),
        ?_assertEqual(
            [{blob, ~"t"}], element(2, kura_dialect_sqlite:update_all(Q, #{token => ~"t"}))
        ),
        ?_assertEqual([token, 'code?'], kura_dialect_sqlite:blob_columns(?LOOKUP_SCHEMA)),
        ?_assertEqual(
            {<<"\"token\" IN (CAST(?1 AS BLOB), CAST(?2 AS BLOB))">>, [~"f1", ~"f2"]},
            unchecked_where(Q, {token, encrypted_in, [~"f1", ~"f2"]})
        ),
        ?_assertEqual(
            {<<"\"token\" NOT IN (CAST(?1 AS BLOB))">>, [~"f1"]},
            unchecked_where(Q, {token, encrypted_not_in, [~"f1"]})
        ),
        ?_assertError(
            {kura_sqlite, {encrypted_field_in_where, token}}, unchecked_where(Q, {token, ~"t"})
        ),
        ?_assertError(
            {kura_sqlite, {encrypted_field_in_where, 'code?'}},
            unchecked_where(Q, {'code?', '=', ~"c"})
        ),
        ?_assertError(
            {kura_sqlite, {unsupported_blob_condition, 'code?', encrypted_in}},
            unchecked_where(Q, {'code?', encrypted_in, [~"f1"]})
        ),
        ?_assertEqual({<<"\"tags\" = ?1">>, [[~"x"]]}, unchecked_where(Q, {tags, [~"x"]}))
    ].

unchecked_where(Query, Condition) ->
    {SQL, Params} = unchecked_where_sql(Query, Condition),
    [_, Where] = binary:split(iolist_to_binary(SQL), ~" WHERE "),
    {Where, Params}.

%%----------------------------------------------------------------------
%% Vector distance
%%----------------------------------------------------------------------

-define(UNSUPPORTED, {unsupported, vector_distance}).
-define(DISTANCE, {distance, embedding, cosine, ~"[1.0,2.0,3.0]"}).

distance_queries() ->
    D = ?DISTANCE,
    Sub = #kura_query{from = items, select = [id], wheres = [{D, '<', 0.5}]},
    [
        {"select expression", #kura_query{from = items, select = {exprs, [{id, id}, {d, D}]}}},
        {"order_by", #kura_query{from = items, order_bys = [{id, asc}, {D, asc}]}},
        {"where threshold", #kura_query{from = items, wheres = [{id, 1}, {D, '<', 0.5}]}},
        {"having threshold", #kura_query{from = items, havings = [{D, '>=', 0.5}]}},
        {"threshold under and, or and not", #kura_query{
            from = items, wheres = [{'or', [{id, 1}, {'and', [{'not', {D, '<=', 0.5}}]}]}]
        }},
        {"bare distance condition", #kura_query{from = items, wheres = [{D, 0.5}]}},
        {"in subquery", #kura_query{from = items, wheres = [{id, in, {subquery, Sub}}]}},
        {"exists subquery", #kura_query{from = items, wheres = [{exists, {subquery, Sub}}]}},
        {"not_exists subquery", #kura_query{
            from = items, havings = [{not_exists, {subquery, Sub}}]
        }},
        {"distance in subquery", #kura_query{
            from = items, wheres = [{D, in, {subquery, #kura_query{from = items}}}]
        }},
        {"select expression after a malformed one", #kura_query{
            from = items, select = {exprs, [not_an_expr, {d, D}]}
        }},
        {"order_by after a malformed one", #kura_query{
            from = items, order_bys = [not_an_order, {D, asc}]
        }},
        {"cte", kura_query:with_cte(#kura_query{from = items}, ~"near", Sub)},
        {"second cte",
            kura_query:with_cte(
                kura_query:with_cte(#kura_query{from = items}, ~"plain", #kura_query{from = items}),
                ~"near",
                Sub
            )},
        {"combination", kura_query:union(#kura_query{from = items}, Sub)}
    ].

distance_raises_unsupported_in_every_position_test_() ->
    [
        {Title, [
            ?_assertError(?UNSUPPORTED, kura_dialect_sqlite:to_sql(Q)),
            ?_assertError(?UNSUPPORTED, kura_dialect_sqlite:to_sql_from(Q, 1)),
            ?_assertError(?UNSUPPORTED, kura_dialect_sqlite:delete_all(Q)),
            ?_assertError(?UNSUPPORTED, kura_dialect_sqlite:update_all(Q, #{content => ~"x"}))
        ]}
     || {Title, Q} <- distance_queries()
    ].

%% Malformed lists and conditions with no distance are left to
%% kura_dialect_pg, as before.
queries_without_a_distance_still_compile_test_() ->
    Sub = #kura_query{from = items, select = [id], wheres = [{id, '>', 1}]},
    Queries = [
        #kura_query{from = items, select = {exprs, [{id, id}, {n, {fragment, ~"1", []}}]}},
        #kura_query{from = items, order_bys = [{id, desc}]},
        #kura_query{
            from = items,
            wheres = [
                {'and', [{id, 1}, {'not', {name, like, ~"a%"}}]},
                {deleted_at, is_nil},
                {fragment, ~"1 = ?", [1]},
                {id, in, {subquery, Sub}},
                {exists, {subquery, Sub}}
            ],
            havings = [{id, '>', 0}]
        },
        kura_query:union(#kura_query{from = items}, Sub)
    ],
    [?_assertMatch({_, _}, kura_dialect_sqlite:to_sql(Q)) || Q <- Queries].

%% Through the compiler, the cached path included: a shape the dialect
%% raises on is cached as uncacheable, and every run raises from the
%% direct compile.
distance_query_through_the_compiler_raises_test_() ->
    {setup,
        fun() ->
            application:set_env(kura, repos, #{
                kura_sqlite_vector_repo => #{dialect => kura_dialect_sqlite}
            }),
            kura_query_cache:init(),
            kura_query_cache:flush()
        end,
        fun(_) ->
            kura_query_cache:flush(),
            application:unset_env(kura, repos)
        end,
        fun(_) ->
            D = kura_query:distance(embedding, cosine, [1, 2, 3]),
            Q0 = kura_query:select_expr(
                kura_query:from(kura_sqlite_vector_schema), [{id, id}, {dist, D}]
            ),
            Q = kura_query:limit(kura_query:order_by(Q0, [{dist, asc}]), 5),
            Ordered = kura_query:order_by(kura_query:from(kura_sqlite_vector_schema), [{D, asc}]),
            [
                ?_assertError(?UNSUPPORTED, kura_query_compiler:to_sql(kura_sqlite_vector_repo, Q)),
                ?_assertError(
                    ?UNSUPPORTED, kura_query_compiler:to_sql_cached(kura_sqlite_vector_repo, Q)
                ),
                ?_assertError(
                    ?UNSUPPORTED,
                    kura_query_compiler:to_sql_cached(kura_sqlite_vector_repo, Ordered)
                ),
                ?_assertError(
                    ?UNSUPPORTED, kura_query_compiler:to_sql_cached(kura_sqlite_vector_repo, Q)
                ),
                ?_test(begin
                    {Shape, _Values} = kura_query_shape:split(Q),
                    ?assertEqual(
                        {ok, uncacheable},
                        kura_query_cache:get(
                            {kura_sqlite_vector_repo, kura_tenant:get_tenant(), Shape}
                        )
                    )
                end)
            ]
        end}.
