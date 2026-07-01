# PostgREST rewrite in Elixir ("postgrext")

Goal: a working Elixir implementation of PostgREST's core — an HTTP server that
introspects a Postgres schema and exposes tables/views/functions as a REST API
using PostgREST's query syntax. Target the core feature set first; exotic
features (OpenAPI output, CORS preflight nuances, `Range` header pagination,
media type handlers) come later.

## Scope (v0)

- [x] Mix project (`postgrext`), supervised app: Postgrex pool + Bandit HTTP server
- [x] Config via env vars mirroring PostgREST: `PGRST_DB_URI`, `PGRST_DB_SCHEMAS`,
      `PGRST_DB_ANON_ROLE`, `PGRST_JWT_SECRET`, `PGRST_SERVER_PORT`
- [x] Schema cache GenServer: introspect tables, columns, primary keys, FK
      relationships (for embedding); refreshable
- [x] Query-string parser (PostgREST syntax):
  - [x] `select=` with column lists, aliases (`alias:col`), casts (`col::text`),
        `*`, and embedded resources `select=id,client(id,name)`
  - [x] filters `col=op.value`: eq, neq/ne, gt, gte, lt, lte, like, ilike,
        match, imatch, in, is, cs, cd, ov, fts/plfts/phfts/wfts, and `not.` negation
  - [x] `and=(...)` / `or=(...)` logic trees, incl. nesting and `not.`
  - [x] `order=col.asc/desc.nullsfirst/nullslast`, multiple keys
  - [x] `limit` / `offset`
- [x] SQL builder: parameterized SQL only, all identifiers quoted, filters on
      embedded resources, embedding via `json_agg` lateral joins (to-one via
      `row_to_json`, to-many via `coalesce(json_agg(...), '[]')`)
- [x] HTTP verbs:
  - [x] `GET /table` → JSON array; `Content-Range` header; `Prefer: count=exact`
  - [x] `POST /table` → insert (single object or array); `Prefer: return=representation`
  - [x] `PATCH /table?filters` → update (filters required — no full-table update)
  - [x] `DELETE /table?filters` → delete (filters required)
  - [x] `GET/POST /rpc/fn` → call function with args
  - [x] `Prefer: return=minimal|representation`, single-object response via
        `Accept: application/vnd.pgrst.object+json`
- [x] Auth: optional HS256 JWT (`role` claim → `SET LOCAL ROLE`), anon role
      fallback; every request runs in a transaction with the role applied
- [x] Errors: Postgres errors mapped to PostgREST-style JSON
      (`{code, message, details, hint}`) and status codes (409 for FK/unique,
      404 unknown relation, 400 parse errors, 401 bad JWT)
- [x] Tests: unit suites for parser + SQL builder; integration suite
      (`@moduletag :integration`, excluded by default) against a scratch DB
      with fixture schema exercising CRUD, filters, embedding, RPC, count
- [x] README with setup/config/feature matrix

## Non-goals for v0

OpenAPI/root spec endpoint, CSV output, `Range` headers, resource embedding
depth > 1 hop chains beyond what one lateral level gives, computed
relationships, `!inner` join hints, upsert (`Prefer: resolution=`), db-pre-request,
JWT aud/exp beyond exp check, listen/notify schema reload.

## Layout

    lib/postgrext/application.ex      supervision tree
    lib/postgrext/config.ex           env → config
    lib/postgrext/schema_cache.ex     introspection + cache
    lib/postgrext/request.ex          parsed request struct
    lib/postgrext/request/parser.ex   query string → AST
    lib/postgrext/query/builder.ex    AST → {sql, params}
    lib/postgrext/auth.ex             JWT → role
    lib/postgrext/router.ex           Plug.Router, verb dispatch
    lib/postgrext/controller.ex       execute + respond
    lib/postgrext/error.ex            error mapping

## Status log

- 2026-07-01: plan written; scaffolding started.
- 2026-07-01: all v0 scope items implemented. 101 tests green (76 unit + 25
  integration). Live smoke test: booted server via env vars against local
  Postgres, verified introspection, filtered reads, insert with
  representation, ordering, and count=exact Content-Range over real HTTP.
  README written. Divergence from PostgREST: UPDATE/DELETE without filters is
  rejected (400) instead of allowed.
- 2026-07-01: toolchain pinned via mise.toml to Elixir 1.20.2-otp-29 /
  Erlang 29.0.2 (latest stable). Rebuilt deps from scratch; 101 tests green,
  zero warnings with --warnings-as-errors, format clean. mix.exs keeps
  `~> 1.16` as the supported floor; README updated.
