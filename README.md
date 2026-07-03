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
- **In-memory** (`<<":memory:">>`) is per-connection. Use `pool_size: 1`
  if multiple checkouts must observe the same data, or use a file path.

## License

MIT.
