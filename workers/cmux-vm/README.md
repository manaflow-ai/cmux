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

## gdp-ts proofs

`src/proofs/` is the only place proofs are minted: `KeyHasScope`,
`TenantOwnsResource` (carries the provider id as evidence) and
`TenantMayCreate`. Every method of the upstream client demands proofs about its
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
pauses them. Until the billing source is wired (TODO in
`src/proofs/tenant-may-create.ts`), only dev/test tenants may create.

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
| `migrations/` | SQL for schema `cmux_vm`: `resources`, `api_keys`, `audit_log` (additive) |
| `upstream/` | pinned provider OpenAPI document and SDK type surface (`PINNED.json`) |

## Checks

`bun run check` runs typecheck, Oxlint, the OpenAPI drift check, the workerd
integration tests (fake upstream), the PGlite store tests and the bundle size
budget. CI runs the same in `.github/workflows/cmux-vm.yml`.

## Operations

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
