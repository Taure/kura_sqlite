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
    {Pool, Path} = nested_setup(memory, 1),
    {ok, _Conn, Token} = kura_pool_sqlite:checkout(Pool, #{}),
    try
        ?assertError(
            {kura_driver_sqlite, {no_connection, no_conns}},
            transaction(Pool, fun() -> {error, from_the_function} end)
        )
    after
        ok = kura_pool_sqlite:checkin(Pool, Token),
        nested_teardown({Pool, Path})
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
