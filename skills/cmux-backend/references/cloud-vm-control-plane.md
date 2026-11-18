# Cloud VM Control Plane

Expands the Cloud VM rules in [../SKILL.md](../SKILL.md).

## Source of truth

Postgres owns VM lifecycle state, active VM limits, idempotency records, usage events, provider identifiers, and team/account ownership. Provider state is observed and reconciled, not treated as canonical. When provider state and database state disagree, make the reconciliation explicit in code.

Cloud VM backend logic lives in Vercel route handlers and Effect services. Request-time workflows must be idempotent; durable state belongs in Postgres. Do not reintroduce Rivet or a raw actor protocol unless a later architecture document explicitly changes this control plane.

## Migrations

Merging `main` deploys `web/` to production immediately, and nothing migrates on deploy. Never run Drizzle migrations from Vercel build or route startup; that makes deploy behavior non-deterministic and couples app availability to schema mutation. A pull request that adds a `web/db/migrations/<name>/` folder therefore follows this order:

1. Write the migration so the code already in production keeps working on the new schema (add nullable columns, tables and indexes; drop only after a merged change stops reading the object).
2. Staging: `gh workflow run cloud-vm-migrate.yml --repo manaflow-ai/cmux --ref main -f target=staging -f source_ref=<PR head SHA>`.
3. Production: the same with `-f target=production`. The run migrates staging again, then waits for a `cloud-vm-production` reviewer, who reads the added SQL in the run summary before approving.
4. Re-run the `Migration ledger` check on the pull request, then merge.

The workflow runs main's migrator and copies in only the pull request's new migration folders; it refuses a pull request that edits a folder already on main, because Drizzle 1.0 selects pending migrations by folder name and never re-runs an applied name. Push after applying and the new head's added folders must be applied again. The operator alternative is `bun run cloud-vm:migrate -- staging` then `-- production` from a checkout of that commit, with the Vercel CLI signed in.

Enforcement is `.github/workflows/cloud-vm-migration-ledger.yml`. Its `Migration ledger` job reads `drizzle.__drizzle_migrations` through ledger-only credentials (`PRODUCTION_LEDGER_DATABASE_URL`, `STAGING_LEDGER_DATABASE_URL` in the `cloud-vm-migration-ledger` environment). In the merge queue it fails when the tree about to deploy has any folder production has not recorded; on a pull request it fails only for folders the pull request adds. Hourly and on every push to `main` it opens or updates the issue "Production database is missing migrations from main" and closes it once the ledger matches. Staging is advisory. Check locally, read only: `bun run cloud-vm:ledger -- production`. Exit codes: 0 applied, 1 pending, 2 usage, 3 ledger unreadable.

Local development keeps the `CMUX_PORT`-derived Docker Postgres path from `bun dev`.

## PlanetScale PostgreSQL runtime

Production and staging use PlanetScale Postgres database `cmux-prod` in organization `cmux`. Production is branch `main`; staging is `staging`; development is `development`. The application reads `DATABASE_URL` and uses `CMUX_DB_DRIVER=url`. Migration jobs use the protected `DATABASE_URL` secret. AWS credentials are not database credentials.

## Pricing and active limits

Create pricing gates use Stack Auth team payment items when enabled. Active limits and usage events are persisted, not inferred from process memory.

When changing create/start flows, verify that idempotency prevents duplicate provider creates, team ownership is checked before provider allocation, active VM limits are enforced before expensive provider work, usage events are written exactly once per lifecycle moment, and a failed provider call leaves a recoverable database state.
