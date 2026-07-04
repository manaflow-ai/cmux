# Command Contract

This file specifies the JSON command contract for the cmux-mux protocol. Implemented commands match protocol v5 in `mux/crates/mux-core/src/server.rs`. Proposed commands are future protocol v6 design.

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

The v5 server does not explicitly deny unknown JSON fields. Clients must not depend on unknown fields being rejected.

Common CLI exit codes for every mapping are `0` success, `1` command error, `2` CLI usage error, and `3` connection error.

## Shared Implemented Result Types

`Tree`:

```text
object{
  workspaces: array<object{
    id: Id,
    name: string,
    active: boolean,
    screens: array<object{
      id: Id,
      name: string|null,
      active: boolean,
      active_pane: Id,
      layout: Layout,
      panes: array<Pane>
    }>
  }>
}
```

`Layout`:

```text
object{type:"leaf",pane:Id}
| object{type:"split",dir:"right"|"down",ratio:float32,a:Layout,b:Layout}
```

`Pane`:

```text
object{id:Id,name:string|null,active_tab:usize,tabs:array<Tab>}
| object{id:Id,dead:true}
```

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

The `dead` pane variant is serialized by the v5 server only if the tree references a pane missing from state. That should not occur in normal operation, but clients must tolerate it.

## Implemented Commands

### identify

| Field | Value |
| --- | --- |
| name | `identify` |
| status | implemented |
| since | protocol 5 |

Returns process and protocol metadata for the connected mux server. Clients use this command to verify that the socket endpoint is cmux-mux and to check feature compatibility.

Params: none.

Result:

```text
object{app:"cmux-mux",version:string,protocol:uint32,session:string,pid:uint32}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad request: ...` | Malformed request envelope |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `identify` |
| Flags | none |
| Plain stdout | `cmux-mux session=<session> protocol=<protocol> pid=<pid>` |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-mux","version":"0.1.0","protocol":5,"session":"main","pid":12345}}
```

### list-workspaces

| Field | Value |
| --- | --- |
| name | `list-workspaces` |
| status | implemented |
| since | protocol 5 |

Returns the full workspace, screen, pane, tab, and split-tree snapshot. The snapshot includes active flags, active pane ids, active tab indexes, tab titles, tab names, surface kinds, browser source, size, and dead flags.

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
{"id":2,"ok":true,"data":{"workspaces":[{"id":4,"name":"1","active":true,"screens":[{"id":3,"name":null,"active":true,"active_pane":2,"layout":{"type":"leaf","pane":2},"panes":[{"id":2,"name":null,"active_tab":0,"tabs":[{"surface":1,"kind":"pty","browser_source":null,"name":null,"title":"","size":{"cols":80,"rows":24},"dead":false}]}]}]}]}}
```

### send

| Field | Value |
| --- | --- |
| name | `send` |
| status | implemented |
| since | protocol 5 |

Writes input to a PTY surface. `text`, when present, is UTF-8 encoded and written as bytes. `bytes`, when present, is standard base64 decoded and written as raw bytes. If both are present, v5 writes `text` first and `bytes` second. If neither is present, v5 returns success and writes nothing.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |
| `text` | `string` | default null | Written before `bytes` when both are present |
| `bytes` | `Base64` | default null | Decoded with standard base64 |

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
| Flags | `--surface <id> [--text <text>] [--bytes <base64>]` |
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

Creates a new PTY tab in a pane and makes it the active tab. If `pane` is absent, the active pane of the active screen is used. If the session has no workspaces and no pane is supplied, v5 creates a new workspace containing the tab. In that empty-session fallback, a supplied `cwd` is silently dropped because v5 delegates to `new_workspace(None, size)`. The new tab inherits the active surface working directory of the target pane when `cwd` is absent.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | default null | Target pane; unknown ids error |
| `cwd` | `string` | default null | PTY child working directory |
| `cols` | `uint16` | default null | Used only when paired with `rows` |
| `rows` | `uint16` | default null | Used only when paired with `cols` |

If only one of `cols` or `rows` is present, v5 ignores both because the server uses `cols.zip(rows)`.

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

