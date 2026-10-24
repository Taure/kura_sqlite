-module(kura_pool_sqlite_tests).
-include_lib("eunit/include/eunit.hrl").

start_pool_opens_in_memory_db_test() ->
    Name = pool_for_in_memory,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 2}),
    try
        ?assertNotEqual(undefined, whereis(Name)),
        ?assertMatch({ok, _, _}, kura_pool_sqlite:checkout(Name, #{})),
        ?assertMatch({ok, _, _}, kura_pool_sqlite:checkout(Name, #{}))
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
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{}))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

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

killed_borrower_returns_its_connection_test() ->
    Name = pool_for_killed_borrower,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        #{} = sql(Name, ~"CREATE TABLE t (id INTEGER)"),
        Borrower = hold_in_transaction(Name, ~"INSERT INTO t VALUES (1)"),
        ok = kill(Borrower),
        ?assertEqual(ok, wait_for_checkout(Name, 1000)),
        ?assertMatch(#{rows := []}, sql(Name, ~"SELECT id FROM t"))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

killed_borrower_releases_the_write_lock_test() ->
    Name = pool_for_killed_writer,
    Path = db_path(Name),
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => Path, pool_size => 2}),
    try
        #{} = sql(Name, ~"CREATE TABLE t (id INTEGER)"),
        Borrower = hold_in_transaction(Name, ~"INSERT INTO t VALUES (1)"),
        ?assertError({case_clause, '$busy'}, sql(Name, ~"INSERT INTO t VALUES (2)")),
        ok = kill(Borrower),
        ?assertEqual(ok, wait_for_checkout(Name, 1000)),
        ?assertMatch(#{command := insert}, sql(Name, ~"INSERT INTO t VALUES (3)")),
        ?assertMatch(#{rows := [#{id := 3}]}, sql(Name, ~"SELECT id FROM t"))
    after
        kura_pool_sqlite:stop_pool(Name),
        file:delete(Path)
    end.

checkin_rolls_back_an_open_transaction_test() ->
    Name = pool_for_open_checkin,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        #{} = sql(Name, ~"CREATE TABLE t (id INTEGER)"),
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        ok = esqlite3:exec(Conn, ~"BEGIN"),
        ok = esqlite3:exec(Conn, ~"INSERT INTO t VALUES (1)"),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertMatch(#{rows := []}, sql(Name, ~"SELECT id FROM t"))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

begin_outside_a_transaction_is_not_inherited_test() ->
    Name = pool_for_stray_begin,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        #{} = sql(Name, ~"BEGIN"),
        ?assertEqual(
            ok, kura_driver_sqlite:transaction(kura_pool_sqlite, Name, fun() -> ok end, #{})
        )
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

give_away_moves_the_watch_test() ->
    Name = pool_for_give_away,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        Self = self(),
        First = spawn(fun() ->
            {ok, _Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
            Self ! {token, Token},
            receive
                never -> ok
            end
        end),
        Token =
            receive
                {token, T} -> T
            after 1000 -> error(no_token)
            end,
        Second = spawn(fun() ->
            receive
                never -> ok
            end
        end),
        ?assertEqual(ok, kura_pool_sqlite:give_away(Token, Second, gift)),
        ok = kill(First),
        ?assertEqual(timeout, wait_for_checkout(Name, 200)),
        ok = kill(Second),
        ?assertEqual(ok, wait_for_checkout(Name, 1000))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

stale_token_does_not_free_another_lease_test() ->
    Name = pool_for_stale_token,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        {ok, Conn, Stale} = kura_pool_sqlite:checkout(Name, #{}),
        ok = kura_pool_sqlite:checkin(Name, Stale),
        {ok, Conn, Current} = kura_pool_sqlite:checkout(Name, #{}),
        ?assertEqual(ok, kura_pool_sqlite:checkin(Name, Stale)),
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{})),
        ?assertEqual(
            {error, not_checked_out}, kura_pool_sqlite:give_away(Stale, self(), gift)
        ),
        ?assertEqual(ok, kura_pool_sqlite:checkin(Name, Current)),
        ?assertMatch({ok, Conn, _}, kura_pool_sqlite:checkout(Name, #{}))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

crashed_pool_is_restarted_test() ->
    Name = pool_for_restart,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        {ok, _Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        Before = whereis(Name),
        true = is_pid(Before),
        exit(Before, kill),
        ok = wait_for_exit(Before),
        ?assertEqual(ok, wait_for_checkout(Name, 1000)),
        ?assertNotEqual(Before, whereis(Name)),
        {ok, _Fresh, Current} = kura_pool_sqlite:checkout(Name, #{}),
        ?assertEqual(ok, kura_pool_sqlite:checkin(Name, Token)),
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{})),
        ok = kura_pool_sqlite:checkin(Name, Current)
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

stop_pool_stops_the_supervisor_test() ->
    Name = pool_for_stop_supervisor,
    {ok, Supervisor} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    Monitor = erlang:monitor(process, Supervisor),
    ok = kura_pool_sqlite:stop_pool(Name),
    receive
        {'DOWN', Monitor, process, Supervisor, _} -> ok
    after 1000 -> error(supervisor_still_running)
    end,
    ?assertEqual(undefined, whereis(Name)).

pool_outlives_the_process_that_started_it_test() ->
    Name = pool_for_outliving,
    Self = self(),
    Starter = spawn(fun() ->
        Self !
            {started,
                kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1})},
        exit(crashed)
    end),
    receive
        {started, {ok, _}} -> ok
    after 1000 -> error(never_started)
    end,
    try
        ok = wait_for_exit(Starter),
        ?assertMatch({ok, _, _}, kura_pool_sqlite:checkout(Name, #{}))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

failed_start_returns_an_error_to_the_caller_test() ->
    ?assertMatch(
        {result, {error, _}},
        in_fresh(fun() ->
            kura_pool_sqlite:start_pool(pool_for_failed_start, #{
                database => ~"/nonexistent_dir/x.db", pool_size => 1
            })
        end)
    ).

second_start_of_a_name_returns_already_started_test() ->
    Name = pool_for_second_start,
    Opts = #{database => ~":memory:", pool_size => 1},
    {ok, _} = kura_pool_sqlite:start_pool(Name, Opts),
    try
        Pool = whereis(Name),
        ?assertEqual(
            {result, {error, {already_started, Pool}}},
            in_fresh(fun() -> kura_pool_sqlite:start_pool(Name, Opts) end)
        )
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

calls_to_a_stopped_pool_do_not_raise_test() ->
    Name = pool_for_stopped_calls,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    {ok, _Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
    ok = kura_pool_sqlite:stop_pool(Name),
    ?assertEqual(ok, kura_pool_sqlite:checkin(Name, Token)),
    ?assertEqual({error, no_pool}, kura_pool_sqlite:checkout(Name, #{})),
    ?assertEqual({error, no_pool}, kura_pool_sqlite:give_away(Token, self(), gift)).

sql(Name, SQL) ->
    kura_driver_sqlite:query(kura_pool_sqlite, Name, SQL, [], #{}).

hold_in_transaction(Name, SQL) ->
    Self = self(),
    Borrower = spawn(fun() ->
        kura_driver_sqlite:transaction(
            kura_pool_sqlite,
            Name,
            fun() ->
                #{} = sql(Name, SQL),
                Self ! {holding, self()},
                receive
                    never -> ok
                end
            end,
            #{}
        )
    end),
    receive
        {holding, Borrower} -> Borrower
    after 1000 -> error(borrower_never_held)
    end.

wait_for_exit(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(still_running)
    end.

in_fresh(Fun) ->
    {Pid, Monitor} = spawn_monitor(fun() -> exit({result, Fun()}) end),
    receive
        {'DOWN', Monitor, process, Pid, Reason} -> Reason
    after 5000 -> error(still_running)
    end.

kill(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(still_running)
    end.

%% The pool learns of a borrower's death from its own monitor, which can land
%% after the caller's, and a restarted pool takes a moment to register.
wait_for_checkout(Name, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_checkout_loop(Name, Deadline).

wait_for_checkout_loop(Name, Deadline) ->
    case kura_pool_sqlite:checkout(Name, #{}) of
        {ok, _Conn, Token} ->
            kura_pool_sqlite:checkin(Name, Token);
        {error, Unavailable} when Unavailable =:= no_conns; Unavailable =:= no_pool ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    timeout;
                false ->
                    timer:sleep(10),
                    wait_for_checkout_loop(Name, Deadline)
            end
    end.

db_path(Name) ->
    iolist_to_binary(filename:join(os:getenv("TMPDIR", "/tmp"), atom_to_list(Name) ++ ".db")).
