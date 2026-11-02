# cmux-next off Postgres: Vitess migration and separate Cloud VMs

Status: in progress (2026-10-28). Owner: Cloud / cmux-next backend.
Builds on `state-placement.md` (sections 4 and 5) and `db-migrations-DESIGN.md`. Replaces nothing.

## 1. Decision

cmux-next uses no Postgres. Its relational data lives in PlanetScale Vitess `cmux-next-vitess`
(org `cmux`, branches `main`, `staging`, `development`).

- **Classic and cmux-next are separate.** Classic keeps Postgres `cmux-prod` and its code as it
  is. No dual write goes into classic code.
- **A Cloud VM belongs to one product.** New cmux-next VMs are records in the cmux-next Worker's
  CloudDO (Durable Object SQLite, the authority) with a projection in Vitess. A classic VM stays a
  classic `cloud_vms` row in `cmux-prod`.
- **Existing cmux-next rows in Postgres `cmux-next` move once**: copy, verify (counts and per-row
  sha256), shadow reads, cutover, then remove the Postgres code paths. Production Postgres is read
  only for this work, and no Postgres data is deleted.

Why not dual write in classic: classic is the product that pays the bills today. A second write
path in its VM code doubles the failure modes of every pause, resume and create, and it couples the
two products' schemas forever. Separate records keep a failure in one product out of the other.

## 2. Inventory: every cmux-next Postgres use

### 2.1 Postgres `cmux-next` (the cmux-next API Worker, `backend/`)

| Place | Use | State 2026-10-28 |
| --- | --- | --- |
| `backend/db/schema/index.ts`, `migrations/0001..0007`, `drizzle/` | 13 projection tables: users, teams, installs, memberships, hosts, automations, automation_runs, connections, audit_events, home_conversations, home_participants, home_invites, home_message_search (hash-partitioned, 64 parts) | MySQL twin in `schema-mysql/`, `drizzle-mysql/0000_baseline` + `0001_credits` |
| `apps/api/src/projection.ts`, `projection-drizzle.ts` | outbox drain: guarded upserts and deletes | `projection-targets.ts`: `PROJECTION_PRIMARY` (postgres), `PROJECTION_SHADOW` (mysql on development and staging) |
| `apps/api/src/home-search.ts` | `home.search` (ILIKE + pg_trgm) | MySQL twin `home-search-mysql.ts`; `PROJECTION_READS` |
| `apps/api/src/feed-sweep.ts` | user id pages for the feed sweep cron | MySQL twin `listUsersMysql`; `PROJECTION_READS` |
| `apps/api/src/projection-compare-cron.ts` | the */15 compare Postgres vs MySQL | report only until 2b1fdf14509; now repairs (section 4) |
| `apps/api/wrangler.jsonc` | `HYPERDRIVE`, `HYPERDRIVE_RO` (Postgres) per env; `PS_MYSQL`, `PS_MYSQL_RO` on development and staging only | production has no MySQL binding |
| `db/migrate.ts`, `db/e2e.ts`, `db/test-pg/`, CI steps in `.github/workflows/backend.yml`, `backend-migrations.yml`, `scripts/cmux-next/release/` | runner, lint, tests, release rails | stay until the contract step (section 6) |
| Triggers, crons in Postgres | none (no Postgres triggers or pg_cron in `cmux-next`) | |

Row counts (read-only, 2026-10-28): production about 45,000 rows (teams 12,759, memberships
12,661, audit_events 16,839, home_message_search about 3,950, the rest under 100 each); staging
22,662; development 8,485. Vitess `main` has no tables yet; `staging` and `development` have the
schema.

### 2.2 Classic Postgres `cmux-prod` used by cmux-next (through `web/`, cmux.com)

| Place | Use by cmux-next |
| --- | --- |
| `Packages/macOS/CmuxNext/Sources/CmuxNextCloud/API/CloudAPIClient.swift` (26 files use `/api/vm`) | the app's default Cloud path (`CloudConfiguration.linkSource = .legacy`): list, create, pause, resume, snapshot, fork, exec on `web/app/api/vm`, which reads and writes `cloud_vms`, `cloud_vm_runtime_intervals` and the other `cloud_*` tables |
| `web/db` trigger `cmux_vm_runtime` (migration `20260912080000_go_runtime_limits`) | opens and closes `cloud_vm_runtime_intervals` rows on `cloud_vms.status` changes |
| `web/services/vms/metering/*` (a761, 1e38b841c95..3622b239fee, flag `CMUX_VM_METERING_CLICKHOUSE` off) | copies those intervals into ClickHouse `vm_runtime_events` every 5 minutes |
| `#26078` (open) "Run New Workspaces in Cloud" | adds more `/api/vm` creates from cmux-next |

The `.appServer` link source (`CMUX_NEXT_CLOUD_LINK=app`, debug only) already uses the cmux-next
Worker's CloudDO instead. CloudDO stores machines in DO SQLite and touches no Postgres.

There is no column in `cloud_vms` that says which app made a VM. So existing VMs are not split
by product now: they stay classic. Moving a user's classic VMs is the wave import of
`state-placement.md` section 6, and it needs a classic fence, which is a classic code change and
is out of scope here.

## 3. Target