Creates a browser tab in a pane and makes it active. If `pane` is absent, the active pane is used. If the session has no workspaces and no pane is supplied, v5 creates a new workspace containing the browser tab. The browser runtime may connect to an external CDP endpoint or launch Chrome according to mux configuration.

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

Creates a new workspace with one screen, one pane, and one PTY tab, then makes the new workspace active. If `name` is absent, the workspace name is the next 1-based workspace count at creation time.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `name` | `string` | default null | Workspace name; empty string is accepted |
| `cols` | `uint16` | default null | Used only when paired with `rows` |
| `rows` | `uint16` | default null | Used only when paired with `cols` |

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

### new-screen

| Field | Value |
| --- | --- |
| name | `new-screen` |
| status | implemented |
| since | protocol 5 |

Creates a new screen in a workspace with one pane and one PTY tab, then makes the new screen active. If `workspace` is absent, the active workspace is used. If no workspace exists and `workspace` is absent, v5 creates a new workspace instead.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | default null | Target workspace; unknown ids error |
| `cols` | `uint16` | default null | Used only when paired with `rows` |
| `rows` | `uint16` | default null | Used only when paired with `cols` |

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

### split

| Field | Value |
| --- | --- |
| name | `split` |
| status | implemented |
| since | protocol 5 |

Splits the screen containing `pane`, inserts a new pane after the target leaf, spawns one PTY tab in the new pane, and focuses the new pane. `dir:"right"` creates left/right columns. `dir:"down"` creates top/bottom rows. The new surface inherits the active surface working directory of the target pane when available.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Target split leaf |
| `dir` | `string` | required | `"right"` or `"down"` |
| `cols` | `uint16` | default null | Used only when paired with `rows` |
| `rows` | `uint16` | default null | Used only when paired with `cols` |

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

### set-default-colors

| Field | Value |
| --- | --- |
| name | `set-default-colors` |
| status | implemented |
| since | protocol 5 |

Updates the session default foreground and/or background colors used by PTY surfaces. Missing fields preserve their previous values. Existing PTY surfaces receive the merged defaults. The v5 server emits `surface-output` for every existing surface, including browser surfaces; browser color application is a no-op, but the event is still emitted. Future PTY surfaces start with the merged defaults.

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

Closes a workspace and every screen, pane, and tab in it. The active workspace selection is adjusted to keep a remaining workspace active when possible.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | required | Must identify a live workspace |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown workspace <id>` | Workspace id does not exist |
| `bad request: ...` | Missing `workspace` or wrong JSON type |

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
{"id":16,"ok":true,"data":{}}
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

Sets a workspace name. Unlike pane, surface, and screen names, an empty `name` is stored as the workspace name and does not clear to a generated fallback in v5.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | required | Must identify a live workspace |
| `name` | `string` | required | Empty string is stored |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown workspace <id>` | Workspace id does not exist |
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
{"id":20,"ok":true,"data":{}}
```

### resize-surface

| Field | Value |
| --- | --- |
| name | `resize-surface` |
| status | implemented |
| since | protocol 5 |

Resizes a surface to a cell grid. PTY surfaces resize both the PTY and VT terminal state. Browser surfaces update their cell grid and CDP device metrics. `cols` and `rows` are clamped to at least 1 by the surface runtime. The command result does not report whether the size changed.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live surface |
| `cols` | `uint16` | required | Final value clamped to at least 1 |
| `rows` | `uint16` | required | Final value clamped to at least 1 |

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
| Verb | `resize-surface` |
| Flags | `--surface <id> --cols <n> --rows <n>` |
| Plain stdout | no output |
| JSON stdout | exact result object |
| Exit codes | common |

Example:

```json
{"id":21,"cmd":"resize-surface","surface":1,"cols":120,"rows":40}
{"id":21,"ok":true,"data":{}}
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

Subscribes the connection to mux events. After this command, response lines and event lines may be interleaved on the same connection. `subscribe` does not send an initial tree snapshot; clients should call `list-workspaces` when they need state.

