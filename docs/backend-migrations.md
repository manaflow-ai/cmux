# cmux-next backend migrations

The cmux-next cloud backend (`backend/`) keeps cross-entity data and read projections in
PlanetScale PostgreSQL `cmux-next` (org `cmux`; branches `main` = production, `staging`,
`development`). Durable Objects own entity state; Postgres rows are written only by outbox
drains. The old `web/` backend and its `cmux-prod` database are separate.

Merging a backend PR deploys it, so schema must already be in place: every migration is
applied to staging and then production before the PR merges. PlanetScale Postgres has no
deploy requests or schema branching for Postgres, so the pipeline enforces this instead:

| Stage | What runs | Where |
| --- | --- | --- |
| PR opened or updated | lint (expand rules, phase header), append-only and contract-alone guard, all migrations from zero on a scratch Postgres, apply to `development`, preview Worker | `.github/workflows/backend.yml` jobs `test`, `migrations-guard`, `migrations-development`, `preview` |
| Label `backend:apply-migrations` | apply to `staging`, then production if staging passed | `migrations-apply-staging`, `migrations-apply-production` |
| Every PR event | `backend migrations applied`: fails while staging or production lacks a migration from the PR | merge gate |
| Push to `feat-cmux-next` | verify staging, deploy API Worker and dashboard | `deploy-staging` |
| Push to `main` or dispatch `target=production` | verify production, deploy | `deploy-production` |

Expand migrations only add (tables, nullable or defaulted columns, indexes, backfills), so
the code already deployed keeps working when production gets them before the merge. Contract
migrations (drops, renames, NOT NULL) ship alone in a later PR, after production code no
longer uses what they remove.

How to write one: [skills/cmux-backend-migrations/SKILL.md](../skills/cmux-backend-migrations/SKILL.md).
Runner: `backend/db/migrate.ts` (`--lint`, `--env <env> [--verify]`).
Credentials: GitHub environments `cmux-next-development`, `cmux-next-staging`,
`cmux-next-production` (`CMUX_NEXT_PG_MIGRATOR_URL`); locally `~/.secrets/cmux-next-planetscale-<env>.env`.
