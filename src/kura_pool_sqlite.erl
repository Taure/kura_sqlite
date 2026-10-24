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

A connection coming back, by `checkin/2` or by its borrower dying, is
reset before anyone else can check it out. The reset runs in a process of
its own, so a slow one does not hold up the pool, and `checkin/2` returns
once it is done. It first waits for any statement still running on the
connection to finish: a borrower killed during a `COMMIT` that is waiting
on a lock leaves that `COMMIT` running, and it can fail and leave the
transaction open after the borrower is gone. A transaction still open
after that is rolled back. If the rollback fails, or the reset raises, for
example because the borrower closed the connection itself, the connection
is closed and a fresh one opened in its place. Closing cannot be relied on
to release what the old connection held: esqlite's close leaves the
database open when its own rollback fails, so a write lock may stay held
until the handle is garbage collected. On `:memory:` a fresh connection is
an empty database.

A lease that ran anything other than `SELECT`, `INSERT`, `UPDATE` or
`DELETE`, in any letter case and with or without a leading `WITH`, through
`kura_driver_sqlite` gets a closer look on return. If it
left TEMP tables, views or triggers, an attached database, or a
`query_only`, `writable_schema`, `foreign_keys`, `trusted_schema` or
`ignore_check_constraints` setting different from what a new connection
has, the connection is closed and a fresh one opened. A reopened
connection starts from the defaults, so settings a consumer made on the
old one, checked or not (`busy_timeout`, for example), are not kept. On
`:memory:` the reopened connection is an empty database, so such a lease
loses the data that connection held.
Statements run on the connection directly through `esqlite3` are not
seen.

One window remains: a borrower killed after it has called into esqlite but
before the call has taken the connection's lock. That call can still run
after the reset. Closing it needs a process that owns each connection and
runs every statement on it, or support from esqlite.

`checkout/2` takes `#{timeout => Ms}`, 5000 by default, as the timeout of
its call to the pool. It does not wait for a connection to come free:
with none free it returns `{error, no_conns}` at once. A checkout that
times out gives its lease back, so a connection the pool hands out after
the caller stopped waiting is not lost to it.

A restarted pool opens new connections. Connections leased before the
restart are no longer the pool's: their checkins are ignored, and they
are closed when garbage collected. A stopping pool closes only the
connections nobody holds.

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

-export([start_link/4, dirty/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-include_lib("kernel/include/logger.hrl").

-define(SETTINGS, [
    ~"query_only",
    ~"writable_schema",
    ~"foreign_keys",
    ~"trusted_schema",
    ~"ignore_check_constraints"
]).

-type lease() :: #{lease := reference(), monitor := reference(), dirty := boolean()}.

-type state() :: #{
    name := atom(),
    supervisor := pid(),
    db_path := binary() | string(),
    settings := [term()],
    available := [esqlite3:esqlite3()],
    out := #{esqlite3:esqlite3() => lease()},
    resetting := #{pid() => {reference(), esqlite3:esqlite3(), gen_server:from() | none}}
}.

-type request() ::
    {checkout, pid(), reference()}
    | {checkin, esqlite3:esqlite3(), reference()}
    | {give_away, esqlite3:esqlite3(), reference(), pid()}
    | {dirty, esqlite3:esqlite3()}
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
checkout(Name, Opts) ->
    Lease = make_ref(),
    case call(Name, {checkout, self(), Lease}, maps:get(timeout, Opts, 5000)) of
        {exit, timeout} ->
            gen_server:cast(Name, {abandon, Lease}),
            {error, checkout_timeout};
        {exit, _} ->
            {error, no_pool};
        Reply ->
            Reply
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
-spec dirty(kura_pool:name(), esqlite3:esqlite3()) -> ok.
dirty(Name, Conn) ->
    _ = call(Name, {dirty, Conn}),
    ok.

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
                settings => opened_settings(Conns),
                available => Conns,
                out => #{},
                resetting => #{}
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call(request(), gen_server:from(), state()) ->
    {reply, term(), state()} | {noreply, state()}.
handle_call(
    {checkout, Borrower, Lease},
    _From,
    State = #{name := Name, available := [Conn | Rest], out := Out}
) ->
    Monitor = erlang:monitor(process, Borrower),
    {reply, {ok, Conn, {Name, Conn, Lease}}, State#{
        available := Rest,
        out := Out#{Conn => #{lease => Lease, monitor => Monitor, dirty => false}}
    }};
