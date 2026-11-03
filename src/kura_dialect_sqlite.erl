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

A schema field stored in a BLOB column (`binary`, an encrypted type, or a
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
  as a placeholder, unless the field is encrypted.
- a where-condition on a byte column of a table named by atom or binary
  rather than a schema module, either as the query's `from` or as a join,
  or on a column of a CTE. With no field types there is nothing to cast,
  and SQLite orders every BLOB after every TEXT value, so on such a column
  `!=`, `not_in`, `NOT (=)`, `>` and `>=` match every row and `=`, `in`,
  `<` and `<=` match none.

The byte fields of the `from` schema and of every joined schema are
rewritten, since a where-field is not qualified by its table.

A byte column `kura_migrator` creates is declared
`BLOB CHECK (typeof(col) IN ('blob', 'null'))`, so it refuses a TEXT value
(see `blob_checks/1`).

A field is encrypted when `kura_types:encryption/1` says so, which
covers `{encrypted, Inner}` and `{encrypted, Inner, Opts}`. An encrypted
type that kura reports `unsupported` raises
`{kura_crypto, unsupported_encrypted_type}` in `column_type/1`, as kura's
PG dialect does, so a migration declaring one fails. A type with no
SQLite storage raises `{kura_sqlite, {unsupported_type, Type}}`, and so
does an array of an encrypted type: in `column_type/1`, and when a list is
written to such a field by `insert`, `update`, `delete`, `insert_all` or
the `SET` of `update_all`. A condition on an encrypted
field other than `is_nil`, `is_not_nil` or a deterministic lookup raises
`{kura_sqlite, {encrypted_field_in_where, Field}}`, in a where or a
having, on the `from` schema or a joined one. A value encrypted under a
fresh nonce never equals the stored ciphertext, and the plaintext would
travel with the query's parameters.

A deterministic lookup, `{Field, encrypted_in, Frames}` or
`{Field, encrypted_not_in, Frames}`, which `kura_query:where/2` and
`having/2` build for a deterministic field, compiles to
`"Field" IN (CAST(? AS BLOB), ...)` or `NOT IN (...)`, one cast per frame.
A lookup on any other field raises
`{kura_sqlite, {unsupported_blob_condition, Field, Op}}`: a randomized
encrypted field, an encrypted type kura reports `unsupported`, an array of
an encrypted type, a `binary` or other non-encrypted field, a field of a
table named by atom or binary, and a field whose name contains `?`. On a
field that is not deterministic the frames would be plaintext, and
`encrypted_not_in` would match every row.

A condition on a byte field with an operator the rewrite cannot cast
raises `{kura_sqlite, {unsupported_blob_condition, Field, Op}}`. `like`,
`ilike`, `is_nil`, `is_not_nil` and an empty `in` or `not_in` list are
passed through unchanged.

## Vector distance

SQLite has no vector distance operators. A query holding a
`kura_query:distance/3` node, in a select expression, an `order_by` or a
distance threshold of a where or a having, in the query or in any of its
CTEs, combinations or condition subqueries, raises
`{unsupported, vector_distance}` before any SQL is emitted, as the
`kura_dialect` contract requires. pgvector's `<->`, `<=>` and `<#>` never
reach SQLite.

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
    swap_placeholders/1,
    blob_checks/1,
    blob_columns/1
]).

-define(CAST, ~"CAST(? AS BLOB)").
-type fields() :: {
    Types :: #{atom() => kura_types:kura_type()}, Blobs :: #{atom() => kura_types:kura_type()}
}.
%% column_type/1 of a byte column. The comment is the marker blob_checks/1
%% replaces, since a column's CHECK names it and column_type/1 is not given
%% the name.
-define(BLOB_MARKER, "BLOB /* kura_sqlite: blob */").
-define(BLOB_COLUMN, <<?BLOB_MARKER>>).
%% kura's ?KURA_IS_UNARY_OP, which the pinned kura does not define yet.
-define(IS_UNARY_OP(Op), (Op =:= is_nil orelse Op =:= is_not_nil)).
%% kura's ?KURA_IS_LOOKUP_OP, which the pinned kura does not define yet.
-define(IS_LOOKUP_OP(Op), (Op =:= encrypted_in orelse Op =:= encrypted_not_in)).
-define(IS_COMPARISON(Op),
    (Op =:= '=' orelse Op =:= '!=' orelse Op =:= '<' orelse Op =:= '>' orelse Op =:= '<=' orelse
        Op =:= '>=')
).

