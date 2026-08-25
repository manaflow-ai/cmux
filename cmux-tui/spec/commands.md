# Command Contract

This file specifies private protocol-v12 commands for cmux frontends and raw
SDK adapters. Application code should use
[`cmux.protocol/2`](resource-api-v2.md).

Implemented commands match protocol v12 in `cmux-tui/crates/cmux-tui-core/src/server.rs`.

## Notation

Schema notation is compact and machine-oriented:

| Notation | Meaning |
| --- | --- |
| `uint64` | Non-negative integer fitting a Rust `u64` |
| `uint32` | Non-negative integer fitting a Rust `u32` |
| `uint16` | Non-negative integer fitting a Rust `u16` |
| `usize` | Non-negative integer fitting a Rust `usize` |
| `isize` | Signed integer fitting a Rust `isize` |
| `float32` | JSON number read as Rust `f32` |
| `string`, `boolean`, `null` | JSON primitive |
| `T?` | Field may be absent or null unless the command says otherwise |
| `array<T>` | JSON array |
| `object{a:T,b?:U}` | JSON object with required `a` and optional `b` |
| `Base64` | Standard base64 string |
| `ColorHex` | `#rrggbb`, exactly 7 bytes, ASCII hex |
| `Id` | Implemented numeric id, `uint64` |
| `IdRef` | Proposed id reference, `Id` or short id string |

The canonical request and response envelope is defined in `transports.md`. Command blocks in this file define the command-specific request fields and response `data` shape.

Malformed JSON, unknown command names, missing required fields, and wrong JSON types fail during request decoding with the transport-level `bad request: ...` envelope.

The server does not explicitly deny unknown JSON fields. Clients must not depend on unknown fields being rejected.

Common CLI exit codes for every mapping are `0` success, `1` command error, `2` CLI usage error, and `3` connection error.

## Shared Implemented Result Types

`Tree`:

```text
object{workspace_revision?:uint64,pane_revision?:uint64,workspaces:array<Workspace>}
```

`Workspace`:

```text
object{id:Id,key?:string,name:string,active:boolean,screens:array<Screen>}
```

`workspace_revision` and `Workspace.key` are present on servers advertising
`workspace-registry-v1`. They are omitted by older servers, so clients must
treat a missing revision as `0` and a missing key as unavailable.

`pane_revision` changes only when the live pane-ID set changes. Renderers can
use it to invalidate pane-membership caches without scanning unchanged trees.
Older servers omit it, so clients must treat it as unavailable.

`Screen`:

```text
object{
  id:Id,
  name:string|null,
  active:boolean,
  active_pane:Id,
  zoomed_pane:Id|null,
  layout:Layout,
  viewport_base_width?:float32,
  viewport_splits?:array<object{split:Id,width:float32}>,
  panes:array<Pane>
}
```

Servers advertising `viewport-splits-v1` include `viewport_splits` when a screen uses horizontal viewport columns. Each entry marks a right split whose second child is appended to a horizontal virtual canvas. `width` is the second child's width as a fraction of each frontend's viewport. Ordinary screens omit the field. Clients that do not implement the capability may ignore it and render the split's fallback ratio.

Servers advertising `viewport-column-resize-v1` include `viewport_base_width` when horizontal viewport layout is active. It is the width of the first column as a fraction of the frontend viewport. A missing value defaults to `1.0`.

`Layout`:

```text
object{type:"leaf",pane:Id}
| object{type:"split",split:Id,dir:"right"|"down",ratio:float32,a:Layout,b:Layout}
| object{type:"stack",panes:array<Id>,expanded:Id}
```

Stack `panes` must be non-empty, and `expanded` must identify one of those panes.

`split` is stable for the lifetime of that split node. Ratio changes, pane focus, tab changes, and leaf swaps preserve it. Collapsing the split removes the id. A later split receives a new id. Protocol v7 and older canonical layouts omit this field.

`DeclarativeLayout`:

```text
object{type:"leaf",cwd?:string,command?:array<string>}
| object{type:"split",dir:"right"|"down",ratio:float32,a:DeclarativeLayout,b:DeclarativeLayout}
| object{type:"stack",panes:array<Id>,expanded:Id}
```

Applying a stack creates one fresh pane per exported pane id, preserves membership order, and expands the corresponding member. Stack `panes` must be non-empty, and `expanded` must identify one of those panes.

`Pane`:

```text
object{id:Id,name:string|null,active_tab:usize,focused_at?:u64,tabs:array<Tab>}
| object{id:Id,dead:true}
```

`focused_at` is an additive focus-only monotonic sequence. Clients must default it to `0` when connected to servers that omit it.

`Tab`:

```text
object{
  surface: Id,
  kind: "pty"|"browser",
  browser_source: "external"|"launched"|null,
  name: string|null,
  title: string,
  size: object{cols:uint16,rows:uint16}|null,
  dead: boolean
}
```

The `dead` pane variant is serialized only if the tree references a pane missing from state. That should not occur in normal operation, but clients must tolerate it.

## Sizing

Every surface has one authoritative cell grid. Byte and render attach modes observe the same grid; attaching by itself never resizes it.

Each client reports the cell grid available for every surface it displays with
`resize-surface`. A terminal report is a viewport hint until that exact client
and terminal view receive explicit geometry authority through
`set-client-sizing`. One terminal has at most one geometry owner. Other views
crop, pan, or scale the canonical grid and never resize the PTY. Input does not
claim geometry. Releasing or disconnecting the owner freezes the current grid;
the server does not silently elect another owner.

Browser surfaces retain the legacy smallest-reported-grid reducer because a
browser surface still has one live tab. When a browser tab becomes hidden, the
client sends `release-surface-size`; detaching or disconnecting also removes
its report. Internal server-only resizes do not update client reports.

Size-aware creation commands are `apply-layout`, `new-tab`, `new-browser-tab`, `new-workspace`, `new-screen`, `split`, and `run`. Their rules are:

| Input | Behavior |
| --- | --- |
| both `cols` and `rows` supplied | Clamp each to `1..10000`, use the pair for the new surface or surfaces, and record the effective grid as the latest client size |
| neither supplied | Use the latest active client size, or the configured server default when no client reports remain |
| only one supplied | Preserve protocol-v6 behavior: the incomplete pair is ignored; clients must always send both |

`resize-surface` requires both fields and clamps each to `1..10000`. Attached
clients retain the report until release; an unattached one-shot report is
removed when its connection closes. A passive terminal report returns
`accepted:false` because it did not change canonical geometry, but the report
is retained and takes effect if that view later claims authority.

For terminals, `set-client-sizing` claims or releases geometry authority.
`exclusive:true`, `enabled:true`, and no `client` claims authority for the
requesting connection. An explicit `client` may be used by an authorized
controller. Omitting `client` and `exclusive` releases any owner and freezes
the terminal. For browsers, the same command retains the legacy include,
exclude, and exclusive reducer controls.

Frontends report their grid after a surface becomes visible and whenever that viewport changes. They release the report when the surface becomes hidden, even if its attach stream remains cached. A frontend must not re-report merely because another client changed the authoritative surface size. See [`render.md`](render.md#sizing-and-multi-client-presentation) for presentation guidance.

## Implemented Commands

### Durable workspace mutation envelope

`create-workspace`, `rename-workspace`, `move-workspace`, and
`close-workspace` accept the following additive fields:

| Name | JSON type | Required/default | Meaning |
| --- | --- | --- | --- |
| `origin` | `string` | paired with `mutation_id` | Stable frontend/profile identity |
| `mutation_id` | `string` | paired with `origin` | Stable UUID/id reused for every retry of one logical mutation |
| `expected_generation` | `string` | optional | Compare-and-swap guard for the daemon boot UUID |
| `expected_revision` | `uint64` | optional | Compare-and-swap guard for the ordered workspace registry |

The server durably records `(origin, mutation_id)`, the logical request
fingerprint, original result, and committed revision. Duplicate lookup occurs
before generation/revision guards and before resolving a live workspace. A
lost-response retry therefore returns the original result with
`replayed:true`, including after a successful close has tombstoned the key or
after the daemon has restarted. Reusing the same mutation identity for a
different logical payload is an error. Guards are not part of the fingerprint.

Workspace mutation results add `registry_id`, `generation`,
`workspace_revision`, `replayed`, stable `key`, and the compatibility numeric
`workspace` id. Canonical frontend state must use `key`, not the numeric id.

### identify

| Field | Value |
| --- | --- |
| name | `identify` |
| status | implemented |
| since | protocol 5 |

Returns process and protocol metadata for the connected mux server. Clients use this command to verify that the socket endpoint is cmux-tui and to check feature compatibility.

Params: none.

Result:

```text
object{app:"cmux-tui",version:string,build_commit?:string|null,ghostty_commit?:string|null,protocol:uint32,capabilities:array<string>,session:string,pid:uint32,registry_id:string,generation:string,workspace_revision:uint64}
```

`build_commit` and `ghostty_commit` are additive build-stamp fields. They are omitted or `null` when the binary was built without the corresponding stamp, so clients must preserve compatibility with older servers and unstamped local builds.

`capabilities` is additive build-level feature negotiation within a protocol version. Clients must treat a missing field as an empty list. `daemon-handoff-force-v1` advertises the optional `force` field on `shutdown-daemon`. `browser-provider-v1` advertises the trusted-local, connection-scoped native browser provider lease used by cmux-browser and local automation. `browser-pointer-frame-guard-v1` advertises authoritative `pointer_frame_seq` and `pointer_frame_floor_seq` browser attach/frame state plus the additive `browser-frame-presented`, `browser-mouse-guarded`, and `browser-wheel-guarded` commands. Each admitted bitmap receives a new guard even when its document and dimensions match the previous bitmap. The reported floor through latest range proves route membership only. `browser-frame-presented` advances one exact acknowledged token for that connection, and only that token authorizes a new guarded pointer action. A guarded pointer command implicitly acknowledges its own token. Each connection retains one token, while the bounded browser input queue owns actions admitted before a later presentation. Navigation or geometry changes clear the range and all acknowledgements. An accepted press keeps its original guard for motion across ordinary repaints while document and geometry remain valid; invalidation suppresses further motion but retains its balancing release. A capable client echoes that value in `set-client-info`; browser attach requires the bilateral capability while PTY attach remains available without it. The legacy `browser-mouse` and `browser-wheel` schemas retain their optional guard, but guarded servers reject a missing guard before surface lookup. `viewport-splits-v1` advertises `new-pane-right` and the `Screen.viewport_splits` field. `viewport-column-resize-v1` advertises `set-viewport-pane-width` and `Screen.viewport_base_width`. `layout-undo-v1` advertises server-owned structural layout history and `undo-layout`. `view-attachment-lease-v1` returns a connection-owned lease for each attach and enables lease-fenced sizing. `view-attachment-detach-v1` enables targeted stream cleanup. `creation-receipts-v1` enables idempotent destination creation, `creation-attempt-keys-v1` separates a stable correlation from the same-key or new-key execution attempt selected by `session.creation.resolve`, and `creation-selector-fallbacks-v1` adds bounded ordered destination continuations. `provider-managed-workspace-authority-v2` advertises pre-provisioned provider ownership and authority-gated post-provider rename and close commits.

Errors:

| Error | Condition |
| --- | --- |
| `bad request: ...` | Malformed request envelope |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `identify` |
| Flags | none |
| Plain stdout | `cmux-tui session=<session> protocol=<protocol> pid=<pid>` |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"abc123","ghostty_commit":"def456","protocol":12,"capabilities":["attach-initial-size","surface-subscribe-filter","workspace-registry-v1","daemon-handoff-force-v1","browser-provider-v1","browser-pointer-frame-guard-v1","viewport-splits-v1","viewport-column-resize-v1","layout-undo-v1","clear-history-v1","clear-history-key-v1","view-attachment-lease-v1","view-attachment-detach-v1","creation-receipts-v1","creation-attempt-keys-v1","creation-selector-fallbacks-v1","provider-managed-workspace-authority-v2"],"session":"main","pid":12345}}
```

The current server reports protocol `12` in this field and in `ping`. Clients must negotiate protocol 8 before requiring stable split ids or sending `set-split-ratio`, protocol 9 before decoding stack layouts or sending `new-pane`, protocol 10 before using per-surface client sizing, protocol 11 before decoding terminal lifecycle creation results or minting terminal renderer credentials, and protocol 12 before decoding lifecycle readiness from `identify`.

### shutdown-daemon

| Field | Value |
| --- | --- |
| name | `shutdown-daemon` |
| status | implemented |
| since | protocol 9 |
| authority | local-admin |

Gracefully hands the durable session to a replacement daemon. `pid` and `generation` must match the latest `identify` result. A successful response is queued before shutdown begins.

Params:

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `pid` | `uint32` | required | Exact process from `identify` |
| `generation` | `string` | required | Exact daemon boot generation from `identify` |
| `force` | `boolean` | `false` | Requires `daemon-handoff-force-v1`; bypasses native-browser ownership only |

Result: `object{accepted:true,pid:uint32,generation:string}`.

The identity fence and trusted-local authority apply even when `force` is true. A stale process or generation is rejected, so reconnecting the same socket path cannot redirect a recovery command to another daemon.

Errors include stale identity, non-local transport, another native-browser owner when unforced, and an existing handoff.

Example:

```json
{"id":2,"cmd":"shutdown-daemon","pid":12345,"generation":"boot-uuid","force":true}
{"id":2,"ok":true,"data":{"accepted":true,"pid":12345,"generation":"boot-uuid"}}
```

### ping

| Field | Value |
| --- | --- |
| name | `ping` |
| status | implemented |
| since | protocol 6 |

Lightweight liveness probe. Unlike `identify`, this does not return session metadata.

Params: none.

Result:

```text
object{ok:true,version:string,build_commit?:string|null,ghostty_commit?:string|null,protocol:uint32}
```

`build_commit` and `ghostty_commit` have the same optional build-stamp semantics as `identify`.

Errors: `bad request: ...`.

CLI mapping: verb `ping`; flags none; plain stdout prints `cmux-tui version=<version> protocol=<protocol>`; JSON stdout prints the exact result object.

Example:

```json
{"id":2,"cmd":"ping"}
{"id":2,"ok":true,"data":{"ok":true,"version":"0.1.0","build_commit":"abc123","ghostty_commit":"def456","protocol":12}}
```

### set-client-info

| Field | Value |
| --- | --- |
| name | `set-client-info` |
| status | implemented |
| since | protocol 6 additive extension |

Labels the requesting control connection and advertises client capabilities. Repeated calls are idempotent. An omitted field preserves its current value; supplied `name` and `kind` values are clamped to 64 Unicode characters by the server. A supplied `capabilities` array adds recognized capabilities to the connection's set; advertised capabilities cannot be withdrawn during that connection, and unknown capabilities are ignored.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `name` | `string` | default unchanged | Control characters are replaced with spaces; first 64 characters are retained |
| `kind` | `string` | default unchanged | Control characters are replaced with spaces; first 64 characters are retained |
| `capabilities` | `array<string>` | default unchanged | Additive client features understood by the server |

Result: `object{}`.

Errors: `bad request: ...` for wrong JSON types.

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `set-client-info` |
| Flags | `[--name <name>] [--kind <kind>]` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":3,"cmd":"set-client-info","name":"lawrences-iphone","kind":"tui","capabilities":["browser-pointer-frame-guard-v1"]}
{"id":3,"ok":true,"data":{}}
```

