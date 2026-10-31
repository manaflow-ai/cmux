# Cloud VM API transport

CloudDO records `direct` or `vm-api` on each new machine, snapshot and provider
intent. Rows without a marker use the existing direct driver. Power, restore,
guest exec, idle pauses, state checks, proxy refresh, cancelled-create cleanup
and orphan reporting use the recorded route. Changing deployment defaults does
not migrate existing resources. Unknown markers fail closed.

The deployment defaults to `direct`. An operator can select `vm-api` for new
machines with these Worker settings:

| Setting | Value |
| --- | --- |
| `CLOUD_VM_TRANSPORT` | `vm-api` |
| `CLOUD_VM_API_ORIGIN` | Bare HTTPS origin of the tenant VM API |
| `CLOUD_VM_API_SERVICE_KEY` | Existing service credential, supplied as a Worker secret |
| `CLOUD_VM_API_IMAGE` | Public approved-image ID |
| `CLOUD_VM_API_IMAGE_REVISION` | Exact approved-image revision |

Keep each transport's configuration available while it has resources. An API
record whose configuration or tenant mapping is unavailable is refused; it
never falls back to the direct provider. Both routes keep this environment's
existing `CLOUD_NAME_PREFIX` check.

The API service requires the `role=cloud` label, the allowed teams, and the
scopes needed by the existing Cloud actions: `vm:read`, `vm:write`, `vm:files`,
`vm:exec`, `vm:network`, `snapshot:read` and `snapshot:write`. Configure its
approved image and HTTPS proxy destination in the VM API's operator policy.
Cloud's current public egress is requested explicitly and its receipt checked.

TeamDO supplies the canonical Stack tenant; callers cannot provide a substitute
tenant, endpoint or credential. Deleted teams retain routing for cleanup only.
Discovery requests `createdBy=caller` and exact Cloud labels, so a member's
matching labels cannot establish service creation. Credentials and transport
markers stay outside public machine/snapshot views. HTTP redirects are not
followed, and errors omit response bodies, guest stdin and proxy credentials.

The existing Cloud operation catalog serves app, CLI and MCP unchanged. This is
an operator deployment choice, not a user preference or a new action. Cloud's
plan/approval checks and the VM API's entitlement, quota, idle and network
policies still apply. In particular, the API adapter asks for no provider idle
timer; dev/test tenants capped at 300 seconds cannot use that policy.

On the first admitted personal Cloud create, TeamDO provisions a real Stack
tenant using its existing server credential. The current personal owner and
canonical Stack user are checked in the configured project. A private intent
and nonce live in TeamDO's SQLite effect ledger; matching server-only metadata
and the solo creator membership confirm the returned tenant. Selected teams,
names and client-writable metadata cannot establish that mapping.

Provisioning follows Cloud admission, approval, plan and bind-configuration
checks. Reads, cleanup and sign-in never create an identity team. Concurrent
creates share one owner flight. Once a POST may have happened, a restart or
lost answer recovers by its exact marker; an empty lookup never resends it.
Recovery alarms back off for at most 24 hours, then retain the unresolved intent
for a later explicit retry. A confirmed no-mutation rejection waits for a new
admitted create. A cancellation committed during identity I/O is rechecked
before VM creation. Mapping supplies routing, not a new VM grant; existing
Stack tenant membership, scoped keys and VM policy still govern access.

Hosted tests use fake identity/VM API responses with real owner RPCs and SQLite;
they do not establish a live provider rollout or production billing integration.

## Native receiver activation

The root supervisor keeps its lifetime-only channel unless the VM image is
started with `CLOUD_VM_TRANSPORT=vm-api`. This is an explicit deployment
capability marker: direct/Freestyle machines do not have a confirmed mesh
membership and must never advertise a Native receiver. The marker does not
grant authority; the receiver still waits for the VM's authenticated policy
read and the backend's `transport=vm-api` plus confirmed `network` row before
it can report `READY`.

Enable the marker only on the approved VM API image after configuring the
settings above. The current image/deploy wiring does not inject this marker;
that must be added as part of the rollout. A signed NEXT DEV rollout remains
required to prove create, bind, receiver `READY`, connect-info/token and
encrypted daemon/SSH traffic; the hosted tests do not replace that live proof.
