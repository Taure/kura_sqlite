-module(kura_backend_sqlite).
-moduledoc """
SQLite backend aggregator. One config knob for users:

```erlang
{repo, [
    {backend, kura_backend_sqlite},
    {database, "priv/myapp.db"},
    {pool_size, 4}
]}.
```

The aggregator wires up:

- `pool_module` -> `kura_pool_sqlite`
- `driver_module` -> `kura_driver_sqlite`
- `dialect` -> `kura_dialect_sqlite`
- `capabilities` -> declared on `kura_pool_sqlite`

Consumers that need to query capabilities directly can call
`kura_capabilities:require(kura_pool_sqlite, [returning, ...])`.
""".

-export([
    pool_module/0,
    driver_module/0,
    dialect/0,
    capabilities/0
]).

-spec pool_module() -> module().
pool_module() -> kura_pool_sqlite.

-spec driver_module() -> module().
driver_module() -> kura_driver_sqlite.

-spec dialect() -> module().
dialect() -> kura_dialect_sqlite.

-doc "Forwards to `kura_pool_sqlite:capabilities/0` so consumers can query the backend's feature set without knowing the impl module names.".
-spec capabilities() -> kura_capabilities:capability_set().
capabilities() -> kura_pool_sqlite:capabilities().
