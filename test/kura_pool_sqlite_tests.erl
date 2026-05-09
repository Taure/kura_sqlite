-module(kura_pool_sqlite_tests).
-include_lib("eunit/include/eunit.hrl").

start_pool_opens_in_memory_db_test() ->
    Name = pool_for_in_memory,
    {ok, _} = kura_pool_sqlite:start_pool(Name, #{database => <<":memory:">>, pool_size => 2}),
    try
        ?assertNotEqual(undefined, ets:whereis(Name)),
        ?assertMatch([{available, [_, _]}], ets:lookup(Name, available))
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
