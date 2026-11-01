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
Recovery alarms back off for at most 24 hours, then retain the unresolved intent;
the next admitted create after that window, once the marker lookup is still
empty, starts over under a fresh nonce (a late answer for the old nonce is never
adopted). A confirmed no-mutation rejection waits for a new
admitted create. A cancellation committed during identity I/O is rechecked
before VM creation. Mapping supplies routing, not a new VM grant; existing
Stack tenant membership, scoped keys and VM policy still govern access.

The tenant's Stack team is never mirrored as a cmux team: the Stack webhook
sync ignores any team whose server metadata carries the personal tenant marker,
so it cannot appear in team lists or invite members through cmux. New work
(`operate`) also re-reads the tenant's membership (a confirmed solo answer is
reused for 30 seconds) and fails closed when anyone besides the owner is a
member or the read fails; cleanup routing is kept.

The team is created with no Stack creator, so the owner never holds Stack's
creator (admin, invite) defaults; the owner then joins as a plain member, and a
team the owner could not join is deleted. The cmux-vm Worker is the access
chokepoint: for a Stack team whose server metadata carries the marker, a Stack
session is admitted only for the marker's `stack_user`, and an unreadable marker
admits nobody. Another member (for example one invited through cmux.com) gets no
VM access. cmux.com does not yet hide marked teams from its team and billing views.

Hosted tests use fake identity/VM API responses with real owner RPCs and SQLite;
they do not establish a live provider rollout or production billing integration.

## Native receiver image

New VM API machines need a guest binary with the Native receiver and an image that
explicitly starts it. `CLOUD_VM_TRANSPORT=vm-api` alone does not activate the guest.
The dedicated image uses root's `cmux host run --mode system --native-receiver`.
Its receiver waits for an authorized original Cloud enrollment, lifecycle and
network policy; the image contains no enrollment or network credentials. Existing
edge configuration and unbound image smoke checks remain in place.

1. Publish the integrated guest commit through `cmux-tui-artifacts.yml` (a push to
   its owned branch publishes commit-addressed binaries; a helper-branch manual
   dispatch is build-only). Pin that exact published SHA:
   `bun images/cmux-vm/pin-cmux-tui.ts --commit GUEST_SHA --write`.
   Review and commit the resulting lock; do not use `--latest`.
2. Once the reviewed image changes and lock are on the branch admitted by the
   existing development image environment, dispatch:

   ```sh
   gh workflow run cloud-vm-image-bake.yml --repo manaflow-ai/cmux \
     --ref feat-cmux-next -f mode=bake -f native_receiver=true \
     -f agent_tools=true -f keep_snapshot=true -f clones=2 -f probes=true
   ```

   Record the workflow's exact source SHA. The bake rejects an old binary without
   `--native-receiver`; each smoke clone verifies root owns the running service
   and its process has the flag. These checks do not prove an enrolled Native
   connection or a model response.
3. The artifact's `native-image.json` records the immutable snapshot and smoke
   result. It deliberately does not emit `channel-dev.json`, so the direct Cloud
   promotion workflow cannot select it. Register its snapshot as a new exact
   revision in the VM API deployment's existing `VM_BOOT_IMAGES` catalog, scoped
   to the Cloud service. Preserve every other catalog entry. Configure the Cloud
   deployment's `CLOUD_VM_API_IMAGE` and `CLOUD_VM_API_IMAGE_REVISION` to that entry,
   alongside its existing service identity and network configuration. The
   development deployment owner applies these through its approved deployment
   route; no provider credentials belong in this repo or in a command line.
4. Create a fresh supported VM through Cloud and verify the returned boot image
   revision, enrollment, Native connection and agent reply. Existing VMs keep
   their images. Rollback changes only the VM API selectors to the prior revision.

Without `native_receiver=true` / `--native-receiver`, image startup, smoke and
direct Cloud candidate promotion are unchanged. Native images currently support
development `bake` mode only, not `repro` or `prod-copy`.
