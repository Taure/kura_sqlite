-module(kura_sqlite).
-moduledoc """
Checks for a database used through `kura_sqlite`.
""".

-export([check_blob_columns/2]).

-export_type([blob_column_finding/0]).

-type blob_column_finding() ::
    {text_in_blob_column, Table :: binary(), Column :: atom()}
    | {check_failed, Table :: binary(), Column :: atom(), Reason :: term()}.

-doc """
Look for TEXT values in the byte columns (`binary`, every encrypted type,
and BLOB custom types) of `Schemas`' tables.

Byte fields are written as BLOB. A row an earlier kura_sqlite wrote
holds TEXT, which a query on the field does not match, and a UNIQUE index
treats it as a different value from a BLOB with the same bytes, so a new
row can shadow it. Run this after converting the columns, and before
serving, as the README's upgrade section describes.

Returns `ok` when no byte column holds TEXT. A column that cannot be
checked, for example because its table is missing, is reported as
`check_failed` rather than passed.
""".
-spec check_blob_columns(module(), [module()]) -> ok | {error, [blob_column_finding()]}.
check_blob_columns(Repo, Schemas) ->
    case
        [
            Finding
         || Schema <- Schemas,
            Column <- kura_dialect_sqlite:blob_columns(Schema),
            Finding <- column_findings(Repo, Schema:table(), Column)
        ]
    of
        [] -> ok;
        Findings -> {error, Findings}
    end.

-spec column_findings(module(), binary(), atom()) -> [blob_column_finding()].
column_findings(Repo, Table, Column) ->
    SQL =
        <<"SELECT 1 FROM ", (quoted(Table))/binary, " WHERE typeof(",
            (quoted(atom_to_binary(Column, utf8)))/binary, ") = 'text' LIMIT 1">>,
    case kura_db:query(Repo, SQL, []) of
        #{rows := []} -> [];
        #{rows := [_]} -> [{text_in_blob_column, Table, Column}];
        {error, Reason} -> [{check_failed, Table, Column, Reason}]
    end.

-spec quoted(binary()) -> binary().
quoted(Name) ->
    <<$", (binary:replace(Name, ~"\"", ~"\"\"", [global]))/binary, $">>.
