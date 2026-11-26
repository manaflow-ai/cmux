# Machine Provider Contract

This document versions the client-side machine catalog boundary. It is separate from the mux control protocol: a selected machine still speaks the implemented cmux protocol v12, while a machine provider decides which machines exist and how to open that protocol transport.

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

The static connector validates the selected server through the normal protocol-v12 `identify` exchange. EOF cancels pending requests and closes the connector process. Switching away performs the normal terminal input drain before the client attaches to the next session.

## Implemented v1

Start the client with one provider connector:

```text
cmux --machine-provider <socket>
cmux --machine-provider-command <program> [arg ...] --
cmux --cloud [--cloud-host <host>] [--cloud-user <user>]
                   [--cloud-port <port>] [--cloud-identity <path>]
```

The modes are mutually exclusive. The direct-command form preserves the supplied argv without a shell and appends exactly `control` or `stream`. The cloud form defaults to `cmux.cloud`, uses a private OpenSSH ControlMaster, and runs exactly `cmux provider control` or `cmux provider stream` remotely. Host, user, port, and identity file have config equivalents under `machine_provider.cloud`; CLI values take precedence. An enabled cloud config is inert when an explicit Unix-socket or command connector is selected.

The connector generates a fresh cryptographically random bearer for every control generation. It is absent from process arguments and environment variables, and diagnostics redact it. The first control request must be `hello`. It carries that bearer, client name and version, and supported provider versions. A provider accepts the bearer for that authenticated transport generation and requires it on later ticket handshakes. The provider rejects any other first request, a second `hello`, or an unsupported version. After authentication, the control transport carries bounded JSON-lines request, response, and event envelopes identified by `cmux.machine-provider` and version `1`.

The successful `hello` response envelope may advertise additive string capabilities. `machine-lifecycle-v1` enables `machine_lifecycle_snapshot`, `rename_machine`, `delete_machine`, `restore_machine`, and `purge_machine`. `workspace-lifecycle-v1` enables `workspace_snapshot`, `rename_workspace`, `delete_workspace`, `restore_workspace`, and `purge_workspace`. `workspace-mirror-authority-v1` lets `open_machine` bind a provider-owned workspace catalog to the selected mux. `durable-notices-v1` enables `subscribe_notices` and `acknowledge_notice`. `connect-external-machine-v1` enables the typed `connect_external_machine` mutation. `client-capability-negotiation-v1` lets an updated client call `negotiate_client_capabilities` immediately after `hello` and before its first snapshot. The provider returns the accepted subset and scopes it to that control generation. Missing or unknown capabilities are safe: a client must not send a gated request unless the matching capability was advertised for that control generation. A client connected to a legacy or rolled-back v1 provider therefore uses the base snapshot and hides managed lifecycle actions. Response-envelope metadata accepts unknown fields, so legacy clients ignore capabilities advertised by a newer provider.

`provider-action-targets-v1` is a client capability. A provider may serialize non-scope `ProviderAction.target` values only after accepting that capability. Before negotiation, or when an older client proceeds directly from `hello` to `snapshot`, the provider must remove targeted actions and omit the default `scope` target from retained actions. The same filtering applies to every `SnapshotResult`, including snapshots nested in `select_scope`. This preserves strict older v1 decoders, which reject an unknown `target` field. Updated clients also discard unnegotiated targeted actions from a nonconforming provider. `connection-progress-v1` is an optional client capability that permits advisory `connection_progress` events while `open_machine` is in flight.

The Unix connector opens the configured socket for control and each machine stream. The command connector starts one control process and a new stream process per ticket. The SSH connector starts its control process with `ControlMaster=yes` and each stream with `ControlMaster=no`, all using one unpredictable socket path inside a mode-0700 directory. A new provider generation receives a new bearer and SSH master path. Closing a connection terminates its child process; releasing the generation removes the private directory.

The local Cloud launch may compose a separate v0 catalog over the v1 catalog. Local descriptors use process-local keys starting at `2^63`; provider keys grow upward from one. The overlay handles local switches and temporary targets itself when provider-owned external connect is unavailable. When both provider signals enable external connect, the same footer routes its opaque input to `connect_external_machine`; the local catalog does not parse or store that input. A provider refresh cannot evict an active local session. Native Unix-provider mode does not construct this local overlay.

