-module(kura_sqlite_orm_SUITE).
-moduledoc """
kura's repo API against a SQLite file: every feature either gives the
result it gives on PostgreSQL or is refused before a statement runs.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kura/include/kura.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    insert_returns_the_row/1,
    insert_writes_a_renamed_column/1,
    arrays_are_refused/1,
    other_scalar_types/1,
    a_decimal_is_the_number_sqlite_holds/1,
    every_field_type_is_written_and_found/1,
    booleans_and_dates_read_back_as_written/1,
    get_get_by_and_reload/1,
    update_stamps_and_keeps_the_rest/1,
    delete_removes_the_row/1,
    where_trees/1,
    empty_in_lists/1,
    order_limit_and_offset/1,
    like_patterns/1,
    literal_text_matches/1,
    text_matches_fold_ascii_only/1,
    joins/1,
    preloads/1,
    aggregates/1,
    group_by_and_having/1,
    window_functions/1,
    ctes_and_combinations/1,
    transaction_commits_and_rolls_back/1,
    nested_transaction_rolls_back_to_its_savepoint/1,
    multi_runs_in_one_transaction/1,
    insert_all_empty_and_uneven/1,
    insert_all_returning/1,
    insert_all_at_the_parameter_limit/1,
    upsert/1,
    upsert_all/1,
    update_all_and_delete_all/1,
    pagination/1,
    stream_needs_server_cursors/1,
    embedded_schema/1,
    encrypted_fields/1,
    renamed_byte_column/1,
    redacted_values_stay_out_of_telemetry/1,
    constraint_errors_land_on_their_field/1,
    constraint_errors_reach_telemetry_without_their_message/1,
    optimistic_locking/1,
    custom_and_absent_timestamps/1,
    attribute_tenant/1,
    prefix_tenant/1,
    require_tenant/1,
    fragments_and_placeholders/1,
    numbered_parameters_bind_by_number/1,
    declared_capabilities_run/1,
    undeclared_capabilities_are_refused/1,
    bind_limit_is_the_bundled_sqlite_limit/1
]).

-define(REPO, kura_sqlite_orm_repo).
-define(AUTHOR, kura_sqlite_orm_author).
-define(POST, kura_sqlite_orm_post).
-define(TAG, kura_sqlite_orm_tag).
-define(SECRET, kura_sqlite_orm_secret).
-define(NOTE, kura_sqlite_orm_note).
-define(PLAN, kura_sqlite_orm_plan).
-define(LIST, kura_sqlite_orm_list).
-define(EVERY, kura_sqlite_orm_every_type).
-define(MEMBER, kura_sqlite_orm_member).
-define(SCHEMAS, [?AUTHOR, ?POST, ?TAG, ?SECRET, ?NOTE, ?PLAN, ?EVERY]).
-define(UNSUPPORTED(Capability), {kura, {unsupported_capability, Capability, kura_pool_sqlite}}).
-define(TELEMETRY, kura_sqlite_orm_telemetry).

all() ->
    [
        insert_returns_the_row,
        insert_writes_a_renamed_column,
        booleans_and_dates_read_back_as_written,
        arrays_are_refused,
        other_scalar_types,
        a_decimal_is_the_number_sqlite_holds,
        every_field_type_is_written_and_found,
        get_get_by_and_reload,
        update_stamps_and_keeps_the_rest,
        delete_removes_the_row,
        where_trees,
        empty_in_lists,
        order_limit_and_offset,
        like_patterns,
        literal_text_matches,
        text_matches_fold_ascii_only,
        joins,
        preloads,
        aggregates,
        group_by_and_having,
        window_functions,
        ctes_and_combinations,
        transaction_commits_and_rolls_back,
        nested_transaction_rolls_back_to_its_savepoint,
        multi_runs_in_one_transaction,
        insert_all_empty_and_uneven,
        insert_all_returning,
        insert_all_at_the_parameter_limit,
        upsert,
        upsert_all,
        update_all_and_delete_all,
        pagination,
        stream_needs_server_cursors,
        embedded_schema,
        encrypted_fields,
        renamed_byte_column,
        redacted_values_stay_out_of_telemetry,
        constraint_errors_land_on_their_field,
        constraint_errors_reach_telemetry_without_their_message,
        optimistic_locking,
        custom_and_absent_timestamps,
        attribute_tenant,
        prefix_tenant,
        require_tenant,
        fragments_and_placeholders,
        numbered_parameters_bind_by_number,
        declared_capabilities_run,
        undeclared_capabilities_are_refused,
        bind_limit_is_the_bundled_sqlite_limit
    ].

init_per_suite(Config) ->
    {module, _} = code:ensure_loaded(kura_backend_sqlite),
    Database = filename:join(?config(priv_dir, Config), "orm.db"),
    application:set_env(kura, repos, #{
        ?REPO => #{backend => kura_backend_sqlite, database => Database, pool_size => 2}
    }),
    application:set_env(kura, ensure_database, false),
    application:set_env(kura, encryption, #{
        active => 1,
        deterministic_active => 1,
        keys => [{1, base64:encode(crypto:strong_rand_bytes(32))}]
    }),
    {ok, _} = application:ensure_all_started(kura),
    #{} = kura_db:query(?REPO, ~"PRAGMA journal_mode = WAL", []),
    [create_table(Schema) || Schema <- ?SCHEMAS],
    run_operation(
        {create_table, ~"posts_tags", [
            #kura_column{name = post_id, type = integer, nullable = false},
            #kura_column{name = tag_id, type = integer, nullable = false}
        ]}
    ),
    run_operation({create_index, ~"authors", [email_address], #{unique => true}}),
    run_operation({create_index, ~"tags", [name], #{unique => true}}),
    Config.

end_per_suite(_Config) ->
    kura_pool_sqlite:stop_pool(?REPO),
    application:stop(kura),
    application:unset_env(kura, repos),
    application:unset_env(kura, ensure_database),
    application:unset_env(kura, encryption),
    ok.

init_per_testcase(_Case, Config) ->
    [
        #{} = kura_db:query(?REPO, [~"DELETE FROM ", Table], [])
     || Table <- [~"posts_tags" | [Schema:table() || Schema <- ?SCHEMAS]]
    ],
    Config.

end_per_testcase(require_tenant, _Config) ->
    _ = kura_tenant:clear_tenant(),
    application:unset_env(kura, require_tenant),
    restarted();
end_per_testcase(_Case, _Config) ->
    _ = kura_tenant:clear_tenant(),
    ok.

%% A repo takes require_tenant from the application environment when its
%% pool starts.
restarted() ->
    ok = kura_db:stop_pool(?REPO),
    ok = kura_db:start_pool(?REPO).

%%----------------------------------------------------------------------
%% Rows
%%----------------------------------------------------------------------

insert_returns_the_row(_Config) ->
    {ok, Author} = insert_author(#{
        name => ~"Ada",
        email => ~"ada@example.com",
        age => 36,
        role => admin,
        score => 9.5,
        settings => #{~"theme" => ~"dark"},
        born => {1815, 12, 10}
    }),
    ?assertMatch(
        #{
            id := Id,
            name := ~"Ada",
            email := ~"ada@example.com",
            age := 36,
            role := admin,
            score := 9.5,
            settings := #{~"theme" := ~"dark"},
            lock_version := 1
        } when is_integer(Id),
        Author
    ),
    {ok, Read} = kura_repo_worker:get(?REPO, ?AUTHOR, maps:get(id, Author)),
    ?assertEqual(maps:without([posts, address], Author), maps:without([posts, address], Read)).

insert_writes_a_renamed_column(_Config) ->
    {ok, #{id := Id}} = insert_author(#{name => ~"Ada", email => ~"ada@example.com"}),
    ?assertMatch(
        #{rows := [#{email_address := ~"ada@example.com"}]},
        kura_db:query(?REPO, ~"SELECT email_address FROM authors WHERE id = ?1", [Id])
    ),
    Q = kura_query:order_by(
        kura_query:where(kura_query:from(?AUTHOR), {email, like, ~"ada@%"}), [{email, asc}]
    ),
    ?assertMatch({ok, [#{id := Id, email := ~"ada@example.com"}]}, kura_repo_worker:all(?REPO, Q)),
    Selected = kura_query:select(kura_query:from(?AUTHOR), [email]),
    ?assertEqual({ok, [#{email => ~"ada@example.com"}]}, kura_repo_worker:all(?REPO, Selected)).

%% SQLite stores a boolean as 0 or 1 and a date or a datetime as text. kura
%% loads them back as the values that were written.
booleans_and_dates_read_back_as_written(_Config) ->
    {ok, #{id := Id} = Author} = insert_author(#{
        name => ~"Bob", active => false, born => {1990, 1, 2}
    }),
    ?assertMatch(
        #{active := false, born := {1990, 1, 2}, inserted_at := {{_, _, _}, {_, _, _}}}, Author
    ),
    ?assertMatch(
        #{rows := [#{active := 0, born := ~"1990-01-02", inserted_at := <<_:19/binary>>}]},
        kura_db:query(?REPO, ~"SELECT active, born, inserted_at FROM authors WHERE id = ?1", [Id])
    ),
    {ok, Read} = kura_repo_worker:get(?REPO, ?AUTHOR, Id),
    ?assertEqual(maps:without([posts, address], Author), maps:without([posts, address], Read)),
    Q = kura_query:from(?AUTHOR),
    ?assertEqual([~"Bob"], names(where(Q, {active, false}))),
    ?assertEqual([~"Bob"], names(where(Q, {born, {1990, 1, 2}}))),
    ?assertEqual([~"Bob"], names(where(Q, {inserted_at, '>', {{2020, 1, 1}, {0, 0, 0}}}))),
    ?assertEqual([], names(where(Q, {active, true}))).

%% A list would bind as one TEXT value, its elements run together. The
%% table is one a kura_sqlite up to 1.3 would migrate.
arrays_are_refused(_Config) ->
    #{} = kura_db:query(
        ?REPO,
        ~"CREATE TABLE lists (id INTEGER PRIMARY KEY, name TEXT, nicknames TEXT, scores TEXT)",
        []
    ),
    Insert = fun(Params) ->
        kura_repo_worker:insert(?REPO, kura_changeset:cast(?LIST, #{}, Params, maps:keys(Params)))
    end,
    try
        [
            ?assertError({kura_sqlite, {unsupported_type, {array, _}}}, Insert(Params))
         || Params <- [#{nicknames => [~"a", ~"b"]}, #{scores => [1, 2, 3]}, #{scores => []}]
        ],
        ?assertError(
            {kura_sqlite, {unsupported_type, {array, string}}},
            kura_repo_worker:insert_all(?REPO, ?LIST, [#{nicknames => [~"a"]}])
        ),
        ?assertError(
            {kura_sqlite, {unsupported_type, {array, integer}}},
            kura_repo_worker:update_all(?REPO, kura_query:from(?LIST), #{scores => [1]})
        ),
        ?assertError(
            {kura_sqlite, {unsupported_type, {array, string}}},
            kura_migrator:compile_operation(
                ?REPO,
                {create_table, ~"lists", [#kura_column{name = items, type = {array, string}}]}
            )
        ),
        ?assertMatch(
            {ok, #{name := ~"empty", nicknames := undefined}}, Insert(#{name => ~"empty"})
        ),
        ?assertEqual({ok, 1}, kura_repo_worker:count(?REPO, kura_query:from(?LIST)))
    after
        #{} = kura_db:query(?REPO, ~"DROP TABLE lists", [])
    end.

%% Stored as the database stores them: a decimal as a number, a uuid as its
%% text, a time as its clock.
other_scalar_types(_Config) ->
    {ok, #{id := Id}} = insert_author(#{
        name => ~"Bob", balance => 1.25, ref => ~"0192e4a0-7b1a-7c3e-8f00-000000000001"
    }),
    ?assertMatch(
        {ok, #{balance := 1.25, ref := ~"0192e4a0-7b1a-7c3e-8f00-000000000001"}},
        kura_repo_worker:get(?REPO, ?AUTHOR, Id)
    ),
    ?assertEqual(
        [~"Bob"],
        names(
            where(kura_query:from(?AUTHOR), {ref, ~"0192e4a0-7b1a-7c3e-8f00-000000000001"})
        )
    ),
    {ok, #{id := Early}} = insert_author(#{name => ~"Early", wakes => {7, 30, 0}}),
    ?assertMatch(
        #{rows := [#{wakes := ~"07:30:00"}]},
        kura_db:query(?REPO, ~"SELECT wakes FROM authors WHERE id = ?1", [Early])
    ),
    ?assertEqual([~"Early"], names(where(kura_query:from(?AUTHOR), {wakes, {7, 30, 0}}))),
    ?assertEqual([~"Early"], names(where(kura_query:from(?AUTHOR), {wakes, '<', {12, 5, 6}}))),
    ?assertEqual([], names(where(kura_query:from(?AUTHOR), {wakes, '>', {12, 5, 6}}))).

%% SQLite has no exact numeric type. A NUMERIC column holds an integer or a
%% float, so a decimal without a fraction comes back as an integer and one
%% longer than a float holds comes back rounded, also when written as text.
a_decimal_is_the_number_sqlite_holds(_Config) ->
    Read = fun(Name, Balance) ->
        {ok, #{id := Id}} = insert_author(#{name => Name, balance => Balance}),
        {ok, #{balance := Held}} = kura_repo_worker:get(?REPO, ?AUTHOR, Id),
        Held
    end,
    ?assertEqual(1.25, Read(~"fraction", 1.25)),
    ?assertEqual(7, Read(~"integer", 7)),
    ?assertEqual(2, Read(~"whole float", 2.0)),
    #{} = kura_db:query(
        ?REPO,
        ~"INSERT INTO authors (name, balance) VALUES ('long', '12345678901234567.89')",
        []
    ),
    ?assertMatch(
        [#{balance := 12345678901234568}],
        all(where(kura_query:from(?AUTHOR), {name, ~"long"}))
    ),
    ?assertMatch(
        #{rows := [#{kind := ~"integer"}]},
        kura_db:query(
            ?REPO, ~"SELECT typeof(balance) AS kind FROM authors WHERE name = 'long'", []
        )
    ).

%% One value of every type SQLite stores goes through kura's dump, the
%% dialect and the driver's bind. Each is read back with a raw query, as
%% SQLite stores it, and the row is found by a condition on each value that
%% can be compared.
every_field_type_is_written_and_found(_Config) ->
    Written = #{
        int => 42,
        big => 9007199254740993,
        small => -7,
        ratio => 2.5,
        amount => 7,
        name => ~"Ada",
        body => ~"a longer text",
        bytes => <<0, 255, 1>>,
        active => true,
        day => {2024, 2, 29},
        wakes => {7, 30, 0},
        at => {{2024, 1, 2}, {3, 4, 5}},
        local_at => {{2024, 6, 7}, {8, 9, 10}},
        ref => ~"0192e4a0-7b1a-7c3e-8f00-000000000001",
        doc => #{~"k" => [1, true]},
        role => admin,
        token => ~"hidden",
        label => ~"custom text",
        raw => <<1, 2, 0>>
    },
    Stored = #{
        int => {~"integer", 42},
        big => {~"integer", 9007199254740993},
        small => {~"integer", -7},
        ratio => {~"real", 2.5},
        amount => {~"integer", 7},
        name => {~"text", ~"Ada"},
        body => {~"text", ~"a longer text"},
        bytes => {~"blob", <<0, 255, 1>>},
        active => {~"integer", 1},
        day => {~"text", ~"2024-02-29"},
        wakes => {~"text", ~"07:30:00"},
        at => {~"text", ~"2024-01-02 03:04:05"},
        local_at => {~"text", ~"2024-06-07 08:09:10"},
        ref => {~"text", ~"0192e4a0-7b1a-7c3e-8f00-000000000001"},
        doc => {~"text", ~"{\"k\":[1,true]}"},
        role => {~"text", ~"admin"},
        label => {~"text", ~"custom text"},
        raw => {~"blob", <<1, 2, 0>>}
    },
    ?assertEqual(
        lists:sort([id | maps:keys(Written)]),
        lists:sort(maps:keys(kura_schema:field_types(?EVERY)))
    ),
    {ok, #{id := Id}} = kura_repo_worker:insert(
        ?REPO, kura_changeset:cast(?EVERY, #{}, Written, maps:keys(Written))
    ),
    [
        ?assertEqual({Field, {Class, Value}}, {Field, stored(Field, Id)})
     || Field := {Class, Value} <- Stored
    ],
    ?assertMatch({~"blob", <<_/binary>>}, stored(token, Id)),
    ?assertNotEqual({~"blob", ~"hidden"}, stored(token, Id)),
    Compared = maps:without([doc, token], Written),
    [
        ?assertEqual(
            {Field, [#{id => Id}]},
            {Field, all(kura_query:select(where(kura_query:from(?EVERY), {Field, Value}), [id]))}
        )
     || Field := Value <- Compared
    ],
    {ok, 1} = kura_repo_worker:update_all(
        ?REPO, where(kura_query:from(?EVERY), {id, Id}), #{
            wakes => {23, 59, 60}, day => {1999, 12, 31}, active => false
        }
    ),
    ?assertEqual({~"text", ~"23:59:60"}, stored(wakes, Id)),
    ?assertEqual({~"text", ~"1999-12-31"}, stored(day, Id)),
    ?assertEqual({~"integer", 0}, stored(active, Id)),
    {ok, 1} = kura_repo_worker:insert_all(?REPO, ?EVERY, [maps:without([token], Written)]),
    ?assertEqual(
        {ok, 2},
        kura_repo_worker:count(
            ?REPO, where(kura_query:from(?EVERY), {wakes, in, [{7, 30, 0}, {23, 59, 60}]})
        )
    ).

get_get_by_and_reload(_Config) ->
    {ok, #{id := Id} = Author} = insert_author(#{name => ~"Ada", email => ~"ada@example.com"}),
    ?assertMatch({ok, #{id := Id}}, kura_repo_worker:get(?REPO, ?AUTHOR, Id)),
    ?assertEqual({error, not_found}, kura_repo_worker:get(?REPO, ?AUTHOR, Id + 1)),
    ?assertMatch(
        {ok, #{id := Id}}, kura_repo_worker:get_by(?REPO, ?AUTHOR, [{email, ~"ada@example.com"}])
    ),
    ?assertEqual(
        {error, not_found}, kura_repo_worker:get_by(?REPO, ?AUTHOR, [{email, ~"none"}])
    ),
    #{} = kura_db:query(?REPO, ~"UPDATE authors SET name = 'Lovelace' WHERE id = ?1", [Id]),
    ?assertMatch({ok, #{name := ~"Lovelace"}}, kura_repo_worker:reload(?REPO, ?AUTHOR, Author)).

update_stamps_and_keeps_the_rest(_Config) ->
    {ok, #{id := Id} = Author} = insert_author(#{name => ~"Ada", email => ~"ada@example.com"}),
    #{} = kura_db:query(
        ?REPO,
        ~"UPDATE authors SET updated_at = '2000-01-01 00:00:00', inserted_at = '2000-01-01 00:00:00' WHERE id = ?1",
        [Id]
    ),
    {ok, Old} = kura_repo_worker:get(?REPO, ?AUTHOR, Id),
    CS = kura_changeset:cast(?AUTHOR, Old, #{email => ~"countess@example.com"}, [email]),
    {ok, Updated} = kura_repo_worker:update(?REPO, CS),
    ?assertMatch(
        #{
            name := ~"Ada",
            email := ~"countess@example.com",
            inserted_at := {{2000, 1, 1}, {0, 0, 0}}
        },
        Updated
    ),
    ?assertNotEqual({{2000, 1, 1}, {0, 0, 0}}, maps:get(updated_at, Updated)),
    ?assertEqual(maps:get(lock_version, Author), maps:get(lock_version, Updated)),
    ?assertMatch(
        #{rows := [#{email_address := ~"countess@example.com"}]},
        kura_db:query(?REPO, ~"SELECT email_address FROM authors", [])
    ).

delete_removes_the_row(_Config) ->
    {ok, #{id := Id} = Author} = insert_author(#{name => ~"Ada"}),
    {ok, _} = insert_author(#{name => ~"Grace"}),
    {ok, _} = kura_repo_worker:delete(?REPO, kura_changeset:cast(?AUTHOR, Author, #{}, [])),
    ?assertEqual({error, not_found}, kura_repo_worker:get(?REPO, ?AUTHOR, Id)),
    ?assertEqual([~"Grace"], names(kura_query:from(?AUTHOR))).

%%----------------------------------------------------------------------
%% Conditions
%%----------------------------------------------------------------------

where_trees(_Config) ->
    seed_authors(),
    Cases = [
        {{age, '>', 40}, [~"Grace", ~"Linus"]},
        {{age, '>=', 36}, [~"Ada", ~"Grace", ~"Linus"]},
        {{age, '<', 36}, [~"Bob"]},
        {{age, '!=', 36}, [~"Bob", ~"Grace", ~"Linus"]},
        {{age, between, {30, 50}}, [~"Ada", ~"Bob"]},
        {{age, in, [36, 85]}, [~"Ada", ~"Grace"]},
        {{age, not_in, [36, 85]}, [~"Bob", ~"Linus"]},
        {{email, is_nil}, [~"Linus"]},
        {{email, is_not_nil}, [~"Ada", ~"Bob", ~"Grace"]},
        {{active, true}, [~"Ada", ~"Grace", ~"Linus"]},
        {{active, false}, [~"Bob"]},
        {{role, admin}, [~"Ada"]},
        {{role, '=', member}, [~"Bob", ~"Grace"]},
        {{born, '<', {1900, 1, 1}}, [~"Ada"]},
        {{'and', [{active, true}, {age, '>', 40}]}, [~"Grace", ~"Linus"]},
        {{'or', [{name, ~"Ada"}, {name, ~"Bob"}]}, [~"Ada", ~"Bob"]},
        {{'not', {name, ~"Ada"}}, [~"Bob", ~"Grace", ~"Linus"]},
        {
            {'or', [{'and', [{active, true}, {age, '<', 40}]}, {'not', {email, is_not_nil}}]},
            [~"Ada", ~"Linus"]
        },
        {{[name, age], in, [{~"Ada", 36}, {~"Bob", 1}]}, [~"Ada"]}
    ],
    [
        ?assertEqual(
            {Condition, Names}, {Condition, names(where(kura_query:from(?AUTHOR), Condition))}
        )
     || {Condition, Names} <- Cases
    ],
    Sub = kura_query:select(kura_query:where(kura_query:from(?AUTHOR), {age, '>', 40}), [id]),
    ?assertEqual(
        [~"Grace", ~"Linus"], names(where(kura_query:from(?AUTHOR), {id, in, {subquery, Sub}}))
    ).

empty_in_lists(_Config) ->
    seed_authors(),
    ?assertEqual([], names(where(kura_query:from(?AUTHOR), {age, in, []}))),
    ?assertEqual(
        [~"Ada", ~"Bob", ~"Grace", ~"Linus"],
        names(where(kura_query:from(?AUTHOR), {age, not_in, []}))
    ),
    ?assertEqual(
        [~"Ada", ~"Bob", ~"Grace", ~"Linus"],
        names(where(kura_query:from(?AUTHOR), {email, not_in, []}))
    ),
    ?assertEqual(
        [~"Ada"],
        names(where(kura_query:from(?AUTHOR), {'or', [{age, in, []}, {name, ~"Ada"}]}))
    ).

order_limit_and_offset(_Config) ->
    seed_authors(),
    Ordered = kura_query:order_by(kura_query:from(?AUTHOR), [{age, desc}]),
    ?assertEqual([~"Grace", ~"Linus", ~"Ada", ~"Bob"], ordered_names(Ordered)),
    ?assertEqual([~"Grace", ~"Linus"], ordered_names(kura_query:limit(Ordered, 2))),
    ?assertEqual(
        [~"Linus", ~"Ada"], ordered_names(kura_query:offset(kura_query:limit(Ordered, 2), 1))
    ),
    ?assertEqual([], ordered_names(kura_query:offset(kura_query:limit(Ordered, 2), 9))),
    ByTwo = kura_query:order_by(kura_query:from(?AUTHOR), [{active, asc}, {name, desc}]),
    ?assertEqual([~"Bob", ~"Linus", ~"Grace", ~"Ada"], ordered_names(ByTwo)).

like_patterns(_Config) ->
    seed_authors(),
    {ok, _} = insert_author(#{name => ~"100%_done"}),
    {ok, _} = insert_author(#{name => ~"100 percent"}),
    {ok, _} = insert_author(#{name => ~"back\\slash"}),
    ?assertEqual([~"Ada"], like(~"A%")),
    ?assertEqual([~"Ada", ~"Bob"], like(~"___")),
    ?assertEqual([~"100 percent", ~"100%_done"], like(~"100%")),
    ?assertEqual([~"100%_done"], like(~"100\\%\\_done")),
    ?assertEqual(
        [~"100%_done"], like(<<(kura_query:escape_like(~"100%_"))/binary, "%">>)
    ),
    ?assertEqual([~"back\\slash"], like(<<(kura_query:escape_like(<<"back\\">>))/binary, "%">>)),
    ?assertEqual([~"Ada"], names(where(kura_query:from(?AUTHOR), {name, ilike, ~"a%"}))).

literal_text_matches(_Config) ->
    Names = [
        ~"100%_done",
        ~"100 percent",
        ~"a*b",
        ~"a?b",
        ~"a[b]",
        ~"a]b",
        ~"a!b",
        ~"a\\b",
        ~"axb",
        ~"AXB",
        ~"it's",
        ~"ünï"
    ],
    [{ok, _} = insert_author(#{name => Name}) || Name <- Names],
    Matches = fun(Op, Text) -> names(where(kura_query:from(?AUTHOR), {name, Op, Text})) end,
    [
        ?assertEqual(
            {Op, Text, lists:sort([Name || Name <- Names, literal_match(Op, Text, Name)])},
            {Op, Text, Matches(Op, Text)}
        )
     || Op <- [contains, starts_with, ends_with],
        Text <- [
            ~"%",
            ~"_",
            ~"*",
            ~"?",
            ~"[",
            ~"]",
            ~"[b]",
            ~"!",
            <<"\\">>,
            ~"'",
            ~"x",
            ~"X",
            ~"a",
            ~"b",
            ~"100%",
            ~"ï",
            ~"a*b",
            ~""
        ]
    ],
    ?assertEqual([], Matches(contains, undefined)).

%% SQLite folds the 26 ASCII letters and nothing else.
text_matches_fold_ascii_only(_Config) ->
    [{ok, _} = insert_author(#{name => Name}) || Name <- [~"Ada%", ~"ADAM", ~"Ångström"]],
    Matches = fun(Op, Text) -> names(where(kura_query:from(?AUTHOR), {name, Op, Text})) end,
    ?assertEqual([~"ADAM", ~"Ada%"], Matches(icontains, ~"da")),
    ?assertEqual([~"ADAM", ~"Ada%"], Matches(istarts_with, ~"ad")),
    ?assertEqual([~"Ada%"], Matches(icontains, ~"A%")),
    ?assertEqual([~"Ada%"], Matches(iends_with, ~"a%")),
    ?assertEqual([~"ADAM"], Matches(iends_with, ~"dam")),
    ?assertEqual([~"Ångström"], Matches(icontains, ~"STR")),
    ?assertEqual([~"Ångström"], Matches(istarts_with, ~"Å")),
    ?assertEqual([], Matches(istarts_with, ~"å")),
    ?assertEqual([~"ADAM", ~"Ada%"], Matches(ilike, ~"ada%")),
    ?assertEqual([~"ADAM", ~"Ada%"], Matches(like, ~"ada%")).

%%----------------------------------------------------------------------
%% Joins, preloads and aggregates
%%----------------------------------------------------------------------

joins(_Config) ->
    {Ada, Bob} = seed_posts(),
    Inner = kura_query:join(kura_query:from(?POST), inner, ?AUTHOR, {author_id, id}),
    ?assertEqual(
        [~"first", ~"second"],
        titles(where(Inner, {name, ~"Ada"}))
    ),
    ?assertEqual([~"second"], titles(where(Inner, {views, '>', 5}))),
    ?assertEqual(
        [~"third"],
        titles(where(Inner, {'and', [{title, like, ~"t%"}, {name, like, ~"B%"}]}))
    ),
    ?assertEqual([~"first"], titles(where(Inner, {modified_at, is_not_nil}), {title, ~"first"})),
    Left = kura_query:join(kura_query:from(?AUTHOR), left, ?POST, {id, author_id}),
    {ok, #{id := Grace}} = kura_repo_worker:get_by(?REPO, ?AUTHOR, [{name, ~"Grace"}]),
    ?assertEqual(
        lists:sort([maps:get(id, Ada), maps:get(id, Ada), maps:get(id, Bob), Grace]),
        lists:sort([
            Id
         || #{id := Id} <- all(kura_query:select(where(Left, {email, is_not_nil}), [id]))
        ])
    ),
    {ok, #{id := Third}} = kura_repo_worker:get_by(?REPO, ?POST, [{title, ~"third"}]),
    ?assertEqual(
        [#{id => Third, title => ~"third"}],
        all(kura_query:select(where(Inner, {name, ~"Bob"}), [id, title]))
    ),
    Selected = kura_query:select(where(Inner, {modified_at, is_not_nil}), [title, modified_at]),
    ?assertMatch([#{title := _, modified_at := {{_, _, _}, {_, _, _}}} | _], all(Selected)).

preloads(_Config) ->
    {#{id := AdaId}, #{id := BobId}} = seed_posts(),
    {ok, Authors} = kura_repo_worker:all(
        ?REPO,
        kura_query:preload(kura_query:order_by(kura_query:from(?AUTHOR), [{id, asc}]), [posts])
    ),
    ?assertEqual(
        [{AdaId, [~"first", ~"second"]}, {BobId, [~"third"]}],
        [
            {Id, lists:sort([Title || #{title := Title} <- Posts])}
         || #{id := Id, posts := [_ | _] = Posts} <- Authors
        ]
    ),
    {ok, Posts} = kura_repo_worker:all(
        ?REPO,
        kura_query:preload(kura_query:order_by(kura_query:from(?POST), [{title, asc}]), [
            author, tags
        ])
    ),
    ?assertEqual(
        [
            {~"first", ~"Ada", [~"erlang", ~"sqlite"]},
            {~"second", ~"Ada", [~"erlang"]},
            {~"third", ~"Bob", []}
        ],
        [
            {Title, Name, lists:sort([Tag || #{name := Tag} <- Tags])}
         || #{title := Title, author := #{name := Name}, tags := Tags} <- Posts
        ]
    ),
    {ok, Post} = kura_repo_worker:get_by(?REPO, ?POST, [{title, ~"first"}]),
    ?assertMatch(
        #{author := #{email := ~"ada@example.com"}},
        kura_repo_worker:preload(?REPO, ?POST, Post, [author])
    ).

aggregates(_Config) ->
    seed_authors(),
    Q = kura_query:from(?AUTHOR),
    ?assertEqual({ok, 4}, kura_repo_worker:count(?REPO, Q)),
    ?assertEqual({ok, 3}, kura_repo_worker:count(?REPO, where(Q, {active, true}))),
    ?assertEqual({ok, 3}, kura_repo_worker:aggregate(?REPO, Q, {count, email})),
    ?assertEqual({ok, 36 + 31 + 85 + 55}, kura_repo_worker:aggregate(?REPO, Q, {sum, age})),
    ?assertEqual({ok, 31}, kura_repo_worker:aggregate(?REPO, Q, {min, age})),
    ?assertEqual({ok, 85}, kura_repo_worker:aggregate(?REPO, Q, {max, age})),
    ?assertEqual({ok, 51.75}, kura_repo_worker:aggregate(?REPO, Q, {avg, age})),
    Nobody = where(Q, {age, '>', 200}),
    ?assertEqual({ok, 0}, kura_repo_worker:count(?REPO, Nobody)),
    ?assertEqual({ok, 0}, kura_repo_worker:aggregate(?REPO, Nobody, {sum, age}, 0)),
    ?assertEqual({ok, true}, kura_repo_worker:exists(?REPO, where(Q, {name, ~"Ada"}))),
    ?assertEqual({ok, false}, kura_repo_worker:exists(?REPO, Nobody)),
    ?assertMatch({ok, #{name := ~"Ada"}}, kura_repo_worker:one(?REPO, where(Q, {name, ~"Ada"}))),
    ?assertEqual({error, not_found}, kura_repo_worker:one(?REPO, Nobody)).

group_by_and_having(_Config) ->
    seed_authors(),
    Grouped = kura_query:group_by(
        kura_query:select_expr(kura_query:from(?AUTHOR), [
            {role, role}, {members, {fragment, ~"count(*)", []}}
        ]),
        [role]
    ),
    Rows = all(kura_query:order_by(Grouped, [{role, asc}])),
    ?assertEqual(
        [{undefined, 1}, {admin, 1}, {member, 2}],
        [{Role, Members} || #{role := Role, members := Members} <- Rows]
    ),
    Having = kura_query:having(Grouped, {fragment, ~"count(*) > ?", [1]}),
    ?assertMatch([#{members := 2}], all(Having)),
    ?assertEqual(
        [#{active => false}, #{active => true}],
        all(
            kura_query:order_by(
                kura_query:distinct(kura_query:select(kura_query:from(?AUTHOR), [active])),
                [{active, asc}]
            )
        )
    ).

window_functions(_Config) ->
    seed_authors(),
    Ranked = kura_query:select_expr(kura_query:from(?AUTHOR), [
        {name, name},
        {position,
            kura_query:over(row_number, #{partition_by => [active], order_by => [{age, desc}]})},
        {total, kura_query:over({sum, age}, #{partition_by => [active]})}
    ]),
    ?assertEqual(
        [{~"Ada", 3, 176}, {~"Bob", 1, 31}, {~"Grace", 1, 176}, {~"Linus", 2, 176}],
        lists:sort([
            {Name, Position, Total}
         || #{name := Name, position := Position, total := Total} <- all(Ranked)
        ])
    ).

ctes_and_combinations(_Config) ->
    seed_authors(),
    Old = kura_query:select(where(kura_query:from(?AUTHOR), {age, '>', 50}), [id, name]),
    Cte = kura_query:with_cte(kura_query:from(elders), ~"elders", Old),
    ?assertEqual(
        [~"Grace", ~"Linus"], lists:sort([Name || #{name := Name} <- all(Cte)])
    ),
    Young = kura_query:select(where(kura_query:from(?AUTHOR), {age, '<', 35}), [id, name]),
    Names = fun(Q) -> lists:sort([Name || #{name := Name} <- all(Q)]) end,
    ?assertEqual([~"Bob", ~"Grace", ~"Linus"], Names(kura_query:union(Old, Young))),
    ?assertEqual([~"Grace", ~"Grace", ~"Linus", ~"Linus"], Names(kura_query:union_all(Old, Old))),
    ?assertEqual([~"Grace", ~"Linus"], Names(kura_query:intersect(Old, Old))),
    ?assertEqual([], Names(kura_query:except(Old, Old))).

%%----------------------------------------------------------------------
%% Transactions
%%----------------------------------------------------------------------

transaction_commits_and_rolls_back(_Config) ->
    {ok, _} = kura_repo_worker:transaction(?REPO, fun() ->
        {ok, _} = insert_author(#{name => ~"Ada"}),
        {ok, done}
    end),
    ?assertEqual([~"Ada"], names(kura_query:from(?AUTHOR))),
    ?assertError(
        boom,
        kura_repo_worker:transaction(?REPO, fun() ->
            {ok, _} = insert_author(#{name => ~"Grace"}),
            error(boom)
        end)
    ),
    ?assertEqual([~"Ada"], names(kura_query:from(?AUTHOR))).

nested_transaction_rolls_back_to_its_savepoint(_Config) ->
    {ok, _} = kura_repo_worker:transaction(?REPO, fun() ->
        {ok, _} = insert_author(#{name => ~"Ada"}),
        ?assertError(
            inner,
            kura_repo_worker:transaction(?REPO, fun() ->
                {ok, _} = insert_author(#{name => ~"Bob"}),
                error(inner)
            end)
        ),
        {ok, _} = kura_repo_worker:transaction(?REPO, fun() ->
            {ok, _} = insert_author(#{name => ~"Grace"}),
            {ok, inner}
        end),
        {ok, outer}
    end),
    ?assertEqual([~"Ada", ~"Grace"], names(kura_query:from(?AUTHOR))).

multi_runs_in_one_transaction(_Config) ->
    Author = fun(Name) -> author_changeset(#{name => Name}) end,
    Ok = kura_multi:insert(
        kura_multi:insert(kura_multi:new(), ada, Author(~"Ada")), bob, Author(~"Bob")
    ),
    ?assertMatch(
        {ok, #{ada := #{name := ~"Ada"}, bob := #{id := _}}}, kura_repo_worker:multi(?REPO, Ok)
    ),
    Failing = kura_multi:run(
        kura_multi:insert(kura_multi:new(), grace, Author(~"Grace")), refuse, fun(_) ->
            {error, refused}
        end
    ),
    ?assertMatch({error, refuse, refused, _}, kura_repo_worker:multi(?REPO, Failing)),
    ?assertEqual([~"Ada", ~"Bob"], names(kura_query:from(?AUTHOR))).

%%----------------------------------------------------------------------
%% Bulk writes
%%----------------------------------------------------------------------

insert_all_empty_and_uneven(_Config) ->
    ?assertEqual({ok, 0}, kura_repo_worker:insert_all(?REPO, ?NOTE, [])),
    ?assertEqual({ok, 0, []}, kura_repo_worker:insert_all(?REPO, ?NOTE, [], #{returning => true})),
    ?assertMatch(
        {error, {entries_differ, _, _}},
        kura_repo_worker:insert_all(?REPO, ?NOTE, [#{org_id => 1, body => ~"a"}, #{org_id => 2}])
    ),
    ?assertEqual({ok, 0}, kura_repo_worker:count(?REPO, kura_query:from(?NOTE))).

insert_all_returning(_Config) ->
    Entries = [#{org_id => N, body => integer_to_binary(N)} || N <- lists:seq(1, 3)],
    {ok, 3, Rows} = kura_repo_worker:insert_all(?REPO, ?NOTE, Entries, #{returning => true}),
    ?assertEqual([~"1", ~"2", ~"3"], lists:sort([Body || #{id := _, body := Body} <- Rows])),
    {ok, 1, [Row]} = kura_repo_worker:insert_all(
        ?REPO, ?AUTHOR, [#{name => ~"Ada", email => ~"ada@example.com"}], #{
            returning => [id, email]
        }
    ),
    ?assertMatch(#{id := _, email := ~"ada@example.com"}, Row).

%% Two values an entry: 16383 entries bind 32766 values, the most one
%% statement takes.
insert_all_at_the_parameter_limit(_Config) ->
    Entries = fun(Count) -> [#{org_id => N, body => ~"n"} || N <- lists:seq(1, Count)] end,
    ?assertEqual({ok, 5000}, kura_repo_worker:insert_all(?REPO, ?NOTE, Entries(5000))),
    ?assertEqual({ok, 16383}, kura_repo_worker:insert_all(?REPO, ?NOTE, Entries(16383))),
    ?assertEqual({ok, 21383}, kura_repo_worker:count(?REPO, kura_query:from(?NOTE))),
    ?assertError(
        {kura, {too_many_parameters, 32768, 32766}},
        kura_repo_worker:insert_all(?REPO, ?NOTE, Entries(16384))
    ),
    ?assertError(
        {kura, {too_many_parameters, 32768, 32766}},
        kura_repo_worker:insert_all(?REPO, ?NOTE, Entries(16384), #{returning => true})
    ),
    ?assertEqual({ok, 21383}, kura_repo_worker:count(?REPO, kura_query:from(?NOTE))).

upsert(_Config) ->
    {ok, #{id := Id}} = insert_author(#{name => ~"Ada", email => ~"ada@example.com", age => 36}),
    Again = author_changeset(#{name => ~"Countess", email => ~"ada@example.com", age => 37}),
    {ok, _} = kura_repo_worker:insert(?REPO, Again, #{on_conflict => {email, nothing}}),
    ?assertMatch({ok, #{name := ~"Ada", age := 36}}, kura_repo_worker:get(?REPO, ?AUTHOR, Id)),
    {ok, Replaced} = kura_repo_worker:insert(?REPO, Again, #{
        on_conflict => {email, {replace, [name]}}
    }),
    ?assertMatch(#{id := Id, name := ~"Countess", age := 36}, Replaced),
    {ok, All} = kura_repo_worker:insert(?REPO, Again, #{on_conflict => {email, replace_all}}),
    ?assertMatch(#{id := Id, name := ~"Countess", age := 37}, All),
    ?assertEqual({ok, 1}, kura_repo_worker:count(?REPO, kura_query:from(?AUTHOR))),
    ?assertMatch(
        {error, _},
        kura_repo_worker:insert(
            ?REPO, author_changeset(#{name => ~"Dup", email => ~"ada@example.com"})
        )
    ).

upsert_all(_Config) ->
    {ok, 2} = kura_repo_worker:insert_all(?REPO, ?TAG, [#{name => ~"erlang"}, #{name => ~"sqlite"}]),
    {ok, 1} = kura_repo_worker:insert_all(
        ?REPO, ?TAG, [#{name => ~"erlang"}, #{name => ~"otp"}], #{on_conflict => {name, nothing}}
    ),
    ?assertEqual({ok, 3}, kura_repo_worker:count(?REPO, kura_query:from(?TAG))),
    {ok, 1} = kura_repo_worker:insert_all(
        ?REPO, ?AUTHOR, [#{name => ~"Ada", email => ~"ada@example.com", age => 1}]
    ),
    {ok, 2, Rows} = kura_repo_worker:insert_all(
        ?REPO,
        ?AUTHOR,
        [
            #{name => ~"Countess", email => ~"ada@example.com", age => 2},
            #{name => ~"Bob", email => ~"bob@example.com", age => 3}
        ],
        #{on_conflict => {email, {replace, [name]}}, returning => [name, age]}
    ),
    ?assertEqual(
        [#{name => ~"Bob", age => 3}, #{name => ~"Countess", age => 1}],
        lists:sort(fun(#{name := A}, #{name := B}) -> A =< B end, Rows)
    ).

update_all_and_delete_all(_Config) ->
    seed_authors(),
    Q = kura_query:from(?AUTHOR),
    ?assertEqual(
        {ok, 2},
        kura_repo_worker:update_all(?REPO, where(Q, {role, member}), #{
            email => undefined, active => false, score => 1.5
        })
    ),
    ?assertEqual([~"Bob", ~"Grace"], names(where(Q, {score, 1.5}))),
    ?assertEqual([~"Ada", ~"Linus"], names(where(Q, {active, true}))),
    ?assertMatch(
        #{rows := [#{n := 3}]},
        kura_db:query(?REPO, ~"SELECT count(*) AS n FROM authors WHERE email_address IS NULL", [])
    ),
    ?assertEqual({ok, 2}, kura_repo_worker:delete_all(?REPO, where(Q, {score, '>', 1.0}))),
    ?assertEqual([~"Ada", ~"Linus"], names(Q)),
    ?assertEqual({ok, 0}, kura_repo_worker:delete_all(?REPO, where(Q, {age, in, []}))),
    ?assertEqual([~"Ada", ~"Linus"], names(Q)).

pagination(_Config) ->
    {ok, 25} = kura_repo_worker:insert_all(
        ?REPO, ?NOTE, [#{org_id => N, body => ~"n"} || N <- lists:seq(1, 25)]
    ),
    Q = kura_query:order_by(kura_query:from(?NOTE), [{org_id, asc}]),
    {ok, Page} = kura_paginator:paginate(?REPO, Q, #{page => 3, page_size => 10}),
    ?assertMatch(#{page := 3, page_size := 10, total_entries := 25, total_pages := 3}, Page),
    ?assertEqual([21, 22, 23, 24, 25], [Org || #{org_id := Org} <- maps:get(entries, Page)]),
    {ok, Past} = kura_paginator:paginate(?REPO, Q, #{page => 9, page_size => 10}),
    ?assertEqual([], maps:get(entries, Past)),
    ?assertMatch({error, _}, kura_paginator:paginate(?REPO, Q, #{page => 0})),
    {ok, First} = kura_paginator:cursor_paginate(?REPO, kura_query:from(?NOTE), #{
        limit => 10, cursor_field => org_id
    }),
    ?assertEqual(lists:seq(1, 10), [Org || #{org_id := Org} <- maps:get(entries, First)]),
    ?assertMatch(#{has_next := true}, First),
    {ok, Next} = kura_paginator:cursor_paginate(?REPO, kura_query:from(?NOTE), #{
        limit => 20, cursor_field => org_id, 'after' => 10
    }),
    ?assertEqual(lists:seq(11, 25), [Org || #{org_id := Org} <- maps:get(entries, Next)]),
    ?assertMatch(#{has_next := false}, Next).

%% kura_stream declares a server-side cursor, which SQLite does not have, so
%% kura refuses before it runs a statement.
stream_needs_server_cursors(_Config) ->
    {ok, 3} = kura_repo_worker:insert_all(
        ?REPO, ?NOTE, [#{org_id => N, body => ~"n"} || N <- lists:seq(1, 3)]
    ),
    Collector = self(),
    ?assertError(
        ?UNSUPPORTED(cursors),
        kura_stream:stream(
            ?REPO,
            kura_query:from(?NOTE),
            fun(Batch) ->
                Collector ! {batch, Batch},
                ok
            end
        )
    ),
    ?assertEqual([], batches()),
    ?assertEqual({ok, 3}, kura_repo_worker:count(?REPO, kura_query:from(?NOTE))).

%%----------------------------------------------------------------------
%% Field kinds
%%----------------------------------------------------------------------

embedded_schema(_Config) ->
    CS = kura_changeset:cast_embed(
        kura_changeset:cast(
            ?AUTHOR,
            #{},
            #{name => ~"Ada", address => #{street => ~"12 St James's Square", city => ~"London"}},
            [name]
        ),
        address,
        #{cast => [street, city]}
    ),
    {ok, #{id := Id} = Author} = kura_repo_worker:insert(?REPO, CS),
    ?assertMatch(#{address := #{street := ~"12 St James's Square", city := ~"London"}}, Author),
    {ok, Read} = kura_repo_worker:get(?REPO, ?AUTHOR, Id),
    ?assertEqual(
        #{street => ~"12 St James's Square", city => ~"London"}, maps:get(address, Read)
    ),
    #{rows := [#{address := Stored}]} = kura_db:query(
        ?REPO, ~"SELECT address FROM authors WHERE id = ?1", [Id]
    ),
    ?assertEqual(
        #{~"street" => ~"12 St James's Square", ~"city" => ~"London"}, json:decode(Stored)
    ).

encrypted_fields(_Config) ->
    {ok, #{id := Id} = Secret} = insert_secret(#{
        label => ~"a", pin => ~"1234", token => ~"tok-plain", ssn => ~"19121212-1212"
    }),
    {ok, _} = insert_secret(#{label => ~"b", token => ~"other", ssn => ~"20000101-0000"}),
    ?assertMatch(#{token := ~"tok-plain", ssn := ~"19121212-1212"}, Secret),
    #{rows := [Raw]} = kura_db:query(
        ?REPO,
        ~"SELECT typeof(token) AS token_type, typeof(ssn) AS ssn_type, token, ssn FROM secrets WHERE id = ?1",
        [Id]
    ),
    ?assertMatch(#{token_type := ~"blob", ssn_type := ~"blob"}, Raw),
    ?assertEqual(nomatch, binary:match(maps:get(token, Raw), ~"tok-plain")),
    ?assertEqual(nomatch, binary:match(maps:get(ssn, Raw), ~"19121212")),
    ?assertMatch(
        {ok, #{token := ~"tok-plain", ssn := ~"19121212-1212"}},
        kura_repo_worker:get(?REPO, ?SECRET, Id)
    ),
    Q = kura_query:from(?SECRET),
    Labels = fun(Condition) ->
        lists:sort([Label || #{label := Label} <- all(where(Q, Condition))])
    end,
    ?assertEqual([~"a"], Labels({ssn, ~"19121212-1212"})),
    ?assertEqual([~"b"], Labels({ssn, '!=', ~"19121212-1212"})),
    ?assertEqual([~"a", ~"b"], Labels({ssn, in, [~"19121212-1212", ~"20000101-0000"]})),
    ?assertEqual([], Labels({ssn, ~"missing"})),
    ?assertMatch(
        {ok, #{label := ~"a"}}, kura_repo_worker:get_by(?REPO, ?SECRET, [{ssn, ~"19121212-1212"}])
    ),
    ?assertError({kura, {encrypted_field_in_where, token}}, where(Q, {token, ~"tok-plain"})),
    ?assertEqual(ok, kura_sqlite:check_blob_columns(?REPO, [?SECRET])).

renamed_byte_column(_Config) ->
    Bytes = <<0, 255, 128, $a>>,
    {ok, #{id := Id}} = insert_secret(#{label => ~"a", raw => Bytes}),
    {ok, _} = insert_secret(#{label => ~"b", raw => ~"other"}),
    ?assertMatch(
        #{rows := [#{kind := ~"blob"}]},
        kura_db:query(?REPO, ~"SELECT typeof(raw_bytes) AS kind FROM secrets WHERE id = ?1", [Id])
    ),
    Q = kura_query:from(?SECRET),
    Labels = fun(Condition) ->
        lists:sort([Label || #{label := Label} <- all(where(Q, Condition))])
    end,
    ?assertEqual([~"a"], Labels({raw, Bytes})),
    ?assertEqual([~"b"], Labels({raw, '!=', Bytes})),
    ?assertEqual([~"a"], Labels({raw, in, [Bytes]})),
    ?assertEqual([~"a", ~"b"], Labels({raw, between, {<<0>>, ~"z"}})),
    ?assertEqual({ok, 1}, kura_repo_worker:delete_all(?REPO, where(Q, {raw, Bytes}))),
    ?assertEqual(ok, kura_sqlite:check_blob_columns(?REPO, [?SECRET])),
    ok = kura_repo_worker:transaction(?REPO, fun() ->
        #{} = kura_db:query(?REPO, ~"PRAGMA ignore_check_constraints = ON", []),
        #{} = kura_db:query(?REPO, ~"UPDATE secrets SET raw_bytes = 'text'", []),
        ok
    end),
    ?assertEqual(
        {error, [{text_in_blob_column, ~"secrets", raw}]},
        kura_sqlite:check_blob_columns(?REPO, [?SECRET])
    ).

redacted_values_stay_out_of_telemetry(_Config) ->
    Collector = self(),
    ok = telemetry:attach(
        ?TELEMETRY,
        [kura, repo, query],
        fun(_Event, _Measurements, Metadata, _Handler) -> Collector ! {query, Metadata} end,
        undefined
    ),
    try
        {ok, _} = insert_secret(#{label => ~"a", pin => ~"1234", token => ~"tok-plain"}),
        {ok, _} = kura_repo_worker:get_by(?REPO, ?SECRET, [{pin, ~"1234"}]),
        Seen = iolist_to_binary(io_lib:format("~0p", [queries()])),
        ?assertNotEqual(nomatch, binary:match(Seen, ~"secrets")),
        ?assertEqual(nomatch, binary:match(Seen, ~"1234")),
        ?assertEqual(nomatch, binary:match(Seen, ~"tok-plain"))
    after
        telemetry:detach(?TELEMETRY)
    end.

%% SQLite names what a constraint refused in a message alone. The driver
%% reads it, so kura reports the violation where it does on PostgreSQL.
constraint_errors_land_on_their_field(_Config) ->
    with_members(fun() ->
        {ok, #{id := AuthorId}} = insert_author(#{name => ~"Ada", email => ~"ada@example.com"}),
        Errors = fun({error, #kura_changeset{valid = false, errors = Errors}}) -> Errors end,
        Member = fun(Params) -> kura_changeset:cast(?MEMBER, #{}, Params, maps:keys(Params)) end,
        Insert = fun(Params) -> kura_repo_worker:insert(?REPO, Member(Params)) end,
        First = #{org_id => 1, handle => ~"ada", slug => ~"a", level => 1, author_id => AuthorId},
        {ok, #{id := Id}} = Insert(First),
        {ok, Other} = Insert(#{org_id => 1, handle => ~"bob", slug => ~"b"}),

        ?assertEqual(
            [{email, ~"has already been taken"}],
            Errors(insert_author(#{name => ~"Other", email => ~"ada@example.com"}))
        ),
        ?assertEqual([{name, ~"can't be blank"}], Errors(insert_author(#{age => 1}))),
        ?assertEqual(
            [{id, ~"has already been taken"}],
            Errors(insert_author(#{id => AuthorId, name => ~"Again"}))
        ),

        ?assertEqual(
            [{handle, ~"has already been taken"}],
            Errors(Insert(#{org_id => 2, handle => ~"ada", slug => ~"c"}))
        ),
        ?assertEqual(
            [{handle, ~"is in use"}],
            Errors(
                kura_repo_worker:insert(
                    ?REPO,
                    kura_changeset:unique_constraint(
                        Member(#{org_id => 2, handle => ~"ada"}),
                        handle,
                        #{name => ~"team members_user handle_index", message => ~"is in use"}
                    )
                )
            )
        ),
        ?assertEqual(
            [{handle, ~"has already been taken"}],
            Errors(
                kura_repo_worker:update(
                    ?REPO, kura_changeset:cast(?MEMBER, Other, #{handle => ~"ada"}, [handle])
                )
            )
        ),
        ?assertEqual(
            [{handle, ~"can't be blank"}], Errors(Insert(#{org_id => 2, slug => ~"c"}))
        ),
        ?assertEqual(
            [{id, ~"has already been taken"}],
            Errors(Insert(#{id => Id, org_id => 2, handle => ~"cy"}))
        ),
        ?assertEqual(
            [{org_id, ~"has already been taken"}],
            Errors(Insert(#{org_id => 1, handle => ~"cy", slug => ~"a"}))
        ),
        ?assertEqual(
            [{base, ~"has already been taken"}],
            Errors(Insert(#{org_id => 1, handle => ~"cy", level => 1}))
        ),
        ?assertEqual(
            [{base, ~"is invalid"}], Errors(Insert(#{org_id => 2, handle => ~"cy", level => 0}))
        ),
        ?assertEqual(
            [{level, ~"must be positive"}],
            Errors(
                kura_repo_worker:insert(
                    ?REPO,
                    kura_changeset:check_constraint(
                        Member(#{org_id => 2, handle => ~"cy", level => 0}),
                        ~"level_is_positive",
                        level,
                        #{message => ~"must be positive"}
                    )
                )
            )
        ),
        ?assertEqual(
            [{base, ~"FOREIGN KEY constraint failed"}],
            Errors(Insert(#{org_id => 2, handle => ~"cy", author_id => AuthorId + 1}))
        ),
        ?assertEqual(
            {ok, 2}, kura_repo_worker:count(?REPO, kura_query:from(?MEMBER))
        )
    end).

%% The message and the SQLite code stay with the caller: telemetry gets the
%% code and the names, as it does for a PostgreSQL error.
constraint_errors_reach_telemetry_without_their_message(_Config) ->
    {ok, _} = insert_author(#{name => ~"Ada", email => ~"ada@example.com"}),
    Collector = self(),
    ok = telemetry:attach(
        ?TELEMETRY,
        [kura, repo, query],
        fun(_Event, _Measurements, Metadata, _Handler) -> Collector ! {query, Metadata} end,
        undefined
    ),
    try
        {error, _} = insert_author(#{name => ~"Other", email => ~"ada@example.com"}),
        ?assertMatch(
            {error,
                {pgsql_error, #{
                    code := ~"23505",
                    message := ~"UNIQUE constraint failed: authors.email_address",
                    sqlite_code := 2067
                }}},
            kura_db:query(
                ?REPO, ~"INSERT INTO authors (name, email_address) VALUES ('x', ?1)", [
                    ~"ada@example.com"
                ]
            )
        ),
        Reported = #{
            code => ~"23505", table => ~"authors", constraint => ~"authors_email_address_index"
        },
        ?assertEqual(
            [{pgsql_error, Reported}, {pgsql_error, Reported}],
            [Reason || #{result := error, error_reason := Reason} <- queries()]
        )
    after
        telemetry:detach(?TELEMETRY)
    end.

with_members(Test) ->
    #{} = kura_db:query(
        ?REPO,
        ~"""
        CREATE TABLE "team members" (
            id INTEGER PRIMARY KEY,
            org_id INTEGER,
            "user handle" TEXT NOT NULL,
            slug TEXT,
            level INTEGER CONSTRAINT level_is_positive CHECK (level > 0),
            author_id INTEGER REFERENCES authors (id)
        )
        """,
        []
    ),
    try
        run_operation({create_index, ~"team members", ['user handle'], #{unique => true}}),
        run_operation({create_index, ~"team members", [org_id, slug], #{unique => true}}),
        run_operation({create_index, ~"team members", [org_id, level], #{unique => true}}),
        Test()
    after
        #{} = kura_db:query(?REPO, ~"DROP TABLE \"team members\"", [])
    end.

optimistic_locking(_Config) ->
    {ok, #{lock_version := 1} = Author} = insert_author(#{name => ~"Ada"}),
    Rename = fun(Record, Name) ->
        kura_changeset:optimistic_lock(
            kura_changeset:cast(?AUTHOR, Record, #{name => Name}, [name]), lock_version
        )
    end,
    {ok, Updated} = kura_repo_worker:update(?REPO, Rename(Author, ~"Countess")),
    ?assertMatch(#{name := ~"Countess", lock_version := 2}, Updated),
    ?assertEqual({error, stale}, kura_repo_worker:update(?REPO, Rename(Author, ~"Stale"))),
    ?assertMatch(
        {ok, #{name := ~"Countess", lock_version := 2}},
        kura_repo_worker:get(?REPO, ?AUTHOR, maps:get(id, Author))
    ).

custom_and_absent_timestamps(_Config) ->
    {ok, #{id := Id} = Post} = insert_post(#{title => ~"first"}),
    ?assertMatch(
        #{created_at := {{_, _, _}, {_, _, _}}, modified_at := {{_, _, _}, {_, _, _}}}, Post
    ),
    #{} = kura_db:query(
        ?REPO,
        ~"UPDATE posts SET changed_at = '2000-01-01 00:00:00', created_at = '2000-01-01 00:00:00'",
        []
    ),
    {ok, Old} = kura_repo_worker:get(?REPO, ?POST, Id),
    {ok, Updated} = kura_repo_worker:update(
        ?REPO, kura_changeset:cast(?POST, Old, #{title => ~"edited"}, [title])
    ),
    ?assertMatch(#{created_at := {{2000, 1, 1}, {0, 0, 0}}}, Updated),
    ?assertNotEqual({{2000, 1, 1}, {0, 0, 0}}, maps:get(modified_at, Updated)),
    ?assertMatch(
        #{rows := [#{n := 1}]},
        kura_db:query(
            ?REPO,
            ~"SELECT count(*) AS n FROM posts WHERE changed_at > '2000-01-01 00:00:00'",
            []
        )
    ),
    {ok, Tag} = kura_repo_worker:insert(
        ?REPO, kura_changeset:cast(?TAG, #{}, #{name => ~"erlang"}, [name])
    ),
    %% Until kura 3.0 an empty timestamps/0 keeps these two stamped.
    ?assertMatch(
        #{inserted_at := {{_, _, _}, {_, _, _}}, updated_at := {{_, _, _}, {_, _, _}}}, Tag
    ).

%%----------------------------------------------------------------------
%% Tenants
%%----------------------------------------------------------------------

attribute_tenant(_Config) ->
    {ok, 3} = kura_repo_worker:insert_all(?REPO, ?NOTE, [
        #{org_id => 1, body => ~"one"},
        #{org_id => 1, body => ~"uno"},
        #{org_id => 2, body => ~"two"}
    ]),
    Q = kura_query:from(?NOTE),
    Bodies = fun(Query) -> lists:sort([Body || #{body := Body} <- all(Query)]) end,
    kura_tenant:with_tenant({attribute, {org_id, 1}}, fun() ->
        ?assertEqual([~"one", ~"uno"], Bodies(Q)),
        ?assertEqual({ok, 2}, kura_repo_worker:count(?REPO, Q)),
        ?assertEqual({ok, 2}, kura_repo_worker:update_all(?REPO, Q, #{body => ~"mine"})),
        ?assertEqual({ok, 0}, kura_repo_worker:delete_all(?REPO, where(Q, {body, ~"two"})))
    end),
    kura_tenant:with_tenant({attribute, {org_id, 2}}, fun() ->
        ?assertEqual([~"two"], Bodies(Q))
    end),
    ?assertEqual([~"mine", ~"mine", ~"two"], Bodies(Q)).

%% A prefix names a schema, which in SQLite is an attached database. `main`
%% is the file the pool opened.
prefix_tenant(_Config) ->
    {ok, 1} = kura_repo_worker:insert_all(?REPO, ?NOTE, [#{org_id => 1, body => ~"one"}]),
    Q = kura_query:from(?NOTE),
    kura_tenant:with_tenant({prefix, ~"main"}, fun() ->
        ?assertMatch([#{body := ~"one"}], all(Q)),
        {ok, _} = kura_repo_worker:insert(
            ?REPO, kura_changeset:cast(?NOTE, #{}, #{org_id => 2, body => ~"two"}, [org_id, body])
        )
    end),
    ?assertEqual({ok, 2}, kura_repo_worker:count(?REPO, Q)),
    kura_tenant:with_tenant({prefix, ~"tenant_a"}, fun() ->
        ?assertMatch({error, _}, kura_repo_worker:all(?REPO, Q))
    end),
    ?assertMatch([#{body := ~"one"}], all(where(kura_query:prefix(Q, ~"main"), {org_id, 1}))).

require_tenant(_Config) ->
    {ok, 1} = kura_repo_worker:insert_all(?REPO, ?NOTE, [#{org_id => 1, body => ~"one"}]),
    {ok, 1} = kura_repo_worker:insert_all(?REPO, ?PLAN, [#{name => ~"free"}]),
    application:set_env(kura, require_tenant, true),
    ok = restarted(),
    ?assertError({kura, {tenant_required, _}}, kura_repo_worker:all(?REPO, kura_query:from(?NOTE))),
    ?assertMatch({ok, [#{name := ~"free"}]}, kura_repo_worker:all(?REPO, kura_query:from(?PLAN))),
    kura_tenant:with_tenant({attribute, {org_id, 1}}, fun() ->
        ?assertMatch({ok, [#{body := ~"one"}]}, kura_repo_worker:all(?REPO, kura_query:from(?NOTE)))
    end).

%%----------------------------------------------------------------------
%% Statements
%%----------------------------------------------------------------------

%% A `$` or a `?` inside a literal, an identifier or a comment is text.
fragments_and_placeholders(_Config) ->
    {ok, _} = insert_author(#{name => ~"cost $1", email => ~"what?"}),
    {ok, _} = insert_author(#{name => ~"Ada", email => ~"ada@example.com"}),
    Q = kura_query:from(?AUTHOR),
    ?assertEqual(
        [~"cost $1"],
        names(
            where(Q, {fragment, ~"name = 'cost $1' AND email_address = ? /* $2 ? */", [~"what?"]})
        )
    ),
    ?assertEqual(
        [~"cost $1"],
        names(
            where(
                Q,
                {'and', [
                    {age, is_nil},
                    {fragment, ~"\"name\" LIKE ? || '$1' -- $3 ?\n AND email_address = 'what?'", [
                        ~"cost "
                    ]},
                    {name, '!=', ~"Ada"}
                ]}
            )
        )
    ),
    ?assertError(
        {kura, {fragment_placeholder_mismatch, 1, 2}},
        kura_repo_worker:all(?REPO, where(Q, {fragment, ~"name = ?", [~"a", ~"b"]}))
    ),
    Selected = kura_query:select_expr(where(Q, {name, ~"Ada"}), [
        {shout, {fragment, ~"upper(name) || ?", [~"$1?"]}}
    ]),
    ?assertEqual([#{shout => ~"ADA$1?"}], all(Selected)).

numbered_parameters_bind_by_number(_Config) ->
    ?assertMatch(
        #{rows := [#{a := ~"two", b := ~"one", c := ~"two", d := ~"$1"}]},
        kura_db:query(?REPO, ~"SELECT ?2 AS a, ?1 AS b, ?2 AS c, '$1' AS d", [~"one", ~"two"])
    ),
    SQL = kura_dialect_sqlite:swap_placeholders(~"SELECT $2 AS a, $1 AS b, $2 AS c, '$1' AS d"),
    ?assertMatch(
        #{rows := [#{a := ~"two", b := ~"one", c := ~"two", d := ~"$1"}]},
        kura_db:query(?REPO, SQL, [~"one", ~"two"])
    ).

%%----------------------------------------------------------------------
%% Capabilities
%%----------------------------------------------------------------------

%% One statement for each capability kura_pool_sqlite declares.
declared_capabilities_run(_Config) ->
    Declared = kura_pool_sqlite:capabilities(),
    Checks = #{
        returning => fun() ->
            {ok, 1, [#{id := Id}]} = kura_repo_worker:insert_all(
                ?REPO, ?PLAN, [#{name => ~"free"}], #{returning => true}
            ),
            ?assertMatch(
                #{rows := [#{name := ~"paid"}]},
                kura_db:query(
                    ?REPO, ~"UPDATE plans SET name = 'paid' WHERE id = ?1 RETURNING name", [Id]
                )
            ),
            ?assertMatch(
                #{rows := [#{id := Id}]},
                kura_db:query(?REPO, ~"DELETE FROM plans WHERE id = ?1 RETURNING id", [Id])
            )
        end,
        json => fun() ->
            {ok, _} = insert_author(#{name => ~"Ada", settings => #{~"theme" => ~"dark"}}),
            ?assertEqual(
                [~"Ada"],
                names(
                    where(
                        kura_query:from(?AUTHOR),
                        {fragment, ~"json_extract(settings, '$.theme') = ?", [~"dark"]}
                    )
                )
            )
        end,
        partial_indexes => fun() ->
            run_operation(
                {create_index, ~"plans", [name], #{unique => true, where => ~"name <> 'free'"}}
            ),
            {ok, 2} = kura_repo_worker:insert_all(?REPO, ?PLAN, [
                #{name => ~"free"}, #{name => ~"free"}
            ]),
            {ok, 1} = kura_repo_worker:insert_all(?REPO, ?PLAN, [#{name => ~"paid"}]),
            ?assertMatch(
                {error, _}, kura_repo_worker:insert_all(?REPO, ?PLAN, [#{name => ~"paid"}])
            ),
            #{} = kura_db:query(?REPO, ~"DROP INDEX plans_name_index", [])
        end,
        window_functions => fun() ->
            {ok, 2} = kura_repo_worker:insert_all(?REPO, ?TAG, [
                #{name => ~"a"}, #{name => ~"b"}
            ]),
            Ranked = kura_query:select_expr(kura_query:from(?TAG), [
                {name, name}, {position, kura_query:over(rank, #{order_by => [{name, desc}]})}
            ]),
            ?assertEqual(
                [#{name => ~"a", position => 2}, #{name => ~"b", position => 1}],
                lists:sort(all(Ranked))
            )
        end,
        transactions => fun() ->
            ?assertError(
                undo,
                kura_repo_worker:transaction(?REPO, fun() ->
                    {ok, 1} = kura_repo_worker:insert_all(?REPO, ?NOTE, [
                        #{org_id => 1, body => ~"t"}
                    ]),
                    error(undo)
                end)
            ),
            ?assertEqual({ok, 0}, kura_repo_worker:count(?REPO, kura_query:from(?NOTE)))
        end,
        savepoints => fun() ->
            {ok, _} = kura_repo_worker:transaction(?REPO, fun() ->
                ?assertError(
                    undo,
                    kura_repo_worker:transaction(?REPO, fun() ->
                        {ok, 1} = kura_repo_worker:insert_all(?REPO, ?NOTE, [
                            #{org_id => 1, body => ~"inner"}
                        ]),
                        error(undo)
                    end)
                ),
                {ok, 1} = kura_repo_worker:insert_all(?REPO, ?NOTE, [
                    #{org_id => 2, body => ~"outer"}
                ]),
                {ok, done}
            end),
            ?assertMatch([#{body := ~"outer"}], all(kura_query:from(?NOTE)))
        end,
        prepared_statements => fun() ->
            [
                ?assertMatch(
                    #{rows := [#{n := N}]}, kura_db:query(?REPO, ~"SELECT ?1 + 1 AS n", [N - 1])
                )
             || N <- [1, 2, 3]
            ]
        end
    },
    ?assertEqual(lists:sort(Declared), lists:sort(maps:keys(Checks))),
    [Check() || _Capability := Check <- Checks],
    ok.

%% What SQLite cannot run is refused before a statement is built.
undeclared_capabilities_are_refused(_Config) ->
    Q = kura_query:from(?AUTHOR),
    Distance = kura_query:distance(embedding, cosine, [1.0, 2.0, 3.0]),
    Refused = [
        {full_text_search, where(Q, {name, matches, ~"ada"})},
        {vector,
            kura_query:order_by(kura_query:from(kura_sqlite_vector_schema), [{Distance, asc}])},
        {select_for_update_skip_locked, kura_query:lock(Q, {for_update, skip_locked})},
        {select_for_update_skip_locked, kura_query:lock(Q, ~"FOR UPDATE SKIP LOCKED")},
        {row_locks, kura_query:lock(Q, for_update)},
        {row_locks, kura_query:lock(Q, {for_share, nowait})},
        {row_locks, kura_query:lock(Q, {fragment, ~"FOR UPDATE OF authors"})},
        {distinct_on, kura_query:distinct(Q, [name])}
    ],
    [
        ?assertError(
            ?UNSUPPORTED(Capability), kura_repo_worker:all(?REPO, Query), {Capability, Query}
        )
     || {Capability, Query} <- Refused
    ],
    Missing = [
        jsonb,
        arrays,
        advisory_locks,
        listen_notify,
        select_for_update_skip_locked,
        row_locks,
        distinct_on,
        cursors,
        concurrent_indexes,
        full_text_search,
        vector
    ],
    ?assertEqual(
        {error, {missing_capabilities, Missing}},
        kura_capabilities:require(kura_pool_sqlite, Missing)
    ),
    Statements = [
        ~"SELECT pg_advisory_lock(1)",
        ~"LISTEN channel",
        ~"SELECT ARRAY[1, 2]",
        ~"SELECT * FROM authors FOR UPDATE SKIP LOCKED",
        ~"CREATE INDEX CONCURRENTLY authors_age ON authors (age)",
        ~"SELECT * FROM authors WHERE to_tsvector(name) @@ plainto_tsquery('a')",
        ~"SELECT '[1]'::vector <-> '[2]'::vector",
        ~"SELECT '{}'::jsonb @> '{}'::jsonb"
    ],
    [
        ?assertMatch({error, _}, kura_db:query(?REPO, Statement, []), Statement)
     || Statement <- Statements
    ],
    ok.

bind_limit_is_the_bundled_sqlite_limit(_Config) ->
    #{rows := Options} = kura_db:query(?REPO, ~"PRAGMA compile_options", []),
    ?assert(
        lists:member(~"MAX_VARIABLE_NUMBER=32766", [
            Option
         || #{compile_options := Option} <- Options
        ])
    ),
    Placeholders = fun(Count) ->
        lists:join(~", ", [[~"?", integer_to_binary(N)] || N <- lists:seq(1, Count)])
    end,
    Select = fun(Count) ->
        kura_db:query(
            ?REPO, [~"SELECT 1 WHERE 0 IN (", Placeholders(Count), ~")"], lists:seq(1, Count)
        )
    end,
    ?assertMatch(#{rows := []}, Select(32766)),
    ?assertMatch({error, _}, Select(32767)).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

%% The columns a migration for Schema would create: one per stored field,
%% under its column name, and one per embed.
create_table(Schema) ->
    Names = kura_schema:column_map(Schema),
    Columns = [
        #kura_column{
            name = binary_to_atom(maps:get(Name, Names)),
            type = Type,
            nullable = Nullable,
            default = Default,
            primary_key = PrimaryKey
        }
     || #kura_field{
            name = Name,
            type = Type,
            nullable = Nullable,
            default = Default,
            primary_key = PrimaryKey,
            virtual = false
        } <- Schema:fields()
    ],
    Embeds = [
        #kura_column{name = Name, type = {embed, Type, Embedded}}
     || #kura_embed{name = Name, type = Type, schema = Embedded} <- kura_schema:embeds(Schema)
    ],
    run_operation({create_table, Schema:table(), Columns ++ Embeds}).

%% A column of `every_type` as SQLite holds it: its storage class and value.
stored(Field, Id) ->
    Column = atom_to_binary(Field),
    #{rows := [#{class := Class, value := Value}]} = kura_db:query(
        ?REPO,
        [
            ~"SELECT typeof(\"",
            Column,
            ~"\") AS class, \"",
            Column,
            ~"\" AS value FROM every_type WHERE id = ?1"
        ],
        [Id]
    ),
    {Class, Value}.

run_operation(Operation) ->
    #{} = kura_db:query(?REPO, kura_migrator:compile_operation(?REPO, Operation), []),
    ok.

author_changeset(Params) ->
    kura_changeset:cast(?AUTHOR, #{}, Params, maps:keys(Params)).

insert_author(Params) ->
    kura_repo_worker:insert(?REPO, author_changeset(Params)).

insert_post(Params) ->
    kura_repo_worker:insert(?REPO, kura_changeset:cast(?POST, #{}, Params, maps:keys(Params))).

insert_secret(Params) ->
    kura_repo_worker:insert(?REPO, kura_changeset:cast(?SECRET, #{}, Params, maps:keys(Params))).

seed_authors() ->
    Authors = [
        #{
            name => ~"Ada",
            email => ~"ada@example.com",
            age => 36,
            role => admin,
            born => {1815, 12, 10}
        },
        #{
            name => ~"Bob",
            email => ~"bob@example.com",
            age => 31,
            role => member,
            active => false,
            born => {1990, 1, 2}
        },
        #{
            name => ~"Grace",
            email => ~"grace@example.com",
            age => 85,
            role => member,
            born => {1906, 12, 9}
        },
        #{name => ~"Linus", age => 55, born => {1969, 12, 28}}
    ],
    [
        begin
            {ok, Author} = insert_author(Params),
            Author
        end
     || Params <- Authors
    ].

seed_posts() ->
    [Ada, Bob | _] = seed_authors(),
    {ok, 2} = kura_repo_worker:insert_all(?REPO, ?TAG, [#{name => ~"erlang"}, #{name => ~"sqlite"}]),
    {ok, #{id := Erlang}} = kura_repo_worker:get_by(?REPO, ?TAG, [{name, ~"erlang"}]),
    {ok, #{id := Sqlite}} = kura_repo_worker:get_by(?REPO, ?TAG, [{name, ~"sqlite"}]),
    {ok, #{id := First}} = insert_post(#{
        title => ~"first", author_id => maps:get(id, Ada), views => 1
    }),
    {ok, #{id := Second}} = insert_post(#{
        title => ~"second", author_id => maps:get(id, Ada), views => 9
    }),
    {ok, _} = insert_post(#{title => ~"third", author_id => maps:get(id, Bob), views => 3}),
    [
        #{} = kura_db:query(
            ?REPO, ~"INSERT INTO posts_tags (post_id, tag_id) VALUES (?1, ?2)", [Post, Tag]
        )
     || {Post, Tag} <- [{First, Erlang}, {First, Sqlite}, {Second, Erlang}]
    ],
    {Ada, Bob}.

where(Query, Condition) ->
    kura_query:where(Query, Condition).

all(Query) ->
    case kura_repo_worker:all(?REPO, Query) of
        {ok, Rows} -> Rows;
        Error -> error({Error, kura_query_compiler:to_sql(?REPO, Query)})
    end.

names(Query) ->
    lists:sort(ordered_names(Query)).

ordered_names(Query) ->
    [Name || #{name := Name} <- all(Query)].

titles(Query) ->
    lists:sort([Title || #{title := Title} <- all(Query)]).

titles(Query, Condition) ->
    titles(where(Query, Condition)).

like(Pattern) ->
    names(where(kura_query:from(?AUTHOR), {name, like, Pattern})).

%% What the literal operators mean, whatever the backend.
literal_match(contains, Text, Name) ->
    Text =:= <<>> orelse binary:match(Name, Text) =/= nomatch;
literal_match(starts_with, Text, Name) ->
    string:prefix(Name, Text) =/= nomatch;
literal_match(ends_with, Text, Name) ->
    byte_size(Name) >= byte_size(Text) andalso
        binary:part(Name, byte_size(Name), -byte_size(Text)) =:= Text.

batches() ->
    receive
        {batch, Batch} -> [Batch | batches()]
    after 0 -> []
    end.

queries() ->
    receive
        {query, Metadata} -> [Metadata | queries()]
    after 0 -> []
    end.
