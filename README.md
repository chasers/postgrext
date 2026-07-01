# Postgrext

A rewrite of [PostgREST](https://postgrest.org) in Elixir. Point it at a
PostgreSQL database and it serves a RESTful API from the schema, speaking
PostgREST's query syntax: tables and views become endpoints, functions become
RPC calls, and foreign keys drive resource embedding.

Everything is executed as parameterized SQL with identifiers validated against
an introspected schema cache; Postgres itself renders the JSON response bodies
(`json_agg` / `to_json`), so all Postgres types serialize correctly.

## Requirements

- Elixir 1.20 / OTP 29, pinned in `mise.toml` — run `mise install` to get the
  toolchain (older versions down to Elixir 1.16 / OTP 26 also work)
- PostgreSQL (any reasonably modern version)

## Running

```sh
mise install
mix deps.get

PGRST_DB_URI="postgres://user:pass@localhost:5432/mydb" \
PGRST_DB_SCHEMAS="public" \
PGRST_DB_ANON_ROLE="web_anon" \
PGRST_JWT_SECRET="reallyreallyreallyreallyverysafe" \
PGRST_SERVER_PORT=3000 \
mix run --no-halt
```

Without `PGRST_DB_URI` the application starts nothing, so the codebase can be
compiled and unit-tested with no database around.

### Configuration

PostgREST-compatible environment variables:

| Variable | Meaning | Default |
|---|---|---|
| `PGRST_DB_URI` | Postgres connection URI (required to serve) | — |
| `PGRST_DB_SCHEMAS` | Comma-separated schemas to expose; first is the default | `public` |
| `PGRST_DB_ANON_ROLE` | Role for unauthenticated requests (`set local role`) | connection role |
| `PGRST_DB_POOL` | Connection pool size | `10` |
| `PGRST_JWT_SECRET` | HS256 secret; enables `Bearer` JWT auth via the `role` claim | auth disabled |
| `PGRST_SERVER_PORT` | HTTP port | `3000` |

Every request runs in a transaction with `set_config('role', ...)` and
`set_config('request.jwt.claims', ...)` applied, so row-level security and
`current_setting('request.jwt.claims')` work as they do under PostgREST.

## API

```
GET    /                     schema listing (relations + functions)
GET    /:table               read rows
POST   /:table               insert (object or array of objects)
PATCH  /:table?filters       update (filters required)
DELETE /:table?filters       delete (filters required)
GET    /rpc/:fn?arg=v        call a function (query-string args)
POST   /rpc/:fn              call a function (JSON body args)
```

### Supported query syntax

- **Vertical filtering** — `select=id,label:name,budget::text,*`
- **Embedding** — `select=name,clients(name,orders(total))` via foreign keys,
  to-one and to-many, arbitrarily nested; disambiguate with
  `clients!constraint_or_column(...)`; alias with `who:clients(...)`
- **Horizontal filtering** — `col=op.value` with `eq neq/ne gt gte lt lte like
  ilike match imatch is in cs cd ov sl sr nxr nxl adj fts plfts phfts wfts`,
  negation via `col=not.op.value`, full text language via `fts(english).query`,
  repeated filters on the same column
- **Logic trees** — `or=(a.eq.1,and(b.gte.2,c.is.null))`, nestable, `not.` prefix
- **Embedded resource params** — `clients.name=eq.acme`, `clients.order=...`,
  `clients.limit=...` scope to the embed
- **Ordering / paging** — `order=col.desc.nullslast,col2`, `limit`, `offset`;
  responses carry `Content-Range`, and `Prefer: count=exact` fills in the total
- **Prefer** — `return=representation|minimal` on mutations (representation
  honors `select=`), `count=exact` on reads
- **Singular responses** — `Accept: application/vnd.pgrst.object+json` returns
  one object and 406s unless exactly one row
- **Schema switching** — `Accept-Profile` / `Content-Profile` headers, validated
  against `PGRST_DB_SCHEMAS`
- **RPC** — scalar, `void`, and set-returning functions; when a function
  returns `setof <table>`, filters/order/select apply to its result
- **Errors** — PostgREST-style JSON `{code, message, details, hint}` with the
  familiar status mapping (409 on FK/unique violations, 404 unknown
  relation/function, 400 parse errors, 401 bad/expired JWT, 406 singular
  cardinality, `PGRST1xx/2xx` codes)

### Not implemented (yet)

OpenAPI root spec, CSV output, `Range` header pagination, upsert
(`Prefer: resolution=`), `!inner` join filtering, many-to-many junction
detection, computed relationships, `columns=`/`on_conflict=` params,
db-pre-request, LISTEN/NOTIFY schema reload (use
`Postgrext.SchemaCache.refresh/0`).

## Architecture

```
lib/postgrext/application.ex      supervision tree (pool + cache + Bandit)
lib/postgrext/config.ex           env → config
lib/postgrext/schema_cache.ex     introspection cache (persistent_term)
lib/postgrext/schema_cache/introspection.ex   pg_catalog queries
lib/postgrext/request/parser.ex   query string → AST
lib/postgrext/query/builder.ex    AST → {sql, params}
lib/postgrext/auth.ex             JWT → role
lib/postgrext/router.ex           Plug.Router dispatch
lib/postgrext/controller.ex       execute + respond
lib/postgrext/error.ex            error mapping
```

## Tests

```sh
mix test                        # unit suites, no database needed
mix test --include integration  # + end-to-end suite against local Postgres
```

The integration suite connects to `PGRST_DB_URI` (default
`postgres://localhost:5432/postgres`), builds a scratch `postgrext_test`
schema, exercises the full router/controller/builder stack, and drops the
schema afterwards.
