# cmux-mux Programmability Contract

This directory is the source of truth for the cmux-mux control protocol, the generated `cmux-mux` command surface, and future generated language bindings. The implemented protocol described here is protocol version 5, as defined by `mux-core/src/server.rs`.

The spec is intentionally stricter than prose docs. Implemented commands and events describe the current server behavior exactly, including awkward result shapes and no-op cases. Proposed commands, events, transports, and config are marked `proposed` and are not part of protocol v5.

## Versioning

The spec version tracks the mux protocol version.

| Change type | Version rule |
| --- | --- |
| Clarification that does not change wire behavior | Patch level of the spec text only |
| Additive command, event, field, CLI flag, binding helper, or transport option | Minor protocol version |
| Removal, rename, incompatible type change, changed error semantics, or changed ordering guarantee | Major protocol version |

Protocol v5 is the implemented baseline. Proposed additions in this directory target protocol v6 unless a later spec says otherwise.

Generated clients must inspect `identify.protocol` before using features newer than the connected server. Bindings may expose proposed APIs behind version checks, but they must not send proposed commands to a v5 server unless the caller explicitly opts into probing.

## Generation Model

The CLI and language bindings are generated from this spec. Hand-written adapters may exist for bootstrapping, but generated output is authoritative once generation lands.

The acceptance gate is the conformance suite described in `bindings.md`. A generated CLI or binding is conformant only when it can replay the fixture request/response pairs, event transcripts, and end-to-end scenario against a real headless mux server.

The generator must preserve the wire command names, parameter names, result shapes, and error handling rules in `commands.md`. Language-specific APIs may be idiomatic, but they must map 1:1 to the command schema.

## File Map

| File | Purpose |
| --- | --- |
| `commands.md` | Command contract, CLI mapping for each command, examples, and compatibility notes |
| `events.md` | Subscribe and attach event payloads, ordering guarantees, and proposed filters |
| `transports.md` | Implemented Unix socket transport and proposed HTTP, SSE, and WebSocket transports |
| `cli.md` | Generated `cmux-mux <verb>` conventions, exit codes, stdin rules, verb table, and examples |
| `bindings.md` | Language binding style sheets and conformance suite contract |

## Implemented Inventory

Protocol v5 implements 28 socket commands and 10 event names. The command inventory is listed in `commands.md`. Events include subscribe events, attach-stream events, and the implemented `empty` and `detached` lifecycle events.

`move-tab` and `move-workspace` are not implemented in this tree.
