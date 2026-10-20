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

VM and snapshot lists accept `createdBy=caller` to recover resources created
by the authenticated caller, using the persisted creation actor rather than
caller-supplied labels. The filter intersects tenant, live rows, service labels,
resource allowlists and other selectors before keyset pagination. Omit it to
keep the usual authorized tenant-wide listing. A service keeps its creator
across key rotation when its configured `id` stays the same; separate API keys
have separate creators, and session/device requests use the owning user's or
key's actor. Creator references remain private. Arbitrary actor selectors are
rejected. The operator CLI sends this filter with `cmux-vm list --created-by-me`
and `cmux-vm snapshot list --created-by-me`.

## gdp-ts proofs

`src/proofs/` is the only place proofs are minted: `KeyHasScope`,
`TenantOwnsResource` (carries the provider id as evidence),
`TenantMayCreate`, `TenantMayGrow`, `VmNetworkAllowed`, `VmImageAllowed` and `ServiceMayActFor`. Every method of the upstream client demands proofs about its
exact named arguments, and tenant provider ids are reachable only through a
`TenantOwnsResource` proof. Operator image references require `VmImageAllowed`. `test/types/proof-misuse.ts` lists calls that must
not compile; Oxlint's gdp-ts preset (strict) bans forging proofs.

## VM lifecycle (S2)

`GET /v1/vms/{vmId}/identity` returns `{ id, scheme: "sha256-v1", fingerprint }`
under the existing `vm:read` scope and current resource restrictions. The
fingerprint is lowercase SHA-256 of UTF-8 `cmux-vm-instance-v1`, a newline,
then the exact guest instance ID. The canonical identity comes from the
ownership record; its private ID is never returned. Power changes keep it;
a new allocation changes it. No provider request or guest wake is needed.
This identifies an allocation; it proves neither liveness nor access rights.
`cmux-vm identity VM_ID --json` exposes the same receipt.

The TeamVmDO bind runner can compare the guest's signed identity through a
driver-supplied API verifier while retaining its single-use nonce, ES256
signature, deadline and current-epoch checks. The API verifier checks the
exact public VM and scheme before comparing fingerprints. Legacy drivers
retain direct instance equality. Actual TeamVmDO transport selection remains
a separate migration; this endpoint does not switch existing resources.

The provider has no stop, resume or fork, so: `start` is the provider's start
(boots a stopped VM, resumes a paused one); `resume` is start of a paused VM
only (409 otherwise); `stop` runs `poweroff` in the guest; `fork` is snapshot,
then create from it, then delete the snapshot. Fork is not atomic: when the
snapshot succeeds and the create fails, the caller gets 503 `ForkIncomplete`
with the snapshot's id, the snapshot stays in the tenant's ownership rows, and
a retry with the same `Idempotency-Key` creates from it without a second
snapshot. Create with `resources` boots the largest base size inside the
request and then grows it. Without an idempotency key, a failed grow deletes
the new VM (409). A keyed create retains its allocation for recovery instead.

Use the same `Idempotency-Key` and request body when retrying a create or fork.
Before provider I/O, the API durably retains the public allocation ID, original
creator, an opaque request/provider-context digest and its quota reservation.
Provider recovery reads only that intent's unique slug and checks its metadata
and source snapshot; it never adopts by display name or account-wide listing.
A provider or ownership-write failure retains the intent and quota slot. A
confirmed ownership row repairs an uncertain completion, including a tombstone:
retrying a deleted allocation cannot create another VM.
A provider 4xx create answer other than 408 or 409, confirmed by a 404 at the
exact slug, frees the slot at once; the same key may retry under quota. A send
whose outcome is unknown (5xx, timeout, transport) is resent, or its
cancellation settles, only after a 10-minute grace window and another empty
exact-slug lookup.

Unresolved allocation intents do not expire at the ordinary 24-hour key or
five-minute quota-reservation deadlines. They continue to occupy their slot
until reconciled. Completed keys retain their result for at least 24 hours.
Legacy pending records without a retained allocation ID also stay unresolved;
expiry never turns them into permission to allocate again.
Changed provider credentials, endpoint or effective create intent refuse
recovery before provider I/O; restore the original context to resume. Unkeyed
requests do not provide this cross-request recovery contract. Production
billing integration, operator reconciliation/cancellation of abandoned intents,
and live-provider validation remain separate work.

