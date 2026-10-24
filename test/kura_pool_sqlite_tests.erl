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
        {_, First} = checkout_within(Name, 1000),
        {_, Second} = checkout_within(Name, 1000),
        ok = kura_pool_sqlite:checkin(Name, First),
        ok = kura_pool_sqlite:checkin(Name, Second),
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

borrower_killed_during_commit_does_not_pass_on_its_transaction_test() ->
    Name = pool_for_killed_committer,
    Path = db_path(Name),
    _ = file:delete(Path),
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => Path, pool_size => 1}),
    {ok, Reader} = esqlite3:open(binary_to_list(Path)),
    try
        #{} = sql(Name, ~"CREATE TABLE t (id INTEGER)"),
        ok = esqlite3:exec(Reader, ~"BEGIN"),
        [] = esqlite3:q(Reader, ~"SELECT id FROM t"),
        Self = self(),
        Committer = spawn(fun() ->
            kura_driver_sqlite:transaction(
                kura_pool_sqlite,
                Name,
                fun() ->
                    #{} = sql(Name, ~"PRAGMA busy_timeout = 500"),
                    #{} = sql(Name, ~"INSERT INTO t VALUES (1)"),
                    Self ! {committing, self()},
                    receive
                        commit -> ok
                    end
                end,
                #{}
            )
        end),
        receive
            {committing, Committer} -> Committer ! commit
        after 1000 -> error(never_committed)
        end,
        ok = wait_in_nif(Committer, {esqlite3_nif, exec, 2}),
        ok = kill(Committer),
        {Conn, Token} = checkout_within(Name, 2000),
        _ = esqlite3:exec(Conn, ~""),
        ?assert(esqlite3:get_autocommit(Conn)),
        ?assertEqual([], esqlite3:q(Conn, ~"SELECT id FROM t")),
        ok = kura_pool_sqlite:checkin(Name, Token)
    after
        _ = esqlite3:close(Reader),
        kura_pool_sqlite:stop_pool(Name),
        file:delete(Path)
    end.

pool_answers_while_a_returned_connection_waits_for_its_statement_test() ->
    Name = pool_for_waiting_reset,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 2}),
    try
        Self = self(),
        Borrower = spawn(fun() ->
            kura_driver_sqlite:transaction(
                kura_pool_sqlite,
                Name,
                fun() ->
                    Self ! {running, self()},
                    sql(
                        Name,
                        ~"WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 10000000) SELECT count(*) FROM c"
                    )
                end,
                #{}
            )
        end),
        receive
            {running, Borrower} -> ok
        after 1000 -> error(never_ran)
        end,
        ok = wait_in_nif(Borrower, {esqlite3_nif, step, 1}),
        ok = kill(Borrower),
        {_Other, Token} = checkout_within(Name, 100),
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{})),
        ok = kura_pool_sqlite:checkin(Name, Token)
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

