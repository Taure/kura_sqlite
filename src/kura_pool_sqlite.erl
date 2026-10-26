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

A lease handed on with `give_away/3` can still be checked in by its token.
If the pool reclaims it instead, because the new owner died, the process
that handed it on may still be using it, so the connection is dropped
rather than lent again.

A connection coming back, by `checkin/2` or by its borrower dying, is
reset before anyone else can check it out. The reset runs in a process of
its own, so a slow one does not hold up the pool, and `checkin/2` returns
once it is done. It first waits for any statement still running on the
connection to finish: a borrower killed during a `COMMIT` that is waiting
on a lock leaves that `COMMIT` running, and it can fail and leave the
transaction open after the borrower is gone. A transaction still open
after that is rolled back. If the rollback fails, or the reset raises, for
example because the borrower closed the connection itself, the pool drops
the connection and opens a fresh one in its place, or, if that fails, on
a later checkout. On `:memory:` a fresh connection is an empty database.

A dropped connection is not closed by the pool: it is closed when the last
process holding it lets it go. The pool first puts it back in NORMAL
locking mode, so a lease that set EXCLUSIVE does not keep the database
locked meanwhile. A connection dropped because its rollback failed keeps
that transaction, and its write lock, until then.

A lease that ran anything other than `SELECT`, `INSERT`, `UPDATE` or
`DELETE`, in any letter case and with or without a leading `WITH`, through
`kura_driver_sqlite` gets a closer look on return. If it
left TEMP tables, views or triggers, an attached database, or a
`query_only`, `writable_schema`, `foreign_keys`, `trusted_schema`,
`ignore_check_constraints`, `locking_mode`, `synchronous`,
`recursive_triggers`, `max_page_count`, `busy_timeout`, `journal_mode` or
`encoding` setting different from what a new connection has, the connection is
dropped and a fresh one opened. WAL is kept in the database file, so a
lease that switches the journal mode into or out of WAL changes what a new
connection has, and that is not counted against it. A reopened connection
starts from the defaults, so settings a consumer made on the old one,
checked or not (`cache_size`, for example), are not kept. On `:memory:`
the reopened connection is an empty database, so such a lease loses the
data that connection held. Statements run on the connection directly
through `esqlite3` are not seen.

Foreign keys are on for every connection the pool opens, so `REFERENCES`
and `ON DELETE` rules are enforced. SQLite leaves them off by default, and
the setting belongs to the connection, not the database. A lease that turns
them off through the driver has them off for that lease only, since the
connection is then reopened. One that turns them off directly through
`esqlite3` keeps them off until the connection is reopened for any of the
reasons above.

With foreign keys on, `DROP TABLE` on a table other tables reference would
first delete its rows and run the children's `ON DELETE` rules, so
`kura_driver_sqlite` refuses it the way Postgres does; see its
documentation.

The pool opens only UTF-8 databases. SQLite stores a bound binary as TEXT,
and in a UTF-16 database TEXT is transcoded, so a binary that is not valid
text, ciphertext from an `{encrypted, _}` field among them, would not come
back as it was written. `start_pool/2` on a database in another encoding
returns `{error, {unsupported_encoding, Encoding}}`, `Encoding` being, for
example, `~"UTF-16le"`. The encoding is checked when the pool starts and
each time a connection comes back. A connection opened to replace a
dropped one is not checked until its first lease returns, so the pool
does not wait on a locked database while it opens one. A lease that sets
the encoding of an empty file database and creates its first table
changes it for every connection on that file. The first connection to
come back reading another encoding stops the pool: it logs
`database_not_utf8`, drops its idle connections, opens no more, and every
checkout returns `{error, no_conns}`. Leases out at that moment, and the
lease that switched it, can still write in that encoding. Other ways
a binary stored as TEXT is changed are outside the pool: statements run
directly through `esqlite3`, a database file replaced under open
connections, and SQL text functions (`lower`, `||`, `substr`) applied to
the value.

`last_insert_rowid()` and `changes()` belong to the connection and are not
reset, so a lease can read the values the previous lease left.

One window remains: a borrower killed after it has called into esqlite but
before the call has taken the connection's lock. That call can still run
after the reset. Closing it needs a process that owns each connection and
runs every statement on it, or support from esqlite.

