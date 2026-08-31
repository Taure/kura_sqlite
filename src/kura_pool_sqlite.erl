-module(kura_pool_sqlite).
-moduledoc """
SQLite pool implementation. Maintains N pre-opened `esqlite3` database
connections in an ETS-tracked free list. Each `checkout/2` hands out a
connection; `checkin/2` returns it.

## Pool state

One ETS table per pool, named after the pool atom. Holds:

- One object per connection: `{esqlite3:esqlite3(), free | {busy, pid()}}`.
- `{db_path, binary()}` - the database path or `:memory:` URI.

`pool_size` from `start_pool/2` opts pre-opens N connections. Each
connection is its own ETS key (rather than one shared free-list value)
so a lease can be taken with a single atomic `select_replace/2` -
"read the list, compute the new list, write it back" on a *shared*
value is a lost-update race between two concurrent checkouts (both can
read the same free list before either writes, and both then believe
they hold the same connection). `ets:select_replace/2` performs its
match-and-replace per object without that read/compute/write gap, so
two concurrent callers racing for the same key are serialized by the
table itself: exactly one of them ever flips it from `free` to
`{busy, _}`.

## Waiting for a connection

`checkout/2` polls rather than failing outright when every connection
is leased: a caller from the same node blocking a few milliseconds is
a fine tradeoff against getting `{error, no_conns}` back the instant
someone else happens to be mid-query, given SQLite's own write
contention is intrinsically transient (see `kura_driver_sqlite`'s
`'$busy'` handling for the equivalent tradeoff *inside* a single
query). Bounded by `timeout` in `checkout/2`'s `Opts`
(`kura_pool:checkout_opts()`), defaulting to `?DEFAULT_CHECKOUT_TIMEOUT`
- the same shape `kura_pool_minato:checkout/2` already gives the PG
backend, whose default wait is nonzero for the identical reason.
`#{timeout => 0}` restores the old fail-immediately behavior for a
caller that specifically wants it.

## Example

```erlang
{ok, _Pid} = kura_pool_sqlite:start_pool(my_pool, #{
    database => <<":memory:">>,
    pool_size => 4
}).
```

## Notes vs PG

Unlike pgo's holder-ETS pattern, SQLite has no socket and no server,
so a connection is simply an open database handle. The pool's only
job is bounding the count of simultaneously open handles and pairing
checkout with checkin.
""".

-include_lib("stdlib/include/ms_transform.hrl").

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

%% Default budget for checkout/2 to wait for a connection to free up
%% before giving up with {error, no_conns} - see the moduledoc's
%% "Waiting for a connection" section for why this isn't 0.
-define(DEFAULT_CHECKOUT_TIMEOUT, 5000).
-define(POLL_INTERVAL_MS, 5).

%%----------------------------------------------------------------------
%% kura_pool callbacks
%%----------------------------------------------------------------------

-spec start_pool(kura_pool:name(), kura_pool:opts()) -> {ok, pid()} | {error, term()}.
start_pool(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            DbPath = maps:get(database, Opts, <<":memory:">>),
            Size = maps:get(pool_size, Opts, 1),
            Tid = ets:new(Name, [named_table, public, set]),
            case open_n(DbPath, Size, []) of
                {ok, Conns} ->
                    true = ets:insert(Tid, [{Conn, free} || Conn <- Conns]),
                    true = ets:insert(Tid, {db_path, DbPath}),
                    {ok, ets_owner_pid(Tid)};
                {error, _} = Err ->
                    true = ets:delete(Name),
                    Err
            end;
        _Existing ->
            {error, {already_started, ets_owner_pid(Name)}}
    end.

-spec stop_pool(kura_pool:name()) -> ok.
stop_pool(Name) ->
    case ets:whereis(Name) of
        undefined ->
            ok;
        _Tid ->
            close_all(Name),
            true = ets:delete(Name),
            ok
    end.

-spec checkout(kura_pool:name(), kura_pool:checkout_opts()) ->
    {ok, kura_pool:conn(), kura_pool:token()} | {error, term()}.
checkout(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            {error, no_pool};
        _Tid ->
            Timeout = maps:get(timeout, Opts, ?DEFAULT_CHECKOUT_TIMEOUT),
            Deadline = erlang:monotonic_time(millisecond) + Timeout,
            checkout_loop(Name, Deadline)
    end.

%% Polls rather than blocks on a signal from checkin/2: this pool has
%% no owning process to park a waiter on (see the moduledoc), and pool
%% sizes here are small enough (single-digit connections, in-process
%% handles) that a short poll interval costs far less than the
%% machinery a real waiter queue would need.
checkout_loop(Name, Deadline) ->
    case try_checkout(Name) of
        {error, no_conns} ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    {error, no_conns};
                false ->
                    timer:sleep(?POLL_INTERVAL_MS),
                    checkout_loop(Name, Deadline)
            end;
        Result ->
            Result
    end.

%% One lease attempt: find a candidate free connection, then try to
%% atomically flip it to busy with select_replace/2 (a per-object
%% match-and-replace, not a read-then-write of a shared value - see
%% the moduledoc). Losing the race just means someone else got there
%% first between the select/3 and the select_replace/2; retrying picks
%% a fresh candidate rather than looping on the one that was just lost.
try_checkout(Name) ->
    case ets:select(Name, ets:fun2ms(fun({Conn, free}) -> Conn end), 1) of
        {[Conn], _Cont} ->
            MatchSpec = ets:fun2ms(
                fun({C, free}) when C =:= Conn -> {C, {busy, self()}} end
            ),
            case ets:select_replace(Name, MatchSpec) of
                1 -> {ok, Conn, Conn};
                0 -> try_checkout(Name)
            end;
        '$end_of_table' ->
            {error, no_conns}
    end.

-spec checkin(kura_pool:name(), kura_pool:token()) -> ok.
checkin(Name, Token) ->
    case ets:whereis(Name) of
        undefined ->
            ok;
        _Tid ->
            %% update_element/3 only touches an object that already
            %% exists, so an unrecognized Token is silently ignored
            %% (idempotent, matches kura_pool_pgo / kura_pool_ets) and
            %% a double checkin is harmless - both in one atomic call,
            %% no read-then-write gap for a concurrent checkout to land in.
            _ = ets:update_element(Name, Token, {2, free}),
            ok
    end.

-spec give_away(kura_pool:token(), pid(), term()) -> ok | {error, term()}.
give_away(_Token, NewOwner, _GiftData) when is_pid(NewOwner) ->
    %% No transferable per-conn structure to hand off; the protocol
    %% guarantee callers care about (checkin not crashing on a
    %% transferred token) holds because checkin keys off the conn
    %% handle rather than the owner pid.
    ok;
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
%% Internal
%%----------------------------------------------------------------------

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

-spec close_all(atom()) -> ok.
close_all(Name) ->
    Conns =
        ets:select(Name, ets:fun2ms(fun({Conn, free}) -> Conn end)) ++
            ets:select(Name, ets:fun2ms(fun({Conn, {busy, _Pid}}) -> Conn end)),
    close_each(Conns).

-spec close_each([esqlite3:esqlite3()]) -> ok.
close_each([]) ->
    ok;
close_each([Conn | Rest]) ->
    _ = esqlite3:close(Conn),
    close_each(Rest).

-spec ets_owner_pid(atom() | ets:tid()) -> pid().
ets_owner_pid(NameOrTid) ->
    case ets:info(NameOrTid, owner) of
        Pid when is_pid(Pid) -> Pid;
        _ -> self()
    end.
