# Machine Provider Contract

This document versions the client-side machine catalog boundary. It is separate from the mux control protocol: a selected machine still speaks the implemented cmux protocol v9, while a machine provider decides which machines exist and how to open that protocol transport.

## Versions

| Contract | Status | Meaning |
| --- | --- | --- |
| `machine-provider-v0` | implemented | In-process static catalog backed by `cmux-tui.json` Unix and SSH targets |
| `machine-provider-v1` | implemented | Authenticated dynamic catalog, scopes, lifecycle actions, and one-use machine transports |

Provider versions do not change `identify.protocol`. V1 negotiates its own version before returning a catalog and does not reuse the mux protocol number.

## Common boundary

The TUI depends on three provider concepts:

1. A snapshot contains ordered machine descriptors, the active machine, and create/connect capabilities.
2. An action switches, creates, or connects a machine without putting provider-specific logic in the rail renderer.
3. Opening a machine returns independently owned complete-message reader and writer halves for `RemoteSession`.

A descriptor has a process-local key, a provider-stable id, a display name, an optional subtitle, and one of `running`, `connecting`, `sleeping`, `stopped`, or `unavailable`. Keys route UI actions only and must not be persisted. Provider-stable ids own deduplication and reconnection.

The app owns focus, selection, the shared rail renderer, terminal mirrors, and minimum layout sizes. A provider owns discovery, authentication, authorization, lifecycle operations, and connection establishment. A connector owns message framing and process cleanup. The mux server remains unaware of the catalog.

## Implemented v0

`machine-provider-v0` is the current `MachineRuntime` implementation:

- It inserts the current session as `current`, then appends valid static config entries.
- Unix targets open an existing local session socket.
- SSH targets run `ssh -T` and remote `binary relay --session session`.
- Unix and SSH process streams use JSON-lines framing. The session layer receives complete JSON message strings and does not own the byte-stream transport.
- It advertises connect capability and does not advertise create capability.
- `Connect machine` accepts `host` or `user@host`, creates a process-local SSH target with default session `main`, and does not persist it.
- Catalog changes, cloud VM creation, wake/suspend, team membership, quotas, and billing are outside v0.

The static connector validates the selected server through the normal protocol-v9 `identify` exchange. EOF cancels pending requests and closes the connector process. Switching away performs the normal terminal input drain before the client attaches to the next session.

## Implemented v1

Start the client with one provider connector:

```text
cmux-tui --machine-provider <socket>
cmux-tui --machine-provider-command <program> [arg ...] --
cmux-tui --cloud [--cloud-host <host>] [--cloud-user <user>]
                   [--cloud-port <port>] [--cloud-identity <path>]
```

The modes are mutually exclusive. The direct-command form preserves the supplied argv without a shell and appends exactly `control` or `stream`. The cloud form defaults to `cmux.cloud`, uses a private OpenSSH ControlMaster, and runs exactly `cmux provider control` or `cmux provider stream` remotely. Host, user, port, and identity file have config equivalents under `machine_provider.cloud`; CLI values take precedence. An enabled cloud config is inert when an explicit Unix-socket or command connector is selected.

The connector generates a fresh cryptographically random bearer for every control generation. It is absent from process arguments and environment variables, and diagnostics redact it. The first control request must be `hello`. It carries that bearer, client name and version, and supported provider versions. A provider accepts the bearer for that authenticated transport generation and requires it on later ticket handshakes. The provider rejects any other first request, a second `hello`, or an unsupported version. After authentication, the control transport carries bounded JSON-lines request, response, and event envelopes identified by `cmux.machine-provider` and version `1`.

The Unix connector opens the configured socket for control and each machine stream. The command connector starts one control process and a new stream process per ticket. The SSH connector starts its control process with `ControlMaster=yes` and each stream with `ControlMaster=no`, all using one unpredictable socket path inside a mode-0700 directory. A new provider generation receives a new bearer and SSH master path. Closing a connection terminates its child process; releasing the generation removes the private directory.

V1 implements these requests:

| Operation | Result |
| --- | --- |
| `hello` | Provider identity and negotiated version |
| `snapshot` | Scopes, selected scope and machine, ordered machines, capabilities, actions, notice, and monotonic revision |
| `open_machine` | Provider connection id and an expiring one-use transport ticket |
| `select_scope` | A replacement snapshot for one personal or team scope |
| `create_machine` | New machine id, revision, and optional notice |
| `create_workspace` | Revision and optional notice for isolated or host mode |
| `invoke_action` | Revision plus optional notice, URL, and selected scope or machine |
| `close_machine` | Revision after idempotently closing one provider connection |

The provider emits `snapshot_changed`, `connection_closed`, and `notice` events. Snapshot changes are invalidations: the client fetches the latest snapshot instead of applying deltas. A bounded full subscriber queue may coalesce invalidations without unsubscribing. Provider disconnect cancels pending requests and closes subscribers.

Snapshots contain provider-stable opaque ids. Scopes distinguish personal and team contexts and advertise `can_admin`. Machines advertise status, connectability, and whether workspace creation belongs to the mux session or provider. Provider-owned creation declares supported `isolated` and `host` modes. Generic actions contain text, email, or integer fields with validation bounds, so team membership, verified domains, seat limits, billing, and future provider features do not add cloud-specific UI code.

`open_machine` does not return credentials or an upstream address. It returns a short-lived bearer ticket. The client opens a fresh stream through the generation's connector and sends exactly one transport handshake containing the generation bearer and ticket. On acceptance, that transport becomes the normal protocol-v9 JSON-lines stream consumed by `RemoteSession`. Tickets are single use; close, expiry, control disconnect, or provider cancellation closes the corresponding upstream connection.

Control requests time out after 30 seconds. Machine open may wait up to three minutes for provisioning or wake. Control frames are limited to 1 MiB, while machine transport frames are limited to 64 MiB for browser and scrollback payloads. Opaque ids and bearer values are bounded, bearer debug output is redacted, and serialized credential buffers are cleared after writes.

A cloud implementation may authenticate at the SSH edge, project a team-scoped catalog, create or wake a VM, and proxy `cmux-tui relay` from that VM. The app must receive only descriptors, capabilities, action results, and an opened message transport. Cloud credentials, billing decisions, and provider API objects must not enter `App`, `RemoteSession`, or the shared rail renderer.

V1 lets a provider withdraw a machine, change status, revoke an open connection, and use capability checks to hide unsupported actions such as `New VM`. User-owned machines and cloud VMs use the same descriptor and open boundary. The reference client preserves process-local keys across snapshots by reconciling provider-stable ids.
