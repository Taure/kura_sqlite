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

%% Regression test for the SQLITE_BUSY case_clause crash: esqlite3:step/1
%% returns the bare atom '$busy' (not an {error, _} tuple) once a
%% connection's own busy_timeout is exhausted racing another writer -
%% see collect_rows/3's own comment. Needs two real connections to the
%% *same file* db (in-memory dbs are private per-connection, so they
%% can never contend) with busy_timeout pragma'd down so the test does
%% not have to wait out the NIF's 2s default.
busy_returns_error_tuple_instead_of_crashing_test_() ->
    {timeout, 10, fun() ->
        Path = tmp_db_path(),
        Name = kura_driver_sqlite_busy_test_pool,
        {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => Path, pool_size => 2}),
        try
            {ok, ConnA, TokenA} = kura_pool_sqlite:checkout(Name, #{}),
            {ok, ConnB, TokenB} = kura_pool_sqlite:checkout(Name, #{}),
            ok = esqlite3:exec(ConnA, ~"PRAGMA busy_timeout = 50"),
            ok = esqlite3:exec(ConnB, ~"PRAGMA busy_timeout = 50"),
            ok = esqlite3:exec(ConnA, ~"CREATE TABLE t (id INTEGER)"),
            %% BEGIN IMMEDIATE takes the write lock right away, unlike a
            %% plain BEGIN (which stays a read lock until the first write) -
            %% needed so ConnB is guaranteed to hit SQLITE_BUSY below.
            ok = esqlite3:exec(ConnA, ~"BEGIN IMMEDIATE"),
            Result = kura_driver_sqlite:query_on(ConnB, ~"INSERT INTO t VALUES (1)", [], #{}),
            ?assertEqual({error, busy}, Result),
            ok = esqlite3:exec(ConnA, ~"ROLLBACK"),
            kura_pool_sqlite:checkin(Name, TokenA),
            kura_pool_sqlite:checkin(Name, TokenB)
        after
            kura_pool_sqlite:stop_pool(Name),
            file:delete(Path)
        end
    end}.

tmp_db_path() ->
    Rand = integer_to_list(erlang:unique_integer([positive])),
    iolist_to_binary(["/tmp/kura_sqlite_busy_test_", Rand, ".db"]).

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
