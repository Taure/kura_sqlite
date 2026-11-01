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

## Byte fields

A schema field stored in a BLOB column (`binary`, `{encrypted, _}`, or a
`{custom, Mod}` whose `sqlite_type/0` is `BLOB`) is written with the BLOB
storage class, so its bytes do not depend on the database encoding:

- `insert`, `update`, `delete`, `insert_all` and the `SET` values of
  `update_all` pass its binary values as `{blob, Bin}`, which
  `kura_driver_sqlite` binds with `sqlite3_bind_blob`.
- A query condition on it (`=`, `!=`, `<`, `>`, `<=`, `>=`, `in`,
  `not_in`, `between`, row-value `in`) compiles to a fragment that wraps
  its placeholder in `CAST(? AS BLOB)`. A TEXT value never equals a BLOB
  one in SQLite, so without the cast a bound binary would match nothing.
  The cast is in the SQL rather than the parameters because kura caches a
  compiled query and reuses it with other values.

The cast path is correct only because `kura_pool_sqlite` refuses a
database whose encoding is not UTF-8. The value still binds as TEXT, and
`CAST(? AS BLOB)` turns it into the database encoding's bytes, which are
the original bytes only in UTF-8. The intended replacement is a
`dump_param` hook in kura core, applied in `kura_query_shape:split/1` and
in the repo worker's dump, so a value is tagged `{blob, Bin}` before it is
replaced by its marker. Once kura has that hook, this rewrite can be
deleted.

These binaries still bind as TEXT:

- values for a table named by atom or binary rather than a schema
  module, which has no field types. That includes a many-to-many join
  table whose `join_through` is a binary.
- values for a field whose name contains `?`, which a fragment would read
  as a placeholder.
- a where-condition on a byte column of a table named by atom or binary
  rather than a schema module, either as the query's `from` or as a join,
  or on a column of a CTE. With no field types there is nothing to cast,
  and SQLite orders every BLOB after every TEXT value, so on such a column
  `!=`, `not_in`, `NOT (=)`, `>` and `>=` match every row and `=`, `in`,
  `<` and `<=` match none.

The byte fields of the `from` schema and of every joined schema are
rewritten, since a where-field is not qualified by its table.

A condition on a byte field with an operator the rewrite cannot cast
raises `{kura_sqlite, {unsupported_blob_condition, Field, Op}}`. `like`,
`ilike`, `is_nil`, `is_not_nil` and an empty `in` or `not_in` list are
passed through unchanged.

## Notes

- Callbacks delegate to `kura_dialect_pg` and then apply
  `swap_placeholders/1`.
- Identifier quoting: SQLite (with `SQLITE_DQS=0` as esqlite ships) treats
  `"foo"` as an identifier. Same as PG.
- esqlite returns rows as tuples, not maps. Map-shaped result
  conversion happens in `kura_driver_sqlite`.
