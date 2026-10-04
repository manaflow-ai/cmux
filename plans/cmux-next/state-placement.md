# cmux-next state placement (DO vs PlanetScale MySQL), MySQL migration, new Cloud backend (design, 2026-10-04)

Status: design for review (backend lead). No code until the coordinator and Lawrence accept it.
It replaces the Postgres projection decision and the classic Cloud dependency. Facts used:
Vitess database `cmux-next-vitess` (org cmux, us-west-2, PS-10, branches main/staging/development);
Postgres `cmux-next` stays only until the copy is verified, then is retired with Lawrence's OK;
classic `cmux-prod` is never touched. Identity stays Stack Auth (prod 9790718f, dev 454ecd03).
Usage history goes to ClickHouse. Billing uses the classic Stripe account and products (one
subscription). Freestyle: same account, new keys `cmux-next-dev` and `cmux-next-prod`.

## 1. The rule

A fact lives where its single writer is.

- **Durable Object SQLite** holds state that one entity owns and that must be strongly
  consistent: the single writer (ordering, invariants, quotas checked at write), the idempotency
  ledger, realtime fan-out (sockets, events), revocation, alarms, and provider calls (crash-safe
  ledger rows). Reads by the owner and its members are served here.
- **PlanetScale MySQL** holds facts that are about many entities at once: cross-entity queries
  (all teams of a user, all machines of an org for admin), directory and search, global uniqueness
  that no one entity owns (email address claims, slugs, domains), billing summaries, admin and
  support reporting, and data an operator must query with SQL. MySQL rows are written only by the
  owning DO through the outbox (projection), or by Stripe webhooks for billing. MySQL is never
  the authority for a decision that a DO makes; a DO never reads MySQL inside a commit.
- **ClickHouse** holds append-only usage and audit history at volume (per-run, per-minute VM
  usage, analytics). MySQL keeps only monthly billing summaries.
- **R2** holds blobs (attachments, archived event windows, snapshot exports, migration files).

A projection row carries `(source_stream, source_seq)`; an upsert applies only when it is newer,
so outbox replay is safe and the whole projection can be rebuilt from the DOs.

## 2. Placement per domain

| Domain | DO (authority) | MySQL (projection or authority) | Why |
| --- | --- | --- | --- |
| Users (profile, settings, installs, grants, presence keys) | UserDO | `users` (id, stack_user_id, email_hash, created) ; `installs` (id, user, kind, revoked) | Revocation and grants are decided per request by UserDO (instant revocation). MySQL is for "find user by Stack id / email" and admin. |
| Email/phone address claims | AddressDO (per address) | `address_claims` (unique address hash -> user) | The DO serializes one address; MySQL gives the global unique index for lookup and admin. |
| Teams, members, hosts, policy, SSO, domains | TeamDO (row mode) ; DomainDO | `teams`, `memberships` (team, user, role), `hosts`, `domains` (unique) | Authorization reads member rows in the TeamDO. MySQL answers "teams of a user" for directory UIs and admin; the UserDO `team_index` stays the hot path for reach. |
| Conversations, messages, reads, attachments refs | ConversationDO | `home_conversations`, `home_participants`, `home_invites`, `home_message_search` | Messages need ordering and realtime. Search is cross-conversation, so it is MySQL (section 4.3). |
| Attachments bytes, quota | ConversationDO record + UserDO quota | none (R2 holds bytes) | Quota is a per-user invariant. |
| Inbox, unread | UserDO inbox engine | none | Per-user, realtime. |
| Scheduler (automations, runs) | SchedulerDO (rows, (g)) | `automations`, `automation_runs` (finished history), billing summary per month | Cron/dedupe/token bucket need one writer. Run history beyond the kept 200 is a cross-time query. Per-run usage detail goes to ClickHouse. |
| Connections (OAuth, sealed credentials) | ConnectionDO | `connections` (id, team, provider, account, status; never secrets) | Secrets never leave the DO. |
| Feed | FeedDO | none except daily counts if needed | Per-install stream. |
| Audit | owner DOs (event window) | `audit_events` (append, retention) and ClickHouse for long history | Compliance queries cross entities. |
| Cloud machines, snapshots, quotas | CloudDO (per team, section 5) | `cloud_machines`, `cloud_snapshots` (projection for admin, support, migration reports) | Quota and provider-call ledger need one writer per team. |
| Billing (plan, seats, entitlements) | UserDO/TeamDO cache of the entitlement (written by the billing webhook op) | `billing_customers` (stripe customer <-> team/user, unique), `billing_subscriptions`, `billing_usage_monthly` | Stripe is the source; the webhook writes MySQL (global uniqueness of the Stripe customer) and sends an op to the owner DO, which keeps the entitlement it checks at write. |
| Usage metering | UsageMeterDO (hard cap, token bucket) | `billing_usage_monthly` | Detail rows go to ClickHouse. |
| Idempotency ledgers, outbox, event windows | every OwnerDO | none | Per-entity by definition. |

