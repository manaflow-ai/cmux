<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

## Complexity ratchet

Keep ESLint as the full Next.js lint. Oxlint adds one incremental gate for
cyclomatic complexity, configured in `.oxlintrc.json` with the classic variant
and a maximum of 20. Run `bun run lint:complexity` from `web/` before handoff.
The gate rejects changes to that limit or variant, and fails when a baseline
entry becomes stale. The baseline file is mandatory, so deleting it also fails
the gate.

The gate scans all production JavaScript and TypeScript and compares the
findings with `oxlint-complexity-baseline.txt`. The baseline contains only the
legacy findings present when this gate was introduced. Any new finding fails
CI, including a complexity increase in an existing function. When a function
is fixed, remove its baseline line in the same change. The checker uses a
stable AST-context fingerprint and a sibling discriminator, so do not hand-edit
fingerprints. Do not add baseline entries. Use a narrow, single-line `oxlint`
suppression only for an intentional exception, with its reason in the comment
and pull request. Do not add a broad disable or raise the limit to accept new
code. Lower the limit in a separate cleanup wave as the remaining debt is
removed.

The required `Web complexity` check runs from the base branch and uses the
base branch checker and Oxlint toolchain against the pull-request source. Keep
the checker, trusted workflow, complexity rule, and Oxlint lock entries
unchanged in normal pull requests. Policy changes need a separate reviewed
update. The contributor-side `Web complexity candidate` check is only an early
local diagnostic.

## Database provider

cmux Cloud uses PlanetScale PostgreSQL, organization `cmux`, database `cmux-prod`. Branches are `main` (production), `staging`, and `development`. Vercel uses a PlanetScale `DATABASE_URL`; migration jobs use `DATABASE_URL` and `bun run cloud-vm:migrate -- <target>`. Aurora/RDS IAM and AWS migration-role instructions are retired. AWS KMS access for coderouter encryption is separate from database access. For PlanetScale CLI work, run `pscale auth check --format json` and pass `--org cmux` plus the confirmed branch.

## Migration order

Production migrations never run at deploy, and merging `main` deploys `cmux` and `cmux-staging` at once. A pull request that adds a folder under `db/migrations` therefore follows this order: open the pull request, apply its migration to staging with `bun run cloud-vm:migrate -- staging`, apply it to production with `bun run cloud-vm:migrate -- production`, then merge. Run both from the pull request's reviewed checkout.

Write the migration as an expand step: the code already on `main` must keep working after it is applied, so it adds tables, columns, or indexes and does not drop, rename, or tighten anything that running code reads or writes. Remove old schema in a later pull request, after no deployed code uses it.

Two checks enforce this order, and one escape hatch bypasses the first:

- `tools/migration-deploy-gate.mjs` runs first in `vercel-build`. On a production build of `cmux` or `cmux-staging`, it reads `drizzle.__drizzle_migrations` in a read-only transaction and fails the build when any local migration name is missing, by the same name rule that `getMigrationsToRun` uses. A failed build leaves the previous deployment live. If the database cannot be read, the build fails. Previews, docs projects, CI, and local builds skip it.
- The `Web migration readiness` workflow checks the migrations that a pull request adds against staging and production, read-only, when the `CMUX_MIGRATION_GATE_STAGING_DATABASE_URL` and `CMUX_MIGRATION_GATE_PRODUCTION_DATABASE_URL` repository secrets exist. Each secret holds a PlanetScale role that can only `SELECT` from `drizzle.__drizzle_migrations`. Without those secrets, the workflow requires the `db-migrations-applied` label as an attestation. Re-run the check after you apply the migration.
- Break-glass: set `CMUX_MIGRATION_GATE_BREAK_GLASS` to the commit SHA being deployed on the project's production environment and redeploy. It skips the deploy gate for that commit only. Use it only when the database is unreachable and a fix must ship, and remove it after the deployment.

## Running Cloud machines

Machines never update themselves: a change to guest software, the daemon's command line, or the attach contract reaches only new machines unless it is shipped to running ones. Before changing `services/vms/images/devbox/`, `scripts/build-devbox-freestyle.ts`, or attach/open/route code that reads `providerMetadata`, read [docs/cloud-guest-upgrades.md](../docs/cloud-guest-upgrades.md). Never gate a running machine on a create-time marker without a backfill in the same PR, and never answer a permanent refusal with a retryable `502`. Upgrade cmux-tui on running machines with `bun scripts/upgrade-fleet-cmux-tui.ts`.
