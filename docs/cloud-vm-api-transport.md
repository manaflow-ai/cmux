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

Personal owners still need real Stack-team provisioning before they can use
this transport. Hosted tests use fake API responses and owner RPCs; they do not
establish a live provider rollout or production billing integration.
