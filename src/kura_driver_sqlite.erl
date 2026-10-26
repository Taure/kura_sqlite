-module(kura_driver_sqlite).
-moduledoc """
SQLite driver impl using [esqlite](https://hex.pm/packages/esqlite).

Wraps `esqlite3:q/3` and `esqlite3:exec/2` behind the `kura_driver`
behaviour so kura code does not need to know which client library is
in use.

## Result shape

Returns `#{rows := Rows, num_rows := N, command := C}`, the shape the
other kura drivers return. `Rows` are maps keyed by atom column names.
`command` is one of
`select | insert | update | delete | other` derived from the SQL
prefix.

## Errors

A statement that fails returns `{error, Reason}`, `Reason` being the
SQLite result code for most failures. A statement that waits out the
connection's busy timeout returns `{error, busy}`.

## Dropping a referenced table

With foreign keys on, SQLite empties a table before it drops it, and that
runs the `ON DELETE` rules of the tables that reference it: `CASCADE`
deletes their rows and `SET NULL` clears their references. Postgres
refuses such a drop. So does this driver: a `DROP TABLE` on a table that
another table references returns
`{error, {referenced_by, Table, Referencing}}`, `Referencing` listing the
tables in that schema that reference it, and drops nothing. A table that
references only itself can be dropped. With foreign keys off on the
connection the drop deletes no rows and is not checked, so the
table-rebuild procedure SQLite documents for schema changes still works.
Outside a transaction, a table created by another connection between the
check and the drop is not seen.

## Transactions

`transaction/4` wraps the fun in `BEGIN`/`COMMIT` (or `ROLLBACK` on
a raise) using `esqlite3:exec/2`. The leased connection is kept in the
process dictionary, per pool, so `query/5` calls inside the fun route
to the same connection.

A `transaction/4` on the same pool inside the fun runs on that
connection under a `SAVEPOINT`: its work is released into the outer
transaction when the fun returns, rolled back to the savepoint when it
raises, and only kept if the outermost transaction commits. A
transaction on another pool, or in another process, is independent.

Failures raise rather than return, so they cannot be mistaken for the
fun's own result:

- `{kura_driver_sqlite, {begin_failed, Reason}}` when `BEGIN` fails.
- `{kura_driver_sqlite, {savepoint_failed, Reason}}` when a nested
  `SAVEPOINT` fails. The nested fun does not run.
- `{kura_driver_sqlite, {commit_failed, Reason}}` when `COMMIT` is
  refused, for example by a deferred foreign key or `SQLITE_BUSY`. The
  transaction is rolled back and nothing it wrote is kept.
- `{kura_driver_sqlite, {commit_unknown, Code}}` when `COMMIT` fails
  with an I/O error (the `SQLITE_IOERR` family). In WAL mode that can
  come after the commit record reached the log, so the transaction may
  or may not have been kept. Do not assume either.
- `{kura_driver_sqlite, {release_failed, Reason}}` when a nested
  `RELEASE` fails while the transaction is still open.
- `{kura_driver_sqlite, {rollback_to_failed, Reason}}` when a nested
  transaction raised and its `ROLLBACK TO` failed, for example because
  the fun released the savepoint itself. The whole transaction is
  rolled back rather than keep work the nested call was meant to undo.
- `{kura_driver_sqlite, transaction_ended_by_statement}` when a
  statement run inside the transaction, such as a raw `COMMIT`, `END`
  or `ROLLBACK`, ended it. Whatever that statement committed stays
  committed; nothing after it runs.
- `{kura_driver_sqlite, {no_connection, Reason}}` when no connection
  can be checked out.
- `transaction_rolled_back` when SQLite has rolled the whole
  transaction back on its own, which it does on `ON CONFLICT ROLLBACK`,
  `INSERT OR ROLLBACK`, a full disk, an I/O error or running out of
  memory. Every statement after that, nested or not, raises it rather
  than run outside the transaction, and so does the commit. Unlike
  Postgres, where a nested `transaction_rolled_back` loses only the
  savepoint's work, on SQLite it always means the outermost
  transaction is gone.

Apart from an I/O error, `COMMIT` has no unknown outcome: SQLite runs
in this process and returns once the database has kept the transaction
or not, so there is no timeout or lost connection to leave it in doubt.

On a file database, set WAL mode (`PRAGMA journal_mode = WAL`) so
readers do not block the writer, and a `PRAGMA busy_timeout` that suits
the workload. esqlite sets 2 seconds by default.

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

-define(REFERENCING,
    ~"""
    SELECT DISTINCT t.name
    FROM pragma_database_list AS d
    JOIN pragma_table_list AS t ON t.schema = d.name,
        pragma_foreign_key_list(t.name, t.schema) AS f
    WHERE d.seq = ?2
        AND t.type = 'table'
        AND f."table" = ?1 COLLATE NOCASE
        AND t.name <> ?1 COLLATE NOCASE
        AND (SELECT foreign_keys FROM pragma_foreign_keys) = 1
    ORDER BY t.name
    """
).

%%----------------------------------------------------------------------
%% kura_driver callbacks
%%----------------------------------------------------------------------

-spec query(module(), atom(), iodata(), [term()], map()) -> dynamic().
query(PoolMod, Pool, SQL, Params, _Opts) ->
    SQLBin = iolist_to_binary(SQL),
    case tx_conn(Pool) of
        undefined ->
            kura_pool:with_conn(PoolMod, Pool, fun(Conn) ->
                ok = touched(PoolMod, Pool, Conn, SQLBin),
                run(Conn, SQLBin, Params)
            end);
        Conn ->
            ok = still_open(Conn),
            ok = touched(PoolMod, Pool, Conn, SQLBin),
            ended(Conn, run(Conn, SQLBin, Params))
    end.

-spec query_on(esqlite3:esqlite3(), iodata(), [term()], map()) -> dynamic().
query_on(Conn, SQL, Params, _Opts) ->
    run(Conn, SQL, Params).

-spec transaction(module(), atom(), fun(() -> term()), map()) -> term().
transaction(PoolMod, Pool, Fun, _Opts) ->
    case tx_conn(Pool) of
        undefined ->
            case PoolMod:checkout(Pool, #{}) of
                {ok, Conn, Token} ->
                    try
                        outermost(Pool, Conn, Fun)
                    after
                        PoolMod:checkin(Pool, Token)
                    end;
                {error, Reason} ->
                    error({kura_driver_sqlite, {no_connection, Reason}})
            end;
        Conn ->
            nested(Conn, Fun)
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

-spec outermost(atom(), esqlite3:esqlite3(), fun(() -> term())) -> term().
outermost(Pool, Conn, Fun) ->
    case esqlite3:exec(Conn, ~"BEGIN") of
        ok ->
            _ = erlang:put({kura_sqlite_tx_conn, Pool}, Conn),
            try Fun() of
                Result -> committed(Conn, Result)
            catch
                Class:Reason:Stack ->
                    _ = esqlite3:exec(Conn, ~"ROLLBACK"),
                    erlang:raise(Class, Reason, Stack)
            after
                erlang:erase({kura_sqlite_tx_conn, Pool})
            end;
        {error, Reason} ->
            error({kura_driver_sqlite, {begin_failed, Reason}})
    end.

%% A COMMIT refused by a deferred constraint leaves the transaction open.
-spec committed(esqlite3:esqlite3(), term()) -> term().
committed(Conn, Result) ->
    ok = still_open(Conn),
    case esqlite3:exec(Conn, ~"COMMIT") of
        ok ->
            Result;
        {error, Reason} ->
            _ = esqlite3:exec(Conn, ~"ROLLBACK"),
            error({kura_driver_sqlite, commit_error(Reason)})
    end.

%% The SQLITE_IOERR family can come after the commit record was written.
-spec commit_error(term()) -> {commit_failed | commit_unknown, term()}.
commit_error(Code) when is_integer(Code), Code band 16#ff =:= 10 ->
    {commit_unknown, Code};
commit_error(Reason) ->
    {commit_failed, Reason}.

-spec nested(esqlite3:esqlite3(), fun(() -> term())) -> term().
nested(Conn, Fun) ->
    Savepoint = [
        ~"kura_savepoint_", integer_to_binary(erlang:unique_integer([positive, monotonic]))
    ],
    ok = still_open(Conn),
    case esqlite3:exec(Conn, [~"SAVEPOINT ", Savepoint]) of
        ok ->
            try Fun() of
                Result -> released(Conn, Savepoint, Result)
            catch
                Class:Reason:Stack ->
                    ok = rolled_back_to(Conn, Savepoint),
                    erlang:raise(Class, Reason, Stack)
            end;
        {error, Reason} ->
            error({kura_driver_sqlite, {savepoint_failed, Reason}})
    end.

-spec released(esqlite3:esqlite3(), iodata(), term()) -> term().
released(Conn, Savepoint, Result) ->
    ok = still_open(Conn),
    case esqlite3:exec(Conn, [~"RELEASE SAVEPOINT ", Savepoint]) of
        ok -> Result;
        {error, Reason} -> error({kura_driver_sqlite, {release_failed, Reason}})
    end.

-spec rolled_back_to(esqlite3:esqlite3(), iodata()) -> ok.
rolled_back_to(Conn, Savepoint) ->
    case esqlite3:exec(Conn, [~"ROLLBACK TO SAVEPOINT ", Savepoint]) of
        ok ->
            _ = esqlite3:exec(Conn, [~"RELEASE SAVEPOINT ", Savepoint]),
            ok;
        {error, Reason} ->
            case esqlite3:get_autocommit(Conn) of
                true ->
                    ok;
                false ->
                    _ = esqlite3:exec(Conn, ~"ROLLBACK"),
                    error({kura_driver_sqlite, {rollback_to_failed, Reason}})
            end
    end.

%% A statement that succeeds and leaves the connection in autocommit was the
%% caller's own COMMIT, END or ROLLBACK.
-spec ended(esqlite3:esqlite3(), dynamic()) -> dynamic().
ended(_Conn, {error, _} = Error) ->
    Error;
ended(Conn, Result) ->
    case esqlite3:get_autocommit(Conn) of
        false -> Result;
        true -> error({kura_driver_sqlite, transaction_ended_by_statement})
    end.

%% A connection back in autocommit inside a transaction means SQLite rolled
%% the transaction back itself, and anything run now would commit on its own.
-spec still_open(esqlite3:esqlite3()) -> ok.
still_open(Conn) ->
    case esqlite3:get_autocommit(Conn) of
        false -> ok;
        true -> error(transaction_rolled_back)
    end.

%% A statement other than DML can leave state on the connection that the
%% next borrower would inherit, so the pool checks it on return.
-spec touched(module(), atom(), esqlite3:esqlite3(), binary()) -> ok.
touched(kura_pool_sqlite, Pool, Conn, SQL) ->
    case command_of(SQL) =/= other orelse keyword(SQL) =:= ~"WITH" of
        true -> ok;
        false -> kura_pool_sqlite:dirty(Pool, Conn)
    end;
touched(_PoolMod, _Pool, _Conn, _SQL) ->
    ok.

-spec run(esqlite3:esqlite3(), iodata(), [term()]) -> dynamic().
run(Conn, SQL, Params) ->
    SQLBin = iolist_to_binary(SQL),
    case dependents(Conn, SQLBin) of
        ok -> prepared(Conn, SQLBin, Params);
        {error, _} = Refused -> Refused
    end.

-spec prepared(esqlite3:esqlite3(), binary(), [term()]) -> dynamic().
prepared(Conn, SQL, Params) ->
    case esqlite3:prepare(Conn, SQL) of
        {ok, Stmt} ->
            run_prepared(Stmt, Params, command_of(SQL));
        {error, _} = Err ->
            Err
    end.

%% With foreign keys on, SQLite empties a table before it drops it, and that
%% runs the ON DELETE rules of every table referencing it. SQLite's own
%% parser names the table: `EXPLAIN` compiles the statement without running
%% it, and its DropTable instruction carries the schema and table.
-spec dependents(esqlite3:esqlite3(), binary()) ->
    ok | {error, {referenced_by, binary(), [binary()]}}.
dependents(Conn, SQL) ->
    case keyword(SQL) of
        ~"DROP" -> dropping(Conn, esqlite3:q(Conn, [~"EXPLAIN ", SQL]));
        _ -> ok
    end.

-spec dropping(esqlite3:esqlite3(), [esqlite3:row()] | {error, term()}) ->
    ok | {error, {referenced_by, binary(), [binary()]}}.
dropping(Conn, Program) when is_list(Program) ->
    case [{Schema, Table} || [_, ~"DropTable", Schema, _, _, Table | _] <- Program] of
        [{Schema, Table} | _] when is_binary(Table) ->
            referenced(Table, esqlite3:q(Conn, ?REFERENCING, [Table, Schema]));
        _ ->
            ok
    end;
dropping(_Conn, {error, _}) ->
    ok.

-spec referenced(binary(), [esqlite3:row()] | {error, term()}) ->
    ok | {error, {referenced_by, binary(), [binary()]}}.
referenced(Table, [_ | _] = Rows) ->
    {error, {referenced_by, Table, [Name || [Name] <- Rows, is_binary(Name)]}};
referenced(_Table, _None) ->
    ok.

%% A statement that stops short of `'$done'`, on an error or `'$busy'`,
%% holds its connection's implicit transaction open until it is reset, and
%% anything the next borrower writes in autocommit would stay uncommitted.
-spec run_prepared(esqlite3:esqlite3_stmt(), [term()], atom()) -> dynamic().
run_prepared(Stmt, Params, Cmd) ->
    case bind_params(Stmt, Params) of
        ok ->
            ColNames = esqlite3:column_names(Stmt),
            try collect_rows(Stmt, ColNames) of
                {error, _} = Err ->
                    Err;
                Rows when is_list(Rows) ->
                    #{rows => Rows, num_rows => length(Rows), command => Cmd}
            after
                _ = esqlite3:reset(Stmt)
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

%% The process dictionary is untyped; what is stored is the connection put
%% there by the outermost transaction.
-spec tx_conn(atom()) -> dynamic().
tx_conn(Pool) ->
    erlang:get({kura_sqlite_tx_conn, Pool}).

-spec collect_rows(esqlite3:esqlite3_stmt(), [binary()]) ->
    [#{atom() => term()}] | {error, term()}.
collect_rows(Stmt, ColNames) ->
    case esqlite3:step(Stmt) of
        %% esqlite3_nif:step/1's spec leaves out '$busy', which esqlite3:step/1
        %% returns, so dialyzer would take a clause for it as unreachable.
        Finished when is_atom(Finished) ->
            maps:get(Finished, #{'$done' => [], '$busy' => {error, busy}});
        {error, _} = Err ->
            Err;
        Row when is_list(Row) ->
            case collect_rows(Stmt, ColNames) of
                {error, _} = Err -> Err;
                Rows -> [row_to_map(Row, ColNames) | Rows]
            end
    end.

-spec row_to_map([term()], [binary()]) -> #{atom() => term()}.
row_to_map(Row, ColNames) ->
    row_to_map(Row, ColNames, #{}).

-spec row_to_map([term()], [binary()], #{atom() => term()}) -> #{atom() => term()}.
row_to_map([], _ColNames, Acc) ->
    Acc;
row_to_map(_Row, [], Acc) ->
    Acc;
row_to_map([Cell | RestRow], [Name | RestNames], Acc) ->
    row_to_map(RestRow, RestNames, Acc#{name_to_atom(Name) => Cell}).

-spec name_to_atom(binary()) -> atom().
name_to_atom(N) -> binary_to_atom(N, utf8).

-spec command_of(binary()) -> select | insert | update | delete | other.
command_of(SQL) ->
    case keyword(SQL) of
        ~"SELECT" -> select;
        ~"INSERT" -> insert;
        ~"UPDATE" -> update;
        ~"DELETE" -> delete;
        _ -> other
    end.

-spec keyword(binary()) -> binary().
keyword(<<First, Rest/binary>>) when
    First =:= $\s; First =:= $\t; First =:= $\n; First =:= $\r
->
    keyword(Rest);
keyword(SQL) ->
    upper_word(SQL).

-spec upper_word(binary()) -> binary().
upper_word(<<Letter, Rest/binary>>) when Letter >= $a, Letter =< $z ->
    <<(Letter - $a + $A), (upper_word(Rest))/binary>>;
upper_word(<<Letter, Rest/binary>>) when Letter >= $A, Letter =< $Z ->
    <<Letter, (upper_word(Rest))/binary>>;
upper_word(_) ->
    ~"".
