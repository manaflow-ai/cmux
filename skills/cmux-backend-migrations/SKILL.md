---
name: cmux-backend-migrations
description: "Write, test and ship PlanetScale `cmux-next` migrations for the cmux-next cloud backend (`backend/`). Use when adding or changing a table, column, index or projection in backend/db, or when a backend PR is blocked by the `backend migrations applied` check."
---

# cmux-next backend migrations

Database: PlanetScale PostgreSQL `cmux-next`, org `cmux` (branches `main` = production,
`staging`, `development`). Never `cmux-prod`: that is the old `web/` backend and has its
own rules in `cmux-backend`. PlanetScale Postgres has no deploy requests, so safety comes
from the rules below and from `.github/workflows/backend.yml`. Background:
[docs/backend-migrations.md](../../docs/backend-migrations.md).

## The rule

Merging deploys. A migration reaches staging and production **before** its PR merges.
Every deploy refuses to run while its environment lacks a migration in `backend/db/migrations`.

## Write

1. Add `backend/db/migrations/NNNN_lower_snake.sql` with a number above the base branch's
   highest. Never edit, rename or delete a file that exists on the base (CI refuses it; the
   runner refuses a changed checksum). If another PR applied a migration first, merge the
   base and renumber yours (the runner refuses a database with migrations your tree lacks).
2. First line: `-- phase: expand` or `-- phase: contract`. No `BEGIN`/`COMMIT`; the runner
   wraps each file in one transaction.
3. **Expand** (default): only changes the currently deployed code survives. The lint parses
   the SQL (libpg_query) and allows only: `CREATE TABLE`; `CREATE INDEX` (unique only on a
   table created in the same file); `ALTER TABLE ... ADD COLUMN` that is nullable or has a
   `DEFAULT` (no inline constraints); `ADD CONSTRAINT ... CHECK|FOREIGN KEY ... NOT VALID`;
   any `ALTER` of a table created in the same file; `UPDATE`/`INSERT` backfills; `COMMENT`;
   `GRANT`. Everything else (drops, renames, type changes, `SET NOT NULL`, `DO` blocks,
   functions, `DELETE`, `TRUNCATE`) is contract.
4. **Contract** (drop, rename, tighten): a separate later PR **into `main`** (production runs
   `main`) that changes **only** migration files, merged after the code that stopped using
   the old shape is deployed to production. A rename is: expand (add new), code writes both
   and reads new, contract (drop old).
5. Projection rows are written only by outbox drains (`backend/apps/api/src/projection.ts`)
   and carry `source_stream` + `source_seq`; keep both on new projection tables and guard
   upserts with `WHERE <table>.source_seq < excluded.source_seq`.
6. Durable Object SQLite schema is not here: DO tables migrate on wake inside the object
   (`own_meta.schema_version`), DO classes through `migrations` in `apps/api/wrangler.jsonc`.

## Test locally

```bash
cd backend/db
bun migrate.ts --lint && bun test test
docker run -d --rm -p 55432:5432 -e POSTGRES_PASSWORD=pg --name cmux-next-scratch postgres:17
SCRATCH_URL=postgres://postgres:pg@localhost:55432/postgres bun migrate.ts --url-env SCRATCH_URL
docker stop cmux-next-scratch
```

Also run `bun run test` in `backend/apps/api` when the drain or a read changes.

## Ship (no human step)

1. Open the PR (same-repo branch; fork PRs cannot reach the databases). `backend.yml` runs
   the tests, every migration from zero on a scratch Postgres, applies to `development` and
   deploys the preview Worker. `backend-migrations.yml` (`pull_request_target`; GitHub runs it
   from `main`, uses the PR base branch's `migrate.ts`, and reads only your SQL as flat regular
   files) runs the guard and the parsed-SQL lint. Edits to that workflow take effect only once
   they reach `main`.
2. Review the migration with a review subagent (correctness: expand rules, locks on large
   tables, idempotent backfill).
3. Add the label `backend:apply-migrations` (no human step). Adding it starts the apply, which
   first removes the label, then applies to `staging`, then to production (`main` branch of
   `cmux-next`) only if staging succeeded. A later push never applies by itself: add the label
   again. Only PRs into `main` or `feat-cmux-next` from this repository can apply.
4. Wait for the required check `backend migrations applied`, then merge. It passes at once for
   PRs without migration changes; otherwise the tree's migrations must equal what staging and
   production have. A push to `feat-cmux-next` deploys staging; a push to `main` (or
   `workflow_dispatch` target production on `main`) deploys production. Deploys verify first.
5. A failed apply blocks the merge. Fix forward with a **new** migration; never edit the
   applied one, never apply by hand outside the runner. An applied migration whose PR is
   abandoned blocks every later migration PR: land it, or have an operator remove its row.

## Direct pushes to feat-cmux-next

Agents push straight to `feat-cmux-next`, and nothing blocks a push. A migration must still
travel through a PR, and three checks catch a mistake:
- `python3 scripts/verify-local.py` (check `backend-migrations`) fails when your outgoing
  commits add or change files under `backend/db/migrations` without an open PR into
  `feat-cmux-next` or `main`. Set `CMUX_BACKEND_MIGRATION_PR=1` only on the PR branch itself
  before its PR exists.
- After a push, the `migrations-push-guard` job turns red when a shared migration changed, a
  number is not above the previous head, a contract migration landed on `feat-cmux-next`, or
  the lint fails.
- The staging deploy refuses (step "Staging schema matches this commit", with an annotation
  and summary naming the commit) while staging lacks a migration of the pushed tree or has
  one the tree lacks. Fix forward: open the PR with the migration and label it, or revert.

## Manual commands (operators, emergencies)

```bash
cd backend/db
bun migrate.ts --env staging --verify            # read-only check
bun migrate.ts --env staging                     # apply (creds: ~/.secrets/cmux-next-planetscale-staging.env)
bun migrate.ts --env production --confirm-production
```

The runner refuses credentials for any other PlanetScale branch (it checks the branch id in
the role name), so a `cmux-prod` URL cannot be used by mistake. Secrets: GitHub environments
`cmux-next-staging` and `cmux-next-production` (deployment branches: `main` and
`feat-cmux-next` only; merge-queue runs get no secrets) hold `CMUX_NEXT_PG_MIGRATOR_URL` and `JWT_PRIVATE_JWK`;
`cmux-next-production` also holds `CMUX_NEXT_STAGING_MIGRATOR_URL` for the gate.
