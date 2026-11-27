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

## Migrations and deploys

A push to `main` deploys cmux.com. A push that adds a migration under `db/migrations` also runs `.github/workflows/cloud-vm-migrate.yml`, which applies it to staging and then production. The production build runs `tools/migration-deploy-gate.mjs` after `next build`: it reads the target database's `drizzle.__drizzle_migrations` read-only and waits, up to `CMUX_MIGRATION_GATE_WAIT_SECONDS` (default 1200), until every migration in the build is recorded. If they are still missing, the build fails and Vercel keeps the previous deployment live. The gate also covers manual `cmux-staging` deploys against the staging database.

Because the previous deployment keeps serving while a migration applies, every migration must be expand-only: new tables, nullable or defaulted columns, indexes, enum values, backfills. Before applying, the push run checks each database's pending migrations and refuses drops (other than `DROP DEFAULT` and `DROP NOT NULL`), renames, column type changes, `SET NOT NULL`, `TRUNCATE`, `REVOKE`, and new constraints, unique indexes or `NOT NULL` columns without a default on existing tables (`scripts/cloud-vm/contract-migrations.mjs`). A held migration stays held on later pushes until someone applies it. Ship those in a later PR, after no deployed code reads or writes the old shape, and dispatch the workflow with `target=production` yourself. For an emergency deploy while the database cannot be read, set `CMUX_MIGRATION_GATE_BREAK_GLASS=<commit SHA>` on the Vercel project's production environment; it applies to that commit only.

## Running Cloud machines

Machines never update themselves: a change to guest software, the daemon's command line, or the attach contract reaches only new machines unless it is shipped to running ones. Before changing `services/vms/images/devbox/`, `scripts/build-devbox-freestyle.ts`, or attach/open/route code that reads `providerMetadata`, read [docs/cloud-guest-upgrades.md](../docs/cloud-guest-upgrades.md). Never gate a running machine on a create-time marker without a backfill in the same PR, and never answer a permanent refusal with a retryable `502`. Upgrade cmux-tui on running machines with `bun scripts/upgrade-fleet-cmux-tui.ts`.
