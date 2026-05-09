-module(kura_pool_sqlite).
-moduledoc """
SQLite pool implementation. Maintains N pre-opened `esqlite3` database
connections in an ETS-tracked free list. Each `checkout/2` hands out a
connection; `checkin/2` returns it.

## Pool state

One ETS table per pool, named after the pool atom. Holds:

- `{available, [esqlite3:esqlite3()]}` - free connections.
- `{checked_out, #{esqlite3:esqlite3() => pid()}}` - leased + owner.
- `{db_path, binary()}` - the database path or `:memory:` URI.

`pool_size` from `start_pool/2` opts pre-opens N connections.

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
                    true = ets:insert(Tid, [
                        {available, Conns},
                        {checked_out, #{}},
                        {db_path, DbPath}
                    ]),
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
checkout(Name, _Opts) ->
    case ets:whereis(Name) of
        undefined ->
            {error, no_pool};
        _Tid ->
            case ets:lookup(Name, available) of
                [{available, []}] ->
                    {error, no_conns};
                [{available, [Conn | Rest]}] ->
                    [{checked_out, Out}] = ets:lookup(Name, checked_out),
                    Out2 = Out#{Conn => self()},
                    true = ets:insert(Name, [
                        {available, Rest},
                        {checked_out, Out2}
                    ]),
                    {ok, Conn, Conn};
                [] ->
                    {error, pool_corrupt}
            end
    end.

-spec checkin(kura_pool:name(), kura_pool:token()) -> ok.
checkin(Name, Token) ->
    case ets:whereis(Name) of
        undefined ->
            ok;
        _Tid ->
            [{available, Avail}] = ets:lookup(Name, available),
            [{checked_out, Out}] = ets:lookup(Name, checked_out),
            case maps:is_key(Token, Out) of
                true ->
                    Out2 = maps:remove(Token, Out),
                    true = ets:insert(Name, [
                        {available, [Token | Avail]},
                        {checked_out, Out2}
                    ]),
                    ok;
                false ->
                    %% Idempotent: matches kura_pool_pgo / kura_pool_ets
                    ok
            end
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
    case ets:lookup(Name, available) of
        [{available, Avail}] -> close_each(Avail);
        _ -> ok
    end,
    case ets:lookup(Name, checked_out) of
        [{checked_out, Out}] -> close_each(maps:keys(Out));
        _ -> ok
    end,
    ok.

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
