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
- SSH targets run noninteractive `ssh -T` with strict host-key checking, disabled agent forwarding, disabled port forwarding, and remote `binary relay --session session`.
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

The successful `hello` response envelope may advertise additive string capabilities. `machine-lifecycle-v1` enables `machine_lifecycle_snapshot`, `rename_machine`, `delete_machine`, `restore_machine`, and `purge_machine`. `workspace-lifecycle-v1` enables `workspace_snapshot`, `rename_workspace`, `delete_workspace`, `restore_workspace`, and `purge_workspace`. `workspace-mirror-authority-v1` lets `open_machine` bind a provider-owned workspace catalog to the selected mux. `connect-external-machine-v1` enables the typed `connect_external_machine` mutation. The client shows and sends that mutation only when the capability was negotiated for the control generation and the current snapshot sets `connect_external_machine: true`. Missing or unknown capabilities are safe: a client must not send a gated request unless the matching capability was advertised for that control generation. A client connected to a legacy or rolled-back v1 provider therefore uses the base snapshot and hides managed lifecycle actions. Response-envelope metadata accepts unknown fields, so legacy clients ignore capabilities advertised by a newer provider.

The Unix connector opens the configured socket for control and each machine stream. The command connector starts one control process and a new stream process per ticket. The SSH connector starts its control process with `ControlMaster=yes` and each stream with `ControlMaster=no`, all using one unpredictable socket path inside a mode-0700 directory. A new provider generation receives a new bearer and SSH master path. Closing a connection terminates its child process; releasing the generation removes the private directory.

The local Cloud launch may compose a separate v0 catalog over the v1 catalog. Local descriptors use process-local keys starting at `2^63`; provider keys grow upward from one. The overlay handles local switches and temporary targets itself when provider-owned external connect is unavailable. When both provider signals enable external connect, the same footer routes its opaque input to `connect_external_machine`; the local catalog does not parse or store that input. A provider refresh cannot evict an active local session. Native Unix-provider mode does not construct this local overlay.

V1 implements these requests:

| Operation | Result |
| --- | --- |
| `hello` | Provider identity and negotiated version |
| `snapshot` | Scopes, selected scope and machine, ordered machines, capabilities, actions, notice, and monotonic revision |
| `open_machine` | Provider connection id, an expiring one-use transport ticket, and, when explicitly requested, the stable per-mux workspace mirror authority for provider-owned workspaces |
| `select_scope` | A replacement snapshot for one personal or team scope |
| `create_machine` | New machine id, revision, and optional notice |
| `connect_external_machine` | Selected enrolled machine id, revision, and optional notice when `connect-external-machine-v1` is advertised |
| `machine_lifecycle_snapshot` | Active and recoverable machines when `machine-lifecycle-v1` is advertised |
| `rename_machine`, `delete_machine`, `restore_machine`, `purge_machine` | Version-fenced machine lifecycle mutations when `machine-lifecycle-v1` is advertised |
| `create_workspace` | Revision and optional notice for isolated or host mode |
| `workspace_snapshot` | Active and recoverable workspaces when `workspace-lifecycle-v1` is advertised |
| `rename_workspace`, `delete_workspace`, `restore_workspace`, `purge_workspace` | Version-fenced workspace lifecycle mutations when `workspace-lifecycle-v1` is advertised |
| `invoke_action` | Revision plus optional notice, URL, and selected scope or machine |
| `close_machine` | Revision after idempotently closing one provider connection |

The provider emits `snapshot_changed`, `connection_closed`, and `notice` events. Snapshot changes are invalidations: the client fetches the latest snapshot instead of applying deltas. A bounded full subscriber queue may coalesce invalidations without unsubscribing. Provider disconnect cancels pending requests and closes subscribers.

Snapshots contain provider-stable opaque ids. Scopes distinguish personal and team contexts and advertise `can_admin`. Machines advertise status, connectability, and whether workspace creation belongs to the mux session or provider. Provider-owned creation declares supported `isolated` and `host` modes. Generic actions contain text, email, or integer fields with validation bounds, so team membership, verified domains, seat limits, billing, and future provider features do not add cloud-specific UI code.