timed_out_checkout_gives_its_lease_back_test() ->
    Name = pool_for_timed_out_checkout,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        Pool = whereis(Name),
        true = is_pid(Pool),
        ok = sys:suspend(Pool),
        {Elapsed, Result} = timer:tc(kura_pool_sqlite, checkout, [Name, #{timeout => 100}]),
        ok = sys:resume(Pool),
        ?assertEqual({error, checkout_timeout}, Result),
        ?assert(Elapsed < 1000000),
        ?assertMatch({_, _}, checkout_within(Name, 1000))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

checkin_of_a_closed_connection_replaces_it_test() ->
    Name = pool_for_closed_checkin,
    Path = db_path(Name),
    _ = file:delete(Path),
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => Path, pool_size => 2}),
    try
        #{} = sql(Name, ~"CREATE TABLE t (id INTEGER)"),
        Pool = whereis(Name),
        Self = self(),
        Writer = spawn(fun() ->
            Self !
                {written,
                    kura_driver_sqlite:transaction(
                        kura_pool_sqlite,
                        Name,
                        fun() ->
                            #{} = sql(Name, ~"INSERT INTO t VALUES (1)"),
                            Self ! {in_transaction, self()},
                            receive
                                go -> ok
                            end,
                            sql(Name, ~"INSERT INTO t VALUES (2)")
                        end,
                        #{}
                    )}
        end),
        receive
            {in_transaction, Writer} -> ok
        after 1000 -> error(never_wrote)
        end,
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        ok = esqlite3:close(Conn),
        ?assertEqual(ok, kura_pool_sqlite:checkin(Name, Token)),
        ?assertEqual(Pool, whereis(Name)),
        Writer ! go,
        receive
            {written, Written} -> ?assertMatch(#{command := insert}, Written)
        after 2000 -> error(never_committed)
        end,
        ?assertMatch(
            #{rows := [#{id := 1}, #{id := 2}]}, sql(Name, ~"SELECT id FROM t ORDER BY id")
        ),
        {First, FirstToken} = checkout_within(Name, 1000),
        {Second, SecondToken} = checkout_within(Name, 1000),
        ?assertEqual([[1]], esqlite3:q(First, ~"SELECT 1")),
        ?assertEqual([[1]], esqlite3:q(Second, ~"SELECT 1")),
        ok = kura_pool_sqlite:checkin(Name, FirstToken),
        ok = kura_pool_sqlite:checkin(Name, SecondToken)
    after
        kura_pool_sqlite:stop_pool(Name),
        file:delete(Path)
    end.

checkin_after_give_away_returns_the_connection_test() ->
    Name = pool_for_give_away_checkin,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        Holder = spawn(fun() ->
            receive
                never -> ok
            end
        end),
        ok = kura_pool_sqlite:give_away(Token, Holder, gift),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertMatch({ok, Conn, _}, kura_pool_sqlite:checkout(Name, #{})),
        ok = kill(Holder)
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

status_does_not_list_leases_test() ->
    Name = pool_for_status,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        {ok, _Conn, {Name, _, Lease}} = kura_pool_sqlite:checkout(Name, #{}),
        Status = lists:flatten(io_lib:format("~p", [sys:get_status(Name)])),
        ?assertEqual(nomatch, string:find(Status, ref_to_list(Lease)))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

temp_table_does_not_shadow_for_the_next_borrower_test() ->
    with_file_pool(pool_for_temp_table, fun(Name) ->
        ok = planted(Name, [
            ~"CREATE TEMP TABLE t (id INTEGER)", ~"INSERT INTO temp.t VALUES (2)"
        ]),
        #{} = sql(Name, ~"INSERT INTO t VALUES (1)"),
        ?assertMatch(#{rows := [#{id := 1}]}, sql(Name, ~"SELECT id FROM t"))
    end).

temp_trigger_does_not_see_the_next_borrowers_writes_test() ->
    with_file_pool(pool_for_temp_trigger, fun(Name) ->
        #{} = sql(Name, ~"CREATE TABLE copied (id INTEGER)"),
        ok = planted(Name, [
            ~"CREATE TEMP TRIGGER copy AFTER INSERT ON main.t BEGIN INSERT INTO copied VALUES (NEW.id); END"
        ]),
        #{} = sql(Name, ~"INSERT INTO t VALUES (1)"),
        ?assertMatch(#{rows := []}, sql(Name, ~"SELECT id FROM copied"))
    end).

query_only_is_not_inherited_test() ->
    with_file_pool(pool_for_query_only, fun(Name) ->
        #{} = sql(Name, ~"PRAGMA query_only = 1"),
        ?assertMatch(#{command := insert}, sql(Name, ~"INSERT INTO t VALUES (1)"))
    end).

writable_schema_is_not_inherited_test() ->
    with_file_pool(pool_for_writable_schema, fun(Name) ->
        #{} = sql(Name, ~"PRAGMA writable_schema = ON"),
        ?assertMatch(#{rows := [#{writable_schema := 0}]}, sql(Name, ~"PRAGMA writable_schema"))
    end).

safety_settings_are_not_inherited_test_() ->
    [
        {Setting, fun() ->
            with_file_pool(pool_for_safety_settings, fun(Name) ->
                Key = binary_to_atom(Setting),
                #{rows := [#{Key := Default}]} = sql(Name, [~"PRAGMA ", Setting]),
                Changed = 1 - Default,
                ?assertEqual(
                    [[Changed]],
                    kura_pool:with_conn(kura_pool_sqlite, Name, fun(Conn) ->
                        ok = esqlite3:exec(Conn, [
                            ~"PRAGMA ", Setting, ~" = ", integer_to_binary(Changed)
                        ]),
                        ok = kura_pool_sqlite:dirty(Name, Conn),
                        esqlite3:q(Conn, [~"PRAGMA ", Setting])
                    end)
                ),
                ?assertMatch(#{rows := [#{Key := Default}]}, sql(Name, [~"PRAGMA ", Setting]))
            end)
        end}
     || Setting <- [~"foreign_keys", ~"trusted_schema", ~"ignore_check_constraints"]
    ].

attached_database_is_not_inherited_test() ->
    with_file_pool(pool_for_attach, fun(Name) ->
        Attached = db_path(pool_for_attach_other),
        try
            #{} = sql(Name, [~"ATTACH '", Attached, ~"' AS other"]),
            ?assertMatch(
                #{rows := [#{name := ~"main"}]}, sql(Name, ~"PRAGMA database_list")
            )
        after
            file:delete(Attached)
        end
    end).

dml_in_any_case_or_under_with_keeps_the_connection_test() ->
    with_file_pool(pool_for_clean_dml, fun(Name) ->
        {Conn, Token} = checkout_within(Name, 1000),
        ok = esqlite3:exec(Conn, ~"CREATE TEMP TABLE marker (id INTEGER)"),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertMatch(#{command := select}, sql(Name, ~"select id from t")),
        ?assertMatch(#{command := insert}, sql(Name, ~"Insert INTO t VALUES (1)")),
        #{} = sql(Name, ~"WITH x AS (SELECT 1) SELECT * FROM x"),
        #{} = sql(Name, ~"with x(id) as (select 2) insert into t select id from x"),
        ?assertMatch({Conn, _}, checkout_within(Name, 1000))
    end).

ddl_on_main_keeps_the_connection_test() ->
    Name = pool_for_kept_ddl,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        #{} = sql(Name, ~"CREATE TABLE t (id INTEGER)"),
        #{} = sql(Name, ~"PRAGMA busy_timeout = 100"),
        ?assertMatch(#{rows := [#{timeout := 100}]}, sql(Name, ~"PRAGMA busy_timeout")),
        ?assertMatch(#{rows := []}, sql(Name, ~"SELECT id FROM t"))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

stop_pool_does_not_wait_for_a_running_statement_test() ->
    Name = pool_for_stop_while_running,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    Self = self(),
    Borrower = spawn(fun() ->
        {ok, Conn, _Token} = kura_pool_sqlite:checkout(Name, #{}),
        Self ! {running, self()},
        esqlite3:q(
            Conn,
            ~"SELECT (WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 30000000) SELECT count(*) FROM c)"
        )
    end),
    try
        receive
            {running, Borrower} -> ok
        after 1000 -> error(never_ran)
        end,
        ok = wait_in_nif(Borrower, {esqlite3_nif, step, 1}),
        {Elapsed, ok} = timer:tc(kura_pool_sqlite, stop_pool, [Name]),
        ?assert(Elapsed < 1000000)
    after
        ok = kill(Borrower),
        kura_pool_sqlite:stop_pool(Name)
    end.

stop_pool_leaves_a_lease_in_use_working_test() ->
    Name = pool_for_stop_mid_lease,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        #{} = sql(Name, ~"CREATE TABLE t (id INTEGER)"),
        ?assertMatch(
            #{command := insert},
            kura_driver_sqlite:transaction(
                kura_pool_sqlite,
                Name,
                fun() ->
                    #{} = sql(Name, ~"INSERT INTO t VALUES (1)"),
                    Pool = whereis(Name),
                    true = is_pid(Pool),
                    ok = kura_pool_sqlite:stop_pool(Name),
                    ok = wait_for_exit(Pool),
                    sql(Name, ~"INSERT INTO t VALUES (2)")
                end,
                #{}
            )
        )
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

write_after_a_busy_statement_is_committed_test() ->
    Name = pool_for_busy_statement,
    Path = db_path(Name),
    _ = file:delete(Path),
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => Path, pool_size => 1}),
    {ok, Other} = esqlite3:open(binary_to_list(Path)),
    try
        #{} = sql(Name, ~"CREATE TABLE t (id INTEGER)"),
        #{} = sql(Name, ~"PRAGMA busy_timeout = 50"),
        ok = esqlite3:exec(Other, ~"BEGIN IMMEDIATE"),
        Self = self(),
        Busy = spawn(fun() ->
            Self !
                {busy,
                    try sql(Name, ~"INSERT INTO t VALUES (1)") of
                        Result -> Result
                    catch
                        error:Reason -> Reason
                    end},
            receive
                never -> ok
            end
        end),
        receive
            {busy, Busied} -> ?assertEqual({case_clause, '$busy'}, Busied)
        after 2000 -> error(never_busy)
        end,
        ok = esqlite3:exec(Other, ~"ROLLBACK"),
        ?assertMatch(#{command := insert}, sql(Name, ~"INSERT INTO t VALUES (2)")),
        ?assertEqual([[2]], esqlite3:q(Other, ~"SELECT id FROM t")),
        ok = kill(Busy)
    after
        _ = esqlite3:close(Other),
        kura_pool_sqlite:stop_pool(Name),
        file:delete(Path)
    end.

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

with_file_pool(Name, Test) ->
    Path = db_path(Name),
    _ = file:delete(Path),
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => Path, pool_size => 1}),
    try
        #{} = sql(Name, ~"CREATE TABLE t (id INTEGER)"),
        Test(Name)
    after
        kura_pool_sqlite:stop_pool(Name),
        file:delete(Path)
    end.

planted(Name, Statements) ->
    kura_driver_sqlite:transaction(
        kura_pool_sqlite,
        Name,
        fun() ->
            _ = [#{} = sql(Name, Statement) || Statement <- Statements],
            ok
        end,
        #{}
    ).

wait_in_nif(Pid, Nif) ->
    wait_in_nif(Pid, Nif, 200).

wait_in_nif(_Pid, _Nif, 0) ->
    error(never_entered_nif);
wait_in_nif(Pid, Nif, N) ->
    case erlang:process_info(Pid, current_function) of
        {current_function, Nif} ->
            ok;
        _ ->
            timer:sleep(5),
            wait_in_nif(Pid, Nif, N - 1)
    end.

checkout_within(Name, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    checkout_within_loop(Name, Deadline).

checkout_within_loop(Name, Deadline) ->
    case kura_pool_sqlite:checkout(Name, #{}) of
        {ok, Conn, Token} ->
            {Conn, Token};
        {error, no_conns} ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    error(no_checkout);
                false ->
                    timer:sleep(10),
                    checkout_within_loop(Name, Deadline)
            end
    end.

db_path(Name) ->
    iolist_to_binary(filename:join(os:getenv("TMPDIR", "/tmp"), atom_to_list(Name) ++ ".db")).
