# cmux VM API

Tenant-scoped VM service on Cloudflare Workers. Design: decision CMUX-VM-API
(V1-V7) in the cmux-next spec. Contract: `src/api.ts`, published as
`openapi.json` (generated; `bun run openapi` regenerates, CI fails on drift).

Every request authenticates as a tenant (a Stack Auth team), either with a
session token plus `X-Cmux-Team-Id`, or with a cmux VM API key
(`cmuxvm_sk_...`, stored only as a SHA-256 hash, with scopes and an optional
resource allowlist). Public ids are opaque (`vm_...`, `snap_...`); the
ownership table maps them to provider ids for the caller's tenant only, so
another tenant's resource is always 404.

A service key (cx-b4h.13; Cloud Chief's is the first) has no tenant. It is
configured in the Worker secret `CMUX_VM_SERVICE_KEYS` (JSON array of `id`,
`sha256`, `scopes`, `labels`, optional `teams`; hashes only), names the team it
acts for in `X-Cmux-Team-Id` on every request (401 without, 403 outside
`teams`), and reaches only resources that carry all of its `labels`
(`role=chief`): it creates only such VMs, every other VM or snapshot of the
team is 404 and missing from its lists, and its Idempotency-Keys never meet the
team's. The `ServiceMayActFor` proof (`src/proofs/service-may-act-for.ts`) is
the only way to build its principal; audit rows and `created_by` name it as
`service:<id>`. The parser refuses the `admin` scope and an empty label set; a
secret that does not parse disables service keys only. A team member can label
a VM `role=chief` to hand it to the service.

## gdp-ts proofs

`src/proofs/` is the only place proofs are minted: `KeyHasScope`,
`TenantOwnsResource` (carries the provider id as evidence),
`TenantMayCreate` and `ServiceMayActFor`. Every method of the upstream client demands proofs about its
exact named arguments, and the provider id is reachable only through a
`TenantOwnsResource` proof. `test/types/proof-misuse.ts` lists calls that must
not compile; Oxlint's gdp-ts preset (strict) bans forging proofs.

## VM lifecycle (S2)

The provider has no stop, resume or fork, so: `start` is the provider's start
(boots a stopped VM, resumes a paused one); `resume` is start of a paused VM
only (409 otherwise); `stop` runs `poweroff` in the guest; `fork` is snapshot,
then create from it, then delete the snapshot. Fork is not atomic: when the
snapshot succeeds and the create fails, the caller gets 503 `ForkIncomplete`
with the snapshot's id, the snapshot stays in the tenant's ownership rows, and
a retry with the same `Idempotency-Key` creates from it without a second
snapshot. Create with `resources` boots the largest base size inside the
request and then grows it; a failed grow deletes the new VM (409).

Every create and fork needs billing (`Entitlements`, 402) and a quota slot
(`TenantMayCreate`, 429; default 20 live VMs, `TENANT_VM_QUOTAS` overrides).
Rate limits, quota reservations and idempotency keys live in one Durable
Object per tenant (`src/limits/`). Every mutation (create, start, stop,
pause, resume, fork, delete, exec, file write) writes an audit row: tenant,
actor (user or key id), action, cmux id, outcome; never commands or contents.

A tenant is dev/test when the Worker is not production, or when its id is in
`DEV_TEST_TENANT_IDS` on production. Dev/test VMs get an idle timeout of at
most 300 s (default 300); product VMs default to -1 and the web app's CloudDO
pauses them. Tenants with an active `cmux_vm.billing_accounts` row may create;
the dev/test and manaflow-team policy lists remain entitled as before.

`bun scripts/smoke.ts` (CI job `smoke-staging`, after each staging deploy)
creates, execs, pauses and deletes a VM by exact id on the smoke tenant.

## Layout

| path | what |
| --- | --- |
| `src/api.ts` | HttpApi definition: every endpoint, Schema and error |
| `src/handlers/` | endpoint handlers |
| `src/auth/` | session JWT (JWKS), team membership, API keys, middleware |
| `src/db/` | Hyperdrive Postgres client (one connection per request) and the ownership, API key and audit stores |
| `src/limits/` | per-tenant Durable Object: rate limits, quota reservations, idempotency keys |
| `src/policy.ts` | dev/test tenants, quotas, rate limits, upload size |
| `src/upstream/` | provider client (proof-gated); `exec-stream.ts` filters exec output as it streams |
| `migrations/` | SQL for schema `cmux_vm`: ownership, audit, mesh and metering tables (additive) |
| `upstream/` | pinned provider OpenAPI document and SDK type surface (`PINNED.json`) |

## Checks

`bun run check` runs typecheck, Oxlint, the OpenAPI drift check, the workerd
integration tests (fake upstream), the PGlite store tests and the bundle size
budget. CI runs the same in `.github/workflows/cmux-vm.yml`.

## Operations

Entitlement (`src/proofs/tenant-may-create.ts`): outside production every
tenant may create; in production a tenant may create when it is listed in
`DEV_TEST_TENANT_IDS`, in `MANAFLOW_TEAM_TENANT_IDS`, or has an active row in
`cmux_vm.billing_accounts`. Every other team gets 402. The two policy lists are
Worker vars in `wrangler.jsonc`; change them in a reviewed commit.

API key management (`/v1/api-keys`) writes `cmux_vm.api_keys`. Besides
SELECT, the Worker's database role needs, applied by an operator:

```sql
GRANT INSERT, UPDATE ON cmux_vm.api_keys TO <worker role>;
```

Migrations are applied by an operator with `psql -f migrations/<file>.sql`,
staging branch first; the Worker never runs DDL. Deploys run only from CI,
gated by the environment variable `CMUX_VM_DEPLOY_ENABLED`, and create or
update the environment's Hyperdrive config before deploying; the workflow header
lists the GitHub environments and the secrets each needs.

## Metering and billing

The Worker records VM lifecycle facts in `cmux_vm.usage_intervals`. Running and
starting intervals bill vCPU, memory and storage; paused and stopped intervals
bill storage until the VM is deleted. The five-minute Cron Trigger reconciles
owned VMs with the provider so provider-side idle pauses and identity wakes are
included. Usage is available to the owning tenant at `GET /v1/usage` with ISO
`from` and `to` timestamps, and includes per-VM and total vCPU-hours,
GiB-hours, storage GiB-hours, list cost and marked-up cost. Transfer billing is
not emitted because the current provider response has no per-VM transfer
counter. TODO: add transfer intervals when the provider exposes that field.
Provider and region are persisted on each ownership row; a missing or unknown
price key stops export and logs an operator-visible error instead of billing
zero.

Freestyle list prices are kept in `src/metering/prices.ts` (source and date are
documented there); each ownership row carries the provider and region used for
that VM. `CMUX_VM_MARKUP_BPS` is an integer basis-point markup and defaults to
zero. A negative, non-integer or
unsafe value disables Stripe export without taking VM requests down.

Stripe export is off unless both the `STRIPE_SECRET_KEY` secret and
`CMUX_VM_STRIPE_METER_EVENT` are set. When enabled, the Cron Trigger sends one
closed tenant-hour at a time to Stripe's Billing Meter API, using micro-dollars
as the meter value and a deterministic tenant-hour identifier. Successful
hours are recorded in `cmux_vm.usage_exports`, so retries do not double bill.
Before enabling export, an operator applies `migrations/0011_cmux_vm_usage.sql`,
grants the Worker role `SELECT, INSERT, UPDATE` on `usage_intervals`, `SELECT`
on `billing_accounts`, and `SELECT, INSERT, UPDATE` on `usage_exports` and
`usage_adjustments`, and writes an active `cmux_vm.billing_accounts` row with
`activated_at` for each Stripe customer. Stripe's meter
must interpret the submitted value as micro-dollars.