Rejected alternatives. Member lists only in MySQL: authorization would read MySQL inside a
commit (not consistent, adds a network hop to every op). Search in a DO: cross-conversation
search would fan out to every ConversationDO. Billing only in a DO: the Stripe customer id must
be globally unique and the webhook has no owner context until it is looked up.

## 3. Postgres usage today (inventory)

All relational code in the cmux-next backend is Postgres:

| Place | What | Postgres-specific |
| --- | --- | --- |
| `backend/db/schema/index.ts` (242 lines) | Drizzle `pg-core` schema: users, teams, automations, installs, hosts, automation_runs, connections, home_conversations, home_invites, memberships, home_participants, audit_events | `pgTable`, `timestamp with time zone`, `jsonb`, `text` keys |
| `backend/db/migrations/0001..0006*.sql`, `backend/db/drizzle/0000_baseline.sql` + `meta/` | hand SQL + Drizzle baseline | `pg_trgm`, `btree_gin`, GIN full-text and trigram indexes, `home_message_search` hash-partitioned (8 parts), `timestamptz` |
| `backend/db/migrate.ts` (+ `libpg-query` lint), `db/e2e.ts`, `db/drizzle.config.ts` | migration runner, lint, e2e | `pg`, `libpg-query`, `schema_migrations` table |
| `backend/db/test-pg/projection.test.ts`, `home-search.test.ts` | DB tests against Postgres | Docker Postgres |
| `backend/apps/api/src/projection.ts` (125) | raw SQL upserts/deletes for message search, dead-row replay | `ON CONFLICT ... DO UPDATE ... WHERE source_seq < excluded.source_seq`, `$n` params |
| `backend/apps/api/src/projection-drizzle.ts` (209) | Drizzle upserts for the other tables | `onConflictDoUpdate` with a `where` guard, `PgTable` |
| `backend/apps/api/src/home-search.ts` (135) | `home.search` read (read-only Hyperdrive) | `ILIKE ... ESCAPE`, `to_tsvector`/GIN, row-value keyset `(a,b,c) < ($1::timestamptz,$2,$3)` |
| `backend/apps/api/src/feed-sweep.ts` (89) | user paging | `$1::text IS NULL` |
| `backend/apps/api/src/env.ts`, `wrangler.jsonc` | `HYPERDRIVE`, `HYPERDRIVE_RO` per env (6 Hyperdrive configs to Postgres) | |

Data in Postgres `cmux-next` today (read-only count, 2026-10-04): production only
`schema_migrations`; staging about 40 rows (12 installs, 10 connections, 5 automations, 5 runs,
3 hosts, 1 conversation, 1 invite, 2 participants, 1 team, 1 user, 1 membership); development 7 rows.

## 4. MySQL migration (proper migration, not rewrite-and-hope)

### 4.1 Schema and Drizzle

- Drizzle moves to `drizzle-orm/mysql-core` with the `mysql2` driver (Hyperdrive MySQL). One schema
  file per area under `backend/db/schema/`. Types: ids `varchar(64)` (our ids are `user_<20 hex>`,
  `team_...`), `ascii_bin` collation for ids and hashes (byte comparison, smaller indexes),
  `utf8mb4_0900_ai_ci` for human text; timestamps `datetime(3)` in UTC (MySQL `timestamp` ends in
  2038); JSON columns `json` (only for opaque payloads, never queried by path in a hot path);
  booleans `tinyint(1)`; `bigint` for seq and money (micros).
- Vitess rules: no foreign keys (integrity comes from the single-writer DOs; orphan checks run in
  the verification job); every table has a primary key; no stored procedures, triggers or
  partitioning in SQL (Vitess shards later by keyspace instead: the shard key is `team` for team
  tables and `user` for user tables, so every hot query filters by it); online DDL through
  PlanetScale deploy requests (safe migrations on for main), never ad hoc `ALTER` on main.
