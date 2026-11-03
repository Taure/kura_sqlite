-module(kura_driver_sqlite_tests).
-include_lib("eunit/include/eunit.hrl").

end_to_end_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"declares kura_driver behaviour", fun declares_behaviour/0},
            {"query_on runs SQL on an explicit conn and returns map rows",
                fun query_on_returns_map_rows/0},
            {"query/5 leases via pool and returns result", fun query_through_pool/0},
            {"transaction/4 commits when fun returns normally", fun transaction_commits/0},
            {"transaction/4 rolls back when fun throws", fun transaction_rolls_back_on_throw/0}
        ]
    end}.

setup() ->
    Name = kura_driver_sqlite_test_pool,
    %% pool_size=1 because in-memory SQLite databases are per-connection.
    %% Tests need every checkout to land on the same conn so they see
    %% the same data. A future shared-cache mode (file::memory:?cache=shared)
    %% would relax this.
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 1}),
    {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
    ok = esqlite3:exec(Conn, ~"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"),
    ok = kura_pool_sqlite:checkin(Name, Token),
    Name.

teardown(Name) ->
    kura_pool_sqlite:stop_pool(Name).

declares_behaviour() ->
    Attrs = kura_driver_sqlite:module_info(attributes),
    Behaviours = lists:append([V || {behaviour, V} <- Attrs] ++ [V || {behavior, V} <- Attrs]),
    ?assert(lists:member(kura_driver, Behaviours)).

query_on_returns_map_rows() ->
    Name = kura_driver_sqlite_test_pool,
    {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
    try
        ok = esqlite3:exec(Conn, ~"DELETE FROM users"),
        ok = esqlite3:exec(Conn, ~"INSERT INTO users VALUES (1, 'alice')"),
        Result = kura_driver_sqlite:query_on(Conn, ~"SELECT id, name FROM users", [], #{}),
        ?assertMatch(
            #{rows := [#{id := 1, name := <<"alice">>}], num_rows := 1, command := select},
            Result
        )
    after
        kura_pool_sqlite:checkin(Name, Token)
    end.

query_through_pool() ->
    Name = kura_driver_sqlite_test_pool,
    Result = kura_driver_sqlite:query(
        kura_pool_sqlite, Name, ~"SELECT 1 AS one", [], #{}
    ),
    ?assertMatch(#{rows := [#{one := 1}], num_rows := 1, command := select}, Result).

transaction_commits() ->
    Name = kura_driver_sqlite_test_pool,
    {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
    ok = esqlite3:exec(Conn, ~"DELETE FROM users"),
    ok = kura_pool_sqlite:checkin(Name, Token),
    %% Transaction returns whatever the Fun returns (here: a map result
    %% from the INSERT). What we care about is that it commits.
    _ = kura_driver_sqlite:transaction(
        kura_pool_sqlite,
        Name,
        fun() ->
            kura_driver_sqlite:query(
                kura_pool_sqlite,
                Name,
                ~"INSERT INTO users (id, name) VALUES (?1, ?2)",
                [42, ~"bob"],
                #{}
            )
        end,
        #{}
    ),
    {ok, C2, Tk2} = kura_pool_sqlite:checkout(Name, #{}),
    try
        Rows = esqlite3:q(C2, ~"SELECT name FROM users WHERE id = ?", [42]),
        ?assertEqual([[<<"bob">>]], Rows)
    after
        kura_pool_sqlite:checkin(Name, Tk2)
    end.

transaction_rolls_back_on_throw() ->
    Name = kura_driver_sqlite_test_pool,
    {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
    ok = esqlite3:exec(Conn, ~"DELETE FROM users"),
    ok = kura_pool_sqlite:checkin(Name, Token),
    ?assertException(
        throw,
        boom,
        kura_driver_sqlite:transaction(
            kura_pool_sqlite,
            Name,
            fun() ->
                _ = kura_driver_sqlite:query(
                    kura_pool_sqlite,
                    Name,
                    ~"INSERT INTO users (id, name) VALUES (?1, ?2)",
                    [99, ~"never"],
                    #{}
                ),
                throw(boom)
            end,
            #{}
        )
    ),
    {ok, C2, Tk2} = kura_pool_sqlite:checkout(Name, #{}),
    try
        Rows = esqlite3:q(C2, ~"SELECT name FROM users WHERE id = ?", [99]),
        ?assertEqual([], Rows)
    after
        kura_pool_sqlite:checkin(Name, Tk2)
    end.

nested_test_() ->
    [
        {Label,
            {foreach, fun() -> nested_setup(Db, Size) end, fun nested_teardown/1, nested_tests()}}
     || {Label, Db, Size} <- [
            {"file database", file, 2},
            {"in-memory database", memory, 1}
        ]
    ].

nested_tests() ->
    [
        fun(Pool) ->
            {"a raise in a nested transaction undoes only its own work", fun() ->
                nested_raise_undoes_only_inner(Pool)
            end}
        end,
        fun(Pool) ->
            {"rolling back the outer transaction undoes the nested one", fun() ->
                outer_rollback_undoes_nested(Pool)
            end}
        end,
        fun(Pool) ->
            {"the outer transaction carries on after a nested one", fun() ->
                outer_continues_after_nested(Pool)
            end}
        end,
        fun(Pool) ->
            {"a raise two levels down undoes only the innermost work", fun() ->
                doubly_nested_raise(Pool)
            end}
        end,
        fun(Pool) ->
            {"a rejected commit raises and leaves no transaction open", fun() ->
                rejected_commit_raises(Pool)
            end}
        end,
        fun(Pool) ->
            {"a statement after SQLite rolls the transaction back raises", fun() ->
                statement_after_sqlite_rollback_raises(Pool)
            end}
        end,
        fun(Pool) ->
            {"the outer transaction raises after SQLite rolls back inside a nested one", fun() ->
                outer_after_nested_sqlite_rollback_raises(Pool)
            end}
        end,

        fun(Pool) ->
            {"a nested transaction after SQLite rolls the transaction back raises", fun() ->
                nested_after_sqlite_rollback_raises(Pool)
            end}
        end,
        fun(Pool) ->
            {"the commit raises after SQLite rolls the transaction back", fun() ->
                commit_after_sqlite_rollback_raises(Pool)
            end}
        end,
        fun(Pool) ->
            {"a statement that ends the transaction raises", fun() ->
                statement_ending_the_transaction_raises(Pool)
            end}
        end,
        fun(Pool) ->
            {"a nested raise whose savepoint is gone rolls back the whole transaction", fun() ->
                failed_rollback_to_abandons_the_transaction(Pool)
            end}
        end,
        fun(Pool) ->
            {"a statement after a caught end raises the same, not a rollback", fun() ->
                statement_after_caught_end_raises_ended(Pool)
            end}
        end,
        fun(Pool) ->
            {"a nested transaction after a caught end raises the same", fun() ->
                nested_after_caught_end_raises_ended(Pool)
            end}
        end,
        fun(Pool) ->
            {"the commit after a caught end raises the same", fun() ->
                commit_after_caught_end_raises_ended(Pool)
            end}
        end,
        fun(Pool) ->
            {"the next transaction after a caught end runs", fun() ->
                transaction_after_caught_end_runs(Pool)
            end}
        end,
        fun(Pool) ->
            {"a transaction that ended leaves no note in the process", fun() ->
                transaction_leaves_no_note(Pool)
            end}
        end,
        fun(Pool) ->
            {"query_on/4: a COMMIT inside a transaction it started raises", fun() ->
                query_on_commit_inside_raises(Pool)
            end}
        end,
        fun(Pool) ->
            {"query_on/4: a statement after SQLite rolls back raises a rollback", fun() ->
                query_on_after_sqlite_rollback_raises(Pool)
            end}
        end,
        fun(Pool) ->
            {"query_on/4: starts forgets an earlier end on the connection", fun() ->
                query_on_starts_forgets_the_end(Pool)
            end}
        end,
        fun(Pool) ->
            {"query_on/4: a transaction after an end it noted runs", fun() ->
                query_on_end_then_transaction_runs(Pool)
            end}
        end,
        fun(Pool) ->
            {"query_on/4: without the option a COMMIT runs as before", fun() ->
                query_on_without_option_commits(Pool)
            end}
        end
    ].

nested_setup(Db, Size) ->
    Pool = list_to_atom(
        "kura_driver_sqlite_nested_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Path =
        case Db of
            memory -> ~":memory:";
            file -> nested_path(Pool)
        end,
    {ok, _} = kura_pool_sqlite:start_pool(Pool, #{database => Path, pool_size => Size}),
    #{} = sql(Pool, ~"CREATE TABLE nested (id INTEGER)"),
    {Pool, Path}.

nested_teardown({Pool, Path}) ->
    kura_pool_sqlite:stop_pool(Pool),
    _ = file:delete(Path),
    ok.

nested_path(Pool) ->
    Dir = os:getenv("TMPDIR", "/tmp"),
    iolist_to_binary(filename:join(Dir, atom_to_list(Pool) ++ ".db")).

nested_raise_undoes_only_inner({Pool, _}) ->
    ok = transaction(Pool, fun() ->
        ok = insert(Pool, 1),
        ?assertThrow(
            inner,
            transaction(Pool, fun() ->
                ok = insert(Pool, 2),
                throw(inner)
            end)
        ),
        insert(Pool, 3)
    end),
    ?assertEqual([1, 3], ids(Pool)).

outer_rollback_undoes_nested({Pool, _}) ->
    ?assertThrow(
        outer,
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            ok = transaction(Pool, fun() -> insert(Pool, 2) end),
            throw(outer)
        end)
    ),
    ?assertEqual([], ids(Pool)).

outer_continues_after_nested({Pool, _}) ->
    ?assertThrow(
        outer,
        transaction(Pool, fun() ->
            ok = transaction(Pool, fun() -> insert(Pool, 1) end),
            ok = insert(Pool, 2),
            ?assertEqual([1, 2], ids(Pool)),
            throw(outer)
        end)
    ),
    ?assertEqual([], ids(Pool)).

doubly_nested_raise({Pool, _}) ->
    ok = transaction(Pool, fun() ->
        ok = insert(Pool, 1),
        ok = transaction(Pool, fun() ->
            ok = insert(Pool, 2),
            ?assertThrow(
                inner,
                transaction(Pool, fun() ->
                    ok = insert(Pool, 3),
                    throw(inner)
                end)
            ),
            insert(Pool, 4)
        end)
    end),
    ?assertEqual([1, 2, 4], ids(Pool)).

rejected_commit_raises({Pool, _}) ->
    #{} = sql(Pool, ~"CREATE TABLE parent (id INTEGER PRIMARY KEY)"),
    #{} = sql(
        Pool,
        ~"CREATE TABLE child (parent_id INTEGER REFERENCES parent (id) DEFERRABLE INITIALLY DEFERRED)"
    ),
    ?assertError(
        {kura_driver_sqlite, {commit_failed, _}},
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            sql(Pool, ~"INSERT INTO child VALUES (99)")
        end)
    ),
    ?assertEqual([], ids(Pool)),
    ok = transaction(Pool, fun() -> insert(Pool, 2) end),
    ?assertEqual([2], ids(Pool)).

statement_after_sqlite_rollback_raises({Pool, _}) ->
    ok = rollback_on_conflict_table(Pool),
    ?assertError(
        transaction_rolled_back,
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            ok = conflict(Pool),
            insert(Pool, 2)
        end)
    ),
    ?assertEqual([], ids(Pool)).

outer_after_nested_sqlite_rollback_raises({Pool, _}) ->
    ok = rollback_on_conflict_table(Pool),
    ?assertError(
        transaction_rolled_back,
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            ?assertError(transaction_rolled_back, transaction(Pool, fun() -> conflict(Pool) end)),
            insert(Pool, 2)
        end)
    ),
    ?assertEqual([], ids(Pool)).

statement_ending_the_transaction_raises({Pool, _}) ->
    ?assertError(
        {kura_driver_sqlite, transaction_ended_by_statement},
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            #{} = sql(Pool, ~"COMMIT"),
            insert(Pool, 2)
        end)
    ),
    ?assertEqual([1], ids(Pool)).

failed_rollback_to_abandons_the_transaction({Pool, _}) ->
    Before = erlang:unique_integer([positive, monotonic]),
    ?assertError(
        transaction_rolled_back,
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            ?assertError(
                {kura_driver_sqlite, {rollback_to_failed, _}},
                transaction(Pool, fun() ->
                    ok = insert(Pool, 2),
                    ok = release_own_savepoint(Pool, Before + 1, Before + 1000),
                    throw(inner)
                end)
            ),
            insert(Pool, 3)
        end)
    ),
    ?assertEqual([], ids(Pool)).

-define(ENDED, {kura_driver_sqlite, transaction_ended_by_statement}).

statement_after_caught_end_raises_ended({Pool, _}) ->
    ?assertError(
        ?ENDED,
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            ?assertError(?ENDED, sql(Pool, ~"COMMIT")),
            insert(Pool, 2)
        end)
    ),
    ?assertEqual([1], ids(Pool)).

nested_after_caught_end_raises_ended({Pool, _}) ->
    ?assertError(
        ?ENDED,
        transaction(Pool, fun() ->
            ?assertError(?ENDED, sql(Pool, ~"COMMIT")),
            transaction(Pool, fun() -> insert(Pool, 2) end)
        end)
    ),
    ?assertEqual([], ids(Pool)).

commit_after_caught_end_raises_ended({Pool, _}) ->
    ?assertError(
        ?ENDED,
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            ?assertError(?ENDED, sql(Pool, ~"COMMIT")),
            done
        end)
    ),
    ?assertEqual([1], ids(Pool)).

%% Every transaction lands on one connection when the pool has one.
transaction_after_caught_end_runs({Pool, _}) ->
    ?assertError(
        ?ENDED,
        transaction(Pool, fun() ->
            ?assertError(?ENDED, sql(Pool, ~"COMMIT")),
            done
        end)
    ),
    ?assertEqual(ok, transaction(Pool, fun() -> insert(Pool, 1) end)),
    ?assertEqual([1], ids(Pool)).

%% The note would keep the connection's handle alive in this process.
transaction_leaves_no_note({Pool, _}) ->
    ?assertError(
        ?ENDED,
        transaction(Pool, fun() ->
            ?assertError(?ENDED, sql(Pool, ~"COMMIT")),
            done
        end)
    ),
    ?assertEqual([], [Key || {{kura_driver_sqlite, ended, _} = Key, _} <- get()]).

query_on_commit_inside_raises({Pool, _}) ->
    on_checked_out(Pool, fun(Conn) ->
        #{} = on(Conn, ~"BEGIN", [], starts),
        #{command := insert} = on(Conn, ~"INSERT INTO nested VALUES (?1)", [1], inside),
        ?assertError(?ENDED, on(Conn, ~"COMMIT", [], inside)),
        ?assertError(?ENDED, on(Conn, ~"INSERT INTO nested VALUES (?1)", [2], inside))
    end),
    ?assertEqual([1], ids(Pool)).

query_on_after_sqlite_rollback_raises({Pool, _}) ->
    ok = rollback_on_conflict_table(Pool),
    on_checked_out(Pool, fun(Conn) ->
        #{} = on(Conn, ~"BEGIN", [], starts),
        #{} = on(Conn, ~"INSERT INTO rollback_on_conflict VALUES (1)", [], inside),
        {error, _} = on(Conn, ~"INSERT INTO rollback_on_conflict VALUES (1)", [], inside),
        ?assertError(
            transaction_rolled_back, on(Conn, ~"INSERT INTO nested VALUES (?1)", [1], inside)
        )
    end),
    ?assertEqual([], ids(Pool)).

query_on_starts_forgets_the_end({Pool, _}) ->
    on_checked_out(Pool, fun(Conn) ->
        #{} = on(Conn, ~"BEGIN", [], starts),
        ?assertError(?ENDED, on(Conn, ~"COMMIT", [], inside)),
        #{} = on(Conn, ~"BEGIN", [], starts),
        #{command := insert} = on(Conn, ~"INSERT INTO nested VALUES (?1)", [1], inside),
        #{} = on(Conn, ~"ROLLBACK", [], none)
    end),
    ?assertEqual([], ids(Pool)).

%% Every checkout lands on one connection when the pool has one.
query_on_end_then_transaction_runs({Pool, _}) ->
    on_checked_out(Pool, fun(Conn) ->
        #{} = on(Conn, ~"BEGIN", [], starts),
        ?assertError(?ENDED, on(Conn, ~"COMMIT", [], inside))
    end),
    ?assertEqual(ok, transaction(Pool, fun() -> insert(Pool, 1) end)),
    ?assertEqual([1], ids(Pool)).

query_on_without_option_commits({Pool, _}) ->
    on_checked_out(Pool, fun(Conn) ->
        #{} = kura_driver_sqlite:query_on(Conn, ~"BEGIN", [], #{}),
        #{} = kura_driver_sqlite:query_on(Conn, ~"INSERT INTO nested VALUES (1)", [], #{}),
        #{} = kura_driver_sqlite:query_on(Conn, ~"COMMIT", [], #{}),
        #{} = kura_driver_sqlite:query_on(Conn, ~"INSERT INTO nested VALUES (2)", [], #{})
    end),
    ?assertEqual([1, 2], ids(Pool)).

on_checked_out(Pool, Fun) ->
    {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
    try
        Fun(Conn)
    after
        ok = kura_pool_sqlite:checkin(Pool, Token)
    end.

on(Conn, SQL, Params, Transaction) ->
    kura_driver_sqlite:query_on(Conn, SQL, Params, #{transaction => Transaction}).

%% The nested call's savepoint is named from the next monotonic integer.
release_own_savepoint(_Pool, From, To) when From > To ->
    error(savepoint_not_found);
release_own_savepoint(Pool, From, To) ->
    case sql(Pool, [~"RELEASE kura_savepoint_", integer_to_binary(From)]) of
        #{} -> ok;
        {error, _} -> release_own_savepoint(Pool, From + 1, To)
    end.

commit_after_sqlite_rollback_raises({Pool, _}) ->
    ok = rollback_on_conflict_table(Pool),
    ?assertError(
        transaction_rolled_back,
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            conflict(Pool)
        end)
    ),
    ?assertEqual([], ids(Pool)).

nested_after_sqlite_rollback_raises({Pool, _}) ->
    ok = rollback_on_conflict_table(Pool),
    ?assertError(
        transaction_rolled_back,
        transaction(Pool, fun() ->
            ok = insert(Pool, 1),
            ok = conflict(Pool),
            transaction(Pool, fun() -> insert(Pool, 2) end)
        end)
    ),
    ?assertEqual([], ids(Pool)).

rollback_on_conflict_table(Pool) ->
    #{} = sql(
        Pool, ~"CREATE TABLE rollback_on_conflict (id INTEGER PRIMARY KEY ON CONFLICT ROLLBACK)"
    ),
    ok.

conflict(Pool) ->
    #{} = sql(Pool, ~"INSERT INTO rollback_on_conflict VALUES (1)"),
    {error, _} = sql(Pool, ~"INSERT INTO rollback_on_conflict VALUES (1)"),
    ok.

transaction(Pool, Fun) ->
    kura_driver_sqlite:transaction(kura_pool_sqlite, Pool, Fun, #{}).

sql(Pool, SQL) ->
    kura_driver_sqlite:query(kura_pool_sqlite, Pool, SQL, [], #{}).

insert(Pool, Id) ->
    #{command := insert} = kura_driver_sqlite:query(
        kura_pool_sqlite, Pool, ~"INSERT INTO nested VALUES (?1)", [Id], #{}
    ),
    ok.

ids(Pool) ->
    #{rows := Rows} = sql(Pool, ~"SELECT id FROM nested ORDER BY id"),
    [Id || #{id := Id} <- Rows].

no_connection_raises_test() ->
    Pool = kura_driver_sqlite_without_connections,
    {ok, _} = kura_pool_sqlite:start_pool(Pool, #{database => ~":memory:", pool_size => 0}),
    try
        ?assertError(
            {kura_driver_sqlite, {no_connection, no_conns}},
            transaction(Pool, fun() -> {error, from_the_function} end)
        )
    after
        kura_pool_sqlite:stop_pool(Pool)
    end.

checkin_after_a_raise_test() ->
    {Pool, Path} = nested_setup(memory, 1),
    try
        ?assertThrow(boom, transaction(Pool, fun() -> throw(boom) end)),
        ?assertEqual(ok, transaction(Pool, fun() -> ok end))
    after
        nested_teardown({Pool, Path})
    end.

other_pool_inside_a_transaction_test() ->
    {Outer, OuterPath} = nested_setup(memory, 1),
    {Other, OtherPath} = nested_setup(memory, 1),
    try
        ?assertThrow(
            outer,
            transaction(Outer, fun() ->
                ok = insert(Other, 1),
                ok = transaction(Other, fun() -> insert(Other, 2) end),
                throw(outer)
            end)
        ),
        ?assertEqual([1, 2], ids(Other))
    after
        nested_teardown({Outer, OuterPath}),
        nested_teardown({Other, OtherPath})
    end.

statement_that_waits_out_the_busy_timeout_returns_busy_test() ->
    {Pool, Path} = nested_setup(file, 1),
    {ok, Other} = esqlite3:open(binary_to_list(Path)),
    {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
    try
        ok = esqlite3:exec(Other, ~"BEGIN IMMEDIATE"),
        #{} = kura_driver_sqlite:query_on(Conn, ~"PRAGMA busy_timeout = 10", [], #{}),
        ?assertEqual(
            {error, busy},
            kura_driver_sqlite:query_on(Conn, ~"INSERT INTO nested VALUES (1)", [], #{})
        )
    after
        _ = esqlite3:exec(Other, ~"ROLLBACK"),
        _ = esqlite3:close(Other),
        ok = kura_pool_sqlite:checkin(Pool, Token),
        nested_teardown({Pool, Path})
    end.

drop_of_a_referenced_table_is_refused_test() ->
    with_parent(fun(Pool) ->
        ?assertEqual(
            {error, {referenced_by, ~"parent", [~"child"]}}, sql(Pool, ~"DROP TABLE parent")
        ),
        ?assertMatch(#{rows := [#{id := 1}]}, sql(Pool, ~"SELECT id FROM parent")),
        ?assertMatch(#{rows := [#{parent_id := 1}]}, sql(Pool, ~"SELECT parent_id FROM child"))
    end).

refusal_names_every_referencing_table_test() ->
    with_parent(fun(Pool) ->
        #{} = sql(Pool, ~"CREATE TABLE \"Other\" (p INTEGER REFERENCES PARENT (id))"),
        #{} = sql(Pool, ~"CREATE TABLE another (p INTEGER, q INTEGER REFERENCES \"parent\" (id))"),
        ?assertEqual(
            {error, {referenced_by, ~"parent", [~"Other", ~"another", ~"child"]}},
            sql(Pool, ~"drop table if exists main.\"Parent\"")
        )
    end).

drop_inside_a_transaction_is_refused_test() ->
    with_parent(fun(Pool) ->
        ?assertEqual(
            {error, {referenced_by, ~"parent", [~"child"]}},
            transaction(Pool, fun() -> sql(Pool, ~"DROP TABLE parent") end)
        ),
        ?assertMatch(#{rows := [#{parent_id := 1}]}, sql(Pool, ~"SELECT parent_id FROM child"))
    end).

drop_on_a_held_connection_is_refused_test() ->
    with_parent(fun(Pool) ->
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
        try
            ?assertEqual(
                {error, {referenced_by, ~"parent", [~"child"]}},
                kura_driver_sqlite:query_on(Conn, ~"DROP TABLE parent", [], #{})
            )
        after
            ok = kura_pool_sqlite:checkin(Pool, Token)
        end
    end).

table_that_only_references_itself_is_dropped_test() ->
    with_parent(fun(Pool) ->
        #{} = sql(
            Pool, ~"CREATE TABLE tree (id INTEGER PRIMARY KEY, up INTEGER REFERENCES tree (id))"
        ),
        ?assertMatch(#{command := other}, sql(Pool, ~"DROP TABLE tree"))
    end).

parent_is_dropped_once_its_children_are_test() ->
    with_parent(fun(Pool) ->
        #{} = sql(Pool, ~"DROP TABLE child"),
        ?assertMatch(#{command := other}, sql(Pool, ~"DROP TABLE parent")),
        ?assertMatch({error, _}, sql(Pool, ~"SELECT id FROM parent"))
    end).

drop_of_a_missing_table_returns_the_sqlite_error_test() ->
    with_parent(fun(Pool) ->
        ?assertMatch({error, _}, sql(Pool, ~"DROP TABLE missing")),
        ?assertMatch(#{command := other}, sql(Pool, ~"DROP TABLE IF EXISTS missing"))
    end).

other_drops_are_not_checked_test() ->
    with_parent(fun(Pool) ->
        #{} = sql(Pool, ~"CREATE INDEX child_parent ON child (parent_id)"),
        #{} = sql(Pool, ~"CREATE VIEW parents AS SELECT id FROM parent"),
        ?assertMatch(#{command := other}, sql(Pool, ~"DROP INDEX child_parent")),
        ?assertMatch(#{command := other}, sql(Pool, ~"DROP VIEW parents"))
    end).

references_from_another_schema_do_not_count_test() ->
    with_parent(fun(Pool) ->
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
        try
            Query = fun(SQL) -> kura_driver_sqlite:query_on(Conn, SQL, [], #{}) end,
            #{} = Query(~"CREATE TABLE lone (id INTEGER PRIMARY KEY)"),
            #{} = Query(~"CREATE TEMP TABLE lone (id INTEGER PRIMARY KEY)"),
            #{} = Query(~"CREATE TEMP TABLE leaf (p INTEGER REFERENCES lone (id))"),
            ?assertEqual(
                {error, {referenced_by, ~"lone", [~"leaf"]}}, Query(~"DROP TABLE temp.lone")
            ),
            ?assertMatch(#{command := other}, Query(~"DROP TABLE main.lone"))
        after
            ok = kura_pool_sqlite:checkin(Pool, Token)
        end
    end).

drop_with_foreign_keys_off_is_not_checked_test() ->
    with_parent(fun(Pool) ->
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
        try
            #{} = kura_driver_sqlite:query_on(Conn, ~"PRAGMA foreign_keys = OFF", [], #{}),
            ?assertMatch(
                #{command := other},
                kura_driver_sqlite:query_on(Conn, ~"DROP TABLE parent", [], #{})
            ),
            ?assertEqual([[1]], esqlite3:q(Conn, ~"SELECT parent_id FROM child"))
        after
            ok = kura_pool_sqlite:checkin(Pool, Token)
        end
    end).

drop_with_foreign_keys_off_is_not_explained_test() ->
    with_parent(fun(Pool) ->
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
        try
            #{} = kura_driver_sqlite:query_on(Conn, ~"PRAGMA foreign_keys = OFF", [], #{}),
            ?assertMatch(
                {#{command := other}, [
                    ~"BEGIN IMMEDIATE", ~"PRAGMA foreign_keys", ~"DROP TABLE parent", ~"COMMIT"
                ]},
                prepares(fun() ->
                    kura_driver_sqlite:query_on(Conn, ~"DROP TABLE parent", [], #{})
                end)
            ),
            #{} = kura_driver_sqlite:query_on(Conn, ~"BEGIN", [], #{}),
            ?assertMatch(
                {#{command := other}, [~"PRAGMA foreign_keys", ~"DROP TABLE child"]},
                prepares(fun() ->
                    kura_driver_sqlite:query_on(Conn, ~"DROP TABLE child", [], #{})
                end)
            ),
            #{} = kura_driver_sqlite:query_on(Conn, ~"ROLLBACK", [], #{})
        after
            ok = kura_pool_sqlite:checkin(Pool, Token)
        end
    end).

with_parent(Test) ->
    {Pool, Path} = nested_setup(file, 1),
    try
        #{} = sql(Pool, ~"CREATE TABLE parent (id INTEGER PRIMARY KEY)"),
        #{} = sql(
            Pool,
            ~"CREATE TABLE child (parent_id INTEGER REFERENCES parent (id) ON DELETE CASCADE)"
        ),
        #{} = sql(Pool, ~"INSERT INTO parent VALUES (1)"),
        #{} = sql(Pool, ~"INSERT INTO child VALUES (1)"),
        Test(Pool)
    after
        nested_teardown({Pool, Path})
    end.

%% The DROP TABLE check reads SQLite's EXPLAIN output, which SQLite does not
%% promise to keep stable. If this fails, the check needs updating.
explain_of_drop_table_has_the_shape_the_check_reads_test() ->
    {ok, Conn} = esqlite3:open(":memory:"),
    try
        ok = esqlite3:exec(Conn, ~"CREATE TABLE t (id INTEGER PRIMARY KEY)"),
        {ok, Explain} = esqlite3:prepare(Conn, ~"EXPLAIN DROP TABLE t"),
        ?assertMatch(
            [~"addr", ~"opcode", ~"p1", ~"p2", ~"p3", ~"p4" | _], esqlite3:column_names(Explain)
        ),
        Program = program(Conn, ~"EXPLAIN DROP TABLE t"),
        ?assertMatch(
            [[_, ~"DropTable", 0, _, _, ~"t" | _]],
            [Row || [_, ~"DropTable" | _] = Row <- Program]
        ),
        Missing = program(Conn, ~"EXPLAIN DROP TABLE IF EXISTS missing"),
        ?assertEqual(
            [],
            [Op || [_, Op | _] <- Missing, not lists:member(Op, nothing_dropped())]
        )
    after
        esqlite3:close(Conn)
    end.

program(Conn, SQL) ->
    case esqlite3:q(Conn, SQL) of
        Rows when is_list(Rows) -> Rows
    end.

nothing_dropped() ->
    [~"Init", ~"Transaction", ~"JournalMode", ~"Goto", ~"Halt"].

drop_is_not_run_when_the_reference_check_is_busy_test() ->
    with_parent(fun(Pool) ->
        Path = nested_path(Pool),
        {ok, Other} = esqlite3:open(binary_to_list(Path)),
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
        try
            #{} = kura_driver_sqlite:query_on(Conn, ~"PRAGMA busy_timeout = 10", [], #{}),
            ok = esqlite3:exec(Conn, ~"BEGIN"),
            ok = esqlite3:exec(Other, ~"BEGIN EXCLUSIVE"),
            ?assertEqual(
                {{error, busy}, [~"PRAGMA foreign_keys", ~"EXPLAIN DROP TABLE parent", referencing]},
                prepares(fun() ->
                    kura_driver_sqlite:query_on(Conn, ~"DROP TABLE parent", [], #{})
                end)
            ),
            ok = esqlite3:exec(Conn, ~"ROLLBACK"),
            ok = esqlite3:exec(Other, ~"ROLLBACK"),
            ?assertMatch(
                #{rows := [#{parent_id := 1}]},
                kura_driver_sqlite:query_on(Conn, ~"SELECT parent_id FROM child", [], #{})
            )
        after
            _ = esqlite3:exec(Other, ~"ROLLBACK"),
            _ = esqlite3:close(Other),
            ok = kura_pool_sqlite:checkin(Pool, Token)
        end
    end).

prepares(Fun) ->
    Session = trace:session_create(?MODULE, self(), []),
    try
        _ = trace:process(Session, new, true, [call]),
        1 = trace:function(Session, {esqlite3, prepare, 2}, true, [local]),
        {result, Result} = in_process(Fun),
        Delivered = trace:delivered(Session, all),
        receive
            {trace_delivered, all, Delivered} -> {Result, prepared()}
        end
    after
        trace:session_destroy(Session)
    end.

in_process(Fun) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({result, Fun()}) end),
    receive
        {'DOWN', Ref, process, Pid, Reason} -> Reason
    end.

prepared() ->
    receive
        {trace, _, call, {esqlite3, prepare, [_, <<"SELECT DISTINCT t.name", _/binary>>]}} ->
            [referencing | prepared()];
        {trace, _, call, {esqlite3, prepare, [_, SQL]}} ->
            [SQL | prepared()]
    after 0 -> []
    end.

drop_outside_a_transaction_shares_one_with_its_check_test() ->
    with_parent(fun(Pool) ->
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
        try
            ?assertEqual(
                {{error, {referenced_by, ~"parent", [~"child"]}}, [
                    ~"BEGIN IMMEDIATE",
                    ~"PRAGMA foreign_keys",
                    ~"EXPLAIN DROP TABLE parent",
                    referencing
                ]},
                prepares(fun() ->
                    kura_driver_sqlite:query_on(Conn, ~"DROP TABLE parent", [], #{})
                end)
            ),
            ?assert(esqlite3:get_autocommit(Conn)),
            ?assertMatch(
                {#{command := other}, [
                    ~"BEGIN IMMEDIATE",
                    ~"PRAGMA foreign_keys",
                    ~"EXPLAIN DROP TABLE child",
                    referencing,
                    ~"DROP TABLE child",
                    ~"COMMIT"
                ]},
                prepares(fun() ->
                    kura_driver_sqlite:query_on(Conn, ~"DROP TABLE child", [], #{})
                end)
            ),
            ?assert(esqlite3:get_autocommit(Conn)),
            ?assertMatch(
                {error, _}, kura_driver_sqlite:query_on(Conn, ~"SELECT * FROM child", [], #{})
            )
        after
            ok = kura_pool_sqlite:checkin(Pool, Token)
        end
    end).

drop_that_cannot_commit_is_rolled_back_test() ->
    with_parent(fun(Pool) ->
        Path = nested_path(Pool),
        {ok, Other} = esqlite3:open(binary_to_list(Path)),
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
        try
            #{} = kura_driver_sqlite:query_on(Conn, ~"PRAGMA busy_timeout = 10", [], #{}),
            ok = esqlite3:exec(Other, ~"BEGIN"),
            [_] = esqlite3:q(Other, ~"SELECT * FROM child"),
            ?assertEqual(
                {error, busy}, kura_driver_sqlite:query_on(Conn, ~"DROP TABLE child", [], #{})
            ),
            ?assert(esqlite3:get_autocommit(Conn)),
            ok = esqlite3:exec(Other, ~"ROLLBACK"),
            ?assertMatch(
                #{rows := [#{parent_id := 1}]},
                kura_driver_sqlite:query_on(Conn, ~"SELECT parent_id FROM child", [], #{})
            )
        after
            _ = esqlite3:exec(Other, ~"ROLLBACK"),
            _ = esqlite3:close(Other),
            ok = kura_pool_sqlite:checkin(Pool, Token)
        end
    end).

drop_waiting_out_the_busy_timeout_returns_busy_test() ->
    with_parent(fun(Pool) ->
        Path = nested_path(Pool),
        {ok, Other} = esqlite3:open(binary_to_list(Path)),
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
        try
            #{} = kura_driver_sqlite:query_on(Conn, ~"PRAGMA busy_timeout = 10", [], #{}),
            ok = esqlite3:exec(Other, ~"BEGIN IMMEDIATE"),
            ?assertEqual(
                {{error, busy}, [~"BEGIN IMMEDIATE"]},
                prepares(fun() ->
                    kura_driver_sqlite:query_on(Conn, ~"DROP TABLE child", [], #{})
                end)
            ),
            ?assert(esqlite3:get_autocommit(Conn))
        after
            _ = esqlite3:exec(Other, ~"ROLLBACK"),
            _ = esqlite3:close(Other),
            ok = kura_pool_sqlite:checkin(Pool, Token)
        end
    end).

drop_after_comments_is_refused_test() ->
    with_parent(fun(Pool) ->
        Refused = {error, {referenced_by, ~"parent", [~"child"]}},
        ?assertEqual(Refused, sql(Pool, ~"-- roll back\nDROP TABLE parent")),
        ?assertEqual(Refused, sql(Pool, ~"/* roll back */ drop /* the parent */ table parent")),
        ?assertEqual(Refused, sql(Pool, ~"\t\f DROP\n\rTABLE parent")),
        ?assertMatch(#{rows := [#{id := 1}]}, sql(Pool, ~"SELECT id FROM parent"))
    end).

drop_after_empty_statements_is_refused_test() ->
    with_parent(fun(Pool) ->
        Refused = {error, {referenced_by, ~"parent", [~"child"]}},
        _ = [
            ?assertEqual({SQL, Refused}, {SQL, sql(Pool, SQL)})
         || SQL <- [
                ~";DROP TABLE parent",
                ~" ; DROP TABLE parent",
                ~";;DROP TABLE parent",
                ~"/*x*/;DROP TABLE parent",
                ~"DROP/**/TABLE parent"
            ]
        ],
        ?assertMatch(#{rows := [#{parent_id := 1}]}, sql(Pool, ~"SELECT parent_id FROM child"))
    end).

%% SQLite skips 0x0B only inside a run of whitespace that starts with
%% another whitespace character; on its own it is a syntax error.
drop_after_a_vertical_tab_is_refused_test() ->
    with_parent(fun(Pool) ->
        Refused = {error, {referenced_by, ~"parent", [~"child"]}},
        Runnable = [
            ~" \vDROP TABLE parent",
            ~"\t\v\vDROP TABLE parent",
            ~"DROP \vTABLE parent",
            ~"DROP \v\vTABLE parent",
            ~"/*x*/ \vDROP TABLE parent",
            ~"; \vDROP TABLE parent",
            ~" \v; \vDROP TABLE parent",
            ~"--x\n\v/*y*/ \v;\n\vDROP \v/**/ \vTABLE parent",
            ~"\t\n\v\f\r DROP TABLE parent"
        ],
        ok = kura_pool:with_conn(kura_pool_sqlite, Pool, fun(Conn) ->
            _ = [{ok, _} = esqlite3:prepare(Conn, SQL) || SQL <- Runnable],
            ok
        end),
        _ = [?assertEqual({SQL, Refused}, {SQL, sql(Pool, SQL)}) || SQL <- Runnable],
        _ = [
            ?assertMatch({SQL, {error, _}}, {SQL, sql(Pool, SQL)})
         || SQL <- [~"\vDROP TABLE parent", ~"DROP\vTABLE parent", ~"/*x*/\vDROP TABLE parent"]
        ],
        ?assertMatch(#{rows := [#{id := 1}]}, sql(Pool, ~"SELECT id FROM parent")),
        ?assertMatch(#{rows := [#{parent_id := 1}]}, sql(Pool, ~"SELECT parent_id FROM child"))
    end).

statement_without_a_readable_keyword_is_checked_as_a_drop_test() ->
    with_parent(fun(Pool) ->
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
        try
            Query = fun(SQL) -> kura_driver_sqlite:query_on(Conn, SQL, [], #{}) end,
            ?assertMatch(
                {{error, _}, [
                    ~"BEGIN IMMEDIATE", ~"PRAGMA foreign_keys", ~"EXPLAIN (DROP TABLE parent)"
                ]},
                prepares(fun() -> Query(~"(DROP TABLE parent)") end)
            ),
            ?assertMatch(
                {{error, _}, [
                    ~"BEGIN IMMEDIATE", ~"PRAGMA foreign_keys", ~"EXPLAIN DROP \"TABLE\" parent"
                ]},
                prepares(fun() -> Query(~"DROP \"TABLE\" parent") end)
            ),
            ?assert(esqlite3:get_autocommit(Conn)),
            ?assertMatch(
                {#{command := insert}, [~"INSERT INTO parent VALUES (2)"]},
                prepares(fun() -> Query(~"INSERT INTO parent VALUES (2)") end)
            ),
            ?assertMatch(#{rows := [#{parent_id := 1}]}, Query(~"SELECT parent_id FROM child"))
        after
            ok = kura_pool_sqlite:checkin(Pool, Token)
        end
    end).

command_is_read_past_comments_test() ->
    with_parent(fun(Pool) ->
        ?assertMatch(
            #{command := select, rows := [#{id := 1}]},
            sql(Pool, ~"/* first */ -- second\n  SELECT id FROM parent")
        ),
        ?assertMatch(#{command := insert}, sql(Pool, ~"--x\nINSERT INTO parent VALUES (2)")),
        ?assertMatch(#{command := update}, sql(Pool, ~"/**/UPDATE parent SET id = 3 WHERE id = 2")),
        ?assertMatch(#{command := delete}, sql(Pool, ~"/* */ delete FROM parent WHERE id = 3"))
    end).

pragma_after_a_comment_is_other_test() ->
    with_parent(fun(Pool) ->
        ?assertMatch(#{command := other}, sql(Pool, ~"-- nothing\nPRAGMA user_version"))
    end).

statement_other_than_dml_gets_its_connection_checked_test() ->
    with_parent(fun(Pool) ->
        ok = marked(Pool),
        #{} = sql(Pool, ~"INSERT INTO parent VALUES (5)"),
        #{} = sql(Pool, ~"-- dml\nWITH x AS (SELECT 1 AS one) SELECT one FROM x"),
        ?assert(still_marked(Pool)),
        #{} = sql(Pool, ~"/* scratch */ CREATE TEMP TABLE scratch (id INTEGER)"),
        ?assertNot(still_marked(Pool)),
        ok = marked(Pool),
        ok = transaction(Pool, fun() ->
            #{} = sql(Pool, ~"CREATE TEMP TABLE inside (id INTEGER)"),
            ok
        end),
        ?assertNot(still_marked(Pool))
    end).

marked(Pool) ->
    kura_pool:with_conn(kura_pool_sqlite, Pool, fun(Conn) ->
        esqlite3:exec(Conn, ~"CREATE TEMP TABLE marker (id INTEGER)")
    end).

still_marked(Pool) ->
    kura_pool:with_conn(kura_pool_sqlite, Pool, fun(Conn) ->
        is_list(esqlite3:q(Conn, ~"SELECT count(*) FROM temp.marker"))
    end).

foreign_keys_turned_off_through_query_on_do_not_outlive_the_lease_test() ->
    with_parent(fun(Pool) ->
        ?assertError(
            rebuild_failed,
            kura_pool:with_conn(kura_pool_sqlite, Pool, fun(Conn) ->
                #{} = kura_driver_sqlite:query_on(Conn, ~"PRAGMA foreign_keys = OFF", [], #{}),
                error(rebuild_failed)
            end)
        ),
        ?assertMatch({error, _}, sql(Pool, ~"INSERT INTO child VALUES (42)"))
    end).

%%----------------------------------------------------------------------
%% Parameters bind by position
%%----------------------------------------------------------------------

with_conn(Fun) ->
    {ok, _} = application:ensure_all_started(esqlite),
    {ok, Conn} = esqlite3:open(":memory:"),
    try
        Fun(Conn)
    after
        esqlite3:close(Conn)
    end.

bound(Params) ->
    with_conn(fun(Conn) ->
        SQL = ~"SELECT typeof(?1) AS t1, ?1 AS v1, typeof(?2) AS t2, ?2 AS v2",
        kura_driver_sqlite:query_on(Conn, SQL, Params, #{})
    end).

params_bind_by_position_test_() ->
    Cases = [
        {[null, undefined], {~"null", null}, {~"null", null}},
        {[{blob, ~"b"}, ~"t"], {~"blob", ~"b"}, {~"text", ~"t"}},
        {[1, 2.5], {~"integer", 1}, {~"real", 2.5}},
        {["chars", [~"io", "list"]], {~"text", ~"chars"}, {~"text", ~"iolist"}},
        {[true, false], {~"integer", 1}, {~"integer", 0}},
        {[atom, {2024, 1, 2}], {~"text", ~"atom"}, {~"text", ~"2024-01-02"}},
        {
            [{{2024, 1, 2}, {3, 4, 5}}, {{999, 12, 31}, {24, 0, 0}}],
            {~"text", ~"2024-01-02 03:04:05"},
            {~"text", ~"0999-12-31 24:00:00"}
        },
        {[{text, ~"t"}, {int64, 7}], {~"text", ~"t"}, {~"integer", 7}},
        {[{int, 3}, {float, 1.5}], {~"integer", 3}, {~"real", 1.5}}
    ],
    [
        ?_assertMatch(
            #{rows := [#{t1 := T1, v1 := V1, t2 := T2, v2 := V2}]}, bound(Params)
        )
     || {Params, {T1, V1}, {T2, V2}} <- Cases
    ].

%% esqlite3:bind/2 binds by name when the first parameter is a 3-tuple or a
%% {Name, Value} pair, which would let a value pick its own position.
params_shaped_like_named_binds_are_refused_test_() ->
    [
        ?_assertEqual(
            {error, {unsupported_param, 1}}, bound([{~"?2", ~"secret"}, {~"?1", ~"x"}])
        ),
        ?_assertEqual(
            {error, {unsupported_param, 1}}, bound([{text, ~"?2", ~"secret"}, ~"x"])
        ),
        ?_assertEqual({error, {unsupported_param, 1}}, bound([{"?2", ~"secret"}, ~"x"])),
        ?_assertEqual({error, {unsupported_param, 2}}, bound([1, {a, b, c}])),
        ?_assertEqual({error, {unsupported_param, 2}}, bound([1, #{a => ~"secret"}])),
        ?_assertEqual({error, {unsupported_param, 1}}, bound([{blob, 1}, 2])),
        ?_assertEqual({error, {unsupported_param, 1}}, bound([{int, ~"1"}, 2]))
    ].

unrecognised_blob_column_is_refused_test() ->
    Blob = kura_dialect_sqlite:column_type(binary),
    ?assertEqual(
        {error, unrecognised_blob_column},
        with_conn(fun(Conn) ->
            kura_driver_sqlite:query_on(Conn, <<"CREATE TABLE t (c ", Blob/binary, ")">>, [], #{})
        end)
    ).

%% A {H, M, S} time has the shape of a date, so a three-integer tuple that
%% could be one is refused rather than bound as a date.
params_that_may_be_a_time_or_are_out_of_range_are_refused_test_() ->
    [
        ?_assertEqual({error, {unsupported_param, 1}}, bound([Param, 1]))
     || Param <- [
            {12, 5, 6},
            {24, 1, 1},
            {2024, 13, 1},
            {2024, 1, 0},
            {10000, 1, 1},
            {2024, 1, 2.0},
            {{2024, 1, 2}, {25, 0, 0}},
            {{2024, 1, 2}, {1, 2, 3.5}},
            {{2024, 1, 2}, {1, 2, 3, 4}}
        ]
    ].

params_esqlite_cannot_bind_are_refused_test_() ->
    [
        ?_assertEqual({error, {unsupported_param, 1}}, bound([Param, 1]))
     || Param <- [
            1 bsl 63,
            -(1 bsl 63) - 1,
            {int64, 1 bsl 63},
            {int, 1 bsl 31},
            {int, -(1 bsl 31) - 1},
            [1000],
            [a],
            {text, [256]},
            {blob, [~"ok", -1]}
        ]
    ].

params_at_the_integer_limits_bind_test() ->
    Max = (1 bsl 63) - 1,
    Min = -(1 bsl 63),
    ?assertMatch(#{rows := [#{v1 := Max, v2 := Min}]}, bound([Max, Min])),
    ?assertMatch(
        #{rows := [#{v1 := 2147483647, v2 := -2147483648}]},
        bound([{int, 2147483647}, {int, -2147483648}])
    ).

null_is_null_in_every_column_type_test() ->
    {Pool, Path} = nested_setup(memory, 1),
    try
        #{} = sql(
            Pool,
            ~"CREATE TABLE nulls (i INTEGER, r REAL, t TEXT, b BLOB, n NUMERIC, a ANY_AFFINITY)"
        ),
        #{} = sql(Pool, ~"INSERT INTO nulls VALUES (NULL, NULL, NULL, NULL, NULL, NULL)"),
        ?assertEqual(
            #{
                rows => [#{i => null, r => null, t => null, b => null, n => null, a => null}],
                num_rows => 1,
                command => select
            },
            sql(Pool, ~"SELECT i, r, t, b, n, a FROM nulls")
        ),
        ?assertMatch(
            #{rows := [#{i := null, t := ~"x"}]},
            kura_driver_sqlite:query(
                kura_pool_sqlite,
                Pool,
                ~"INSERT INTO nulls (i, t) VALUES (?1, ?2) RETURNING i, t",
                [null, ~"x"],
                #{}
            )
        ),
        ?assertMatch(
            #{rows := [#{i := null}]},
            transaction(Pool, fun() -> sql(Pool, ~"SELECT i FROM nulls WHERE t = 'x'") end)
        )
    after
        nested_teardown({Pool, Path})
    end.

write_without_returning_counts_the_rows_it_changed_test() ->
    {Pool, Path} = nested_setup(memory, 1),
    try
        #{} = sql(Pool, ~"CREATE UNIQUE INDEX nested_id ON nested (id)"),
        ?assertMatch(
            #{rows := [], num_rows := 3, command := insert},
            sql(Pool, ~"INSERT INTO nested VALUES (1), (2), (3)")
        ),
        ?assertMatch(
            #{rows := [], num_rows := 1, command := insert},
            sql(Pool, ~"INSERT INTO nested VALUES (3), (4) ON CONFLICT DO NOTHING")
        ),
        ?assertMatch(
            #{rows := [], num_rows := 2, command := update},
            sql(Pool, ~"UPDATE nested SET id = id + 10 WHERE id > 2")
        ),
        ?assertMatch(
            #{rows := [], num_rows := 0, command := update},
            sql(Pool, ~"UPDATE nested SET id = 0 WHERE id > 100")
        ),
        ?assertMatch(
            #{rows := [], num_rows := 2, command := delete},
            transaction(Pool, fun() -> sql(Pool, ~"DELETE FROM nested WHERE id < 10") end)
        ),
        ?assertMatch(
            #{rows := [], num_rows := 0, command := delete},
            sql(Pool, ~"DELETE FROM nested WHERE id < 10")
        )
    after
        nested_teardown({Pool, Path})
    end.

write_with_returning_counts_the_rows_it_returned_test() ->
    {Pool, Path} = nested_setup(memory, 1),
    try
        #{} = sql(Pool, ~"INSERT INTO nested VALUES (1), (2), (3)"),
        ?assertMatch(
            #{rows := [_, _], num_rows := 2, command := update},
            sql(Pool, ~"UPDATE nested SET id = id + 10 WHERE id > 1 RETURNING id")
        ),
        ?assertMatch(
            #{rows := [], num_rows := 0, command := delete},
            sql(Pool, ~"DELETE FROM nested WHERE id > 100 RETURNING id")
        )
    after
        nested_teardown({Pool, Path})
    end.

reads_and_other_statements_do_not_report_an_earlier_write_test() ->
    {Pool, Path} = nested_setup(memory, 1),
    try
        #{num_rows := 3} = sql(Pool, ~"INSERT INTO nested VALUES (1), (2), (3)"),
        ?assertMatch(
            #{num_rows := 0, command := select}, sql(Pool, ~"SELECT id FROM nested WHERE id > 3")
        ),
        ?assertMatch(
            #{num_rows := 0, command := other}, sql(Pool, ~"CREATE TABLE more (id INTEGER)")
        )
    after
        nested_teardown({Pool, Path})
    end.

replace_is_counted_as_an_insert_test() ->
    {Pool, Path} = nested_setup(memory, 1),
    try
        #{} = sql(Pool, ~"CREATE UNIQUE INDEX nested_id ON nested (id)"),
        #{} = sql(Pool, ~"INSERT INTO nested VALUES (1)"),
        ?assertMatch(
            #{rows := [], num_rows := 2, command := insert},
            sql(Pool, ~"REPLACE INTO nested VALUES (1), (2)")
        ),
        ?assertMatch(
            #{rows := [], num_rows := 1, command := insert},
            sql(Pool, ~"/* again */ replace into nested VALUES (2)")
        ),
        ?assertEqual([1, 2], ids(Pool))
    after
        nested_teardown({Pool, Path})
    end.

write_after_common_table_expressions_is_counted_test() ->
    {Pool, Path} = nested_setup(memory, 1),
    try
        ?assertMatch(
            #{rows := [], num_rows := 3, command := insert},
            sql(
                Pool,
                ~"""
                WITH a AS (SELECT 1 AS id), b (id) AS (SELECT 2 UNION ALL SELECT 3)
                INSERT INTO nested SELECT id FROM a UNION ALL SELECT id FROM b
                """
            )
        ),
        ?assertMatch(
            #{rows := [], num_rows := 2, command := update},
            sql(
                Pool,
                ~"""
                WITH RECURSIVE n (x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 2)
                UPDATE nested SET id = id + 10 WHERE id IN (SELECT x FROM n)
                """
            )
        ),
        ?assertMatch(
            #{rows := [], num_rows := 1, command := delete},
            sql(Pool, ~"WITH big AS MATERIALIZED (SELECT 10) DELETE FROM nested WHERE id > 11")
        ),
        ?assertMatch(
            #{rows := [_, _], num_rows := 2, command := select},
            sql(Pool, ~"WITH s AS NOT MATERIALIZED (SELECT id FROM nested) SELECT id FROM s")
        ),
        ?assertMatch(
            #{rows := [], num_rows := 2, command := insert},
            sql(Pool, ~"WITH x AS (SELECT 7) REPLACE INTO nested VALUES (8), (9)")
        )
    after
        nested_teardown({Pool, Path})
    end.

keyword_inside_common_table_expressions_is_not_the_command_test() ->
    {Pool, Path} = nested_setup(memory, 1),
    try
        #{num_rows := 2} = sql(Pool, ~"INSERT INTO nested VALUES (1), (2)"),
        ?assertMatch(
            #{rows := [#{v := ~") delete ("}], num_rows := 1, command := select},
            sql(
                Pool,
                ~"""
                WITH "insert" AS (SELECT ') delete (' AS v), [update)] AS (SELECT 1 /* ) */)
                -- ) delete
                SELECT v FROM "insert", [update)]
                """
            )
        ),
        ?assertMatch(
            #{rows := [#{one := 1}], num_rows := 1, command := select},
            sql(Pool, ~"WITH replace (one) AS (SELECT 1) SELECT one FROM replace")
        ),
        ?assertMatch(
            #{rows := [], num_rows := 1, command := delete},
            sql(Pool, ~"WITH `it's` AS (SELECT 'it''s (') DELETE FROM nested WHERE id = 1")
        )
    after
        nested_teardown({Pool, Path})
    end.

nesting_quotes_and_comments_inside_a_cte_body_are_skipped_test() ->
    {Pool, Path} = nested_setup(memory, 1),
    try
        #{num_rows := 2} = sql(Pool, ~"INSERT INTO nested VALUES (1), (2)"),
        ?assertMatch(
            #{rows := [], num_rows := 1, command := delete},
            sql(
                Pool,
                ~"""
                WITH a AS (
                    SELECT max(id) AS m, ') x' AS s, 1 AS ")", 1 AS `)`, 1 AS [)] -- ) select
                    FROM nested
                )
                DELETE FROM nested WHERE id IN (SELECT m FROM a)
                """
            )
        ),
        ?assertEqual([1], ids(Pool))
    after
        nested_teardown({Pool, Path})
    end.
