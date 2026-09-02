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

Requests for the removed `websocket` and `ssh` attach transports fail with `409 vm_attach_transport_unsupported`. The response lists `details.supportedTransports: ["cmux-remote"]`. `cmux vm attach`, `cmux vm shell`, `cmux vm new`, `cmux vm base open`, and the Machines panel all use this path. `cmux vm ssh` is a user-facing alias for the same managed workspace path, not an SSH gateway. `cmux vm ssh-info` has no endpoint to print.

## Image behavior

The checked-in image manifest is the source of truth for images that current cmux can create. Clients normally request a machine kind and let the server select that kind's default manifest entry. A client-requested image must also be in the manifest unless a local development override explicitly permits an unlisted image.

The manifest retains old image entries for rollback and audit history. An old entry made for `cmuxd-remote` does not gain `cmux-remote` support because it is listed. Current create and restore workflows install and start cmux-tui. A machine made by a removed legacy driver cannot serve the current transport and must be recreated.

## Capability and error guidance

1. Run `cmux vm ls --json`. Treat each machine's `capabilities` object as the server answer for snapshot, restore, and fork operations.
2. Use `cmux-remote` for every attach. Do not retry a rejected SSH or legacy WebSocket transport against the same machine.
3. `vm_attach_transport_unsupported` means the requested session transport is not supported. Follow `details.supportedTransports`.
4. `vm_operation_unsupported` means the provider cannot perform the requested checkpoint operation. Preserve the machine and use an operation whose capability is true.
5. If `vm tree` returns no workspaces or terminals after create, inspect daemon installation, enrollment, routing, and health. Do not switch to a retired transport or change the provider registry from the client.

## Sources of truth

The provider registry and capability defaults are in `web/services/vms/drivers/index.ts`. Provider identifiers are in `web/services/vms/drivers/types.ts`. Freestyle declares its attach transport in `web/services/vms/drivers/freestyle.ts`. Image eligibility and defaults are in `web/services/vms/images/manifest.json`.
