# cmux resource API v1

Status: normative, prelaunch, incompatible with every earlier control API.

## Model

The public hierarchy is:

```text
Machine
└── Session
    ├── Workspace
    │   └── Screen
    │       └── Pane
    │           └── Tab
    │               ├── Terminal
    │               └── Browser
    ├── Client
    ├── Notification
    ├── Agent
    ├── Projection
    ├── SidebarView
    └── SidebarPlugin
```

A tab owns exactly one terminal or browser. Sidebar extensions are
session-scoped auxiliary resources and cannot become tabs.

All public IDs are JSON strings with one registered prefix and 128 bits of
lowercase hexadecimal entropy:

| Resource | Prefix |
| --- | --- |
| Machine | `machine_` |
| Session | `session_` |
| Workspace | `ws_` |
| Screen | `screen_` |
| Pane | `pane_` |
| Tab | `tab_` |
| Terminal | `term_` |
| Browser | `browser_` |
| Client | `client_` |
| Split | `split_` |
| Notification | `notification_` |
| Agent | `agent_` |
| Stream | `stream_` |
| Projection | `projection_` |
| Sidebar view | `sidebar_view_` |
| Sidebar plugin | `sidebar_plugin_` |

IDs are immutable and never reused. A durable session stores IDs with the
logical resource and restores every ID for every resource that remains alive
after daemon restart. Mux slot numbers are private and cannot appear in a v1
request, response, event, error, CLI value, or high-level SDK.

Names are labels. They are preserved byte-for-byte, may be empty, and need
not be unique.

## Selectors

Every CLI instance selector accepts:

1. a typed opaque ID;
2. `current`;
3. an exact name.

An exact name with zero matches returns `selector.not_found`. More than one
match returns `selector.ambiguous` with every candidate ID. Resolution and
mutation use one snapshot, so an ambiguous request cannot partially mutate.
SDK `find_by_name` methods always return a list.

## Protocol

Unix sockets use one UTF-8 JSON object per line. WebSockets use one UTF-8 JSON
object per text frame. Both transports carry identical envelopes.

Request:

```json
{
  "protocol": "cmux.protocol/1",
  "id": "request-owned-json-scalar",
  "operation": "workspace.list",
  "params": {},
  "idempotency_key": null
}
```

Success:

```json
{
  "protocol": "cmux.protocol/1",
  "id": "request-owned-json-scalar",
  "ok": true,
  "result": {}
}
```

Failure:

```json
{
  "protocol": "cmux.protocol/1",
  "id": "request-owned-json-scalar",
  "ok": false,
  "error": {
    "code": "selector.ambiguous",
    "message": "more than one workspace is named \"api\"",
    "details": {"candidates": ["ws_…", "ws_…"]},
    "retryable": false
  }
}
```

Every mutation requires a non-empty idempotency key. Repeating the same key,
operation, and canonical parameters returns the committed result. Reusing a
key with different parameters returns `idempotency.conflict`. SDKs never
retry mutations implicitly.

Messages are limited to 4 MiB. Each stream queue holds at most 256 events and
16 MiB. Overflow terminates the stream with `stream.gap`, including the last
delivered revision, current revision, and generation. A client recovers with
`session.snapshot`, verifies generation, and resumes after the new revision.

Stream open returns a `stream_` ID. `stream.cancel` is idempotent. Events use:

```json
{
  "protocol": "cmux.protocol/1",
  "stream_id": "stream_…",
  "event": "terminal.output",
  "revision": 42,
  "generation": "opaque",
  "data": {}
}
```

## Operations

All mutations below require `idempotency_key`.

