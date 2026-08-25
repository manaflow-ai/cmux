# Programmability Completeness

This inventory audits both the private frontend protocol and secondary
implementation boundaries. Public application completeness is defined by
[`cmux.protocol/2`](resource-api-v2.md), its
[operation catalog](resource-operations-v2.json), the
[noun-first CLI](cli.md), and the [SDK contract](bindings.md).

A feature is complete only when its authoritative state and side effects have a typed protocol route, observable results, compatibility metadata, and conformance coverage. A raw JSON escape hatch does not count as typed SDK support.

[`inventory.json`](inventory.json) is the checked inventory. CI validates it against its JSON Schema and compares it with the Rust protocol version, `Command`, `Action`, and `MenuAction` enums, serialized wire event names, secondary protocol enums, and the prose sections that define each implemented command and event.

## Ownership classes

Every feature belongs to one ownership class:

| Class | Authority | Required route |
| --- | --- | --- |
| Mux state | Server topology, terminal registry, processes, agents, notifications, and shared configuration | Mux command plus snapshot or event |
| Frontend presentation | Sidebar visibility, prompt/menu state, rail widths, hover/drag state, local viewport, and local selection | Frontend action adapter; it must not be presented as shared mux state |
| Terminal host | Durable PTY process and renderer data plane | [`terminal-host.md`](terminal-host.md) |
| Machine provider | Machine discovery, lifecycle, scopes, and transport tickets | [`machine-provider.md`](machine-provider.md) |
| Provider management | Root-owned authority installation and rotation | [`provider-management.md`](provider-management.md) |
| Plugin host | Installed executable, manifest, permissions, contributions, and lifecycle | [`plugins.md`](plugins.md) |

An action that combines a frontend choice with a mux mutation has two steps. For example, `browser-edit-url` opens a local prompt, then calls `browser-navigate`. The local prompt is not copied into mux state.

## Native entrypoint coverage

Every variant of the native TUI `Action` enum appears in `inventory.json` with one classification:

- `direct` invokes one implemented command.
- `composite` derives a target from frontend state or selects among multiple authority-specific routes, then invokes the matching command or secondary protocol.
- `presentation-only` changes one frontend and uses the proposed frontend action adapter when remote automation is required.

CI rejects a new native action until its route is classified. This prevents keyboard and context-menu features from silently bypassing the public contract.

Every `MenuAction` variant is inventoried separately because context menus expose machine lifecycle, provider actions, client sizing, clipboard operations, and workspace deletion that are not configurable keyboard actions. Direct pointer routing, omnibar hits, and the built-in file sidebar are not claimed as enum-exhaustive. Their ownership is tracked by the feature-family rows for frontend presentation, browser lifecycle, host-terminal integration, and the file sidebar.

`focus-left`, `focus-right`, `focus-up`, and `focus-down` are composites because the native TUI uses its rendered geometry and client focus history before calling `focus-pane`. `focus-direction` is a server-side approximation and is not an exact substitute. `scroll-up` and `scroll-down` are presentation-only for an attached remote TUI because that frontend owns its mirrored viewport; `scroll-surface` controls the server-owned viewport.

`new-workspace` is conditional. Its structured inventory route reads ownership
from the active workspace session. Session ownership selects the mux
`new-workspace` command. Provider ownership selects machine-provider
`create_workspace` with the advertised isolated or host mode. A missing or
unknown ownership signal rejects the action instead of selecting either route.

## Required vNext primitives

The implemented v10 inventory is complete as a description of current wire behavior. The following primitives are required before the affected feature family can claim portable automation completeness.

