-module(kura_pool_sqlite_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

start_pool_opens_in_memory_db_test() ->
    Name = pool_for_in_memory,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 2}),
    try
        ?assertNotEqual(undefined, ets:whereis(Name)),
        ?assertEqual(2, free_count(Name))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

checkout_returns_a_usable_esqlite_conn_test() ->
    Name = pool_for_checkout,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 1}),
    try
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        try
            ok = esqlite3:exec(Conn, ~"CREATE TABLE foo (id INTEGER)"),
            ok = esqlite3:exec(Conn, ~"INSERT INTO foo VALUES (1)"),
            Rows = esqlite3:q(Conn, ~"SELECT * FROM foo"),
            ?assertEqual([[1]], Rows)
        after
            kura_pool_sqlite:checkin(Name, Token)
        end
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

drains_pool_then_returns_no_conns_test() ->
    Name = pool_for_drain,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 2}),
    try
        {ok, _, _} = kura_pool_sqlite:checkout(Name, #{}),
        {ok, _, _} = kura_pool_sqlite:checkout(Name, #{}),
        %% timeout => 0: this test wants the old fail-immediately
        %% behavior, not the default bounded wait (checkout_waits_for_a_checkin_test
        %% and checkout_times_out_when_nothing_frees_up_test below cover the wait).
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{timeout => 0}))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

checkout_waits_for_a_checkin_test() ->
    Name = pool_for_wait,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 1}),
    try
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        _ = spawn(fun() ->
            timer:sleep(30),
            kura_pool_sqlite:checkin(Name, Token)
        end),
        %% The only connection is held for 30ms by the process above;
        %% a default-timeout checkout must wait it out and succeed
        %% rather than fail-fast on {error, no_conns}.
        ?assertEqual({ok, Conn, Conn}, kura_pool_sqlite:checkout(Name, #{timeout => 2000}))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

checkout_times_out_when_nothing_frees_up_test() ->
    Name = pool_for_timeout,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 1}),
    try
        {ok, _, _} = kura_pool_sqlite:checkout(Name, #{}),
        Start = erlang:monotonic_time(millisecond),
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{timeout => 50})),
        Elapsed = erlang:monotonic_time(millisecond) - Start,
        ?assert(Elapsed >= 50)
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

%% Regression test for the lost-update race the old {available, List}
%% / {checked_out, Map} representation had: two concurrent checkouts
%% could both read the same free list before either wrote it back and
%% walk away believing they each hold the connection the other one
%% also holds. Hammer a tiny pool from many processes and assert the
%% set of connections ever handed out concurrently never exceeds
%% pool_size, and no two workers are ever handed the same connection
%% at the same time.
no_double_checkout_under_concurrency_test_() ->
    {timeout, 20, fun() ->
        Name = pool_for_race,
        PoolSize = 3,
        Workers = 20,
        Rounds = 50,
        {ok, _} = kura_pool_sqlite:start_pool(Name, #{
            database => <<":memory:">>, pool_size => PoolSize
        }),
        try
            Holders = ets:new(holders, [public, set]),
            Parent = self(),
            Pids = [
                spawn(fun() -> race_worker(Name, Holders, Rounds, Parent) end)
             || _ <- lists:seq(1, Workers)
            ],
            [
                receive
                    {done, Pid} -> ok
                after 15000 -> error({worker_timed_out, Pid})
                end
             || Pid <- Pids
            ],
            ets:delete(Holders)
        after
            kura_pool_sqlite:stop_pool(Name)
        end
    end}.

race_worker(_Name, _Holders, 0, Parent) ->
    Parent ! {done, self()};
race_worker(Name, Holders, Rounds, Parent) ->
    {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{timeout => 5000}),
    %% Register-check-unregister around the connection: if another
    %% worker is concurrently handed the same Conn, this ets:insert_new
    %% will fail (key already present) and blow up the test.
    true = ets:insert_new(Holders, {Conn, self()}),
    timer:sleep(1),
    true = ets:delete(Holders, Conn),
    ok = kura_pool_sqlite:checkin(Name, Token),
    race_worker(Name, Holders, Rounds - 1, Parent).

free_count(Name) ->
    length(ets:select(Name, ets:fun2ms(fun({Conn, free}) -> Conn end))).

stop_pool_idempotent_test() ->
    Name = pool_for_stop,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 1}),
    ?assertEqual(ok, kura_pool_sqlite:stop_pool(Name)),
    ?assertEqual(ok, kura_pool_sqlite:stop_pool(Name)).

declares_kura_pool_behaviour_test() ->
    Attrs = kura_pool_sqlite:module_info(attributes),
    Behaviours = lists:append([V || {behaviour, V} <- Attrs] ++ [V || {behavior, V} <- Attrs]),
    ?assert(lists:member(kura_pool, Behaviours)).

declares_kura_capabilities_behaviour_test() ->
    Attrs = kura_pool_sqlite:module_info(attributes),
    Behaviours = lists:append([V || {behaviour, V} <- Attrs] ++ [V || {behavior, V} <- Attrs]),
    ?assert(lists:member(kura_capabilities, Behaviours)).

capabilities_excludes_pg_only_features_test() ->
    Caps = kura_pool_sqlite:capabilities(),
    ?assertNot(lists:member(advisory_locks, Caps)),
    ?assertNot(lists:member(listen_notify, Caps)),
    ?assertNot(lists:member(arrays, Caps)),
    %% SQLite 3.45 supports these:
    ?assert(lists:member(returning, Caps)),
    ?assert(lists:member(transactions, Caps)).

require_advisory_locks_returns_missing_test() ->
    %% A consumer that needs PG-only features should refuse to boot
    %% on a SQLite backend.
    ?assertEqual(
        {error, {missing_capabilities, [advisory_locks]}},
        kura_capabilities:require(kura_pool_sqlite, [returning, advisory_locks])
    ).
