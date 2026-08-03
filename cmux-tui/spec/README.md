# cmux-tui programmability contracts

cmux-tui has one stable public resource protocol and several explicitly
separate internal or privileged protocols.

## Public API

`cmux.protocol/1` is the compatibility boundary for the noun-first CLI and
high-level SDKs.

## Raw protocol versioning

The spec version tracks the mux protocol version.

| Change type | Version rule |
| --- | --- |
| Clarification that does not change wire behavior | Patch level of the spec text only |
| Additive command, event, field, CLI flag, binding helper, or transport option | Minor protocol version |
| Removal, rename, incompatible type change, changed error semantics, or changed ordering guarantee | Major protocol version |

Protocol v8 adds stable ids to canonical split nodes and exact split-ratio mutation while preserving the protocol-v5 `set-ratio` command. Protocol-v7 layout nodes do not carry `split`, so clients must negotiate v8 before requiring that field or sending `set-split-ratio`.

Protocol v9 adds stack layout nodes and `new-pane`. Clients must negotiate v9 before decoding a stack node or sending `new-pane`.

Protocol v10 is the implemented baseline. It scopes client-sizing participation
to one terminal attachment, requires an explicit terminal selector on
`set-client-sizing`, and reports `size_participating` on each
`list-clients.sizes` entry. Proposed additions in this directory target the
next minor protocol unless a later spec says otherwise.

Protocol v7 is additive for v6 clients: the raw attachment `mode` field
defaults to `"bytes"`, and `subscribe.tree_events` defaults to `"coarse"`, so
absent v7 selectors retain exact v6 attach and tree-event behavior. A v7
server reports `identify.protocol == 7`; clients must require that value before
selecting render mode or using other v7-only fields and commands.

Generated clients must inspect `identify.protocol` before using features newer than the connected server. Bindings may expose proposed APIs behind version checks, but they must not send proposed commands to an older server unless the caller explicitly opts into probing.

`identify.capabilities` negotiates additive build-level features within one
protocol version. Clients must treat a missing capability list as empty. Exact
raw capability names are documented in [`commands.md`](commands.md). Clients
must negotiate initial attachment sizing before sending initial `cols` or
`rows`, terminal-scoped subscription filtering before sending a terminal
selector on `subscribe`, `workspace-registry-v1` before using registry
creation, placement, stable-key, or revision-CAS APIs, `viewport-splits-v1`
before creating horizontal viewport columns, `viewport-column-resize-v1`
before resizing those columns, `layout-undo-v1` before sending `undo-layout`,
`clear-history-v1` before sending `clear-history`, both `clear-history-v1` and
`clear-history-key-v1` before including its structured `fallback_key`,
`provider-managed-workspace-authority-v2` before committing provider-owned
workspace mirrors with a pre-provisioned authority, and `server-shutdown-v1`
before assuming `shutdown` is implemented.

## SDK model

The noun-first CLI and high-level SDK facades are handwritten against the
resource operation catalog. Raw SDK namespaces are generated from the
protocol schema, and their checked-in manifests make schema drift visible.

The acceptance gate is the conformance suite described in `bindings.md`. A
binding is conformant only when it can replay the fixture request/response
pairs, event transcripts, and end-to-end scenario against a real headless mux
server.

Raw-layer generators preserve wire command names, parameter names, result
shapes, and error handling rules. High-level language APIs may be idiomatic,
but they map to the operations and schemas declared here.

## File Map

| File | Purpose |
| --- | --- |
| [`resource-api-v1.md`](resource-api-v1.md) | IDs, selectors, envelopes, mutations, streams, limits, and lifecycle rules |
| [`resource-api-v1.json`](resource-api-v1.json) | JSON Schema for request, response, and stream envelopes |
| [`resource-operations-v1.json`](resource-operations-v1.json) | Normative catalog of 112 transported and six local operations |
| [`resource-operations-v1.schema.json`](resource-operations-v1.schema.json) | JSON Schema for the operation catalog |
| [`resource-operations-v1.md`](resource-operations-v1.md) | Human-readable operation inventory |
| [`cli.md`](cli.md) | Noun-first public CLI |
| [`bindings.md`](bindings.md) | Seven handwritten SDK facades and generated raw layers |
| [`plugins.md`](plugins.md) | Sidebar view and local plugin contract |

The operation catalog is authoritative for every operation's class, selector
scopes, parameter presence, result type, structured errors, stream items, and
stream end. Unknown fields are rejected except at named extension points.

Public IDs are typed opaque strings. Internal mux positions, storage keys,
numeric identities, and private renderer lifecycle values cannot cross this
boundary.

## Raw and implementation protocols

The authenticated remote daemon has an independent protocol version.
[`remote-daemon.md`](remote-daemon.md) and [`remote-rpc.md`](remote-rpc.md)
define remote protocol 5; `mux-control` carries private control protocol 10
inside that authenticated session.

Protocol v10 is the current private mux implementation protocol. It remains
documented for cmux frontends and compatibility adapters:

| File | Purpose |
| --- | --- |
| [`commands.md`](commands.md) | Raw protocol-v10 commands |
| [`events.md`](events.md) | Raw events and attachment messages |
| [`render.md`](render.md) | Styled render model used by private frontends |
| [`transports.md`](transports.md) | Unix socket, WebSocket, and relay framing |
| [`frontends.md`](frontends.md) | Private frontend synchronization |
| [`programmability.md`](programmability.md) | Implementation inventory and ownership |
| [`native-frontend.md`](native-frontend.md) | Native TUI integration boundaries |

Private protocol-v10 compatibility does not imply `cmux.protocol/1`
compatibility. High-level SDK packages expose it only through a path named
`raw`.

The remote daemon, machine-provider, provider-management, terminal-host, and
machine-agent protocols each have their own version and authority boundary:

| File | Version domain |
| --- | --- |
| [`remote-daemon.md`](remote-daemon.md) | Authenticated remote transport and service protocol |
| [`remote-rpc.md`](remote-rpc.md) | Workspace RPC envelopes, including patch application |
| [`machine-provider.md`](machine-provider.md) | Dynamic provider control and stream |
| [`provider-management.md`](provider-management.md) | Root-only provider authority |
| [`terminal-host.md`](terminal-host.md) | Terminal host process |
| [`machine-agent.md`](machine-agent.md) | Outbound machine registration and relay |

Clients must negotiate each domain independently.

## Inventory and checks

[`inventory.json`](inventory.json) records raw server commands, events, TUI
actions, menu actions, feature families, and secondary protocol messages.
[`inventory.schema.json`](inventory.schema.json) defines that index.
[`sdk-schema.json`](sdk-schema.json) drives only raw protocol-v10 generation.

Run the contract checks from the repository root:

```bash
python3 cmux-tui/scripts/test_check_spec_inventory.py
python3 cmux-tui/scripts/check-spec-inventory.py
python3 cmux-tui/scripts/test_check_resource_api_boundary.py
python3 cmux-tui/scripts/check-resource-api-boundary.py
python3 cmux-tui/bindings/codegen/generate.py --check
```

A change to any operation, field, class, public ID, raw command, serialized
event, native action, menu action, or secondary protocol entry updates its
machine-readable catalog and normative prose in the same commit.

## Versioning

`cmux.protocol/1` may receive backward-compatible optional additions while it
is version 1. Removing an operation, changing field presence or type, changing
selector behavior, or weakening ordering and idempotency semantics requires a
new public protocol version.

Private protocol v10 follows its own negotiation and capability rules. Public
SDKs do not infer private capability support and private frontends do not infer
the public resource version.
