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

A team key (`src/auth/team-keys.ts`) is a long-lived `cmuxvm_sk_` key a team's
own agents use headless (a lane VM's `cmux vm new` with `CMUX_VM_API_KEY`, a
demand scaler), with no person signed in and no confirm per call. Rows come from
the plain var `CMUX_VM_TEAM_KEYS` (JSON array of `id` `tk-...`, `team`, one or
two `sha256`, VM `scopes`, `labels`, `maxVms` up to 500, `maxUsdPerHour` up to
500; hashes only). It authenticates as the service `tk-...` acting for its one
team (`X-Cmux-Team-Id` optional, another team 403), reaches only VMs carrying its
labels, gets those labels on every create, and every create is held to its
caps: over `maxVms` live VMs, or over `maxUsdPerHour` estimated (the agent-key
estimate, every live VM counted), is 429 naming the cap. Three optional caps
(RFD 0016; unset, no limit) also hold on every create, start and resume:
`maxRunningVms` (running or booting VMs; paused and stopped ones do not count),
and `maxUsdPerDay` / `maxUsdPerMonth` (estimated list-price spend this UTC day
or month: each live VM from its create, ending at its pause when paused; a VM
gone at the provider and each VM deleted in the window at the default size,
summed in SQL; it errs high). A start or resume counts every live VM of the key,
up to 5000 (past that it refuses). A refusal is 429
with `budget` `agent_running_vms`, `agent_usd_per_day` or `agent_usd_per_month`,
naming the cap and its current value. These checks read then act, so two
concurrent starts can pass together at the cap. It cannot resize, fork
or mint keys. It never expires and nothing deletes its VMs; rotating keeps them
(second hash, move holders, drop the first). Mint with `bun scripts/team-key.ts
mint --out FILE ...` (the key only to FILE, the row to stdout); revoke by
removing the row and deploying. An invalid var disables team keys only.

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

## Device overlay policy

Mesh ACL destinations accept device IDs and `device:*` as well as VM
selectors. Device edges are directed and omit self connections. They compile
separately from provider firewall rules, with limits of 2,500 directed rules
per mesh and 180 incoming plus outgoing rules per device.

`GET /v1/devices/{deviceId}/overlay-policy` requires `mesh:join` and the
device's enrolling principal or a tenant admin. A device can instead use
`POST /v1/devices/{deviceId}/signed/overlay-policy`, signing the existing
eight-line `cmux-mesh-v1` message with the distinct purpose `overlay-policy`.
The operator CLI exposes the credential read as
`cmux-vm device overlay-policy dev_…` (`--json` preserves the response).

The response includes public install and WireGuard keys and separate inbound
and outbound permissions for relevant peers whose owners remain valid. Its
digest identifies the projection even when a key changes at the same ACL
version; it does not prove freshness. Reads hold the ACL/removal writer lock
and use one device identity inventory.
This contract does not activate transport, push updates, admit HostDO relay
sessions or grant command execution; those integrations remain separate.

Provider-free servers use `POST /v1/meshes/{meshId}/overlay-servers`. Sign the
same eight-line message with purpose `enroll-overlay-server`, the mesh id,
the server's public keys and name. A fresh signed retry returns the existing
identity when its owner, name and keys match. Records are separate from
gateway devices, have no tunnel id and do not authorize provider operations.
Source wildcards include gateway clients; server initiation needs an explicit
source-id grant to another device. Provider VM firewall paths cannot originate
from an overlay server. Destination selectors include both inventories. Enrollment
checks existing wildcard expansion before recording the new identity.

Operators can read/list/revoke these identities and read their policy under
`/v1/overlay-servers/{id}` and `/v1/meshes/{meshId}/overlay-servers`. Servers
can sign their own `/signed/policy` or `/signed/revoke` request with the
distinct purposes `overlay-server-policy` and `revoke-overlay-server`.
Policy responses include the authoritative Native tenant id for a future
backend binding, alongside the mesh id and public keys. Neither pairing nor
this metadata activates a server role or grants execution. Backend pairing,
policy push and relay admission still need integration.

The CLI exposes `device enroll-server MESH --request signed-request.json`,
`device get-server ID`, `device servers MESH`, `device server-policy ID`,
and `device revoke-server ID --yes`. The enrollment file contains a signed
public request; the CLI sends only the known request fields. Private keys
remain with their signer. Admission is limited to 50 live server identities
per mesh, independently of provider tunnel and Cloud VM billing capacity.

