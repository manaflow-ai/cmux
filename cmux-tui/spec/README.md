# cmux-tui programmability contracts

cmux-tui exposes two different client protocols. Use the resource API for new
integrations. Use the raw mux protocol only when implementing cmux's own
frontend or a compatibility adapter.

## Choose a protocol

| Use case | Protocol | Stability |
| --- | --- | --- |
| New CLI, SDK, plugin, or external integration | `cmux.protocol/2` (resource API v2) | Public compatibility boundary |
| cmux frontend, renderer, or migration adapter | Private mux protocol v12 | Negotiated implementation protocol |

The two protocols do not share envelopes, IDs, capability negotiation, or
version numbers. A client must not infer support for one from the other.

## Public resource API

`cmux.protocol/2` is the compatibility boundary for the noun-first CLI and
high-level SDKs:

| File | Purpose |
| --- | --- |
| [`resource-api-v2.md`](resource-api-v2.md) | IDs, selectors, envelopes, mutations, streams, limits, and lifecycle rules |
| [`resource-api-v2.json`](resource-api-v2.json) | JSON Schema for request, response, and stream envelopes |
| [`resource-operations-v2.json`](resource-operations-v2.json) | Normative catalog of 125 transported and six local operations |
| [`resource-operations-v2.schema.json`](resource-operations-v2.schema.json) | JSON Schema for the operation catalog |
| [`resource-operations-v2.md`](resource-operations-v2.md) | Human-readable operation inventory |
| [`cli.md`](cli.md) | Noun-first public CLI |
| [`bindings.md`](bindings.md) | Seven handwritten SDK facades and generated raw layers |
| [`plugins.md`](plugins.md) | Sidebar view and local plugin contract |

The operation catalog is authoritative for every operation's class, selector
scopes, parameter presence, result type, structured errors, stream items, and
stream end. Unknown fields are rejected except at named extension points.

Public IDs are typed opaque strings. Internal mux positions, storage keys,
numeric identities, and private renderer lifecycle values cannot cross this
boundary.

## Private mux protocol

The authenticated remote daemon has an independent protocol version.
[`remote-daemon.md`](remote-daemon.md) and [`remote-rpc.md`](remote-rpc.md)
define remote protocol 5; `mux-control` carries private control protocol 12
inside that authenticated session.

Protocol v12 is the current private mux implementation protocol. It remains
documented for cmux frontends and compatibility adapters:

| File | Purpose |
| --- | --- |
| [`commands.md`](commands.md) | Raw protocol-v12 commands |
| [`events.md`](events.md) | Raw events and attachment messages |
| [`render.md`](render.md) | Styled render model used by private frontends |
| [`transports.md`](transports.md) | Unix socket, WebSocket, and relay framing |
| [`frontends.md`](frontends.md) | Private frontend synchronization |
| [`programmability.md`](programmability.md) | Implementation inventory and ownership |
| [`native-frontend.md`](native-frontend.md) | Native TUI integration boundaries |
| [`session-journal.md`](session-journal.md) | Canonical event storage, hooks, agent ownership, and restoration |

The private protocol is not a second public API. High-level SDK packages expose
it only through a path named `raw`, so callers opt into its compatibility
constraints explicitly.

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
[`sdk-schema.json`](sdk-schema.json) drives only raw protocol-v12 generation.

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

`cmux.protocol/2` may receive backward-compatible optional additions while it
is version 2. Removing an operation, changing field presence or type, changing
selector behavior, or weakening ordering and idempotency semantics requires a
new public protocol version.

Private protocol v12 follows its own negotiation and capability rules. Public
SDKs do not infer private capability support and private frontends do not infer
the public resource version.
