-module(kura_pool_sqlite_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-export([log/2]).

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
        {Elapsed, Result} = timer:tc(kura_pool_sqlite, checkout, [Name, #{timeout => 0}]),
        ?assertEqual({error, no_conns}, Result),
        ?assert(Elapsed < 400000)
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
        ?assertEqual({error, busy}, sql(Name, ~"INSERT INTO t VALUES (2)")),
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
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{timeout => 0})),
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
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{timeout => 0})),
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
        {result, {error, 14}},
        in_fresh(fun() ->
            kura_pool_sqlite:start_pool(pool_for_failed_start, #{
                database => ~"/nonexistent_dir/x.db", pool_size => 1
            })
        end)
    ).

start_on_a_utf16_database_is_refused_test() ->
    Path = db_path(pool_for_utf16),
    _ = file:delete(Path),
    {ok, Setup} = esqlite3:open(binary_to_list(Path)),
    ok = esqlite3:exec(Setup, ~"PRAGMA encoding = 'UTF-16'; CREATE TABLE t (id INTEGER)"),
    ok = esqlite3:close(Setup),
    try
        ?assertMatch(
            {result, {error, {unsupported_encoding, ~"UTF-16le"}}},
            in_fresh(fun() ->
                kura_pool_sqlite:start_pool(pool_for_utf16, #{database => Path, pool_size => 1})
            end)
        )
    after
        file:delete(Path)
    end.

start_on_a_file_that_is_not_a_database_returns_the_sqlite_error_test() ->
    Path = db_path(pool_for_not_a_database),
    ok = file:write_file(Path, binary:copy(~"not a database", 512)),
    try
        {result, {error, Reason}} = in_fresh(fun() ->
            kura_pool_sqlite:start_pool(pool_for_not_a_database, #{database => Path})
        end),
        ?assertEqual(26, Reason)
    after
        file:delete(Path)
    end.

database_switched_to_another_encoding_stops_the_pool_test() ->
    Name = pool_for_shared_encoding,
    Path = db_path(Name),
    _ = file:delete(Path),
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => Path, pool_size => 2}),
    try
        {Switcher, SwitcherToken} = checkout_within(Name, 1000),
        {Reader, ReaderToken} = checkout_within(Name, 1000),
        ok = esqlite3:exec(Switcher, ~"PRAGMA encoding = 'UTF-16le'; CREATE TABLE t (id INTEGER)"),
        ok = kura_pool_sqlite:dirty(Name, Switcher),
        [[0]] = esqlite3:q(Reader, ~"SELECT count(*) FROM t"),
        ok = kura_pool_sqlite:checkin(Name, SwitcherToken),
        ok = kura_pool_sqlite:checkin(Name, ReaderToken),
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{}))
    after
        kura_pool_sqlite:stop_pool(Name),
        file:delete(Path)
    end.

lease_that_switches_the_encoding_is_not_inherited_test() ->
    Name = pool_for_encoding_switch,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{pool_size => 1}),
    try
        #{} = sql(Name, ~"PRAGMA encoding = 'UTF-16'"),
        ?assertMatch(#{rows := [#{encoding := ~"UTF-8"}]}, sql(Name, ~"PRAGMA encoding"))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

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
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{timeout => 0})),
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