%%----------------------------------------------------------------------
%% kura_dialect callbacks
%%----------------------------------------------------------------------

-spec to_sql(#kura_query{}) -> {iodata(), [term()]}.
to_sql(Query) ->
    ok = refuse_distances(Query),
    {SQL, Params} = kura_dialect_pg:to_sql(blob_query(Query)),
    {swap_placeholders(SQL), Params}.

-spec to_sql_from(#kura_query{}, pos_integer()) -> {iodata(), [term()], pos_integer()}.
to_sql_from(Query, StartCounter) ->
    ok = refuse_distances(Query),
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
    ok = refuse_distances(Query),
    {SQL, Params} = kura_dialect_pg:update_all(blob_query(Query), blob_values(From, SetMap)),
    {swap_placeholders(SQL), Params}.

-spec delete_all(#kura_query{}) -> {iodata(), [term()]}.
delete_all(Query) ->
    ok = refuse_distances(Query),
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
column_type(Type) ->
    case storage_type(Type) of
        ~"BLOB" -> ?BLOB_COLUMN;
        Storage -> Storage
    end.

-spec storage_type(kura_types:kura_type()) -> binary().
storage_type(id) ->
    ~"INTEGER";
storage_type(integer) ->
    ~"INTEGER";
storage_type(bigint) ->
    ~"INTEGER";
storage_type(smallint) ->
    ~"INTEGER";
storage_type(float) ->
    ~"REAL";
storage_type(decimal) ->
    ~"NUMERIC";
storage_type(string) ->
    ~"TEXT";
storage_type(text) ->
    ~"TEXT";
storage_type(binary) ->
    ~"BLOB";
storage_type(boolean) ->
    ~"INTEGER";
storage_type(date) ->
    ~"TEXT";
storage_type(time) ->
    ~"TEXT";
storage_type(utc_datetime) ->
    ~"TEXT";
storage_type(naive_datetime) ->
    ~"TEXT";
storage_type(uuid) ->
    ~"TEXT";
storage_type(jsonb) ->
    ~"TEXT";
storage_type({enum, _}) ->
    ~"TEXT";
storage_type({array, _} = Type) ->
    ok = supported_array(Type),
    ~"TEXT";
storage_type({embed, _, _}) ->
    ~"TEXT";
storage_type({custom, Mod}) ->
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, sqlite_type, 0) of
        true -> Mod:sqlite_type();
        false -> Mod:pg_type()
    end;
storage_type(Type) ->
    case kura_types:encryption(Type) of
        {ok, _Spec} -> ~"BLOB";
        unsupported -> erlang:error({kura_crypto, unsupported_encrypted_type});
        none -> erlang:error({kura_sqlite, {unsupported_type, Type}})
    end.

%% kura_driver_sqlite binds a list as one TEXT value, which would corrupt
%% ciphertexts, so an array of an encrypted type is refused.
-spec supported_array({array, kura_types:kura_type()}) -> ok.
supported_array({array, Inner} = Type) ->
    case kura_types:encryption(Inner) of
        none -> ok;
        _ -> erlang:error({kura_sqlite, {unsupported_type, Type}})
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

-doc """
Add `CHECK (typeof(col) IN ('blob', 'null'))` to every byte column a
`CREATE TABLE` or `ALTER TABLE ... ADD COLUMN` from `kura_migrator`
defines, found by the marker `column_type/1` writes for it.
`kura_driver_sqlite` applies it to every `CREATE` and `ALTER` statement.

A UNIQUE index treats TEXT and BLOB holding the same bytes as different
values, so a TEXT row in a byte column could be shadowed by a BLOB row
with the same bytes. A column whose name holds `?`, whose values bind as
TEXT, is left without the check. A marker inside a quoted literal or
identifier is not a column. A marker that does not follow a quoted column
name returns `{error, unrecognised_blob_column}`, rather than leave a byte
column without its check.

The column's default, which `kura_migrator` writes as a TEXT literal the
check would refuse, is written as a BLOB literal of the same bytes. A
default that is neither a quoted literal nor a number returns
`{error, unrecognised_blob_default}`.
""".
-spec blob_checks(binary()) ->
    {ok, binary()} | {error, unrecognised_blob_column | unrecognised_blob_default}.
blob_checks(SQL) ->
    case binary:match(SQL, ?BLOB_COLUMN) of
        nomatch -> {ok, SQL};
        _ -> checked(SQL, <<>>, none)
    end.

%% kura_migrator writes a column as `"name" Type`, so a marker follows the
%% last quoted name read and a space.
-spec checked(binary(), binary(), binary() | none) ->
    {ok, binary()} | {error, unrecognised_blob_column | unrecognised_blob_default}.
checked(<<>>, Acc, _Name) ->
    {ok, Acc};
checked(<<?BLOB_MARKER, Rest/binary>>, Acc, Name) when is_binary(Name) ->
    case binary:longest_common_suffix([Acc, <<Name/binary, " ">>]) =:= byte_size(Name) + 1 of
        true -> blob_column(Name, Rest, Acc);
        false -> {error, unrecognised_blob_column}
    end;
checked(<<?BLOB_MARKER, _/binary>>, _Acc, none) ->
    {error, unrecognised_blob_column};
checked(<<Quote, Rest/binary>>, Acc, Name) when Quote =:= $'; Quote =:= $" ->
    {Quoted, Tail} = quoted(Rest, Quote, <<Quote>>),
    case Quote of
        $" -> checked(Tail, <<Acc/binary, Quoted/binary>>, Quoted);
        $' -> checked(Tail, <<Acc/binary, Quoted/binary>>, Name)
    end;
checked(<<Byte, Rest/binary>>, Acc, Name) ->
    checked(Rest, <<Acc/binary, Byte>>, Name).

%% A quoted literal or identifier, the quote doubled inside it. An
%% unterminated one runs to the end, and SQLite refuses the statement.
-spec quoted(binary(), byte(), binary()) -> {binary(), binary()}.
quoted(<<First, Second, Rest/binary>>, Quote, Acc) when First =:= Quote, Second =:= Quote ->
    quoted(Rest, Quote, <<Acc/binary, Quote, Quote>>);
quoted(<<First, Rest/binary>>, Quote, Acc) when First =:= Quote ->
    {<<Acc/binary, Quote>>, Rest};
quoted(<<Byte, Rest/binary>>, Quote, Acc) ->
    quoted(Rest, Quote, <<Acc/binary, Byte>>);
quoted(<<>>, _Quote, Acc) ->
    {Acc, <<>>}.

-spec blob_column(binary(), binary(), binary()) ->
    {ok, binary()} | {error, unrecognised_blob_column | unrecognised_blob_default}.
blob_column(Name, Rest, Acc) ->
    case {binary:match(Name, ~"?"), blob_default(Rest)} of
        {nomatch, {ok, Constraints, Tail}} ->
            Check = <<"BLOB CHECK (typeof(", Name/binary, ") IN ('blob', 'null'))">>,
            checked(Tail, <<Acc/binary, Check/binary, Constraints/binary>>, none);
        {nomatch, {error, _} = Error} ->
            Error;
        {_, _} ->
            checked(Rest, <<Acc/binary, ?BLOB_MARKER>>, none)
    end.

%% kura_migrator writes a column's constraints as
%% `[ PRIMARY KEY][ NOT NULL][ DEFAULT Value]...`. A default is written as a
%% TEXT literal, which the CHECK would refuse, so it becomes a BLOB literal
%% of the same bytes.
-spec blob_default(binary()) -> {ok, binary(), binary()} | {error, unrecognised_blob_default}.
blob_default(Rest) ->
    {Kept, After} = leading(Rest, [~" PRIMARY KEY", ~" NOT NULL"], <<>>),
    case After of
        <<" DEFAULT ", Default/binary>> ->
            case default_bytes(Default) of
                {ok, Bytes, Tail} ->
                    Hex = binary:encode_hex(Bytes),
                    {ok, <<Kept/binary, " DEFAULT X'", Hex/binary, "'">>, Tail};
                error ->
                    {error, unrecognised_blob_default}
            end;
        _ ->
            {ok, Kept, After}
    end.

-spec leading(binary(), [binary()], binary()) -> {binary(), binary()}.
leading(SQL, [], Acc) ->
    {Acc, SQL};
leading(SQL, [Word | Words], Acc) ->
    Size = byte_size(Word),
    case SQL of
        <<Word:Size/binary, Rest/binary>> -> leading(Rest, Words, <<Acc/binary, Word/binary>>);
        _ -> leading(SQL, Words, Acc)
    end.

-spec default_bytes(binary()) -> {ok, binary(), binary()} | error.
default_bytes(<<$', Rest/binary>>) ->
    literal(Rest, <<>>);
default_bytes(Default) ->
    number(Default, <<>>).

-spec literal(binary(), binary()) -> {ok, binary(), binary()} | error.
literal(<<$', $', Rest/binary>>, Acc) ->
    literal(Rest, <<Acc/binary, $'>>);
literal(<<$', Rest/binary>>, Acc) ->
    {ok, Acc, Rest};
literal(<<Byte, Rest/binary>>, Acc) ->
    literal(Rest, <<Acc/binary, Byte>>);
literal(<<>>, _Acc) ->
    error.

-spec number(binary(), binary()) -> {ok, binary(), binary()} | error.
number(<<Byte, Rest/binary>>, Acc) when
    Byte >= $0, Byte =< $9; Byte =:= $-; Byte =:= $+; Byte =:= $.; Byte =:= $e; Byte =:= $E
->
    number(Rest, <<Acc/binary, Byte>>);
number(_Rest, <<>>) ->
    error;
number(Rest, Acc) ->
    {ok, Acc, Rest}.

-doc """
The fields of a schema stored in BLOB columns, in field order, leaving out
virtual fields. `kura_sqlite:check_blob_columns/2` checks these.
""".
-spec blob_columns(module()) -> [atom()].
blob_columns(Schema) ->
    Blobs = blob_fields(Schema),
    [Field || Field <- kura_schema:non_virtual_fields(Schema), is_map_key(Field, Blobs)].

%%----------------------------------------------------------------------
%% Vector distance
%%----------------------------------------------------------------------

%% kura_dialect_pg would emit pgvector's operators, which SQLite does not
%% have. Every position it compiles a distance in is checked: a select
%% expression, an order_by and the left side of a condition, in the query
%% and in its CTEs, combinations and condition subqueries.
-spec refuse_distances(term()) -> ok.
refuse_distances(#kura_query{
    select = Select,
    wheres = Wheres,
    havings = Havings,
    order_bys = Orders,
    ctes = Ctes,
    combinations = Combinations
}) ->
    ok = refuse_select_distances(Select),
    ok = refuse_condition_distances(Wheres),
    ok = refuse_condition_distances(Havings),
    ok = refuse_order_distances(Orders),
    ok = refuse_named_distances(Ctes),
    refuse_named_distances(Combinations);
refuse_distances(_Query) ->
    ok.

-spec refuse_select_distances(term()) -> ok.
refuse_select_distances({exprs, Exprs}) ->
    refuse_expr_distances(Exprs);
refuse_select_distances(_Select) ->
    ok.

-spec refuse_expr_distances(term()) -> ok.
refuse_expr_distances([{_Alias, Expr} | Rest]) ->
    ok = refuse_distance(Expr),
    refuse_expr_distances(Rest);
refuse_expr_distances([_ | Rest]) ->
    refuse_expr_distances(Rest);
refuse_expr_distances(_Exprs) ->
    ok.

-spec refuse_order_distances(term()) -> ok.
refuse_order_distances([{Expr, _Dir} | Rest]) ->
    ok = refuse_distance(Expr),
    refuse_order_distances(Rest);
refuse_order_distances([_ | Rest]) ->
    refuse_order_distances(Rest);
refuse_order_distances(_Orders) ->
    ok.

-spec refuse_condition_distances(term()) -> ok.
refuse_condition_distances([Condition | Rest]) ->
    ok = refuse_condition_distance(Condition),
    refuse_condition_distances(Rest);
refuse_condition_distances(_Conditions) ->
    ok.

-spec refuse_condition_distance(term()) -> ok.
refuse_condition_distance({Op, Conditions}) when Op =:= 'and'; Op =:= 'or' ->
    refuse_condition_distances(Conditions);
refuse_condition_distance({'not', Condition}) ->
    refuse_condition_distance(Condition);
refuse_condition_distance({Exists, {subquery, Sub}}) when
    Exists =:= exists; Exists =:= not_exists
->
    refuse_distances(Sub);
refuse_condition_distance({Field, in, {subquery, Sub}}) ->
    ok = refuse_distance(Field),
    refuse_distances(Sub);
refuse_condition_distance({Field, _Op, _Value}) ->
    refuse_distance(Field);
refuse_condition_distance({Field, _Value}) ->
    refuse_distance(Field);
refuse_condition_distance(_Condition) ->
    ok.

-spec refuse_named_distances(term()) -> ok.
refuse_named_distances([{_Name, Query} | Rest]) ->
    ok = refuse_distances(Query),
    refuse_named_distances(Rest);
refuse_named_distances(_Queries) ->
    ok.

-spec refuse_distance(term()) -> ok.
refuse_distance({distance, _Field, _Metric, _Vector}) -> error({unsupported, vector_distance});
refuse_distance(_Expr) -> ok.

%%----------------------------------------------------------------------
%% Byte fields
%%----------------------------------------------------------------------

-spec blob_values(term(), map()) -> map().
blob_values(Table, Values) ->
    {Types, _Blobs} = Fields = schema_fields(Table),
    case map_size(Types) of
        0 -> Values;
        _ -> maps:map(fun(Field, Value) -> blob_value(Field, Value, Fields) end, Values)
    end.

-spec blob_keys(term(), [{atom(), term()}]) -> [{atom(), term()}].
blob_keys(Table, KeyClauses) ->
    Fields = schema_fields(Table),
    [{Field, blob_value(Field, Value, Fields)} || {Field, Value} <- KeyClauses].

-spec blob_value(atom(), term(), fields()) -> term().
blob_value(Field, Value, {_Types, Blobs}) when is_binary(Value), is_map_key(Field, Blobs) ->
    {blob, Value};
blob_value(Field, Value, {Types, _Blobs}) when is_list(Value) ->
    ok =
        case Types of
            #{Field := {array, _} = Type} -> supported_array(Type);
            #{} -> ok
        end,
    Value;
blob_value(_Field, Value, _Fields) ->
    Value.

-spec blob_fields(term()) -> #{atom() => kura_types:kura_type()}.
blob_fields(Table) ->
    {_Types, Blobs} = schema_fields(Table),
    Blobs.

%% A schema's field types and its byte fields. Kept in persistent_term per
%% module, and recomputed when kura's field types differ, as they do after
%% kura_schema:forget/1. A module that is not a schema is not cached, since
%% it may be loaded later.
-spec schema_fields(term()) -> fields().
schema_fields(Mod) when is_atom(Mod), Mod =/= undefined ->
    Key = {?MODULE, blob_fields, Mod},
    case cached(Key) of
        {Types, Blobs} when is_map(Types), is_map(Blobs) ->
            case kura_schema:field_types(Mod) of
                Types -> {Types, Blobs};
                Changed -> cache_schema_fields(Key, Changed)
            end;
        _ ->
            case is_schema(Mod) of
                true -> cache_schema_fields(Key, kura_schema:field_types(Mod));
                false -> {#{}, #{}}
            end
    end;
schema_fields(_Table) ->
    {#{}, #{}}.

-spec cache_schema_fields(term(), #{atom() => kura_types:kura_type()}) -> fields().
cache_schema_fields(Key, Types) ->
    Fields = {Types, schema_blob_fields(Types)},
    persistent_term:put(Key, Fields),
    Fields.

%% persistent_term is untyped; what is stored under the key is the pair
%% schema_fields/1 put there.
-spec cached(term()) -> dynamic().
cached(Key) ->
    persistent_term:get(Key, undefined).

%% The fields of a schema stored in BLOB columns. A name holding `?` is left
%% out, since it would be read as a placeholder in a fragment, unless the
%% field is encrypted: a condition on one is refused before any fragment.
-spec schema_blob_fields(#{atom() => kura_types:kura_type()}) ->
    #{atom() => kura_types:kura_type()}.
schema_blob_fields(Types) ->
    maps:filter(
        fun(Field, Type) ->
            encrypted_type(Type) orelse (blob_type(Type) andalso placeholder_free(Field))
        end,
        Types
    ).

-spec is_schema(module()) -> boolean().
is_schema(Mod) ->
    code:ensure_loaded(Mod) =:= {module, Mod} andalso
        erlang:function_exported(Mod, table, 0) andalso
        erlang:function_exported(Mod, fields, 0).

-spec placeholder_free(atom()) -> boolean().
placeholder_free(Field) ->
    binary:match(atom_to_binary(Field, utf8), ~"?") =:= nomatch.

-spec encrypted_type(kura_types:kura_type()) -> boolean().
encrypted_type({array, _}) -> false;
encrypted_type(Type) -> kura_types:encryption(Type) =/= none.

-spec blob_type(kura_types:kura_type()) -> boolean().
blob_type(binary) -> true;
blob_type({custom, _} = Type) -> storage_type(Type) =:= ~"BLOB";
blob_type(_Type) -> false.

%% A query compiled once is reused with other values, so the cast is written
%% into the SQL rather than into the parameters.
-spec blob_query(#kura_query{}) -> #kura_query{}.
blob_query(#kura_query{from = From, joins = Joins, wheres = Wheres, havings = Havings} = Query) ->
    Fields = joined_fields([From | [Table || {_Type, Table, _On, _As} <- Joins]]),
    Query#kura_query{
        wheres = blob_conditions(Wheres, Fields),
        havings = blob_conditions(Havings, Fields),
        ctes = blob_named(Query#kura_query.ctes),
        combinations = blob_named(Query#kura_query.combinations)
    }.

%% A where-field is not qualified by its table, so the fields of every
%% joined schema are rewritten too. A name in two of the tables is an
%% ambiguous column to SQLite.
-spec joined_fields([term()]) -> fields().
joined_fields([]) ->
    {#{}, #{}};
joined_fields([Table | Rest]) ->
    {Types, Blobs} = schema_fields(Table),
    {RestTypes, RestBlobs} = joined_fields(Rest),
    {maps:merge(Types, RestTypes), maps:merge(Blobs, RestBlobs)}.

-spec blob_named([{Name, #kura_query{}}]) -> [{Name, #kura_query{}}].
blob_named(Queries) ->
    [{Name, blob_query(Query)} || {Name, Query} <- Queries].

-spec blob_subquery(term()) -> term().
blob_subquery(#kura_query{} = Query) -> blob_query(Query);
blob_subquery(Other) -> Other.

-spec blob_conditions([term()], fields()) -> [term()].
blob_conditions(Conditions, Fields) ->
    [blob_condition(Condition, Fields) || Condition <- Conditions].

-spec blob_condition(term(), fields()) -> term().
blob_condition({Op, Conditions}, Fields) when
    (Op =:= 'and' orelse Op =:= 'or'), is_list(Conditions)
->
    {Op, blob_conditions(Conditions, Fields)};
blob_condition({fragment, _SQL, _Params} = Condition, _Fields) ->
    Condition;
blob_condition({'not', Condition}, Fields) ->
    {'not', blob_condition(Condition, Fields)};
blob_condition({Exists, {subquery, Sub}}, _Fields) when Exists =:= exists; Exists =:= not_exists ->
    {Exists, {subquery, blob_subquery(Sub)}};
blob_condition({Field, Op, Frames}, {Types, Blobs}) when
    is_atom(Field), ?IS_LOOKUP_OP(Op), is_list(Frames)
->
    case deterministic_field(Field, Types) of
        true -> cast_condition({Field, lookup_in(Op), Frames}, Blobs);
        false -> error({kura_sqlite, {unsupported_blob_condition, Field, Op}})
    end;
blob_condition(Condition, {Types, Blobs}) ->
    case [Field || Field <- compared_fields(Condition), is_encrypted(Field, Types)] of
        [Field | _] -> error({kura_sqlite, {encrypted_field_in_where, Field}});
        [] -> cast_condition(Condition, Blobs)
    end.

%% Only a deterministic field is looked up: on any other field the frames
%% would be plaintext, and NOT IN would match every row.
-spec deterministic_field(atom(), #{atom() => kura_types:kura_type()}) -> boolean().
deterministic_field(Field, Types) ->
    case Types of
        #{Field := Type} ->
            placeholder_free(Field) andalso deterministic(kura_types:encryption(Type));
        #{} ->
            false
    end.

-spec deterministic(kura_types:encryption()) -> boolean().
deterministic({ok, Spec}) -> maps:get(mode, Spec, randomized) =:= deterministic;
deterministic(_Encryption) -> false.

-spec compared_fields(term()) -> [atom()].
compared_fields({Field, Unary}) when is_atom(Field), ?IS_UNARY_OP(Unary) ->
    [];
compared_fields({Fields, _Op, _Value}) when is_list(Fields) ->
    [Field || Field <- Fields, is_atom(Field)];
compared_fields({Field, _Op, _Value}) when is_atom(Field) ->
    [Field];
compared_fields({Field, _Value}) when is_atom(Field) ->
    [Field];
compared_fields(_Condition) ->
    [].

-spec is_encrypted(atom(), #{atom() => kura_types:kura_type()}) -> boolean().
is_encrypted(Field, Types) ->
    case Types of
        #{Field := Type} -> kura_types:encryption(Type) =/= none;
        #{} -> false
    end.

-spec cast_condition(term(), #{atom() => kura_types:kura_type()}) -> term().
cast_condition({Field, in, {subquery, Sub}}, _Blobs) ->
    {Field, in, {subquery, blob_subquery(Sub)}};
cast_condition({Field, Op, Value}, Blobs) when
    is_atom(Field), ?IS_COMPARISON(Op), is_map_key(Field, Blobs)
->
    {fragment, <<(ident(Field))/binary, " ", (atom_to_binary(Op))/binary, " ", ?CAST/binary>>, [
        Value
    ]};
cast_condition({Field, In, [_ | _] = Values}, Blobs) when
    is_atom(Field), (In =:= in orelse In =:= not_in), is_map_key(Field, Blobs)
->
    Casts = comma([?CAST || _ <- Values]),
    {fragment, <<(ident(Field))/binary, (in_sql(In))/binary, Casts/binary, ")">>, Values};
cast_condition({[_ | _] = Fields, in, [_ | _] = Rows} = Condition, Blobs) ->
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
cast_condition({Field, between, {Low, High}}, Blobs) when
    is_atom(Field), is_map_key(Field, Blobs)
->
    {fragment, <<(ident(Field))/binary, " BETWEEN ", ?CAST/binary, " AND ", ?CAST/binary>>, [
        Low, High
    ]};
cast_condition({Field, Value}, Blobs) when
    is_atom(Field), not ?IS_UNARY_OP(Value), is_map_key(Field, Blobs)
->
    cast_condition({Field, '=', Value}, Blobs);
cast_condition({Field, Op, _Value} = Condition, Blobs) when
    is_atom(Field), (Op =:= like orelse Op =:= ilike), is_map_key(Field, Blobs)
->
    Condition;
cast_condition({Field, In, []} = Condition, Blobs) when
    is_atom(Field), (In =:= in orelse In =:= not_in), is_map_key(Field, Blobs)
->
    Condition;
cast_condition({Field, Op, _Value}, Blobs) when is_atom(Field), is_map_key(Field, Blobs) ->
    error({kura_sqlite, {unsupported_blob_condition, Field, Op}});
cast_condition(Condition, _Blobs) ->
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

-spec lookup_in(encrypted_in | encrypted_not_in) -> in | not_in.
lookup_in(encrypted_in) -> in;
lookup_in(encrypted_not_in) -> not_in.

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