Params: none.

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| thread spawn error string | Server cannot create the event writer thread |
| `bad request: ...` | Malformed request envelope |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `subscribe` |
| Flags | none in v5 |
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

Attaches the connection to a PTY surface stream. The server first sends a `vt-state` event for the current surface state, then sends live `output` events for subsequent PTY bytes, and finally sends `detached` when the stream ends. The command response is sent after the initial `vt-state` event in v5.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live PTY surface |

Result:

```text
object{}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `browser panes are not supported over attach yet` | Surface is a browser |
| terminal error string | VT replay generation fails |
| thread spawn error string | Server cannot create the attach writer thread |
| `bad request: ...` | Missing `surface` or wrong JSON type |

CLI mapping:

| Item | Value |
| --- | --- |
| Verb | `attach-surface` |
| Flags | `--surface <id>` |
| Plain stdout | JSON event object per line |
| JSON stdout | JSON event object per line |
| Exit codes | common; runs until `detached`, connection closes, or interrupted |

Example:

```json
{"id":28,"cmd":"attach-surface","surface":1}
{"event":"vt-state","surface":1,"cols":80,"rows":24,"data":"G1s/bA=="}
{"id":28,"ok":true,"data":{}}
```

## Proposed Commands

### wait-for

| Field | Value |
| --- | --- |
| name | `wait-for` |
| status | proposed |
| since | proposed protocol 6 |

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
| status | proposed |
| since | proposed protocol 6 |

Spawns a command in a new PTY tab and returns the new surface id. `argv` executes directly without a shell. `command` executes through the session shell as `shell -lc <command>`. Exactly one of `argv` or `command` is required. By default the tab is created in the active pane. With `pane`, it is created in that pane. With `new_workspace:true`, a new workspace is created instead.

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
| status | proposed |
| since | proposed protocol 6 |

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
| status | proposed |
| since | proposed protocol 6 |

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
| status | proposed |
| since | proposed protocol 6 |

Returns the session id mapping and establishes the short-id scheme. Every workspace, screen, pane, and surface has a numeric id and a stable short id for the lifetime of the session. Short ids are content-independent, collision-checked per session, and usable anywhere an `IdRef` is accepted.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `kind` | `string` | default null | Optional filter: `"workspace"`, `"screen"`, `"pane"`, or `"surface"` |

Short id format:

```text
[a-z0-9]{6}
```

Generation rule: the server derives a candidate from a per-session random seed plus numeric id, encodes it base36, and checks for collisions across all live ids. On collision, it rehashes with an incrementing salt. Short ids never depend on names, titles, command text, cwd, or layout position. A short id is not reused while the session is alive.

Resolution rule: numeric JSON ids resolve first. String ids matching `[0-9]+` are rejected as ambiguous. String ids matching the short-id format resolve by exact short id. Unknown or ambiguous strings error.

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
| status | proposed |
| since | proposed protocol 6 |

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
| status | proposed |
| since | proposed protocol 6 |

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
| status | proposed |
| since | proposed protocol 6 |

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

Hooks are proposed protocol v6 config, not a socket command. They are declared in `~/.config/cmux/mux.json` under `hooks`.

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
| `CMUX_MUX_SOCKET` | Unix socket path when available |
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
| Resize command | `resize-surface` does not report whether size changed or final clamped size | Return `{changed,cols,rows}` |
| Ratio command | `set-ratio` silently clamps and does not return final ratio | Return `{ratio}` after clamping |
| Naming commands | Empty string clears pane/surface/screen names but stores an empty workspace name | Make empty string clear all optional display names, including workspace |
| Attach response ordering | `attach-surface` sends `vt-state` before the command response | Either document as permanent or return the initial `vt-state` in the response and reserve events for live stream |
| Error taxonomy | Errors are strings from `anyhow`, IO, base64, and terminal layers | Add stable machine error codes while preserving messages |
| Optional size pair | Supplying only one of `cols` or `rows` is silently ignored | Reject partial size pairs |
| Unknown fields | Unknown request fields are ignored by serde | Reject unknown fields or define extension slots |