reset_that_raises_is_logged_test() ->
    Name = pool_for_raising_reset,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    ok = logger:add_handler(Name, ?MODULE, #{config => #{test => self()}}),
    try
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        ok = esqlite3:close(Conn),
        ok = kura_pool_sqlite:checkin(Name, Token),
        receive
            {logged, connection_reset_failed} -> ok
        after 1000 -> error(not_logged)
        end,
        ?assertMatch({_, _}, checkout_within(Name, 1000))
    after
        _ = logger:remove_handler(Name),
        kura_pool_sqlite:stop_pool(Name)
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
        Waiter = waiter(Name, #{}),
        ok = await_waiting(Name, 1),
        [Waiting] = waiting_leases(Name),
        Status = lists:flatten(io_lib:format("~p", [sys:get_status(Name)])),
        ?assertEqual(nomatch, string:find(Status, ref_to_list(Lease))),
        ?assertEqual(nomatch, string:find(Status, ref_to_list(Waiting))),
        ?assertNotEqual(nomatch, string:find(Status, "waiting => 1")),
        ok = kill(Waiter)
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

every_connection_enforces_foreign_keys_test() ->
    Name = pool_for_foreign_keys,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{pool_size => 3}),
    try
        Leases = [checkout_within(Name, 1000) || _ <- lists:seq(1, 3)],
        ?assertEqual(
            [[[1]], [[1]], [[1]]],
            [esqlite3:q(Conn, ~"PRAGMA foreign_keys") || {Conn, _} <- Leases]
        ),
        [ok = kura_pool_sqlite:checkin(Name, Token) || {_, Token} <- Leases]
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

on_delete_cascade_removes_the_children_test() ->
    with_file_pool(pool_for_cascade, fun(Name) ->
        #{} = sql(Name, ~"CREATE TABLE parent (id INTEGER PRIMARY KEY)"),
        #{} = sql(
            Name,
            ~"CREATE TABLE child (id INTEGER, parent_id INTEGER REFERENCES parent (id) ON DELETE CASCADE)"
        ),
        #{} = sql(Name, ~"INSERT INTO parent VALUES (1)"),
        #{} = sql(Name, ~"INSERT INTO child VALUES (1, 1)"),
        #{} = sql(Name, ~"DELETE FROM parent WHERE id = 1"),
        ?assertMatch(#{rows := []}, sql(Name, ~"SELECT id FROM child"))
    end).

reference_to_a_missing_row_is_refused_test() ->
    with_file_pool(pool_for_restrict, fun(Name) ->
        #{} = sql(Name, ~"CREATE TABLE parent (id INTEGER PRIMARY KEY)"),
        #{} = sql(Name, ~"CREATE TABLE child (parent_id INTEGER REFERENCES parent (id))"),
        ?assertEqual({error, 787}, sql(Name, ~"INSERT INTO child VALUES (99)"))
    end).

replaced_connection_enforces_foreign_keys_test() ->
    Name = pool_for_replaced_foreign_keys,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{pool_size => 1}),
    try
        {Closed, ClosedToken} = checkout_within(Name, 1000),
        ok = esqlite3:close(Closed),
        ok = kura_pool_sqlite:checkin(Name, ClosedToken),
        {Fresh, FreshToken} = checkout_within(Name, 1000),
        ?assertEqual([[1]], esqlite3:q(Fresh, ~"PRAGMA foreign_keys")),
        ok = kura_pool_sqlite:checkin(Name, FreshToken)
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

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
        #{} = sql(Name, ~"PRAGMA cache_size = 100"),
        ?assertMatch(#{rows := [#{cache_size := 100}]}, sql(Name, ~"PRAGMA cache_size")),
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
        ok = kura_pool:with_conn(kura_pool_sqlite, Name, fun(Conn) ->
            esqlite3:exec(Conn, ~"PRAGMA busy_timeout = 50")
        end),
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
            {busy, Busied} -> ?assertEqual({error, busy}, Busied)
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

exclusive_locking_mode_is_not_inherited_test() ->
    with_file_pool(pool_for_locking_mode, fun(Name) ->
        #{} = sql(Name, ~"PRAGMA locking_mode = EXCLUSIVE"),
        #{} = sql(Name, ~"INSERT INTO t VALUES (1)"),
        {ok, Other} = esqlite3:open(binary_to_list(db_path(Name))),
        try
            ok = esqlite3:exec(Other, ~"PRAGMA busy_timeout = 0"),
            ?assertEqual(ok, esqlite3:exec(Other, ~"INSERT INTO t VALUES (2)"))
        after
            _ = esqlite3:close(Other)
        end
    end).

connection_settings_are_not_inherited_test() ->
    with_file_pool(pool_for_settings, fun(Name) ->
        _ = [
            begin
                Default = sql(Name, [~"PRAGMA ", Setting]),
                #{} = sql(Name, [~"PRAGMA ", Setting, ~" = ", Value]),
                ?assertEqual({Setting, Default}, {Setting, sql(Name, [~"PRAGMA ", Setting])})
            end
         || {Setting, Value} <- changed_settings()
        ],
        ok
    end).

journal_mode_off_is_not_inherited_test() ->
    with_file_pool(pool_for_journal_off, fun(Name) ->
        #{} = sql(Name, ~"PRAGMA journal_mode = OFF"),
        ?assertMatch(#{rows := [#{journal_mode := ~"delete"}]}, sql(Name, ~"PRAGMA journal_mode"))
    end).

switch_to_wal_keeps_the_connection_test() ->
    with_file_pool(pool_for_wal, fun(Name) ->
        #{} = sql(Name, ~"PRAGMA journal_mode = WAL"),
        {Conn, Token} = checkout_within(Name, 1000),
        ok = kura_pool_sqlite:checkin(Name, Token),
        #{} = sql(Name, ~"CREATE TABLE u (id INTEGER)"),
        ?assertMatch({Conn, _}, checkout_within(Name, 1000))
    end).

settings_after_a_switch_to_wal_become_the_baseline_test() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "pool_for_wal_baseline"),
    _ = file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    Name = pool_for_wal_baseline,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{
        database => filename:join(Dir, "db"), pool_size => 1
    }),
    try
        #{} = sql(Name, ~"PRAGMA journal_mode = WAL"),
        {Conn, Token} = checkout_within(Name, 1000),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ok = file:del_dir_r(Dir),
        #{} = sql(Name, ~"PRAGMA user_version"),
        ?assertMatch({Conn, _}, checkout_within(Name, 1000))
    after
        kura_pool_sqlite:stop_pool(Name),
        file:del_dir_r(Dir)
    end.

