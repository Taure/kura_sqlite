-module(kura_pool_sqlite_sup).
-moduledoc false.

-behaviour(supervisor).

-export([start/3, stop/1]).
-export([init/1]).

-doc """
Start a pool's supervisor, not linked to the caller, so the pool outlives
the process that started it and is restarted if it crashes. The start runs
in a process of its own that traps exits, so a pool that fails to start
returns an error rather than killing the caller.
""".
-spec start(atom(), binary() | string(), non_neg_integer()) -> {ok, pid()} | {error, term()}.
start(Name, DbPath, Size) ->
    Caller = self(),
    {Starter, Monitor} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        Caller ! {self(), started(supervisor:start_link(?MODULE, {Name, DbPath, Size}))}
    end),
    receive
        {Starter, Result} ->
            true = erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Starter, Reason} ->
            {error, Reason}
    end.

-spec started(supervisor:startlink_ret()) -> {ok, pid()} | {error, term()}.
started({ok, Supervisor}) ->
    true = unlink(Supervisor),
    {ok, Supervisor};
started({error, {shutdown, {failed_to_start_child, pool, {already_started, Pid}}}}) ->
    {error, {already_started, Pid}};
started({error, {shutdown, {failed_to_start_child, pool, Reason}}}) ->
    {error, Reason};
started({error, Reason}) ->
    {error, Reason}.

-spec stop(pid()) -> ok.
stop(Supervisor) ->
    try
        gen_server:stop(Supervisor)
    catch
        exit:noproc -> ok
    end.

-spec init({atom(), binary() | string(), non_neg_integer()}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Name, DbPath, Size}) ->
    Pool = #{
        id => pool,
        start => {kura_pool_sqlite, start_link, [Name, DbPath, Size, self()]},
        restart => permanent,
        shutdown => 5000
    },
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Pool]}}.