| Feature family | Current route | Required addition |
| --- | --- | --- |
| Stream lifecycle | Repeated `subscribe` and `attach-surface` registrations share a connection and have no public identity | Client-generated `stream_id`, echoed events, and idempotent `cancel-stream` |
| Event recovery | Local consumers can replay or tail the session journal with durable cursors, structured filters, and compiled regex; remote consumers receive token-gated metadata with redaction | Classify remaining transient producers and expose retained-range discovery |
| Mutating retries | Workspace and durable-terminal mutations have partial mutation ledgers; some legacy acknowledgements do not prove a commit | One operation identity and receipt format for every side effect; success must identify committed, changed, or no-op state |
| Errors | Response `error` is one string | `{code,message,details,retryable}` with stable codes |
| TUI presentation | State stays inside one frontend | `register-frontend`, `describe-frontend-actions`, `invoke-frontend-action`, and `frontend-action-result` |
| PTY keyboard | `send-key` emits semantic keyboard input for PTYs | Preserve this route and add negotiated key capability discovery |
| PTY mouse and focus | Native TUI encodes mouse/focus bytes locally | `send-mouse` and `send-focus`, with current terminal modes in render state |
| Terminal-host resize | The host produces a length-prefixed replay, while the current consumer includes that length word in replay bytes | Repair the decoder, add producer-consumer and cross-language fixtures, then promote terminal-host v1 from partial |
| PTY selection | Native selection is frontend-local and `copy selection` cannot reconstruct it remotely | `extract-text` by absolute range; optional frontend-local selection adapter |
| Terminal search | Clients page scrollback and search themselves | Cursor-based `search-scrollback` with revision and match ranges |
| Process outcome | `terminal.process.get`, `terminal.wait_exit`, and `TerminalSnapshot.exit` expose one durable child outcome per terminal | Separate execution IDs and lifecycle events for multiple sequential processes in one terminal |
| Terminal history | Paged retained rows have unstable indexes | History revision, cursor pagination, eviction boundary, and explicit clear-history operation |
| Browser basics | Create, input, navigate, back, forward, reload, activate, state, and frames are implemented | Typed methods in every frontend SDK |
| Browser lifecycle | Browser success is asynchronous and CDP failures arrive later | Correlated operation ids, target/crash/dialog/download events, viewport revision, and optional raw CDP profile |
| Client identity | `list-clients` exposes transient connection ids | `hello` or `whoami` with client instance, authenticated principal, rights, credential expiry, and protocol selection |
| Pairing | Trusted Unix clients approve requests; request ids are JSON numbers | Origin allowlist, Origin-aware challenges, JavaScript-safe string ids, and typed SDK callbacks |
| Agents | Explicit reports have durable journal history, but the projection still stores one current agent per terminal | Authenticated adapter context, durable agent ids, multiple agents, root leases, continuations, and semantic transition events |
| Notifications | Creation and one unread marker per inactive surface | Durable records, list/get/read/unread/dismiss/clear/open commands, counts, and lifecycle events |
| Hooks and feeds | Versioned producer and hook manifests, schema-validated ingress, durable cursors, receipts, bounded retries, and causal loop prevention are implemented | Add declarative feed projections and stronger principal-scoped permissions |
| Config | Local JSON contains many unversioned leaves | Versioned JSON Schema, ownership, hot/restart metadata, `get-config`, `validate-config`, `patch-config`, and `config-changed` |
| Plugins | Trusted executable sidebar plugin is implemented | Manifest v1, contribution points, permissions, trust decisions, transactional install/update/remove, and typed management |
| File sidebar | Native TUI reads the host filesystem directly | Classify as local-only, or add a separately permissioned list/stat/read/watch filesystem capability |
| Machines | Dynamic provider v1 is separate and implemented; workspace mirror authority is one shared mux bearer | Replace the shared bearer with a provider-authenticated channel or scoped frontend/operation capabilities; generate its SDK from its own schema |
| Session startup | CLI performs connect-or-start and relay discovery outside the wire protocol | Document socket resolution, ownership, and auto-start; enforce server-side session validation |
| Transport authority and bounds | Child PTYs inherit full-session sockets, relay receives Unix authority, and JSON-lines readers lack common limits | Scoped child capabilities, a restricted relay profile, and one enforced message-size contract across transports |
| Keyboard and menu routing | `Action` and `MenuAction` are local enums with config and UI dispatch | Machine-readable action schemas, active keymap query, collision diagnostics, and the frontend action adapter |
| Host terminal integration | OSC colors, clipboard, pointer shape, graphics, and cell-pixel probing are local side channels | Negotiated host capabilities with ownership, fallback, size, and delivery-result contracts |
| Localization | Native English/Japanese catalogs own part of the chrome | Stable message keys, locale precedence, catalog completeness checks, and frontend-local rendering rules |
| Diagnostics and retention | Transient status plus local debug dumps and bounded subprocess stderr | Permissioned, redacted records with bounds, retention, export, and explicit sensitive-data warnings |
| Session restore/import | Versioned checkpoints capture projections and content-addressed terminal replay; a pure reducer previews checkpoint-plus-tail restoration; immutable segments preserve sealed prefixes | Apply reduced models live, add continuous content offsets, process and agent continuation policy, export/import, and secret-exclusion rules |
| Distribution identity | Binary, protocol, SDK, and registry packages version independently | One support matrix defining version relationships, platform floors, package namespaces, and compatibility guarantees |
| Window integration | Window title requests and frontend projections cover only part of host-window state | Frontend-owned window schema and actions for create, close, focus, move, size, and host capability failures |

