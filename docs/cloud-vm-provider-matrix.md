# Cloud VM provider and transport matrix

This compatibility reference describes the provider registry and machine behavior in the current `main` branch. The registry contains one provider, Freestyle. Every machine that current cmux can create uses the cmux-tui remote daemon and the `cmux-remote` session transport.

## Matrix

| Provider | Session transport | Snapshot | Restore | Fork |
| --- | --- | --- | --- | --- |
| Freestyle | `cmux-remote` only | Yes | Yes | No |

The API reports this checkpoint capability set in `cmux vm ls --json` as `capabilities.snapshot`, `capabilities.restore`, and `capabilities.fork`. Clients must use these fields instead of inferring support from an image name.

Freestyle machines support cmux-tui session operations, including `vm tree`, `vm open`, `vm terminal send|read|wait`, and `vm exec`. The `cmux-remote` protocol carries the authoritative workspace and terminal state. Its WebSocket carrier can use a private VPC address or a public IPv6 address, depending on the network posture recorded for the machine. This carrier detail does not create a separate `websocket` session transport.

## Attach behavior

Request `cmux-remote` from `POST /api/vm/:id/attach-endpoint`. The response contains the daemon route, lease token, session name, optional daemon build, and an enrollment invitation when the client device is not enrolled.

Legacy attach requests with no transport, or with `transport: "websocket"`, fail with `409 vm_attach_transport_unsupported`; the response lists `details.supportedTransports: ["cmux-remote"]`. An explicit `transport: "ssh"` is rejected earlier as an unknown request transport (`400`). `cmux vm attach`, `cmux vm shell`, `cmux vm new`, `cmux vm base open`, and the Machines panel all use this path. `cmux vm ssh` remains a legacy SSH command and fails for current Freestyle because the backend has no SSH endpoint; use `cmux vm shell`, `cmux vm attach`, `cmux vm tui`, or `cmux vm open` for cmux-remote. `cmux vm ssh-info` remains a CLI/debug verb, but the current Freestyle backend has no SSH endpoint to print.

## Image behavior

The checked-in image manifest is the source of truth for images that current cmux can create. Clients normally request a machine kind and let the server select that kind's default manifest entry. A client-requested image must also be in the manifest unless a local development override explicitly permits an unlisted image.

The manifest retains old image entries for rollback and audit history. Listing an image does not change its guest contents, so a legacy snapshot without cmux-tui is not itself cmux-remote-ready; attach can install or heal cmux-tui, and a failed repair requires recreation from a current manifest entry. Current create relies on the baked image and supervisor. Restore starts from the snapshot and best-effort heals the daemon.

### Image and tooling state

The checked-in manifest selects `freestyle-cmux-devbox-20260902e` as the
current `base` default. It records the pinned agent versions and the baked
cmux-tui commit. The validated desktop entries (`freestyle-cmux-devbox-20260902h`
and the sized `i-*` entries) are reference bakes from another Freestyle
account, so this deployment does not advertise `desktop` in `limits.imageKinds`.
Current Freestyle creates use the baked tools and supervisor; create does not
install tools after boot. The work user is `ubuntu`; the pinned agent binaries
are linked in `/usr/local/bin`. Older snapshots can need attach-time healing or
recreation from a current manifest entry.

Provider image rules are not interchangeable. Before adding a provider row,
check its official image documentation:

- [Freestyle base snapshots](https://www.freestyle.sh/docs/vms/base-snapshots)
  capture the source VM's memory and disk, and new snapshots are private to the
  account that creates them.
- [Daytona snapshots](https://www.daytona.io/docs/snapshots/) require an
  existing image reference for Linux VM snapshots; Dockerfile and declarative
  builds are not supported for that VM path.
- [E2B template builds](https://e2b.dev/docs/sdk-reference/cli/v1.0.9/template)
  build a sandbox template from a Dockerfile. The [JavaScript template API](https://e2b.dev/docs/sdk-reference/js-sdk/v2.4.3/template)
  also supports Dockerfile and code templates.
- [Blaxel sandbox templates](https://docs.blaxel.ai/Sandboxes/Templates)
  require a custom image to include the sandbox API, unless the SDK builder
  injects it during the build.

## Capability and error guidance

1. Run `cmux vm ls --json`. Treat each machine's `capabilities` object as the server answer for snapshot, restore, and fork operations.
2. Use `cmux-remote` for every attach. Do not retry a rejected SSH or legacy WebSocket transport against the same machine.
3. `vm_attach_transport_unsupported` means the requested session transport is not supported. Follow `details.supportedTransports`.
4. `vm_operation_unsupported` means the provider cannot perform the requested operation. Preserve the machine and use an operation whose capability is true, or follow the deployment-specific action in the error.
5. If `vm tree` returns no workspaces or terminals after create, inspect daemon installation, enrollment, routing, and health. Do not switch to a retired transport or change the provider registry from the client.

## Sources of truth

The provider registry and capability defaults are in `web/services/vms/drivers/index.ts`. Provider identifiers are in `web/services/vms/drivers/types.ts`. Freestyle declares its attach transport in `web/services/vms/drivers/freestyle.ts`. Image eligibility and defaults are in `web/services/vms/images/manifest.json`.
