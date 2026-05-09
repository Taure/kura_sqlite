-module(kura_driver_sqlite).
-moduledoc """
SQLite driver impl using [esqlite](https://hex.pm/packages/esqlite).

Wraps `esqlite3:q/3` and `esqlite3:exec/2` behind the `kura_driver`
behaviour so kura code does not need to know which client library is
in use.

## Result shape

Returns `#{rows := Rows, num_rows := N, command := C}` to match
`kura_driver_pgo`'s shape. `Rows` are maps keyed by atom column names,
making them interchangeable with pgo result rows. `command` is one of
`select | insert | update | delete | other` derived from the SQL
prefix.

## Transactions

`transaction/4` wraps the fun in `BEGIN`/`COMMIT` (or `ROLLBACK` on
throw) using `esqlite3:exec/2`. The leased connection is stashed in
the process dict under `kura_sqlite_tx_conn` so nested `query/5`
calls inside the fun route to the same conn.

## Caveats (phase 2 skeleton)

- Type encoding: pass-through. SQLite has type affinity, so booleans
  arrive as 0/1 rather than `true`/`false`. Phase 3 normalizes via
  the kura type system.
- `query/5` always opens a fresh checkout when not in a transaction;
  there is no per-query optimization yet.
""".

-behaviour(kura_driver).

-export([
    query/5,
    query_on/4,
    transaction/4
]).

%%----------------------------------------------------------------------
%% kura_driver callbacks
%%----------------------------------------------------------------------

-spec query(module(), atom(), iodata(), [term()], map()) -> dynamic().
query(PoolMod, Pool, SQL, Params, _Opts) ->
    case erlang:get(kura_sqlite_tx_conn) of
        undefined ->
            kura_pool:with_conn(PoolMod, Pool, fun(Conn) ->
                run(Conn, SQL, Params)
            end);
        Conn ->
            run(Conn, SQL, Params)
    end.

-spec query_on(esqlite3:esqlite3(), iodata(), [term()], map()) -> dynamic().
query_on(Conn, SQL, Params, _Opts) ->
    run(Conn, SQL, Params).

-spec transaction(module(), atom(), fun(() -> term()), map()) -> term().
transaction(PoolMod, Pool, Fun, _Opts) ->
    case kura_pool:with_conn(PoolMod, Pool, fun(Conn) -> begin_run_finish(Conn, Fun) end) of
        {sqlite_tx_threw, Class, Reason, Stack} ->
            erlang:raise(Class, Reason, Stack);
        Result ->
            Result
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

-spec begin_run_finish(esqlite3:esqlite3(), fun(() -> term())) -> term().
begin_run_finish(Conn, Fun) ->
    Prior = erlang:put(kura_sqlite_tx_conn, Conn),
    case esqlite3:exec(Conn, ~"BEGIN") of
        ok ->
            try Fun() of
                Result ->
                    case esqlite3:exec(Conn, ~"COMMIT") of
                        ok -> Result;
                        {error, _} = E -> E
                    end
            catch
                Class:Reason:Stack ->
                    _ = esqlite3:exec(Conn, ~"ROLLBACK"),
                    {sqlite_tx_threw, Class, Reason, Stack}
            after
                restore(Prior)
            end;
        {error, _} = Err ->
            restore(Prior),
            Err
    end.

-spec restore(term()) -> ok.
restore(undefined) ->
    erlang:erase(kura_sqlite_tx_conn),
    ok;
restore(Prior) ->
    erlang:put(kura_sqlite_tx_conn, Prior),
    ok.

-spec run(esqlite3:esqlite3(), iodata(), [term()]) -> dynamic().
run(Conn, SQL, Params) ->
    SQLBin = iolist_to_binary(SQL),
    case esqlite3:prepare(Conn, SQLBin) of
        {ok, Stmt} ->
            run_prepared(Stmt, Params, command_of(SQLBin));
        {error, _} = Err ->
            Err
    end.

-spec run_prepared(esqlite3:esqlite3_stmt(), [term()], atom()) -> dynamic().
run_prepared(Stmt, Params, Cmd) ->
    case bind_params(Stmt, Params) of
        ok ->
            ColNames = esqlite3:column_names(Stmt),
            case collect_rows(Stmt, ColNames, []) of
                {error, _} = Err ->
                    Err;
                Rows when is_list(Rows) ->
                    #{rows => Rows, num_rows => length(Rows), command => Cmd}
            end;
        {error, _} = Err ->
            Err
    end.

-spec bind_params(esqlite3:esqlite3_stmt(), [term()]) -> ok | {error, term()}.
bind_params(Stmt, []) ->
    case esqlite3:bind(Stmt, []) of
        ok -> ok;
        {error, _} = E -> E
    end;
bind_params(Stmt, Params) ->
    case esqlite3:bind(Stmt, Params) of
        ok -> ok;
        {error, _} = E -> E
    end.

-spec collect_rows(esqlite3:esqlite3_stmt(), [binary()], [map()]) -> [map()] | {error, term()}.
collect_rows(Stmt, ColNames, Acc) ->
    case esqlite3:step(Stmt) of
        '$done' ->
            lists:reverse(Acc);
        {error, _} = Err ->
            Err;
        Row when is_list(Row) ->
            Map = row_to_map(Row, ColNames),
            collect_rows(Stmt, ColNames, [Map | Acc])
    end.

-spec row_to_map([term()], [binary()]) -> map().
row_to_map(Row, ColNames) ->
    row_to_map(Row, ColNames, #{}).

-spec row_to_map([term()], [binary()], map()) -> map().
row_to_map([], _ColNames, Acc) ->
    Acc;
row_to_map(_Row, [], Acc) ->
    Acc;
row_to_map([Cell | RestRow], [Name | RestNames], Acc) ->
    row_to_map(RestRow, RestNames, Acc#{name_to_atom(Name) => Cell}).

-spec name_to_atom(binary()) -> atom().
name_to_atom(N) -> binary_to_atom(N, utf8).

-spec command_of(binary()) -> select | insert | update | delete | other.
command_of(<<First, Rest/binary>>) when
    First =:= $\s; First =:= $\t; First =:= $\n; First =:= $\r
->
    command_of(Rest);
command_of(<<"SELECT", _/binary>>) ->
    select;
command_of(<<"select", _/binary>>) ->
    select;
command_of(<<"INSERT", _/binary>>) ->
    insert;
command_of(<<"insert", _/binary>>) ->
    insert;
command_of(<<"UPDATE", _/binary>>) ->
    update;
command_of(<<"update", _/binary>>) ->
    update;
command_of(<<"DELETE", _/binary>>) ->
    delete;
command_of(<<"delete", _/binary>>) ->
    delete;
command_of(_) ->
    other.
