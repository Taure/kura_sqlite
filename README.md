# kura_sqlite

SQLite backend for [kura](https://github.com/Taure/kura).

Provides `kura_pool_sqlite`, `kura_driver_sqlite`, `kura_dialect_sqlite`,
and `kura_backend_sqlite` so kura applications can target SQLite via the
[esqlite](https://hex.pm/packages/esqlite) NIF driver.

## Use

Add `kura` and `kura_sqlite` to your `rebar.config`:

```erlang
{deps, [
    {kura, "~> 2.0"},
    {kura_sqlite, "~> 0.1"}
]}.
```

Configure your repo to use the SQLite backend:

```erlang
{my_app, [
    {repo, [
        {backend, kura_backend_sqlite},
        {database, "priv/myapp.db"},
        {pool_size, 4}
    ]}
]}.
```

## Status

This is a phase-2 skeleton. The core SQL surface (SELECT / INSERT / UPDATE /
DELETE / WHERE / ORDER / LIMIT / RETURNING / ON CONFLICT) works through
the `kura_dialect_sqlite` placeholder rewrite. Type mapping, full migration
DDL, and the sandbox path are tracked for phase 3.

Capability set declared by `kura_pool_sqlite`:

```
[returning, json, partial_indexes, transactions, savepoints, prepared_statements]
```

PG-only features (`advisory_locks`, `listen_notify`, `arrays`) are deliberately
absent; consumers that require them will refuse to start on this backend
via `kura_capabilities:require/2`.

## License

MIT.