Every create and fork needs billing (`Entitlements`, 402) and a quota slot
(`TenantMayCreate`, 429; default 20 live VMs, `TENANT_VM_QUOTAS` overrides).
Snapshot captures have the same durable send boundary, with separate quota and
public snapshot IDs. A key permanently identifies one capture: use a new key
for a new point in time. Omitted-key requests are separate captures, and retained
failures return `pendingSnapshotId`. `GET /v1/snapshot-creations` lists capture
receipts newest first, including pending unkeyed requests; it never contacts the
provider or returns caller keys. `GET /v1/snapshot-creations/ID` is read only. Callers that retained their key can
use `GET /v1/snapshot-creations/by-key` with the original `Idempotency-Key`
header for an exact lookup without scanning history or contacting the provider.
`POST /v1/snapshot-creations/ID/reconcile` records an exactly verified capture,
even after its source is deleted; it never captures again. `POST .../cancel`
fences future sends before deleting a verified capture. An unknown capture stays
pending and consumes quota even if its provider lookup currently returns 404.
Completed or cancelled keys never create another snapshot. Delete a committed
snapshot through the ordinary snapshot endpoint. Source-allowlisted credentials
can control only their original derived capture; general snapshot access stays
subject to its own allowlist. Service labels and the original service actor apply
to capture controls. Legacy uncertain snapshot requests fail closed; their old
records contain no reliable capture identity. VM fork's separate snapshot stage
still needs this recovery protocol.

Rate limits, quota reservations and idempotency keys live in one Durable
Object per tenant (`src/limits/`). Every mutation (create, start, stop,
pause, resume, fork, delete, exec, file write) writes an audit row: tenant,
actor (user or key id), action, cmux id, outcome; never commands or contents.

`POST /v1/vms/{vmId}/retire` permanently fences an owned VM against starts,
inbound wakes, exec and file writes. It confirms a zero lifetime run budget
and a paused/stopped state before returning `{ id, state, retired: true }`.
Reads and deletion remain available under their existing scopes and deletion
deadlines. A running guest gets a bounded, best-effort `sync` before fencing;
paused guests are never started. A 503 may leave the fence applied: retry the
same VM to confirm it. Retirement needs `vm:write`, current ownership and the
usual rate limit; a lapsed create plan does not block it. There is no unretire
operation. `cmux-vm retire VM_ID --yes --json` requires explicit confirmation
for scripts and refuses success without the matching retirement receipt.

`GET /v1/vms/{vmId}/files/stat?path=/absolute/path` reads metadata under
`vm:files` on running, paused, stopped or retired VMs without executing guest
code. It returns `kind`, byte `size`, integer permission `mode`, epoch-second
`mtime` (null when unavailable), `owner` and `group`. Symlinks keep their own
kind; file-type bits are removed from mode. A missing path is 404; malformed
metadata is 503. Ownership, service labels, resource allowlists, path validation
and file-rate limits apply before any provider request. There is no read audit
row. `cmux-vm file stat VM_ID /absolute/path --json` exposes the same contract;
human output prints permission bits in octal and escapes control characters.

A tenant is dev/test when the Worker is not production, or when its id is in
`DEV_TEST_TENANT_IDS` on production. Dev/test VMs get an idle timeout of at
most 300 s (default 300); product VMs default to -1 and the web app's CloudDO
pauses them. Until the billing source is wired (TODO in
`src/proofs/tenant-may-create.ts`), only dev/test tenants may create.

`bun scripts/smoke.ts` (CI job `smoke-staging`, after each staging deploy)
creates, execs, pauses and deletes a VM by exact id on the smoke tenant.

## Recover a create without a client key

VM creates and forks always journal the VM allocation before provider I/O.
If the client omitted `Idempotency-Key`, success and retained-allocation errors
include a public `creationKey` (`vcr_…`). Save it and use it as the
`Idempotency-Key` on retries, status, reconciliation or cancellation. A new
request without a key is a distinct intent. Server-issued handles never become
fresh allocation authority, including after the VM is deleted.

`cmux-vm creation list --json` and
`GET /v1/vm-creations?limit=50&cursor=…` discover server-issued handles after
a lost response. It returns `items` and an opaque `nextCursor`; a filtered page
may be empty while still having a next cursor. It reads no provider state.
The caller needs `vm:read` and an unrestricted credential; tenant, service
identity and current resource labels still apply. Client-supplied keys are
never returned or indexed in this history. History persists with its operation. The compatibility check runs the pinned preceding ledger against these
protected records; that version refuses them and needs current software for recovery.