dropped_connection_stays_usable_by_a_process_still_holding_it_test() ->
    with_file_pool(pool_for_dropped_in_use, fun(Name) ->
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        Holder = spawn(fun() ->
            receive
                never -> ok
            end
        end),
        ok = kura_pool_sqlite:give_away(Token, Holder, gift),
        ok = esqlite3:exec(Conn, ~"CREATE TEMP TABLE scratch (id INTEGER)"),
        ok = kura_pool_sqlite:dirty(Name, Conn),
        ok = kill(Holder),
        {Fresh, FreshToken} = checkout_within(Name, 1000),
        ?assertNotEqual(Conn, Fresh),
        ok = kura_pool_sqlite:checkin(Name, FreshToken),
        ?assertEqual([[0]], esqlite3:q(Conn, ~"SELECT count(*) FROM scratch"))
    end).

connection_that_could_not_be_replaced_is_opened_on_checkout_test() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "pool_for_late_reopen"),
    _ = file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    Name = pool_for_late_reopen,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{
        database => filename:join(Dir, "db"), pool_size => 1
    }),
    ok = logger:add_handler(Name, ?MODULE, #{config => #{test => self()}}),
    try
        ok = file:del_dir_r(Dir),
        ok = planted(Name, [~"CREATE TEMP TABLE scratch (id INTEGER)"]),
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{})),
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{})),
        ?assertEqual([connection_not_replaced], logged()),
        ok = file:make_dir(Dir),
        {ok, _Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        ?assertEqual({error, no_conns}, kura_pool_sqlite:checkout(Name, #{timeout => 0})),
        ok = kura_pool_sqlite:checkin(Name, Token)
    after
        _ = logger:remove_handler(Name),
        kura_pool_sqlite:stop_pool(Name),
        file:del_dir_r(Dir)
    end.

reclaimed_given_away_connection_is_not_lent_again_test() ->
    Name = pool_for_reclaimed_gift,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        Holder = spawn(fun() ->
            receive
                never -> ok
            end
        end),
        ok = kura_pool_sqlite:give_away(Token, Holder, gift),
        ok = kill(Holder),
        {Fresh, FreshToken} = checkout_within(Name, 1000),
        ?assertNotEqual(Conn, Fresh),
        ok = kura_pool_sqlite:checkin(Name, FreshToken),
        ok = kura_pool_sqlite:stop_pool(Name),
        ?assertEqual([[1]], esqlite3:q(Conn, ~"SELECT 1"))
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

checkout_waits_for_a_checkin_test() ->
    with_held(pool_for_waiting_checkout, fun(Name, Conn, Token) ->
        Waiter = waiter(Name, #{}),
        ok = await_waiting(Name, 1),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertMatch({ok, Conn, _}, result_of(Waiter)),
        ?assertEqual(0, waiting(Name)),
        ok = released(Waiter)
    end).

checkout_that_runs_out_of_time_returns_no_conns_test() ->
    with_held(pool_for_waiting_timeout, fun(Name, Conn, Token) ->
        {Elapsed, Result} = timer:tc(kura_pool_sqlite, checkout, [Name, #{timeout => 100}]),
        ?assertEqual({error, no_conns}, Result),
        ?assert(Elapsed >= 100000),
        ?assertEqual(0, waiting(Name)),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertMatch({ok, Conn, _}, kura_pool_sqlite:checkout(Name, #{timeout => 0}))
    end).

waiters_are_served_in_the_order_they_came_test() ->
    with_held(pool_for_waiting_order, fun(Name, Conn, Token) ->
        First = waiter(Name, #{timeout => 5000}),
        ok = await_waiting(Name, 1),
        Second = waiter(Name, #{timeout => 5000}),
        ok = await_waiting(Name, 2),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertMatch({ok, Conn, _}, result_of(First)),
        ?assertEqual(1, waiting(Name)),
        ok = released(First),
        ?assertMatch({ok, Conn, _}, result_of(Second)),
        ok = released(Second)
    end).

waiter_that_died_is_not_served_test() ->
    with_held(pool_for_dead_waiter, fun(Name, Conn, Token) ->
        Pool = whereis(Name),
        {ok, Received} = received_by(Pool, fun() ->
            Dead = waiter(Name, #{timeout => 100}),
            ok = await_waiting(Name, 1),
            ok = kill(Dead),
            ok = await_waiting(Name, 0),
            Live = waiter(Name, #{timeout => 5000}),
            ok = await_waiting(Name, 1),
            ok = kura_pool_sqlite:checkin(Name, Token),
            ?assertMatch({ok, Conn, _}, result_of(Live)),
            ok = released(Live),
            timer:sleep(200)
        end),
        ?assertEqual([], timeouts(Received))
    end).

served_waiter_leaves_no_timer_behind_test() ->
    with_held(pool_for_served_timer, fun(Name, _Conn, Token) ->
        Pool = whereis(Name),
        {ok, Received} = received_by(Pool, fun() ->
            Waiter = waiter(Name, #{timeout => 100}),
            ok = await_waiting(Name, 1),
            ok = kura_pool_sqlite:checkin(Name, Token),
            ?assertMatch({ok, _, _}, result_of(Waiter)),
            ok = released(Waiter),
            timer:sleep(200)
        end),
        ?assertEqual([], timeouts(Received))
    end).

checkout_without_a_timeout_waits_test() ->
    with_held(pool_for_endless_wait, fun(Name, Conn, Token) ->
        Waiter = waiter(Name, #{timeout => infinity}),
        ok = await_waiting(Name, 1),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertMatch({ok, Conn, _}, result_of(Waiter)),
        ok = released(Waiter)
    end).

checkout_wait_longer_than_a_timer_can_run_waits_test() ->
    with_held(pool_for_longest_wait, fun(Name, Conn, Token) ->
        Waiters = [
            waiter(Name, #{timeout => Wait})
         || Wait <- [16#FFFFFFFF - 500, 16#FFFFFFFF - 499, 5000000000]
        ],
        ok = await_waiting(Name, 3),
        ok = kura_pool_sqlite:checkin(Name, Token),
        _ = [
            begin
                ?assertMatch({ok, Conn, _}, result_of(Waiter)),
                ok = released(Waiter)
            end
         || Waiter <- Waiters
        ]
    end).

waiter_gone_from_the_middle_of_the_queue_is_skipped_test() ->
    with_held(pool_for_middle_waiter, fun(Name, Conn, Token) ->
        First = waiter(Name, #{}),
        ok = await_waiting(Name, 1),
        Gone = waiter(Name, #{}),
        ok = await_waiting(Name, 2),
        Last = waiter(Name, #{}),
        ok = await_waiting(Name, 3),
        ok = kill(Gone),
        ok = await_waiting(Name, 2),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertMatch({ok, Conn, _}, result_of(First)),
        ok = released(First),
        ?assertMatch({ok, Conn, _}, result_of(Last)),
        ok = released(Last),
        ?assertEqual(0, waiting(Name))
    end).

checkout_with_a_bad_timeout_raises_test() ->
    with_held(pool_for_bad_timeout, fun(Name, _Conn, _Token) ->
        ?assertError({badarg, {timeout, -1}}, kura_pool_sqlite:checkout(Name, #{timeout => -1})),
        ?assertError(
            {badarg, {timeout, soon}}, kura_pool_sqlite:checkout(Name, #{timeout => soon})
        ),
        ?assertEqual(0, waiting(Name))
    end).

checkout_does_not_wait_when_nothing_can_come_back_test() ->
    Name = pool_for_empty_wait,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 0}),
    try
        {Elapsed, Result} = timer:tc(kura_pool_sqlite, checkout, [Name, #{timeout => 5000}]),
        ?assertEqual({error, no_conns}, Result),
        ?assert(Elapsed < 1000000)
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

replacement_connection_goes_to_a_waiter_test() ->
    with_file_pool(pool_for_waiting_replacement, fun(Name) ->
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        ok = esqlite3:exec(Conn, ~"CREATE TEMP TABLE scratch (id INTEGER)"),
        ok = kura_pool_sqlite:dirty(Name, Conn),
        Waiter = waiter(Name, #{timeout => 5000}),
        ok = await_waiting(Name, 1),
        ok = kura_pool_sqlite:checkin(Name, Token),
        {ok, Fresh, _} = result_of(Waiter),
        ?assertNotEqual(Conn, Fresh),
        ok = released(Waiter)
    end).

waiter_is_refused_when_no_connection_can_be_opened_test() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "pool_for_waiting_reopen"),
    _ = file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    Name = pool_for_waiting_reopen,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{
        database => filename:join(Dir, "db"), pool_size => 1
    }),
    try
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        ok = esqlite3:exec(Conn, ~"CREATE TEMP TABLE scratch (id INTEGER)"),
        ok = kura_pool_sqlite:dirty(Name, Conn),
        ok = file:del_dir_r(Dir),
        Waiter = waiter(Name, #{timeout => 5000}),
        ok = await_waiting(Name, 1),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertEqual({error, no_conns}, result_of(Waiter)),
        ?assertEqual(0, waiting(Name))
    after
        kura_pool_sqlite:stop_pool(Name),
        file:del_dir_r(Dir)
    end.

waiter_is_refused_when_the_database_leaves_utf8_test() ->
    Name = pool_for_waiting_encoding,
    Path = db_path(Name),
    _ = file:delete(Path),
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => Path, pool_size => 2}),
    try
        Pool = whereis(Name),
        {Switcher, SwitcherToken} = checkout_within(Name, 1000),
        {_Reader, ReaderToken} = checkout_within(Name, 1000),
        {Waiter, Received} = received_by(Pool, fun() ->
            Waiter = waiter(Name, #{timeout => 300}),
            ok = await_waiting(Name, 1),
            ok = esqlite3:exec(
                Switcher, ~"PRAGMA encoding = 'UTF-16le'; CREATE TABLE t (id INTEGER)"
            ),
            ok = kura_pool_sqlite:dirty(Name, Switcher),
            ok = kura_pool_sqlite:checkin(Name, SwitcherToken),
            ?assertEqual({error, no_conns}, result_of(Waiter)),
            ok = released(Waiter),
            timer:sleep(400),
            Waiter
        end),
        ?assertEqual([], timeouts(Received)),
        ?assertEqual([], [Down || {'DOWN', _, process, Pid, _} = Down <- Received, Pid =:= Waiter]),
        ok = kura_pool_sqlite:checkin(Name, ReaderToken)
    after
        kura_pool_sqlite:stop_pool(Name),
        file:delete(Path)
    end.

open_in_a_missing_directory_is_refused_before_esqlite_test() ->
    Session = trace:session_create(?MODULE, self(), []),
    try
        _ = trace:process(Session, new, true, [call]),
        1 = trace:function(Session, {esqlite3, open, 1}, true, [local]),
        ?assertEqual(
            {result, {error, 14}},
            in_fresh(fun() ->
                kura_pool_sqlite:start_pool(pool_for_missing_directory, #{
                    database => ~"/nonexistent_dir/x.db", pool_size => 1
                })
            end)
        ),
        ?assertEqual([], traced(Session))
    after
        trace:session_destroy(Session)
    end.

file_uri_is_refused_before_esqlite_test() ->
    Path = db_path(pool_for_file_uri),
    _ = file:delete(Path),
    ?assertEqual({error, uri_not_supported}, opened_with(<<"file:", Path/binary>>)),
    ?assertEqual({error, uri_not_supported}, opened_with(~"file:/nonexistent_dir/x.db")),
    ?assertNot(filelib:is_file(Path)).

dangling_symlink_is_refused_before_esqlite_test() ->
    Link = db_path(pool_for_dangling_symlink),
    _ = file:delete(Link),
    ok = file:make_symlink(~"/nonexistent_dir/x.db", Link),
    try
        ?assertEqual({error, 14}, opened_with(Link))
    after
        file:delete(Link)
    end.

path_holding_a_nul_is_refused_before_esqlite_test() ->
    Path = db_path(pool_for_nul),
    ?assertEqual({error, invalid_filename}, opened_with(<<Path/binary, 0>>)),
    ?assertEqual({error, invalid_filename}, opened_with(binary_to_list(Path) ++ [0])),
    ?assertNot(filelib:is_file(Path)).

string_path_holding_a_wide_character_is_refused_before_esqlite_test() ->
    ?assertEqual(
        {error, invalid_filename}, opened_with(binary_to_list(db_path(pool_for_wide)) ++ [16#3042])
    ).

unreadable_file_is_refused_before_esqlite_test() ->
    Path = db_path(pool_for_unreadable),
    ok = file:write_file(Path, ~""),
    try
        ok = file:change_mode(Path, 8#000),
        case file:read_file_info(Path) of
            {ok, #file_info{access = none}} -> ?assertEqual({error, 14}, opened_with(Path));
            {ok, #file_info{}} -> ok
        end
    after
        file:delete(Path)
    end.

read_only_file_is_opened_test() ->
    Path = db_path(pool_for_read_only),
    ok = file:write_file(Path, ~""),
    try
        ok = file:change_mode(Path, 8#444),
        ?assertMatch({ok, [_]}, opened_with(Path))
    after
        file:delete(Path)
    end.

non_ascii_path_is_opened_and_created_test() ->
    Path = db_path(pool_for_non_ascii),
    Name = <<(filename:rootname(Path))/binary, "_", "ö"/utf8, ".db">>,
    _ = file:delete(Name),
    try
        ?assertEqual({ok, [Name]}, opened_with(Name)),
        ?assert(filelib:is_regular(Name))
    after
        file:delete(Name)
    end.

non_ascii_missing_directory_is_refused_before_esqlite_test() ->
    ?assertEqual({error, 14}, opened_with(<<"/nonexistent_", "ö"/utf8, "/x.db">>)).

empty_path_opens_a_temporary_database_test() ->
    ?assertEqual({ok, [~""]}, opened_with(~"")).

%% Starts and stops a one-connection pool on Database, returning what
%% start_pool/2 returned, or the paths esqlite was asked to open.
opened_with(Database) ->
    Name = pool_for_opened_with,
    Session = trace:session_create(?MODULE, self(), []),
    try
        _ = trace:process(Session, new, true, [call]),
        1 = trace:function(Session, {esqlite3, open, 1}, true, [local]),
        {result, Started} = in_fresh(fun() ->
            case kura_pool_sqlite:start_pool(Name, #{database => Database, pool_size => 1}) of
                {ok, _} -> kura_pool_sqlite:stop_pool(Name);
                {error, _} = Error -> Error
            end
        end),
        Opened = [list_to_binary(Filename) || Filename <- traced(Session), is_list(Filename)],
        case Started of
            ok -> {ok, Opened};
            {error, _} when Opened =:= [] -> Started
        end
    after
        trace:session_destroy(Session)
    end.

checkout_that_reaches_a_backed_up_pool_late_is_not_queued_test() ->
    with_held(pool_for_backlog, fun(Name, Conn, Token) ->
        ok = sys:suspend(Name),
        Late = waiter(Name, #{timeout => 100}),
        Result =
            receive
                {checked_out, Late, Checked} -> Checked
            after 2000 -> error(never_timed_out)
            end,
        ok = sys:resume(Name),
        ?assertEqual({error, checkout_timeout}, Result),
        ?assertEqual(0, waiting(Name)),
        ok = kura_pool_sqlite:checkin(Name, Token),
        ?assertMatch({ok, Conn, _}, kura_pool_sqlite:checkout(Name, #{timeout => 0})),
        ok = kill(Late)
    end).

abandoned_checkout_leaves_the_queue_test() ->
    with_held(pool_for_abandoned_waiter, fun(Name, Conn, Token) ->
        Pool = whereis(Name),
        {ok, Received} = received_by(Pool, fun() ->
            Gone = waiter(Name, #{timeout => 1000}),
            ok = await_waiting(Name, 1),
            [Lease] = waiting_leases(Name),
            gen_server:cast(Name, {abandon, Lease}),
            ok = await_waiting(Name, 0),
            ok = kura_pool_sqlite:checkin(Name, Token),
            ?assertMatch({ok, Conn, _}, kura_pool_sqlite:checkout(Name, #{timeout => 0})),
            ok = kill(Gone),
            timer:sleep(1100)
        end),
        ?assertEqual([], timeouts(Received)),
        ?assertEqual([], [Down || {'DOWN', _, process, _, shutdown} = Down <- Received])
    end).

database_path_that_is_a_directory_is_refused_before_esqlite_test() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "pool_for_directory_path"),
    _ = file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    Session = trace:session_create(?MODULE, self(), []),
    try
        _ = trace:process(Session, new, true, [call]),
        1 = trace:function(Session, {esqlite3, open, 1}, true, [local]),
        ?assertEqual(
            {result, {error, 14}},
            in_fresh(fun() ->
                kura_pool_sqlite:start_pool(pool_for_directory_path, #{database => Dir})
            end)
        ),
        ?assertEqual([], traced(Session))
    after
        trace:session_destroy(Session),
        file:del_dir_r(Dir)
    end.

with_held(Name, Test) ->
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => ~":memory:", pool_size => 1}),
    try
        {ok, Conn, Token} = kura_pool_sqlite:checkout(Name, #{}),
        Test(Name, Conn, Token)
    after
        kura_pool_sqlite:stop_pool(Name)
    end.

waiter(Name, Opts) ->
    Self = self(),
    spawn(fun() ->
        Result = kura_pool_sqlite:checkout(Name, Opts),
        Self ! {checked_out, self(), Result},
        receive
            release ->
                case Result of
                    {ok, _Conn, Token} -> kura_pool_sqlite:checkin(Name, Token);
                    {error, _} -> ok
                end,
                Self ! {released, self()}
        end
    end).

result_of(Waiter) ->
    receive
        {checked_out, Waiter, Result} -> Result
    after 1000 -> error(still_waiting)
    end.

released(Waiter) ->
    Waiter ! release,
    receive
        {released, Waiter} -> ok
    after 1000 -> error(never_released)
    end.

waiting(Name) ->
    case sys:get_state(Name) of
        #{waiting_leases := Waiting} when is_map(Waiting) -> map_size(Waiting)
    end.

waiting_leases(Name) ->
    case sys:get_state(Name) of
        #{waiting_leases := Waiting} when is_map(Waiting) -> maps:keys(Waiting)
    end.

await_waiting(Name, N) ->
    await_waiting(Name, N, 100).

await_waiting(_Name, _N, 0) ->
    error(wrong_number_waiting);
await_waiting(Name, N, Tries) ->
    case waiting(Name) of
        N ->
            ok;
        _ ->
            timer:sleep(10),
            await_waiting(Name, N, Tries - 1)
    end.

timeouts(Received) ->
    [Message || {waited, _} = Message <- Received].

received_by(Pid, Fun) ->
    Session = trace:session_create(?MODULE, self(), []),
    try
        1 = trace:process(Session, Pid, true, ['receive']),
        Result = Fun(),
        {Result, traced(Session)}
    after
        trace:session_destroy(Session)
    end.

traced(Session) ->
    Ref = trace:delivered(Session, all),
    receive
        {trace_delivered, all, Ref} -> ok
    after 1000 -> error(trace_not_delivered)
    end,
    trace_messages().

trace_messages() ->
    receive
        {trace, _Pid, 'receive', Message} -> [Message | trace_messages()];
        {trace, _Pid, call, {esqlite3, open, [Filename]}} -> [Filename | trace_messages()]
    after 0 -> []
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
    case kura_pool_sqlite:checkout(Name, #{timeout => 0}) of
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

changed_settings() ->
    [
        {~"synchronous", ~"OFF"},
        {~"recursive_triggers", ~"ON"},
        {~"max_page_count", ~"100000"},
        {~"busy_timeout", ~"1"}
    ].

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
    case kura_pool_sqlite:checkout(Name, #{timeout => 0}) of
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
    File = atom_to_list(Name) ++ "_" ++ os:getpid() ++ ".db",
    iolist_to_binary(filename:join(os:getenv("TMPDIR", "/tmp"), File)).

logged() ->
    receive
        {logged, Event} -> [Event | logged()]
    after 0 -> []
    end.

log(#{msg := {report, #{event := Event}}}, #{config := #{test := Test}}) ->
    Test ! {logged, Event},
    ok;
log(_Event, _Config) ->
    ok.