### list-clients

| Field | Value |
| --- | --- |
| name | `list-clients` |
| status | implemented |
| since | protocol 6 additive extension |

Returns all current Unix and WebSocket control connections in ascending client-id order. `self` identifies the requesting connection. `connected_seconds` is elapsed monotonic whole seconds. `attached` contains unique surface ids, and each corresponding `sizes` entry has null dimensions until that connection requests `resize-surface` for the attached surface. Protocol v10 reports `size_participating` on each size entry because one client may participate on one terminal and be excluded on another.

Params: none.

Result:

```text
array<object{
  client:uint64,
  transport:"local"|"unix"|"ws",
  name:string|null,
  kind:string|null,
  connected_seconds:uint64,
  attached:array<Id>,
  sizes:array<object{
    surface:Id,
    cols:uint16|null,
    rows:uint16|null,
    size_participating:boolean
  }>,
  self:boolean
}>
```

Errors: `bad request: ...`.

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `list-clients` |
| Flags | none |
| Plain stdout | one line per client: `<client> <transport> <name-or-> <kind-or-> connected=<n>s attached=<ids-or-> sizes=<surface>:<cols>x<rows>:sizing=<bool> self=<bool>` |
| JSON stdout | exact result array |
| Exit codes | common |

Example:

```json
{"id":4,"cmd":"list-clients"}
{"id":4,"ok":true,"data":[{"client":1,"transport":"unix","name":"host","kind":"tui","connected_seconds":12,"attached":[7],"sizes":[{"surface":7,"cols":120,"rows":36,"size_participating":true}],"self":true}]}
```

### register-browser-provider / get-browser-provider

| Field | Value |
| --- | --- |
| names | `register-browser-provider`, `get-browser-provider`, `unregister-browser-provider` |
| status | implemented |
| since | protocol 10 additive extension |
| capability | `browser-provider-v1` |
| authority | local-admin |

These commands lease cmux-browser's native CDP endpoint and canonical tab targets to cmux-tui. The lease is live process state, scoped to the registering Unix-classified control connection, and never enters SQLite or the session journal. Disconnecting the control connection releases its complete target set automatically.

`register-browser-provider` replaces the calling connection's full contribution. Multiple control clients from one native browser process may publish disjoint target sets when their `provider_id`, endpoint, and authentication agree. The deterministic oldest connection supplies a duplicated tab until it disconnects. A different provider process cannot replace the live owner.

Registration params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `provider_id` | `string` | required | 1..128 ASCII identifier characters |
| `endpoint` | `string` | required | Explicit loopback `ws://` URL with a port and no credentials or fragment |
| `authentication` | `"none"|"bearer"` | required | Selects the CDP WebSocket upgrade policy |
| `bearer_token` | `string|null` | default `null` | Required only for bearer authentication; 1..4096 visible ASCII bytes |
| `targets` | `array<object{tab_id:string,target_id:string}>` | required | Complete set for this connection; unique stable tab ids; at most 16,384 entries |

`register-browser-provider` and `get-browser-provider` return:

```text
object{
  available:boolean,
  provider_id?:string,
  endpoint?:string,
  authentication?:"none"|"bearer",
  revision:uint64,
  clients?:uint64,
  targets:array<object{tab_id:string,target_id:string}>
}
```

When unavailable, provider-specific fields are omitted and `targets` is empty. `unregister-browser-provider` returns `object{removed:boolean}` and affects only the calling connection. Endpoints and targets are disclosed only through this trusted-local command; WebSocket control clients are rejected. Bearer tokens are accepted only during registration and are never returned. Bearer mode adds `Authorization: Bearer <token>` to the CDP WebSocket upgrade and is intended for a configurable loopback gateway. The default native endpoint uses an ephemeral loopback port and no bearer.

There is intentionally no dedicated browser automation CLI. Local tools can use `cmux raw command --request-json ...`, select the target by stable `tab_id`, and treat CDP only as a data plane. When cmux-browser owns the session, its bundled helper exposes an upstream `agent-browser.plugin.v1` `browser.provider` adapter: it resolves the caller's workspace from `CMUX_TUI_TERMINAL_ID`, returns a page-scoped target, and never consults shared active/focus state or spawns Chrome.

Example:

```json
{"id":5,"cmd":"register-browser-provider","provider_id":"browser-process-1","endpoint":"ws://127.0.0.1:49152/devtools/browser/secret","authentication":"none","targets":[{"tab_id":"tab_00000000000000000000000000000001","target_id":"page-target-1"}]}
{"id":5,"ok":true,"data":{"available":true,"provider_id":"browser-process-1","endpoint":"ws://127.0.0.1:49152/devtools/browser/secret","authentication":"none","revision":1,"clients":1,"targets":[{"tab_id":"tab_00000000000000000000000000000001","target_id":"page-target-1"}]}}
```

### unregister-browser-provider

| Field | Value |
| --- | --- |
| name | `unregister-browser-provider` |
| status | implemented |
| since | protocol 10 additive extension |
| capability | `browser-provider-v1` |
| authority | local-admin |

Explicitly removes the calling connection's provider contribution and returns `object{removed:boolean}`. Closing that control connection has the same release effect. Other clients from the same `provider_id` and consumer CDP attachments remain independent.

Params: none.

### set-client-sizing

| Field | Value |
| --- | --- |
| name | `set-client-sizing` |
| status | implemented |
| since | protocol 9; per-surface request shape protocol 10 |

Claims or releases terminal geometry authority, or changes legacy browser size
participation. The `surface` field is always required. For a terminal,
`exclusive:true` requires `enabled:true`; omitting `client` selects the
requesting connection. The selected client must have reported a size for that
exact view. Omitting both `client` and `exclusive` releases terminal authority.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Existing terminal or browser surface |
| `client` | `uint64` | optional | Attached or reporting client for this surface; defaults to self for an exclusive terminal claim |
| `enabled` | `boolean` | required | Include or exclude the client |
| `exclusive` | `boolean` | default `false` | Valid with `enabled:true`; an omitted client defaults to the requesting connection for terminals |

Result: `object{}`.

For browser surfaces, `enabled` includes or excludes a size report from the
legacy smallest-grid reducer, and `exclusive:true` retains only the selected
client's report. Errors include `unknown surface <id>`, `client <id> is not
attached to surface <id>`, `client <id> has no reported size for surface <id>`,
and invalid exclusive combinations.

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `set-client-sizing` |
| Flags | `--surface <id> --enabled <true-or-false> [--client <id>] [--exclusive <true-or-false>]` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":5,"cmd":"set-client-sizing","surface":7,"client":1,"enabled":true,"exclusive":true}
{"id":5,"ok":true,"data":{}}
```

### detach-client

| Field | Value |
| --- | --- |
| name | `detach-client` |
| status | implemented |
| since | protocol 6 additive extension |

Ends a control connection. Every attached surface receives its normal `detached` event when the target transport is still writable, then the socket closes. Detaching the requesting client is allowed; the server writes that command's success response before its `detached` events and transport close.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `client` | `uint64` | required | Current client id from `list-clients` |

Result: `object{}`.

Errors:

| Error | Condition |
| --- | --- |
| `unknown client <id>` | Client id is not currently connected |
| `bad request: ...` | Missing `client` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `detach-client` |
| Flags | `--client <id>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":5,"cmd":"detach-client","client":2}
{"id":5,"ok":true,"data":{}}
```

### reload-config

| Field | Value |
| --- | --- |
| name | `reload-config` |
| status | implemented |
| since | protocol 6 |

Requests that attached TUI frontends re-read the cmux-tui config from the same source as startup config loading (`CMUX_TUI_CONFIG`, then legacy `CMUX_MUX_CONFIG`, then `cmux-tui.json` with legacy `mux.json` fallback) and redraw. Headless servers acknowledge the command but have no TUI state to update.

Params: none.

Result:

```text
object{reloaded:true,path:string|null}
```

Live reapply: theme/colors, tab display settings, sidebar width settings, scrollbar placement, and keybindings apply on the next TUI frame. Browser config updates local server launch options for future browser surfaces when a local TUI is present; existing browser runtimes, already-open browser surfaces, and remote headless servers may require restart for browser endpoint/profile/binary changes.

Errors: `bad request: ...`.

CLI mapping: verb `reload-config`; flags none; plain stdout prints nothing; JSON stdout prints the exact result object.

Example:

```json
{"id":3,"cmd":"reload-config"}
{"id":3,"ok":true,"data":{"reloaded":true,"path":"/Users/me/.config/cmux/cmux-tui.json"}}
```

### set-window-title

| Field | Value |
| --- | --- |
| name | `set-window-title` |
| status | implemented |
| since | protocol 6 |

Requests attached TUI frontends to set the outer terminal emulator window title by writing OSC 0 and OSC 2 sequences to their controlling stdout. This is display-only and does not change focus or selection.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `title` | `string` | required | C0 controls are sanitized before OSC output |

Result:

```text
object{}
```

Errors: `bad request: ...`.

CLI mapping: verb `set-window-title`; flags `--title <title>`; plain stdout and JSON stdout are empty result object behavior.

Example:

```json
{"id":4,"cmd":"set-window-title","title":"hello"}
{"id":4,"ok":true,"data":{}}
```

### clear-window-title

| Field | Value |
| --- | --- |
| name | `clear-window-title` |
| status | implemented |
| since | protocol 6 |

Requests attached TUI frontends to restore the default outer terminal window title. The current TUI default is empty.

Params: none.

Result:

```text
object{}
```

Errors: `bad request: ...`.

CLI mapping: verb `clear-window-title`; flags none; plain stdout and JSON stdout are empty result object behavior.

Example:

```json
{"id":5,"cmd":"clear-window-title"}
{"id":5,"ok":true,"data":{}}
```

### list-workspaces

| Field | Value |
| --- | --- |
| name | `list-workspaces` |
| status | implemented |
| since | protocol 5 |

Returns the full workspace, screen, pane, tab, and split-tree snapshot. The
snapshot includes `registry_id`, the current boot `generation`, the durable
`workspace_revision`, and every empty canonical workspace. It also includes
active flags, active pane ids, active tab indexes, tab titles, tab names,
surface kinds, browser source, size, and dead flags.

Params: none.

Result:

```text
Tree
```

Errors:

| Error | Condition |
| --- | --- |
| `bad request: ...` | Malformed request envelope |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `list-workspaces` |
| Flags | none |
| Plain stdout | one stable line per workspace, screen, pane, and tab |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":2,"cmd":"list-workspaces"}
{"id":2,"ok":true,"data":{"workspace_revision":1,"workspaces":[{"id":4,"key":"6ba7b810-9dad-41d1-80b4-00c04fd430c8","name":"1","active":true,"screens":[{"id":3,"name":null,"active":true,"active_pane":2,"layout":{"type":"leaf","pane":2},"panes":[{"id":2,"name":null,"active_tab":0,"focused_at":1,"tabs":[{"surface":1,"kind":"pty","browser_source":null,"name":null,"title":"","size":{"cols":80,"rows":24},"dead":false}]}]}]}]}}
```

### get-frontend-projection / put-frontend-projection

| Field | Value |
| --- | --- |
| names | `get-frontend-projection`, `put-frontend-projection` |
| status | implemented |
| since | protocol 7 |

Stores one opaque, schema-versioned frontend view document per
`(frontend, scope, subject_key)`. Use `scope:"personal"` with a stable
user/profile or device subject for a private durable view. Use
`scope:"shared"` with a stable collaboration-view subject for a document that
multiple clients edit. Existing application-specific scopes, including the
`cmux-browser` `window-group` convention, remain valid.

`put-frontend-projection` additionally requires `schema_version`, a JSON
`projection`, optional `expected_projection_revision`, and `origin` plus
`mutation_id`. It uses its own exactly-once ledger and projection CAS; it does
not advance `workspace_revision`. A projection may contain layouts, browser
content, saved focus or viewport preferences, and any number of placements of
one canonical terminal UUID. It must not encode terminal process ownership or
turn view removal into `terminal.close`. Transient focus, selection, scroll,
crop, pan, hover, drag, and key-prefix state should remain client-local unless
the frontend deliberately saves them as preferences.

Result:

```text
object{frontend:string,scope:string,subject_key:string,schema_version:uint32,projection_revision:uint64,projection:any,replayed?:bool}
```

Missing projections return revision/schema `0` and `projection:null`.
Documents larger than 1 MiB are rejected.

### journal-frontend-event

| Field | Value |
| --- | --- |
| name | `journal-frontend-event` |
| status | implemented |
| since | protocol 10 |

Appends one frontend observation to the session journal. The server derives
the producer identity from the authenticated control client rather than
accepting it from the request.

Params contain one `event` tagged by `kind`:

```text
object{kind:"focus",event_id:string,generation:string,target:"pane"|"machine_rail"|"workspace_rail"|"tabs_rail"|"projection_rail",workspace_id?:string,screen_id?:string,pane_id?:string,tab_id?:string,content_id?:string}
| object{kind:"resize",event_id:string,generation:string,cols:uint16,rows:uint16,cell_width:uint16,cell_height:uint16}
| object{kind:"viewport",event_id:string,generation:string,screen_id?:string,offset:uint64,target:uint64,settled:boolean}
```

`event_id` provides idempotency. `generation` rejects observations from a
stale frontend attachment. Focus identities are optional because the rails
have no pane or tab. Viewport observations record both the current and target
offset so replay can distinguish motion from a settled position.

Result:

```text
object{committed:boolean}
```

### export-layout

| Field | Value |
| --- | --- |
| name | `export-layout` |
| status | implemented |
| since | protocol 6 |

Returns one screen's canonical split tree and the surface ids attached to each leaf pane. Zoom state does not rewrite the exported tree.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `screen` | `Id` | default active screen | Must identify a screen |

Result:

```text
object{layout:Layout,viewport_base_width?:float32,viewport_splits?:array<object{split:Id,width:float32}>,panes:array<object{pane:Id,surfaces:array<Id>}>}
```

Errors: `unknown screen <id>`, `no active screen`, `bad request: ...`.

CLI mapping: verb `export-layout`; flags `[--screen <id>]`; plain stdout and JSON stdout both print the exact result object.

The result is an identity-bearing runtime snapshot for inspection. Its `layout` is not the declarative `layout` input accepted by `apply-layout`.

### apply-layout

| Field | Value |
| --- | --- |
| name | `apply-layout` |
| status | implemented |
| since | protocol 6 |

Creates a new screen in the given or active workspace from a declarative layout. Each leaf or stack member creates a new pane with one PTY surface. `command` is argv (`array<string>`), not a shell string. Ratios use the same clamp path as `set-ratio`. Initial dimensions follow the shared [Sizing](#sizing) contract; one supplied dimension without the other retains the protocol-v6 incomplete-pair behavior.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | default active workspace | Existing workspace; if omitted and none exists, one is created |
| `name` | `string` | default null | New screen name |
| `layout` | `DeclarativeLayout` | required | Must contain at least one pane |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |
Result:

```text
object{screen:Id,panes:array<object{pane:Id,surface:Id}>}
```

Errors: `unknown workspace <id>`, `layout must contain at least one leaf`, `leaf command must not be empty`, spawn or PTY error string, `bad request: ...`.

CLI mapping: verb `apply-layout`; flags `[--workspace <id>] [--name <name>] [--cols <n> --rows <n>] --layout <json>`; plain stdout prints the new screen and created pane/surface pairs; JSON stdout prints the exact result object.

### send

| Field | Value |
| --- | --- |
| name | `send` |
| status | implemented |
| since | protocol 5 |
| `paste` field | protocol 7 additive extension |

Writes input to a PTY surface. `text`, when present, is UTF-8 encoded and written as bytes. `bytes`, when present, is standard base64 decoded and written as raw bytes. If both are present, v5 writes `text` first and `bytes` second. If neither is present, v5 returns success and writes nothing.

Protocol v7 adds `paste`. The payload is the concatenation of encoded `text` followed by decoded `bytes`. With `paste:true` and a non-empty payload, the server checks the target terminal's current DEC private mode 2004 while holding the terminal/input lock. If enabled, it writes `ESC [ 200 ~`, the payload, then `ESC [ 201 ~`; if disabled, it writes the payload unchanged. `paste:false` is the exact v5/v6 path. The server does not inspect or remove caller-supplied bracketed-paste markers.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |
| `text` | `string` | default null | Written before `bytes` when both are present |
| `bytes` | `Base64` | default null | Decoded with standard base64 |
| `paste` | `boolean` | default false | Protocol 7; conditionally wraps the combined non-empty payload when DEC mode 2004 is enabled |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser surface does not support PTY/VT socket commands` | Surface is a browser |
| base64 decode error | `bytes` is not valid standard base64 |
| IO error string | PTY write fails |
| `bad request: ...` | Missing `surface` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `send` |
| Flags | `--surface <id> [--text <text>] [--bytes <base64>] [--paste]` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

When neither `--text` nor `--bytes` is supplied, the CLI reads stdin as text and sends it as `text`.

Example:

```json
{"id":3,"cmd":"send","surface":1,"text":"ls\r"}
{"id":3,"ok":true,"data":{}}
```

### read-screen

| Field | Value |
| --- | --- |
| name | `read-screen` |
| status | implemented |
| since | protocol 5 |

Returns the current plain-text viewport of a PTY surface. The text is produced by the Ghostty VT terminal state and does not include prior scrollback beyond the current screen.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |

Result:

```text
object{text:string}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser surface does not support PTY/VT socket commands` | Surface is a browser |
| terminal error string | VT plain-text extraction fails |
| `bad request: ...` | Missing `surface` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `read-screen` |
| Flags | `--surface <id>` |
| Plain stdout | `text` exactly |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":4,"cmd":"read-screen","surface":1}
{"id":4,"ok":true,"data":{"text":"$ ls\nREADME.md\n"}}
```

### clear-history

| Field | Value |
| --- | --- |
| name | `clear-history` |
| status | implemented |
| since | protocol 9 with `clear-history-v1` |

On a primary screen with OSC 133 prompt metadata, clears retained scrollback and complete visible rows before the active prompt inside the terminal emulator. The prompt, edit buffer, and cursor remain in place, and no bytes are written to the child process. Without prompt metadata, only retained scrollback is cleared, preserving the visible grid and cursor. The authoritative server terminal and attached frontend mirrors receive the same VT erase sequence.

The command fails without changing history, the visible grid, or the cursor when active input extends into retained history or exact preservation cannot be proven. If the terminal stream ends inside an incomplete VT sequence, the server waits for a bounded interval and then fails without mutation unless the sequence completes. Repeated requests against the same unchanged stream share that interval. After it expires, only new PTY output permits a fresh interval.

Clients must require `identify.capabilities` to contain `clear-history-v1` before sending this command.

When the alternate screen is active, the command leaves both screens untouched. If `fallback_key` is present, the server encodes that structured key from its authoritative terminal keyboard modes and writes the encoded bytes to the PTY. If the active keyboard mode cannot represent the key, the command fails without writing bytes. If `fallback_key` is absent, the alternate-screen request succeeds as a no-op. Clients must require both `clear-history-v1` and `clear-history-key-v1` before sending `fallback_key`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |
| `fallback_key` | `TerminalKeyInput \| null` | default null | Requires `clear-history-key-v1`; ignored on the primary screen |

`TerminalKeyInput` preserves the frontend key event so the server can apply its current Kitty keyboard and terminal mode state:

| Field | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `key` | `TerminalKey` | required | One of the symbolic values below |
| `mods` | `TerminalModifiers` | required | Exact active modifier state |
| `consumed_mods` | `TerminalModifiers` | required | Must be a subset of `mods` |
| `composing` | `boolean` | default false | Whether the key belongs to an uncommitted composition sequence |
| `utf8` | `string` | required | At most 4 KiB of UTF-8 and contains no control characters |
| `unshifted_codepoint` | `string \| null` | default null | Exactly one Unicode scalar when present |
| `shifted_codepoint` | `string \| null` | default null | Shifted logical identity; exactly one Unicode scalar when present |
| `base_layout_codepoint` | `string \| null` | default null | Explicit PC-101 base-layout identity; exactly one Unicode scalar when present |
| `action` | `"press" \| "release" \| "repeat" \| null` | default null | Key action when known |
| `macos_option_as_alt` | `boolean` | required | `false` is valid only when Alt is active and consumed |

`TerminalModifiers` contains six required booleans: `shift`, `control`, `alt`, `super`, `caps_lock`, and `num_lock`. Unknown fields are rejected.

`TerminalKey` accepts these exact kebab-case values:

```text
unidentified backquote backslash bracket-left bracket-right comma
digit0 digit1 digit2 digit3 digit4 digit5 digit6 digit7 digit8 digit9 equal
a b c d e f g h i j k l m n o p q r s t u v w x y z
minus period quote semicolon slash backspace enter space tab delete end home insert
page-down page-up arrow-down arrow-left arrow-right arrow-up
numpad0 numpad1 numpad2 numpad3 numpad4 numpad5 numpad6 numpad7 numpad8 numpad9
numpad-add numpad-backspace numpad-comma numpad-decimal numpad-divide numpad-enter
numpad-equal numpad-multiply numpad-subtract numpad-up numpad-down numpad-right
numpad-left numpad-begin numpad-home numpad-end numpad-insert numpad-delete
numpad-page-up numpad-page-down escape
f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16 f17 f18 f19 f20
```

Result: empty object.

Failed `clear-history` responses include the response-envelope `error_delivery` field. Clients may
retry or preserve the input lane after `"known-not-delivered"`. They must quarantine the affected
input lane after `"ambiguous"` because fallback input may have reached the PTY.

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser surface does not support PTY/VT socket commands` | Surface is a browser |
| `active terminal input extends into retained history` | The prompt or active input cannot be preserved exactly |
| `terminal output did not reach a safe clear-history boundary` | An incomplete VT sequence did not finish before the bounded wait expired |
| `terminal keyboard mode cannot encode clear-history fallback key` | The alternate-screen fallback key is not representable in the active keyboard mode |
| `bad request: ...` | Missing `surface` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `clear-history` |
| Flags | `--surface <id>` |
| Plain stdout | none |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":5,"cmd":"clear-history","surface":1}
{"id":5,"ok":true,"data":{}}
```

Alternate-screen key fallback:

```json
{"id":6,"cmd":"clear-history","surface":1,"fallback_key":{"key":"k","mods":{"shift":false,"control":false,"alt":false,"super":true,"caps_lock":false,"num_lock":false},"consumed_mods":{"shift":false,"control":false,"alt":false,"super":false,"caps_lock":false,"num_lock":false},"composing":false,"utf8":"","unshifted_codepoint":"k","shifted_codepoint":null,"base_layout_codepoint":"k","action":"press","macos_option_as_alt":true}}
{"id":6,"ok":true,"data":{}}
```

### sidebar-plugin

| Field | Value |
| --- | --- |
| name | `sidebar-plugin` |
| CLI mapping | none (client-internal: issued by attach clients to obtain the sidebar plugin surface) |
| status | implemented |
| since | protocol 6 |

Ensures the configured server-owned sidebar plugin PTY exists at the requested size and returns the surface id to render through `attach-surface`. This command does not install, build, or discover plugins; it only hosts the command already configured in server-side cmux-tui config.

Params:

```text
object{cmd:"sidebar-plugin",cols:uint16,rows:uint16,relaunch?:boolean}
```

Result:

```text
object{surface:Id|null,error:string|null,retry_after_ms:uint64|null}
```

Compatibility notes:

- Attached clients use this command to obtain the server-owned plugin surface, then render it through `attach-surface` and send input through `send`.
- If no sidebar plugin is configured, `surface`, `error`, and `retry_after_ms` are all `null`.
- If the plugin exited or failed to start, `error` is populated. The server may also return `retry_after_ms` to indicate restart backoff. A client should pass `relaunch:true` only when the user focuses the sidebar or explicitly retries.

Example:

```json
{"id":104,"cmd":"sidebar-plugin","cols":21,"rows":30,"relaunch":true}
{"id":104,"ok":true,"data":{"surface":42,"error":null,"retry_after_ms":null}}
```

### vt-state

| Field | Value |
| --- | --- |
| name | `vt-state` |
| status | implemented |
| since | protocol 5 |

Returns a one-shot base64 VT replay for a PTY surface, including the current screen, styles, cursor, modes, palette, keyboard protocol state, charsets, tabstops, Kitty image-number aliases, resource limits, and per-screen automatic image-ID cursors. Apply `data` through `replay_cursor_offset`, install the replay cursors, apply the remaining `data`, restore `kitty_image_aliases`, then install the steady-state cursors before live output.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |

Result:

```text
object{cols:uint16,rows:uint16,data:Base64,kitty_image_aliases?:array<KittyImageAlias>,kitty_graphics_state?:KittyGraphicsState}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser surface does not support PTY/VT socket commands` | Surface is a browser |
| terminal error string | VT replay generation fails |
| `bad request: ...` | Missing `surface` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `vt-state` |
| Flags | `--surface <id>` |
| Plain stdout | `cols=<cols> rows=<rows> data=<base64>` |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":5,"cmd":"vt-state","surface":1}
{"id":5,"ok":true,"data":{"cols":80,"rows":24,"data":"G1s/bA=="}}
```

### new-tab

| Field | Value |
| --- | --- |
| name | `new-tab` |
| status | implemented |
| since | protocol 5 |

Creates a new PTY tab in a pane and makes it the active tab. If `pane` is absent, the active pane of the active screen is used. If the selected workspace exists but has no screens, the command materializes its first screen, pane, and terminal and preserves `cwd`. If the session has no workspaces, the command creates a workspace containing the tab; that legacy fallback ignores `cwd`. The new tab inherits the active surface working directory of the target pane when `cwd` is absent. When there is nothing to inherit, the terminal starts in the directory the session daemon was launched from, and falls back to the user home directory only when that directory no longer exists. Initial dimensions follow [Sizing](#sizing).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | default null | Target pane; unknown ids error |
| `cwd` | `string` | default null | PTY child working directory |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |

If only one of `cols` or `rows` is present, the server ignores both because it uses `cols.zip(rows)`.

Result:

```text
object{surface:Id}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown pane <id>` | Supplied pane id does not exist |
| `pane disappeared while creating tab` | Target pane vanished after validation |
| spawn or PTY error string | PTY creation or child spawn fails |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `new-tab` |
| Flags | `[--pane <id>] [--cwd <path>] [--cols <n> --rows <n>]` |
| Plain stdout | new surface id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":6,"cmd":"new-tab","pane":2,"cwd":"/tmp","cols":100,"rows":30}
{"id":6,"ok":true,"data":{"surface":5}}
```

### new-browser-tab

| Field | Value |
| --- | --- |
| name | `new-browser-tab` |
| status | implemented |
| since | protocol 5 |

Creates a browser tab in a pane and makes it active. If `pane` is absent, the active pane is used. If the selected workspace exists but has no screens, the command materializes its first screen, pane, and browser tab. If the session has no workspaces, the command creates a workspace containing the browser tab. The canonical tab waits for cmux-browser to publish its stable `tab_id` target; the mux never discovers or launches Chrome. An explicit configured CDP URL remains a development-only compatibility path. Initial dimensions follow [Sizing](#sizing).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `url` | `string` | required | Normalized by browser runtime |
| `pane` | `Id` | default null | Target pane; unknown ids error |
| `cols` | `uint16` | default null | Used only when paired with `rows` |
| `rows` | `uint16` | default null | Used only when paired with `cols` |

Result:

```text
object{surface:Id}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown pane <id>` | Supplied pane id does not exist |
| `pane disappeared while creating browser tab` | Target pane vanished after validation |
| browser/CDP error string | Browser runtime connect, target create, attach, setup, or Chrome launch fails |
| `bad request: ...` | Missing `url` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `new-browser-tab` |
| Flags | `--url <url> [--pane <id>] [--cols <n> --rows <n>]` |
| Plain stdout | new surface id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":7,"cmd":"new-browser-tab","url":"https://example.com","pane":2}
{"id":7,"ok":true,"data":{"surface":8}}
```

### new-workspace

| Field | Value |
| --- | --- |
| name | `new-workspace` |
| status | implemented |
| since | protocol 5 |

Creates a new workspace with one screen, one pane, and one PTY tab, then makes the new workspace active. If `name` is absent, the workspace name is the zero-based workspace count at creation time. Initial dimensions follow [Sizing](#sizing).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `name` | `string` | default null | Workspace name; empty string is accepted |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |

Result:

```text
object{surface:Id}
```

Errors:

| Error | Condition |
| --- | --- |
| spawn or PTY error string | PTY creation or child spawn fails |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `new-workspace` |
| Flags | `[--name <name>] [--cols <n> --rows <n>]` |
| Plain stdout | new surface id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":8,"cmd":"new-workspace","name":"ops"}
{"id":8,"ok":true,"data":{"surface":10}}
```

### create-workspace

Requires the `workspace-registry-v1` capability. Clients must not send this command to a server that omits the capability.

| Field | Value |
| --- | --- |
| name | `create-workspace` |
| status | implemented |
| since | protocol 7 |

Creates a canonical ordered workspace without implicitly spawning a terminal,
pane, or screen. This is the preferred GUI workflow: commit the shared
workspace first, then create browser-only layout or a terminal inside its
stable `key`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `name` | `string` | default null | Defaults to the zero-based workspace count at creation time |
| `key` | `string` | default generated UUID | Must be a lowercase canonical UUID and never previously used |
| mutation fields | see [common envelope](#durable-workspace-mutation-envelope) | optional | Exactly-once retry and CAS |

Result:

```text
object{workspace:Id,key:string,index:usize,workspace_revision:uint64,replayed:bool,registry_id:string,generation:string}
```

Errors include `workspace key must be a lowercase UUID`, `workspace key already exists: <key>`, `workspace revision conflict: expected <n>, current <n>`, and malformed request errors.

Example:

```json
{"id":9,"cmd":"create-workspace","name":"ops","key":"9dc5432b-6e28-4b58-9f35-75b263f6e84f","expected_revision":1}
{"id":9,"ok":true,"data":{"workspace":12,"key":"9dc5432b-6e28-4b58-9f35-75b263f6e84f","index":1,"workspace_revision":2}}
```

The server retains tombstones indefinitely; a closed `key` cannot be reused.
The last terminal exiting never closes this workspace. Only
`close-workspace` removes it from the live registry.

### create-terminal

Requires the `workspace-registry-v1` capability. Clients must not send this command to a server that omits the capability.

| Field | Value |
| --- | --- |
| name | `create-terminal` |
| status | implemented |
| since | protocol 7 |

Creates a PTY tab in the workspace selected by stable `key` or compatibility
numeric `workspace`. An empty workspace is materialized in place with its
first screen and pane; no workspace revision is advanced. `argv` executes
directly, while `command` executes through the default shell.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | required unless `key` is supplied | Mutually identifies the target with `key` |
| `key` | `string` | required unless `workspace` is supplied | Lowercase canonical workspace UUID; must match `workspace` when both are supplied |
| `argv` | `string[]` | default shell | Mutually exclusive with `command`; must be non-empty when supplied |
| `command` | `string` | default null | Mutually exclusive with `argv`; must be non-empty when supplied |
| `cwd` | `string` | default inherited | PTY child working directory |
| `name` | `string` | default null | New terminal tab name |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |
| `terminal_id` | `string` | default generated | Caller-reserved canonical 32-character terminal UUID; requires mutation identity |
| `origin` | `string` | paired with `mutation_id` | Stable frontend/profile identity reused for retries |
| `mutation_id` | `string` | paired with `origin` | Stable logical creation id reused for retries |
| `expected_generation` | `string` | optional | Compare-and-swap guard for the daemon boot UUID |
| `expected_revision` | `uint64` | optional | Compare-and-swap guard for the resource projection revision |

Result:

```text
object{
  surface:Id|null,terminal_id:string,terminal_incarnation:string|null,
  pane:Id|null,screen:Id|null,workspace:Id|null,key:string,
  lifecycle:"launching"|"adopting"|"running"|"exited"|"tombstoned",
  exit:TerminalExit|null,
  already_exited:bool,terminal_revision:uint64,replayed:bool,
  registry_id:string,generation:string
}
```

If the child exits before creation returns, the request still succeeds with
`already_exited:true`, exact durable `exit` metadata, and null live-placement
fields. Retrying with the same `origin`, `mutation_id`, and logical request
returns the same terminal and exit record without recreating its tab or
process. Reusing a mutation identity with different parameters is an error.

Errors include missing, unknown, or mismatched workspace selectors; mutually exclusive or empty commands; PTY spawn failures; and malformed requests.

Example:

```json
{"id":10,"cmd":"create-terminal","key":"9dc5432b-6e28-4b58-9f35-75b263f6e84f","command":"htop","cwd":"/tmp","terminal_id":"00000000000040008000000000000001","origin":"ios-demo","mutation_id":"create-monitor"}
{"id":10,"ok":true,"data":{"surface":15,"terminal_id":"00000000000040008000000000000001","terminal_incarnation":"00000000000040008000000000000002","pane":14,"screen":13,"workspace":12,"key":"9dc5432b-6e28-4b58-9f35-75b263f6e84f","lifecycle":"running","exit":null,"already_exited":false,"terminal_revision":4,"replayed":false,"registry_id":"71f24185-113a-4eb0-9286-1e20743e7e05","generation":"37928442-1982-40b6-bf80-c1ea50ca8bf8"}}
{"id":11,"cmd":"create-terminal","key":"9dc5432b-6e28-4b58-9f35-75b263f6e84f","command":"exit 7","terminal_id":"00000000000040008000000000000003","origin":"ios-demo","mutation_id":"create-short-job"}
{"id":11,"ok":true,"data":{"surface":null,"terminal_id":"00000000000040008000000000000003","terminal_incarnation":null,"pane":null,"screen":null,"workspace":null,"key":"9dc5432b-6e28-4b58-9f35-75b263f6e84f","lifecycle":"exited","exit":{"outcome":{"kind":"exit","code":7},"exited_at_ms":1785900000000},"already_exited":true,"terminal_revision":6,"replayed":false,"registry_id":"71f24185-113a-4eb0-9286-1e20743e7e05","generation":"37928442-1982-40b6-bf80-c1ea50ca8bf8"}}
```

### new-screen

| Field | Value |
| --- | --- |
| name | `new-screen` |
| status | implemented |
| since | protocol 5 |

Creates a new screen in a workspace with one pane and one PTY tab, then makes the new screen active. If `workspace` is absent, the active workspace is used. If no workspace exists and `workspace` is absent, v5 creates a new workspace instead. Initial dimensions follow [Sizing](#sizing).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | default null | Target workspace; unknown ids error |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |

Result:

```text
object{surface:Id}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown workspace <id>` | Supplied workspace id does not exist |
| `workspace disappeared while creating screen` | Target workspace vanished after validation |
| spawn or PTY error string | PTY creation or child spawn fails |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `new-screen` |
| Flags | `[--workspace <id>] [--cols <n> --rows <n>]` |
| Plain stdout | new surface id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":9,"cmd":"new-screen","workspace":4}
{"id":9,"ok":true,"data":{"surface":12}}
```

### new-pane

| Field | Value |
| --- | --- |
| name | `new-pane` |
| status | implemented |
| since | protocol 9 |

Creates a PTY pane after the current panes in creation order, focuses it, and reapplies the default automatic layout inside the horizontal viewport column containing `pane`. A screen without horizontal viewport columns is one implicit column, preserving the original whole-screen behavior. Panes one through five use one full-height left column and up to four equal right-side rows. Panes six through twelve fill balanced columns of four. Above twelve panes, the first pane stays full-height on the left while the remaining panes form a right-side stack whose focused member expands. The new surface inherits the active surface working directory of `pane` when available.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Pane whose horizontal column receives the new pane |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |

Result:

```text
object{surface:Id}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown pane <id>` | Target pane is not in any screen tree |
| `pane creation failed` | PTY creation or child spawn fails; raw runtime details are logged internally only |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `new-pane` |
| Flags | `--pane <id> [--cols <n> --rows <n>]` |
| Plain stdout | new surface id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":10,"cmd":"new-pane","pane":2}
{"id":10,"ok":true,"data":{"surface":14}}
```

### new-pane-right

| Field | Value |
| --- | --- |
| name | `new-pane-right` |
| status | implemented |
| since | protocol 9 additive capability `viewport-splits-v1` |

Creates and focuses one PTY column immediately to the right of the horizontal viewport column containing `pane`. Supporting frontends keep each existing column at its independent viewport-relative width and insert the new pane at `width` times the viewport width. The default is two thirds. The shared split tree stores equivalent proportional fallback ratios for clients that ignore viewport metadata. The new surface inherits the active surface working directory of `pane` when available.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Pane whose screen receives the new pane |
| `width` | `float32` | default `0.6666667` | From 0.1 through 1.0 |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |

Result:

```text
object{surface:Id}
```

Errors:

| Error | Condition |
| --- | --- |
| `pane <id> has no workspace` | Target pane is not in a screen |
| `viewport pane width must be between 0.1 and 1.0` | `width` is outside the supported range |
| `pane creation failed` | PTY creation or child spawn fails; raw runtime details are logged internally only |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `new-pane-right` |
| Flags | `--pane <id> [--width <fraction>] [--cols <n> --rows <n>]` |
| Plain stdout | new surface id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":11,"cmd":"new-pane-right","pane":2}
{"id":11,"ok":true,"data":{"surface":15}}
```

### set-viewport-pane-width

| Field | Value |
| --- | --- |
| name | `set-viewport-pane-width` |
| status | implemented |
| since | protocol 9 additive capability `viewport-column-resize-v1` |

Sets the width of the horizontal viewport column containing `pane`. Every pane nested inside that column keeps its internal split ratios. The command updates proportional fallback ratios for clients that ignore viewport metadata.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Must belong to a screen with viewport columns |
| `width` | `float32` | required | Finite value from 0.1 through 1.0 |
| `transaction` | `uint64` | default null | Samples with the same connection and transaction coalesce into one undo entry |

Result: empty object.

Errors:

| Error | Condition |
| --- | --- |
| `viewport pane width must be between 0.1 and 1.0` | `width` is non-finite or outside the supported range |
| `pane <id> has no resizable viewport column` | Pane is unknown or its screen has no viewport columns |
| `bad request: ...` | Missing fields or wrong JSON type |

Invalid widths return `error_code:"viewport-width-out-of-range"`. A missing pane or a pane outside a viewport layout returns `error_code:"viewport-column-not-found"`.

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `set-viewport-pane-width` |
| Flags | `--pane <id> --width <fraction>` |
| Plain stdout | empty |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":12,"cmd":"set-viewport-pane-width","pane":15,"width":0.5}
{"id":12,"ok":true,"data":{}}
```

### undo-layout

| Field | Value |
| --- | --- |
| name | `undo-layout` |
| status | implemented |
| since | protocol 9 additive capability `layout-undo-v1` |

Undoes the latest structural layout entry on the screen containing `pane`. History is owned by that screen, capped at 32 entries, and kept in memory only. Resize samples carrying the same connection-scoped `transaction` coalesce. A new transaction, another connection, or a request without a transaction starts a new undo entry. Pane creation, split and column resize, swap, zoom, and automatic-layout changes are undoable. A direct pane close clears that screen's history because the journal cannot reconstruct exact removed tab membership or a closed browser target.

If the entry created panes, the first request returns a confirmation preview. The server advances to a unique confirmation revision and binds it to the exact ordered surface membership of every pane in `closes_panes`. The client must show the consequence, then resend that revision with `confirm_close:true`. Confirming detaches PTY terminal views and closes single-view browser surfaces; it never invokes `terminal.close`. A later structural change, tab addition, tab removal, tab reorder, tab move, or newer preview invalidates the confirmation. A rejected or stale confirmation changes nothing.

Clients must reject the response unless it contains exactly one complete result variant. The applied variant requires `undone:true`, `screen`, and `revision`, with `confirmation_required` either absent or false. The preview variant requires `undone:false`, `confirmation_required:true`, `screen`, `revision`, and an array of valid pane ids in `closes_panes`. Missing fields, contradictory outcome flags, invalid ids, and non-array `closes_panes` values are protocol errors.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Selects the screen whose history is used |
| `revision` | `uint64` | default null | Required for a confirmed pane-closing undo; must equal the preview revision |
| `confirm_close` | `boolean` | default false | Must be true to commit an undo that closes panes |

Result:

```text
object{undone:true,screen:Id,revision:uint64}
| object{undone:false,confirmation_required:true,screen:Id,revision:uint64,closes_panes:array<Id>}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown pane <id>` | `pane` is not in a live screen |
| `no layout change to undo` | The selected screen has no undo entry |
| `confirmed layout undo requires the preview revision` | `confirm_close` is true without `revision` |
| `layout revision conflict: expected <n>, current <n>` | The confirmation revision is stale or incorrect |
| `tabs in pane <id> changed since the undo confirmation` | A pane's surface membership differs from the preview |
| `layout changed before undo could commit` | The layout changed after validation and before commit |
| `bad request: ...` | Missing fields or wrong JSON type |

Expected failures also include a machine-readable response `error_code`.
`layout-undo-unavailable` means the screen has no undo entry.
`layout-undo-stale` means a previously valid entry or confirmation can no
longer commit. Other failures omit `error_code`.

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `undo-layout` |
| Flags | `--pane <id> [--revision <n> --confirm-close]` |
| Plain stdout | undo line, or confirmation instructions with the revision and closing pane ids |
| JSON stdout | exact result object |
| Exit codes | common |

Examples:

```json
{"id":13,"cmd":"undo-layout","pane":15}
{"id":13,"ok":true,"data":{"undone":false,"confirmation_required":true,"screen":3,"revision":8,"closes_panes":[15]}}
{"id":14,"cmd":"undo-layout","pane":15,"revision":8,"confirm_close":true}
{"id":14,"ok":true,"data":{"undone":true,"screen":3,"revision":9}}
```

### split

| Field | Value |
| --- | --- |
| name | `split` |
| status | implemented |
| since | protocol 5 |

Splits the screen containing `pane`, inserts a new pane after the target leaf, spawns one PTY tab in the new pane, and focuses the new pane. `dir:"right"` creates left/right columns. `dir:"down"` creates top/bottom rows. The new surface inherits the active surface working directory of the target pane when available. Initial dimensions follow [Sizing](#sizing).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Target split leaf |
| `dir` | `string` | required | `"right"` or `"down"` |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |

Result:

```text
object{surface:Id}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad dir "<value>" (want "right" or "down")` | `dir` is not allowed |
| `pane <id> not found` | Target pane is not in any screen split tree |
| spawn or PTY error string | PTY creation or child spawn fails |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `split` |
| Flags | `--pane <id> --dir right|down [--cols <n> --rows <n>]` |
| Plain stdout | new surface id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":10,"cmd":"split","pane":2,"dir":"right"}
{"id":10,"ok":true,"data":{"surface":14}}
```

### set-ratio

| Field | Value |
| --- | --- |
| name | `set-ratio` |
| status | implemented |
| since | protocol 5 |

Sets the deepest split ratio in `dir` on the path to `pane`. The server clamps the supplied ratio to `0.05..0.95` before applying it. The result does not report the clamped value.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Pane used to find a split on its ancestor path |
| `dir` | `string` | required | `"right"` or `"down"` |
| `ratio` | `float32` | required | Clamped to `0.05..0.95` |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad dir "<value>" (want "right" or "down")` | `dir` is not allowed |
| `unknown pane/split <id>` | Pane is unknown or no ancestor split has `dir` |
| `split <id> ratio ... width must be between 0.1 and 1` | The projected viewport split cannot represent the clamped ratio |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `set-ratio` |
| Flags | `--pane <id> --dir right|down --ratio <number>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":11,"cmd":"set-ratio","pane":2,"dir":"right","ratio":0.7}
{"id":11,"ok":true,"data":{}}
```

`set-ratio` remains supported in protocol v8 for existing clients. Its pane-and-direction lookup can be ambiguous when same-direction splits are nested, so new frontends should use `set-split-ratio` with the canonical layout's stable split id.

### set-split-ratio

| Field | Value |
| --- | --- |
| name | `set-split-ratio` |
| status | implemented |
| since | protocol 8 |

Sets the ratio of exactly one canonical split node. The server clamps the supplied ratio to `0.05..0.95`. The split id and every unrelated node remain unchanged. A compatibility split representing a horizontal viewport column also preserves the column width invariant `0.1..1.0`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `split` | `Id` | required | Stable split id from `list-workspaces` or `export-layout` |
| `ratio` | `float32` | required | Clamped to `0.05..0.95` |
| `transaction` | `uint64` | default null | Samples with the same connection and transaction coalesce into one undo entry |

Result: `object{}`.

Errors:

| Error | Condition |
| --- | --- |
| `unknown split <id>` | No live split node has the id |
| `split <id> ratio ... width must be between 0.1 and 1` | The live viewport split would require an unsupported column width; layout remains unchanged |
| `bad request: ...` | Missing fields or wrong JSON type |

Missing targets return `error_code:"layout-ratio-target-missing"`. Unsupported viewport widths return `error_code:"layout-ratio-out-of-range"`.

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `set-split-ratio` |
| Flags | `--split <id> --ratio <number>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":12,"cmd":"set-split-ratio","split":9,"ratio":0.7}
{"id":12,"ok":true,"data":{}}
```

### pane-neighbor

| Field | Value |
| --- | --- |
| name | `pane-neighbor` |
| status | implemented |
| since | protocol 6 |

Queries the directional adjacent pane in the screen split layout. It does not change focus.

Params: `object{pane:Id,dir:"left"|"right"|"up"|"down"}`.

Result:

```text
object{pane:Id|null}
```

Errors: `unknown pane <id>`, bad `dir`, `bad request: ...`.

CLI mapping: verb `pane-neighbor`; flags `--pane <id> --dir left|right|up|down`; plain stdout prints the pane id or `null`; JSON stdout prints the exact result object.

### focus-direction

| Field | Value |
| --- | --- |
| name | `focus-direction` |
| status | implemented |
| since | protocol 6 |

Moves focus from the supplied pane, or the active pane, to its directional neighbor.

Params: `object{pane?:Id,dir:"left"|"right"|"up"|"down"}`.

Result:

```text
object{pane:Id}
```

Errors: `no active pane`, `unknown pane <id>`, `no neighbor`, bad `dir`, `bad request: ...`.

CLI mapping: verb `focus-direction`; flags `[--pane <id>] --dir left|right|up|down`; plain stdout prints the focused pane id; JSON stdout prints the exact result object.

### swap-pane

| Field | Value |
| --- | --- |
| name | `swap-pane` |
| status | implemented |
| since | protocol 6 |

Exchanges two pane leaves in the split tree, preserving each pane's tabs and all split ratios. The target is either a directional neighbor or an explicit pane id.

Params: `object{pane:Id,dir:"left"|"right"|"up"|"down"}` or `object{pane:Id,target:Id}`.

Result: `object{}`.

Errors: `one of dir or target is required`, `use only one of dir or target`, `no neighbor`, `unknown pane/target`, bad `dir`, `bad request: ...`.

CLI mapping: verb `swap-pane`; flags `--pane <id> (--dir left|right|up|down | --target <id>)`; plain stdout no output; JSON stdout exact result object.

### zoom-pane

| Field | Value |
| --- | --- |
| name | `zoom-pane` |
| status | implemented |
| since | protocol 6 |

Sets per-screen zoom state. A zoomed pane renders as the only pane in its screen; the canonical split tree is preserved for restore and export.

Params: `object{pane?:Id,mode?:"toggle"|"on"|"off"}`. Defaults: active pane and `toggle`.

Result:

```text
object{pane:Id,zoomed:boolean,zoomed_pane:Id|null}
```

Errors: `no active pane`, `unknown pane <id>`, bad `mode`, `bad request: ...`.

CLI mapping: verb `zoom-pane`; flags `[--pane <id>] [--mode toggle|on|off]`; plain stdout prints zoom state; JSON stdout prints the exact result object.

### process-info

| Field | Value |
| --- | --- |
| name | `process-info` |
| status | implemented |
| since | protocol 6 |

Returns PTY child metadata for a surface. `pid`, `command`, and `cwd` are
recorded spawn and shell-reported metadata. `foreground_cwd` is read live at
request time: it is the working directory of the process group leader that
currently owns the PTY (the `tcgetpgrp` value of the child's controlling
terminal), so it tracks a foreground subshell that changed directory. It is
null whenever the lookup fails: no live child, the leader exited, the child
detached from the terminal, the platform denied the read, or an unsupported
platform. The field is additive within protocol 12; current daemons always
emit it, and clients treat a missing field from an older daemon as null.

Params: `object{surface:Id}`.

Result:

```text
object{pid:uint32|null,command:string|null,cwd:string|null,foreground_cwd?:string|null}
```

Errors: `unknown surface <id>`, `browser surface does not support PTY/VT socket commands`, `bad request: ...`.

CLI mapping: verb `process-info`; flags `--surface <id>`; plain stdout prints `pid=<v> command=<v> cwd=<v> foreground_cwd=<v>`; JSON stdout prints the exact result object.

### set-default-colors

| Field | Value |
| --- | --- |
| name | `set-default-colors` |
| status | implemented |
| since | protocol 5 |

Updates the session default foreground and/or background colors used by PTY surfaces. Missing fields preserve their previous values. Existing PTY surfaces receive the merged defaults. When the merged defaults change, each live PTY attach stream receives a `colors-changed` event containing that surface's effective colors and cursor metadata; active OSC 10/11/12 and DECSCUSR overrides remain authoritative. The cursor fields may be unchanged by this command. The server also emits `surface-output` for every existing surface, including browser surfaces; browser color application is a no-op, but the event is still emitted. Future PTY surfaces start with the merged defaults. Attach clients can read the initial effective colors and cursor metadata from `vt-state.colors` without issuing this write command.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `fg` | `ColorHex` | default null | Foreground color |
| `bg` | `ColorHex` | default null | Background color |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad color "<value>" (want "#rrggbb")` | Color is not exactly `#rrggbb` |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `set-default-colors` |
| Flags | `[--fg #rrggbb] [--bg #rrggbb]` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":12,"cmd":"set-default-colors","fg":"#d8d9da","bg":"#131415"}
{"id":12,"ok":true,"data":{}}
```

### close-surface

| Field | Value |
| --- | --- |
| name | `close-surface` |
| status | implemented |
| since | protocol 5 |

Closes one tab placement. For a PTY, the session-owned terminal process,
history, and canonical grid remain available, including when this was its last
view. A browser runtime closes because a browser is single-view. The server
removes the tab from its pane, collapses an emptied pane and screen, keeps an
emptied canonical workspace, and may emit `tree-changed`. Only explicit
`close-workspace` can remove the workspace and produce `empty`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live surface |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist before close |
| `bad request: ...` | Missing `surface` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `close-surface` |
| Flags | `--surface <id>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":13,"cmd":"close-surface","surface":1}
{"id":13,"ok":true,"data":{}}
```

### close-pane

| Field | Value |
| --- | --- |
| name | `close-pane` |
| status | implemented |
| since | protocol 5 |

Closes a pane and removes every tab placement in it. PTY terminal resources
remain session-owned and browser runtimes close. The pane is collapsed out of
the screen split tree. An emptied screen is removed, while its canonical
workspace remains.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Must identify a live pane |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown pane <id>` | Pane id does not exist before close |
| `bad request: ...` | Missing `pane` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `close-pane` |
| Flags | `--pane <id>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":14,"cmd":"close-pane","pane":2}
{"id":14,"ok":true,"data":{}}
```

### close-screen

| Field | Value |
| --- | --- |
| name | `close-screen` |
| status | implemented |
| since | protocol 5 |

Closes a screen and removes every pane and tab placement in it. PTY terminal
resources remain session-owned and browser runtimes close. The canonical
workspace remains even when this was its final screen.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `screen` | `Id` | required | Must identify a live screen |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown screen <id>` | Screen id does not exist |
| `bad request: ...` | Missing `screen` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `close-screen` |
| Flags | `--screen <id>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":15,"cmd":"close-screen","screen":3}
{"id":15,"ok":true,"data":{}}
```

### close-workspace

| Field | Value |
| --- | --- |
| name | `close-workspace` |
| status | implemented |
| since | protocol 5 |

Explicitly tombstones a workspace and removes every screen, pane, and tab
placement in it. PTY terminal resources remain session-owned with zero or more
views; only `terminal.close` ends them. Single-view browser runtimes close.
Terminal or pane exit alone never invokes this operation. The active
workspace selection is adjusted to keep a remaining workspace active when
possible. The workspace may be selected by stable key or numeric id, and the
common mutation envelope provides revision CAS and exactly-once retries.
Stable-key selection, revision CAS, and the mutation result require
`workspace-registry-v1`; the legacy numeric-id form remains available without
it. After provider ownership is enabled, this ordinary command fails without
changing workspace state.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | one of id/key | Must identify a live workspace |
| `key` | `string` | one of id/key | Lowercase canonical workspace UUID |
| mutation fields | see common envelope | optional | Exactly-once retry and CAS |

Result:

```text
object{workspace:Id,key:string,index:usize,workspace_revision:uint64,changed:bool,replayed:bool,registry_id:string,generation:string}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown workspace <id>` | Workspace id does not exist |
| `unknown workspace key <key>` | Workspace key does not exist |
| `workspace id and key do not identify the same workspace` | Supplied selectors identify different workspaces |
| `workspace revision conflict: ...` | Compare-and-swap guard is stale |
| `cannot close a provider-managed workspace directly; use the managed workspace lifecycle controls` | Provider ownership is enabled for this mux generation |
| `bad request: ...` | Missing selector or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `close-workspace` |
| Flags | `--workspace <id>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":16,"cmd":"close-workspace","workspace":4}
{"id":16,"ok":true,"data":{"workspace":4,"key":"9dc5432b-6e28-4b58-9f35-75b263f6e84f","workspace_revision":3}}
```

### mark-workspaces-provider-managed

Requires the `provider-managed-workspace-authority-v2` capability. Clients must not send this command to a server that omits the capability.

| Field | Value |
| --- | --- |
| name | `mark-workspaces-provider-managed` |
| status | implemented |
| since | protocol 9 additive capability |

Verifies that the provider frontend holds the authority provisioned when this mux generation started. The mux is already provider-owned before this handshake and before its first control client. Repeated authorized requests are idempotent. `rename-workspace` and `close-workspace` fail for every current and future workspace in the generation even when the handshake is missing or invalid.

Params: `object{authority:string}`. The authority is required and must match the mux's pre-provisioned value.

Result: `object{}`.

Errors:

| Error | Condition |
| --- | --- |
| `invalid provider workspace authority` | Authority is missing from this mux generation or does not match |
| `bad request: ...` | Authority is missing or has the wrong JSON type |

This control-only command has no public CLI mapping. The provider-aware TUI sends it before exposing provider-owned workspace lifecycle controls.

Example:

```json
{"id":17,"cmd":"mark-workspaces-provider-managed","authority":"<provider-authority>"}
{"id":17,"ok":true,"data":{}}
```

### close-provider-managed-workspace

Requires the `provider-managed-workspace-authority-v2` capability. Clients must not send this command to a server that omits the capability.

| Field | Value |
| --- | --- |
| name | `close-provider-managed-workspace` |
| status | implemented |
| since | protocol 9 additive capability |

Commits a provider-approved close to the local mux mirror. Both selectors are required and must identify the same live workspace. Clients must send this command only after the external provider durably accepts the close.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | required | Must identify a live workspace |
| `key` | `string` | required | Must identify the same workspace as `workspace` |
| `authority` | `string` | required | Must match the mux's pre-provisioned provider authority |

Result: `object{workspace:Id,key:string,workspace_revision:uint64}`.

Errors:

| Error | Condition |
| --- | --- |
| `invalid provider workspace authority` | Authority is missing from this mux generation or does not match |
| `workspace id and key do not identify the same workspace` | Supplied selectors identify different workspaces |
| `bad request: ...` | Missing fields or wrong JSON type |

This control-only command has no public CLI mapping.

Example:

```json
{"id":18,"cmd":"close-provider-managed-workspace","workspace":4,"key":"ops-stable","authority":"<provider-authority>"}
{"id":18,"ok":true,"data":{"workspace":4,"key":"ops-stable","workspace_revision":3}}
```

### rename-pane

| Field | Value |
| --- | --- |
| name | `rename-pane` |
| status | implemented |
| since | protocol 5 |

Sets a pane user-visible name. An empty `name` clears the pane name so display falls back to the active tab title or shell label.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Must identify a live pane |
| `name` | `string` | required | Empty string clears |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown pane <id>` | Pane id does not exist |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `rename-pane` |
| Flags | `--pane <id> --name <name>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":17,"cmd":"rename-pane","pane":2,"name":"logs"}
{"id":17,"ok":true,"data":{}}
```

### rename-surface

| Field | Value |
| --- | --- |
| name | `rename-surface` |
| status | implemented |
| since | protocol 5 |

Sets a tab user-visible name on a surface. An empty `name` clears the tab name so display falls back to generated tab label and process title.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live surface |
| `name` | `string` | required | Empty string clears |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `rename-surface` |
| Flags | `--surface <id> --name <name>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":18,"cmd":"rename-surface","surface":1,"name":"api"}
{"id":18,"ok":true,"data":{}}
```

### rename-screen

| Field | Value |
| --- | --- |
| name | `rename-screen` |
| status | implemented |
| since | protocol 5 |

Sets a screen user-visible name. An empty `name` clears the screen name so display falls back to the screen number.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `screen` | `Id` | required | Must identify a live screen |
| `name` | `string` | required | Empty string clears |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown screen <id>` | Screen id does not exist |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `rename-screen` |
| Flags | `--screen <id> --name <name>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":19,"cmd":"rename-screen","screen":3,"name":"build"}
{"id":19,"ok":true,"data":{}}
```

### rename-workspace

| Field | Value |
| --- | --- |
| name | `rename-workspace` |
| status | implemented |
| since | protocol 5 |

Sets a workspace name. The workspace may be selected by stable key or numeric id. Unlike pane, surface, and screen names, an empty `name` is stored as the workspace name. `expected_revision` provides compare-and-swap protection against concurrent registry mutations. Stable-key selection, revision CAS, and the mutation result require `workspace-registry-v1`; the legacy numeric-id form remains available without it. After provider ownership is enabled, this ordinary command fails without changing workspace state.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | one of id/key | Must identify a live workspace |
| `key` | `string` | one of id/key | Lowercase canonical workspace UUID |
| `name` | `string` | required | Empty string is stored |
| mutation fields | see common envelope | optional | Exactly-once retry and CAS |

Result:

```text
object{workspace:Id,key:string,index:usize,workspace_revision:uint64,changed:bool,replayed:bool,registry_id:string,generation:string}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown workspace <id>` | Workspace id does not exist |
| `unknown workspace key <key>` | Workspace key does not exist |
| `workspace id and key do not identify the same workspace` | Supplied selectors identify different workspaces |
| `workspace revision conflict: ...` | Compare-and-swap guard is stale |
| `cannot rename a provider-managed workspace directly; use the managed workspace lifecycle controls` | Provider ownership is enabled for this mux generation |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `rename-workspace` |
| Flags | `--workspace <id> --name <name>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":20,"cmd":"rename-workspace","workspace":4,"name":"prod"}
{"id":20,"ok":true,"data":{"workspace":4,"key":"9dc5432b-6e28-4b58-9f35-75b263f6e84f","workspace_revision":2}}
```

### rename-provider-managed-workspace

Requires the `provider-managed-workspace-authority-v2` capability. Clients must not send this command to a server that omits the capability.

| Field | Value |
| --- | --- |
| name | `rename-provider-managed-workspace` |
| status | implemented |
| since | protocol 9 additive capability |

Commits a provider-approved rename to the local mux mirror. Both selectors are required and must identify the same live workspace. Clients must send this command only after the external provider durably accepts the rename.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | required | Must identify a live workspace |
| `key` | `string` | required | Must identify the same workspace as `workspace` |
| `name` | `string` | required | Empty string is stored |
| `authority` | `string` | required | Must match the mux's pre-provisioned provider authority |

Result: `object{workspace:Id,key:string,workspace_revision:uint64}`.

Errors:

| Error | Condition |
| --- | --- |
| `invalid provider workspace authority` | Authority is missing from this mux generation or does not match |
| `workspace id and key do not identify the same workspace` | Supplied selectors identify different workspaces |
| `bad request: ...` | Missing fields or wrong JSON type |

This control-only command has no public CLI mapping.

Example:

```json
{"id":21,"cmd":"rename-provider-managed-workspace","workspace":4,"key":"ops-stable","name":"prod","authority":"<provider-authority>"}
{"id":21,"ok":true,"data":{"workspace":4,"key":"ops-stable","workspace_revision":2}}
```

### resize-surface

| Field | Value |
| --- | --- |
| name | `resize-surface` |
| status | implemented |
| since | protocol 5 |

Reports a view's available cell grid. A terminal PTY and VT resize only when
the requesting client and view hold geometry authority. A passive terminal
report is retained and returns `accepted:false`. Browser surfaces update their
cell grid and CDP device metrics asynchronously through the legacy reducer.
Clamping and bookkeeping follow [Sizing](#sizing). An accepted browser resize
returns a numeric `reservation_id`, repeated by its `surface-resized` or
`surface-resize-failed` completion. PTY reports and rejected browser resizes
return `null`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live surface |
| `cols` | `uint16` | required | Final value clamped to at least 1 |
| `rows` | `uint16` | required | Final value clamped to at least 1 |

Result:

```text
object{accepted:bool,reservation_id:uint64|null}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `resize-surface` |
| Flags | `--surface <id> --cols <n> --rows <n>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":21,"cmd":"resize-surface","surface":1,"cols":120,"rows":40}
{"id":21,"ok":true,"data":{"accepted":true,"reservation_id":7}}
```

### release-surface-size

| Field | Value |
| --- | --- |
| name | `release-surface-size` |
| status | implemented |
| since | protocol 7 |

Removes the requesting client's sizing lease for a surface without closing its attach stream. Frontends use this when a pane switches tabs or otherwise stops displaying the surface.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | An attached surface; an absent lease is a successful no-op |

Result: empty object.

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `release-surface-size` |
| Flags | `--surface <id>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

### resize-attached-view

| Field | Value |
| --- | --- |
| name | `resize-attached-view` |
| status | implemented |
| since | protocol 10 with `view-attachment-lease-v1` |

Reports the cell grid for one exact attach stream. The opaque lease binds the
request to its connection, surface, and stream, so delayed resize requests
cannot mutate a replacement view. The geometry-owning lease can resize the
terminal. Other leases retain passive sizes for later promotion.

Params: `surface:Id`, `lease:string`, `cols:uint16`, and `rows:uint16` are
required. Dimensions are clamped to `1..10000`.

Result:

```text
object{accepted:bool,reservation_id:uint64|null,outcome:"applied"|"passive"|"superseded"}
```

### release-attached-view-size

| Field | Value |
| --- | --- |
| name | `release-attached-view-size` |
| status | implemented |
| since | protocol 10 with `view-attachment-lease-v1` |

Removes one attachment's geometry contribution while retaining its stream for
cached rendering. A retired lease returns `outcome:"superseded"`.

Params: required `surface:Id` and `lease:string`.

Result:

```text
object{outcome:"applied"|"passive"|"superseded"}
```

### detach-attached-view

| Field | Value |
| --- | --- |
| name | `detach-attached-view` |
| status | implemented |
| since | protocol 10 with `view-attachment-detach-v1` |

Closes one leased attach stream and synchronously removes its size
participation. The terminal, its other placements, and other client views stay
live. Repeating a completed detach returns `outcome:"superseded"`.

Params: required `surface:Id` and `lease:string`.

Result:

```text
object{outcome:"applied"|"superseded"}
```

### focus-pane

| Field | Value |
| --- | --- |
| name | `focus-pane` |
| status | implemented |
| since | protocol 5 |

Makes `pane` the active pane of its screen and also activates the containing screen and workspace. This is an explicit focus-intent command.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Must identify a pane in a screen tree |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown pane <id>` | Pane id is not in any screen tree |
| `bad request: ...` | Missing `pane` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `focus-pane` |
| Flags | `--pane <id>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":22,"cmd":"focus-pane","pane":2}
{"id":22,"ok":true,"data":{}}
```

### select-tab

| Field | Value |
| --- | --- |
| name | `select-tab` |
| status | implemented |
| since | protocol 5 |

Selects a tab within a pane by zero-based `index` or relative `delta`. If both `index` and `delta` are present, v5 uses `index` and ignores `delta`. If `pane` is absent, the active pane is used.

No-op event behavior is split by target resolution. If the target pane cannot be resolved, or if the resolved pane has no tabs, v5 returns success and emits no `tree-changed`. This includes an unknown supplied pane, no supplied pane with no active pane, and an empty pane. If the target pane resolves and has tabs, an out-of-range `index` or missing `index`/`delta` returns success and emits `tree-changed` even though the active tab does not change.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | default null | Target pane or active pane |
| `index` | `usize` | default null | Zero-based; ignored if out of range |
| `delta` | `isize` | default null | Relative; wraps with Euclidean modulo |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `select-tab` |
| Flags | `[--pane <id>] (--index <n> | --delta <n>)` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common; CLI rejects missing selector with exit 2 |

Example:

```json
{"id":23,"cmd":"select-tab","pane":2,"index":0}
{"id":23,"ok":true,"data":{}}
```

### select-screen

| Field | Value |
| --- | --- |
| name | `select-screen` |
| status | implemented |
| since | protocol 5 |

Selects a screen in the active workspace by zero-based `index` or relative `delta`. If both `index` and `delta` are present, v5 uses `index` and ignores `delta`.

No-op event behavior is split by target resolution. If there is no active workspace or the active workspace has no screens, v5 returns success and emits no `tree-changed`. If the active workspace resolves and has screens, an out-of-range `index` or missing `index`/`delta` returns success and emits `tree-changed` even though the active screen does not change.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `index` | `usize` | default null | Zero-based; ignored if out of range |
| `delta` | `isize` | default null | Relative; wraps with Euclidean modulo |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `select-screen` |
| Flags | `--index <n> | --delta <n>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common; CLI rejects missing selector with exit 2 |

Example:

```json
{"id":24,"cmd":"select-screen","delta":1}
{"id":24,"ok":true,"data":{}}
```

### select-workspace

| Field | Value |
| --- | --- |
| name | `select-workspace` |
| status | implemented |
| since | protocol 5 |

Selects a workspace by zero-based `index` or relative `delta`. If both `index` and `delta` are present, v5 uses `index` and ignores `delta`.

No-op event behavior is split by target resolution. If the session has no workspaces, v5 returns success and emits no `tree-changed`. If at least one workspace exists, an out-of-range `index` or missing `index`/`delta` returns success and emits `tree-changed` even though the active workspace does not change.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `index` | `usize` | default null | Zero-based; ignored if out of range |
| `delta` | `isize` | default null | Relative; wraps with Euclidean modulo |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `select-workspace` |
| Flags | `--index <n> | --delta <n>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common; CLI rejects missing selector with exit 2 |

Example:

```json
{"id":25,"cmd":"select-workspace","index":0}
{"id":25,"ok":true,"data":{}}
```

### report-focus

| Field | Value |
| --- | --- |
| name | `report-focus` |
| status | implemented |
| since | protocol 12, capability `client-focus-v1` |

Reports one client's focus. Records it as the session's last reported focus (the adoption default a later `client-focus` query falls back to) and remembers it per `client_id` so that client's own later `client-focus` query restores it. A report only writes this memory; it never moves the live session focus, so clients that are already attached stay where they are. The memory is in-process and bounded; a server restart degrades to the tree's own focus.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `client_id` | `string` | required | 1-128 bytes, ASCII graphic |
| `pane` | `Id` | required | Must be a live pane |
| `tab` | `usize` | default null | Tab index within the pane |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad request: invalid client_id` | Empty, oversized, or non-graphic id |
| `unknown pane ...` | Pane is not alive |

### client-focus

| Field | Value |
| --- | --- |
| name | `client-focus` |
| status | implemented |
| since | protocol 12, capability `client-focus-v1` |

The focus last reported by `client_id` via `report-focus`, falling back to the session's last reported focus from any client, or nulls when neither exists or the pane no longer does.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `client_id` | `string` | required | 1-128 bytes, ASCII graphic |

Result:

```text
object{pane: Id | null, tab: usize | null}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad request: invalid client_id` | Empty, oversized, or non-graphic id |

### move-tab

| Field | Value |
| --- | --- |
| name | `move-tab` |
| status | implemented |
| since | protocol 5 |

Moves an existing tab, identified by `surface`, into `pane` at zero-based `index`. Moving a tab to its current pane and current index is an `ok:true` no-op. This command is documented from the consumer-side landed contract; it is not present in this branch's `server.rs`, so out-of-range index behavior and event emission could not be verified here.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Surface tab to move |
| `pane` | `Id` | required | Destination pane |
| `index` | `usize` | required | Zero-based destination index |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `unknown pane <id>` | Destination pane does not exist |
| `bad request: ...` | Missing fields or wrong JSON type |
| unverified error string | Non-same-position out-of-range index behavior could not be checked in this branch |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `move-tab` |
| Flags | `--surface <id> --pane <id> --index <n>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":26,"cmd":"move-tab","surface":1,"pane":2,"index":0}
{"id":26,"ok":true,"data":{}}
```

### move-workspace

| Field | Value |
| --- | --- |
| name | `move-workspace` |
| status | implemented |
| since | protocol 5 |

Moves an existing workspace to zero-based insertion `index`. The destination
is clamped to the last workspace after removing the source, so moving right
produces a final index one less than the requested insertion index. A
same-position request is
serialized as a valid mutation with `changed:false`, giving retries one stable
result and revision.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | one of id/key | Workspace to move |
| `key` | `string` | one of id/key | Lowercase canonical workspace UUID |
| `index` | `usize` | required | Zero-based destination index |
| mutation fields | see common envelope | optional | Exactly-once retry and CAS |

Result:

```text
object{workspace:Id,key:string,index:usize,workspace_revision:uint64,changed:bool,replayed:bool,registry_id:string,generation:string}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown workspace <id>` | Workspace id does not exist |
| `unknown workspace key <key>` | Workspace key does not exist |
| `workspace id and key do not identify the same workspace` | Supplied selectors identify different workspaces |
| `workspace revision conflict: ...` | Compare-and-swap guard is stale |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `move-workspace` |
| Flags | `--workspace <id> --index <n>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":27,"cmd":"move-workspace","workspace":4,"index":0}
{"id":27,"ok":true,"data":{"workspace":4,"key":"9dc5432b-6e28-4b58-9f35-75b263f6e84f","workspace_revision":4}}
```

### scroll-surface

| Field | Value |
| --- | --- |
| name | `scroll-surface` |
| status | implemented |
| since | protocol 5 |

Scrolls a PTY surface viewport by row delta. Negative values scroll up. Positive values scroll down. This changes the terminal viewport state used by `read-screen` and renderers.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |
| `delta` | `isize` | required | Negative up, positive down |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser surface does not support PTY/VT socket commands` | Surface is a browser |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `scroll-surface` |
| Flags | `--surface <id> --delta <n>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":26,"cmd":"scroll-surface","surface":1,"delta":-10}
{"id":26,"ok":true,"data":{}}
```

### subscribe

| Field | Value |
| --- | --- |
| name | `subscribe` |
| status | implemented |
| since | protocol 5 |
| `tree_events` field | protocol 7 additive extension |
| `surface` field | protocol 9 additive extension |

Subscribes the connection to mux events. After this command, response lines and event lines may be interleaved on the same connection. `subscribe` does not send an initial tree snapshot; clients should call `list-workspaces` when they need state.

Protocol v7 adds opt-in tree deltas. `tree_events:"coarse"`, including the default when the field is absent, preserves the exact protocol-v6 tree behavior: tree mutations emit `tree-changed` where v6 emits it, and the subscription never receives `workspace-*`, `screen-*`, `pane-*`, or `tab-*` lifecycle deltas. `tree_events:"deltas"` selects those lifecycle deltas. A delta subscriber must handle `tree-changed` as the documented resync fallback, but must not rely on receiving it for ordinary delta-representable mutations. The selection affects only tree events; every other subscribe event is unchanged.

Protocol v9 adds `surface` for a single-terminal frontend. The server filters unrelated surface output, titles, notifications, and layouts before the bounded subscriber mailbox. It retains events for the target surface, its current workspace/screen/pane path, coarse tree resyncs, and session lifecycle. Omitting `surface` preserves the unfiltered stream.

Clients must require the `surface-subscribe-filter` capability before sending `surface`. A client connected to an older protocol-v9 build must ask the user to restart or upgrade the session instead of silently falling back to an unfiltered stream.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `tree_events` | `string` | default `"coarse"` | Protocol 7: `"coarse"` or `"deltas"` |
| `surface` | `Id` | optional | Protocol 9: existing surface to scope at the event source |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| thread spawn error string | Server cannot create the event writer thread |
| `bad request: ...` | Malformed request envelope, wrong field type, or unsupported `tree_events` value |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `subscribe` |
| Flags | `[--tree-events coarse|deltas]`; flag requires protocol 7 and defaults to `coarse` |
| Plain stdout | JSON event object per line |
| JSON stdout | JSON event object per line |
| Exit codes | common; runs until connection closes or interrupted |

Example:

```json
{"id":27,"cmd":"subscribe"}
{"id":27,"ok":true,"data":{}}
{"event":"tree-changed"}
```

### attach-surface

| Field | Value |
| --- | --- |
| name | `attach-surface` |
| status | implemented |
| since | protocol 5 |
| `mode`, `cols`, `rows` fields | protocol 7 additive extensions |

Attaches the connection to a PTY or browser surface stream. In protocol v5, the server first sends a `vt-state` event for the current PTY surface state, then sends live `output` events for subsequent PTY bytes, and finally sends `detached` when the stream ends. The command response is sent after the initial `vt-state` event in v5.

Protocol v6 changes the attach stream ordering to `vt-state -> (resized | output | colors-changed)* -> detached`. A v6 `resized` attach event carries a fresh replay and requires clients to discard the old mirror and replace it from that replay. The additive `vt-state.colors` field contains effective colors plus `cursor_style` and `cursor_blink` captured with the snapshot, and `colors-changed` reports later `set-default-colors` updates without changing the replay/output ordering contract. The Ghostty VT replay does not emit DECSCUSR, so clients must apply these cursor fields after replaying `data`; current per-surface DECSCUSR state takes precedence over Ghostty configuration defaults. Clients that support only protocol 5 or older must refuse protocol v6 attach streams rather than treating `resized` as a normal resize. The v6 field name `replay` could not be verified against this branch's code.

Protocol v7 adds `mode`. `mode:"bytes"`, including the default when the field is absent, is the exact protocol-v6 attach behavior above. `mode:"render"` selects the authoritative styled-cell stream specified in [`render.md`](render.md): `render-state -> (render-delta | scroll-changed)* -> detached`. A client must require `identify.protocol >= 7` before selecting render mode.

Servers advertising the `attach-initial-size` capability accept paired `cols` and `rows`. The pair records the attaching client's initial viewer-size claim before initial state is generated. Supplying only one dimension is an error. Clients must not send either field to a server that omits the capability, including an older protocol-v7 server.

When both peers negotiate `view-attachment-lease-v1` through `identify` and
`set-client-info`, the response includes an opaque `lease`. The lease names
this exact connection-local attach stream. Use it with
`resize-attached-view` and `release-attached-view-size`. When both peers also
negotiate `view-attachment-detach-v1`, use `detach-attached-view` to close the
stream without disconnecting or affecting another view of the terminal.

Browser attach requires `browser-pointer-frame-guard-v1` in both the server's `identify` response and the client's earlier `set-client-info` request. This prevents an older client from rendering browser frames that it cannot address with an authoritative sequence. PTY attach does not require this capability.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY or negotiated browser surface |
| `mode` | `string` | default `"bytes"` | Protocol 7: `"bytes"` or `"render"` |
| `cols` | `uint16` | default null | `attach-initial-size` capability; paired with `rows`, clamped to at least 1 |
| `rows` | `uint16` | default null | `attach-initial-size` capability; paired with `cols`, clamped to at least 1 |

Result:

```text
object{lease?:string}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser attach requires client capability browser-pointer-frame-guard-v1; ...` | The client did not advertise guarded pointer support |
| `bad attach mode <mode>` | `mode` is not `"bytes"` or `"render"` |
| `attach-surface cols and rows must be supplied together` | Only one initial dimension is supplied |
| `render attach requires protocol 7` | Server does not implement render mode |
| terminal error string | VT replay generation fails |
| thread spawn error string | Server cannot create the attach writer thread |
| `bad request: ...` | Missing `surface` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `attach-surface` |
| Flags | `--surface <id> [--mode bytes|render] [--cols <n> --rows <n>]` |
| Plain stdout | JSON event object per line |
| JSON stdout | JSON event object per line |
| Exit codes | common; runs until `detached`, connection closes, or interrupted |

Example:

```json
{"id":28,"cmd":"attach-surface","surface":1}
{"event":"vt-state","surface":1,"cols":80,"rows":24,"data":"G1s/bA==","colors":{"fg":"#d8d9da","bg":"#131415","cursor":null,"selection_bg":null,"selection_fg":null,"cursor_style":"bar","cursor_blink":false}}
{"id":28,"ok":true,"data":{}}
```

Render mode example:

```json
{"id":29,"cmd":"attach-surface","surface":1,"mode":"render"}
{"event":"render-state","surface":1,"size":{"cols":3,"rows":1},"cursor":{"x":2,"y":0,"style":"block","blink":true,"visible":true,"color":null},"default_fg":"#d8d9da","default_bg":"#131415","scrollback_rows":0,"history_epoch":1,"rows":[{"row":0,"runs":[{"text":"$ x","fg":null,"bg":null,"attrs":0}]}]}
{"id":29,"ok":true,"data":{}}
```

## Proposed Commands

### read-scrollback

| Field | Value |
| --- | --- |
| name | `read-scrollback` |
| status | proposed |
| since | protocol 7 |

Returns one atomic page of the PTY surface's styled retained scrollback. `start` is zero-based from the oldest row retained when the server captures the request. The result uses the `Row` and `Run` types from [`render.md`](render.md#shared-render-types); each returned `Row.row` is relative to the returned page.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |
| `start` | `uint32` | required | Current-buffer index from the oldest retained row |
| `count` | `uint32` | required | See the inclusive bound below |

The inclusive `count` bound is `0 <= count <= 65,535`.

Result:

```text
object{rows:array<Row>,start:uint32,total:uint32,epoch:uint64}
```

The response `start` is `min(request.start,total)`. `rows` contains at most `count` entries and stops at `total`; `count:0` returns an empty page. `total` is the scrollback row count captured with the page and excludes the live viewport. `epoch` matches the `history_epoch` render field captured in the same retained-history coordinate space.

Indexes are not durable identities. Eviction shifts surviving indexes toward zero, and resize reflow can change row boundaries and `total`. The request does not move the shared viewport. See [`render.md`](render.md#scrollback) for the full eviction, consistency, and reflow contract.

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser surface does not support PTY/VT socket commands` | Surface is a browser |
| `count out of range` | `count` cannot be represented by relative `Row.row` |
| terminal/render error string | Styled scrollback capture fails |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `read-scrollback` |
| Flags | `--surface <id> --start <n> --count <n>` |
| Plain stdout | returned rows as plain text, one newline per row; styles are omitted |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":5,"cmd":"read-scrollback","surface":1,"start":40,"count":2}
{"id":5,"ok":true,"data":{"rows":[{"row":0,"runs":[{"text":"cargo test","fg":null,"bg":null,"attrs":0}]},{"row":1,"runs":[{"text":"ok","fg":"#00ff00","bg":null,"attrs":1}]}],"start":40,"total":83,"epoch":17}}
```

### wait-for

| Field | Value |
| --- | --- |
| name | `wait-for` |
| status | implemented |
| since | protocol 6 |

Blocks until a regular expression matches the current plain-text screen for a PTY surface. The server polls the same text source as `read-screen` and returns as soon as a match is found or the timeout expires. This is the primary automation synchronization primitive.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `IdRef` | required | PTY surface |
| `pattern` | `string` | required | Rust regex syntax |
| `timeout_ms` | `uint64` | required | `0` means a single immediate check |

Result:

```text
object{matched:true,text:string,elapsed_ms:uint64}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser surface does not support PTY/VT socket commands` | Surface is a browser |
| `bad regex: <message>` | Pattern cannot compile |
| `timeout waiting for pattern` | Timeout expires before match |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `wait-for` |
| Flags | `--surface <id> --pattern <regex> --timeout-ms <n>` |
| Plain stdout | no output on success |
| JSON stdout | exact result object |
| Exit codes | common; timeout is exit code 1 |

Example:

```json
{"id":101,"cmd":"wait-for","surface":1,"pattern":"ready> $","timeout_ms":5000}
{"id":101,"ok":true,"data":{"matched":true,"text":"ready> ","elapsed_ms":143}}
```

### run

| Field | Value |
| --- | --- |
| name | `run` |
| status | implemented |
| since | protocol 6 |

Spawns a command in a new PTY tab. `argv` executes directly without a shell. `command` executes through the session shell as `shell -lc <command>`. Exactly one of `argv` or `command` is required. By default the tab is created in the active pane. With `pane`, it is created in that pane. With `new_workspace:true`, a new workspace is created instead. `key` assigns that workspace a caller-owned stable identity so detached or provider-backed frontends can reconcile it after a display-name change. Initial dimensions follow [Sizing](#sizing).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `argv` | `array<string>` | required if `command` absent | Non-empty; direct exec |
| `command` | `string` | required if `argv` absent | Executed via shell `-lc` |
| `cwd` | `string` | default null | Working directory |
| `pane` | `IdRef` | default null | Mutually exclusive with `new_workspace:true` |
| `new_workspace` | `boolean` | default false | Create a new workspace |
| `key` | `string` | default null | Protocol 9; valid only with `new_workspace:true`; unique stable workspace key |
| `name` | `string` | default null | Sets surface name; also workspace name when `new_workspace:true` |
| `cols` | `uint16` | default null | Used only with `rows` |
| `rows` | `uint16` | default null | Used only with `cols` |

Result:

```text
object{
  surface:Id|null,terminal_id:string,terminal_incarnation:string|null,
  pane:Id|null,screen:Id|null,workspace:Id|null,
  lifecycle:"running"|"exited",exit:TerminalExit|null,
  terminal_revision:uint64,already_exited:bool
}
```

If the child exits before `run` returns, the request succeeds with
`already_exited:true`, exact durable `exit` metadata, and null live-placement
fields. The terminal remains resolvable by `terminal_id` for exit inspection.

`run` carries no mutation identity and is not idempotent. Retrying after a
lost response starts a second process and creates a second durable terminal.
Use `create-terminal` when creation must be safe to retry.

Errors:

| Error | Condition |
| --- | --- |
| `argv or command is required` | Neither is supplied |
| `argv and command are mutually exclusive` | Both are supplied |
| `pane and new_workspace are mutually exclusive` | Both placement options are supplied by a raw socket caller |
| `key requires new_workspace` | A stable key is supplied without workspace creation |
| `workspace key already exists: <key>` | The stable key is already present in the session |
| `unknown pane <id>` | Supplied pane does not exist |
| spawn or PTY error string | PTY creation or child spawn fails |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `run` |
| Flags | `[--pane <id> \| --new-workspace [--key <key>]] [--cwd <path>] [--name <name>] -- <argv...>` or `--command <cmd>` |
| Plain stdout | new surface id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":102,"cmd":"run","argv":["python3","-m","http.server"],"cwd":"/tmp","name":"server"}
{"id":102,"ok":true,"data":{"surface":31,"terminal_id":"00000000000040008000000000000004","terminal_incarnation":"00000000000040008000000000000005","pane":2,"screen":3,"workspace":4,"lifecycle":"running","exit":null,"terminal_revision":7,"already_exited":false}}
{"id":103,"cmd":"run","argv":["/bin/zsh","-l"],"new_workspace":true,"key":"workspace-019c","name":"cloud"}
{"id":103,"ok":true,"data":{"surface":32,"terminal_id":"00000000000040008000000000000006","terminal_incarnation":"00000000000040008000000000000007","pane":5,"screen":6,"workspace":7,"lifecycle":"running","exit":null,"terminal_revision":8,"already_exited":false}}
{"id":104,"cmd":"run","command":"exit 9"}
{"id":104,"ok":true,"data":{"surface":null,"terminal_id":"00000000000040008000000000000008","terminal_incarnation":null,"pane":null,"screen":null,"workspace":null,"lifecycle":"exited","exit":{"outcome":{"kind":"exit","code":9},"exited_at_ms":1785900001000},"terminal_revision":10,"already_exited":true}}
```

### create-surface-with-receipt

| Field | Value |
| --- | --- |
| name | `create-surface-with-receipt` |
| status | implemented |
| since | protocol 10 with `creation-receipts-v1` |

Executes one destination-creating frontend intent behind a durable receipt.
The frontend chooses `origin` and stable correlation `receipt` before sending
the request. With `creation-attempt-keys-v1`, optional `idempotency_key` names
one execution attempt and defaults to `receipt`. The frontend changes it only
when `session.creation.resolve` returns `retry_new_idempotency_key`; same-key
recovery reuses the exact reported key. A retry with identical semantics
returns the original `surface` with `replayed:true`; reusing the correlation
for different semantics fails. This prevents lost responses and concurrent
tree refreshes from duplicating or retargeting a creation.

`operation` is `new-tab`, `run-command`, `new-browser-tab`, `new-workspace`,
`new-screen`, `new-pane`, `new-pane-right`, `split-right`, or `split-down`.
Stable `selectors` identify the primary destination. Up to seven ordered
`selector_fallbacks` require `creation-selector-fallbacks-v1` and are resolved
inside the same commit. Numeric `pane` and `workspace` fields are compatibility
fallbacks. Operation-specific options are `argv`, `cwd`, `url`, `width`,
`cols`, and `rows`.

Result:

```text
object{surface:Id,replayed:bool}
```

This connection-scoped primitive has no ordinary CLI verb. Interactive
frontends use it through the raw SDK or remote-session adapter.

### send-key

| Field | Value |
| --- | --- |
| name | `send-key` |
| status | implemented |
| since | protocol 6 |

Sends named key chords to a surface without requiring callers to hand-encode escape sequences. PTY surfaces use the same Ghostty key encoder as the TUI, synced to the surface terminal modes. Browser surfaces translate supported keys to CDP keyboard input when the browser runtime is local.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `IdRef` | required | Target surface |
| `keys` | `array<string>` | required | Non-empty key chord list |

Key chord syntax is lower-case tokens joined with `+`. Supported names are `enter`, `tab`, `backtab`, `escape`, `backspace`, `delete`, `insert`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `f1` through `f24`, printable single characters, `ctrl+<key>`, `alt+<key>`, and `shift+<key>` where the encoder supports it.

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `unknown key <key>` | Key token is not supported |
| `surface does not support key input` | Surface kind cannot accept keys |
| IO or CDP error string | Input write fails |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `send-key` |
| Flags | `--surface <id> <key>...` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":103,"cmd":"send-key","surface":1,"keys":["ctrl+c","enter"]}
{"id":103,"ok":true,"data":{}}
```

### copy

| Field | Value |
| --- | --- |
| name | `copy` |
| status | implemented |
| since | protocol 6 |

Extracts text from a surface. `screen` returns the current plain-text viewport. `selection` returns the current mux-owned selection. `scrollback` returns available scrollback followed by the current viewport.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `IdRef` | required | PTY surface |
| `mode` | `string` | required | `"screen"`, `"selection"`, or `"scrollback"` |

Result:

```text
object{text:string,mode:"screen"|"selection"|"scrollback"}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser surface does not support PTY/VT socket commands` | Surface is a browser |
| `bad mode <mode>` | Mode is not allowed |
| `no selection` | Mode is `selection` and no selection exists |
| `scrollback unavailable` | Mode is `scrollback` and the terminal cannot export it |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `copy` |
| Flags | `--surface <id> --mode screen|selection|scrollback` |
| Plain stdout | extracted text exactly |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":104,"cmd":"copy","surface":1,"mode":"screen"}
{"id":104,"ok":true,"data":{"text":"ready> ","mode":"screen"}}
```

### ids

| Field | Value |
| --- | --- |
| name | `ids` |
| status | implemented |
| since | protocol 6 |

Returns the session id mapping. Every workspace, screen, pane, and surface has a numeric id and a stable short id for the lifetime of the session. Short ids are content-independent and collision-checked per session. Accepting short ids anywhere an `IdRef` is accepted remains proposed; implemented command parameters currently accept numeric ids only.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `kind` | `string` | default null | Optional filter: `"workspace"`, `"screen"`, `"pane"`, or `"surface"` |

Short id format:

```text
[a-z0-9]{6}
```

Generation rule: implemented short ids are stable six-character base36 ids collision-checked across live ids. The proposed future scheme derives a candidate from a per-session random seed plus numeric id, encodes it base36, and checks for collisions across all live ids. On collision, it rehashes with an incrementing salt. Short ids never depend on names, titles, command text, cwd, or layout position.

Resolution rule: short-id / `IdRef` string resolution across commands is still proposed and not yet accepted by the implementation. Implemented commands currently deserialize id parameters as numeric JSON ids. Proposed behavior is: numeric JSON ids resolve first; string ids matching `[0-9]+` are rejected as ambiguous; string ids matching the short-id format resolve by exact short id; unknown or ambiguous strings error.

Result:

```text
object{ids:array<object{kind:"workspace"|"screen"|"pane"|"surface",id:Id,short_id:string}>}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad kind <kind>` | Filter kind is not allowed |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `ids` |
| Flags | `[--kind workspace|screen|pane|surface]` |
| Plain stdout | one line per id: `<kind> <id> <short_id>` |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":105,"cmd":"ids","kind":"surface"}
{"id":105,"ok":true,"data":{"ids":[{"kind":"surface","id":1,"short_id":"a8f3k2"}]}}
```

### notify

| Field | Value |
| --- | --- |
| name | `notify` |
| status | implemented |
| since | protocol 6 |

Posts a notification into the mux notification area. This is a telemetry command and must not change app focus or pane selection.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `title` | `string` | required | Non-empty |
| `body` | `string` | required | May be empty |
| `level` | `string` | default `"info"` | `"info"`, `"warning"`, or `"error"` |
| `surface` | `IdRef` | default null | Optional originating surface |

Result:

```text
object{notification:Id}
```

Errors:

| Error | Condition |
| --- | --- |
| `title is required` | Title is empty |
| `bad level <level>` | Level is not allowed |
| `unknown surface <id>` | Optional surface id does not exist |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `notify` |
| Flags | `--title <title> --body <body> [--level info|warning|error] [--surface <id>]` |
| Plain stdout | notification id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":106,"cmd":"notify","title":"Build failed","body":"api tests failed","level":"error","surface":1}
{"id":106,"ok":true,"data":{"notification":44}}
```

### list-agents

| Field | Value |
| --- | --- |
| name | `list-agents` |
| status | implemented |
| since | protocol 6 |

Returns known agent status records. Records may come from detection, explicit reports, or hooks. Explicit hook-authority reports override detection for the same surface until another explicit report changes the state or the surface closes.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `IdRef` | default null | Optional surface filter |
| `state` | `string` | default null | Optional state filter |

Result:

```text
object{
  agents: array<object{
    surface: Id,
    state: "working"|"blocked"|"idle"|"done"|"unknown",
    source: "detected"|"socket"|"hook",
    session: string|null,
    updated_at_ms: uint64
  }>
}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Optional surface id does not exist |
| `bad state <state>` | State filter is not allowed |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `list-agents` |
| Flags | `[--surface <id>] [--state working|blocked|idle|done|unknown]` |
| Plain stdout | one line per agent: `<surface> <state> <source> <session-or->` |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":107,"cmd":"list-agents","state":"blocked"}
{"id":107,"ok":true,"data":{"agents":[{"surface":1,"state":"blocked","source":"hook","session":"abc","updated_at_ms":1710000000000}]}}
```

### report-agent

| Field | Value |
| --- | --- |
| name | `report-agent` |
| status | implemented |
| since | protocol 6 |

Reports agent state for a durable terminal surface without changing focus. A
successful report commits the same public agent projection used by
`agent.report`, advances the resource revision, and publishes one agent change
to `session.events`. The server generates an internal mutation identity for
this raw command.

Each live terminal has at most one current agent projection. Hook reports have
authority over socket reports. A socket report received after a hook retains
the hook value while still advancing the resource revision and publishing that
retained value. Restart restores the current projection. Closing the terminal
deletes it, so historical reports cannot recreate an agent. Browser surfaces,
surfaces without durable terminal identity, and terminal-less default reports
are rejected.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `IdRef` | required | Surface associated with the agent |
| `state` | `string` | required | `"working"`, `"blocked"`, `"idle"`, `"done"`, or `"unknown"` |
| `source` | `string` | required | `"socket"` or `"hook"` |
| `session` | `string` | default null | Optional upstream agent session id |

Result:

```text
object{surface:Id,state:string,source:string,session:string|null}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `surface <id> is not a terminal` | Surface is a browser |
| `surface <id> has no durable resource identity` | Surface is not durably registered |
| `bad state <state>` | State is not allowed |
| `bad source <source>` | Source is not allowed |
| `bad request: ...` | Missing fields or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `report-agent` |
| Flags | `--surface <id> --state working|blocked|idle|done|unknown --source socket|hook [--session <id>]` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":108,"cmd":"report-agent","surface":1,"state":"working","source":"socket","session":"abc"}
{"id":108,"ok":true,"data":{"surface":1,"state":"working","source":"socket","session":"abc"}}
```

## Journal hooks

Hooks are versioned resource-API manifests over the canonical session journal,
not protocol-v10 socket commands or event-specific config arrays. Use
`session <selector> journal hook put` and `hook list`. The session-owned
dispatcher, durable cursor, delivery receipts, retry policy, loop prevention,
authority, and replay semantics are specified in
[`session-journal.md`](session-journal.md#hook-subscriptions). The strict
runtime config parser continues to reject hook manifests so there is one
durable installation path.

## Compatibility Notes

The following v5 behaviors are awkward for generated bindings and should be normalized in protocol v6:

| Area | v5 behavior | Proposed v6 normalization |
| --- | --- | --- |
| Create commands | `new-tab`, `new-browser-tab`, `new-screen`, `new-workspace`, and `split` return only `{surface}` | Return `{surface,pane,screen,workspace}` |
| Selection commands | `select-*` returns success for unknown targets, out-of-range indexes, and missing selector fields | Return a changed boolean or reject invalid target/index |
| Resize command | `resize-surface` reports acceptance but not the final clamped size | Return `{accepted,cols,rows}` |
| Ratio command | `set-ratio` silently clamps and does not return final ratio | Return `{ratio}` after clamping |
| Naming commands | Empty string clears pane/surface/screen names but stores an empty workspace name | Make empty string clear all optional display names, including workspace |
| Attach response ordering | v5 `attach-surface` sends `vt-state` before the command response | v6 keeps attach as an event stream and adds `resized` replay events; clients must gate behavior by protocol |
| Error taxonomy | Errors are strings from `anyhow`, IO, base64, and terminal layers | Add stable machine error codes while preserving messages |
| Optional size pair | Supplying only one of `cols` or `rows` is silently ignored | Reject partial size pairs |
| Unknown fields | Unknown request fields are ignored by serde | Reject unknown fields or define extension slots |

Protocol v9 adds `new-pane`; its implemented result is `{surface}`. A future result expansion may add `{pane,screen,workspace}` only behind a newer protocol version.

`viewport-splits-v1` is additive within protocol v9. Clients must require the capability before sending `new-pane-right` or interpreting `Screen.viewport_splits`.

`viewport-column-resize-v1` is additive within protocol v9. Clients must require the capability before sending `set-viewport-pane-width` or interpreting `Screen.viewport_base_width`.

`layout-undo-v1` is additive within protocol v9. Clients must require the capability before sending `undo-layout`. A binding must preserve both result variants and must not set `confirm_close` without the exact revision returned by the confirmation preview.