An uncertain send, or a failed grow under a client key, retains the VM and its
quota reservation. A failed grow without a client key cancels the creation:
the VM is deleted and tombstoned, its slot is released, and the answer is 409.
Use the original intent to recover it, or cancel with its handle. A fork that
retained its snapshot but has not admitted a VM allocation reports unresolved;
retry the original fork with its handle. Interrupted snapshot acquisition is a
separate recovery gap; a VM creation handle does not prove a snapshot's outcome.

## Grow an existing VM

`POST /v1/vms/{vmId}/resize` takes a nonempty `resources` object with one or
more `vcpus` (2–32), `memoryMib` (4096–65536), or `diskMib` (16384–131072).
Values are integer minimums: omitted axes stay unchanged and already larger
axes are retained. No VM is recreated or shrunk. Growing the disk requires a
running VM; CPU and memory changes on paused/stopped VMs apply on resume/boot.

The caller needs `vm:write`, ownership (including resource allowlists/service
labels), and the tenant's VM plan. Growth does not reserve another VM quota
slot. `TenantMayGrow` binds the plan decision to the exact caller, alongside
scope and ownership proofs. The response is the current public VM, with
provider-confirmed resources satisfying every requested minimum.

After a provider error, the API reads the VM: satisfied floors count as
success, otherwise the failure is returned. Partial growth is retained; the
API never deletes an existing VM after resize failure. Retry the same intent
with the same `Idempotency-Key`; only unfinished axes grow. Completed retries
read the current VM during the existing 24-hour ledger window. Changed axes or
VM IDs under the same key conflict with 409. Capacity errors are 429, growth
conflicts are 409, and unavailable/unconfirmed outcomes are 503.

`cmux-vm resize VM_ID --disk-mib 65536 --idempotency-key KEY --json` exposes
the same path; `--vcpus` and `--memory-mib` may be combined. Omit the key to
generate one. Errors retain the sent key, and the CLI refuses responses for
another VM or below the requested floors. It does not automatically retry or
delete the VM.

## Approved service boot images

A configured service can list `GET /v1/vm-images` with `vm:read` and create
with `image: { "id": "cloud-standard", "revision": "r1" }` and `vm:write`.
The exact revision is required; `image` and `snapshotId` are mutually exclusive.
Ordinary tenant credentials see an empty catalog and cannot select these images.
Service team restrictions, required labels, billing, quota and dev/test idle caps
still apply. Image approval grants no network access.

Operators configure `VM_BOOT_IMAGES` as a JSON array (at most 32 entries):

```json
[{ "id": "cloud-standard", "revision": "r1", "displayName": "Cloud standard",
   "snapshotId": "<immutable operator snapshot id>", "services": ["cloud-driver"] }]
```

Missing configuration gives an empty catalog. Invalid configuration disables
approved images while ordinary creation remains available. Each entry requires
at least one service. Before creating, the API resolves the configured snapshot
and requires its canonical ID to match exactly; mutable aliases or unavailable
images produce 503 without falling back to a base image. Prepare images without
embedded credentials. Snapshot references and service approvals stay private;
the catalog exposes only `id`, `revision` and `displayName`.

An image create returns `bootImage: { id, revision, displayName }`. Callers must
check that receipt because an older API may ignore `image`. With the same retry
key, a changed revision or backing snapshot produces 409 within the existing
24-hour idempotency window. Omitted image keeps ordinary creation unchanged.

The operator CLI supports `cmux-vm image list --json` and
`cmux-vm create --image cloud-standard --image-revision r1 --json`.
`--public-egress` separately requests outbound access and requires `vm:network`.
The CLI fails if a requested image or egress receipt is missing or mismatched,
retaining the retry key and a validated public VM ID when available. Creation
may have succeeded; inspect that VM or retry the same intent with the same key.
The CLI never automatically deletes a VM after an unconfirmed receipt.

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

`PUT /v1/vms/{vmId}/https-proxies/{hostname}` replaces an existing HTTP
proxy with `{ "destination": "https://api.example.com", "headers": { ... } }`.
It requires `vm:network` and ownership of that VM, including any key resource
allowlist or service labels. The same origin and header policy applies.
Omitted headers clear the previous set. The receipt contains only `id` and
`hostname`.

Only rules whose source is exactly the owned VM qualify. Shared-network,
public, foreign-VM and non-HTTP rules are never changed. No match is 404;
multiple exact matches are 409. Lookup is bounded to 256 rules and refuses
an incomplete listing before updating anything. Replacement never creates a
rule or installs guest hosts/CA files. With an Idempotency-Key, replaying a
completed rotation does not overwrite a later one; changing policy or
credentials under the same key is 409.

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