""".

-behaviour(kura_dialect).

-include_lib("kura/include/kura.hrl").

-export([
    to_sql/1,
    to_sql_from/2,
    insert/3,
    insert/4,
    update/4,
    delete/2,
    update_all/2,
    delete_all/1,
    insert_all/3,
    insert_all/4,
    column_type/1,
    format_default/1,
    swap_placeholders/1
]).

-define(CAST, ~"CAST(? AS BLOB)").
%% kura's ?KURA_IS_UNARY_OP, which the pinned kura does not define yet.
-define(IS_UNARY_OP(Op), (Op =:= is_nil orelse Op =:= is_not_nil)).
-define(IS_COMPARISON(Op),
    (Op =:= '=' orelse Op =:= '!=' orelse Op =:= '<' orelse Op =:= '>' orelse Op =:= '<=' orelse
        Op =:= '>=')
).

%%----------------------------------------------------------------------
%% kura_dialect callbacks
%%----------------------------------------------------------------------

-spec to_sql(#kura_query{}) -> {iodata(), [term()]}.
to_sql(Query) ->
    {SQL, Params} = kura_dialect_pg:to_sql(blob_query(Query)),
    {swap_placeholders(SQL), Params}.

-spec to_sql_from(#kura_query{}, pos_integer()) -> {iodata(), [term()], pos_integer()}.
to_sql_from(Query, StartCounter) ->
    {SQL, Params, NextCounter} = kura_dialect_pg:to_sql_from(blob_query(Query), StartCounter),
    {swap_placeholders(SQL), Params, NextCounter}.

-spec insert(atom() | module(), [atom()], map()) -> {iodata(), [term()]}.
insert(SchemaOrTable, Fields, Data) ->
    {SQL, Params} = kura_dialect_pg:insert(SchemaOrTable, Fields, blob_values(SchemaOrTable, Data)),
    {swap_placeholders(SQL), Params}.

-spec insert(atom() | module(), [atom()], map(), map()) -> {iodata(), [term()]}.
insert(SchemaOrTable, Fields, Data, Opts) ->
    {SQL, Params} = kura_dialect_pg:insert(
        SchemaOrTable, Fields, blob_values(SchemaOrTable, Data), Opts
    ),
    {swap_placeholders(SQL), Params}.

-spec update(atom() | module(), [atom()], map(), [{atom(), term()}]) -> {iodata(), [term()]}.
update(SchemaOrTable, Fields, Changes, KeyClauses) ->
    {SQL, Params} = kura_dialect_pg:update(
        SchemaOrTable,
        Fields,
        blob_values(SchemaOrTable, Changes),
        blob_keys(SchemaOrTable, KeyClauses)
    ),
    {swap_placeholders(SQL), Params}.

-spec delete(atom() | module(), [{atom(), term()}]) -> {iodata(), [term()]}.
delete(SchemaOrTable, KeyClauses) ->
    {SQL, Params} = kura_dialect_pg:delete(SchemaOrTable, blob_keys(SchemaOrTable, KeyClauses)),
    {swap_placeholders(SQL), Params}.

-spec update_all(#kura_query{}, map()) -> {iodata(), [term()]}.
update_all(#kura_query{from = From} = Query, SetMap) ->
    {SQL, Params} = kura_dialect_pg:update_all(blob_query(Query), blob_values(From, SetMap)),
    {swap_placeholders(SQL), Params}.

-spec delete_all(#kura_query{}) -> {iodata(), [term()]}.
delete_all(Query) ->
    {SQL, Params} = kura_dialect_pg:delete_all(blob_query(Query)),
    {swap_placeholders(SQL), Params}.

-spec insert_all(atom() | module(), [atom()], [map()]) -> {iodata(), [term()]}.
insert_all(SchemaOrTable, Fields, Rows) ->
    {SQL, Params} = kura_dialect_pg:insert_all(
        SchemaOrTable, Fields, [blob_values(SchemaOrTable, Row) || Row <- Rows]
    ),
    {swap_placeholders(SQL), Params}.

-spec insert_all(atom() | module(), [atom()], [map()], map()) -> {iodata(), [term()]}.
insert_all(SchemaOrTable, Fields, Rows, Opts) ->
    {SQL, Params} = kura_dialect_pg:insert_all(
        SchemaOrTable, Fields, [blob_values(SchemaOrTable, Row) || Row <- Rows], Opts
    ),
    {swap_placeholders(SQL), Params}.

%%----------------------------------------------------------------------
%% DDL: column type + default value emit
%%----------------------------------------------------------------------

-spec column_type(kura_types:kura_type()) -> binary().
column_type(id) ->
    ~"INTEGER";
column_type(integer) ->
    ~"INTEGER";
column_type(bigint) ->
    ~"INTEGER";
column_type(smallint) ->
    ~"INTEGER";
column_type(float) ->
    ~"REAL";
column_type(decimal) ->
    ~"NUMERIC";
column_type(string) ->
    ~"TEXT";
column_type(text) ->
    ~"TEXT";
column_type(binary) ->
    ~"BLOB";
column_type(boolean) ->
    ~"INTEGER";
column_type(date) ->
    ~"TEXT";
column_type(time) ->
    ~"TEXT";
column_type(utc_datetime) ->
    ~"TEXT";
column_type(naive_datetime) ->
    ~"TEXT";
column_type(uuid) ->
    ~"TEXT";
column_type(jsonb) ->
    ~"TEXT";
column_type({enum, _}) ->
    ~"TEXT";
column_type({array, _}) ->
    ~"TEXT";
column_type({embed, _, _}) ->
    ~"TEXT";
column_type({encrypted, _}) ->
    ~"BLOB";
column_type({custom, Mod}) ->
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, sqlite_type, 0) of
        true -> Mod:sqlite_type();
        false -> Mod:pg_type()
    end.

%% A default is whatever the schema declares.
-spec format_default(dynamic()) -> binary().
format_default(Val) when is_integer(Val) -> integer_to_binary(Val);
format_default(Val) when is_float(Val) -> float_to_binary(Val);
format_default(Val) when is_binary(Val) -> <<"'", Val/binary, "'">>;
format_default(true) ->
    ~"1";
format_default(false) ->
    ~"0";
format_default(Val) when is_map(Val) ->
    Json = iolist_to_binary(json:encode(Val)),
    <<"'", Json/binary, "'">>;
format_default(Val) when is_list(Val) ->
    Json = iolist_to_binary(json:encode(Val)),
    <<"'", Json/binary, "'">>.

%%----------------------------------------------------------------------
%% Byte fields
%%----------------------------------------------------------------------

-spec blob_values(term(), map()) -> map().
blob_values(Table, Values) ->
    Blobs = blob_fields(Table),
    case map_size(Blobs) of
        0 -> Values;
        _ -> maps:map(fun(Field, Value) -> blob_value(Field, Value, Blobs) end, Values)
    end.

-spec blob_keys(term(), [{atom(), term()}]) -> [{atom(), term()}].
blob_keys(Table, KeyClauses) ->
    Blobs = blob_fields(Table),
    [{Field, blob_value(Field, Value, Blobs)} || {Field, Value} <- KeyClauses].

-spec blob_value(atom(), term(), #{atom() => kura_types:kura_type()}) -> term().
blob_value(Field, Value, Blobs) when is_binary(Value), is_map_key(Field, Blobs) ->
    {blob, Value};
blob_value(_Field, Value, _Blobs) ->
    Value.

%% Kept in persistent_term per module, as kura_schema keeps field types.
-spec blob_fields(term()) -> #{atom() => kura_types:kura_type()}.
blob_fields(Mod) when is_atom(Mod), Mod =/= undefined ->
    Key = {?MODULE, blob_fields, Mod},
    case cached(Key) of
        undefined ->
            Blobs = schema_blob_fields(Mod),
            persistent_term:put(Key, Blobs),
            Blobs;
        Blobs ->
            Blobs
    end;
blob_fields(_Table) ->
    #{}.

%% persistent_term is untyped; what is stored under the key is the map
%% blob_fields/1 put there.
-spec cached(term()) -> dynamic().
cached(Key) ->
    persistent_term:get(Key, undefined).

%% The fields of a schema stored in BLOB columns. A name holding `?` is left
%% out, since it would be read as a placeholder in a fragment.
-spec schema_blob_fields(module()) -> #{atom() => kura_types:kura_type()}.
schema_blob_fields(Mod) ->
    case is_schema(Mod) of
        true ->
            maps:filter(
                fun(Field, Type) ->
                    blob_type(Type) andalso
                        binary:match(atom_to_binary(Field, utf8), ~"?") =:= nomatch
                end,
                kura_schema:field_types(Mod)
            );
        false ->
            #{}
    end.

-spec is_schema(module()) -> boolean().
is_schema(Mod) ->
    code:ensure_loaded(Mod) =:= {module, Mod} andalso
        erlang:function_exported(Mod, table, 0) andalso
        erlang:function_exported(Mod, fields, 0).

-spec blob_type(kura_types:kura_type()) -> boolean().
blob_type(binary) -> true;
blob_type({encrypted, _}) -> true;
blob_type({custom, _} = Type) -> column_type(Type) =:= ~"BLOB";
blob_type(_Type) -> false.

%% A query compiled once is reused with other values, so the cast is written
%% into the SQL rather than into the parameters.
-spec blob_query(#kura_query{}) -> #kura_query{}.
blob_query(#kura_query{from = From, joins = Joins, wheres = Wheres, havings = Havings} = Query) ->
    Blobs = joined_blob_fields([From | [Table || {_Type, Table, _On, _As} <- Joins]]),
    Query#kura_query{
        wheres = blob_conditions(Wheres, Blobs),
        havings = blob_conditions(Havings, Blobs),
        ctes = blob_named(Query#kura_query.ctes),
        combinations = blob_named(Query#kura_query.combinations)
    }.

%% A where-field is not qualified by its table, so the byte fields of every
%% joined schema are rewritten too. A name in two of the tables is an
%% ambiguous column to SQLite.
-spec joined_blob_fields([term()]) -> #{atom() => kura_types:kura_type()}.
joined_blob_fields([]) ->
    #{};
joined_blob_fields([Table | Rest]) ->
    maps:merge(blob_fields(Table), joined_blob_fields(Rest)).

-spec blob_named([{Name, #kura_query{}}]) -> [{Name, #kura_query{}}].
blob_named(Queries) ->
    [{Name, blob_query(Query)} || {Name, Query} <- Queries].

-spec blob_subquery(term()) -> term().
blob_subquery(#kura_query{} = Query) -> blob_query(Query);
blob_subquery(Other) -> Other.

-spec blob_conditions([term()], #{atom() => kura_types:kura_type()}) -> [term()].
blob_conditions(Conditions, Blobs) ->
    [blob_condition(Condition, Blobs) || Condition <- Conditions].

-spec blob_condition(term(), #{atom() => kura_types:kura_type()}) -> term().
blob_condition({Op, Conditions}, Blobs) when
    (Op =:= 'and' orelse Op =:= 'or'), is_list(Conditions)
->
    {Op, blob_conditions(Conditions, Blobs)};
blob_condition({fragment, _SQL, _Params} = Condition, _Blobs) ->
    Condition;
blob_condition({'not', Condition}, Blobs) ->
    {'not', blob_condition(Condition, Blobs)};
blob_condition({Exists, {subquery, Sub}}, _Blobs) when Exists =:= exists; Exists =:= not_exists ->
    {Exists, {subquery, blob_subquery(Sub)}};
blob_condition({Field, in, {subquery, Sub}}, _Blobs) ->
    {Field, in, {subquery, blob_subquery(Sub)}};
blob_condition({Field, Op, Value}, Blobs) when
    is_atom(Field), ?IS_COMPARISON(Op), is_map_key(Field, Blobs)
->
    {fragment, <<(ident(Field))/binary, " ", (atom_to_binary(Op))/binary, " ", ?CAST/binary>>, [
        Value
    ]};
blob_condition({Field, In, [_ | _] = Values}, Blobs) when
    is_atom(Field), (In =:= in orelse In =:= not_in), is_map_key(Field, Blobs)
->
    Casts = comma([?CAST || _ <- Values]),
    {fragment, <<(ident(Field))/binary, (in_sql(In))/binary, Casts/binary, ")">>, Values};
blob_condition({[_ | _] = Fields, in, [_ | _] = Rows} = Condition, Blobs) ->
    Arity = length(Fields),
    Atoms = [Field || Field <- Fields, is_atom(Field)],
    Values = [tuple_to_list(Row) || Row <- Rows, is_tuple(Row), tuple_size(Row) =:= Arity],
    case
        length(Atoms) =:= Arity andalso length(Values) =:= length(Rows) andalso
            lists:any(fun(Field) -> is_map_key(Field, Blobs) end, Atoms)
    of
        true -> row_fragment(Atoms, Values, Blobs);
        false -> Condition
    end;
blob_condition({Field, between, {Low, High}}, Blobs) when
    is_atom(Field), is_map_key(Field, Blobs)
->
    {fragment, <<(ident(Field))/binary, " BETWEEN ", ?CAST/binary, " AND ", ?CAST/binary>>, [
        Low, High
    ]};
blob_condition({Field, Value}, Blobs) when
    is_atom(Field), not ?IS_UNARY_OP(Value), is_map_key(Field, Blobs)
->
    blob_condition({Field, '=', Value}, Blobs);
blob_condition({Field, Op, _Value} = Condition, Blobs) when
    is_atom(Field), (Op =:= like orelse Op =:= ilike), is_map_key(Field, Blobs)
->
    Condition;
blob_condition({Field, In, []} = Condition, Blobs) when
    is_atom(Field), (In =:= in orelse In =:= not_in), is_map_key(Field, Blobs)
->
    Condition;
blob_condition({Field, Op, _Value}, Blobs) when is_atom(Field), is_map_key(Field, Blobs) ->
    error({kura_sqlite, {unsupported_blob_condition, Field, Op}});
blob_condition(Condition, _Blobs) ->
    Condition.

-spec row_fragment([atom()], [[term()]], #{atom() => kura_types:kura_type()}) ->
    {fragment, binary(), [term()]}.
row_fragment(Fields, Values, Blobs) ->
    Row = <<"(", (comma([placeholder(Field, Blobs) || Field <- Fields]))/binary, ")">>,
    Rows = comma([Row || _ <- Values]),
    Columns = comma([ident(Field) || Field <- Fields]),
    {fragment, <<"(", Columns/binary, ") IN (", Rows/binary, ")">>, lists:append(Values)}.

-spec placeholder(atom(), #{atom() => kura_types:kura_type()}) -> binary().
placeholder(Field, Blobs) when is_map_key(Field, Blobs) -> ?CAST;
placeholder(_Field, _Blobs) -> ~"?".

-spec in_sql(in | not_in) -> binary().
in_sql(in) -> ~" IN (";
in_sql(not_in) -> ~" NOT IN (".

-spec comma([binary()]) -> binary().
comma([]) -> <<>>;
comma([Part]) -> Part;
comma([Part | Rest]) -> <<Part/binary, ", ", (comma(Rest))/binary>>.

-spec ident(atom()) -> binary().
ident(Field) ->
    Escaped = binary:replace(atom_to_binary(Field, utf8), ~"\"", ~"\"\"", [global]),
    <<$", Escaped/binary, $">>.

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
