# cmux-tui Programmability Contract

This directory is the source of truth for the cmux-tui control protocol, the generated `cmux-tui` command surface, plugin contracts, and future generated language bindings. The implemented protocol described here is protocol version 8, as defined by `cmux-tui-core/src/server.rs`.

The spec is intentionally stricter than prose docs. Implemented commands and events describe the current server behavior exactly, including awkward result shapes and no-op cases. Proposed commands, events, transports, and config are marked `proposed` and are not part of the implemented protocol.

## Versioning

The spec version tracks the mux protocol version.

| Change type | Version rule |
| --- | --- |
| Clarification that does not change wire behavior | Patch level of the spec text only |
| Additive command, event, field, CLI flag, binding helper, or transport option | Minor protocol version, unless a named capability gates a baseline-compatible extension |
| Removal, rename, incompatible type change, changed error semantics, or changed ordering guarantee | Major protocol version |

Protocol v8 is the implemented baseline. Proposed additions in this directory target the next minor protocol unless a later spec assigns a named capability to a baseline-compatible extension.

Protocol v8 retains protocol-v7 command defaults and payloads. `attach-surface.mode` still defaults to `"bytes"`, and `subscribe.tree_events` still defaults to `"coarse"`, so legacy clients retain their prior attach and tree-event behavior. A v8 server reports `identify.protocol == 8`, `protocol_min == 6`, and `protocol_max == 8`. Clients must require a named capability before using a capability-gated extension.

`presentation-registry-v1` gates `open-presentation`, `update-presentation`, `close-presentation`, and `list-presentations`. Open, close, and list began in protocol v7; protocol v8 adds generation-fenced updates and UUID entity fields. Protocol-v7 numeric entity fields remain accepted and returned alongside the UUID fields.

`durable-session-identity-v1` means `session_id` is loaded from the versioned daemon state store while `daemon_instance_id` remains process-local. `topology-revision-v1` preserves monotonic legacy `topology_revision` on identity, liveness, and legacy tree snapshot responses. Protocol-v8 identity and liveness responses also expose `canonical_topology_revision`, the structural cursor used by topology snapshot and resume.

`canonical-topology-snapshot-v1`, `stable-entity-uuid-v1`, and `topology-resume-v1` gate protocol-v8 topology synchronization. They add an atomic canonical snapshot, stable UUIDs alongside legacy numeric IDs, and a bounded revisioned resume stream. Clients using this path must still handle an explicit resnapshot requirement.

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
| `transports.md` | Implemented Unix socket and WebSocket transports plus proposed HTTP and SSE transports |
| `frontends.md` | Canonical connection, synchronization, terminal streaming, and agent/notification guide for frontend authors |
| `cli.md` | Generated `cmux-tui <verb>` conventions, exit codes, stdin rules, verb table, and examples |
| `bindings.md` | Language binding style sheets and conformance suite contract |
| `plugins.md` | Sidebar plugin PTY, manifest, lifecycle, focus, and config contract |
| `persistence.md` | Canonical checkpoint, journal, redacted launch recipe, replay, compaction, and daemon-restart contract |

## Implemented Inventory

Protocol v8 implements the socket commands listed in `commands.md` and the event names listed in `events.md`. Events include both topology and legacy subscribe streams, attach-stream events, and the implemented `empty` and `detached` lifecycle events.
