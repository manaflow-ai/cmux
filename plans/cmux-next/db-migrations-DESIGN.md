# Zero-downtime database migrations: staging and production

Status: design, with the first guardrails in place (2026-10-20). Owner: cmux-next backend.
Scope: the cmux-next Cloud API databases on PlanetScale (org `cmux`).

- Vitess `cmux-next-vitess`: the target primary (`state-placement.md` 4.4-4.5). Migrations in
  `backend/db/drizzle-mysql/`, runner `backend/db/migrate-mysql.ts`, rules
  `backend/db/vitess-guard.ts`.
- Postgres `cmux-next`: the primary today. Migrations in `backend/db/migrations/`, runner
  `backend/db/migrate.ts`, release rails `scripts/cmux-next/release/` (`release-rails.md`). This
  design does not change them; it uses the same rules for Vitess.

## 1. Goal and rules

Goal: no schema change ever stops or breaks the serving Worker. Production does not go down for a
migration, and a bad migration can be undone without data loss.

The rules:

1. **Backward-compatible only.** At each step, the code that runs now and the code that runs next
   both work with the schema. A change that breaks the running code is never one step.
2. **Expand, then code, then contract.** Additions (expand) deploy before the code that uses them.
   Removals (contract) deploy only after no deployed code uses the old shape. Backfill is its own
   step. Each step is a separate deploy.
3. **Staging first.** Every migration runs on staging, with the exact file, before production gets
   a deploy request. Production gets only what staging ran.
4. **Production schema changes only by deploy request.** No person, agent or CI job runs DDL on
   production `main` directly. PlanetScale safe migrations enforce this (on for
   `cmux-next-vitess/main` now).
5. **Revert window.** Each production deploy request keeps PlanetScale's revert open until the
   checks after the deploy pass.
6. **The hold switch stops code, not only schema.** `CMUX_NEXT_PRODUCTION_HOLD` holds the Worker
   promotion while a schema step is in flight.

## 2. Branches (environments)

| Branch | Role | Who changes the schema | Dev-branch hours |
|---|---|---|---|
| `main` | production. Safe migrations ON. | only deploy requests | none (production) |
| `staging` | production rehearsal: the staging Worker (`cmux-api-staging`), dogfood data | CI (`deploy-staging`), from `drizzle-mysql/` | 744 h/month |
| `development` | dev Worker, previews, the CI `vitess-development` job, test-only keys | operator or agent: `migrate-mysql.ts --branch development` | 744 h/month |
| `release-<sha12>` | short-lived: source of one production deploy request | `migrate-mysql.ts` onto a fresh branch of `main` | about 1-2 h each, deleted after the deploy |

The included 1,488 h/month cover `staging` plus `development` exactly. Delete each release branch
on the day of its deploy (`--auto-delete-branch`). No other long-lived branch. (`mysql-baseline`
was deleted 2026-10-20; its schema dump is in
`gs://cmux-489202-db-archive/planetscale/20261020/cmux-next-vitess-mysql-baseline/`.)

## 3. Expand / contract

Each file in `drizzle-mysql/` starts with a phase header:

```sql
-- phase: expand
ALTER TABLE `installs` ADD COLUMN `platform` varchar(16);
```

```sql
-- phase: contract
-- contract: the Worker stopped reading installs.legacy_os in a1b2c3d4e5f6 (deployed 2026-11-02)
ALTER TABLE `installs` DROP COLUMN `legacy_os`;
```

| Class | Allowed shapes | Where |
|---|---|---|
| expand | `CREATE TABLE` with a primary key; `CREATE INDEX` / `ADD INDEX` / `ADD FULLTEXT INDEX` (not unique); `CREATE UNIQUE INDEX` only on a table created in the same file; `ADD COLUMN` that is nullable, or `NOT NULL` with a `DEFAULT`. Any change to a table the same file created. | `-- phase: expand` file |
| contract | `DROP COLUMN`, `DROP INDEX`, `MODIFY`, `CHANGE` (same name), `ALTER COLUMN ... DEFAULT`, `RENAME INDEX`, a `UNIQUE` key on an existing table, `ADD COLUMN` with `NOT NULL` but no default, `UNIQUE`, `AUTO_INCREMENT` or a generated expression | `-- phase: contract` file with `-- contract: <reason>` (10+ characters: what stopped using it, in which deploy) |
| never | `DROP TABLE`, `DROP DATABASE`, `TRUNCATE`, `RENAME TABLE`, a column rename (`RENAME COLUMN`, `CHANGE a b`), `DROP PRIMARY KEY`, foreign keys, `CHECK`, partitions, views, triggers, routines, events, any data change (`INSERT`, `UPDATE`, `DELETE`, `REPLACE`), executable comments (`/*! */`), any unknown statement | refused in every file |

