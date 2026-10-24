-module(kura_pool_sqlite).
-moduledoc """
SQLite pool implementation. Holds N pre-opened `esqlite3` database
connections. Each `checkout/2` hands out a connection; `checkin/2`
returns it.

## Pool process

Each pool is a `gen_server` registered under the pool name, under a
supervisor of its own that restarts it. It owns the connections, hands
each one to a single borrower at a time, and monitors the borrower. A
borrower that dies without checking in, for example one killed
mid-transaction, gets its connection reclaimed.

A checkout's token names that one lease, so a checkin or `give_away/3`
with a token from an earlier lease of the same connection does nothing.

A connection coming back, by `checkin/2` or by its borrower dying, that
is still inside a transaction is rolled back first. If the rollback
fails it is closed and a fresh one opened in its place. Closing cannot
be relied on to release what the old connection held: esqlite's close
leaves the database open when its own rollback fails, so a write lock
may stay held until the handle is garbage collected. On `:memory:` a
fresh connection is an empty database.

A restarted pool opens new connections. Connections leased before the
restart are no longer the pool's: their checkins are ignored, and if
the pool stopped normally they were closed with it.

`pool_size` from `start_pool/2` opts pre-opens N connections.

## Example

```erlang
{ok, _Pid} = kura_pool_sqlite:start_pool(my_pool, #{
    database => <<":memory:">>,
    pool_size => 1
}).
```
""".

-behaviour(gen_server).
-behaviour(kura_pool).
-behaviour(kura_capabilities).

-export([
    start_pool/2,
    stop_pool/1,
    checkout/2,
    checkin/2,
    give_away/3,
    capabilities/0
]).

-export([start_link/4]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-type state() :: #{
    name := atom(),
    supervisor := pid(),
    db_path := binary() | string(),
    available := [esqlite3:esqlite3()],
    out := #{esqlite3:esqlite3() => reference()}
}.

-type request() ::
    {checkout, pid()}
    | {checkin, esqlite3:esqlite3(), reference()}
    | {give_away, esqlite3:esqlite3(), reference(), pid()}
    | supervisor.

%%----------------------------------------------------------------------
%% kura_pool callbacks
%%----------------------------------------------------------------------

-spec start_pool(kura_pool:name(), kura_pool:opts()) -> {ok, pid()} | {error, term()}.
start_pool(Name, Opts) ->
    DbPath = maps:get(database, Opts, ~":memory:"),
    Size = maps:get(pool_size, Opts, 1),
    kura_pool_sqlite_sup:start(Name, DbPath, Size).

-spec stop_pool(kura_pool:name()) -> ok.
stop_pool(Name) ->
    case call(Name, supervisor) of
        Supervisor when is_pid(Supervisor) -> kura_pool_sqlite_sup:stop(Supervisor);
        {exit, _} -> ok
    end.

-spec checkout(kura_pool:name(), kura_pool:checkout_opts()) ->
    {ok, kura_pool:conn(), kura_pool:token()} | {error, term()}.
checkout(Name, _Opts) ->
    case call(Name, {checkout, self()}) of
        {exit, timeout} -> {error, checkout_timeout};
        {exit, _} -> {error, no_pool};
        Reply -> Reply
    end.

-spec checkin(kura_pool:name(), kura_pool:token()) -> ok.
checkin(Name, {Name, Conn, Lease}) ->
    _ = call(Name, {checkin, Conn, Lease}),
    ok;
checkin(_Name, _Token) ->
    ok.

-doc """
Move the watch on a borrowed connection to `NewOwner`, so the pool
reclaims the connection when `NewOwner` dies rather than the process
that checked it out.
""".
-spec give_away(kura_pool:token(), pid(), term()) -> ok | {error, term()}.
give_away({Name, Conn, Lease}, NewOwner, _GiftData) when is_pid(NewOwner) ->
    case call(Name, {give_away, Conn, Lease, NewOwner}) of
        {exit, _} -> {error, no_pool};
        Reply -> Reply
    end;
give_away(_Token, _NotPid, _GiftData) ->
    {error, badarg}.

%%----------------------------------------------------------------------
%% kura_capabilities
%%----------------------------------------------------------------------

-doc """
SQLite 3.45 capability set as shipped by esqlite. Excludes PG-only
features (advisory_locks, listen_notify, arrays). RETURNING is
included since 3.35.
""".
-spec capabilities() -> kura_capabilities:capability_set().
capabilities() ->
    [
        returning,
        json,
        partial_indexes,
        transactions,
        savepoints,
        prepared_statements
    ].

%%----------------------------------------------------------------------
%% gen_server
%%----------------------------------------------------------------------

