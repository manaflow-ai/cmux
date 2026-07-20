# Command Contract

This file specifies the JSON command contract for the cmux-tui protocol. Implemented commands match protocol v9 in `cmux-tui/crates/cmux-tui-core/src/server.rs`.

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
  panes:array<Pane>
}
```

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

Each client reports the cell grid available for every surface it currently displays with `resize-surface`. The authoritative grid uses the smallest reported `cols` and the smallest reported `rows`, matching tmux's `window-size smallest` policy. Input does not claim or change sizing ownership. When a tab becomes hidden, the client sends `release-surface-size`; detaching or disconnecting also removes its reports. The surface expands to the minimum of the remaining visible clients.

The final effective grid is retained while at least one client still reports a visible surface. Once the final report is released or disconnected, existing surfaces keep their last grids and later unsized headless creation uses the configured default, normally `80x24`. Internal server-only resizes, including sidebar plugin tracking, do not update the client-size cache.

Size-aware creation commands are `apply-layout`, `new-tab`, `new-browser-tab`, `new-workspace`, `new-screen`, `split`, and `run`. Their rules are:

| Input | Behavior |
| --- | --- |
| both `cols` and `rows` supplied | Clamp each to `1..10000`, use the pair for the new surface or surfaces, and record the effective grid as the latest client size |
| neither supplied | Use the latest active client size, or the configured server default when no client reports remain |
| only one supplied | Preserve protocol-v6 behavior: the incomplete pair is ignored; clients must always send both |

`resize-surface` requires both fields and clamps each to `1..10000`, matching tmux's window bounds. Every live control connection enters the same shared reducer. Attached clients retain the report until release; an unattached one-shot report is removed when its connection closes. A disconnected client id is rejected.

`set-client-sizing` controls tmux-style `ignore-size` participation. A normal request supplies `client` and `enabled`. Supplying `exclusive:true` with an enabled client atomically includes only that client. Omitting `client` with `enabled:true` atomically includes all clients. Ignored clients keep reporting; if every attached client is ignored, all ignored reports participate as tmux's global fallback.

Frontends report their grid after a surface becomes visible and whenever that viewport changes. They release the report when the surface becomes hidden, even if its attach stream remains cached. A frontend must not re-report merely because another client changed the authoritative surface size. See [`render.md`](render.md#sizing-and-multi-client-presentation) for presentation guidance.

## Implemented Commands

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
object{app:"cmux-tui",version:string,build_commit?:string|null,ghostty_commit?:string|null,protocol:uint32,capabilities:array<string>,session:string,pid:uint32}
```

`build_commit` and `ghostty_commit` are additive build-stamp fields. They are omitted or `null` when the binary was built without the corresponding stamp, so clients must preserve compatibility with older servers and unstamped local builds.

