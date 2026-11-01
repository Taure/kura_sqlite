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
  with `{error, {unsupported_encoding, Encoding}}`. Binaries are stored as
  TEXT, which a UTF-16 database transcodes, so encrypted fields would not
  read back.
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

## License

MIT.