handle_call({checkout, _Borrower, _Lease}, _From, State) ->
    {reply, {error, no_conns}, State};
handle_call({checkin, Conn, Lease}, From, State = #{out := Out}) ->
    case Out of
        #{Conn := Held = #{lease := Lease}} ->
            {noreply, returned(Conn, Held, From, State)};
        #{} ->
            {reply, ok, State}
    end;
handle_call({give_away, Conn, Lease, NewOwner}, _From, State = #{out := Out}) ->
    case Out of
        #{Conn := Held = #{lease := Lease, monitor := Monitor}} ->
            true = erlang:demonitor(Monitor, [flush]),
            Moved = Held#{monitor := erlang:monitor(process, NewOwner)},
            {reply, ok, State#{out := Out#{Conn := Moved}}};
        #{} ->
            {reply, {error, not_checked_out}, State}
    end;
handle_call({dirty, Conn}, _From, State = #{out := Out}) ->
    case Out of
        #{Conn := Held} -> {reply, ok, State#{out := Out#{Conn := Held#{dirty := true}}}};
        #{} -> {reply, ok, State}
    end;
handle_call(supervisor, _From, State = #{supervisor := Supervisor}) ->
    {reply, Supervisor, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({abandon, Lease}, State = #{out := Out}) ->
    case [{Conn, Held} || Conn := Held = #{lease := L} <- Out, L =:= Lease] of
        [{Conn, Held}] -> {noreply, returned(Conn, Held, none, State)};
        [] -> {noreply, State}
    end;
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({reset, Helper, Outcome}, State = #{resetting := Resetting}) when
    is_map_key(Helper, Resetting), Outcome =:= kept orelse Outcome =:= closed
->
    #{Helper := {Monitor, Conn, From}} = Resetting,
    true = erlang:demonitor(Monitor, [flush]),
    {noreply, restored(Conn, From, Outcome, State#{resetting := maps:remove(Helper, Resetting)})};
%% A reset that raised, for example on a connection the borrower closed
%% itself, leaves the connection in an unknown state.
handle_info({'DOWN', _Monitor, process, Helper, _Reason}, State = #{resetting := Resetting}) when
    is_map_key(Helper, Resetting)
->
    #{Helper := {_, Conn, From}} = Resetting,
    _ = spawn(fun() -> closed(Conn) end),
    {noreply, restored(Conn, From, closed, State#{resetting := maps:remove(Helper, Resetting)})};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #{out := Out}) when is_reference(Ref) ->
    case [{Conn, Held} || Conn := Held = #{monitor := Monitor} <- Out, Monitor =:= Ref] of
        [{Conn, Held}] -> {noreply, returned(Conn, Held, none, State)};
        [] -> {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{available := Available}) ->
    close_each(Available).

%% A crash report would otherwise list every lease, and a lease is what a
%% checkin needs.
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(Status) ->
    request_name(lease_counts(Status)).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% A pool that is gone, stopping or too busy to answer must not crash the
%% caller, which may be checking in from an `after` with an exception of
%% its own on the way.
-spec call(atom(), request()) -> dynamic().
call(Name, Request) ->
    call(Name, Request, 5000).

-spec call(atom(), request(), timeout()) -> dynamic().
call(Name, Request, Timeout) ->
    try
        gen_server:call(Name, Request, Timeout)
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

-spec returned(esqlite3:esqlite3(), lease(), gen_server:from() | none, state()) -> state().
returned(
    Conn,
    #{monitor := Monitor, dirty := Dirty},
    From,
    State = #{out := Out, resetting := Resetting, settings := Settings}
) ->
    true = erlang:demonitor(Monitor, [flush]),
    Pool = self(),
    {Helper, HelperMonitor} = spawn_monitor(fun() ->
        Pool ! {reset, self(), reset(Conn, Dirty, Settings)}
    end),
    State#{
        out := maps:remove(Conn, Out),
        resetting := Resetting#{Helper => {HelperMonitor, Conn, From}}
    }.

-spec restored(esqlite3:esqlite3(), gen_server:from() | none, kept | closed, state()) -> state().
restored(Conn, From, kept, State = #{available := Available}) ->
    ok = replied(From),
    State#{available := [Conn | Available]};
restored(_Conn, From, closed, State = #{name := Name, db_path := DbPath, available := Available}) ->
    ok = replied(From),
    case esqlite3:open(to_filename(DbPath)) of
        {ok, Fresh} ->
            State#{available := [Fresh | Available]};
        {error, Reason} ->
            ?LOG_WARNING(#{event => connection_not_replaced, pool => Name, reason => Reason}),
            State
    end.

-spec replied(gen_server:from() | none) -> ok.
replied(none) -> ok;
replied(From) -> gen_server:reply(From, ok).

%% A connection still inside a transaction would hand its open transaction,
%% and on a file database its write lock, to the next borrower.
%%
%% The empty statement first waits for the connection's mutex, so a
%% statement the borrower was running when it died, such as a COMMIT
%% waiting on a lock, has returned before the transaction state is read.
%% Until then `get_autocommit/1` can report a transaction that is still
%% open as finished.
-spec reset(esqlite3:esqlite3(), boolean(), [term()]) -> kept | closed.
reset(Conn, Dirty, Settings) ->
    _ = esqlite3:exec(Conn, ~""),
    case rolled_back(Conn) andalso (not Dirty orelse pristine(Conn, Settings)) of
        true -> kept;
        false -> closed(Conn)
    end.

-spec rolled_back(esqlite3:esqlite3()) -> boolean().
rolled_back(Conn) ->
    case esqlite3:get_autocommit(Conn) of
        true ->
            true;
        false ->
            _ = esqlite3:exec(Conn, ~"ROLLBACK"),
            esqlite3:get_autocommit(Conn)
    end.

%% TEMP tables, views and triggers, attached databases and changed settings
%% outlive the lease that made them.
-spec pristine(esqlite3:esqlite3(), [term()]) -> boolean().
pristine(Conn, Settings) ->
    true =:= apart(fun() -> unchanged(Conn, Settings) end).

-spec unchanged(esqlite3:esqlite3(), [term()]) -> boolean().
unchanged(Conn, Settings) ->
    Temp = esqlite3:q(Conn, ~"SELECT count(*) FROM temp.sqlite_schema"),
    Attached = esqlite3:q(
        Conn, ~"SELECT count(*) FROM pragma_database_list WHERE name NOT IN ('main', 'temp')"
    ),
    {Temp, Attached, settings(Conn)} =:= {[[0]], [[0]], Settings}.

-spec opened_settings([esqlite3:esqlite3()]) -> [term()].
opened_settings([Conn | _]) ->
    case apart(fun() -> settings(Conn) end) of
        Settings when is_list(Settings) -> Settings
    end;
opened_settings([]) ->
    [].

-spec settings(esqlite3:esqlite3()) -> [term()].
settings(Conn) ->
    [esqlite3:q(Conn, [~"PRAGMA ", Setting]) || Setting <- ?SETTINGS].

%% A statement is finalized when it is garbage collected, under its
%% connection's lock, so a process that collects one while a borrower runs
%% a long statement on that connection stalls its scheduler. Run in a
%% process of its own, the statements are finalized when it exits, and
%% erpc returns only after that.
-spec apart(fun(() -> term())) -> term().
apart(Fun) ->
    erpc:call(node(), Fun, #{timeout => infinity, always_spawn => true}).

-spec closed(esqlite3:esqlite3()) -> closed.
closed(Conn) ->
    try esqlite3:close(Conn) of
        _ -> closed
    catch
        _:_ -> closed
    end.

-spec lease_counts(gen_server:format_status()) -> gen_server:format_status().
lease_counts(Status = #{state := State = #{out := Out, resetting := Resetting}}) when
    is_map(Out), is_map(Resetting)
->
    Status#{state := State#{out := maps:size(Out), resetting := maps:size(Resetting)}};
lease_counts(Status) ->
    Status.

-spec request_name(gen_server:format_status()) -> gen_server:format_status().
request_name(Status = #{message := Message}) when is_tuple(Message), tuple_size(Message) > 0 ->
    Status#{message := element(1, Message)};
request_name(Status) ->
    Status.

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
    closed = closed(Conn),
    close_each(Rest).