-doc false.
-spec start_link(atom(), binary() | string(), non_neg_integer(), pid()) -> gen_server:start_ret().
start_link(Name, DbPath, Size, Supervisor) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, DbPath, Size, Supervisor}, []).

-spec init({atom(), binary() | string(), non_neg_integer(), pid()}) ->
    {ok, state()} | {stop, term()}.
init({Name, DbPath, Size, Supervisor}) ->
    process_flag(trap_exit, true),
    case open_n(DbPath, Size, []) of
        {ok, Conns} ->
            {ok, #{
                name => Name,
                supervisor => Supervisor,
                db_path => DbPath,
                available => Conns,
                out => #{}
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call(request(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(
    {checkout, Borrower}, _From, State = #{name := Name, available := [Conn | Rest], out := Out}
) ->
    Lease = erlang:monitor(process, Borrower),
    {reply, {ok, Conn, {Name, Conn, Lease}}, State#{available := Rest, out := Out#{Conn => Lease}}};
handle_call({checkout, _Borrower}, _From, State) ->
    {reply, {error, no_conns}, State};
handle_call({checkin, Conn, Lease}, _From, State = #{out := Out}) ->
    case Out of
        #{Conn := Lease} ->
            true = erlang:demonitor(Lease, [flush]),
            {reply, ok, returned(Conn, State#{out := maps:remove(Conn, Out)})};
        #{} ->
            {reply, ok, State}
    end;
handle_call({give_away, Conn, Lease, NewOwner}, _From, State = #{out := Out}) ->
    case Out of
        #{Conn := Lease} ->
            true = erlang:demonitor(Lease, [flush]),
            {reply, ok, State#{out := Out#{Conn => erlang:monitor(process, NewOwner)}}};
        #{} ->
            {reply, {error, not_checked_out}, State}
    end;
handle_call(supervisor, _From, State = #{supervisor := Supervisor}) ->
    {reply, Supervisor, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State = #{out := Out}) ->
    case [Conn || Conn := M <- Out, M =:= Monitor] of
        [Conn] -> {noreply, returned(Conn, State#{out := maps:remove(Conn, Out)})};
        [] -> {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{available := Available, out := Out}) ->
    close_each(Available ++ maps:keys(Out)).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% A pool that is gone, stopping or too busy to answer must not crash the
%% caller, which may be checking in from an `after` with an exception of
%% its own on the way.
-spec call(atom(), request()) -> dynamic().
call(Name, Request) ->
    try
        gen_server:call(Name, Request)
    catch
        exit:{Reason, _} when
            Reason =:= noproc;
            Reason =:= normal;
            Reason =:= shutdown;
            Reason =:= killed;
            Reason =:= timeout
        ->
            {exit, Reason};
        exit:{{shutdown, _}, _} ->
            {exit, shutdown}
    end.

-spec returned(esqlite3:esqlite3(), state()) -> state().
returned(Conn, State = #{name := Name, available := Available, db_path := DbPath}) ->
    case reset(Conn, DbPath) of
        {ok, Fresh} ->
            State#{available := [Fresh | Available]};
        {error, Reason} ->
            ?LOG_WARNING(#{event => connection_not_replaced, pool => Name, reason => Reason}),
            State
    end.

%% A connection still inside a transaction would hand its open transaction,
%% and on a file database its write lock, to the next borrower.
-spec reset(esqlite3:esqlite3(), binary() | string()) ->
    {ok, esqlite3:esqlite3()} | {error, term()}.
reset(Conn, DbPath) ->
    case esqlite3:get_autocommit(Conn) of
        true ->
            {ok, Conn};
        false ->
            _ = esqlite3:exec(Conn, ~"ROLLBACK"),
            case esqlite3:get_autocommit(Conn) of
                true ->
                    {ok, Conn};
                false ->
                    _ = esqlite3:close(Conn),
                    esqlite3:open(to_filename(DbPath))
            end
    end.

-spec open_n(binary() | string(), non_neg_integer(), [esqlite3:esqlite3()]) ->
    {ok, [esqlite3:esqlite3()]} | {error, term()}.
open_n(_DbPath, 0, Acc) ->
    {ok, Acc};
open_n(DbPath, N, Acc) when N > 0 ->
    case esqlite3:open(to_filename(DbPath)) of
        {ok, Conn} ->
            open_n(DbPath, N - 1, [Conn | Acc]);
        {error, _} = Err ->
            close_each(Acc),
            Err
    end.

-spec to_filename(binary() | string()) -> string().
to_filename(B) when is_binary(B) -> binary_to_list(B);
to_filename(L) when is_list(L) -> L.

-spec close_each([esqlite3:esqlite3()]) -> ok.
close_each([]) ->
    ok;
close_each([Conn | Rest]) ->
    _ = esqlite3:close(Conn),
    close_each(Rest).