Why data changes are never in a migration: a deploy request carries schema only, so a data change
in a migration runs on staging and never on production. Backfill is a script (like
`copy-pg-to-mysql.ts`): batched, idempotent, keyed by primary key, re-runnable, with a verify
mode.

A rename or type change is a sequence of separate deploys:

1. **Expand** (deploy 1): add the new column (nullable) or new table. Deploy request to production.
2. **Dual write** (deploy 2): the Worker writes both old and new, and reads old.
3. **Backfill** (deploy 3, a script run): fill the new column for old rows; verify (counts and
   per-row compare, as `projection-compare.ts` does).
4. **Switch reads** (deploy 4): the Worker reads new and still writes both. Soak at least one full
   staging promotion cycle.
5. **Stop the old writes** (deploy 5): the Worker no longer reads or writes old.
6. **Contract** (deploy 6): drop the old column, in a contract file whose reason names deploy 5.

Expand and contract files may not land in the same push: the CI history check refuses it, so a
contract always lands after the code that stopped using the old shape is deployed.

## 4. Staging first

On every push to `feat-cmux-next`, CI job `deploy-staging` in `.github/workflows/backend.yml`:

1. `migrate-mysql.ts --url-env VITESS_STAGING_URL --phase expand`: applies the pending expand
   files, and stops before the first contract file. The old Worker survives these.
2. Deploys and smokes the staging Worker (automatic rollback on red).
3. `migrate-mysql.ts --phase all`, then `--verify`: applies the contract files after the new code
   serves, then checks that the staging history equals the tree.

Without the secret `CMUX_NEXT_VITESS_STAGING_ADMIN_URL` (environment `cmux-next-staging`), step 1
refuses the deploy when the push changes `drizzle-mysql/`, and passes with a notice otherwise.

The Postgres side already does the same through the label flow (`backend-migrations.yml`,
`db-release.ts apply`: production needs staging to hold every pending file with the same
checksum).

## 5. Production: deploy requests

From the commit staging runs (staging-proven, the same commit `prod-promote.ts` G1 picks):

```bash
# 0. Hold Worker promotions while the schema moves.
gh variable set CMUX_NEXT_PRODUCTION_HOLD --repo manaflow-ai/cmux --body "schema: release-<sha12>"
# 1. Release branch from production, with the tree's migrations.
pscale branch create cmux-next-vitess release-<sha12> --from main --org cmux --wait
#    (2 h admin password for the branch into RELEASE_URL; never print it)
bun backend/db/migrate-mysql.ts --url-env RELEASE_URL
# 2. Staging-first gate: staging ran every file with the same checksum,
#    and the release branch schema equals staging's.
bun backend/db/migrate-mysql.ts --gate-release --staging-url-env STAGING_URL --release-url-env RELEASE_URL
# 3. Deploy request, gated (no automatic swap), branch deleted after.
pscale deploy-request create cmux-next-vitess release-<sha12> --into main --org cmux \
  --disable-auto-apply --auto-delete-branch --notes "<sha> <files>"
pscale deploy-request diff cmux-next-vitess <n> --org cmux      # review: only the expected DDL
pscale deploy-request deploy cmux-next-vitess <n> --org cmux
pscale deploy-request apply cmux-next-vitess <n> --org cmux     # swap when ready, at a quiet time
```

PlanetScale runs each change as an online schema change (a shadow table, copied in the background,
then a short cut-over), so tables stay readable and writable. Only one deploy request runs at a time
per database (the deploy queue).

