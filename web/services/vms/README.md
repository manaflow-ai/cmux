# Cloud VMs service

Backend for `cmux vm new/ls/rm/exec/attach` and the sidebar Cloud VM surface. Stack Auth gates every public route. Provider API keys stay server-side. Freestyle and E2B prefer `cmuxd-remote` WebSocket PTY with short-lived leases; older Freestyle VMs can fall back to its SSH gateway.

## Layout

```text
services/vms/
  auth.ts             Stack Auth request verification helpers
  billingGateway.ts   Stack Auth VM create credit reservations
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
- `CMUX_DB_SSL_CA_PEM`, optional AWS RDS CA bundle PEM, such as the current global bundle from AWS.
- `CMUX_DB_SSL_CA_PEM_BASE64`, Vercel-friendly alternative to `CMUX_DB_SSL_CA_PEM`.
- `CMUX_DB_SSL_REJECT_UNAUTHORIZED`, defaults to verifying AWS RDS server certificates. Only set
  `false` temporarily after explicitly accepting the risk, and prefer installing or pinning the AWS
  RDS global CA bundle.
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
- `CMUX_VM_CREATE_CREDIT_ITEM_ID`, optional Stack Auth team item used as a prepaid create-credit bucket. When unset, create credits are disabled and only active VM limits apply.
- `CMUX_VM_CREATE_CREDIT_COST`, default `1`.
- `CMUX_VM_CREATE_CREDIT_COST_E2B`, optional provider-specific override.
- `CMUX_VM_CREATE_CREDIT_COST_FREESTYLE`, optional provider-specific override.
- `CMUX_VM_FREE_MAX_ACTIVE_VMS`, default `1`.
- `CMUX_VM_PAID_MAX_ACTIVE_VMS`, default `10`.
- Stack Auth environment variables.
- Axiom/OpenTelemetry exporter variables.

Local development keeps using Docker Postgres through `DATABASE_URL`, derived from `CMUX_PORT`.

Run production/staging migrations explicitly, never during Vercel build or route startup:

```bash
CMUX_DB_DRIVER=aws-rds-iam bun db:migrate:aws-rds-iam
```

For local Docker Postgres, keep using:

```bash
bun db:migrate
```

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

## Usage, limits, and pricing

The usage ledger is in Postgres. VM create pricing gates use Stack Auth payment items when `CMUX_VM_CREATE_CREDIT_ITEM_ID` is configured. The create workflow inserts the idempotent VM row first, reserves one Stack Auth create credit only for a newly inserted row, calls the provider, and refunds the credit if provisioning fails before a usable VM exists.

Plan limits are team-based. Stack Auth personal teams should stay enabled for both dev/staging and production projects. New VM rows store `billing_team_id` and `billing_plan_id`; the free plan allows one active VM by default. Paid plan activation should write a readable plan id such as `pro` into Stack Auth team read-only metadata (`cmuxVmPlan`) or equivalent billing sync metadata, then configure the matching `CMUX_VM_PLAN_<PLAN>_MAX_ACTIVE_VMS` env var.