V1 implements these requests:

| Operation | Result |
| --- | --- |
| `hello` | Provider identity and negotiated version |
| `negotiate_client_capabilities` | Accepted client capabilities for this control generation |
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
| `subscribe_notices` | Resume one consumer's durable notice stream when `durable-notices-v1` is advertised |
| `acknowledge_notice` | Confirm the exact delivered notice after it was painted when `durable-notices-v1` is advertised |
| `invoke_action` | Revision plus optional notice, URL, and selected scope or machine |
| `close_machine` | Revision after idempotently closing one provider connection |

`create_machine`, `create_workspace`, `invoke_action`, and every rename,
delete, restore, or purge request carry a provider-opaque `mutation_id`. A
provider must use it as the durable idempotency key for one logical mutation:
repeating the same id and request returns the committed result, while reusing
the id with a different operation or payload returns `conflict`. Lifecycle
mutations also carry the descriptor's `expected_version`; a fresh request with
a stale version returns `conflict`, but replay lookup precedes that fence so a
lost successful response remains recoverable. The successful response is the
durability boundary. A later snapshot refresh failure must not turn an
accepted mutation into a failed mutation or cause the client to issue it
again.

The provider emits `snapshot_changed`, `connection_closed`, `notice`, and `connection_progress` events. Snapshot changes are invalidations: the client fetches the latest snapshot instead of applying deltas. A bounded full subscriber queue may coalesce invalidations without unsubscribing. Provider disconnect cancels pending requests and closes subscribers.

When the client offers `connection-progress-v1` in `negotiate_client_capabilities` and the provider accepts it, the provider may emit `connection_progress` events while an `open_machine` request is in flight. Each event carries the machine id and a short human-readable stage ("resuming the machine", "waiting for sshd") that the client renders on the connection interstitial. The events are advisory and additive: they never replace the `open_machine` response, arrive only between the request and its response for that machine, and a client that did not negotiate the capability receives none. Ordering within one open is the provider's narration order; a client must tolerate zero events, and must clear rendered progress when the open settles either way.

When `durable-notices-v1` is negotiated, each durable `notice` event includes additive outer `delivery` metadata with the stable notice id and the consumer's monotonic sequence. Legacy clients ignore the outer field and continue decoding the unchanged notice payload. After capability negotiation, a durable-notice client persists one random consumer id per workspace state root, holds exclusive ownership of that identity for the rest of its process lifetime, reuses it across control reconnects and process restarts, subscribes once per generation, and accepts only exact sequence order. A second live client using the same state root fails before subscribing so it cannot advance the shared cursor. Clients connected to providers without this capability do not access or lease durable notice identity state. The `subscribe_notices` response reports the consumer's last acknowledged sequence. Replayed deliveries may precede that response, so the client buffers them without exposing them until it can validate the first replay as the next sequence after the reported cursor. The provider keeps at most one notice in flight for each consumer until the matching id and sequence are acknowledged.

The TUI acknowledges a durable notice only after Ratatui successfully paints it. Keyboard, paste, scroll, and mouse presses outside the banner still reach their normal handlers when they dismiss it. A press on the banner row is consumed so hidden status-bar targets cannot activate. A failed acknowledgement reconnects the control generation, resubscribes with the same consumer id, and suppresses redisplay of a notice already painted in that process. Both the pending queue and recent-delivery ledger are bounded.

Snapshots contain provider-stable opaque ids. Scopes distinguish personal and team contexts and advertise `can_admin`. Machines advertise status, connectability, and whether workspace creation belongs to the mux session or provider. Provider-owned creation declares supported `isolated` and `host` modes. Generic actions contain text, email, or integer fields with validation bounds, so team membership, verified domains, seat limits, billing, and future provider features do not add cloud-specific UI code.