| Fact | Authority | Vitess |
| --- | --- | --- |
| the 13 projection tables | owner DOs | same tables (`schema-mysql/`) |
| cmux-next VMs, snapshots | CloudDO | `cloud_machines`, `cloud_snapshots` (projection) |
| VM run intervals (metering) | CloudDO, written in code at each status change (Vitess has no triggers) | `cloud_vm_runtime_intervals` (projection, `(source_stream, source_seq)` guard); ClickHouse `vm_runtime_events` gets the same rows |
| credits | UsageMeterDO | `credit_ledger`, `credit_balance` (already MySQL only) |

## 4. Slices and order

Each slice is test-first (red commit, then green) and lands on `feat-cmux-next`.

1. **Repair the shadow** (done, 691e221fd96 red, 2b1fdf14509 green). The shadow write is best
   effort. Staging had lost 2 `home_participants` rows and development 2 `home_message_search`
   rows on 2026-10-16, and nothing repaired them. The compare cron now copies the rows of a lasting
   difference that are missing or changed in MySQL from Postgres, through the same seq guard
   (`guardedUpsertMysql`, shared with `copy-pg-to-mysql.ts`). Rows that only MySQL has are
   reported, never deleted. A one-time `copy-pg-to-mysql.ts` run on development and staging
   (MySQL writes only) made all 13 tables equal on both.
2. **Shadow reads** (done, red then green). `PROJECTION_READS=shadow` serves Postgres and runs the
   same read on MySQL, logging `projection.read.match` or `projection.read.diff` (ids and seqs
   only). On for development and staging.
   **Development cutover** (2026-11-02, ahead of staging; development data is throwaway):
   `PROJECTION_PRIMARY=mysql`, `PROJECTION_SHADOW=postgres`, `PROJECTION_READS=mysql`. The compare
   cron stays on and reports only (repairs flow primary to shadow, so none run while MySQL is
   primary). Rollback: flip the three variables back, one deploy.
3. **Staging cutover**, after 24 h of shadow reads with 0 `projection.read.diff` and 0 lasting
   `projection.compare.diff`: `PROJECTION_READS=mysql`, then `PROJECTION_PRIMARY=mysql` with
   `PROJECTION_SHADOW=postgres` (Postgres stays current for rollback; repairs then flow MySQL to
   Postgres, a later slice). Rollback: flip the variables back, one deploy.
4. **Production expand**: the `release-<sha12>` deploy request of `db-migrations-DESIGN.md`
   section 5 creates the schema on Vitess `main` (empty today), with `CMUX_NEXT_PRODUCTION_HOLD`
   set. Then production `PS_MYSQL`/`PS_MYSQL_RO` Hyperdrive configs (reader/writer passwords on
   `main`), `PROJECTION_SHADOW=mysql`, a one-time copy and verify, then the same shadow-read soak
   as staging.
5. **Production cutover**: as step 3, only after staging has run on MySQL for 3 clean days.
6. **Contract**: after 3 clean days on MySQL in production, remove `projection.ts` Postgres paths,
   `home-search.ts` Postgres query, `HYPERDRIVE`/`HYPERDRIVE_RO`, `db/migrate.ts`, `test-pg/`, the
   Postgres CI steps and `pg`. The Postgres `cmux-next` database is kept (read only) until Lawrence
   approves its deletion.
7. **Cloud VMs separate**: make `.appServer` (CloudDO) the cmux-next app's default Cloud path once
   CloudDO is open to all teams on staging; `/api/vm` stays only for showing classic machines.
   `#26078` should create through CloudDO, not `/api/vm`.
8. **Metering on Vitess**: CloudDO writes a `cloud.vm_interval.upsert` outbox item at each status
   change (open on `provisioning`/`running`, close on any other status, the same rule as the classic
   trigger), projected into Vitess `cloud_vm_runtime_intervals` (expand migration, new table) and
   sent to the same ClickHouse `vm_runtime_events` table with a `product = 'next'` source. a761's
   classic job keeps reading classic Postgres for classic VMs.

Slices 8 and every other `drizzle-mysql/` change wait for the GitHub environment secret
`CMUX_NEXT_VITESS_STAGING_ADMIN_URL`: without it, CI refuses the staging deploy for a push that
changes `drizzle-mysql/` (`db-migrations-DESIGN.md` section 4).

## 5. Rules for new cmux-next features

New cmux-next tables go in `backend/db/schema-mysql/` and `drizzle-mysql/` only (Vitess rules: a
primary key on every table, no foreign keys, no triggers). Nothing new goes into
`backend/db/schema/` (Postgres) or into classic `web/db`. Cloud environments and Cloud GitHub
auth build on CloudDO plus Vitess.

## 6. Checks

- `bun copy-pg-to-mysql.ts --branch <b> --verify-only`: full per-row compare (not bounded).
- Worker logs: `projection.read.match|diff|shadow_failed`, `projection.compare.ok|diff|repaired|repair_failed`.
- Tests: `backend/db/test-mysql/compare-cron.test.ts`, `shadow-reads.test.ts`,
  `backend/apps/api/test/projection-reads.test.ts`.

Known limit: the */15 cron compares at most 5,000 rows per table, so on large tables
(production teams, memberships, audit_events) it checks counts plus the first 5,000 keys. The
full `--verify-only` run is the cutover gate.