Migration 0014 adds the server inventory and widens signed-request purposes.
Apply it and grant the Worker SELECT, INSERT and UPDATE on
`cmux_vm.mesh_overlay_servers` before deployment. The shared Worker/release
schema gate requires the table, these privileges and a validated replay
constraint; older gateway rows/readers remain unchanged.

An approver can instead issue `POST /v1/meshes/{meshId}/overlay-server-codes`
with the approved `name`, `wgPublicKey` and `installPublicKey`. The response
contains an `msc_` code, those bindings, tenant/mesh ids, a reserved device id
and a 10-minute expiry. Issuance creates no server; the code is shown once
and only its SHA-256 is stored. Each mesh may issue 20 codes per hour.
Deliver the response through the approved pairing channel.

The server redeems at `POST /v1/meshes/{meshId}/overlay-server-enrollments`
without an account credential. Sign `cmux-mesh-v1` with purpose
`enroll-overlay-server`, mesh id as target, the approved public keys, and
`<code>:<name>` as the name line. Colons are not allowed in a plain server
name, so this cannot be replayed as credential enrollment. The signature
must be fresh and single use. Authentication failures burn unused codes;
quota and dependency failures leave them usable with a fresh signature.
Registration and consumption commit atomically. Until expiry, a fresh
signed retry acknowledges the same live identity; revocation cannot revive
it. After a lost response the reserved device id also supports signed policy
recovery, including after code expiry.

Use `device server-code MESH --request binding.json` to approve, and
`device redeem-server-code MESH --request signed-code.json` to redeem.
Redemption reads no account configuration and sends no account headers;
its origin comes from `--base-url`, `CMUX_VM_BASE_URL`, or the default API.
The code stays in the request file rather than command arguments. Private
keys remain with the signer. This API does not deliver the code or activate
a server role; backend pairing still needs to supply the approved channel.

Migration 0015 adds `cmux_vm.mesh_overlay_server_codes`. Apply it through
the versioned runner and grant the Worker SELECT, INSERT and UPDATE before
deployment. The schema gate checks those privileges. Gateway codes and
older readers retain their own table and code prefix.

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
request and then grows it. A failed grow keeps the new VM as an uncommitted
creation instead of deleting it (see "Recover a create without a client key").

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
(`TenantMayCreate`, 429). A production product tenant has no machine-count
cap: its machines are metered and cmux-platform's team spending cap is the stop.
Dev/test tenants (every tenant off production) keep 300 live VMs (NEXT Max's
machines kept, so a plan is the stop there), paused ones
too; a production tenant in `DEV_TEST_TENANT_IDS` (the smoke service) keeps 20; a `TENANT_VM_QUOTAS` entry holds any one tenant to its own number.
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
snapshot through the ordinary snapshot endpoint. To cancel by key, use
`POST /v1/snapshot-creations/by-key/cancel` with the original header and
`expectedSnapshotId` from the lookup. A null ID fences only an unadmitted key;
it does not prove an older unrecorded provider operation was deleted. A known ID
can cancel a pending capture or delete its committed snapshot. Unverified cleanup
stays pending and retains quota. By-key cancellation requires credentials without
a resource allowlist; existing by-ID controls retain their source scope.
Source-allowlisted credentials
can control only their original derived capture; general snapshot access stays
subject to its own allowlist. Service labels and the original service actor apply
to capture controls. Legacy uncertain snapshot requests fail closed; their old
records contain no reliable capture identity. Fork intermediates use this same
capture journal, with a destination VM ID and VM quota reserved before capture.
VM creation status can therefore be pending before VM allocation has begun.
An unresolved capture also holds a snapshot slot. Retry the original fork to
continue; reconcile records existing effects without sending a capture or VM
create. VM creation cancellation fences both stages, deleting only an exactly
verified intermediate before releasing quota. The VM write credential receives
authority for that fork snapshot only, without general snapshot write access.

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

Use `cmux-vm creation list --pending` or `GET /v1/vm-creations?state=pending`
for unfinished server-issued work, newest first, including requested cancellations.
This view follows retained VM quota slots and rechecks current authorization and
canonical receipts. Keep `--pending` or `state=pending` with its page cursor.
`pendingIndex: ready` confirms that the retained slots were correlated. Older
slots are linked to their journals in bounded steps: `building` returns an index
cursor, and `unavailable` means some retained work needs manual reconciliation.
Neither value is complete history, and listing never releases quota or contacts
the provider. The CLI advances at most 32 backfill pages per command; set
`--index-pages 1..128` to change that budget or resume from the printed cursor.

