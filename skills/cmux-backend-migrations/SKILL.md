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

1. Add `backend/db/migrations/NNNN_lower_snake.sql` with the next number. Never edit or
   rename a file that exists on the base branch (CI refuses it; the runner refuses a changed
   checksum).
2. First line: `-- phase: expand` or `-- phase: contract`. No `BEGIN`/`COMMIT`; the runner
   wraps each file in one transaction.
3. **Expand** (default): only changes the currently deployed code survives. Allowed: create
   table, add nullable column, add column with a `DEFAULT`, create index, add a check marked
   `NOT VALID`, backfill with `UPDATE`. Refused by `bun migrate.ts --lint`: `DROP`, `RENAME`,
   `ALTER COLUMN ... TYPE`, `SET NOT NULL`, `TRUNCATE`, `DELETE FROM`, `ADD COLUMN ... NOT NULL`
   without a default.
4. **Contract** (drop, rename, tighten): a separate later PR that changes **only** migration
   files, merged after the code that stopped using the old shape is deployed to production.
   A rename is: expand (add new), code writes both and reads new, contract (drop old).
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

1. Open the PR. CI runs lint, the immutability/contract guard, every migration from zero on a
   scratch Postgres, applies to `development`, and deploys the preview Worker.
2. Review the migration with a review subagent (correctness: expand rules, locks on large
   tables, idempotent backfill).
3. Add the label `backend:apply-migrations`. CI applies to `staging`, then to production
   (`main`) only if staging succeeded.
4. Wait for the check `backend migrations applied` to pass, then merge. A push to
   `feat-cmux-next` deploys staging; a push to `main` (or `workflow_dispatch` target
   production) deploys production. Both verify migrations first.
5. A failed apply blocks the merge. Fix forward with a **new** migration; never edit the
   applied one, never apply by hand outside the runner.

## Manual commands (operators, emergencies)

```bash
cd backend/db
bun migrate.ts --env staging --verify            # read-only check
bun migrate.ts --env staging                     # apply (creds: ~/.secrets/cmux-next-planetscale-staging.env)
bun migrate.ts --env production --confirm-production
```

Confirm the target before applying: `pscale branch list cmux-next --org cmux`.