`checkout/2` waits up to `#{timeout => Ms}`, 5000 by default, for a
connection to come free; `infinity` waits for as long as it takes.
Callers wait in the order they came, and a connection that comes back, or
one opened in place of a dropped one, goes to the first of them. A caller
whose time runs out gets `{error, no_conns}`, and one that dies stops
waiting. `#{timeout => 0}` does not wait. Nor does any checkout when
nothing could come back to it: with no connection out or being reset, or
once the pool has stopped opening connections, it returns
`{error, no_conns}` at once, and so does every caller still waiting.

A pool too busy to answer within the timeout and another 500 ms returns
`{error, checkout_timeout}`. A checkout carries its deadline, so one the
pool only reaches after it has passed does not wait, and one that times
out that way gives its lease or its place in the queue back, so a
connection the pool hands out after the caller stopped waiting is not lost
to it.

A database path that is a directory, or whose directory does not exist,
is refused with `{error, 14}` (`SQLITE_CANTOPEN`) without asking esqlite
to open it:
esqlite frees the handle twice when an open fails, which can corrupt the
memory of the whole node. Other failed opens, such as a file the node may
not read, still go through esqlite.

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

-define(DEFAULT_WAIT, 5000).
-define(SQLITE_CANTOPEN, 14).
-define(REPLY_MARGIN, 500).

-define(SETTINGS, [
    ~"query_only",
    ~"writable_schema",
    ~"foreign_keys",
    ~"trusted_schema",
    ~"ignore_check_constraints",
    ~"locking_mode",
    ~"synchronous",
    ~"recursive_triggers",
    ~"max_page_count",
    ~"busy_timeout",
    ~"journal_mode",
    ~"encoding"
]).

-type lease() :: #{
    lease := reference(), monitor := reference(), dirty := boolean(), given_away := boolean()
}.

-type waiter() :: #{
    lease := reference(),
    from := gen_server:from(),
    monitor := reference(),
    timer := reference() | infinity
}.

-type deadline() :: integer() | infinity.

-type outcome() :: kept | {kept, [term()]} | dropped | not_utf8.

-type baseline() :: #{settings := [term()], db_path := binary() | string()}.

-type state() :: #{
    name := atom(),
    supervisor := pid(),
    db_path := binary() | string(),
    size := non_neg_integer(),
    short := boolean(),
    not_utf8 := boolean(),
    baseline := baseline(),
    available := [esqlite3:esqlite3()],
    out := #{esqlite3:esqlite3() => lease()},
    waiting := #{integer() => waiter()},
    resetting := #{pid() => {reference(), esqlite3:esqlite3(), gen_server:from() | none}}
}.

-type request() ::
    {checkout, pid(), reference(), deadline()}
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
    Wait = wait(Opts),
    case call(Name, {checkout, self(), Lease, deadline(Wait)}, answered_within(Wait)) of
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
                size => Size,
                short => false,
                not_utf8 => false,
                baseline => baseline(Conns, DbPath),
                available => Conns,
                out => #{},
                waiting => #{},
                resetting => #{}
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call(request(), gen_server:from(), state()) ->
    {reply, term(), state()} | {noreply, state()}.