An uncertain send or failed grow retains the VM and its quota reservation.
Use the original intent to recover it, or cancel with its handle. After a
failed grow (503, or 429 when the provider is out of capacity) the VM is
recorded as uncommitted: `GET /v1/vms` and `GET /v1/vms/{vmId}` show it with
`creation: "pending"`, and the creation status stays `pending`. It is never
replayed or settled as a finished create, and it keeps its quota slot. Retry
the create with the same key (or `creationKey`) to grow and commit it;
reconcile commits it once the VM already meets the requested size. Deleting
it cancels the creation and frees the slot, including when the delete's own
answer was lost and it is retried. A same-key retry never creates another VM.
If the provider deleted it first (for example after `autoDeleteSeconds`), the
retry answers 503 and keeps the slot until the 10-minute send grace window has
passed; then, once both its exact slug and its recorded provider VM answer 404,
the allocation is recorded as deleted, its slot is freed, and the retry answers
404 like any deleted allocation. A fork that
used the older snapshot stage without a VM receipt reports unresolved. New
forks retain their destination ID before capture and stay pending under the
same handle. Retry the original fork to continue. An absent provider lookup
does not prove the snapshot was never taken. Older claims without capture
receipts require reconciliation; their expiry cannot authorize recapturing.

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
The list keeps `VM_BOOT_IMAGES` order and says so with `order: "configured"`:
the first entry is the image in use. A caller that follows the list (the cloud
platform picks the first entry, or the last on an append-only list) must treat a
response without `order` as unordered, since older servers sorted it by id.

An image create returns `bootImage: { id, revision, displayName }`. Callers must
check that receipt because an older API may ignore `image`. With the same retry
key, a changed revision or backing snapshot produces 409 within the existing
24-hour idempotency window. Omitted image keeps ordinary creation unchanged.

### One provider call per create

An image create that asks for a size boots the image's own snapshot (baked
small) and is then resized, after two provider reads: four provider calls. Two
switches, each a Worker var listing service key ids (`CMUX_VM_SERVICE_KEYS`
ids), remove all but the create for those services. Unset, nothing changes.

- `CMUX_VM_SIZED_IMAGE_SERVICE_IDS`: an entry of `VM_BOOT_IMAGES` may carry
  `"large": { "snapshotId": "...", "vcpus": 4, "memoryMib": 16384, "diskMib": 65536 }`,
  a second snapshot of the same bake taken after its builder was grown to that
  size (`web/scripts/cmux-vm-image/large-image.ts`). A listed service's create
  that names the image and asks for exactly that size on all three axes boots
  it, so the VM is at its size from the create and no resize is sent. The
  resize is decided by the provider's answer, not by the entry: a VM that
  boots smaller is still grown. Any other size, a create that names no size
  and an image without `large` boot the image's own snapshot as before. The
  receipt is the same either way (`bootImage` id and revision, exact
  `resources`); the large snapshot's id is never returned. A malformed `large`
  is dropped and the image stays listed. A large boot is held to the size
  asked: a VM that answers bigger than asked on any axis (an entry that
  declares the wrong size) is deleted and the create fails with 503, like a
  VM from another snapshot, because machines are billed by size; the
  `vm_create` line says `oversized`.
  Operator rule: a revision's `large` is published with it and never removed
  or replaced. To change or drop it, publish a new revision (a new entry) and
  remove the old entry as a whole. Add `large` only to a list a Worker with
  this change reads: an older Worker treats the unknown field as an invalid
  list and disables every image. A create in flight when the switch changes,
  or when an entry gains `large`, still recovers: a retry keeps the snapshot
  its first attempt was journaled from. If the rule is broken while a create
  is in flight, its retry reads the exact slug first and returns the VM the
  first attempt made, checked against the journal (`imageVariant`
  `unlisted`); when that attempt made nothing the key fails (503) and sends
  nothing, and a new Idempotency-Key creates from the entry as it is.