`connect_external_machine` carries the selected `scope_id`, a provider-opaque `specifier`, and an opaque `mutation_id`. The specifier may be a host address or a human-readable pairing code. cmux trims only surrounding prompt whitespace, retains internal whitespace and punctuation, never passes it to a shell, and limits it to 512 UTF-8 bytes without control bytes. Providers validate its domain meaning and authorize enrollment against the exact scope in the request. A provider must bind `mutation_id` to that scope and the exact request, select the enrolled machine before replying, and return the same result for an exact replay. Reusing one mutation id with a different scope or specifier must fail with `conflict`.

`open_machine` does not return an upstream address or general cloud credentials. It returns a short-lived bearer ticket. The client opens a fresh stream through the generation's connector and sends exactly one transport handshake containing the generation bearer and ticket. On acceptance, that transport becomes the normal protocol-v9 JSON-lines stream consumed by `RemoteSession`. Tickets are single use; close, expiry, control disconnect, or provider cancellation closes the corresponding upstream connection.

When a machine declares provider-owned workspaces, the provider must advertise `workspace-mirror-authority-v1`. After seeing that capability, the client sets `workspace_mirror_authority: true` in `open_machine`; the provider includes the result field only for that opt-in request. An older client omits the request field, so a new provider can return an upgrade-required error without sending a result that the strict v1 client cannot decode. An updated client connected to a legacy or rolled-back provider sees no capability and refuses to open a provider-owned machine before sending an incompatible request.

The authority is a random value of at least 32 bytes scoped to one long-lived mux. The provider persists it server-side, provisions the same value as `CMUX_PROVIDER_WORKSPACE_AUTHORITY` when starting that mux, and returns it to every authorized team member who opens the machine. It stays stable across frontend reconnects, concurrent team members, and mux software upgrades. A provider rotates it only when it can restart the mux generation and update its persisted record atomically. A session-owned machine must omit the result field. The client rejects either a missing provider-owned authority or an authority attached to a session-owned machine.

A provider-authorized mux starts in provider-managed mode before accepting its first control connection. Ordinary rename and close commands are blocked immediately. The provider frontend includes the authority only in the private mirror handshake and post-provider rename or close commit; the mux compares it in constant time. This prevents an ordinary control-socket client from claiming ownership or forging a mirror commit after a provider mutation succeeds.

Control requests time out after 30 seconds. Machine open may wait up to three minutes for provisioning or wake. Control frames are limited to 1 MiB, while machine transport frames are limited to 64 MiB for browser and scrollback payloads. Opaque ids, external-machine specifiers, and bearer values are bounded. Bearer, external-machine specifier, and mux-authority debug output is redacted. Their owned allocations and serialized control buffers are overwritten when no longer needed.

On Linux, a mux with `CMUX_PROVIDER_WORKSPACE_AUTHORITY` must set `PR_SET_DUMPABLE=0` before retaining the authority, overwrite the value in the original environment block, and unset the variable before spawning terminals or helpers. Startup fails closed when the non-dumpable state cannot be established. This blocks same-UID host-workspace shells from reading the authority through `/proc/<pid>/environ`, `/proc/<pid>/mem`, or ptrace. The VM's root user remains trusted and can replace or inspect the mux process.

A cloud implementation may authenticate at the SSH edge, project a team-scoped catalog, create or wake a VM, and proxy `cmux-tui relay` from that VM. The app must receive only descriptors, capabilities, action results, and an opened message transport. Cloud credentials, billing decisions, and provider API objects must not enter `App`, `RemoteSession`, or the shared rail renderer.

V1 lets a provider withdraw a machine, change status, revoke an open connection, and use capability checks to hide unsupported actions such as `New VM`. User-owned machines and cloud VMs use the same descriptor and open boundary. The reference client preserves process-local keys across snapshots by reconciling provider-stable ids.
