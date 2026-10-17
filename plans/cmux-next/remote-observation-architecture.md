# Read-only remote observation architecture

This plan connects existing cmux transport, session identity, ACPMUX observation,
and durable receipt primitives. It does not create a second remote-control stack.

## Goals

- Inspect Codex or another app-server running on an SSH host without enrolling
  that process as a native cmux remote-control host.
- Give every observation a stable, reconnect-safe identity and sequence cursor.
- Persist coordination receipts through the existing ACPMUX mailbox contract.
- Keep UI work small: Swift owns SSH lifecycle and machine routing, Rust owns
  protocol normalization and durable receipts, and React renders normalized data.
- Preserve the existing no-polling, bounded-work, and frame-budget rules.

## Existing owners

| Concern | Existing owner | Reuse |
| --- | --- | --- |
| SSH host identity and lifecycle | `CmuxNextRemote/SSH/SSHHost.swift`, `SSHMachineLink.swift`, `SSHService.swift` | Probe, install, start, stop, and reconnect the SSH link |
| Paired server identity | `ServerReach.swift`, `ServerReachService.swift`, `ServerMachineSession.swift` | Keep paired servers separate from SSH machine sessions |
| Remote daemon socket | `cmux-tui remote connect ssh://...` and `DaemonConnection` | Continue using the normal remote cmux daemon path |
| Session/activity identity | `AgentActivitySocketSource.swift` | Machine/session IDs, sequence cursors, `after_seq` replay |
| Authenticated peer transport | `cmux-tui/crates/acpmux/src/peer.rs` | Bearer + peer token, `served_as`, generation, watch/delta stream |
| Read-only agent observation | `server/agent_session_observe.rs` | `agent-session-observe-v1` and mutation refusal |
| Durable receipts | `acpmux/src/mailbox.rs`, `src/protocol/mailbox.rs` | Idempotency, cursors, recipient-scoped ack, delivery receipts |

## Identity envelope

Every observation event and receipt carries:

```text
machine_id          SSHHost.machineID or the peer's machine identity
route_kind          ssh_app_server | acpmux_peer | local
remote_session_id   app-server or ACP session identifier
daemon_session_id   cmux daemon session identifier when available
connection_generation SSH link/Peer generation
sequence            source event sequence, or mailbox cursor
observed_at         monotonic/local timestamp for diagnostics
```

The tuple `(machine_id, route_kind, remote_session_id, connection_generation,
sequence)` is the deduplication key. A reconnect starts a new generation; it may
replay from the last durable cursor but cannot overwrite an event from an older
generation.

## SSH app-server inspection

`SSHMachineLink` remains responsible for the cmux daemon link. An inspection
sidecar uses the same `SSHHost` and `SSHCommandLine`, but launches
`codex app-server --stdio` as a separate bounded child process.

The sidecar may perform:

1. app-server initialize/capability negotiation;
2. read-only session and status inspection;
3. event framing, sequence assignment, and reconnect replay;
4. receipt publication through the Rust adapter.

It may not:

- reuse native remote-control enrollment or `ServerReach` state;
- send prompt, cancel, permission, filesystem, or workspace mutations;
- expose the app-server bearer token to the webview or mailbox body;
- silently turn an inspection route into an attached cmux daemon session.

The observed `remoteControl/status/changed` event is a capability/status signal.
`disabled` with a null environment ID means inspection is available only as far
as the app-server reports it; it is not proof of native remote-control access.

## ACPMUX bridge

Add a Rust-only adapter over the existing authenticated `Peer::request` and
mailbox primitives. The adapter should expose a typed observation receipt, not a
new transport:

- `observation.snapshot`
- `observation.delta`
- `observation.reconnect`
- `observation.capability`
- `observation.error`

Receipts are addressed to a stable recipient (`acp:<session-id>` or a named
observer role). The mailbox message ID is the idempotency key. The receipt
metadata contains the identity envelope and source cursor; message bodies remain
untrusted data.

Only a peer-authenticated connection with `served_as == peer` may publish or
read remote observation receipts. Page relays and ordinary bearer WebSockets
remain denied. Acknowledgement proves transport acceptance, not that a model
understood or acted on the receipt.

## Reconnect and backpressure

- Keep one in-flight read per `(machine, session, generation)`.
- Replay from the last acknowledged sequence/cursor before accepting live deltas.
- Cap event and receipt buffers. On overflow, emit a typed gap receipt and require
  a bounded snapshot refresh; never grow an unbounded queue.
- Treat push notifications as wake-up hints. The mailbox and source cursor remain
  authoritative after reconnect.
- Stop the sidecar on SSH disconnect, capability refusal, or auth failure; expose
  the reason as a typed receipt.

## Performance rules

- Decode app-server and ACPMUX JSON off the main actor.
- Coalesce observation deltas once per frame for UI consumers.
- Keep Swift responsible for process/SSH lifecycle only; do not move AppKit
  sidebar layout or `Observation` models into Rust.
- Move pure Rust work first: framing, cursor reconciliation, receipt encoding,
  deduplication, and capability normalization.
- Keep React responsible for webview rendering and interaction, consuming typed
  snapshots/deltas rather than owning transport state.
- Add receipts for decode time, queue depth, replay count, gap count, and publish
  latency. Enforce bounded budgets before attempting larger rewrites.

## Delivery slices

1. **Contract:** define the identity envelope and observation receipt schema in
   the ACPMUX protocol spec; add Rust encode/decode and dedup tests.
2. **Peer path:** adapt existing `PeerNotice` and mailbox calls; test peer-token
   authorization, reconnect generations, cursor replay, and recipient-only ack.
3. **SSH sidecar:** add a read-only app-server stdio inspector behind
   `SSHMachineLink` credentials; test initialize, status changes, disconnect, and
   capability refusal.
4. **Durability:** persist the last acknowledged cursor and replay gap receipts;
   verify restart recovery without duplicate delivery.
5. **UI consumption:** expose normalized receipts to existing activity/session
   surfaces. Do not add a new remote-control UI until the transport receipts are
   stable and measured.

## Explicitly separate work

PR #21305's durable runs, attach tickets, run board, and UI tournament are a
separate product surface. They may consume observation receipts later, but they
do not own SSH transport, ACPMUX peer authorization, or session identity.

