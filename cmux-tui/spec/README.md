# cmux-tui Programmability Contract

This directory is the source of truth for the cmux-tui control protocol, the generated `cmux-tui` command surface, plugin contracts, and future generated language bindings. Protocol version 8 remains the preferred baseline. The server also implements an explicitly negotiated protocol-v9 terminal-control extension, as defined by `cmux-tui-core/src/server.rs` and `terminal-control-v9.md`.

The spec is intentionally stricter than prose docs. Implemented commands and events describe the current server behavior exactly, including awkward result shapes and no-op cases. Proposed commands, events, transports, and config are marked `proposed` and are not part of the implemented protocol.

## Versioning

The spec version tracks the mux protocol version.

| Change type | Version rule |
| --- | --- |
| Clarification that does not change wire behavior | Patch level of the spec text only |
| Additive command, event, field, CLI flag, binding helper, or transport option | Minor protocol version, unless a named capability gates a baseline-compatible extension |
| Removal, rename, incompatible type change, changed error semantics, or changed ordering guarantee | Major protocol version |

Protocol v8 is the preferred implemented baseline. Protocol v9 is implemented only for registered clients that negotiate it. Proposed additions in this directory target the next minor protocol unless a later spec assigns a named capability to a baseline-compatible extension.

Protocol v8 retains protocol-v7 command defaults and payloads. `attach-surface.mode` still defaults to `"bytes"`, and `subscribe.tree_events` still defaults to `"coarse"`, so legacy clients retain their prior attach and tree-event behavior. The server reports `identify.protocol == 8`, `protocol_min == 6`, and `protocol_max == 9`. A client stays on v8 unless it sends `register-client` and negotiates v9. Clients must require a named capability before using a capability-gated extension.

Protocol-v9 terminal mutation requires the complete capability set in
`terminal-control-v9.md`. Input and geometry have independent leases, TTLs,
renewal, transfer, and revocation sequences. Input additionally has bounded
automation delegation, atomic lifecycle groups, terminal-wide order, and
acknowledged idempotent receipts. The order is daemon-assigned per canonical
terminal and shared by GUI, TUI, and delegated automation clients.

`terminal-activity-v1` gates persisted, content-free activity facts and durable receipts keyed by registered stable client UUID plus terminal UUID. One reader acknowledging a terminal never clears another reader's unread state.

`presentation-registry-v1` gates `open-presentation`, `update-presentation`, `close-presentation`, and `list-presentations`. Open, close, and list began in protocol v7; protocol v8 adds generation-fenced updates and UUID entity fields. Protocol-v7 numeric entity fields remain accepted and returned alongside the UUID fields.

`durable-session-identity-v1` means `session_id` is loaded from the versioned daemon state store while `daemon_instance_id` remains process-local. `topology-revision-v1` preserves monotonic legacy `topology_revision` on identity, liveness, and legacy tree snapshot responses. Protocol-v8 identity and liveness responses also expose `canonical_topology_revision`, the structural cursor used by topology snapshot and resume.

`canonical-topology-snapshot-v1`, `stable-entity-uuid-v1`, and `topology-resume-v1` gate protocol-v8 topology synchronization. They add an atomic canonical snapshot, stable UUIDs alongside legacy numeric IDs, and a bounded revisioned resume stream. Clients using this path must still handle an explicit resnapshot requirement.

`projection-state-reconnect-v1` gates daemon-lifetime logical-window placement for registered protocol-v9 clients. The mapping from a stable frontend window UUID to canonical workspace and selected-screen UUIDs survives frontend disconnect, but it is outside canonical topology revisions and disk checkpoints. Claims are fenced by stable client, frontend process, connection, claim UUID, and generation. Live renderer presentations and terminal-control leases remain connection-owned.

`ensure-terminals-v1` gates bounded, ordered cold-terminal materialization in one canonical topology and persistence transaction. Clients that do not observe the capability must use ordered singular `ensure-terminal` calls.

Generated clients must inspect `identify.protocol` before using features newer than the connected server. Bindings may expose proposed APIs behind version checks, but they must not send proposed commands to an older server unless the caller explicitly opts into probing.

## Generation Model

The CLI and language bindings are generated from this spec. Hand-written adapters may exist for bootstrapping, but generated output is authoritative once generation lands.

The acceptance gate is the conformance suite described in `bindings.md`. A generated CLI or binding is conformant only when it can replay the fixture request/response pairs, event transcripts, and end-to-end scenario against a real headless mux server.

The generator must preserve the wire command names, parameter names, result shapes, and error handling rules in `commands.md`. Language-specific APIs may be idiomatic, but they must map 1:1 to the command schema.

## File Map

| File | Purpose |
| --- | --- |
| `commands.md` | Command contract, CLI mapping for each command, examples, and compatibility notes |
| `events.md` | Subscribe and attach event payloads, ordering guarantees, and proposed filters |
| `render.md` | Protocol-v7 authoritative styled-cell attach, deltas, scrollback, sizing guidance, and draft open questions |
| `terminal-control-v9.md` | Opt-in terminal input and geometry ownership, ordering, retries, and v8 migration |
| `transports.md` | Implemented Unix socket and WebSocket transports plus proposed HTTP and SSE transports |
| `frontends.md` | Canonical connection, synchronization, terminal streaming, and agent/notification guide for frontend authors |
| `cli.md` | Generated `cmux-tui <verb>` conventions, exit codes, stdin rules, verb table, and examples |
| `bindings.md` | Language binding style sheets and conformance suite contract |
| `plugins.md` | Sidebar plugin PTY, manifest, lifecycle, focus, and config contract |
| `persistence.md` | Canonical checkpoint, journal, redacted launch recipe, replay, compaction, and daemon-restart contract |

## Implemented Inventory

Protocol v8 implements the socket commands listed in `commands.md` and the event names listed in `events.md`. Events include both topology and legacy subscribe streams, attach-stream events, and the implemented `empty` and `detached` lifecycle events.
