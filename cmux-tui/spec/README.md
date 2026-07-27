# cmux-tui Programmability Contract

This directory is the source of truth for the cmux-tui control protocol,
frontend programmability, the generated `cmux-tui` command surface, plugin
contracts, separately versioned provider, machine-agent, and terminal-host
boundaries, and language bindings. The implemented mux protocol described here
is protocol version 10, as defined by `cmux-tui-core/src/server.rs`.

The spec is intentionally stricter than prose docs. Implemented commands and events describe the current server behavior exactly, including awkward result shapes and no-op cases. Proposed commands, events, transports, and config are marked `proposed` and are not part of the implemented protocol.

[`inventory.json`](inventory.json) is the machine-readable coverage index. CI validates it against its JSON Schema and compares it with the Rust protocol version, every server command, serialized event name, configurable TUI action, context-menu action, terminal-host message kind, machine-provider request/event, machine-agent message, provider-management operation, and corresponding prose section. The current checked baseline contains 83 commands, 44 serialized event names, 45 configurable actions, 40 menu actions, 28 cross-boundary feature families, 23 terminal-host messages, 22 machine-provider requests, and 14 machine-agent messages.

## Versioning

The spec version tracks the mux protocol version.

| Change type | Version rule |
| --- | --- |
| Clarification that does not change wire behavior | Patch level of the spec text only |
| Additive command, event, field, CLI flag, binding helper, or transport option | Minor protocol version |
| Removal, rename, incompatible type change, changed error semantics, or changed ordering guarantee | Major protocol version |

Protocol v8 adds stable ids to canonical split nodes and exact split-ratio mutation while preserving the protocol-v5 `set-ratio` command. Protocol-v7 layout nodes do not carry `split`, so clients must negotiate v8 before requiring that field or sending `set-split-ratio`.

Protocol v9 adds stack layout nodes and `new-pane`. Clients must negotiate v9 before decoding a stack node or sending `new-pane`.

Protocol v10 is the implemented baseline. It scopes client-sizing participation to one terminal surface, requires `surface` on `set-client-sizing`, and reports `size_participating` on each `list-clients.sizes` entry. Proposed additions in this directory target the next minor protocol unless a later spec says otherwise.

Protocol v7 is additive for v6 clients: `attach-surface.mode` defaults to `"bytes"`, and `subscribe.tree_events` defaults to `"coarse"`, so absent v7 selectors retain exact v6 attach and tree-event behavior. A v7 server reports `identify.protocol == 7`; clients must require that value before selecting render mode or using other v7-only fields and commands.

Generated clients must inspect `identify.protocol` before using features newer than the connected server. Bindings may expose proposed APIs behind version checks, but they must not send proposed commands to an older server unless the caller explicitly opts into probing.

`identify.capabilities` negotiates additive build-level features within one protocol version. Clients must treat a missing capability list as empty. They must require `attach-initial-size` before sending initial `cols` or `rows` on `attach-surface`, `surface-subscribe-filter` before sending `surface` on `subscribe`, `workspace-registry-v1` before using registry creation, placement, stable-key, or revision-CAS APIs, and `provider-managed-workspace-authority-v2` before committing provider-owned workspace mirrors with a pre-provisioned authority.

## Generation Model

The checked-in bindings are currently a mix of hand-written code and prompt-generated drafts. They are not the protocol source of truth. Deterministic generation must consume a reviewed machine-readable schema, write only generator-owned files, validate in a temporary directory, run formatters and conformance tests, and fail when regenerated output differs.

The acceptance gate is the conformance suite described in `bindings.md`. A binding is conformant only when it can replay the fixture request/response pairs, event transcripts, and end-to-end scenarios against a real headless mux server. Raw request access does not satisfy a typed-method requirement.

The generator must preserve the wire command names, parameter names, result shapes, and error handling rules in `commands.md`. Language-specific APIs may be idiomatic, but they must map 1:1 to the command schema.

## File Map

| File | Purpose |
| --- | --- |
| `inventory.json` | Checked list of implemented commands/events, native action routes, protocol profiles, domains, and pending heads |
| `inventory.schema.json` | JSON Schema for the checked inventory |
| `programmability.md` | Ownership model, exhaustive action policy, missing primitive backlog, compatibility profiles, and conformance bar |
| `commands.md` | Command contract, CLI mapping for each command, examples, and compatibility notes |
| `events.md` | Subscribe and attach event payloads, ordering guarantees, and proposed filters |
| `render.md` | Protocol-v7 authoritative styled-cell attach, deltas, scrollback, sizing guidance, and draft open questions |
| `transports.md` | Implemented Unix socket and WebSocket transports plus proposed HTTP and SSE transports |
| `frontends.md` | Canonical connection, synchronization, terminal streaming, and agent/notification guide for frontend authors |
| `cli.md` | Generated `cmux-tui <verb>` conventions, exit codes, stdin rules, verb table, and examples |
| `bindings.md` | Language binding style sheets and conformance suite contract |
| `native-frontend.md` | Current ownership of config, actions, host terminal side channels, filesystem access, localization, and diagnostics |
| `plugins.md` | Sidebar plugin PTY, manifest, lifecycle, focus, and config contract |
| `machine-provider.md` | Implemented static catalog and authenticated dynamic-provider v1 contract |
| `provider-management.md` | Implemented root-only Linux provider-authority management protocol v1 |
| `terminal-host.md` | Local terminal-host binary protocol v1, with the current resize decoder incompatibility called out as partial |
| `machine-agent.md` | Implemented outbound local-machine registration, stream relay, and generation migration contract |

## Implemented Inventory

Protocol v10 implements the socket commands listed in `inventory.json` and
`commands.md`. The event inventory includes subscribe events, attach-stream
events, and implemented stream lifecycle events. Reserved serializers without a
current producer remain marked separately.

The client also implements `machine-provider-v0`, an in-process static Unix/SSH
catalog, `machine-provider-v1`, an authenticated dynamic-provider protocol over
Unix sockets, direct child processes, or the built-in SSH connector, and
`cmux.machine-agent` v1 for outbound local-machine registration. These
contracts are versioned separately from protocol v10.

Terminal-host v1 and provider-management v1 are also separate version domains. Terminal-host v1 is partial because its current `Resized` producer and consumer disagree on replay framing. SDKs must not infer either domain's compatibility from `identify.protocol`.

## Change Rule

A PR that changes the mux protocol version or adds, removes, or renames a server command, serialized event, configurable action, menu action, or secondary-protocol entry must update `inventory.json` and its normative prose in the same commit. Run:

```sh
python3 cmux-tui/scripts/check-spec-inventory.py
```

Pending PR behavior stays under `pending_heads` until it lands on `main`.
