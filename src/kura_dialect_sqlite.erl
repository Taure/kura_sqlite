-module(kura_dialect_sqlite).
-moduledoc """
SQLite dialect. Translates `#kura_query{}` AST into SQLite-flavored
SQL.

## Strategy

SQLite 3.35+ supports nearly every SQL feature kura emits: `RETURNING`,
`ON CONFLICT (col) DO UPDATE`, `LIMIT/OFFSET`, double-quoted identifiers.
The main wire-protocol difference vs PG is the placeholder syntax: PG
uses `$N`, SQLite uses `?N`.

This dialect delegates the AST-to-SQL emission to `kura_dialect_pg` and
post-processes the SQL string to swap `$N` for `?N`. The number of
placeholders and their positions are unchanged. Edge cases where SQL
bytes between dialects truly diverge (`JSONB` operators, advisory
locks, partial-index expressions, etc.) are out of scope for this
phase 2 skeleton and will be addressed by capability flags in phase 3.

## Notes

- All callbacks are pure pass-throughs to `kura_dialect_pg` followed by
  `swap_placeholders/1`.
- Identifier quoting: SQLite (with `SQLITE_DQS=0` as esqlite ships) treats
  `"foo"` as an identifier. Same as PG.
- esqlite returns rows as tuples, not maps. Map-shaped result
  conversion happens in `kura_driver_sqlite`.
""".

-behaviour(kura_dialect).

-export([
    to_sql/1,
    to_sql_from/2,
    insert/3,
    insert/4,
    update/4,
    delete/3,
    update_all/2,
    delete_all/1,
    insert_all/3,
    insert_all/4,
    swap_placeholders/1
]).

%%----------------------------------------------------------------------
%% kura_dialect callbacks
%%----------------------------------------------------------------------

-spec to_sql(term()) -> {iodata(), [term()]}.
to_sql(Query) ->
    {SQL, Params} = kura_dialect_pg:to_sql(Query),
    {swap_placeholders(SQL), Params}.

-spec to_sql_from(term(), pos_integer()) -> {iodata(), [term()], pos_integer()}.
to_sql_from(Query, StartCounter) ->
    {SQL, Params, NextCounter} = kura_dialect_pg:to_sql_from(Query, StartCounter),
    {swap_placeholders(SQL), Params, NextCounter}.

-spec insert(atom() | module(), [atom()], map()) -> {iodata(), [term()]}.
insert(SchemaOrTable, Fields, Data) ->
    {SQL, Params} = kura_dialect_pg:insert(SchemaOrTable, Fields, Data),
    {swap_placeholders(SQL), Params}.

-spec insert(atom() | module(), [atom()], map(), map()) -> {iodata(), [term()]}.
insert(SchemaOrTable, Fields, Data, Opts) ->
    {SQL, Params} = kura_dialect_pg:insert(SchemaOrTable, Fields, Data, Opts),
    {swap_placeholders(SQL), Params}.

-spec update(atom() | module(), [atom()], map(), {atom(), term()}) -> {iodata(), [term()]}.
update(SchemaOrTable, Fields, Changes, PK) ->
    {SQL, Params} = kura_dialect_pg:update(SchemaOrTable, Fields, Changes, PK),
    {swap_placeholders(SQL), Params}.

-spec delete(atom() | module(), atom(), term()) -> {iodata(), [term()]}.
delete(SchemaOrTable, PKField, PKValue) ->
    {SQL, Params} = kura_dialect_pg:delete(SchemaOrTable, PKField, PKValue),
    {swap_placeholders(SQL), Params}.

-spec update_all(term(), map()) -> {iodata(), [term()]}.
update_all(Query, SetMap) ->
    {SQL, Params} = kura_dialect_pg:update_all(Query, SetMap),
    {swap_placeholders(SQL), Params}.

-spec delete_all(term()) -> {iodata(), [term()]}.
delete_all(Query) ->
    {SQL, Params} = kura_dialect_pg:delete_all(Query),
    {swap_placeholders(SQL), Params}.

-spec insert_all(atom() | module(), [atom()], [map()]) -> {iodata(), [term()]}.
insert_all(SchemaOrTable, Fields, Rows) ->
    {SQL, Params} = kura_dialect_pg:insert_all(SchemaOrTable, Fields, Rows),
    {swap_placeholders(SQL), Params}.

-spec insert_all(atom() | module(), [atom()], [map()], map()) -> {iodata(), [term()]}.
insert_all(SchemaOrTable, Fields, Rows, Opts) ->
    {SQL, Params} = kura_dialect_pg:insert_all(SchemaOrTable, Fields, Rows, Opts),
    {swap_placeholders(SQL), Params}.

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

-doc """
Rewrite PG's `$N` placeholders to SQLite's `?N` form.

Both backends accept positional and numbered placeholders. SQLite
specifically: `?NNN` where NNN is a 1-indexed integer. Position-for-
position swap; counts and ordering preserved.

Bytes inside string literals are not rewritten; SQLite uses single
quotes for literals (`SQLITE_DQS=0` excludes double-quoted strings)
and the kura emitter follows the same convention.
""".
-spec swap_placeholders(iodata()) -> binary().
swap_placeholders(SQL) ->
    Bin = iolist_to_binary(SQL),
    swap(Bin, <<>>).

-spec swap(binary(), binary()) -> binary().
swap(<<>>, Acc) ->
    Acc;
swap(<<$$, Rest/binary>>, Acc) ->
    swap(Rest, <<Acc/binary, $?>>);
swap(<<C, Rest/binary>>, Acc) ->
    swap(Rest, <<Acc/binary, C>>).