The deploy request may contain only expand changes, or only contract changes, never both (the same
rule as the files). A contract deploy request opens only after the Worker that stopped using the old
shape serves production (check the source tag with `prod-promote.ts`).

## 6. Revert window

After the swap, PlanetScale keeps the old table and replicates writes back to it, so
`pscale deploy-request revert` undoes the schema change without data loss. The window is short
(about 30 minutes; check the deploy request page). Within it:

1. Smoke production (the `release-smoke.json` routes, `projection.shadow.failed` and
   `projection.compare.*` zero, Worker error rate and p99 against the hour before).
2. If any check is red: `pscale deploy-request revert cmux-next-vitess <n> --org cmux`, then fix
   forward.
3. If all are green: `pscale deploy-request skip-revert` closes the window. Only then clear the
   hold, so the Worker that needs the schema can promote.

## 7. The hold switch (`CMUX_NEXT_PRODUCTION_HOLD`)

`prod-promote.ts` (G6) holds every automatic promotion unless the variable is `released`, and
an exact-SHA promote only when it is `released:<40 hex>`.

- Before a production deploy request: set a hold value (`schema: release-<sha12>`).
- After the revert window closes green: an expand deploy request releases the code that needs it
  (`released:<sha>` for that exact commit, or `released`).
- A contract deploy request runs only while production already serves code that does not use the
  old shape, so it needs no code promotion: restore the previous value.
- After an automatic Worker rollback, keep the hold (the existing rule): a schema reverted under a
  newer Worker is not allowed.

Next gate to add (once production binds `PS_MYSQL`): `deploy-worker.sh production` runs a
read-only check that production `main` has every expand change of the candidate commit (the same
`schemaSnapshot` comparison against the release schema), so code never promotes ahead of its
schema. This needs a production reader credential in `cmux-next-production`.

## 8. CI checks (in place 2026-10-20)

| Check | Where | What it refuses |
|---|---|---|
| Vitess migration lint | `backend.yml` `test`: `migrate-mysql.ts --lint` and `bun test test` (`test/vitess-guard.test.ts`) | missing phase header; a contract change in an expand file; a contract file without a reason, or with an expand change; every "never" shape |
| History | `backend.yml` `migrations-push-guard`: `migrate-mysql.ts --lint --base <before>` | an edited or removed landed file, a number not above the previous head, expand and contract in one push |
| Staging first | `backend.yml` `deploy-staging` | a drizzle-mysql change that did not reach staging; staging history not equal to the tree after the deploy |
| Release gate | `migrate-mysql.ts --gate-release` (operator or agent, before each production deploy request) | a file staging did not run or ran with another checksum; staging history the tree lacks; a release-branch schema that differs from staging |
| Schema check on a real MySQL | `test-mysql/schema-gate.test.ts` (CI mysql:8.4 service) | a `schemaSnapshot` that misses tables or reads `schema_migrations` |
| Postgres (existing) | `migrate.ts --lint`, `release/lint.ts`, `backend-migrations.yml`, `db-release.ts` | see `release-rails.md` |

Settings to keep on PlanetScale: safe migrations ON for `main` (it is). Recommended: require an
approval on deploy requests (database settings), so a second reviewer (person or review agent)
approves each production schema change.

## 9. Open items

- The secret `CMUX_NEXT_VITESS_STAGING_ADMIN_URL` (environment `cmux-next-staging`) is not set
  yet. Until it is, a drizzle-mysql push fails `deploy-staging` and the operator applies by hand:
  `bun migrate-mysql.ts --branch staging --phase expand`.
- `development` gets Vitess migrations by hand (`--branch development`). The CI secret
  `CMUX_NEXT_VITESS_DEV_URL` has test-only rights, not DDL rights.
- A `vitess-release.ts` wrapper for section 5 (create branch, 2 h password, apply, gate, deploy
  request, delete password) would remove the hand steps. Build it before the first production
  Vitess deploy request.
- Production `main` has no tables yet; the first deploy request carries `0000_baseline` and
  `0001_credits` (`skills/infra/planetscale-branches/cmux-next-vitess-migration.md` step 2).
