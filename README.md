# Postgrext

A rewrite of [PostgREST](https://postgrest.org) in Elixir. Point it at a
PostgreSQL — or SQLite — database and it serves a RESTful API from the schema,
speaking PostgREST's query syntax: tables and views become endpoints,
functions become RPC calls, and foreign keys drive resource embedding.

Everything is executed as parameterized SQL with identifiers validated against
an introspected schema cache; the database itself renders the JSON response
bodies (`json_agg`/`to_json` on Postgres, `json_group_array`/`json_object` on
SQLite), so types serialize correctly.

Backends are pluggable behind the `Postgrext.Adapter` behaviour: an adapter
owns its supervision children, introspection, SQL dialect, and transactions,
and the HTTP layer only sees operation results.

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
| `PGRST_DB_URI` | `postgres://` URI or `sqlite:<path>` / `sqlite::memory:` (required to serve) | — |
| `PGRST_DB_SCHEMAS` | Comma-separated schemas to expose; first is the default | `public` (Postgres) / `main` (SQLite) |
| `PGRST_DB_ANON_ROLE` | Role for unauthenticated requests (`set local role`) | connection role |
| `PGRST_DB_POOL` | Connection pool size | `10` |
| `PGRST_JWT_SECRET` | HS256 secret; enables `Bearer` JWT auth via the `role` claim | auth disabled |
| `PGRST_SERVER_PORT` | HTTP port | `3000` |

On Postgres every request runs in a transaction with `set_config('role', ...)`
and `set_config('request.jwt.claims', ...)` applied, so row-level security and
`current_setting('request.jwt.claims')` work as they do under PostgREST.

### SQLite backend

    PGRST_DB_URI="sqlite:/path/to/app.db" mix run --no-halt

The full query syntax works — filters, logic trees, embedding (both
directions, nested), ordering, paging, counts, singular responses, and all
mutations including `Prefer: return=representation` (implemented by
re-reading the affected rows by rowid inside the transaction). Booleans are
rendered as JSON `true`/`false` despite SQLite's 0/1 storage.

SQLite-specific limitations:

- No RPC — SQLite has no stored functions, so `/rpc/*` 404s.
- No database roles or grants — the JWT `role` claim only selects which RLS
  policies apply.
- Unsupported operators (400): `fts`/`plfts`/`phfts`/`wfts`, `match`/`imatch`,
  and the array/range operators (`cs`, `cd`, `ov`, `sl`, `sr`, `nxr`, `nxl`,
  `adj`).
- `WITHOUT ROWID` tables only support `Prefer: return=minimal` mutations, and
  RLS `WITH CHECK` enforcement (which re-reads by rowid) doesn't work on them.

#### Row-level security on SQLite

SQLite has no native RLS, so policies are modeled as rows in two internal
tables that Postgrext creates in the database on first open (they are never
exposed as API endpoints):

```sql
-- ALTER TABLE <t> ENABLE ROW LEVEL SECURITY
insert into postgrext_rls_enabled (table_name) values ('notes');

-- CREATE POLICY <name> ON <t> [AS kind] [FOR command] [TO roles]
--   [USING (expr)] [WITH CHECK (expr)]
insert into postgrext_policies
  (table_name, name, command, kind, roles, using_expr, check_expr)
values
  ('notes', 'own_notes', 'ALL', 'PERMISSIVE', '["authenticated"]',
   'owner = auth.uid()', null);
```

Columns map 1:1 onto Postgres `CREATE POLICY` clauses, so a SQLite database
upgrades to native Postgres policies mechanically. `command` is
`ALL|SELECT|INSERT|UPDATE|DELETE`, `kind` is `PERMISSIVE|RESTRICTIVE`, and
`roles` is a JSON array of role names (null = all roles, like `TO public`).

`using_expr` / `check_expr` are SQL boolean expressions over the table's
columns. The request auth context is available as `auth.role()` (the request
role), `auth.uid()` (the JWT `sub` claim), and `auth.jwt()` (the claims as
JSON text — combine with `->>`); on SQLite these are bound as parameters, on
Postgres they resolve to the standard Supabase `auth.*` helper functions.

Semantics follow Postgres: with RLS enabled and no applicable policy the
table is inaccessible; permissive policies OR together and restrictive
policies AND on top; `USING` filters reads (including embedded tables,
counts, and representation re-reads), updates, and deletes; `WITH CHECK`
(falling back to `USING`) is enforced on inserted/updated rows inside the
transaction — violations roll back with `403` / code `42501`. Policy changes
take effect after `Postgrext.SchemaCache.refresh/0` (policies load with the
schema cache).

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
lib/postgrext/application.ex      supervision tree (adapter children + cache + Bandit)
lib/postgrext/config.ex           env → config, adapter selection
lib/postgrext/schema_cache.ex     introspection cache (persistent_term)
lib/postgrext/request/parser.ex   query string → adapter-neutral AST
lib/postgrext/request/parser/grammar.ex   NimbleParsec grammars
lib/postgrext/adapter.ex          backend behaviour (the contract)
lib/postgrext/adapters/postgres.ex          Postgrex pool, transactions, roles
lib/postgrext/adapters/postgres/builder.ex  PostgreSQL dialect
lib/postgrext/adapters/postgres/introspection.ex  pg_catalog queries
lib/postgrext/adapters/sqlite.ex            exqlite backend
lib/postgrext/adapters/sqlite/builder.ex    SQLite dialect
lib/postgrext/adapters/sqlite/policies.ex   emulated row-level security
lib/postgrext/adapters/sqlite/introspection.ex    sqlite_master + pragmas
lib/postgrext/auth.ex             JWT → role
lib/postgrext/router.ex           Plug.Router dispatch
lib/postgrext/controller.ex       HTTP ↔ adapter operations
lib/postgrext/error.ex            error mapping
```

## Tests

```sh
mix test                        # unit suites + SQLite end-to-end (in-memory)
mix test --include integration  # + end-to-end suite against local Postgres
```

The SQLite end-to-end suite runs by default on a `:memory:` database — no
external service needed. The Postgres integration suite connects to
`PGRST_DB_URI` (default `postgres://localhost:5432/postgres`), builds a
scratch `postgrext_test` schema, exercises the full stack, and drops the
schema afterwards.
