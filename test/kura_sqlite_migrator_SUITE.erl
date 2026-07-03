-module(kura_sqlite_migrator_SUITE).
-moduledoc """
End-to-end migration through `kura_migrator:migrate/1` against an
in-memory SQLite database. Pins the SQLite migration runtime path
that asobi-CT covers for Postgres but no app exercises for SQLite.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    migrate_creates_table/1,
    migrate_records_version_in_schema_migrations/1,
    rollback_drops_table/1
]).

-define(REPO, kura_sqlite_e2e_test_repo).
-define(APP, kura_sqlite_e2e_test_app).
-define(VERSION, 20260510000000).

all() ->
    [
        migrate_creates_table,
        migrate_records_version_in_schema_migrations,
        rollback_drops_table
    ].

init_per_suite(Config) ->
    %% Make sure backend modules are loaded before kura_app:resolve_backends
    %% looks them up.
    {module, _} = code:ensure_loaded(kura_backend_sqlite),
    application:set_env(kura, repos, #{
        ?REPO => #{
            backend => kura_backend_sqlite,
            database => <<":memory:">>,
            pool_size => 1
        }
    }),
    application:set_env(kura, ensure_database, false),
    {ok, _} = application:ensure_all_started(kura),
    %% Synthetic app so kura_migrator:discover_migrations/1 finds the test
    %% migration via application:get_key(?APP, modules).
    AppSpec =
        {application, ?APP, [
            {description, "test app for kura_sqlite_migrator_SUITE"},
            {vsn, "0.0.1"},
            {modules, [?REPO, m20260510000000_e2e_create_widgets]},
            {registered, []},
            {applications, [kernel, stdlib]}
        ]},
    ok = application:load(AppSpec),
    Config.

end_per_suite(_Config) ->
    application:unload(?APP),
    kura_pool_sqlite:stop_pool(?REPO),
    application:stop(kura),
    application:unset_env(kura, repos),
    application:unset_env(kura, ensure_database),
    ok.

migrate_creates_table(_Config) ->
    {ok, [?VERSION]} = kura_migrator:migrate(?REPO),
    %% Verify the widgets table is queryable.
    Result = kura_db:query(?REPO, ~"SELECT name FROM widgets WHERE 1=0", []),
    ?assertMatch(#{rows := []}, Result).

migrate_records_version_in_schema_migrations(_Config) ->
    %% migrate_creates_table already applied, so this run should be a no-op.
    {ok, []} = kura_migrator:migrate(?REPO),
    Result = kura_db:query(
        ?REPO, ~"SELECT version FROM schema_migrations ORDER BY version", []
    ),
    ?assertMatch(#{rows := [#{version := ?VERSION}]}, Result).

rollback_drops_table(_Config) ->
    {ok, [?VERSION]} = kura_migrator:rollback(?REPO),
    Result = kura_db:query(
        ?REPO,
        ~"SELECT name FROM sqlite_master WHERE type='table' AND name='widgets'",
        []
    ),
    ?assertMatch(#{rows := []}, Result).