`capabilities` is additive build-level feature negotiation within a protocol version. Clients must treat a missing field as an empty list.

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
{"id":1,"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"abc123","ghostty_commit":"def456","protocol":9,"capabilities":["attach-initial-size","workspace-registry-v1"],"session":"main","pid":12345}}
```

The current server reports protocol `9` in this field and in `ping`. Clients must negotiate protocol 8 before requiring stable split ids or sending `set-split-ratio`, and protocol 9 before decoding stack layouts or sending `new-pane`.

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
{"id":2,"ok":true,"data":{"ok":true,"version":"0.1.0","build_commit":"abc123","ghostty_commit":"def456","protocol":9}}
```

### set-client-info

| Field | Value |
| --- | --- |
| name | `set-client-info` |
| status | implemented |
| since | protocol 6 additive extension |

Labels the requesting control connection. Repeated calls are idempotent. An omitted field preserves its current value; supplied `name` and `kind` values are clamped to 64 Unicode characters by the server.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `name` | `string` | default unchanged | Control characters are replaced with spaces; first 64 characters are retained |
| `kind` | `string` | default unchanged | Control characters are replaced with spaces; first 64 characters are retained |

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
{"id":3,"cmd":"set-client-info","name":"lawrences-iphone","kind":"web"}
{"id":3,"ok":true,"data":{}}
```

### list-clients

| Field | Value |
| --- | --- |
| name | `list-clients` |
| status | implemented |
| since | protocol 6 additive extension |

Returns all current Unix and WebSocket control connections in ascending client-id order. `self` identifies the requesting connection. `connected_seconds` is elapsed monotonic whole seconds. `attached` contains unique surface ids, and each corresponding `sizes` entry has null dimensions until that connection requests `resize-surface` for the attached surface.

Params: none.

Result:

```text
array<object{
  client:uint64,
  transport:"unix"|"ws",
  name:string|null,
  kind:string|null,
  connected_seconds:uint64,
  attached:array<Id>,
  sizes:array<object{surface:Id,cols:uint16|null,rows:uint16|null}>,
  self:boolean
}>
```

Errors: `bad request: ...`.

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `list-clients` |
| Flags | none |
| Plain stdout | one line per client: `<client> <transport> <name-or-> <kind-or-> connected=<n>s attached=<ids-or-> sizes=<sizes-or-> self=<bool>` |
| JSON stdout | exact result array |
| Exit codes | common |

Example:

```json
{"id":4,"cmd":"list-clients"}
{"id":4,"ok":true,"data":[{"client":1,"transport":"unix","name":"host","kind":"tui","connected_seconds":12,"attached":[7],"sizes":[{"surface":7,"cols":120,"rows":36}],"self":true}]}
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

Returns the full workspace, screen, pane, tab, and split-tree snapshot. The snapshot includes the ordered workspace registry revision, each workspace's stable key, active flags, active pane ids, active tab indexes, tab titles, tab names, surface kinds, browser source, size, and dead flags.

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
object{layout:Layout,panes:array<object{pane:Id,surfaces:array<Id>}>}
```

Errors: `unknown screen <id>`, `no active screen`, `bad request: ...`.

CLI mapping: verb `export-layout`; flags `[--screen <id>]`; plain stdout and JSON stdout both print the exact result object.

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

Returns a one-shot base64 VT replay for a PTY surface, including the current screen, styles, cursor, modes, palette, keyboard protocol state, charsets, and tabstops. Replaying this data into a fresh Ghostty VT terminal reproduces the surface state at the time of the snapshot.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |

Result:

```text
object{cols:uint16,rows:uint16,data:Base64}
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

Creates a new PTY tab in a pane and makes it the active tab. If `pane` is absent, the active pane of the active screen is used. If the selected workspace exists but has no screens, the command materializes its first screen, pane, and terminal and preserves `cwd`. If the session has no workspaces, the command creates a workspace containing the tab; that legacy fallback ignores `cwd`. The new tab inherits the active surface working directory of the target pane when `cwd` is absent. Initial dimensions follow [Sizing](#sizing).

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

Creates a browser tab in a pane and makes it active. If `pane` is absent, the active pane is used. If the selected workspace exists but has no screens, the command materializes its first screen, pane, and browser tab. If the session has no workspaces, the command creates a workspace containing the browser tab. The browser runtime may connect to an external CDP endpoint or launch Chrome according to mux configuration. Initial dimensions follow [Sizing](#sizing).

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

Creates a new workspace with one screen, one pane, and one PTY tab, then makes the new workspace active. If `name` is absent, the workspace name is the next 1-based workspace count at creation time. Initial dimensions follow [Sizing](#sizing).

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

Adds an empty workspace to the ordered registry and makes it active. The caller may provide a stable key or let the mux generate one. `expected_revision` provides compare-and-swap protection against concurrent registry mutations.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `name` | `string` | default null | Defaults to the next 1-based workspace count |
| `key` | `string` | default generated UUID | Must be non-empty and unique |
| `expected_revision` | `uint64` | default null | Must equal the current registry revision when supplied |

Result:

```text
object{workspace:Id,key:string,index:uint64,workspace_revision:uint64}
```

Errors include `workspace key cannot be empty`, `workspace key already exists: <key>`, `workspace revision conflict: expected <n>, current <n>`, and malformed request errors.

Example:

```json
{"id":9,"cmd":"create-workspace","name":"ops","key":"ops-stable","expected_revision":1}
{"id":9,"ok":true,"data":{"workspace":12,"key":"ops-stable","index":1,"workspace_revision":2}}
```

### create-terminal

Requires the `workspace-registry-v1` capability. Clients must not send this command to a server that omits the capability.

| Field | Value |
| --- | --- |
| name | `create-terminal` |
| status | implemented |
| since | protocol 7 |

Creates a PTY terminal in an existing workspace selected by stable `key` or numeric `workspace` id. An empty workspace receives its first screen and pane; a populated workspace receives a new active tab in its active pane. `argv` executes directly, while `command` executes through the default shell.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | required unless `key` is supplied | Mutually identifies the target with `key` |
| `key` | `string` | required unless `workspace` is supplied | Must match `workspace` when both are supplied |
| `argv` | `string[]` | default shell | Mutually exclusive with `command`; must be non-empty when supplied |
| `command` | `string` | default null | Mutually exclusive with `argv`; must be non-empty when supplied |
| `cwd` | `string` | default inherited | PTY child working directory |
| `name` | `string` | default null | New terminal tab name |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |

Result:

```text
object{surface:Id,pane:Id,screen:Id,workspace:Id,key:string}
```

Errors include missing, unknown, or mismatched workspace selectors; mutually exclusive or empty commands; PTY spawn failures; and malformed requests.

Example:

```json
{"id":10,"cmd":"create-terminal","key":"ops-stable","command":"htop","cwd":"/tmp"}
{"id":10,"ok":true,"data":{"surface":15,"pane":14,"screen":13,"workspace":12,"key":"ops-stable"}}
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

Creates a PTY pane after the current panes in creation order, focuses it, and reapplies the default automatic layout. Panes one through five use one full-height left column and up to four equal right-side rows. Panes six through twelve fill balanced columns of four. Above twelve panes, the first pane stays full-height on the left while the remaining panes form a right-side stack whose focused member expands. The new surface inherits the active surface working directory of `pane` when available.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Pane whose screen receives the new pane |
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

Sets the ratio of exactly one canonical split node. The server clamps the supplied ratio to `0.05..0.95`. The split id and every unrelated node remain unchanged.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `split` | `Id` | required | Stable split id from `list-workspaces` or `export-layout` |
| `ratio` | `float32` | required | Clamped to `0.05..0.95` |

Result: `object{}`.

Errors:

| Error | Condition |
| --- | --- |
| `unknown split <id>` | No live split node has the id |
| `bad request: ...` | Missing fields or wrong JSON type |

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

Returns PTY child metadata for a surface.

Params: `object{surface:Id}`.

Result:

```text
object{pid:uint32|null,command:string|null,cwd:string|null}
```

Errors: `unknown surface <id>`, `browser surface does not support PTY/VT socket commands`, `bad request: ...`.

CLI mapping: verb `process-info`; flags `--surface <id>`; plain stdout prints `pid=<v> command=<v> cwd=<v>`; JSON stdout prints the exact result object.

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

Closes one surface tab. The server kills the surface runtime, removes the tab from its pane, collapses an emptied pane out of its split tree, removes emptied screens and workspaces, and may emit `tree-changed` and `empty`.

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

Closes a pane and every tab in it. The pane is collapsed out of the screen split tree. Emptied screens and workspaces are removed.

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

Closes a screen and every pane and tab in it. The workspace remains if it still has screens; otherwise the workspace is removed.

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

Closes a workspace and every screen, pane, and tab in it. The workspace may be selected by stable key or numeric id. The active workspace selection is adjusted to keep a remaining workspace active when possible. `expected_revision` provides compare-and-swap protection against concurrent registry mutations. Stable-key selection, revision CAS, and the mutation result require `workspace-registry-v1`; the legacy numeric-id form remains available without it.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | required unless `key` is supplied | Must identify a live workspace |
| `key` | `string` | required unless `workspace` is supplied | Must match `workspace` when both are supplied |
| `expected_revision` | `uint64` | default null | Must equal the current registry revision when supplied |

Result:

```text
object{workspace:Id,key:string,workspace_revision:uint64}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown workspace <id>` | Workspace id does not exist |
| `unknown workspace key <key>` | Workspace key does not exist |
| `workspace id and key do not identify the same workspace` | Supplied selectors identify different workspaces |
| `workspace revision conflict: ...` | Compare-and-swap guard is stale |
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
{"id":16,"ok":true,"data":{"workspace":4,"key":"ops-stable","workspace_revision":3}}
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

Sets a workspace name. The workspace may be selected by stable key or numeric id. Unlike pane, surface, and screen names, an empty `name` is stored as the workspace name. `expected_revision` provides compare-and-swap protection against concurrent registry mutations. Stable-key selection, revision CAS, and the mutation result require `workspace-registry-v1`; the legacy numeric-id form remains available without it.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | required unless `key` is supplied | Must identify a live workspace |
| `key` | `string` | required unless `workspace` is supplied | Must match `workspace` when both are supplied |
| `name` | `string` | required | Empty string is stored |
| `expected_revision` | `uint64` | default null | Must equal the current registry revision when supplied |

Result:

```text
object{workspace:Id,key:string,workspace_revision:uint64}
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
| Verb | `rename-workspace` |
| Flags | `--workspace <id> --name <name>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":20,"cmd":"rename-workspace","workspace":4,"name":"prod"}
{"id":20,"ok":true,"data":{"workspace":4,"key":"ops-stable","workspace_revision":2}}
```

### resize-surface

| Field | Value |
| --- | --- |
| name | `resize-surface` |
| status | implemented |
| since | protocol 5 |

Resizes a surface to a cell grid. PTY surfaces resize both the PTY and VT terminal state. Browser surfaces update their cell grid and CDP device metrics asynchronously. Clamping and client-size bookkeeping follow [Sizing](#sizing). Protocol v7 returns `accepted`: `true` means the resize was applied or queued, while `false` means the surface already has that size, the same browser resize is pending, or its retry backoff has not elapsed. An accepted browser resize returns a numeric `reservation_id`, which is repeated by its `surface-resized` or `surface-resize-failed` completion. PTY resizes and rejected browser resizes return `null` because their completion does not need asynchronous ownership matching.

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

Moves an existing workspace to zero-based insertion `index`. The workspace may be selected by stable key or numeric id. The destination is clamped to the last workspace after removing the source, so moving right produces a final index one less than the requested insertion index. Moving a workspace to its current position is an `ok:true` no-op that preserves the current revision. `expected_revision` provides compare-and-swap protection against concurrent registry mutations. Stable-key selection, revision CAS, and the mutation result require `workspace-registry-v1`; the legacy numeric-id form remains available without it.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | required unless `key` is supplied | Workspace to move |
| `key` | `string` | required unless `workspace` is supplied | Must match `workspace` when both are supplied |
| `index` | `usize` | required | Zero-based insertion index |
| `expected_revision` | `uint64` | default null | Must equal the current registry revision when supplied |

Result:

```text
object{workspace:Id,key:string,workspace_revision:uint64}
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
{"id":27,"ok":true,"data":{"workspace":4,"key":"ops-stable","workspace_revision":4}}
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

Subscribes the connection to mux events. After this command, response lines and event lines may be interleaved on the same connection. `subscribe` does not send an initial tree snapshot; clients should call `list-workspaces` when they need state.

Protocol v7 adds opt-in tree deltas. `tree_events:"coarse"`, including the default when the field is absent, preserves the exact protocol-v6 tree behavior: tree mutations emit `tree-changed` where v6 emits it, and the subscription never receives `workspace-*`, `screen-*`, `pane-*`, or `tab-*` lifecycle deltas. `tree_events:"deltas"` selects those lifecycle deltas. A delta subscriber must handle `tree-changed` as the documented resync fallback, but must not rely on receiving it for ordinary delta-representable mutations. The selection affects only tree events; every other subscribe event is unchanged.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `tree_events` | `string` | default `"coarse"` | Protocol 7: `"coarse"` or `"deltas"` |

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

Attaches the connection to a PTY surface stream. In protocol v5, the server first sends a `vt-state` event for the current surface state, then sends live `output` events for subsequent PTY bytes, and finally sends `detached` when the stream ends. The command response is sent after the initial `vt-state` event in v5.

Protocol v6 changes the attach stream ordering to `vt-state -> (resized | output | colors-changed)* -> detached`. A v6 `resized` attach event carries a fresh replay and requires clients to discard the old mirror and replace it from that replay. The additive `vt-state.colors` field contains effective colors plus `cursor_style` and `cursor_blink` captured with the snapshot, and `colors-changed` reports later `set-default-colors` updates without changing the replay/output ordering contract. The Ghostty VT replay does not emit DECSCUSR, so clients must apply these cursor fields after replaying `data`; current per-surface DECSCUSR state takes precedence over Ghostty configuration defaults. Clients that support only protocol 5 or older must refuse protocol v6 attach streams rather than treating `resized` as a normal resize. The v6 field name `replay` could not be verified against this branch's code.

Protocol v7 adds `mode`. `mode:"bytes"`, including the default when the field is absent, is the exact protocol-v6 attach behavior above. `mode:"render"` selects the authoritative styled-cell stream specified in [`render.md`](render.md): `render-state -> (render-delta | scroll-changed)* -> detached`. A client must require `identify.protocol >= 7` before selecting render mode.

Servers advertising the `attach-initial-size` capability accept paired `cols` and `rows`. The pair records the attaching client's initial viewer-size claim before initial state is generated. Supplying only one dimension is an error. Clients must not send either field to a server that omits the capability, including an older protocol-v7 server.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |
| `mode` | `string` | default `"bytes"` | Protocol 7: `"bytes"` or `"render"` |
| `cols` | `uint16` | default null | `attach-initial-size` capability; paired with `rows`, clamped to at least 1 |
| `rows` | `uint16` | default null | `attach-initial-size` capability; paired with `cols`, clamped to at least 1 |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser panes are not supported over attach yet` | Surface is a browser |
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
{"event":"render-state","surface":1,"size":{"cols":3,"rows":1},"cursor":{"x":2,"y":0,"style":"block","blink":true,"visible":true,"color":null},"default_fg":"#d8d9da","default_bg":"#131415","scrollback_rows":0,"rows":[{"row":0,"runs":[{"text":"$ x","fg":null,"bg":null,"attrs":0}]}]}
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
object{rows:array<Row>,start:uint32,total:uint32}
```

The response `start` is `min(request.start,total)`. `rows` contains at most `count` entries and stops at `total`; `count:0` returns an empty page. `total` is the scrollback row count captured with the page and excludes the live viewport.

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
{"id":5,"ok":true,"data":{"rows":[{"row":0,"runs":[{"text":"cargo test","fg":null,"bg":null,"attrs":0}]},{"row":1,"runs":[{"text":"ok","fg":"#00ff00","bg":null,"attrs":1}]}],"start":40,"total":83}}
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

Spawns a command in a new PTY tab and returns the new surface id. `argv` executes directly without a shell. `command` executes through the session shell as `shell -lc <command>`. Exactly one of `argv` or `command` is required. By default the tab is created in the active pane. With `pane`, it is created in that pane. With `new_workspace:true`, a new workspace is created instead. Initial dimensions follow [Sizing](#sizing).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `argv` | `array<string>` | required if `command` absent | Non-empty; direct exec |
| `command` | `string` | required if `argv` absent | Executed via shell `-lc` |
| `cwd` | `string` | default null | Working directory |
| `pane` | `IdRef` | default null | Mutually exclusive with `new_workspace:true` |
| `new_workspace` | `boolean` | default false | Create isolated workspace |
| `name` | `string` | default null | Sets surface name; also workspace name when `new_workspace:true` |
| `cols` | `uint16` | default null | Used only with `rows` |
| `rows` | `uint16` | default null | Used only with `cols` |

Result:

```text
object{surface:Id,pane:Id,screen:Id,workspace:Id}
```

Errors:

| Error | Condition |
| --- | --- |
| `argv or command is required` | Neither is supplied |
| `argv and command are mutually exclusive` | Both are supplied |
| `pane and new_workspace are mutually exclusive` | Both placement options are supplied by a raw socket caller |
| `unknown pane <id>` | Supplied pane does not exist |
| spawn or PTY error string | PTY creation or child spawn fails |
| `bad request: ...` | Wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `run` |
| Flags | `[--pane <id> | --new-workspace] [--cwd <path>] [--name <name>] -- <argv...>` or `--command <cmd>` |
| Plain stdout | new surface id followed by newline |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":102,"cmd":"run","argv":["python3","-m","http.server"],"cwd":"/tmp","name":"server"}
{"id":102,"ok":true,"data":{"surface":31,"pane":2,"screen":3,"workspace":4}}
```

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

Reports agent state for a surface. This is a telemetry command and must not change focus. Reports with `source:"hook"` have hook authority and override detector-derived state. Reports with `source:"socket"` override detector-derived state but are lower priority than a newer hook report.

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

## Proposed Hooks Config

Hooks are proposed protocol v10 config, not a socket command. They are declared in `~/.config/cmux/cmux-tui.json` under `hooks`, with legacy `mux.json` still accepted.

Schema:

```text
object{
  hooks?: object{
    on-bell?: array<HookCommand>,
    on-agent-blocked?: array<HookCommand>,
    on-agent-done?: array<HookCommand>,
    on-surface-exit?: array<HookCommand>
  }
}

HookCommand =
  object{
    argv: array<string>,
    cwd?: string|null,
    timeout_ms?: uint64,
    env?: object<string,string>
  }
| object{
    command: string,
    cwd?: string|null,
    timeout_ms?: uint64,
    env?: object<string,string>
  }
```

Exactly one of `argv` or `command` is required. `argv` executes directly. `command` executes through the session shell as `shell -lc <command>`. The default timeout is 5000 ms. Hook failures are reported through the debug log and may post a `warning` notification; they must not block the mux event loop indefinitely.

Common environment:

| Env var | Meaning |
| --- | --- |
| `CMUX_MUX_SESSION` | Session name |
| `CMUX_TUI_SOCKET` | Unix socket path when available |
| `CMUX_MUX_EVENT` | Hook event name |
| `CMUX_MUX_SURFACE` | Surface id when the event is surface-scoped |
| `CMUX_MUX_WORKSPACE` | Workspace id when known |
| `CMUX_MUX_SCREEN` | Screen id when known |
| `CMUX_MUX_PANE` | Pane id when known |
| `CMUX_MUX_AGENT_STATE` | Agent state for agent hooks |
| `CMUX_MUX_AGENT_SOURCE` | Agent source for agent hooks |
| `CMUX_MUX_AGENT_SESSION` | Upstream agent session id when reported |

Hook event mapping:

| Hook | Trigger |
| --- | --- |
| `on-bell` | Implemented `bell` event |
| `on-agent-blocked` | Proposed agent state becomes `blocked` |
| `on-agent-done` | Proposed agent state becomes `done` |
| `on-surface-exit` | Implemented surface exits and is reaped |

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
