# kura_sqlite

SQLite backend for [kura](https://github.com/Taure/kura). Provides
`kura_pool_sqlite`, `kura_driver_sqlite`, `kura_dialect_sqlite`, and
`kura_backend_sqlite` on top of the
[esqlite](https://hex.pm/packages/esqlite) NIF driver.

## Use

```erlang
{deps, [
    {kura, "~> 2.4"},
    {kura_sqlite, "~> 0.2"}
]}.
```

Point kura at the backend in `sys.config`:

```erlang
[{kura, [
    {repo, my_repo},
    {backend, kura_backend_sqlite},
    {database, <<"priv/my_app.db">>},   %% or <<":memory:">>
    {pool_size, 4}
]}].
```

On application start, Kura resolves the aggregator and auto-populates `dialect`,
`pool_module`, and `driver_module`. Per-key overrides still win.

## Status

Working: schemas, queries, migrations, `INSERT … ON CONFLICT`,
`RETURNING`, transactions, JSON storage as TEXT, boolean as `0`/`1`
(transparently round-tripped via `kura_types:cast/2`).

Not yet: `kura_sandbox` test fixtures, JSONB operators (`->`, `->>`,
`@>`), arrays.

`kura_pool_sqlite:capabilities/0`:

```
[returning, json, partial_indexes, transactions, savepoints, prepared_statements]
```

PG-only features (`advisory_locks`, `listen_notify`, `arrays`,
`jsonb`) are deliberately absent; consumers that require them refuse
to start on this backend via `kura_capabilities:require/2`.

## Caveats

- **Booleans** encode as INTEGER 0/1 on disk. `kura_types:cast/2`
  transparently decodes them back to `true`/`false` on read, so user
  code is unaffected.
- **JSON** values store as TEXT. JSONB operators (`->`, `->>`, `@>`)
  are not available; use Erlang map operations after decoding.
- **Arrays** are unsupported.
- **Composite primary and foreign keys** work the same as on Postgres
  (SQLite supports `PRIMARY KEY (a, b)` and row-value `IN`).
- **Foreign keys** are enforced. The pool turns `PRAGMA foreign_keys` on
  for every connection it opens, so `ON DELETE` rules fire and a reference
  to a missing row is refused. SQLite leaves enforcement off by default,
  so a database written without it can hold rows whose references are
  already broken; `PRAGMA foreign_key_check` lists them. Dropping a table
  that other tables reference is refused with
  `{error, {referenced_by, Table, Referencing}}`, as Postgres refuses it,
  rather than letting SQLite delete its rows and run their `ON DELETE`
  rules. `PRAGMA foreign_keys` has no effect inside a transaction and every
  kura migration runs in one, so rebuild a referenced table outside a
  migration; `kura_driver_sqlite`'s documentation has the steps.
- **Checkout waits** up to `#{timeout => Ms}` (5000 by default, or
  `infinity`) for a connection to come free, then returns
  `{error, checkout_timeout}`, as `kura_pool_minato` does.
  `#{timeout => 0}` does not wait and returns `{error, no_conns}`, and so
  does a checkout when no connection is out to come back. A process that
  already holds the last connection and checks out again waits for the
  whole timeout.
- **UTF-8 only.** `start_pool/2` refuses a database in another encoding
  with `{error, {unsupported_encoding, Encoding}}`.
- **Byte fields** (`binary`, `{encrypted, Inner}` and
  `{encrypted, Inner, Opts}`, and `{custom, Mod}` types
  whose `sqlite_type/0` is `BLOB`) are stored as BLOB, so `typeof(col)` is
  `'blob'` and the bytes do not depend on the database encoding. Queries
  on them compare against `CAST(? AS BLOB)`, including conditions on a
  byte column of a joined schema. Other binaries are stored as TEXT, and
  so are these: values written to a table named by atom or binary rather
  than a schema (including a many-to-many join table whose `join_through`
  is a binary), and values of a field, other than an encrypted one, whose
  name contains `?`. In raw SQL, pass `{blob, Bin}` to bind a BLOB.
- **Encrypted fields** cannot be compared in a query. A where or having
  condition on an encrypted field other than `is_nil`, `is_not_nil` and a
  deterministic lookup raises
  `{kura_sqlite, {encrypted_field_in_where, Field}}`, since a value
  encrypted under a fresh nonce never equals the stored ciphertext and the
  plaintext would go out with the query's parameters. An encrypted type
  kura reports `unsupported` raises
  `{kura_crypto, unsupported_encrypted_type}` when a migration declares
  it, as on Postgres.
- **Arrays of encrypted values** are not supported on SQLite.
- **Deterministic lookups**: the `encrypted_in` and `encrypted_not_in`
  conditions kura builds for a deterministic field compile to `IN` and
  `NOT IN` over `CAST(? AS BLOB)`, one per ciphertext. A lookup raises
  `{kura_sqlite, {unsupported_blob_condition, Field, Op}}` rather than
  bind the ciphertexts as TEXT when its field is not a byte field of the
  `from` schema or a joined one (a TEXT field, or any field of a table
  named by atom or binary), or when the field's name contains `?`.
- **Byte columns refuse TEXT.** A byte column a kura migration creates,
  with `create_table` or `add_column`, is declared
  `BLOB CHECK (typeof(col) IN ('blob', 'null'))`, so a TEXT value written
  by raw SQL is refused rather than stored next to a BLOB with the same
  bytes, and its `default` is written as a BLOB literal of the same bytes.
  The check is left off a column whose name contains `?`.
- **Vector distance** is unsupported. A query with `kura_query:distance/3`
  in its select, order, where or having raises
  `{unsupported, vector_distance}`, before any SQL reaches SQLite.
- **Joins and CTEs by name.** A `from` or join target named by atom or
  binary rather than a schema module, or a CTE, has no field types, so a
  where-condition on one of its BLOB columns binds TEXT. SQLite orders
  every BLOB after every TEXT value, so on such a column the exclusion
  operators `!=`, `not_in` and `NOT (=)`, and `>` and `>=`, match every
  row, while `=`, `in`, `<` and `<=` match none. Join the schema module,
  or write the condition as a fragment with `CAST(? AS BLOB)`.
- **Database paths** must name a regular file the node can read, or a
  missing file in a directory the node can read and write, which SQLite
  then creates. A directory, a missing directory, a dangling symbolic link,
  a path that comes to 500 bytes or more once made absolute and its
  symbolic links followed, or one that takes more than 100 symbolic links
  is refused with `{error, 14}`. A path holding a NUL byte, or a string
  path holding a character above 255, is refused with
  `{error, invalid_filename}`.
- **Failed opens.** esqlite 0.10.0 frees the handle twice when an open
  fails, which can corrupt the node's memory. The path checks keep bad
  paths away from it, but an open can still fail on a good path, for
  example when the node runs out of file descriptors. Give the node a
  generous `nofile` limit. The fix is in mmzeeman/esqlite#108.
- **In-memory `file:` URIs** need an esqlite built with
  `SQLITE_USE_URI`, as the default build is. Without it SQLite treats the
  URI as a file name.
- **`file:` URIs** are refused with `{error, uri_not_supported}`, since
  SQLite resolves them in ways the pool cannot check before opening. The
  in-memory forms are allowed: `file::memory:`, optionally with
  `?cache=shared` or `?cache=private`, and `file:Name?mode=memory`, `Name`
  made of ASCII letters, digits, `_`, `-` and `.`, optionally with
  `cache=shared` or `cache=private`.
- **In-memory** (`<<":memory:">>`) is per-connection. Use `pool_size: 1`
  if multiple checkouts must observe the same data, a shared-cache URI
  such as `<<"file:my_db?mode=memory&cache=shared">>`, or a file path.

## Upgrading from 0.5

- **`file:` URIs** are refused with `{error, uri_not_supported}`, except
  the in-memory forms listed under Caveats. This breaks any other URI
  `database` setting.
- **Checkout waits** for a connection to come free, up to
  `#{timeout => Ms}`, 5000 by default, instead of returning
  `{error, no_conns}` at once. A caller whose time runs out gets
  `{error, checkout_timeout}`; `#{timeout => 0}` keeps the old behaviour.
- **`DROP TABLE`** on a table another table references is refused with
  `{error, {referenced_by, Table, Referencing}}`, so a migration rollback
  that drops a parent before its children fails instead of deleting the
  children's rows. A `DROP TABLE` the check cannot read is refused with
  `{error, unrecognised_drop_table}`, and outside a transaction the check
  and the drop run in one `BEGIN IMMEDIATE` transaction.
- **Dangling symbolic links** as the database path are refused with
  `{error, 14}`. SQLite used to follow the link and create its target.
- **Busy database**: a statement that waits out the busy timeout returns
  `{error, busy}` instead of crashing the caller. esqlite is now `~> 0.10`.
- **Foreign keys** are on for every pooled connection, and the pool opens
  only UTF-8 databases.
- **Parameters** bind by position only. A `{Name, Value}` or
  `{Type, Name, Value}` parameter, which esqlite took as a named bind when
  it came first, and any other value the driver cannot bind, returns
  `{error, {unsupported_param, Index}}` instead of binding or crashing.
- **Byte fields** are written as BLOB instead of TEXT. A row written
  before holds TEXT, which a query on the field no longer matches, and a
  UNIQUE index treats TEXT `'abc'` and BLOB `'abc'` as different values.
  So until a column is converted, an upsert whose conflict target is that
  column misses the old row and inserts a second one, and a lookup finds
  only the new one. See below for how to convert, how to handle rows
  written before converting, and how to check that none are left.
- **Migrations** declare new byte columns with
  `CHECK (typeof(col) IN ('blob', 'null'))`. Columns created before keep
  no check.
- **NULL** reads as `null` in driver results, as kura_postgres returns it,
  instead of `undefined`. Rows loaded through a schema still hold
  `undefined`, and a NULL `{encrypted, _}` field now loads instead of
  crashing. A raw `kura_db:query/3` sees `null`, and so does
  `kura_repo_worker:aggregate/3`: a `sum`, `min`, `max` or `avg` over no
  rows returns `{ok, null}` rather than `{ok, undefined}`.
  `aggregate/4` returns its default for either.
- **Row counts**: an `INSERT`, `UPDATE`, `DELETE` or `REPLACE` without
  `RETURNING`, also after a `WITH`, reports the rows it changed, so
  `update_all`, `delete_all` and `insert_all` return the real count
  instead of `{ok, 0}`.
- **Raw query results**: a raw `kura_db:query/3` write without
  `RETURNING` now reports its real `num_rows` instead of 0, and a
  `WITH ... SELECT` reports `command := select` instead of `other`.
  Callers matching on the old values need updating.

### Converting byte columns

Convert every `binary`, encrypted and BLOB custom column before
the new version writes anything. The safest way is a kura migration
that ships in the same deploy, so it runs before any other write:

```erlang
up() ->
    [{execute, ~"UPDATE t SET col = CAST(col AS BLOB) WHERE typeof(col) = 'text'"}].

down() ->
    [].
```

On a UTF-8 database the cast keeps the bytes exactly as they are.

If the new version has already written to a UNIQUE column, the column
can hold the same bytes twice, once as TEXT and once as BLOB, and the
conversion fails with `UNIQUE constraint failed`. To list the pairs:

```sql
SELECT old.rowid AS text_row, new.rowid AS blob_row
FROM t AS old
JOIN t AS new ON new.col = CAST(old.col AS BLOB)
WHERE typeof(old.col) = 'text' AND typeof(new.col) = 'blob';
```

For each pair, keep one row and delete the other, first moving over
anything that references the row you delete. The BLOB row is the newer
one. Then run the conversion.

After the upgrade, check that no byte column still holds TEXT, for
example when the application starts, and refuse to serve until it does
not:

```erlang
ok = kura_sqlite:check_blob_columns(my_repo, [my_user, my_api_key]).
```

It returns `{error, [{text_in_blob_column, Table, Column}]}` for each
column that still holds a TEXT value, and
`{error, [{check_failed, Table, Column, Reason}]}` for one it could not
read. A column created by an earlier kura_sqlite has no CHECK, so raw
SQL can still write TEXT to it; to add one, rebuild the table as SQLite's
[ALTER TABLE](https://www.sqlite.org/lang_altertable.html#otheralter)
page describes.

## License

MIT.
