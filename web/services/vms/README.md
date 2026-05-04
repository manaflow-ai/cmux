# Cloud VMs service

Backend for `cmux vm new/ls/rm/exec/attach` and the sidebar Cloud VM surface. Stack Auth gates every public route. Provider API keys stay server-side. Freestyle and E2B prefer `cmuxd-remote` WebSocket PTY with short-lived leases; older Freestyle VMs can fall back to its SSH gateway.

## Layout

```text
services/vms/
  auth.ts             Stack Auth request verification helpers
  billingGateway.ts   Stack Auth VM create-credit reservations
  entitlements.ts     Team plan and active VM limit resolution
  drivers/            Provider SDK adapters for E2B and Freestyle
  images/             Checked-in known-good provider image manifest
  errors.ts           Typed Effect errors for VM workflows
  config.ts           Runtime kill switches and deployment guards
  providerGateway.ts  Effect service wrapper around provider drivers
  repository.ts       Effect service for Postgres state and usage rows
  routeHelpers.ts     Shared authenticated REST route helpers
  workflows.ts        Effect workflows for create, list, destroy, exec, attach
db/
  schema.ts           Drizzle schema for VM state, leases, and usage events
  migrations/         SQL migrations applied by `bun db:migrate`
```

## HTTP surface

- `/api/vm`, authenticated `GET` list and `POST` create.
- `/api/vm/:id`, authenticated `DELETE` destroy.
- `/api/vm/:id/exec`, authenticated `POST` command execution.
- `/api/vm/:id/attach-endpoint`, authenticated `POST` PTY/RPC attach lease minting.
- `/api/vm/:id/ssh-endpoint`, authenticated `POST` legacy Freestyle SSH attach.

There is no raw actor or provider protocol endpoint. The old `/api/rivet/*` gateway has been removed.

## Authentication model

Public callers only use `/api/vm/*`. Each route calls Stack Auth first and returns `401` before any Postgres or provider operation when the caller is unauthenticated.

Ownership checks happen inside the Effect workflow by loading the VM row with both `user_id` and `provider_vm_id`. A user cannot destroy, exec, attach, or mint SSH credentials for a VM owned by another Stack Auth user.

Cookie-authenticated browser mutations also require a same-origin browser request. Native macOS
calls use `Authorization: Bearer` plus `X-Stack-Refresh-Token` and are not subject to browser CSRF.
For cookie calls, `POST`/`DELETE` routes reject cross-site `Origin` or `Sec-Fetch-Site` requests
before any VM workflow runs.

Cloud VM billing is team-scoped. The native client sends the selected Stack team in
`X-Cmux-Team-Id`; browser callers may send that header or `teamId`/`billingTeamId` in the request.
The backend validates membership before create or team-filtered list. If Stack returns one team,
the backend treats it as the personal team created on sign-up. If Stack returns no team, or multiple
teams without a selected/requested team, create fails before providers or billing are called.

The auth regression tests live in `web/tests/vm-route-auth.test.ts`. They verify unauthenticated create, list, destroy, attach, SSH endpoint, and exec requests return `401` before the VM workflow runs, and that cross-site cookie mutations are rejected.

## State model

- `cloud_vms` owns VM lifecycle state, provider ids, image ids, billing team/plan ids, and per-user idempotency keys.
- `cloud_vm_leases` stores hashed PTY/RPC/SSH lease tokens, provider identity handles, session ids, expiry, and revocation timestamps.
- `cloud_vm_usage_events` records lifecycle, attach, SSH, and exec events with billing team/plan ids for billing and audit rollups.

Create idempotency is enforced by the partial unique index on `(user_id, idempotency_key)`. A retry with the same key returns the existing VM after provisioning succeeds. A concurrent retry while the first create is still provisioning returns `409` instead of starting a second paid provider VM.

Active VM limits are enforced inside the same Postgres transaction that inserts the create row. The transaction takes a billing-team advisory lock before counting active VMs, so two concurrent creates for the same team cannot both pass the free-plan limit.

## Image manifest and rollback

Known-good provider images are recorded in `services/vms/images/manifest.json`. Each entry records
the provider, provider image id, cmux image version, build metadata, and validation status.

Vercel production, staging, and preview deployments fail closed for VM create if the selected image
env var is missing or is not listed in the manifest. Local development can use the manifest default
without setting provider image env vars. Set `CMUX_VM_ALLOW_UNMANIFESTED_IMAGES=1` only for local
image experiments.

Rollback is an env-only operation:

1. Choose a previous manifest entry with `validationStatus: "passed"`.
2. Set `E2B_CMUXD_WS_TEMPLATE` or `FREESTYLE_SANDBOX_SNAPSHOT` back to that entry's `imageId`.
3. Redeploy staging, smoke test, then repeat for production.
4. Keep old provider templates/snapshots until all VMs using them are gone.

## Effect conventions

Routes stay thin. They parse HTTP input, set span attributes, and run an Effect workflow.

`workflows.ts` composes explicit services:

- `VmRepository`, Postgres reads and writes.
- `VmProviderGateway`, provider SDK calls wrapped in typed Effect errors.

Provider SDKs remain Promise-based adapters under `drivers/`, but all route-visible backend logic is modeled as Effect values with typed errors and explicit dependencies.

## Deployment

Vercel runs the Next.js application and all VM REST routes. Postgres is the persistent control plane. There is no Rivet deployment for this feature.

Production and staging use Vercel Marketplace AWS Aurora PostgreSQL with OIDC federation and RDS IAM auth. The runtime does not need a long-lived database password.

Set these Vercel environment variables per production/staging environment:

- `CMUX_DB_DRIVER=aws-rds-iam`.
- `AWS_ROLE_ARN`, IAM role Vercel assumes.
- `AWS_REGION`, Aurora region.
- `PGHOST`, Aurora cluster endpoint.
- `PGPORT`, usually `5432`.
- `PGUSER`, IAM-enabled Postgres role.
- `PGDATABASE`, app database name.
- `CMUX_DB_POOL_MAX`, small pool size for Vercel Functions. Start with `5`.
- `CMUX_DB_SSL_REJECT_UNAUTHORIZED`, optional. Leave unset for the current Vercel Marketplace Aurora databases so Node uses its default trust store.
- `CMUX_VM_CREATE_ENABLED`, global create kill switch. Set `0` to block new paid creates while
  keeping list, attach, and delete available.
- `CMUX_VM_E2B_ENABLED`, per-provider E2B create kill switch.
- `CMUX_VM_FREESTYLE_ENABLED`, per-provider Freestyle create kill switch.
- `CMUX_VM_ALLOWED_ORIGINS`, optional comma-separated extra origins allowed for cookie mutations.
- `E2B_API_KEY`, E2B provider key.
- `FREESTYLE_API_KEY`, Freestyle provider key.
- `E2B_CMUXD_WS_TEMPLATE`, E2B template alias/name for WebSocket PTY sandboxes.
- `FREESTYLE_SANDBOX_SNAPSHOT`, Freestyle snapshot id.
- `CMUX_VM_DEFAULT_PROVIDER`, `freestyle` or `e2b`.
- `CMUX_VM_PLAN_FREE_CREATE_CREDIT_ITEM_ID`, Stack Auth team item used as the free-plan create-credit bucket. Defaults to `cmux-vm-create-credit`; set to `none`, `disabled`, `off`, or `false` to opt out.
- `CMUX_VM_PLAN_FREE_CREATE_CREDIT_COST`, optional free-plan per-create cost. Defaults to `1`.
- `CMUX_VM_CREATE_CREDIT_ITEM_ID`, optional global Stack Auth item used as a prepaid create-credit bucket for every plan without a plan-specific item. Set to `none`, `disabled`, `off`, or `false` to opt out of create credits for plans without a plan-specific value.
- `CMUX_VM_CREATE_CREDIT_COST`, default `1`.
- `CMUX_VM_CREATE_CREDIT_COST_E2B`, optional provider-specific override.
- `CMUX_VM_CREATE_CREDIT_COST_FREESTYLE`, optional provider-specific override.
- `CMUX_VM_FREE_MAX_ACTIVE_VMS`, default `1`.
- `CMUX_VM_PAID_MAX_ACTIVE_VMS`, default `10`.
- Stack Auth environment variables.
- Axiom/OpenTelemetry exporter variables.

Local development keeps using Docker Postgres through `DATABASE_URL`, derived from `CMUX_PORT`.

Run production/staging migrations explicitly, never during Vercel build or route startup. The local operator path pulls deployed Vercel env. The GitHub Actions path uses the minimal DB metadata copied into protected GitHub environments, generates an RDS IAM auth token, and applies Drizzle migrations:

```bash
bun run cloud-vm:migrate -- staging
bun run cloud-vm:migrate -- production
```

For local Docker Postgres, keep using:

```bash
bun db:migrate
```

Before a staging or production migration, run the preflight:

```bash
bun run cloud-vm:preflight -- --schema-only .
```

Audit deployed env names without printing values:

```bash
bun run cloud-vm:env:audit -- staging --strict
bun run cloud-vm:env:audit -- production --strict
```

This audit is a local operator command. It intentionally does not run in GitHub Actions because
reading all Vercel env values from Actions would require a broad Vercel env-read token.

Smoke deployed API auth/list behavior without creating production VMs:

```bash
bun run cloud-vm:smoke -- staging
bun run cloud-vm:smoke -- production
```

Staging may run a real create/destroy smoke with tiny quotas:

```bash
bun run cloud-vm:smoke -- staging --create --provider e2b
```

## GitHub operations

Cloud VM migrations and smoke checks are exposed as manual GitHub Actions:

- `Cloud VM DB migration`
- `Cloud VM smoke`

They use these GitHub Environments:

- `cloud-vm-staging`
- `cloud-vm-production`

Each environment needs:

- variable `AWS_REGION`, usually `us-west-2`
- variables `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE`
- variable `CMUX_DB_SSL_REJECT_UNAUTHORIZED`, usually `true`
- variables `NEXT_PUBLIC_STACK_PROJECT_ID` and `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY`
- secret `STACK_SECRET_SERVER_KEY` for smoke workflows
- secret `AWS_MIGRATION_ROLE_ARN` for migration workflows

Production migration runs staging migration first on the same commit, then waits on the protected production environment approval.

## Local database development

Use `CMUX_PORT` to run multiple isolated web and database environments on one machine:

```bash
CMUX_PORT=10180 bun dev
```

`bun dev` sources `~/.secrets/cmuxterm-dev.env` (falling back to the legacy secret files), derives the local database URL from `CMUX_PORT`, starts this worktree's Docker Postgres, applies Drizzle migrations, then starts Next.js. When it exits or is interrupted, it stops the matching Docker container and network while preserving the Postgres volume.

The dev Postgres port is `CMUX_PORT + 10000`, so `CMUX_PORT=10180` maps to `localhost:20180`. `bun db:test` starts a separate test DB on `CMUX_PORT + 30000`, applies migrations twice, and runs behavior tests against a real Postgres container.

## Provider matrix

| Verb                        | Freestyle | E2B |
|-----------------------------|-----------|-----|
| `cmux vm new`               | yes       | yes |
| `cmux vm new --workspace`   | yes       | yes |
| `cmux vm new --detach`      | yes       | yes |
| `cmux vm attach <id>`       | yes       | yes |
| `cmux vm exec <id> -- ...`  | yes       | yes |
| `cmux vm ls / rm`           | yes       | yes |

E2B interactive paths require a cmuxd WebSocket PTY image. The backend writes only a hash of attach tokens to Postgres; raw tokens are returned once to the Mac client.

Operational note: Freestyle creates are currently disabled in staging and production while the active Freestyle snapshot lacks the cmuxd RPC lease path required for browser proxy. Keep `CMUX_VM_DEFAULT_PROVIDER=e2b` and `CMUX_VM_FREESTYLE_ENABLED=0` until a new Freestyle snapshot passes WebSocket PTY and browser proxy smoke.

## Usage, limits, and pricing

The usage ledger is in Postgres. VM create pricing gates use Stack Auth payment items. The free plan uses the team-scoped item `cmux-vm-create-credit` by default. Configure the Stack Auth free product as team-owned, include-by-default, and grant 20 of that item with no repeat and no expiry. Set `CMUX_VM_PLAN_FREE_CREATE_CREDIT_ITEM_ID=none` in local or self-hosted deployments that intentionally do not use Stack Auth create credits. The create workflow inserts the idempotent VM row first, reserves one Stack Auth create credit only for a newly inserted row, calls the provider, and refunds the credit if provisioning fails before a usable VM exists.

Plan limits are team-based. Stack Auth personal teams should stay enabled for both dev/staging and production projects (`createTeamOnSignUp` / `teams.createPersonalTeamOnSignUp`). New VM rows store `billing_team_id` and `billing_plan_id`; the free plan allows one active VM at a time and 20 total successful creates by default. Paid plan activation should write a readable plan id such as `pro` into Stack Auth team read-only metadata (`cmuxVmPlan`) or equivalent billing sync metadata, then configure the matching `CMUX_VM_PLAN_<PLAN>_MAX_ACTIVE_VMS` env var. Paid plans only consume Stack Auth create credits when `CMUX_VM_PLAN_<PLAN>_CREATE_CREDIT_ITEM_ID` or the global `CMUX_VM_CREATE_CREDIT_ITEM_ID` is configured.