`connect_external_machine` carries the selected `scope_id`, a provider-opaque `specifier`, and an opaque `mutation_id`. The specifier may be a host address or a human-readable pairing code. cmux trims only surrounding prompt whitespace, retains internal whitespace and punctuation, never passes it to a shell, and limits it to 512 UTF-8 bytes without control bytes. Providers validate its domain meaning and authorize enrollment against the exact scope in the request. A provider must bind `mutation_id` to that scope and the exact request, select the enrolled machine before replying, and return the same result for an exact replay. Reusing one mutation id with a different scope or specifier must fail with `conflict`.

`open_machine` does not return an upstream address or general cloud credentials. It returns a short-lived bearer ticket. The client opens a fresh stream through the generation's connector and sends exactly one transport handshake containing the generation bearer and ticket. On acceptance, that transport becomes the normal protocol-v12 JSON-lines stream consumed by `RemoteSession`. Tickets are single use; close, expiry, control disconnect, or provider cancellation closes the corresponding upstream connection.

When a machine declares provider-owned workspaces, the provider must advertise `workspace-mirror-authority-v1`. After seeing that capability, the client sets `workspace_mirror_authority: true` in `open_machine`; the provider includes the result field only for that opt-in request. An older client omits the request field, so a new provider can return an upgrade-required error without sending a result that the strict v1 client cannot decode. An updated client connected to a legacy or rolled-back provider sees no capability and refuses to open a provider-owned machine before sending an incompatible request.

The authority is a random value of at least 32 bytes scoped to one long-lived mux. The provider persists it server-side, provisions the same value as `CMUX_PROVIDER_WORKSPACE_AUTHORITY` when starting that mux, and returns it to every authorized team member who opens the machine. It stays stable across frontend reconnects, concurrent team members, and mux software upgrades. On Linux, a root-owned manager may rotate it live through [`provider-management-v1`](provider-management.md) using mux-generation and authority-generation fences. Without that protocol, rotation requires an atomic mux restart and persisted-record update. A session-owned machine must omit the result field. The client rejects either a missing provider-owned authority or an authority attached to a session-owned machine.

V1 treats that shared value as a bearer capability. Any frontend that receives it
and can reach the mux socket can invoke provider-authority commands directly.
vNext must replace the shared bearer with a provider-authenticated channel or
scoped per-frontend or per-operation capabilities.

A provider-authorized mux starts in provider-managed mode before accepting its first control connection. Ordinary rename and close commands are blocked immediately. The provider frontend includes the authority only in the private mirror handshake and post-provider rename or close commit; the mux compares it in constant time. This prevents an ordinary control-socket client from claiming ownership or forging a mirror commit after a provider mutation succeeds.

Control requests time out after 30 seconds. Machine open may wait up to five minutes for provisioning or wake. Control frames are limited to 1 MiB, while machine transport frames are limited to 64 MiB for browser and scrollback payloads. Opaque ids, external-machine specifiers, and bearer values are bounded. Bearer, external-machine specifier, and mux-authority debug output is redacted. Their owned allocations and serialized control buffers are overwritten when no longer needed.

On Linux, a mux with `CMUX_PROVIDER_WORKSPACE_AUTHORITY` must set `PR_SET_DUMPABLE=0` before retaining the authority, overwrite the value in the original environment block, and unset the variable before spawning terminals or helpers. Startup fails closed when the non-dumpable state cannot be established. This blocks same-UID host-workspace shells from reading the authority through `/proc/<pid>/environ`, `/proc/<pid>/mem`, or ptrace. The VM's root user remains trusted and can replace or inspect the mux process.

A cloud implementation may authenticate at the SSH edge, project a team-scoped catalog, create or wake a VM, and proxy `cmux relay` from that VM. The app must receive only descriptors, capabilities, action results, and an opened message transport. Cloud credentials, billing decisions, and provider API objects must not enter `App`, `RemoteSession`, or the shared rail renderer.

V1 lets a provider withdraw a machine, change status, revoke an open connection, and use capability checks to hide unsupported actions such as `new machine`. User-owned machines and cloud VMs use the same descriptor and open boundary. The reference client preserves process-local keys across snapshots by reconciling provider-stable ids.