- Migration history: a fresh MySQL history. `0000_baseline` = the current schema translated
  table by table (generated by `drizzle-kit generate` from the mysql-core schema, then reviewed by
  hand). Each later change is one Drizzle migration plus a deploy request per branch. The old
  Postgres history is archived under `backend/db/postgres-archive/` until the database is retired.
- Upsert guard: `INSERT ... ON DUPLICATE KEY UPDATE col = IF(VALUES(source_seq) > source_seq,
  VALUES(col), col), ...` with `source_seq` assigned last in the list (MySQL evaluates the
  assignments left to right). One helper builds this so every projection uses the same guard;
  tests cover older, equal and newer seq. Deletes keep the `source_seq <=` guard.

### 4.2 Queries

Every query in section 3 is ported: `$n` -> `?`; row-value keyset becomes
`(created_at < ? OR (created_at = ? AND (conversation_id < ? OR (conversation_id = ? AND seq < ?))))`
with a covering index; `IS NULL` paging as is; `ILIKE` becomes `LIKE` on a `utf8mb4_0900_ai_ci`
column (case- and accent-insensitive).

### 4.3 Search on MySQL

`home_message_search` gets a `FULLTEXT` index with the `ngram` parser (works for CJK, the reason
`pg_trgm` was used), queried `MATCH(body) AGAINST(? IN BOOLEAN MODE)` filtered by the caller's
conversation ids (the Worker passes the ids the user's inbox lists; never a cross-team scan).
Substring fallback for one- and two-character queries: `LIKE` on the recent window only.
Risk: Vitess supports FULLTEXT in an unsharded keyspace; when we shard, search moves to its own
unsharded keyspace or to a search service. Test: the existing home-search test cases (CJK,
punctuation, keyset) must pass on MySQL.

### 4.4 Hyperdrive, harness, CI

- One MySQL Hyperdrive config per environment and per role: `cmux-next-vitess` development,
  staging, main, each with a read-write credential (projection writer) and a read-only credential
  (reads such as home.search). Bindings keep the names `HYPERDRIVE` and `HYPERDRIVE_RO`, switched
  per environment only after verification (4.5). Credentials are created with
  `pscale password create cmux-next-vitess <branch> --org cmux --role writer|reader`, stored in
  `~/.secrets/cmux-next-vitess-<branch>-{rw,ro}.env` (600) and in the Hyperdrive config, never
  printed.
- Local and CI: a `mysql:8.4` container for unit and projection tests (fast, offline) plus one CI
  job against the PlanetScale development branch (catches Vitess-only differences). The test-pg
  suite becomes test-mysql with the same cases.
- Runner: `db/migrate.ts` applies Drizzle migrations to development and staging; main changes go
  through deploy requests only.

### 4.5 Data move and cutover (per environment: development, then staging, then main)

1. Create the schema on the Vitess branch (baseline migration).
2. Rebuild, not copy, as the primary path: every projection row is derived from a DO, so the
   backend replays the projection into MySQL from the DOs (admin op `projection.rebuild {target}`
   that walks owners and re-emits their projection items with the current seq). This proves the
   projection code on MySQL and needs no Postgres-to-MySQL type mapping.
3. Verified copy as the check: an export job reads each Postgres table (read-only) and the MySQL
   table, and compares row counts and a per-row checksum (sha256 of the canonical JSON of the row,
   normalized types). Any difference blocks the switch. Tables that are not rebuildable from DOs
   (none today; audit_events is rebuildable only inside the event window) are copied row by row
   by the same job, then checked.
4. Dual write window: for one day per environment the outbox writes both Postgres and MySQL
   (two projection targets, same guard); a compare job runs every hour and must show 0 differences.
5. Switch `HYPERDRIVE`/`HYPERDRIVE_RO` to MySQL for that environment (one Worker deploy). Reads
   now come from MySQL; Postgres still receives writes for 3 more days.
6. Rollback: switch the bindings back (one deploy); Postgres is current because dual write
   continued. After 3 clean days, stop the Postgres writes.
7. After all three environments are done and verified, ask the coordinator (and Lawrence) once
   more, then delete the Postgres `cmux-next` database and its 6 Hyperdrive configs.

Production holds no projection rows today, so main is the lowest-risk step; staging is the real
rehearsal.

## 5. New Cloud backend (Cloudflare Worker/DO <> Freestyle)

No dependency on `web/`, Vercel, classic Postgres `cloud_vms`, the GCP edge or classic WireGuard.

### 5.1 Objects

- **CloudDO, one per team** (a personal account is a team of one): the machine and snapshot
  registry (rows, row mode), the provider-call ledger, quotas and plan checks, idle policy, and
  the alarm that repairs interrupted provider calls and polls provider state. Teams have few
  machines (plan max_active is 5 to 50), so one writer per team is cheap and makes quota checks
  exact. Provider calls run single-flight per machine (not per team), like TeamVmDO.
- **UserDO**: identity, install revocation, chief/agent refusal for destructive and money ops.
- **TeamDO**: member role and Cloud policy (who may create, max size), read by CloudDO through
  authorize rows (member) or an RPC cached per request.
- **MySQL** `cloud_machines`, `cloud_snapshots`: projection for admin/support/migration reports.

### 5.2 Provider-call ledger (answers contract 1.6)

1. A mutation commits a ledger row first: `{op, key, machine id, provider name, state: pending}`.
   The provider name is deterministic: `<env prefix><machine id>`.
2. CloudDO then calls Freestyle (single flight per machine) and commits the outcome as an internal
   op (`cloud.driver_result`). A crash between the call and the commit is repaired by the alarm:
   it looks the resource up by its deterministic name, so a lost create answer never makes a
   second VM.
3. A call cut off mid-flight (timeout, Worker eviction) answers `mutation.indeterminate`; the
   client retries with the same key; the retry reads the ledger row and resumes or returns the
   stored result. A retry with a different key is a new intent.
4. Deletes are idempotent: a provider 404 on delete is success; the row stays as a tombstone 30
   days so a retry answers `{deleted: true}`.

### 5.3 Names, keys, account isolation

Same Freestyle account as classic, new keys. Env prefixes: `cmuxnp-dev-`, `cmuxnp-stg-`,
`cmuxnp-prod-` (not `cmux-`: classic already uses `cmux-` names on this account, and a prefix
must identify our resources for cleanup). The driver refuses any call on a resource whose name
does not carry its environment prefix, except classic machines imported by migration (allowlist
by provider id, written by the import). Keys: Worker secrets `FREESTYLE_API_KEY` per environment
(`wrangler secret put`), source of truth `~/.secrets/cmux-next-freestyle-{dev,prod}.env`; no client,
VM, app server or log ever sees one. Staging uses the dev key with the `cmuxnp-stg-` prefix unless
Lawrence wants a third key.

### 5.4 Ops

I accept the contract's op set (section 1.3) and names `cloud.machine.*`, `cloud.snapshot.*`,
`cloud.plan.get`, `cloud.billing.checkout`, `cloud.shell.open`, `cloud.migration.*`,
`cloud.machine.upgrade`, owner `cloud:CloudDO`, with these changes:
- Agent principals (claim `agt`) are refused for create, delete, resize up, snapshot delete,
  billing checkout and migration start (backend-enforced, not only the client).
- `cloud.machine.list` pages (`cursor`, `limit<=100`) for large teams; first page is the default.
- Add `cloud.machine.exec {machine, argv, timeout_s}` only for the upgrade path (internal), not
  public in v1.

### 5.5 Credential: install token, not Stack bearer

Yes. The backend already authenticates install tokens on every request with instant revocation
through UserDO. The daemon relay adds the install token; the Stack session token stays in the
browser/app sign-in path only.

### 5.6 Exec / terminal stream relay through the Worker

Feasible. `cloud.shell.open` returns a stream id; the client opens a WebSocket to the Worker; the
Worker authenticates (install token, machine membership via CloudDO) and opens the Freestyle exec
WebSocket with the key, then pipes frames both ways. A plain Worker request (not a DO) does the
relay, so it costs wall time only, not CPU, and needs no DO memory. Limits: one relay per stream,
idle close after 10 minutes, max 4 per machine. Normal terminals use the daemon link; the relay is
for rescue shell and classic machines before upgrade.

### 5.7 Quotas and billing

CloudDO checks the team entitlement (plan, max_active, max_saved, sizes) before any provider call.
The entitlement comes from the billing webhook path (section 2: Stripe -> MySQL billing tables ->
op to the owner), never from the request. VM-hours: CloudDO emits usage events per state change
to UsageMeterDO (hard cap) and ClickHouse (detail); MySQL holds the monthly summary.

### 5.8 VM bind and `cloud.machine.connect_info` (contract 1.7)

1. Create: CloudDO mints the machine id, the overlay host id (`host_...`, stable for the machine's
   life) and epoch 1, and a one-time bind token (32 random bytes; only its sha256 is stored; expires
   15 minutes after the provider reports running). The token goes into the VM at create (Freestyle
   file write), never into a log or the client.
2. Bind: the image's bind agent calls internal op `cloud.machine.bind {machine, bind_token,
   wg_public_key, daemon: {version, capabilities}}` once. CloudDO checks the token hash and expiry,
   spends it, records `host`, `epoch`, `wg_public_key`, `daemon`, and emits `cloud.machine.upsert`
   (revision = stream seq) plus an outbox item to TeamDO's peer map (lane 12). A restore or a re-bind
   raises `epoch` and needs a fresh token; a second bind with a spent token is refused.
3. `connect_info` (read, session or install; `cmux link` through the host credential relay): CloudDO
   checks the caller may reach the machine (team policy), derives `overlay_address` from the host id,
   reads `vpc_endpoint`/`gateway` from TeamDO's peer map (lane 12), and mints a `link_token` (signed,
   single host, single install, the allowed services, this epoch, at most 5 minutes). Not bound
   answers `cloud.machine.not_bound`; paused answers the record with `state: paused`.
4. Revocation: install revocation through UserDO closes links (the token is checked at hello and
   bound to one install); a machine delete emits `cloud.machine.removed` and drops the peer entry.

## 6. Classic Cloud migration

Inputs: classic users and VMs live in classic Postgres `cmux-prod` (`cloud_vms`) and on the same
Freestyle account. Rule: no live connection from cmux-next to classic; a one-time read-only export
per wave.

1. Wave export (operator, read-only): for the users in the wave, export
   `{stack_user_id, billing_team_id, provider_vm_id, slug, display_name, size, status, created_at,
   snapshots}` as JSONL, encrypted, to a private R2 bucket `cmux-next-migration` (dev/staging/prod
   prefixes). Who runs it and with which read credential is Lawrence's call (the coordinator is
   asking). The export never contains secrets.
2. Import (backend admin op `cloud.migration.import {object}`, admin key only): for each user,
   map the Stack user id to the cmux-next user and personal team (same Stack project, so ids map
   1:1), write classic machines into that team's CloudDO as `classic: true` with the provider id
   allowlisted, and record the wave in MySQL `cloud_migrations`.
3. User move (`cloud.migration.start`): one way per user. The classic side gets the fence: a small
   classic main PR adds a read-only `moved_to_next` flag that makes classic show those machines
   as moved and refuse mutations; merged only with Lawrence's verdict. Until the fence is live for
   a user, the new backend shows imported machines read-only.
4. Upgrade (`cloud.machine.upgrade`): CloudDO installs the cmux-next daemon through Freestyle exec,
   binds it to the overlay and drops the classic badge; failure leaves a working classic machine.
5. Billing: same Stripe customer and subscription; the import links the existing Stripe customer
   to the team in `billing_customers`.
6. Verification per wave: counts of exported vs imported machines per user, a provider lookup of
   every imported id, and a report in MySQL. Rollback before the fence: delete the imported rows
   (no provider change). After the fence, rollback is a classic flag flip.

## 7. Order of work and target dates (updated 2026-10-04)

1. MySQL step 1 (done 2026-10-04, 019d7ff4d24) and step 2a (done 2026-10-04, e94afacf348): development
   Hyperdrive configs, copy and verify job, live dual write on development (verified: 13 tables equal).
2. MySQL step 2b: staging schema, staging Hyperdrive configs, one-time copy, dual write with hourly
   compare, target 2026-10-06; main schema by deploy request (id reported first, coordinator's go),
   target 2026-10-08; read switch per environment after 3 clean days.
3. CloudDO skeleton: ledger, Freestyle driver (port of TeamVmDO's), create/get/list/delete, quotas,
   per-environment keys and prefixes (cmuxnp-dev-, cmuxnp-stg-, cmuxnp-prod-), target 2026-10-08.
4. VM bind and `connect_info` (5.8), snapshots, start/pause/resize, events, MySQL projection, target
   2026-10-10; staging deploy for the Cloud v2 client, target 2026-10-12.
5. Shell relay, classic migration import, upgrade: after 2026-10-12.
6. (g) continues in parallel; g2 history goes to MySQL `automation_runs`.

## 8. Open decisions

- D1: staging Freestyle key: reuse cmux-next-dev with prefix `cmuxnp-stg-`, or a third key.
- D2: production prefix `cmuxnp-prod-` instead of the contract's `cmux-` (recommended, classic
  uses `cmux-`).
- D3: who runs the classic wave export and with which read-only credential.
- D4: search on MySQL FULLTEXT ngram now, accepting the unsharded-keyspace limit.
