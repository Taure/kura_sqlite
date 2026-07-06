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