| Scope | Operations |
| --- | --- |
| machine | `list`, `show`, `session_snapshot`, `open_session` |
| session | `show`, `snapshot`, `events`, `ping`, `shutdown`, `reload_config` |
| client | `list`, `show`, `label`, `detach`, `set_sizing`, `release_sizing` |
| window | `title_set`, `title_clear`, `colors_set` |
| pairing | `list`, `respond` |
| projection | `get`, `put` |
| workspace | `list`, `show`, `create`, `rename`, `move`, `close`, `run` |
| screen | `list`, `show`, `create`, `rename`, `select`, `close`, `layout_export`, `layout_apply` |
| pane | `list`, `show`, `create`, `split`, `rename`, `focus`, `focus_direction`, `neighbor`, `swap`, `zoom`, `ratio_set`, `close`, `run` |
| tab | `list`, `show`, `create_terminal`, `create_browser`, `rename`, `select`, `move`, `close` |
| terminal | `show`, `send`, `keys`, `read`, `scrollback`, `copy`, `wait`, `process`, `resize`, `scroll`, `attach`, `state`, `move`, `close` |
| browser | `show`, `navigate`, `back`, `forward`, `reload`, `activate`, `key`, `text`, `mouse`, `wheel`, `attach`, `close` |
| notification | `list`, `create` |
| agent | `list`, `report` |
| sidebar | `show`, `resize`, `reload`, `disable`, `use_builtin` |
| sidebar_plugin | `list`, `install`, `use`, `update`, `remove` |
| provider | `authority_install`, `workspace_mark`, `workspace_rename`, `workspace_close` |
| stream | `cancel` |

`workspace.create`, `workspace.run`, `pane.run`, `tab.create_terminal`, and
`tab.create_browser` return the complete created path: workspace, screen,
pane, tab, and terminal or browser IDs.

`workspace.run` creates a terminal tab in the active pane. `pane.run` creates
a terminal tab in that pane. `argv` is an exact string array. Shell evaluation
is available only through an explicit `shell` helper that expands to the
platform shell plus `-lc`.

## CLI

The executable starts or attaches when no resource scope is supplied. Control
commands are noun-first:

```text
cmux workspace list
cmux workspace create --name api
cmux workspace api show
cmux workspace ws_… run -- cargo test
cmux workspace ws_… screen current pane current split --right
cmux terminal term_… read
cmux terminal term_… keys ctrl-c
```

Root control scopes are `machine`, `session`, `client`, `workspace`, `screen`,
`pane`, `tab`, `terminal`, `browser`, `notification`, `agent`, `sidebar`,
`sidebar-plugin`, `pairing`, `projection`, `provider`, `stream`, and `raw`.
Hyphenated action-first commands are usage errors with exit code 2.

Global routing flags are `--machine`, `--session`, and advanced `--socket`.
Machine providers expose typed session discovery and open operations. A
provider with one session returns one default session through the same API.

Human output follows the selected locale, currently English and Japanese.
`--json` prints one result object. `--jsonl` prints one object per result or
event. `--quiet` suppresses success output. Results use stdout. Diagnostics
use stderr. Exit codes are 0 success, 1 operation failure, 2 usage, and 3
transport.

Local filesystem actions are `sidebar-plugin install|update|remove` and
configuration discovery. Their results use the same output modes but they do
not cross the session protocol.

## SDK boundary

Generated wire models and codecs are available only under `raw`. High-level
resource handles are handwritten and dependency-light. A handle contains a
typed ID and client reference. Copying a handle performs no I/O. Dropping a
handle never deletes the resource. `refresh` is explicit. `close` is explicit.

Language contracts:

| Language | Contract |
| --- | --- |
| Rust | blocking `Result`, owned iterator streams |
| Python | synchronous client plus standard-library `asyncio` adapter |
| TypeScript | `Promise`, `AsyncIterable`, `AbortSignal`, browser-safe WebSocket export |
| Go | `context.Context` on every I/O method |
| Java | immutable values, builders, `AutoCloseable` streams |
| C++20 | `result<T>`, move-only RAII streams |
| Zig | caller allocator, explicit `deinit` |

Protocol errors retain `code`, `message`, `details`, and `retryable` in every
language. All seven SDKs implement the same fake-server and live-server
conformance cases.

## Separate protocols

Terminal-host, machine-agent, and machine-provider transports keep separate
version numbers. The machine-provider protocol includes typed
`session_snapshot(machine_id)` and `open_session(machine_id, session_id)`
messages. They translate to this API only at the provider adapter.