- `CMUX_VM_CREATE_NO_READS_SERVICE_IDS`: a listed service's create sends no
  provider read first. The exact-slug read is skipped only when the VM id was
  minted in that request (no earlier attempt can have created its slug); a
  retry under the same key, and a fork resumed from its capture, read first as
  before, and the read after a failed create stays. The boot image read is
  skipped on every attempt: the create's answer must name the approved
  snapshot, and a VM that names another is deleted and the create fails, so a
  snapshot the provider no longer has is still 503 with nothing recorded. It
  is found by the create instead of a read before it, and that differs in
  what a retry may do. With the read, nothing was sent, so a retry under the
  same key could send at once. Without it: a clean refusal (a 4xx other than
  408 or 409, then 404 at the exact slug) marks the send rejected and frees
  the slot, and a retry sends at once; a 5xx, a timeout or a VM booted from
  another snapshot leaves the send uncertain, and retries under that key
  answer 503 without sending until the 10 minute send grace has passed
  (`CREATE_SEND_GRACE_MS`), each later round that boots another snapshot
  making and deleting one VM. What the provider answers for a snapshot it no
  longer has is not confirmed; confirm it before listing production. A mismatched VM whose delete fails runs
  unrecorded until the orphan sweep; it is logged as
  `vm_create_discard_failed` (public VM id, `reason` `receipt` or
  `oversized`, the delete's `status`).

The staging Worker lists `cloud-platform-dev` and `cloud-platform-staging` in
both; production lists none. Staging takes the unconfirmed missing-snapshot
case above: at worst a staging create answers 503 for the send grace. The
`vm_create` line (Operations) says what each create did: `imageVariant`, and
null `recoverMs`, `verifyImageMs` and `resizeMs` for a call that was not made.

The operator CLI supports `cmux-vm image list --json` and
`cmux-vm create --image cloud-standard --image-revision r1 --json`.
`--public-egress` separately requests outbound access and requires `vm:network`.
The CLI fails if a requested image or egress receipt is missing or mismatched,
retaining the retry key and a validated public VM ID when available. Creation
may have succeeded; inspect that VM or retry the same intent with the same key.
The CLI never automatically deletes a VM after an unconfirmed receipt.

### Rolling a new image (no hand PR)

`.github/workflows/cloud-vm-image-roll.yml` replaces the hand pin PR
(`images/cmux-vm/pin-cmux-tui.ts`) and the hand approval PR (an entry put first in
production's `VM_BOOT_IMAGES`):

1. Every feat-cmux-next cmux-tui build that `cmux-tui-artifacts.yml` publishes
   dispatches it, and so does a push that changes the image inputs
   (`images/cmux-vm/**`, `web/scripts/cmux-vm-image/**`).
   `images/cmux-vm/auto-roll.ts plan` rolls only a build of the branch whose
   binaries differ from the pinned ones, never an older one.
2. `cloud-vm-image-bake.yml` (called with `roll: true`) pins that build and bakes
   the Native receiver image with the agent tools. Its 5-clone smoke and agent
   tools probe on the candidate snapshot are the gate: a red keeps nothing and
   production stays on its image.
3. A bot commit (`cmux-vm: image roll cloud-native-auto-<cmux-tui>-<run>-<attempt> ...`)
   lands the pinned lock and the image, first in production and last in
   staging. Only the newest 6 `cloud-native-auto-*` entries stay in each list;
   hand-approved entries are never removed. Its push deploys production and
   runs `smoke-production`, whose product create boots that first image.
4. `image-roll-settle` in `cmux-vm.yml` (`auto-roll.ts settle` decides): a
   deploy or product smoke that isn't green, or a create that booted another
   image, lands `cmux-vm: image rollback <id> ...`, which takes the image out of
   both lists, so the entry before it boots again. A failed, cancelled or timed
   out deploy all roll back. The image leaves the lists even when a newer roll
   already sits above it, so that roll's own rollback can never bring it back;
   only an image already gone from both lists needs nothing.
5. The rollback's own deploy is settled too: its product create must boot the
   entry now first. If not, `image-roll-settle` dispatches `deploy-production`
   again, at most 3 production deploys in all, then records `rollback_failed`
   and comments on the `cloud-image-roll` issue. A rollback never lands another
   rollback commit.

`images/cmux-vm/auto-roll.json` switches it: `off`, `dry-run` (bake and gate,
then upload the commit's diff without pushing) or `live`. One roll runs at a
time and one waits; a newer request replaces the waiting one.

Each roll's record (fix commits with merge times, gate, promotion commit and
time, production smoke time, rollback) is `rolls/<run id>.json` on the
`cloud-image-rolls` branch: `git fetch origin cloud-image-rolls` reads it with
no API call. The roll and rollback commits carry `Image-Roll-Run` and
`Image-Roll-Image` trailers. A red gate, promotion or rollback comments on the
open `cloud-image-roll` issue.

cmux-platform boots the image its `CLOUD_VM_API_IMAGE` and
`CLOUD_VM_API_IMAGE_REVISION` name, so a rolled image reaches people's
machines only when the platform names it too (or follows the first entry).

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

### Joining a mesh at creation

`POST /v1/vms` accepts optional `meshId` (`"meshId": "mesh_..."`). The VM is
then created on that mesh's private network, instead of being moved onto it by
a second provider call after it booted. It requires `mesh:write` besides
`vm:write`, and a mesh of the caller's team: a missing scope is 403, and a mesh
that is not the caller's (or the mesh experiment being off for the team) is
404, both before anything is created. Omit it and nothing changes.

`PUT /v1/meshes/{meshId}/vms/{vmId}` is still required: it applies the mesh's
access rules, and the VM is reachable only after it. For a VM created with
`meshId` it finds the membership already recorded, makes no provider attach
call and only applies the rules. The membership is recorded only when the
provider's create answer shows the VM on exactly that network with an address;
otherwise the `PUT` attaches as before, which the provider treats as setting
the same network again. A retry with a different `meshId` (or none) under the
same Idempotency-Key is 409. Forks do not take a `meshId`.

`GET /v1/vms/{vmId}/public-egress` reads, and `PUT` turns on, an existing
VM's public egress: `{ "id": "vm_...", "publicEgress": true }`. Both require
`vm:network` and ownership of the VM. It counts only a rule that allows the
public Internet on every port and whose source is exactly this VM (a create's
`initialNetwork.publicEgress` rule is one). `PUT` adds that rule, deleted with
the VM, only when none is there; it never turns egress off or touches other
rules. A VM created private can join the Internet later this way (cmux Cloud
keeps a copy that resumes another VM's memory private until it cold boots).

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

## Agent keys and client sessions

A cloud agent holds its own credential to start and clean up its own
sandboxes; the team's provider key never leaves the Worker.

`POST /v1/agent-keys` (operator CLI: none yet; the in-VM `cmux sandbox` verbs
use the key) issues an agent key from a credential with `vm:write` that is not
itself an agent key or resource-allowlisted: a session of a team member, an
API key or a service key. The response shows the `cmuxvm_sk_` key once, with
`labels`, `expiresAt`, `maxVms` and `maxUsdPerHour`. The key:

- holds at most `vm:read`, `vm:write` and `vm:exec`, never more than its issuer;
- reaches only VMs labelled `cmux.agent=<its id>` plus any labels its issuer is
  confined to (a service key's `role=chief` stays in force); every VM it creates
  gets those labels, and a label naming another agent is 403. Another agent's
  VM, like another tenant's, is 404;
- has a budget checked on each create: fewer than `maxVms` live VMs (default 5,
  at most 20) and an estimated `maxUsdPerHour` (default 2, at most 50), counting
  0.05 USD per vCPU-hour and 0.0075 USD per GiB-hour of the sizes the provider
  reports (4 vCPU / 8 GiB is 0.26). Over budget is 429 with `budget`
  `agent_vms` or `agent_usd_per_hour`. The check is not atomic with the create:
  concurrent creates can overshoot by the in-flight count; the team quota holds;
- expires after `ttlSeconds` (default 4 h, 60 s to 24 h), never after its issuer;
- cannot fork and cannot issue agent keys.

`DELETE /v1/agent-keys/{keyId}` revokes it at once and deletes its VMs, best
effort; the issuer, an admin key or team admin, or the agent key itself may.
The cron trigger (every 5 minutes) runs the agent reaper
(`src/agents/reaper.ts`): for every agent key that expired or was revoked and is
not cleaned yet, it deletes the key's VMs through the ordinary delete path as
`service:agent-reaper` (audited), revokes their client sessions, and marks the
key cleaned once none is left. It also revokes client sessions whose VM was
deleted while their revoke failed. A run skips itself when the schema check
fails.

`POST /v1/vms/{vmId}/client-session` (`vm:exec`) mints a provider identity
granted only this VM and one Linux user (`linuxUser`, default `ubuntu`), and one
access token. The response shows the token once with `providerVmId`,
`apiBaseUrl` and `ssh` (`<providerVmId>+<user>@beta-ssh.freestyle.sh`, token as
password). This is the one response that names the provider's VM id: the token
is useless without it. Only the identity id is stored
(`cmux_vm.vm_client_sessions`); deleting the VM, or
`DELETE /v1/vms/{vmId}/client-sessions/{sessionId}`, deletes the identity, which
revokes the token and grant.

The operator CLI exposes the same Tenant API:

```sh
cmux-vm client-session create vm_... [--user LINUX_USER] [--token-file PATH]
cmux-vm client-session list vm_...
cmux-vm client-session revoke vm_... vcs_... [--yes]
```

`create` prints the SSH line (`<providerVmId>+<user>@beta-ssh.freestyle.sh`) and
shows the provider token once. Use `--token-file` to write it to a newly created
0600 file on Unix; other platforms use stdout. The token is never logged. Existing paths are refused before minting.
A failed request leaves an empty reservation; inspect the session list and revoke
any newly created session before retrying with a new path.
All commands accept `--json`. Create JSON includes `sshLine` and the token only
without `--token-file`; file mode replaces the token with `tokenFile`. Session
JSON includes only known metadata fields. `list` never returns tokens. `revoke`
names the VM and asks for the session id before revoking it (or accepts `--yes`). The same
commands are available through `cmux vm client-session ...`.

Migrations 0016 (agent columns on `api_keys`, `vm_client_sessions`) and 0017
(its concurrent index) apply through the release runner; grant the Worker role
SELECT, INSERT and UPDATE on `cmux_vm.vm_client_sessions`.

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

Where a create or a wake spends its time is one JSON log line each, in the
shape of the mesh handler's `mesh_vm_attach` line (`wrangler tail`, or the
`tail-production` action). Durations are milliseconds; a line carries the
public VM id (and mesh id) and no tenant, provider id or request body.

- `vm_create`: one per `POST /v1/vms` (or fork) that reached the provider,
  success or failure (`ok`). `recoverMs` (the exact-slug read), `verifyImageMs`
  (the boot image read, in flight with it; null without an approved image),
  both null when the read was not made ("One provider call per create"),
  `imageVariant` (`large` or `base`: which snapshot of an approved image
  booted, or `unlisted` for a retry that recovered a VM from a snapshot its
  entry no longer lists; null without one), `oversized` (a large boot that
  answered bigger than asked and was refused),
  `createMs` (the provider create; null when the VM was recovered),
  `recoverAfterMs` (the read after a failed create; null otherwise),
  `resizeMs` (null without a grow: the VM booted at the size asked),
  `recordMs` (the ownership write),
  `preMs` (handler entry to the first provider call: validation, idempotency,
  quota), `totalMs`, `recovered`, `meshAtCreate` (with `meshId`, `meshJoined`
  and `memberMs` when a mesh was named), and the provider's own
  `providerTotalMs` and `providerTimingsMs` when its create answer has them.
- `vm_create_discard_failed`: a create's answer described a VM that is not
  what was asked (another snapshot, or a large boot bigger than asked) and
  deleting it failed. `vmId` (public), `reason` (`receipt` or `oversized`),
  `status` (the delete's). The VM runs unrecorded until the orphan sweep.
- `vm_start`: one per start or resume whose provider start was called.
  `route` (`start` or `resume`), `stateBefore` (resume reads it; start does
  not, so null), `stateAfter`, `readMs` (resume only), `startMs`, `totalMs`.

Entitlement until billing exists (`src/proofs/tenant-may-create.ts`): outside
production every tenant may create; in production a tenant may create when it is
listed in `DEV_TEST_TENANT_IDS` (dev/test: idle timeout at most 300 s) or in
`MANAFLOW_TEAM_TENANT_IDS` (the manaflow-team flag, cx-b4h.16: product tenant,
no idle cap), or when the request comes with a service key listed in
`CMUX_VM_ENTITLED_SERVICE_IDS` (cmux-platform production: the platform has
already decided the team's plan, so the team it acts for needs no list entry;
the key's teams, scopes and labels still apply). Every other caller gets 402.
These lists are Worker vars in `wrangler.jsonc`; change them in a reviewed commit.

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

The staging database fault switch (`src/db/fault.ts`) holds a share of queries
for a set time inside a window of at most an hour: `latency` then runs them,
`stall` then fails them as a database that stopped answering. It is the Worker
secret `CMUX_VM_DB_FAULT`, off unless set, read only where `ENVIRONMENT` is
`staging`, and it turns itself off at the window's end. Set it with
`cmux-vm.yml` action `db-fault-staging` (`db_fault`: the JSON, or `off`); the
Cloud chaos suite's database-stall scenario does. Each held query logs
`cmux-vm database fault` with its operation.