handle_call({checkout, Borrower, Lease, Deadline}, From, State0) ->
    case replenished(State0) of
        State = #{name := Name, available := [Conn | Rest]} ->
            Monitor = erlang:monitor(process, Borrower),
            {reply, {ok, Conn, {Name, Conn, Lease}},
                lent(Conn, Lease, Monitor, State#{available := Rest})};
        State ->
            case {outstanding(State), remaining(Deadline)} of
                {true, Wait} when Wait =/= expired ->
                    {noreply, queued(Borrower, Lease, Wait, From, State)};
                {_, _} ->
                    {reply, {error, no_conns}, State}
            end
    end;
handle_call({checkin, Conn, Lease}, From, State = #{out := Out}) ->
    case Out of
        #{Conn := Held = #{lease := Lease}} ->
            {noreply, returned(Conn, Held#{given_away := false}, From, State)};
        #{} ->
            {reply, ok, State}
    end;
handle_call({give_away, Conn, Lease, NewOwner}, _From, State = #{out := Out}) ->
    case Out of
        #{Conn := Held = #{lease := Lease, monitor := Monitor}} ->
            true = erlang:demonitor(Monitor, [flush]),
            Moved = Held#{monitor := erlang:monitor(process, NewOwner), given_away := true},
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
        [] -> {noreply, given_up(withdrawn(lease, Lease, State), State)}
    end;
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({reset, Helper, Outcome}, State = #{resetting := Resetting}) when
    is_map_key(Helper, Resetting)
->
    #{Helper := {Monitor, Conn, From}} = Resetting,
    true = erlang:demonitor(Monitor, [flush]),
    Rest = State#{resetting := maps:remove(Helper, Resetting)},
    case Outcome of
        {kept, Settings} when is_list(Settings) ->
            {noreply, restored(Conn, From, kept, learned(Settings, Rest))};
        kept ->
            {noreply, restored(Conn, From, kept, Rest)};
        not_utf8 ->
            {noreply, restored(Conn, From, not_utf8, Rest)};
        _ ->
            {noreply, restored(Conn, From, dropped, Rest)}
    end;
%% A reset helper killed before it reported back leaves the connection in an
%% unknown state.
handle_info({'DOWN', _Monitor, process, Helper, _Reason}, State = #{resetting := Resetting}) when
    is_map_key(Helper, Resetting)
->
    #{Helper := {_, Conn, From}} = Resetting,
    {noreply, restored(Conn, From, dropped, State#{resetting := maps:remove(Helper, Resetting)})};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #{out := Out}) when is_reference(Ref) ->
    case [{Conn, Held} || Conn := Held = #{monitor := Monitor} <- Out, Monitor =:= Ref] of
        [{Conn, Held}] -> {noreply, returned(Conn, Held, none, State)};
        [] -> {noreply, given_up(withdrawn(monitor, Ref, State), State)}
    end;
handle_info({waited, Lease}, State) when is_reference(Lease) ->
    case withdrawn(lease, Lease, State) of
        {#{from := From, monitor := Monitor}, Rest} ->
            true = erlang:demonitor(Monitor, [flush]),
            ok = gen_server:reply(From, {error, no_conns}),
            {noreply, Rest};
        none ->
            {noreply, State}
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

-spec wait(kura_pool:checkout_opts()) -> timeout().
wait(#{timeout := Wait}) when Wait =:= infinity; is_integer(Wait), Wait >= 0 ->
    Wait;
wait(#{timeout := Wait}) ->
    error({badarg, {timeout, Wait}});
wait(#{}) ->
    ?DEFAULT_WAIT.

%% The pool answers a checkout that runs out of time itself, so the call
%% waits a little longer than that for the answer.
-spec answered_within(timeout()) -> timeout().
answered_within(infinity) ->
    infinity;
answered_within(Wait) ->
    Wait + ?REPLY_MARGIN.

%% The request can sit in the pool's mailbox for a while, so it carries
%% when the caller stops waiting rather than for how long.
-spec deadline(timeout()) -> deadline().
deadline(infinity) ->
    infinity;
deadline(Wait) ->
    erlang:monotonic_time(millisecond) + Wait.

-spec remaining(deadline()) -> timeout() | expired.
remaining(infinity) ->
    infinity;
remaining(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 -> Left;
        _ -> expired
    end.

-spec lent(esqlite3:esqlite3(), reference(), reference(), state()) -> state().
lent(Conn, Lease, Monitor, State = #{out := Out}) ->
    State#{
        out := Out#{
            Conn => #{lease => Lease, monitor => Monitor, dirty => false, given_away => false}
        }
    }.

%% A connection can only become free by coming back from a lease or a reset,
%% and not at all once the database has left UTF-8.
-spec outstanding(state()) -> boolean().
outstanding(#{not_utf8 := true}) ->
    false;
outstanding(#{out := Out, resetting := Resetting}) ->
    map_size(Out) + map_size(Resetting) > 0.

-spec queued(pid(), reference(), timeout(), gen_server:from(), state()) -> state().
queued(Borrower, Lease, Wait, From, State = #{waiting := Waiting}) ->
    Waiter = #{
        lease => Lease,
        from => From,
        monitor => erlang:monitor(process, Borrower),
        timer => timer(Wait, Lease)
    },
    State#{waiting := Waiting#{erlang:unique_integer([monotonic]) => Waiter}}.

-spec timer(timeout(), reference()) -> reference() | infinity.
timer(infinity, _Lease) ->
    infinity;
timer(Wait, Lease) ->
    erlang:send_after(Wait, self(), {waited, Lease}).

-spec withdrawn(lease | monitor, reference(), state()) -> {waiter(), state()} | none.
withdrawn(Key, Ref, State = #{waiting := Waiting}) ->
    case [{Arrived, Waiter} || Arrived := Waiter <- Waiting, maps:get(Key, Waiter) =:= Ref] of
        [{Arrived, Waiter}] -> {Waiter, State#{waiting := maps:remove(Arrived, Waiting)}};
        [] -> none
    end.

-spec given_up({waiter(), state()} | none, state()) -> state().
given_up({#{monitor := Monitor, timer := Timer}, Rest}, _State) ->
    true = erlang:demonitor(Monitor, [flush]),
    ok = cancelled(Timer),
    Rest;
given_up(none, State) ->
    State.

-spec cancelled(reference() | infinity) -> ok.
cancelled(infinity) ->
    ok;
cancelled(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

%% Waiters only queue while no connection is free, so each connection that
%% becomes free goes to the first of them. Once nothing can come back, none
%% of them will be served.
-spec served(state()) -> state().
served(State = #{name := Name, available := [Conn | Rest], waiting := Waiting}) ->
    case maps:next(maps:iterator(Waiting, ordered)) of
        {Arrived, #{lease := Lease, from := From, monitor := Monitor, timer := Timer}, _} ->
            ok = cancelled(Timer),
            ok = gen_server:reply(From, {ok, Conn, {Name, Conn, Lease}}),
            Others = maps:remove(Arrived, Waiting),
            served(lent(Conn, Lease, Monitor, State#{available := Rest, waiting := Others}));
        none ->
            State
    end;
served(State = #{waiting := Waiting}) ->
    case outstanding(State) of
        true ->
            State;
        false ->
            _ = [refused(Waiter) || _ := Waiter <- Waiting],
            State#{waiting := #{}}
    end.

-spec refused(waiter()) -> ok.
refused(#{from := From, monitor := Monitor, timer := Timer}) ->
    true = erlang:demonitor(Monitor, [flush]),
    ok = cancelled(Timer),
    gen_server:reply(From, {error, no_conns}).

-spec returned(esqlite3:esqlite3(), lease(), gen_server:from() | none, state()) -> state().
returned(
    Conn,
    Held = #{monitor := Monitor},
    From,
    State = #{name := Name, out := Out, resetting := Resetting, baseline := Baseline}
) ->
    true = erlang:demonitor(Monitor, [flush]),
    Pool = self(),
    {Helper, HelperMonitor} = spawn_monitor(fun() ->
        Pool ! {reset, self(), outcome(Name, Conn, Held, Baseline)}
    end),
    State#{
        out := maps:remove(Conn, Out),
        resetting := Resetting#{Helper => {HelperMonitor, Conn, From}}
    }.

-spec learned([term()], state()) -> state().
learned(Settings, State = #{baseline := Baseline}) ->
    State#{baseline := Baseline#{settings := Settings}}.

-spec restored(esqlite3:esqlite3(), gen_server:from() | none, kept | dropped | not_utf8, state()) ->
    state().
restored(Conn, From, kept, State = #{available := Available}) ->
    ok = replied(From),
    served(State#{available := [Conn | Available]});
%% esqlite's close is not safe against a statement another process is still
%% running on the connection, and gives up without closing when its rollback
%% fails, so a dropped connection is left to its destructor.
restored(_Conn, From, dropped, State) ->
    ok = replied(From),
    served(opened(State));
%% Every connection on the file now reads it in another encoding, the idle
%% ones included, and so would any connection opened in their place.
restored(_Conn, From, not_utf8, State = #{name := Name, not_utf8 := Logged}) ->
    ok = replied(From),
    case Logged of
        true -> ok;
        false -> ?LOG_ERROR(#{event => database_not_utf8, pool => Name})
    end,
    served(State#{available := [], not_utf8 := true}).

%% A connection that could not be replaced is opened on a later checkout.
-spec replenished(state()) -> state().
replenished(
    State = #{size := Size, available := [], out := Out, resetting := Resetting}
) when map_size(Out) + map_size(Resetting) < Size ->
    opened(State);
replenished(State) ->
    State.

-spec opened(state()) -> state().
opened(State = #{not_utf8 := true}) ->
    State;
opened(State = #{name := Name, db_path := DbPath, available := Available, short := Short}) ->
    case connected(DbPath) of
        {ok, Fresh} ->
            State#{available := [Fresh | Available], short := false};
        {error, _} when Short ->
            State;
        {error, Reason} ->
            ?LOG_WARNING(#{event => connection_not_replaced, pool => Name, reason => Reason}),
            State#{short := true}
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
-spec reset(esqlite3:esqlite3(), boolean(), baseline()) -> outcome().
reset(Conn, Dirty, Baseline) ->
    _ = esqlite3:exec(Conn, ~""),
    case rolled_back(Conn) andalso esqlite3:q(Conn, ~"PRAGMA encoding") of
        [[~"UTF-8"]] when Dirty -> inspected(Conn, Baseline);
        [[~"UTF-8"]] -> kept;
        false -> unlocked(Conn);
        _ -> not_utf8(Conn, Baseline)
    end.

%% A lease that fixed the encoding of an empty file database changes it for
%% every connection on that file, including ones whose leases ran only DML.
%% One that only set it, on a database still empty or on `:memory:`, changed
%% its own connection, which a new connection shows.
-spec not_utf8(esqlite3:esqlite3(), baseline()) -> dropped | not_utf8.
not_utf8(Conn, #{db_path := DbPath}) ->
    dropped = unlocked(Conn),
    Opened = apart(fun() ->
        case utf8_opened(DbPath) of
            {ok, New} -> closed(New);
            {error, Reason} -> Reason
        end
    end),
    case Opened of
        {unsupported_encoding, _} -> not_utf8;
        _ -> dropped
    end.

-spec outcome(atom(), esqlite3:esqlite3(), lease(), baseline()) -> outcome().
outcome(Name, Conn, #{dirty := Dirty, given_away := GivenAway}, Baseline) ->
    try
        reclaimed(Conn, GivenAway, reset(Conn, Dirty, Baseline))
    catch
        Class:Reason ->
            ?LOG_WARNING(#{
                event => connection_reset_failed, pool => Name, class => Class, reason => Reason
            }),
            dropped
    end.

%% A lease handed on with `give_away/3` and reclaimed from its new owner may
%% still be in use by the process that handed it on.
-spec reclaimed(esqlite3:esqlite3(), boolean(), outcome()) -> outcome().
reclaimed(Conn, true, Outcome) when Outcome =/= dropped, Outcome =/= not_utf8 ->
    unlocked(Conn);
reclaimed(_Conn, _GivenAway, Outcome) ->
    Outcome.

%% A dropped connection lives on until no process holds it. In EXCLUSIVE
%% locking mode it would keep the database locked all that time; back in
%% NORMAL mode it gives the lock up on its next access.
-spec unlocked(esqlite3:esqlite3()) -> dropped.
unlocked(Conn) ->
    _ = esqlite3:exec(Conn, ~"PRAGMA locking_mode = NORMAL; SELECT count(*) FROM sqlite_schema"),
    dropped.

-spec rolled_back(esqlite3:esqlite3()) -> boolean().
rolled_back(Conn) ->
    case esqlite3:get_autocommit(Conn) of
        true ->
            true;
        false ->
            _ = esqlite3:exec(Conn, ~"ROLLBACK"),
            esqlite3:get_autocommit(Conn)
    end.

-spec inspected(esqlite3:esqlite3(), baseline()) -> outcome().
inspected(Conn, Baseline) ->
    case apart(fun() -> unchanged(Conn, Baseline) end) of
        true -> kept;
        {new, Settings} when is_list(Settings) -> {kept, Settings};
        _ -> unlocked(Conn)
    end.

-spec unchanged(esqlite3:esqlite3(), baseline()) -> boolean() | {new, [term()]}.
unchanged(Conn, #{settings := Opened, db_path := DbPath}) ->
    Temp = esqlite3:q(Conn, ~"SELECT count(*) FROM temp.sqlite_schema"),
    Attached = esqlite3:q(
        Conn, ~"SELECT count(*) FROM pragma_database_list WHERE name NOT IN ('main', 'temp')"
    ),
    case {Temp, Attached} =:= {[[0]], [[0]]} andalso settings(Conn) of
        false -> false;
        Opened -> true;
        Settings -> Settings =:= settings_of_new(DbPath) andalso {new, Settings}
    end.

%% WAL is kept in the database file, and a connection opened on a WAL
%% database starts from other defaults (`synchronous`), so a lease that
%% switched the journal mode changed what a new connection has. Settings
%% that differ from the baseline are held against a connection opened now,
%% and become the baseline if they match it.
-spec settings_of_new(binary() | string()) -> [term()] | {error, term()}.
settings_of_new(DbPath) ->
    case utf8_opened(DbPath) of
        {ok, New} ->
            Settings = settings(New),
            closed = closed(New),
            Settings;
        {error, Reason} ->
            {error, Reason}
    end.

-spec baseline([esqlite3:esqlite3()], binary() | string()) -> baseline().
baseline([Conn | _], DbPath) ->
    case apart(fun() -> settings(Conn) end) of
        Settings when is_list(Settings) -> #{settings => Settings, db_path => DbPath}
    end;
baseline([], DbPath) ->
    #{settings => [], db_path => DbPath}.

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
lease_counts(
    Status = #{state := State = #{out := Out, resetting := Resetting, waiting := Waiting}}
) when
    is_map(Out), is_map(Resetting), is_map(Waiting)
->
    Status#{
        state := State#{
            out := maps:size(Out),
            resetting := maps:size(Resetting),
            waiting := maps:size(Waiting)
        }
    };
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
    case utf8_opened(DbPath) of
        {ok, Conn} ->
            open_n(DbPath, N - 1, [Conn | Acc]);
        {error, _} = Err ->
            close_each(Acc),
            Err
    end.

%% `foreign_keys` is a flag on the connection and reads nothing from the
%% database, so it cannot wait on a lock the way a schema read can.
-spec connected(binary() | string()) -> {ok, esqlite3:esqlite3()} | {error, term()}.
connected(DbPath) ->
    Filename = to_filename(DbPath),
    case openable(Filename) of
        true -> foreign_keys_on(esqlite3:open(Filename));
        false -> {error, ?SQLITE_CANTOPEN}
    end.

%% esqlite closes the handle twice when SQLite cannot open a file, which
%% corrupts the heap of the whole node, so the usual reasons, a missing
%% directory or a path that is itself a directory, are refused before esqlite
%% tries. A `file:` URI is not a path.
-spec openable(string()) -> boolean().
openable("file:" ++ _Uri) ->
    true;
openable(Filename) ->
    filelib:is_dir(filename:dirname(Filename)) andalso not filelib:is_dir(Filename).

-spec foreign_keys_on({ok, esqlite3:esqlite3()} | {error, term()}) ->
    {ok, esqlite3:esqlite3()} | {error, term()}.
foreign_keys_on({ok, Conn}) ->
    ok = esqlite3:exec(Conn, ~"PRAGMA foreign_keys = ON"),
    {ok, Conn};
foreign_keys_on({error, _} = Error) ->
    Error.

-spec utf8_opened(binary() | string()) -> {ok, esqlite3:esqlite3()} | {error, term()}.
utf8_opened(DbPath) ->
    case connected(DbPath) of
        {ok, Conn} -> utf8(Conn);
        {error, _} = Error -> Error
    end.

-spec utf8(esqlite3:esqlite3()) -> {ok, esqlite3:esqlite3()} | {error, term()}.
utf8(Conn) ->
    case esqlite3:q(Conn, ~"PRAGMA encoding") of
        [[~"UTF-8"]] ->
            {ok, Conn};
        [[Encoding]] ->
            closed = closed(Conn),
            {error, {unsupported_encoding, Encoding}};
        {error, _} = Error ->
            closed = closed(Conn),
            Error
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
