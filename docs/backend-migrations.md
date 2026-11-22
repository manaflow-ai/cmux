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
| PR opened or updated | tests, all migrations from zero on a scratch Postgres, apply to `development`, preview Worker | `backend.yml` (`pull_request`, untrusted) |
| PR opened or updated | guard (append-only, numbers above the base, contract only alone and only into `main`), parsed-SQL lint | `backend-migrations.yml` job `plan` (`pull_request_target`: base-branch tooling, head SQL only) |
| Label `backend:apply-migrations` | apply to `staging`, then production if staging passed; label removed | `apply-staging`, `apply-production` |
| Every PR and merge-group event | `backend migrations applied`: passes when no migration changed, else the tree must equal staging and production | required check on `main`; on `feat-cmux-next` it reports but is not required (direct pushes) |
| Push to `feat-cmux-next` | append-only, numbering, contract and lint guard on the pushed range (never rejects the push; turns it red) | `migrations-push-guard` |
| Push to `feat-cmux-next` | verify staging (visible refusal naming the commit), deploy API Worker and dashboard | `deploy-staging` |
| Before any push (local) | migration changes without an open PR into `feat-cmux-next` or `main` fail | `scripts/verify-local.py` check `backend-migrations` |
| Push to `main` or dispatch `target=production` | verify production, deploy | `deploy-production` |

Expand migrations only add (tables, nullable or defaulted columns, indexes, backfills), so
the code already deployed keeps working when production gets them before the merge. Contract
migrations (drops, renames, NOT NULL) ship alone in a later PR, after production code no
longer uses what they remove.

A PR that changes nothing under `backend/db/migrations` passes the gate without touching a database.

How to write one: [skills/cmux-backend-migrations/SKILL.md](../skills/cmux-backend-migrations/SKILL.md).
Runner: `backend/db/migrate.ts` (`--lint`, `--env <env> [--verify]`).
Credentials: GitHub environments `cmux-next-development`, `cmux-next-staging`,
`cmux-next-production` (`CMUX_NEXT_PG_MIGRATOR_URL`; production also `CMUX_NEXT_STAGING_MIGRATOR_URL`).
Staging and production only release secrets to `main` and `feat-cmux-next`, so neither a PR's
own workflow nor a merge-queue run can read them. GitHub runs `backend-migrations.yml` from
`main`; changes to it take effect when they reach `main`. Locally `~/.secrets/cmux-next-planetscale-<env>.env`.
