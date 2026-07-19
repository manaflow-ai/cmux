# cmux-tui Programmability Contract

This directory is the source of truth for the cmux-tui control protocol, the generated `cmux-tui` command surface, plugin contracts, and future generated language bindings. The implemented protocol described here is protocol version 9, as defined by `cmux-tui-core/src/server.rs`.

The spec is intentionally stricter than prose docs. Implemented commands and events describe the current server behavior exactly, including awkward result shapes and no-op cases. Proposed commands, events, transports, and config are marked `proposed` and are not part of the implemented protocol.

## Versioning

The spec version tracks the mux protocol version.

| Change type | Version rule |
| --- | --- |
| Clarification that does not change wire behavior | Patch level of the spec text only |
| Additive command, event, field, CLI flag, binding helper, or transport option | Minor protocol version |
| Removal, rename, incompatible type change, changed error semantics, or changed ordering guarantee | Major protocol version |

Protocol v8 adds stable ids to canonical split nodes and exact split-ratio mutation while preserving the protocol-v5 `set-ratio` command. Protocol-v7 layout nodes do not carry `split`, so clients must negotiate v8 before requiring that field or sending `set-split-ratio`.

Protocol v9 is the implemented baseline. It adds stack layout nodes and `new-pane`. Clients must negotiate v9 before decoding a stack node or sending `new-pane`. Proposed additions in this directory target the next minor protocol unless a later spec says otherwise.

Protocol v7 is additive for v6 clients: `attach-surface.mode` defaults to `"bytes"`, and `subscribe.tree_events` defaults to `"coarse"`, so absent v7 selectors retain exact v6 attach and tree-event behavior. A v7 server reports `identify.protocol == 7`; clients must require that value before selecting render mode or using other v7-only fields and commands.

Generated clients must inspect `identify.protocol` before using features newer than the connected server. Bindings may expose proposed APIs behind version checks, but they must not send proposed commands to an older server unless the caller explicitly opts into probing.

`identify.capabilities` negotiates additive build-level features within one protocol version. Clients must treat a missing capability list as empty. They must require `attach-initial-size` before sending initial `cols` or `rows` on `attach-surface`, and `workspace-registry-v1` before using registry creation, placement, stable-key, or revision-CAS APIs.

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

## Implemented Inventory

Protocol v9 implements the socket commands listed in `commands.md` and the event names listed in `events.md`. Events include subscribe events, attach-stream events, and the implemented `empty` and `detached` lifecycle events.
