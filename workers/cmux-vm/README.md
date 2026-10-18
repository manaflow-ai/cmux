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

Response scope names are extensible strings: clients must preserve unfamiliar
names in key records and permission errors. They do not grant authority.
Authentication and key creation requests accept only this server's known
scopes; unknown stored names are dropped. This matches the Rust client's
existing handling of response enums. Update schema-validating clients before
enabling server features that introduce new scope names.

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
`TenantMayCreate`, `VmNetworkAllowed` and `ServiceMayActFor`. Every method of the upstream client demands proofs about its
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

## Creation-time networking

`POST /v1/vms` accepts optional `initialNetwork`. Omit it to retain the
private default. Supplying it requires both `vm:write` and `vm:network`,
including when requesting an empty policy. Existing API keys keep their
current scopes.

```json
{
  "initialNetwork": {
    "publicEgress": true,
    "httpsProxies": [{
      "hostname": "api.cmux.internal",
      "destination": "https://api.example.com",
      "headers": { "authorization": "Bearer <proxy credential>" }
    }]
  }
}
```

`publicEgress` defaults to false and allows only public destinations.
HTTPS proxies default to none. An operator must separately enable each
destination origin with `VM_HTTPS_PROXY_ORIGINS`, a JSON array such as
`["https://api.example.com"]`. Missing or malformed configuration disables
proxies. Origins match exactly, including nondefault ports; paths,
credentials, query strings and fragments are refused.

Up to eight distinct virtual DNS hostnames are installed inline during
creation. Each proxy accepts up to 16 headers, with names up to 128 bytes,
values up to 4096 printable ASCII bytes and a combined 32 KiB limit.
Case-insensitive duplicate names and framing/hop-by-hop headers are refused.
All rules use only the newly created VM as their source. This endpoint does
not configure inbound domains, existing VMs or token refresh.

The create response includes `initialNetwork: { publicEgress,
httpsProxyHosts }` only when requested. Callers requiring networking must
check for this receipt: an older API may ignore the request field. Headers
are write-only and are never persisted in ownership, audit or idempotency
rows, or returned in errors and VM responses. A retry with changed network
intent or credentials under the same Idempotency-Key is 409. Forks do not
inherit network intent.

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

Entitlement until billing exists (`src/proofs/tenant-may-create.ts`): outside
production every tenant may create; in production a tenant may create when it is
listed in `DEV_TEST_TENANT_IDS` (dev/test: idle timeout at most 300 s) or in
`MANAFLOW_TEAM_TENANT_IDS` (the manaflow-team flag, cx-b4h.16: product tenant,
no idle cap). Every other team gets 402. Both lists are Worker vars in
`wrangler.jsonc`; change them in a reviewed commit.

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