## Frontend action adapter

The proposed frontend adapter is a separate, opt-in control profile. A frontend registers an opaque frontend instance id, its action names, schemas, and whether each action is safe for unattended invocation. An authorized caller invokes one registered action with a unique operation id. The frontend returns `accepted`, `completed`, `rejected`, or `unavailable`; completion includes the resulting local projection revision.

The adapter must not grant mux authority to a frontend-only action. It must not serialize transient hover, drag, prompt text, or key-prefix state unless that frontend explicitly declares the field in its projection schema. A disconnected frontend makes its actions unavailable.

## Compatibility profiles

The inventory assigns each command to one disjoint authority group. Generated SDKs expose cumulative profiles:

| Profile | Contents |
| --- | --- |
| `control` | The `control` group: ordinary commands, snapshots, durable terminal identity, and frontend projections |
| `frontend` | `control` plus the `frontend` group: subscriptions, attach streams, browser input, and render data |
| `local-admin` | `control` plus the `local-admin` group on a trusted Unix-classified transport, including the current stdio relay |
| `provider-authority` | `control` plus the `provider-authority` group after separate authority authentication |
| `machine-provider` | Separate provider v0/v1 client and server types |
| `terminal-renderer` | Separate terminal-host v1 frame types with a minted capability |

An SDK must refuse a profile when the selected transport cannot satisfy its trust boundary.

## Conformance bar

Each implemented command needs success, invalid request, target-not-found, and no-op/retry fixtures when those outcomes exist. Each event needs decode fixtures on every stream where it can occur. Stream suites cover ordering, overflow, disconnect, late responses, cancellation, and generation change. Transport suites cover size bounds, partial frames, invalid UTF-8, path resolution, authentication failure, and concurrent requests.

Feature-family `wire_status` records whether a current transport exists. `programmability` records portable typed SDK and conformance completeness. This distinction prevents a live raw command, such as browser control, from being reported as complete while language clients remain uneven.

The initial inventory gate prevents undocumented runtime drift. It does not claim
that the current 11 shared fixtures cover every command in the inventory.
Fixture coverage becomes a required per-command field when deterministic
schema-driven generation replaces the current prompt-based binding script.

## Pending protocol heads

The inventory is based on `main`. [PR 8698](https://github.com/manaflow-ai/cmux/pull/8698) adds clear-history and structured shortcut work and remains `pending` in `inventory.json`. Per-surface client sizing landed with protocol 10 and is part of the implemented inventory.
