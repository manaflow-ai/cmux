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
object{workspace_revision?:uint64,pane_revision?:uint64,groups?:array<WorkspaceGroup>,workspaces:array<Workspace>}
```

`Workspace`:

```text
object{id:Id,key?:string,name:string,group?:string|null,color?:string|null,icon?:string|null,title?:string|null,pinned?:boolean,marked_unread?:boolean,active:boolean,screens:array<Screen>}
```

Servers advertising `notification-ack-v1` add `unread_count`, the number of
tabs in the workspace whose content has an unread notification marker.

Servers advertising `workspace-metadata-v1` add the shared presentation
fields `color` (palette token or `#RRGGBB[AA]`), `icon` (an icon value, see "Icon values" under `put-blob`), and
`title` (a custom sidebar title that overrides `name` for display). Each is
null when unset.

Servers advertising `workspace-pin-v1` add `pinned`, true while the workspace
is pinned to the top of the sidebar.

Servers advertising `notification-mark-unread-v1` add `marked_unread`, true
while the workspace is marked unread by hand. It is independent of
`unread_count`; frontends show it as unread. The daemon never clears it on its
own: a frontend clears it with `set-workspace-metadata` when the user types
into one of the workspace's terminals (the Mac app does this for workspaces on
this Mac), or marks the workspace read or clears
its notifications. Focusing or opening the workspace keeps it.

Servers advertising `workspace-groups-v1` add the ordered `Tree.groups` array
(the `list-workspace-groups` result) and `Workspace.group`, the id of the
workspace's group or null. Groups partition the workspace order: a sidebar
section lists the workspaces of one group in `workspaces` order.

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
  columns?:array<object{
    id:Id,
    width:float32,
    layout:Layout,
    dock?:object{edge:"left"|"right"|"top"|"bottom",mode:"docked"|"overlay"},
    rows?:array<object{id:Id,height:uint16,layout:Layout}>
  }>,
  panes:array<Pane>
}
```

Servers advertising `viewport-splits-v1` include `viewport_splits` when a screen uses horizontal viewport columns. Each entry marks a right split whose second child is appended to a horizontal virtual canvas. `width` is the second child's width as a fraction of each frontend's viewport. Ordinary screens omit the field. Clients that do not implement the capability may ignore it and render the split's fallback ratio.

Servers advertising `viewport-column-resize-v1` include `viewport_base_width` when horizontal viewport layout is active. It is the width of the first column as a fraction of the frontend viewport. A missing value defaults to `1.0`.

`columns` lists the horizontal viewport columns in order while viewport layout is active and is omitted otherwise. `id` is the column's stable id (also `after_column` in `move-tab-to-column`), `width` its fraction of the frontend viewport, and `layout` the split tree inside it.

Servers advertising `dock-columns-v1` add `dock` to a column pinned with `set-column-dock` and omit it for a scrolling column. `edge` is the viewport edge the frontend keeps the column at while the other columns scroll. With `mode:"docked"` the column's width is taken out of the scrolling area; with `mode:"overlay"` it floats above the scrolling columns. A screen has at most one docked column per edge and always at least one scrolling column. `columns` keeps the stored order, so a client without the capability renders a docked column in place. The flag moves with the column, persists across daemon restarts, is restored by `undo-layout`, and disappears with the column. A new column is never docked unless `move-tab-to-column` names `dock`. When removing columns would leave only docked columns, the server clears their flags; when the screen collapses to one column, `columns` is omitted. With `dock-column-role-v1`, `dock.role` names what the column is for (`"agent_chat"`: the agent chat column of cmux next); it is omitted when unset, kept with the pin, and dropped when the column is unpinned or pinned again without one. The agent chat column keeps its chat as its top pane: every new pane in it (a split, a row, an auto-layout append, an edge drop) is refused with `dock-column-agent-chat`, except, with `dock-column-split-down-v1`, a split toward `down` of a pane in a column that is not pinned, which adds that pane below it (Cmd-Shift-D).

Servers advertising `permanent-dock-v1` accept `permanent: true` in `set-column-dock` and then report `"permanent": true` in that column's `dock` (omitted while false; a record or client without the capability reads the column as an ordinary docked one). A permanent column stays docked on its edge for every client: its `mode` may change, and a later `set-column-dock` that omits `permanent` keeps it. An undock, a move to another edge, another column taking that edge, or any close, move or undo that would remove the column from its workspace (closing its pane, closing the last scrolling column beside it, moving its last tab out) is refused with `error_code` or `reason_code` `"dock-column-permanent"`. Closing the whole workspace, or a terminal in it exiting, is not refused. The flag is never cleared.

Servers advertising `pinned-dock-v1` accept `pinned: true` in `set-column-dock` (and `pinned`, `allow_tabs` in the resource op `column.update`) and report `"pinned": true` and `"allow_tabs": true` in that column's `dock` (each omitted while false). A pinned column is the Home dock: a column kind, not a title or page check. Its first tab is its pinned tab: a close, a move out of the column, or a reorder that takes the first place from it is refused. While `allow_tabs` is false (the default) no other tab enters the column: a new tab, a move in or a drop is refused; with it true, other tabs come and go freely. The column itself is never removed, undocked, moved to another edge or unpinned, and a later `set-column-dock` keeps both flags. Every refusal answers `error_code` or `reason_code` `"dock-column-pinned"`. Closing the whole workspace, or a terminal in it exiting, is not refused. `pinned` is never cleared; `allow_tabs` changes only with `column.update`.

Servers advertising `pinned-dock-alone-v1` let a pinned column be a screen's only column (Home's dock with nothing beside it): every other dock needs a scrolling column beside it, a pinned one does not. `move-tab-to-column` with a `dock` whose `pinned` is true may move a pane's only tab without `respawn`: the source pane closes and, when nothing else was on the screen, the new pinned column is its only column (`columns` lists just it, at its own width). Closing the last column beside a pinned column is no longer refused: the pinned column stays, alone. A frontend draws a lone pinned column across the whole screen. A pinned column alone still takes no other tab; a browser or conversation tab created in it (`tab.create_browser`, `new-frontend-browser-tab`, `new-conversation-tab {pane}`) opens in a new column right of it in the same commit, 0.5 wide (a background tab keeps the focus where it was), and a terminal tab is refused as before. A conversation split to its right (`new-conversation-tab {split: {direction: "right"}}`) is a new column beside it, 0.5 wide like a link `workspace.open_url` opens there. A lone pinned column is stored outside `viewport_json` (which stays empty, so a server without the capability reads the screen as a plain tree) and restored with its id, width and flags.

Servers advertising `edge-docks-v1` also pin columns to the `top` or `bottom` edge: a screen-wide band the frontend draws above or below the scrolling columns. Such a column carries `dock` (same shape as `dock`) instead of `dock`, so a client without the capability renders it as an ordinary column. The per-edge, at-least-one-scrolling and normalization rules cover all four edges. A top or bottom pin persists outside the screen's stored viewport record, so a daemon without the capability reads the column as an ordinary one.

Servers advertising `rows-v1` add `rows` to a column with two or more rows and omit it for a column with one row. Each column is a vertical strip of rows, top to bottom: `id` is the row's stable id, `height` its height in permille of the column's viewport height (100 to 1000; the sum is not fixed, at most 1000 fills the column and more scrolls it), and `layout` the split tree inside the row. The column's `layout` stays the compatibility chain: the rows folded into `down` splits whose `split` ids are the ids of rows 2..n and whose ratios follow the heights, so a client without the capability still sees every pane. `set-split-ratio` and `set-ratio` refuse such a synthetic split with `row-split-compat-readonly`; resize rows with `set-row-heights`. One column with two or more rows keeps `columns`; a removal that leaves one column with one row collapses the screen to its split tree. An emptied row is removed in the same commit. Rows persist across daemon restarts outside the screen's stored viewport record and are restored by `undo-layout`. `workspace.layout.apply` with a columns document (`root.kind: "viewport"`, the form `screen.layout.export` returns for a screen with rows) carries each column's rows: a column with two or more rows lists `rows: [{row_id, height}]` top to bottom, where row 2..n's `row_id` is the `split_id` of its compat chain split in the column's `root` (each row's content is its subtree of that chain). Applying a document sets the rows and heights it lists: row 1's `row_id` is the column's current row 1 id or omitted (a new id when the column has none), so a document can turn a vertical split chain into rows; `rows: []` leaves the column one row (the chain splits stay as plain splits); an omitted `rows` keeps the rows of the column with the same `column_id`. A chain split's ratio follows the row heights. A document whose tree does not hold a column's compat chain, or whose height is outside 100 to 1000, is refused and changes nothing. A split-tree document (no viewport columns) cannot carry rows, so applying one to a screen with rows is refused (`operation.failed`, `reason_code: "rows-layout-replace-unsupported"`) and changes nothing. A column keeps its `id` when it is left as the only column of rows and when a second column joins it, across daemon restarts too; the only column fills the screen width (`width` 1.0). A row keeps its `id` for its lifetime, and no row or column id is ever reused.

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

Servers advertising `tab-metadata-v1` add `pinned:boolean` to every tab, plus
`cwd:string|null`, `git_branch:string|null`, and `git_detached:boolean`. Pinned
tabs sort first in their pane. `cwd` is the directory the tab presents: the
shell's last OSC 7 report, or the directory the terminal launched in. The
daemon reads the git HEAD of the repository containing `cwd` on the machine
that hosts the PTY, without running git: `git_branch` is the branch name, or
the seven-character commit when `git_detached` is true. Browser tabs report
null. A changed `cwd` emits `tab-changed`; a branch switch without a directory
change appears at the next snapshot (HEAD lookups are cached for two seconds).

Every tab also reports `pinned_url:string|null`: for a pinned browser tab, the
page it showed when it was pinned (pinning an already pinned tab keeps it, and
unpinning forgets it); null for an unpinned tab, a terminal, or a pin an older
server stored.

Servers advertising `frontend-browser-tabs-v1` add `browser_renderer` to
every tab: `"daemon"` for a CDP browser, `"frontend"` for a browser whose page
the frontend renders, and null for a PTY. Frontend browsers also report
`browser_engine` (`"webkit"` or `"cef"`), `favicon_url`, and
`browser_profile_id`, and report null `browser_status`/`browser_error`. Their
`url` and `title` are the values the frontend last recorded. Servers advertising
`frontend-browser-owner-v1` also report `browser_owner`, the install id of the
app that hosts the page (null when no app has claimed it).

Servers advertising `remote-terminal-tabs-v1` report a tab that references a
terminal on another session (`new-remote-terminal-tab`) as
`kind:"remote-terminal"` with `remote:object{session_id:string,
terminal_id:string, session_name:string}` and `title` (the recorded title,
else `Terminal on <session_name>`). Such a tab has no `terminal_id`,
`terminal_resource_id`, or `terminal_incarnation` field and reports null
`url`, `cwd`, `git_branch`, and browser fields. Its snapshot is never in the
tree (`remote-terminal-snapshot` reads it).

Terminal tabs carry `terminal_host_fallback:
"breakaway_denied"|"host_start_failed"|null`. It is null unless the terminal
will end with something other than its shell although terminal hosts are on:
`breakaway_denied` is a Windows daemon in a Job Object that forbids breakaway
and kills its processes on close, so the terminal's host runs inside that job
and ends when the program that started the daemon closes it (it still
survives a daemon restart); `host_start_failed` is a host process that did
not start, so the daemon runs the terminal itself and it ends with the
daemon. A job that forbids breakaway without killing on close keeps the host
alive and reports null. The field is set before the tab is first published
and does not change for the terminal's life, so every tree shows it. Browser
tabs report null. Clients treat an unknown value as a notice for another
reason and ignore the field when the server omits it.

Servers advertising `tab-groups-v1` add `tab_groups` to every pane, in strip
order: `array<object{id:string, name:string, color:string, collapsed:bool,
saved_id:string|null, start:usize, count:usize, surfaces:array<Id>}>`, and
`group:string|null` to every tab. With `tab-group-icon-v1` each run also
carries `icon:string|null`, the group's icon. `start` is the strip index of the group's
first tab. Group members are contiguous; a tab another path moved away from
its group's run is reported ungrouped. A color is one of nine tokens, `grey`,
`blue`, `red`, `yellow`, `green`, `pink`, `purple`, `cyan`, `orange`, or a
custom `#RRGGBB`, kept as given.

The `dead` pane variant is serialized only if the tree references a pane missing from state. That should not occur in normal operation, but clients must tolerate it.

## Sizing

Every surface has one authoritative cell grid. Byte and render attach modes observe the same grid; attaching by itself never resizes it.

Each client reports the cell grid available for every surface it displays with
`resize-surface`. Terminals use the shared sizing reducer defined in
[`docs/shared-terminal-sizing.md`](../../docs/shared-terminal-sizing.md) and
implemented in `crates/cmux-terminal-sizing` (re-exported as `cmux_tui_core::sizing_policy`). Every client view of a
terminal placement is one participant with id `c<client>` (or
`c<client>@<placement>` for a projected placement other than the terminal's
first), and every relay sub-view is one participant `c<client>/<view>`. A view
joins when it attaches or first reports a size and leaves when its last attach
stream ends or its connection closes.

The default policy is `latest`: the counting participant with the newest
activity sets the grid. Activity is attaching, an explicit claim through
`set-client-sizing` (or the local TUI's focus), and `send`/`send-key` input.
Other views crop, pan, or scale the canonical grid. When the owner leaves, the
next owner takes the grid in the same step; the grid never freezes waiting for
a departed owner. With no counting participant the grid keeps its last size.
`set-size-policy` selects `smallest`, `largest`, `priority`, or `fixed`, and
`set-size-counts` sets a participant's counts-toward-size override (tmux
`attach -f ignore-size` is `counts:false`). A resize that the engine did not
make, such as a direct terminal-host renderer's, is not reverted until the
engine's own decision changes.

Browser surfaces retain the legacy smallest-reported-grid reducer because a
browser surface still has one live tab. When a browser tab becomes hidden, the
client sends `release-surface-size`; detaching or disconnecting also removes
its report. Internal server-only resizes do not update client reports.

Optional-size creation commands are `apply-layout`, `new-tab`, `new-browser-tab`, `new-workspace`, `new-screen`, `new-pane`, `new-pane-right`, `split`, and `run`. The `split` command uses `dir:"right"` or `dir:"down"`; receipt operations may use `split-right` or `split-down`. `create-terminal` and `create-surface-with-receipt` also accept dimensions but require the pair. `attach-surface` requires the pair when `attach-initial-size` is used. Their rules are:

| Input | Behavior |
| --- | --- |
| both `cols` and `rows` supplied | Clamp each to `1..10000`, use the pair for the new surface or surfaces, and record the effective grid as the latest client size |
| neither supplied | Use the latest active client size, or the configured server default when no client reports remain |
| only one supplied | Optional-size commands ignore the incomplete pair. `create-terminal`, `create-surface-with-receipt`, and `attach-surface` are strict exceptions: they return an error and require `cols` and `rows` together. |

`resize-surface` requires both fields and clamps each to `1..10000`. Attached
clients retain the report until release; an unattached one-shot report is
removed when its connection closes. A terminal report from a
view that does not set the grid returns `accepted:false`, but the report is
retained and takes effect when that view becomes the owner.

For terminals, `set-client-sizing` maps onto the shared reducer.
`enabled:true` (with or without `exclusive`) clears a `counts:false` override
and counts as activity for the selected view; `enabled:false` sets
`counts:false`; omitting `client` and `exclusive` restores the automatic
counts rule for every view of the terminal. For browsers, the same command
retains the legacy include, exclude, and exclusive reducer controls.

### Relay attachment sizing boundary

The Rust `chatmux-relay` wrapper can have several relay viewers for one
terminal. When its local owner leaves, disconnects, or receives an
unsuccessful report response, the wrapper closes that attachment and does not
issue a replacement claim from another relay socket. The core server elects
the next owner among the remaining participants itself.

A relay that forwards several leaves on one connection (a Mac mirror with its
paired phones) reports each leaf as a relay sub-view with
`resize-attached-view {surface, view, identity, cols, rows}`. The relay's own
view stays its `attach-surface` lease. Sub-views have no byte stream: the
relay renders for them and forwards `size-state` and `detached` (with `view`)
back down. A relay that forwards a leaf's input sends it with `send`/`send-key`
and then `note-size-activity {surface, view}`, so the activity belongs to the
leaf and not to the relay.

A connection that sends `set-client-info remote:true` (cmux-mobile-host does
for every phone it splices, with the link's own `device_id`) is a remote
device's lane: it is never one of this host's own views for the host sizing
policy (`get-host-size-policy`). The mark is sticky for the connection and is
never published in `size-state`.

Identity trust: `user_id` in `set-client-info` and in a sub-view `identity` is
asserted by the connection. This daemon has no Stack session and cannot verify
it; relay tickets carry no user identity. It only selects the same-user
handheld rule and priority keys, never access.

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
object{app:"cmux-tui",version:string,build_commit?:string|null,build_id?:string|null,cli_path?:string|null,ghostty_commit?:string|null,protocol:uint32,capabilities:array<string>,session:string,pid:uint32,session_id?:string,machine_id?:string,machine_platform?:object{os:string,arch:string},machine_capabilities?:array<string>,machine_name?:string,registry_id:string,generation:string,workspace_revision:uint64}
```

`machine_id` is the opaque owner ID returned by `machine.list`, persisted with the
machine registry. It is distinct from the session's `registry_id`, the boot's
`generation`, host names and client UI routes. Older daemons may omit it; clients
must leave the machine owner unknown rather than derive an ID from other fields.
`machine_platform` and `machine_capabilities` describe that owner using the same
source as its native `machine.list` snapshot. Machine capabilities are separate
from protocol features in `capabilities`. Older owners may omit the new fields;
clients retain unknown platform and an empty capability list.

With `revisions: true` the reply also carries `build_time`: unix seconds of the
source commit the daemon was built from, or null when unknown. A client that
updates the machine (`cmux link machine update --if-older`) moves it only to a
build with a later time, never back to an older one.
The conversations-only remote `identify` remains restricted to `app`, `protocol`
and `capabilities`.

With `launch-snapshot-v1`, `launch_snapshot_path` is the absolute path of the session's launch snapshot, or `null` when the session has no durable registry. The daemon keeps that owner-only JSON file next to its registry: `{schema_version:1, app:"cmux-tui", version, session, registry_id, generation, written_at_ms, tree, personal, frontend_projections}`, where `tree` is the `list-workspaces` result, `personal` is the `list-personal` result without room `defaults.env` (or `null` when it cannot be read), and `frontend_projections` lists every native frontend projection (`{frontend, scope, subject_key, schema_version, projection_revision, projection}`; omitted as `[]` when the file would exceed 8 MiB). It is rewritten atomically (temporary file and rename) once changes to the tree, layout, personal state or projections settle (a title change alone does not rewrite it, so titles are those of the last write) (500 ms after the last change, at most 3 s after the first), once at daemon start, and never while nothing changes. A frontend may read it before it connects, to draw the last known layout, and must replace it with live state after `identify`; the daemon never reads it, so it is never a second source of truth.

`build_commit` and `ghostty_commit` are additive build-stamp fields. They are omitted or `null` when the binary was built without the corresponding stamp, so clients must preserve compatibility with older servers and unstamped local builds.

With `daemon-build-v1`, `build_id` names the exact build of the binary that serves the socket (its source commit, with a hash of uncommitted source changes for a dirty build), and `cli_path` is the absolute, symlink-resolved path of that binary, which is also the `cmux` CLI that matches the daemon (`null` when it cannot be resolved). A daemon advertises the capability only when its entry point recorded both at start. A CLI of another build uses them to run the matching CLI (plans/cmux-next/version-skew.md); it must check the path itself and never trust it for a remote daemon. Remote attach forwards `identify` unchanged, so these fields then describe the remote machine's binary.

`capabilities` is additive build-level feature negotiation within a protocol version. Clients must treat a missing field as an empty list. `daemon-handoff-force-v1` advertises the optional `force` field on `shutdown-daemon`. `browser-provider-v1` advertises the trusted-local, connection-scoped native browser provider lease used by cmux-browser and local automation. `browser-provider-native-hosting-v1` advertises the optional `hosting` field of `register-browser-provider`: a `"native"` provider presents its pages itself, so the daemon never overrides their device metrics and screencasts them only while a frame viewer is attached. `browser-pointer-frame-guard-v1` advertises authoritative `pointer_frame_seq` and `pointer_frame_floor_seq` browser attach/frame state plus the additive `browser-frame-presented`, `browser-mouse-guarded`, and `browser-wheel-guarded` commands. Each admitted bitmap receives a new guard even when its document and dimensions match the previous bitmap. The reported floor through latest range proves route membership only. `browser-frame-presented` advances one exact acknowledged token for that connection, and only that token authorizes a new guarded pointer action. A guarded pointer command implicitly acknowledges its own token. Each connection retains one token, while the bounded browser input queue owns actions admitted before a later presentation. Navigation or geometry changes clear the range and all acknowledgements. An accepted press keeps its original guard for motion across ordinary repaints while document and geometry remain valid; invalidation suppresses further motion but retains its balancing release. A capable client echoes that value in `set-client-info`; browser attach requires the bilateral capability while PTY attach remains available without it. The legacy `browser-mouse` and `browser-wheel` schemas retain their optional guard, but guarded servers reject a missing guard before surface lookup. `viewport-splits-v1` advertises `new-pane-right` and the `Screen.viewport_splits` field. `viewport-column-resize-v1` advertises `set-viewport-pane-width` and `Screen.viewport_base_width`. `pane-browser-kind-v1` advertises `kind` and `url` on `split` and `new-pane-right`: `kind:"browser"` with a non-empty `url` puts a browser tab at that URL in the new pane, through the same `pane.split` commit and restart recovery as a terminal pane; public `pane.split` stays terminal-only. `layout-undo-v1` advertises server-owned structural layout history and `undo-layout`. `view-attachment-lease-v1` returns a connection-owned lease for each attach and enables lease-fenced sizing. `view-attachment-detach-v1` enables targeted stream cleanup. `creation-receipts-v1` enables idempotent destination creation, `creation-attempt-keys-v1` separates a stable correlation from the same-key or new-key execution attempt selected by `session.creation.resolve`, and `creation-selector-fallbacks-v1` adds bounded ordered destination continuations. `provider-managed-workspace-authority-v2` advertises pre-provisioned provider ownership and authority-gated post-provider rename and close commits. `terminal-idle-close-v1` advertises `set-terminal-idle-policy` and the owner-side reaper that closes a terminal after its policy elapses with no attached view. `resume-command` advertises `terminal-resume-command`: a person's resume command for one terminal, typed on the new prompt when the owner respawns it. `terminal-pending-sequence-v1` advertises the separate `pending` field on byte-attach `vt-state` and `resized` events; a client that echoes it in `set-client-info` receives it (see `events.md`). `terminal-placement-env-v1` advertises a caller-chosen `terminal_id` on `new-tab`, `split`, `new-pane`, and `new-pane-right`, `cwd` and `env` on `new-pane` and `new-pane-right`, and `terminal_id`/`terminal_incarnation` in all four results. `split-client-keys-v1` advertises the client-minted `pane_id` and `tab_id` on `split`, `new-pane`, and `new-pane-right`, keyed retries that return the first result with `replayed`, and `pane_id`/`tab_id` in their results (see "Client-minted pane ids"). `row-client-keys-v1` advertises the same client-minted `pane_id` and `tab_id` on `new-row`, and `pane_id`/`tab_id` in its result. `split-client-split-id-v1` advertises the client-minted `split_id` on `split` and on the `split` of `new-conversation-tab`, and `split_id` (the split's public id) on every split node of a layout (see "Client-minted split ids"). `terminal-resources-v1` advertises `terminal-resources`, which reads the CPU time and memory of each terminal's shell, descendants, and terminal host at request time. `batch-close-v1` advertises `close-tabs` and the optional `end_terminals` field on `close-pane`, `close-screen`, `close-workspace`, and `close-tab-group`: many placements and the terminals they end close in one durable commit. `close-workspace-if-empty-v1` advertises the optional `if_empty` field on `close-workspace`: the close commits only when the workspace has no tab at commit time, else it fails with `workspace_not_empty` and changes nothing. `end-terminals-keep-layout-v1` advertises `keep_layout` on `shutdown-daemon`: with `end_terminals`, placed terminals keep their tabs across the handoff. `tab-restart-kept-layout-v1` (Unix owners, with `tab-restart-v1`) advertises that `restart-tab` of a tab kept by `keep_layout` starts the new shell in the directory the keep recorded and ends the keep once the new shell is in the tab: the tab's `relaunch` is null again, its shell's exit closes it, and a host loss respawns it. `tab-park-v1` (Unix owners) advertises `park-tabs`, which ends the shells of terminal tabs and keeps the tabs as `keep_layout` does, each with `relaunch.on_show: true` so a frontend restarts it when its workspace is first shown. `terminal-reap-v1` advertises the owner-side reaper that ends a terminal after it has had no tab placement for the reap grace period (active only when the daemon was started with `--terminal-reap-grace-seconds`), `set-terminal-keep`, the `keep` field on `new-tab`, `split`, and `create-terminal`, the `terminal-reaped` event, and `end_terminals` on `shutdown-daemon`. `dock-columns-v1` advertises `set-column-dock` and the optional `Screen.columns[].dock` field for every edge; the resource API operation `column.update` (resource-operations-v2.json) sets the same flag and the column width. `terminal-env-v1` advertises the per-terminal `env` object on `new-tab`, `split`, and `create-terminal`, and `cwd` on `split`. `tab-groups-v1` advertises Chrome-style tab groups: the `*-tab-group` commands, `Pane.tab_groups`, and `Tab.group`. `saved-tab-groups-v1` advertises saved groups: `save-tab-group`, `unsave-tab-group`, `delete-saved-tab-group`, `list-saved-tab-groups`, and `reopen-saved-tab-group`. `notification-ack-v1` advertises `ack-tab-notifications`, `list-notifications`, durable notification acknowledgement, and `Workspace.unread_count`. `tab-drag-v1` advertises the single-command tab drag outcomes `move-tab-to-split`, `move-tab-to-column`, and `move-tab-to-new-workspace`, layout undo for same-screen tab drags and cross-pane `move-tab`, and the optional `transaction` field on every drag command, echoed in the resulting `tab-changed` delta. `tab-workspace-name-v1` advertises the optional `name` field on `move-tab-to-new-workspace`: the new workspace takes that name in the same commit. `workspace-name-source-v1` advertises workspace name provenance: `source`, `expected_generation` and `expected_name_revision` on `rename-workspace` and `workspace.rename`, and `name_source` (`user` or `auto`) and `name_revision` (a decimal string) on every workspace (`Workspace.name_source`/`Workspace.name_revision` in the raw tree, `extra.name_source`/`extra.name_revision` in resource snapshots). A workspace the daemon names itself (no requested name) starts `auto`; a requested name, any rename without `source` and every name stored by an older daemon are `user`. An automatic rename never replaces a non-empty user name, never empties a name, and fails when the name revision moved since the caller read it; every rename advances the revision. `frontend-browser-tabs-v1` advertises `new-frontend-browser-tab`, `update-frontend-browser-tab`, and the frontend browser tab fields. `tab-metadata-v1` advertises `set-tab-pinned`, pinned-first tab order, the `Tab.pinned`, `Tab.cwd`, `Tab.git_branch`, and `Tab.git_detached` fields, and the `tab-changed` delta. `workspace-metadata-v1` advertises `set-workspace-metadata`, the `Workspace.color`, `Workspace.icon`, and `Workspace.title` fields, and the `workspace-changed` delta. `workspace-pin-v1` advertises the `pinned` field on `set-workspace-metadata` and `Workspace.pinned`. `notification-mark-unread-v1` advertises the `marked_unread` field on `set-workspace-metadata` and `Workspace.marked_unread`. `workspace-groups-v1` advertises durable sidebar groups: the `*-workspace-group` commands, `move-workspace-to-group`, `Tree.groups`, and `Workspace.group`. `loopback-forward-v1` advertises multiplexed TCP streams to the daemon machine's own loopback services (see "Loopback forwarding"); a Unix client echoes it in `set-client-info` before its first `loopback-open`. `fs-v1` advertises the `fs.*` file ops and their byte streams (see "File system (fs-v1)"); only cmux Cloud hosts serve it. `session-identity-v1` advertises `identify.session_id` (the durable `registry_id`, stable across restarts and upgrades) and `identify.machine_name` (the host name, at most 255 bytes, no control characters). `remote-terminal-tabs-v1` advertises `new-remote-terminal-tab`, `update-remote-terminal-tab`, `remote-terminal-snapshot`, and the `kind:"remote-terminal"` tab with its `remote` object. `detached-terminals-v1` advertises `detached` on `create-terminal` and `terminal_resource_id` in its detached result. `profiles-v1` advertises the home session's personal state: `list-personal`, the `*-profile` room commands, `set-profile-follows`, `pin-workspace`, `unpin-workspace`, `put-session`, `forget-session`, `import-session-organization`, the `*-personal-group` commands, `set-personal-workspace`, and the `personal-changed` event. `personal-terminals-v1` advertises `set-personal-terminal` and `list-personal.terminals`. `screen-metadata-v1` advertises `set-screen-metadata`, `set-screen-pinned`, `move-screen`, the `screen_name`, `color`, `icon`, `pinned`, `index`, `group`, and `cwd` fields on `new-screen` (whose result then also carries `screen`), the `Screen.color`, `Screen.icon`, `Screen.pinned`, and `Screen.group` fields, and the `screen-changed` delta. `screen-groups-v1` advertises Chrome-style screen groups: the `*-screen-group` commands, saved screen groups, and `Workspace.screen_groups`. `browser-profiles-v1` advertises browser profile records in personal state: `browser_profiles` in `list-personal` and `create-browser-profile`, `update-browser-profile`, `move-browser-profile`, and `delete-browser-profile`. `notification-source-v1` advertises `source` on `notify`, the `notification` event, the tab `notification` marker, and `list-notifications` rows (`extra.source` in resource notification snapshots), and daemon-side desktop notifications from terminal output (OSC 9, OSC 777 `notify`, kitty OSC 99) with source `terminal`. `terminal-shell-args-v1` advertises `shell_args` on `new-tab`, `split`, `new-pane`, `new-pane-right`, and `create-terminal`: the terminal runs its `SHELL` from `env` (else the daemon's default shell) with those arguments, so a frontend can apply Ghostty's argv-based shell integration (bash `--posix` with `ENV`, nushell `--execute`). `terminal-frontend-shell-integration-v1` lets a frontend that resolves Ghostty's shell integration itself (from the user's `shell-integration` and `shell-integration-features`, into the terminal's `env` and `shell_args`) echo it in `set-client-info`; the terminals that connection creates with a `SHELL` in `env` then run that shell exactly as given (stored as `argv`), with no host-added integration, on `new-tab`, `split`, `new-pane`, `new-pane-right`, `new-row`, `create-terminal`, and a terminal `respawn`; without a `SHELL` the host integrates as before. `new-workspace`, `new-screen` and the reopen-saved-group commands take no `env` and keep the host integration. `screen-terminal-env-v1` advertises `env`, `terminal_id`, and `shell_args` on `new-screen` (the first terminal takes them as on `new-pane`, including `terminal-frontend-shell-integration-v1`) and `terminal_id` in its result. `launch-snapshot-v1` advertises `launch_snapshot_path` in `identify` and the launch snapshot file described there. `state-resources-v1` advertises the `cmux.protocol/2` state resources (workspace metadata, tab pins and tab groups, personal workspace groups, rooms and saved tab groups, screen metadata, order and screen groups, closed history, ephemeral workspaces, and workspace status, progress and log; see `resource-api-v2.md`), `extra.state` on session snapshots, and `state_upsert`/`state_delete` changes on `session.events`. `window-records-v1` advertises `window_record.list`, `window_record.put` and `window_record.delete` (see `resource-api-v2.md`). `sidebar-layout-v1` advertises `sidebar_layout.get`, `sidebar_layout.update` and `extra.state.sidebar_layout` on session snapshots (see `resource-api-v2.md`). `sidebar-doc-v1` advertises the sidebar document: `sidebar.get`, `sidebar.move`, `sidebar.pin`, `sidebar.unpin`, the `sidebar.item.*`, `sidebar.section.*` and `sidebar.group.*` mutations, `sidebar.adopt`, `sidebar.apply`, `extra.state.sidebar` on session snapshots, and `state_upsert`/`state_delete` changes of resources `sidebar_item`, `sidebar_section` and `sidebar_doc` on `session.events` (see `resource-api-v2.md`). `placement-shift-v1` advertises the placement shift: a client that echoes it in `set-client-info` or `client.metadata.update` gets no `workspace_placement` restatement on `session.events` for rows that a new or moved workspace only shifts; every other connection still gets them (see "Placement shift" in `resource-api-v2.md`). `project-list-v1` advertises the project list: `project.list`, `project.observe`, `project.add`, `project.update`, `project.remove` and `project.sync`, and `state_upsert`/`state_delete` changes of resource `project` on `session.events` (see `resource-api-v2.md` and plans/cmux-next/projects.md). `project-sources-v1` advertises `project.source.update` (a source turned off or on) and `sources` (each source with its on state and project count) in the `project.list` result. `browser-devices-v1` advertises `browser.devices.list`, `browser.devices.add_custom`, `browser.devices.remove_custom`, `browser.tab.emulate` and `browser.tab.emulate.clear`, and a browser tab's `extra.emulation` (the resolved device emulation every engine applies; see `resource-api-v2.md`). `browser-fit-v1` advertises `fit` on `browser.tab.emulate` (a desktop layout of aspect W:H, such as 16:9, scaled to the tab's view width with the full view height) and the `mode: "fit"` form of `extra.emulation` (see `resource-operations-v2.json`). `browser-fit-width-v1` advertises a fixed layout width as `fit` (a bare number of CSS px, such as 1280) and `fit.value` in that record. `browser-profile-agent-v1` advertises `browser.tab.set_profile` (moves a frontend browser tab to another browser profile in place, as `update-frontend-browser-tab {profile_id}` does; `frontend-browser-tab-profile-v1`) and a frontend browser tab's `extra.browser_profile_id` (see `resource-api-v2.md`). `palette-usage-v1` advertises `palette_usage.get`, `palette_usage.record`, `palette_usage.import`, `palette_usage.hide` and `palette_usage.forget`, the user's local palette usage history (see `resource-api-v2.md`). `stash-v1` advertises `stash.create`, `stash.list`, `stash.restore`, `stash.delete` and `stash.import`, the user's stashed web pages (a native OneTab; see `resource-api-v2.md`). `stash-workspaces-v1` advertises `workspaces` and `name` on `stash.create`: whole workspaces, terminals included, close into one stash of `kind: "workspace"` members, and `stash.restore` reopens each as its own workspace (see `resource-api-v2.md`). `frontend-browser-owner-v1` advertises `owner` on `new-frontend-browser-tab` and `update-frontend-browser-tab`, `Tab.browser_owner`, `tab.update {owner}` and the tab's `extra.owner`. `frontend-browser-tab-keys-v1` advertises `idempotency_key` on `new-frontend-browser-tab` and `replayed` in its result: a retry with the same key returns the tab the first request created. The raw screen commands of `screen-metadata-v1` and `screen-groups-v1` and the v2 `screen.*` and `screen_group.*` operations read and write one storage and publish the same changes. `workspace-kind-v1` advertises `workspace.ensure_home` and `extra.kind` on workspace snapshots (see `resource-api-v2.md`). `workspace-agent-folder-v1` advertises `workspace.agent_folder.set` and `extra.agent_folder` on workspace snapshots (see `resource-api-v2.md`). `personal-mixed-order-v1` advertises one personal order for groups and loose workspaces: `top_index` on `workspace_group.update`, on `WorkspaceGroupSnapshot` and on `list-personal` groups, `workspace.list {order}`, and the personal row of a new workspace in its creation commit (see `resource-api-v2.md`). `workspace-group-icon-v1` advertises a personal workspace group's icon: `icon` on `workspace_group.update`, on `WorkspaceGroupSnapshot` and on `list-personal` groups (see `resource-api-v2.md`). `screen-group-icon-v1` advertises a screen group's icon: `icon` on `update-screen-group`, on screen group runs (`Workspace.screen_groups`), on saved screen groups (`list-saved-screen-groups`, kept by `reopen-saved-screen-group`), on `screen_group.update` and on `ScreenGroupSnapshot` (see `resource-api-v2.md`). `tab-group-icon-v1` advertises a tab group's icon: `icon` on `update-tab-group`, on tab group runs (`Pane.tab_groups`), on saved tab groups (`list-saved-tab-groups`, kept by `reopen-saved-tab-group`), on `tab_group.update`, on `TabGroupSnapshot` and on `SavedTabGroupSnapshot` (see `resource-api-v2.md`). `workspace-group-pin-v1` advertises pinned (saved) personal workspace groups: `pinned` on `workspace_group.update`, on `WorkspaceGroupSnapshot` and on `list-personal` groups (see `resource-api-v2.md`). `chief-inspect-v1` advertises `chief-inspect`, the Chief memory inspector's read-only API for the owner's trusted connection. `conversation-tabs-v1` advertises `new-conversation-tab`, the canonical `conversation` tab kind, and `capabilities` on `client.metadata.update`; a client that echoes it in `set-client-info` or `client.metadata.update` reads conversation tabs in their canonical form. `agent-session-tabs-v1` advertises the `agent_session` source of `new-conversation-tab` (an acpmux agent session on the install `host`; its tabs are ordinary store tabs that move, split and close like any tab) and `bind-conversation-tab-session`; a client that echoes it as well reads agent session tabs in their canonical form, and any other connection reads them as `browser` tabs without `conversation`. `page-tabs-v1` advertises the `page` source of `new-conversation-tab` (one of the app's own pages, such as the App Store or Settings; its tabs are ordinary store tabs); a client that echoes it as well reads page tabs in their canonical form, and any other connection reads them as `browser` tabs without `conversation`. `page-tab-route-v1` advertises the optional `route` of a page tab on `new-conversation-tab` and in its `conversation` record. `close-reason-v1` advertises `reason` on `close-tabs` and, with `end_terminals`, on `close-workspace`: `session_end` closes without a closed-history record. `conversation-tab-transaction-v1` advertises `transaction` on `new-conversation-tab`: the created tab's `tab-added` delta and the result echo it. `conversation-tab-split-v1` advertises `split` on `new-conversation-tab`: the tab is created in a new pane split from `pane`, in one `pane-added` delta. `browser-host-provider-v1` advertises `browser-host-provider`: the verified local app gets the provider credentials of the daemon's own browser host. `frontend-browser-activate-v1` advertises `activate` on `new-frontend-browser-tab`. `frontend-browser-insert-after-v1` advertises `after` on `new-frontend-browser-tab`. `bookmarks-v1` advertises one bookmark tree per browser profile: `list-bookmarks`, `create-bookmark`, `update-bookmark`, `move-bookmark`, `delete-bookmark`, `import-bookmarks`, the `bookmarks-changed` event, and `deleted_bookmarks` in the `delete-browser-profile` result. `bookmark-icon-v1` advertises a bookmark folder's `icon`: set or cleared by `update-bookmark` and shown in `list-bookmarks` (see "Icon values" under `put-blob`). `session-icon-v1` advertises a session's (machine's) `icon` in the home session registry: set or cleared by `set-session-icon`, kept by `put-session`, and shown on each `list-personal` session record. `icon-assets-v1` advertises the asset blob store (`put-blob`, `get-blob`) and the asset icon values `image:sha256-<hex>` and `svg:sha256-<hex>` on the workspace, screen, room, browser profile and workspace status icon fields (see "Icon values" under `put-blob`). `origin-claim-v1` advertises `client-hello` step 1, the optional `origin` claim on `cmux.protocol/2` requests, and `origin.confirmation.issue` (see "client-hello" and `resource-api-v2.md`, "Request origin") `page-router-v1` advertises the daemon page router (`page-router.md`): the optional `page` on a page relay's `client-hello` (the reply carries that page's `page_operations`), the page of a WebSocket connection whose handshake Origin is `cmux-page://cmux.<page>`, the per-page allow list of `cmux.protocol/2` operations in `page-router.json`, and the routed v2 namespaces (`apps.catalog.list`, `apps.catalog.get`, `apps.installed.list`, `apps.grants.get`, `apps.logs`, `apps.asset.get`, `apps.set`, `apps.install`, `apps.uninstall`, `apps.hidden.set`, `apps.grant.set`, `apps.grant.revoke`) answered by their owner outside the operation catalog. `ws-listen-origins-v1` advertises `allow_origins` on `ws-listen` and `origins` in its reply. `page-events-v1` advertises `page_events` in a page relay's `client-hello` reply (the `events` of its page in `page-router.json`) and `subscribe` on a page relay whose page names events: the stream carries only those events (no `surface` output stream, no pairing requests). `terminal-clipboard-read-v1` advertises the OSC 52 clipboard-read broker: `terminal-clipboard-subscribe`, `terminal-clipboard-reply`, and the targeted `terminal-clipboard-read` and `terminal-clipboard-read-cancelled` control events (see "Terminal clipboard reads"). `launch-credential-v1` advertises the optional `credential` member of `cmux.protocol/2` requests and `credential.verify`, `credential.mint` and `credential.rotate` (see `resource-api-v2.md`, "Launch credentials"); a client sends a credential only to a daemon that advertises it. `feed-local-owner-v1` advertises the daemon's local feed owner (plans/cmux-next/feed.md section 9.1): every notification is also a local feed item committed in the same transaction, `select-tab`, `select-workspace`, `select-screen`, `focus-pane` and `focus-direction` no longer clear unread (a client acknowledges with `ack-tab-notifications`, which also reads the tab's local items and reports `refused` items), the `feed-local-list`, `feed-local-read`, `feed-local-handoff-begin`, `feed-local-handoff-abort` and `feed-local-handoff-done` commands, and the error codes `feed.moving`, `owner.unreachable` (both retryable), `feed.invalid_state`, `not_found` and `forbidden` (a handoff step from a connection that is not the verified cmux app). `workspace-open-url-v1` advertises `workspace.open_url`: a web link opens on the right side of a workspace (the home workspace when none is named), reusing its browser tab, never in the agent chat dock and without moving the keyboard focus (see `resource-api-v2.md`).
.

`capabilities` is additive build-level feature negotiation within a protocol version. Clients must treat a missing field as an empty list. `daemon-handoff-force-v1` advertises the optional `force` field on `shutdown-daemon`. `browser-provider-v1` advertises the trusted-local, connection-scoped native browser provider lease used by cmux-browser and local automation. `browser-provider-native-hosting-v1` advertises the optional `hosting` field of `register-browser-provider`: a `"native"` provider presents its pages itself, so the daemon never overrides their device metrics and screencasts them only while a frame viewer is attached. `browser-pointer-frame-guard-v1` advertises authoritative `pointer_frame_seq` and `pointer_frame_floor_seq` browser attach/frame state plus the additive `browser-frame-presented`, `browser-mouse-guarded`, and `browser-wheel-guarded` commands. Each admitted bitmap receives a new guard even when its document and dimensions match the previous bitmap. The reported floor through latest range proves route membership only. `browser-frame-presented` advances one exact acknowledged token for that connection, and only that token authorizes a new guarded pointer action. A guarded pointer command implicitly acknowledges its own token. Each connection retains one token, while the bounded browser input queue owns actions admitted before a later presentation. Navigation or geometry changes clear the range and all acknowledgements. An accepted press keeps its original guard for motion across ordinary repaints while document and geometry remain valid; invalidation suppresses further motion but retains its balancing release. A capable client echoes that value in `set-client-info`; browser attach requires the bilateral capability while PTY attach remains available without it. The legacy `browser-mouse` and `browser-wheel` schemas retain their optional guard, but guarded servers reject a missing guard before surface lookup. `viewport-splits-v1` advertises `new-pane-right` and the `Screen.viewport_splits` field. `viewport-column-resize-v1` advertises `set-viewport-pane-width` and `Screen.viewport_base_width`. `pane-browser-kind-v1` advertises `kind` and `url` on `split` and `new-pane-right`: `kind:"browser"` with a non-empty `url` puts a browser tab at that URL in the new pane, through the same `pane.split` commit and restart recovery as a terminal pane; public `pane.split` stays terminal-only. `dock-columns-v1` advertises `set-column-dock` and the optional `Screen.columns[].dock` field for every edge. `layout-delta-v1` advertises the screen layout fields, `workspace` and `transaction` on the `layout-changed` event (see `events.md`): a frontend patches one screen instead of re-fetching the tree. `edge-docks-v1` advertises the edges `top` and `bottom` on `set-column-dock` and on `dock` in `move-tab-to-column` (the `dock` field itself needs `dock-columns-v1`). `dock-column-role-v1` advertises `role` on `set-column-dock` and on `dock` in `move-tab-to-column`, and `Screen.columns[].dock.role`. `rows-v1` advertises `new-row`, `set-row-heights`, and the optional `Screen.columns[].rows` field. `layout-undo-v1` advertises server-owned structural layout history and `undo-layout`. `view-attachment-lease-v1` returns a connection-owned lease for each attach and enables lease-fenced sizing. `view-attachment-detach-v1` enables targeted stream cleanup. `creation-receipts-v1` enables idempotent destination creation, `creation-attempt-keys-v1` separates a stable correlation from the same-key or new-key execution attempt selected by `session.creation.resolve`, and `creation-selector-fallbacks-v1` adds bounded ordered destination continuations. `provider-managed-workspace-authority-v2` advertises pre-provisioned provider ownership and authority-gated post-provider rename and close commits. `terminal-idle-close-v1` advertises `set-terminal-idle-policy` and the owner-side reaper that closes a terminal after its policy elapses with no attached view. `resume-command` advertises `terminal-resume-command`: a person's resume command for one terminal, typed on the new prompt when the owner respawns it. `terminal-pending-sequence-v1` advertises the separate `pending` field on byte-attach `vt-state` and `resized` events; a client that echoes it in `set-client-info` receives it (see `events.md`). `terminal-placement-env-v1` advertises a caller-chosen `terminal_id` on `new-tab`, `split`, `new-pane`, and `new-pane-right`, `cwd` and `env` on `new-pane` and `new-pane-right`, and `terminal_id`/`terminal_incarnation` in all four results. `split-client-keys-v1` advertises the client-minted `pane_id` and `tab_id` on `split`, `new-pane`, and `new-pane-right`, keyed retries that return the first result with `replayed`, and `pane_id`/`tab_id` in their results (see "Client-minted pane ids"). `row-client-keys-v1` advertises the same client-minted `pane_id` and `tab_id` on `new-row`, and `pane_id`/`tab_id` in its result. `split-client-split-id-v1` advertises the client-minted `split_id` on `split` and on the `split` of `new-conversation-tab`, and `split_id` (the split's public id) on every split node of a layout (see "Client-minted split ids"). `terminal-resources-v1` advertises `terminal-resources`, which reads the CPU time and memory of each terminal's shell, descendants, and terminal host at request time. `batch-close-v1` advertises `close-tabs` and the optional `end_terminals` field on `close-pane`, `close-screen`, `close-workspace`, and `close-tab-group`: many placements and the terminals they end close in one durable commit. `close-workspace-if-empty-v1` advertises the optional `if_empty` field on `close-workspace`: the close commits only when the workspace has no tab at commit time, else it fails with `workspace_not_empty` and changes nothing. `end-terminals-keep-layout-v1` advertises `keep_layout` on `shutdown-daemon`: with `end_terminals`, placed terminals keep their tabs across the handoff. `tab-restart-kept-layout-v1` (Unix owners, with `tab-restart-v1`) advertises that `restart-tab` of a tab kept by `keep_layout` starts the new shell in the directory the keep recorded and ends the keep once the new shell is in the tab: the tab's `relaunch` is null again, its shell's exit closes it, and a host loss respawns it. `tab-park-v1` (Unix owners) advertises `park-tabs`, which ends the shells of terminal tabs and keeps the tabs as `keep_layout` does, each with `relaunch.on_show: true` so a frontend restarts it when its workspace is first shown. `terminal-reap-v1` advertises the owner-side reaper that ends a terminal after it has had no tab placement for the reap grace period (active only when the daemon was started with `--terminal-reap-grace-seconds`), `set-terminal-keep`, the `keep` field on `new-tab`, `split`, and `create-terminal`, the `terminal-reaped` event, and `end_terminals` on `shutdown-daemon`. `terminal-env-v1` advertises the per-terminal `env` object on `new-tab`, `split`, and `create-terminal`, and `cwd` on `split`. `tab-groups-v1` advertises tab groups: the `*-tab-group` commands, `Pane.tab_groups`, and `Tab.group`. `saved-tab-groups-v1` advertises saved groups: `save-tab-group`, `unsave-tab-group`, `delete-saved-tab-group`, `list-saved-tab-groups`, and `reopen-saved-tab-group`. `notification-ack-v1` advertises `ack-tab-notifications`, `list-notifications`, durable notification acknowledgement, and `Workspace.unread_count`. `tab-drag-v1` advertises the single-command tab drag outcomes `move-tab-to-split`, `move-tab-to-column`, and `move-tab-to-new-workspace`, layout undo for same-screen tab drags and cross-pane `move-tab`, and the optional `transaction` field on every drag command, echoed in the resulting `tab-changed` delta. `tab-workspace-name-v1` advertises the optional `name` field on `move-tab-to-new-workspace`: the new workspace takes that name in the same commit. `workspace-name-source-v1` advertises workspace name provenance: `source`, `expected_generation` and `expected_name_revision` on `rename-workspace` and `workspace.rename`, and `name_source` (`user` or `auto`) and `name_revision` (a decimal string) on every workspace (`Workspace.name_source`/`Workspace.name_revision` in the raw tree, `extra.name_source`/`extra.name_revision` in resource snapshots). A workspace the daemon names itself (no requested name) starts `auto`; a requested name, any rename without `source` and every name stored by an older daemon are `user`. An automatic rename never replaces a non-empty user name, never empties a name, and fails when the name revision moved since the caller read it; every rename advances the revision. `tab-split-respawn-v1` advertises `respawn` on `move-tab-to-split`: a pane's only tab dropped on its own pane's edge splits that pane and leaves a fresh tab of the same kind behind. `tab-split-keep-focus-v1` advertises `keep_focus` on `move-tab-to-split` and `move-tab-to-column`: the new pane does not take focus. `tab-column-respawn-v1` advertises `respawn` on `move-tab-to-column`: a pane's only tab moves into the new column and leaves a fresh tab of the same kind in its pane. `frontend-browser-tabs-v1` advertises `new-frontend-browser-tab`, `update-frontend-browser-tab`, and the frontend browser tab fields. `frontend-browser-history-v1` advertises `set-frontend-browser-history` and `get-frontend-browser-history`: an opaque per-tab session history object for frontend-rendered browsers, stored durably outside the tree. `tab-metadata-v1` advertises `set-tab-pinned`, pinned-first tab order, the `Tab.pinned`, `Tab.cwd`, `Tab.git_branch`, and `Tab.git_detached` fields, and the `tab-changed` delta. `workspace-metadata-v1` advertises `set-workspace-metadata`, the `Workspace.color`, `Workspace.icon`, and `Workspace.title` fields, and the `workspace-changed` delta. `workspace-pin-v1` advertises the `pinned` field on `set-workspace-metadata` and `Workspace.pinned`. `notification-mark-unread-v1` advertises the `marked_unread` field on `set-workspace-metadata` and `Workspace.marked_unread`. `workspace-groups-v1` advertises durable sidebar groups: the `*-workspace-group` commands, `move-workspace-to-group`, `Tree.groups`, and `Workspace.group`. `loopback-forward-v1` advertises multiplexed TCP streams to the daemon machine's own loopback services (see "Loopback forwarding"); a Unix client echoes it in `set-client-info` before its first `loopback-open`. `fs-v1` advertises the `fs.*` file ops and their byte streams (see "File system (fs-v1)"); only cmux Cloud hosts serve it. `session-identity-v1` advertises `identify.session_id` (the durable `registry_id`, stable across restarts and upgrades) and `identify.machine_name` (the host name, at most 255 bytes, no control characters). `profiles-v1` advertises the home session's personal state: `list-personal`, the `*-profile` room commands, `set-profile-follows`, `pin-workspace`, `unpin-workspace`, `put-session`, `forget-session`, `import-session-organization`, the `*-personal-group` commands, `set-personal-workspace`, and the `personal-changed` event. `personal-terminals-v1` advertises `set-personal-terminal` and `list-personal.terminals`. `screen-metadata-v1` advertises `set-screen-metadata`, `set-screen-pinned`, `move-screen`, the `screen_name`, `color`, `icon`, `pinned`, `index`, `group`, and `cwd` fields on `new-screen` (whose result then also carries `screen`), the `Screen.color`, `Screen.icon`, `Screen.pinned`, and `Screen.group` fields, and the `screen-changed` delta. `screen-groups-v1` advertises screen groups: the `*-screen-group` commands, saved screen groups, and `Workspace.screen_groups`. `browser-profiles-v1` advertises browser profile records in personal state: `browser_profiles` in `list-personal` and `create-browser-profile`, `update-browser-profile`, `move-browser-profile`, and `delete-browser-profile`. `conversation-search-v1` advertises `conversation-search` on the local conversation owner. `conversation-draft-v1` advertises `conversation-draft`, the v1 command of the `conversation.draft` operation for a bound agent connection. `conversation-draft-events-v1` advertises the `conversation-draft` event on `subscribe` (the `conversation.events` draft item, with its `conversation` and `participant`) for a trusted local connection that echoes the capability in `set-client-info`; other connections never get drafts on `subscribe`. `conversation-threads-v1` advertises `thread_root` on `message.send` and on `Message`, the `invalid_thread_root` reject, and that a `message.send` moves the sender's own read cursor to the new seq when the sender had read everything before it (see `conversation-op`). `conversation-thread-v1` advertises `conversation-thread`, the `threads` root stats on `conversation-snapshot` and `conversation-history` results, and, with `cloud-conversations-v1`, `cloud-conversation-thread`. `conversation-tree-v1` advertises threads that nest without a limit on the local conversation owner (`reply_to` is the parent, `thread_root` the top root; a `message.send` whose `reply_to` parent is in a thread joins that thread, and a named `thread_root` must be the parent's own; see `conversation-op`) and `conversation-link-resolve`, which opens a conversation or message permalink. `home-inbox-v1` advertises `home-inbox`, the Home list rows the caller sees, derived by the owner (kind, display name, unread count, preview, a Chief's live state, the caller's pins and marks, list order). `conversation-inbox-state-v1` advertises the person's own list state of a conversation, kept beside it (a pin with its position and a "marked unread" flag): `conversation-inbox-op`, the caller's `pinned`, `pin_position` and `marked_unread` on `conversation-list` items, the `conversation-inbox-changed` event on `subscribe` (only to connections whose principal is that participant), and with `cloud-conversations-v1` also `cloud-inbox-op`. `conversation-thread-objects-v1` advertises threads as objects: the `thread.update` op (a `title`, a `status` of `open` or `resolved`, and an `owner` participant; any participant may send it, an agent too) on `conversation-op` and through `cloud-conversation-op`, the `thread` object on a root `Message`, and the `status`, `title`, `owner`, `resolved_by` and `resolved_at` fields of `ThreadSummary` (see `conversation-op` and `conversation-thread`). `conversation-runs-v1` advertises agent runs on the local conversation owner: `conversation-run-append` for a bound agent participant, `conversation-runs` and `conversation-run` on trusted local connections (Unix, and authenticated WebSocket connections with `ws-conversations-v1`), and the `conversation-run-changed` event on `subscribe` for a connection that echoes the capability in `set-client-info` (see "conversation-run-append, conversation-runs, conversation-run"). `cloud-conversation-runs-v1` (advertised with `cloud-conversations-v1`) advertises `cloud-conversation-runs`, `cloud-conversation-run` and the `cloud-conversation-run-changed` event (see "cloud-conversation-runs, cloud-conversation-run"). `chief-live-v1` advertises a Chief's live run frames on the local conversation owner: `conversation-live-publish` for the run's bound agent, `conversation-live` (the `run.live` snapshot) on trusted local connections, and the `conversation-live` event on `subscribe` for a connection that echoes the capability in `set-client-info` (see "conversation-live-publish, conversation-live"). `cloud-chief-live-v1` (advertised with `cloud-conversations-v1`) advertises `cloud-conversation-live` and the `cloud-conversation-live` event, a Cloud Chief's live frames of a subscribed conversation passed through unchanged, for a connection that echoes `chief-live-v1`. `cloud-conversation-typing-v1` (advertised with `cloud-conversations-v1`) advertises `cloud-conversation-typing`, the lease participant's typing indicator on a subscribed Cloud conversation, and the `cloud-conversation-typing` event (the owner's `conversation-typing` broadcast of a subscribed conversation) for a connection that echoes the capability in `set-client-info` (see "cloud-conversation-typing"). `cloud-conversation-presence-v1` (advertised with `cloud-conversations-v1`) advertises `cloud-conversation-presence`, a connection's viewing of a subscribed Cloud conversation, and the `cloud-conversation-presence` event (the owner's `conversation-presence` set of a subscribed conversation) for a connection that echoes the capability in `set-client-info` (see "cloud-conversation-presence"). `local-attachments-v1` advertises `attachment` message parts on the local conversation owner and the `conversation-attachment-upload` and `conversation-attachment-read` commands on trusted local connections. `cloud-attachments-v1` (advertised with `cloud-conversations-v1`) advertises `cloud-attachment-upload`, `cloud-attachment-read` and `cloud-attachment-link`: the same steps and results for a cloud conversation's attachments, through the daemon with the person's lease. `cloud-selfhost-v1` (advertised with `cloud-conversations-v1`) advertises `cloud-session-set` with `auth: "tailscale"` (a self-hosted chat server on the tailnet: no token, no Authorization header) and `cloud-selfhost-info` (see "cloud-session-set" and "cloud-selfhost-info"). `ws-attachments-v1` advertises the same two commands and `conversation-attachment-link` on an authenticated WebSocket connection (the clients of `ws-conversations-v1`; never a relayed remote device), and the listener's `GET /attachments/<token>` download links with byte ranges (transports.md). `link-preview-v1` advertises `link_preview` message parts on the local conversation owner (see `conversation-attachment-upload`). `conversation-person-credentials-v1` advertises that `conversation-agent-token` and `conversation-bind` also take a person other than the server's own user (a `user_` id that is not `user_local`; never a `remote_` device): the bound Unix connection then acts as that person (sends, thread replies, reactions, edits, typing) and is a human participant (it may answer questions, its messages reset the agent turn budget and wake a Chief the way an imported message of that person does), but never the owner: it cannot mint credentials, import history or use any command reserved to `user_local`. That person's typing ends when their last bound connection ends or their credential is replaced. `participant-avatars-v1` advertises `participant.avatar.set` and `participant.avatar.get` (one picture per participant, a person or a Chief, in one avatar store; resource-api-v2.md "Participant avatars") and the `participant-avatar-changed` event on `subscribe` for a connection that echoes the capability in `set-client-info`. `chief-profile-adopt-v1` advertises `chief.profile.adopt` (the owner makes an existing agent participant a Chief record under its own id; resource-api-v2.md "Chief registry"). `ws-conversations-v1` advertises the local conversation owner on an authenticated WebSocket connection (the static credential or an approved pairing) as `user_local`, the same as on a Unix connection: `conversation-list`, `conversation-create`, `conversation-snapshot`, `conversation-history`, `conversation-thread`, `conversation-link-resolve` (with `conversation-tree-v1`), `conversation-search`, `conversation-op`, `conversation-typing`, the `conversation.*` operations, and the `conversation-changed`, `conversation-typing` and (with `conversation-draft-events-v1`) `conversation-draft` events on `subscribe`; `conversation-bind`, `conversation-agent-token` and `conversation-import` stay on Unix connections, and the attachment commands come to WebSocket connections only with `ws-attachments-v1` (cmux#13742). `local-conversations-v1` advertises the local conversation owner on trusted local connections: `conversation-list`, `conversation-create`, `conversation-snapshot`, `conversation-history`, `conversation-op`, `conversation-typing`, `conversation-bind`, `conversation-agent-token`, `conversation-import`, and the `conversation-changed` and `conversation-typing` events. `notification-source-v1` advertises `source` on `notify`, the `notification` event, the tab `notification` marker, and `list-notifications` rows (`extra.source` in resource notification snapshots), and daemon-side desktop notifications from terminal output (OSC 9, OSC 777 `notify`, kitty OSC 99) with source `terminal`. `terminal-shell-args-v1` advertises `shell_args` on `new-tab`, `split`, `new-pane`, `new-pane-right`, and `create-terminal`: the terminal runs its `SHELL` from `env` (else the daemon's default shell) with those arguments, so a frontend can apply Ghostty's argv-based shell integration (bash `--posix` with `ENV`, nushell `--execute`). `terminal-frontend-shell-integration-v1` lets a frontend that resolves Ghostty's shell integration itself (from the user's `shell-integration` and `shell-integration-features`, into the terminal's `env` and `shell_args`) echo it in `set-client-info`; the terminals that connection creates with a `SHELL` in `env` then run that shell exactly as given (stored as `argv`), with no host-added integration, on `new-tab`, `split`, `new-pane`, `new-pane-right`, `new-row`, `create-terminal`, and a terminal `respawn`; without a `SHELL` the host integrates as before. `new-workspace` and the reopen-saved-group commands take no `env` and keep the host integration; `new-screen` follows it with `screen-terminal-env-v1`. `screen-terminal-env-v1` advertises `env`, `terminal_id`, and `shell_args` on `new-screen` (the first terminal takes them as on `new-pane`, including `terminal-frontend-shell-integration-v1`) and `terminal_id` in its result. `launch-snapshot-v1` advertises `launch_snapshot_path` in `identify` and the launch snapshot file described there. `close-reason-v1` advertises `reason` on `close-tabs` and, with `end_terminals`, on `close-workspace`: `session_end` closes without a closed-history record. `conversation-tab-transaction-v1` advertises `transaction` on `new-conversation-tab`: the created tab's `tab-added` delta and the result echo it. `conversation-tab-split-v1` advertises `split` on `new-conversation-tab`: the tab is created in a new pane split from `pane`, in one `pane-added` delta. `browser-host-provider-v1` advertises `browser-host-provider`: the verified local app gets the provider credentials of the daemon's own browser host. `frontend-browser-activate-v1` advertises `activate` on `new-frontend-browser-tab`. `history-search-v1` (advertised only when the daemon has a search index) advertises `history-search`. `frontend-browser-insert-after-v1` advertises `after` on `new-frontend-browser-tab`. `bookmarks-v1` advertises one bookmark tree per browser profile: `list-bookmarks`, `create-bookmark`, `update-bookmark`, `move-bookmark`, `delete-bookmark`, `import-bookmarks`, the `bookmarks-changed` event, and `deleted_bookmarks` in the `delete-browser-profile` result. `bookmark-icon-v1` advertises a bookmark folder's `icon`: set or cleared by `update-bookmark` and shown in `list-bookmarks` (see "Icon values" under `put-blob`). `session-icon-v1` advertises a session's (machine's) `icon` in the home session registry: set or cleared by `set-session-icon`, kept by `put-session`, and shown on each `list-personal` session record. `icon-assets-v1` advertises the asset blob store (`put-blob`, `get-blob`) and the asset icon values `image:sha256-<hex>` and `svg:sha256-<hex>` on the workspace, screen, room, browser profile and workspace status icon fields (see "Icon values" under `put-blob`). `ws-listen-v1` (advertised when the binary can open a page listener) advertises `ws-listen`: a running owner opens its loopback page listener and credential file on request. `cloud-conversations-v1` (advertised only when the daemon has a cloud transport) advertises the cloud conversations proxy on trusted local connections: the `cloud-session-*`, `cloud-inbox-*` and `cloud-conversation-*` commands and the `cloud-*` events (plans/cmux-next/home-cloud-proxy.md). `cloud-host-replica-v1` (advertised only when the daemon has a cloud transport) advertises `cloud-host-replica-set`, `cloud-host-replica-clear` and `cloud-host-replica-status`: the host's read replica publisher on the verified cmux app connection (see "cloud-host-replica-set, cloud-host-replica-clear, cloud-host-replica-status"). `cloud-lease-app-only-v1` (advertised with `cloud-conversations-v1`) advertises that only the verified cmux app connection may replace, clear or use a lease the app set and send `cloud-conversation-op` with `origin: "user"`; other connections get `cloud_conversation_rejected` with `reason` `forbidden`. `page-credential-v1` advertises `page-credential`: the verified cmux app gets a credential for its own page. `page-credential-scoped-v1` advertises the optional `page` field of `page-credential`: any trusted local connection gets a single-use credential bound to that page of the page-router table, which admits only a WebSocket handshake whose Origin names that page and never carries the Cloud lease. `ws-cloud-conversations-v1` (advertised with `cloud-conversations-v1`) advertises that a WebSocket connection that authenticated with a pairing-store credential (an approved pairing, or a `page-credential`; never the static or file token, which any same-user process can read) acts as the person with the lease the verified app set: `cloud-session-status` (with `participant`), `cloud-inbox-list`, `cloud-conversation-snapshot`, `cloud-conversation-history`, `cloud-conversation-thread`, `cloud-conversation-op` (also with `origin: "user"`), the `cloud-*-subscribe` and `cloud-*-unsubscribe` commands, and the `cloud-*` events on `subscribe`; it never sets or clears a lease, and without the app's lease it is signed out (`cloud_signed_out`), never using a lease another connection set (cmux#13742). `origin-claim-v1` advertises `client-hello` step 1, the optional `origin` claim on `cmux.protocol/2` requests, and `origin.confirmation.issue` (see "client-hello" and `resource-api-v2.md`, "Request origin"). `terminal-clipboard-read-v1` advertises the OSC 52 clipboard-read broker: `terminal-clipboard-subscribe`, `terminal-clipboard-reply`, and the targeted `terminal-clipboard-read` and `terminal-clipboard-read-cancelled` control events (see "Terminal clipboard reads"). `agent-session-attach-v1` (advertised when the daemon resolved an acpmux socket path) advertises the `agent-session-*` commands and events on trusted local connections (see "Agent session attach"). `agent-session-observe-v1` is advertised alongside it for the read-only `agent-session-observe` endpoint. `agent-session-children-v1` is advertised alongside it for `agent-session-children` (see "agent-session-children"). `agent-session-presence-v1` is advertised alongside it for `agent-session-typing`, `agent-session-view` and the `agent-session-presence` event (see "agent-session-typing, agent-session-view"). `agent-session-settings-v1` is advertised alongside it for `agent-session-set-model`, `agent-session-set-mode` and `agent-session-set-config` (see "agent-session-set-model, agent-session-set-mode, agent-session-set-config"). `agent-session-start-v1` (advertised with `agent-session-attach-v1`) advertises `agent-session-start` (see "agent-session-start"). `agent-session-start-keyed-reason-v1` (advertised with `agent-session-start-v1`) advertises `require_person_key` and `person_instance` on `agent-session-start` and its typed `agent_session.needs_keyed_start` refusal. `agent-update-v1` (advertised with `agent-session-attach-v1`) advertises `agent-update-plan` and `agent-update-apply` on trusted local connections (see "Agent CLI updates"). `agent-update-owner-v1` adds a canonical `expected_machine_id` condition and an opted-in success owner echo to both update verbs. `agent-transfer-v1` (advertised with `agent-session-attach-v1` once the daemon knows its host) advertises the `agent-transfer-*` commands on trusted local connections (see "Agent chat transfer"). `access-request-v1` (advertised on a cmux Cloud host) advertises the `access-request*` commands on trusted local connections (see "Access requests"). `feed-local-owner-v1` advertises the daemon's local feed owner (plans/cmux-next/feed.md section 9.1): every notification is also a local feed item committed in the same transaction, `select-tab`, `select-workspace`, `select-screen`, `focus-pane` and `focus-direction` no longer clear unread (a client acknowledges with `ack-tab-notifications`, which also reads the tab's local items and reports `refused` items), the `feed-local-list`, `feed-local-read`, `feed-local-handoff-begin`, `feed-local-handoff-abort` and `feed-local-handoff-done` commands, and the error codes `feed.moving`, `owner.unreachable` (both retryable), `feed.invalid_state`, `not_found` and `forbidden` (a handoff step from a connection that is not the verified cmux app). `chief-profile-ws-v1` advertises that the person's page (page `home-channels` admitted with a page-bound credential, or an authenticated WebSocket with the daemon's own credential and no page Origin) may call `chief.profile.*`: list, read, and change display_name, role and the avatar; create, delete, instructions, personality and the grant fields need the person's gesture (resource-api-v2.md "Chief registry"). `chief-events-v1` advertises the `chief-changed` event on `subscribe` (a Chief's id and `created`, `updated` or `deleted`, after every committed `chief.profile.*` write) for the person's own connection (`user_local`, the Channels page included) that echoes the capability in `set-client-info`.

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
| `end_terminals` | `boolean` | `false` | Requires `terminal-reap-v1`; ends every terminal and removes its tabs before the handoff |
| `keep_layout` | `boolean` | `false` | Requires `end-terminals-keep-layout-v1` and `end_terminals`; placed terminals keep their tabs |

Result: `object{accepted:true,pid:uint32,generation:string,ended_terminals?:uint64|null}`.

A normal shutdown keeps terminal hosts alive for the next owner. With `end_terminals`, the daemon ends every terminal that has a live runtime in one commit (one projection; the terminal tombstones and the removal of their tabs in one transaction, as `close-tabs` with `end_terminals` does), ends a pending or exited terminal through the `close-terminal` path, waits for their hosts to exit, and reports the count in `ended_terminals`. The batch is one `terminals.end` resource record (not one `terminal.close` record per terminal), and its terminal events carry reason `topology-closed`. Each host's close deadline starts when the host is asked to exit; the call waits while hosts are still being signaled or keep exiting, at most 60 s, and stops waiting after a close deadline with no progress. A host still running after its close deadline (it ignored termination) is killed, and the call succeeds only once every terminal host of the session is provably dead; otherwise it fails and the daemon keeps serving. Test harnesses use it so a run leaves no terminal host or PTY behind. A failure to end a terminal cancels the handoff and the daemon keeps serving.

With `keep_layout` as well, every terminal still ends, but a terminal shown in a tab keeps its tabs. Before any terminal ends, the workspace store records each kept tab with the directory its shell is in and the title its terminal shows (`kept_tabs`, keyed by tab resource id; the session host supplies the directory: the foreground process's, else the OSC 7 or launch directory). A tab in `kept_tabs` is never removed by its terminal's exit, now or at the next owner's startup reconciliation. Each terminal's own exit records its outcome as usual; no layout decision reads it. If the handoff fails, the records of terminals that did not end are removed. The next owner shows the same workspaces, screens, split layout, ratios, panes and tab resource ids; each kept tab is `dead`, has no terminal behind it, and carries `relaunch: {cwd}` in `list-workspaces` (only while its terminal has ended). While a kept tab has no live surface, `list-workspaces` reports the tab resource's name as its `name` and the recorded title as its `title`; a live surface's own name and title win. `rename-surface` on a kept tab without a surface needs no process: it sets the tab resource's name (the recorded title is the terminal's, so a rename leaves it), and the next `list-workspaces` reports it. A frontend starts a new shell there (cmux opens a new tab in the same pane, in `cwd`, and closes the dead one); a closed kept tab's record is inert and pruned on the next write. Terminals without a tab end as with `end_terminals` alone. `keep_layout` without `end_terminals` is refused with `bad request: keep_layout requires end_terminals`.

Until the response is sent the handoff can still fail, so the daemon keeps every connection open. A request that arrives meanwhile, on the requester's own connection (for example a subscriber's snapshot refresh triggered by the ended terminals) or another one, gets an error response (`daemon shutdown is in progress; request was not executed`, or `operation.failed` with reason `daemon_handoff_pending` on the resource protocol) and is not executed. After the successful response, further messages close the connection.

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

### set-terminal-command-history

| Field | Value |
| --- | --- |
| name | `set-terminal-command-history` |
| status | implemented |
| since | protocol 12, capability `terminal-command-history-v1` |

Turns terminal command history on or off for this daemon and sets how long
commands are kept. The switch is off by default and off again after every
daemon start (it is never persisted), so a client that wants history turns it
on after each connect. Trusted local (Unix-classified) connections only.

While on, the daemon tracks OSC 133 shell-integration marks in each terminal's
output (`A` prompt start, `B` input start, `C` command start, `D[;exit]`
command end) and stores one row per finished command in the session's
workspace registry: `{id, terminal_id, command, cwd, exit_code,
started_at_ms, duration_ms}`. `command` is the text of the newest block of
cells Ghostty marks as input (after `B`, until `C`), read at `C`: the
semantics are assigned byte by byte while the output is parsed, so typeahead,
prompt redraws and reflow do not change it. It is trimmed, without control
characters and cut at 1 KiB; null on the alternate screen or when no input
cell is found. `cwd` is the local path of the OSC 7 directory at `C` (null
when it names another host). A `D` without a `C` (an empty Enter) records
nothing; an `A` while a command runs ends it with a null `exit_code`. A
terminal records at most 10 commands a second; one daemon worker stores them
in order from a queue of 256 (more drop with a diagnostic). While off, marks
are dropped and the screen is never read.

Command rows are never session journal records: the journal is append-only,
and a command line can hold a secret that a user must be able to delete.
`cmux_shell` stays a reserved journal producer id (development builds used
it): `session.journal.append` refuses it and it cannot be installed as a
plugin.

`retention_days` (1 to 3650, default 30) is persisted in the registry. A
row expires when `retention_days` have passed since its command started.
Lists hide expired rows at once; one daemon worker deletes them when the
daemon starts, on every store and retention change, and at the oldest row's
expiry time (it waits for that one deadline; no polling). The same worker is
the only writer of command rows: it stores queued commands and runs client
deletes in queue order. After it deletes rows it checkpoints the WAL without
waiting for readers, and tries again a minute later while a reader blocks
it. The registry connection runs with SQLite `secure_delete`, so deleted
rows are zeroed. The switch is one daemon-wide value that any trusted local
client sets (not per client); turning it off keeps the stored rows
(`delete-terminal-commands` removes them).

Params: `{enabled: bool, retention_days?: u32}` (without `retention_days`
the stored value is kept). Result: `{enabled: bool, retention_days: u32}`.

### list-terminal-commands

| Field | Value |
| --- | --- |
| name | `list-terminal-commands` |
| status | implemented |
| since | protocol 12, capability `terminal-command-history-v1` |

Returns stored terminal commands, whether recording is on or off. Expired
rows are never returned (the worker deletes them at their expiry time).
Trusted local connections only.

Params: `{after_id?: decimal string, limit?: 1..1000}` (default limit 1000).
Result: `{commands: [{id, terminal_id, command, cwd, exit_code,
started_at_ms, duration_ms}], truncated, deletions: decimal string,
registry_id, retention_days}`. `commands` holds the newest `limit` unexpired
rows with an id above `after_id`, oldest first; `truncated` is true when
older rows above `after_id` were left out (a reader that appends after its
last id then has a gap and reads again from the start). Ids, times and
`deletions` are decimal strings. Ids are never reused within a registry.
`deletions` counts client deletes that removed rows (expiry does not count:
a reader drops rows older than `retention_days` itself). A reader that saw
another `deletions` or `registry_id` reads again from the start instead of
appending after its last id.

### delete-terminal-commands

| Field | Value |
| --- | --- |
| name | `delete-terminal-commands` |
| status | implemented |
| since | protocol 12, capability `terminal-command-history-v1` |

Deletes stored terminal commands. Trusted local connections only.

Params: exactly one of `{ids: [decimal string]}` (1 to 1000), `{started_since_ms:
decimal string}` (commands that started at or after that time) or
`{all: true}`. Result: `{deleted: u64}`.

The delete runs on the command history worker after every command queued
before it, so a command that finished just before the delete is deleted
too. Rows are zeroed (`secure_delete`); the worker then checkpoints the WAL
(see `set-terminal-command-history`).

### server-stats

| Field | Value |
| --- | --- |
| name | `server-stats` |
| status | implemented |
| since | protocol 12, capability `server-stats-v1` |

Reports where the daemon spends its time so an operator or agent can locate a
bottleneck without sampling the process: registry mutex contention with the
source site that holds it, journal writer batch shape and commit latency, and
control-socket admission. Counters accumulate since daemon start. The command
reads atomics (and, for `hook_queue`, the small hook queue files) and never
touches SQLite or the journal, so it is safe to poll.

Params: `{include?: array<string>|null}`. `include` names optional result
sections: `resource_projection`, `write_path`, `locks` and `hook_queue`;
unknown names are ignored.
An optional section is absent unless requested, because SDK decoders refuse
unknown result fields.

Result:

```text
object{
  schema:uint32,
  uptime_ms:uint64,
  registry_lock:object{
    wait_us:histogram, hold_us:histogram,
    contended_acquisitions:uint64, stalls:uint64,
    holder:object{site:string,held_for_us:uint64}|null,
    last_stall:object{waiter:string,blocker:string|null,waited_us:uint64}|null,
    top_sites:array<object{site:string,acquisitions:uint64,hold_total_us:uint64,hold_max_us:uint64}>
  },
  journal_writer:object{
    batches:uint64, terminal_events:uint64, durable_events:uint64,
    batch_size:histogram, commit_us:histogram, commit_lock_wait_us:histogram,
    receipt_wait_us:histogram, commit_failures:uint64, deadline_expiries:uint64,
    terminal_queued:uint64, durable_queued:uint64,
    phase:"idle"|"waiting_lock"|"committing", phase_for_us:uint64
  }|null,
  connections:object{active:uint64,peak:uint64,limit:uint64,accepted:uint64,refused:uint64},
  resource_projection?:object{
    projections:uint64, full_projections:uint64, scoped_projections:uint64,
    scope_fallbacks:uint64, crosschecks:uint64, crosscheck_mismatches:uint64,
    read_us:histogram, index_us:histogram, diff_us:histogram,
    projected_changes:histogram,
    commits:uint64, commit_us:histogram, commit_prune_us:histogram,
    commit_apply_us:histogram, commit_journal_us:histogram,
    written_changes:histogram, journaled_changes:histogram
  },
  write_path?:object{
    effect_intents:uint64, effect_intent_failures:uint64,
    effect_intent_batches:uint64, request_effect_commits:uint64,
    writer_registry_locks:uint64
  },
  locks?:object{registry:lock_detail, state:lock_detail},
  hook_queue?:object{queued_events:uint64,reset_dropped_events:uint64,undeliverable_events:uint64}
}
histogram = object{count:uint64,mean:uint64,max:uint64,p50:uint64,p90:uint64,p99:uint64}
lock_detail = object{
  wait_us:histogram, hold_us:histogram,
  contended_acquisitions:uint64, stalls:uint64,
  holder:object{site:string,held_for_us:uint64}|null,
  last_stall:object{waiter:string,blocker:string|null,waited_us:uint64}|null,
  sites:uint64,
  by_hold_total:array<lock_site>, by_hold_p99:array<lock_site>
}
lock_site = object{
  site:string, acquisitions:uint64,
  hold_total_us:uint64, hold_max_us:uint64, hold_p99_us:uint64,
  wait_total_us:uint64, wait_max_us:uint64, wait_p99_us:uint64
}
```

`resource_projection` splits the topology projection that every topology
mutation runs under the registry lock: `read_us` reads the stored topology and
terminal records, `index_us` rebuilds the live resource indexes, and `diff_us`
diffs the live tree against the stored topology. `commit_us` is the whole
registry commit of a projected patch (only the commit that follows a
projection counts; it also covers path-specific steps such as the replay
check, the legacy workspace ledger or terminal close completion; for an
effect receipt patch it is the apply inside the transaction, without the
public-fold pruning before it or the fsync after it, which the journal
writer shares across a batch, see `write_path`);
`commit_prune_us`, `commit_apply_us` and `commit_journal_us` are its
unchanged-row pruning, row writes and journal append. `projected_changes`, `written_changes` and `journaled_changes` count
the patch's durable changes, the changes left after pruning, and the public
changes in the journal record. A projection is full (it reads and restates
the whole topology) or scoped (it restates only the workspaces it changed);
`scope_fallbacks` counts scoped projections that found a change outside their
scope and ran full. `crosschecks` counts scoped projections compared with the
full projection (debug builds, or `CMUX_TUI_PROJECTION_CROSSCHECK=1` in the
daemon environment) and `crosscheck_mismatches` the comparisons that differed.

`write_path` says which thread commits registry writes. `effect_intents`
counts registry commits the journal writer applied inside its batch
transaction (one SAVEPOINT each, one shared fsync per batch): effect
receipts, terminal records (reserved, ready, adopting, exited) and
workspace registry revisions. `effect_intent_failures` counts the intents it
rolled back to their savepoint and answered with an error, and
`effect_intent_batches` the batches that carried at least one.
`request_effect_commits` counts those registry commits that ran their own
transaction on a request thread instead: commits whose caller still holds
the registry connection (topology close patches, workspace commits with
borrowed extra rows), and every one while the journal writer is disabled,
stopped, or not yet running. `writer_registry_locks` counts, process-wide,
registry lock, registry connection or mux state lock acquisitions on a
journal writer thread. It is always `0`: a request thread holds the registry
lock (and may hold state) while it waits for its writer receipt, so the
writer never takes either.

`locks` reports the workspace registry lock (`registry`) and the mux state
lock (`state`) by acquiring site, so a convoy names the code that holds it.
`by_hold_total` lists at most twenty sites by total hold time and
`by_hold_p99` at most twenty by 99th percentile hold; `sites` counts every
distinct site seen. A site's `hold_p99_us` and `wait_p99_us` are power-of-two
bucket bounds: at most twice the true value and never above its maximum.
`wait_*` is how long that site waited to acquire the lock. Recording costs
no allocation after a site's first acquisition.

`hook_queue` shows the agent hook queue. The hook helper keeps each
agent's hook events in a queue on disk (`hook-spool/` beside the session
socket) until a daemon answers them; a stopped, restarting or crashed owner
leaves them queued for the next owner. `queued_events` counts the lines in
this session's queues (events not answered yet, and answered ones a sender
has not removed yet). `reset_dropped_events` counts the events that
`cmux session NAME reset-state` dropped with a session's saved state, for
the sessions whose sockets share this directory. `undeliverable_events`
counts events a live daemon took several times in a row and never answered
(it closed on them, or did not reply within its own longest journal wait),
so their senders gave them up and the agent's later events went on. Unlike
the other sections,
it reads these small files. It is present only when the session serves a
socket.

`schema` is `1`. Latency histograms are in microseconds; `batch_size` counts
events. Percentiles are log-linear bucket upper bounds and overestimate by at
most 25%. `site` values are `file:line` of the code that acquired the registry
lock. `contended_acquisitions` counts waits of at least 1 ms and `stalls`
counts waits of at least 100 ms. `journal_writer` is `null` for ephemeral
sessions. `connections.refused` counts sockets dropped at `limit`; for hook
producers each one is a lost event.

Errors: `bad request: ...`.

CLI mapping: `cmux daemon stats [--session <name>] [--socket <path>]`; plain
stdout renders the object as nested `key: value` lines; `--json` prints the
exact result object. Against a server without `server-stats-v1` the CLI exits
1 with `server.stats_unsupported`.

### browser-host-provider

| Field | Value |
| --- | --- |
| name | `browser-host-provider` |
| status | implemented |
| since | protocol 12, capability `browser-host-provider-v1` |

Gives the cmux app what it needs to dial the daemon's browser host as its
engine provider (plans/cmux-next/browser-host.md, step c2). When
`cmux-browser-host` is beside the daemon (or named by `CMUX_BROWSER_HOST_BIN`),
the daemon binds the host's two sockets in a `bh-<digest>` directory beside
its own socket and keeps them; it starts one host for itself (`serve
--supervised`, the sockets passed as fds) on the first agent connect or on
this command, which waits for the start. The host exits after 5 minutes with
no session, no agent connection and no app provider, and the next agent
connect starts a new one; a crashed host restarts with a backoff. The host
stops with the daemon. Each host launch has a new provider secret: 32 random bytes the
daemon writes to the host on an inherited pipe (never argv or environment).
Terminals the daemon creates get the agent socket as
`CMUX_BROWSER_HOST_SOCKET` (the path only, never the secret), and a client
there never starts a host of its own on it.

Only a verified app connection may call it: a connection on the daemon's Unix
socket whose `client-hello` declared role `main` and passed a proof. A
connection without a hello, an unproven `main`, a page relay, a WebSocket
client and a remote client are refused with `error_code:"origin.forbidden"`
before any host starts.

Params: none.

Result:

```text
object{socket:string, secret:string, host_pid:uint32, listener_pid:uint32}
```

`socket` is the host's provider socket (`browser-host-provider.sock`).
`secret` is 64 lowercase hex digits; the app sends it only in the provider
`hello`, and never logs or stores it. `host_pid` is the host process.
`listener_pid` is the process that holds the listening socket: the daemon,
which binds the socket at its start (with the lock file) and passes it only to
its host, or the host when it bound the socket itself. The app sends `hello`
only when the socket's peer pid is `host_pid` or `listener_pid`: the peer pid
is the listen(2) caller on Linux and the last process that used the server end
on macOS. The host sets close-on-exec on the inherited sockets, so no process
it starts holds them. Repeated calls return the same values until the host
restarts.

Errors: `error_code:"origin.forbidden"` (not the verified local app);
`error_code:"engine_unavailable"` (no host binary beside the daemon, or the
host did not start; the message names why).

### client-hello

| Field | Value |
| --- | --- |
| name | `client-hello` |
| status | implemented (steps 1 and 2) |
| since | capability `origin-claim-v1` |

Fixes the role of a local control connection for request origin
(`resource-api-v2.md`, "Request origin"). It is accepted only as the
connection's first line, or as its second line right after exactly one
`identify`; any other line first (a second `identify` included) closes the
hello window. The role is fixed for the life of the connection;
`set-client-info` never sets it. A connection that sends no `client-hello` has
the legacy client role: it is never `page_relay` and never `user`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `role` | `string` | required | `main` (the app's own connection) or `page_relay` (relays a page's requests) |
| `install_id` | `string` | optional | 1-128 characters of `A-Z a-z 0-9 _ -`; with role `main` it asks for a nonce (step 2 proves it) |

Result: `object{connection_id:string, user_origin_allowed:bool, nonce?:string}`.
`connection_id` is the daemon's id for this connection (the
`relay_connection_id` of `origin.confirmation.issue`). `user_origin_allowed`
says whether a request with origin `user` is accepted on this connection now:
true only for role `main` that the daemon has verified as the cmux app (the
app's code signature on a signed build) and that is not bound to an agent.
`nonce` (64 hex digits) comes only for role `main` with an `install_id`; the
very next line must then be step 2, `{cmd:"client-hello", install_id, proof}`
(the install-key proof over the nonce, unsigned DEV builds), with result
`object{verified:true, install_id:string, connection_id:string,
user_origin_allowed:bool}`, or `client_hello.refused` for any wrong or missing
proof. After step 2 the step 2 value of `user_origin_allowed` is the one that
counts. A client sends origin `user` only when the last value is true; when the
daemon refuses origin `user` (`origin.forbidden`, `apps.origin_forbidden`), the
client shows the refusal and never sends the same request again with another
origin. A daemon without this field allows no client to assume `user`.

Errors (`error_code`; none changes state, and each closes the hello window):

| Code | When |
| --- | --- |
| `client_hello.local_only` | the connection is not a local Unix socket connection |
| `client_hello.bad_request` | `error_details {field: "role"}`: role missing or unknown; `{field: "install_id"}`: install_id malformed |
| `client_hello.window_closed` | after any other line, after two `identify` lines, or a second `client-hello` |
| `client_hello.refused` | step 2 with a wrong or missing proof or install id (the connection stays unverified) |

A `page_relay` connection derives origin `page` on every request and may not
`subscribe` (`origin.forbidden`, `error_details {derived: "page"}`).

Example:

```json
{"id":1,"cmd":"client-hello","role":"page_relay"}
{"id":1,"ok":true,"data":{"connection_id":"42","user_origin_allowed":false}}
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
| `user_id` | `string` | default unchanged | Shared sizing identity; asserted by the client and not verified |
| `display_name` | `string` | default unchanged | Shared sizing identity; defaults to `name` |
| `device_kind` | `string` | default unchanged | `mac`, `iphone`, `ipad`, `tui`, `browser`, `linux`, `windows`; anything else is `unknown`; defaults to `kind` |
| `device_name` | `string` | default unchanged | Shared sizing identity |
| `device_id` | `string` | default unchanged | Stable per-install device id; tells two devices of one user apart and extends the priority key |

`set-client-info` labels a connection; it never sets the `client-hello` role
or the request origin. Identity fields are clamped like `name`. A connection that sends
`shared-sizing-v1` in `capabilities` receives `size-state` events on its
subscribe and attach streams and `participant`/`size_state` in terminal
`attach-surface` responses.

`linux` and `windows` are the GPUI desktop app on Linux and Windows. A
connection that also sends `open-device-kinds-v1` (advertised in `identify`)
decodes every `device_kind` and reads a kind it does not know as `unknown`; it
receives `linux`, `windows` and any later kind as they are in every size state
(`size-state`, `attach-surface`, `get-size-state`, `set-size-policy`,
`reattach-view`). Other connections receive those kinds as `unknown`, because
SDKs built before them reject an unknown `device_kind`. `priority_key` keeps
the real kind for every connection.

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

### machine-listening-tcp

| Field | Value |
| --- | --- |
| name | `machine-listening-tcp` |
| status | implemented |
| since | protocol 12 additive extension; capability `machine-listening-tcp-v1` |

Returns the host's listening TCP socket table. The daemon runs a fixed `ss -H -ltnp` command, with fixed `netstat -ltnp` compatibility on Linux when `ss` is absent (`netstat -ltn` on other Unix platforms). On Linux it first attempts those fixed read-only commands with `sudo -n`, using existing guest permissions to identify root-owned services; it falls back to unprivileged commands when that permission is unavailable and never prompts. Process ownership, when visible to the daemon, lets clients distinguish application listeners from infrastructure services on dynamically assigned ports. Missing ownership does not imply that a listener is an infrastructure service. The request accepts no command text. A Cloud client uses this command through its authenticated private cmux-tui link. Routine port discovery does not call the web control plane or the VM provider.

Params: none.

Result:

```text
object{stdout:string}
```

Example:

```json
{"id":8,"cmd":"machine-listening-tcp"}
{"id":8,"ok":true,"data":{"stdout":"LISTEN 0 128 0.0.0.0:3000 0.0.0.0:*\\n"}}
```

### machine-usage

| Field | Value |
| --- | --- |
| name | `machine-usage` |
| status | implemented |
| since | protocol 12 additive extension; capability `machine-usage-v1` |

Returns the machine-level model spend readout hosted by this daemon. Inside a cmux Cloud VM the daemon polls coderouter for the trailing-window totals of the machine's model traffic; anywhere else, or while coderouter has no ready totals, `usage` is null and frontends hide the readout. Servers advertise `machine-usage-v1` in `identify.capabilities`.

Params: none.

Result:

```text
object{
  usage:object{
    vm_id:string,
    period_days:uint32,
    total_tokens:uint64,
    api_equivalent_usd:float64,
    as_of:string|null
  }|null
}
```

Example:

```json
{"id":9,"cmd":"machine-usage"}
{"id":9,"ok":true,"data":{"usage":{"vm_id":"3f1c...","period_days":30,"total_tokens":184220,"api_equivalent_usd":1.23,"as_of":"2026-09-01T00:00:00Z"}}}
```

### subscribe-activity

| Field | Value |
| --- | --- |
| name | `subscribe-activity` |
| status | implemented |
| since | protocol 12 additive extension; capability `vm-activity-v1` |
| profile | local-admin (trusted Unix socket connections only) |

Opens a stream of the daemon's activity facts for the cmux Cloud VM agent, which forwards them in `cloud.vm.status.report` so the idle pause acts on real activity (plans/cmux-next/cloud-automation.md 27). The reply carries the current snapshot; then `activity-changed` events follow each change, at most one per second (leading edge plus one trailing event), never on a timer. Times and counts only: no content and no surface ids. `attached_clients` counts attached connections whose `set-client-info` kind is `tui`, `web`, `mac` or `frontend`; `live_agents` counts agents that are working or blocked; `last_user_input_at_ms` is the newest keyboard, paste or mouse input from an attached client (a one-shot `send` from an unattached connection does not count); `last_agent_action_at_ms` is the newest agent hook commit or agent state report. At most 16 subscribers; closing the connection ends the subscription. Servers advertise `vm-activity-v1` in `identify.capabilities`.

Params: none.

Result:

```text
object{
  activity:object{
    attached_clients:uint32,
    live_agents:uint32,
    last_user_input_at_ms:uint64|null,
    last_agent_action_at_ms:uint64|null
  }
}
```

Example:

```json
{"id":1,"cmd":"subscribe-activity"}
{"id":1,"ok":true,"data":{"activity":{"attached_clients":1,"live_agents":0,"last_user_input_at_ms":1791246114793,"last_agent_action_at_ms":null}}}
{"event":"activity-changed","activity":{"attached_clients":1,"live_agents":1,"last_user_input_at_ms":1791246114793,"last_agent_action_at_ms":1791246120001}}
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
| `hosting` | `"daemon"|"native"|null` | default `"daemon"` | Capability `browser-provider-native-hosting-v1`. Who presents the pages; every client of one live registration must agree |
| `targets` | `array<object{tab_id:string,target_id:string}>` | required | Complete set for this connection; unique stable tab ids; at most 16,384 entries |

`register-browser-provider` and `get-browser-provider` return:

```text
object{
  available:boolean,
  provider_id?:string,
  endpoint?:string,
  authentication?:"none"|"bearer",
  hosting?:"daemon"|"native",
  revision:uint64,
  clients?:uint64,
  targets:array<object{tab_id:string,target_id:string}>
}
```

`hosting` (capability `browser-provider-native-hosting-v1`) says who presents the provider's pages. `"daemon"`, the default and the only behavior of older servers, is the original contract: on attach and on every resize the daemon sends `Emulation.setDeviceMetricsOverride` with its own viewer geometry (device scale factor 1) and runs a `Page.startScreencast` mirror; while frames stall it may send `Target.activateTarget`. `"native"` is for a provider that shows each page in its own native view, such as cmux-browser or an app-hosted Chromium: the daemon never sends a geometry `Emulation.setDeviceMetricsOverride`, so the page keeps its native viewport (`window.innerWidth` and `innerHeight` follow the native view), never sends `Target.activateTarget` to recover a stalled frame stream, and runs a screencast only while at least one frame viewer (an `attach-surface` or resource browser attach) is attached; the last viewer to detach stops it. A viewer's resize changes only the screencast frame size. Explicit device emulation (`browser-devices-v1`, `extra.emulation`) is applied by the hosting frontend and is not affected. An older server ignores the field and keeps the daemon contract, so a provider checks `identify.capabilities` to know which contract it got. The result echoes `hosting` only on servers with the capability. When unavailable, provider-specific fields are omitted and `targets` is empty. `unregister-browser-provider` returns `object{removed:boolean}` and affects only the calling connection. Endpoints and targets are disclosed only through this trusted-local command; WebSocket control clients are rejected. Bearer tokens are accepted only during registration and are never returned. Bearer mode adds `Authorization: Bearer <token>` to the CDP WebSocket upgrade and is intended for a configurable loopback gateway. The default native endpoint uses an ephemeral loopback port and no bearer.

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

Maps legacy participation controls onto terminal shared sizing (see
[Sizing](#sizing)), or changes legacy browser size participation. The
`surface` field is always required. For a terminal, `exclusive:true` requires
`enabled:true`; omitting `client` selects the requesting connection. The
selected client must have reported a size for that exact view. `enabled:true`
clears a `counts:false` override and counts as activity; `enabled:false` sets
`counts:false`; omitting both `client` and `exclusive` restores automatic
counting for every view. Prefer `set-size-counts` and `set-size-policy`.

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

Ends a control connection. Every attached surface receives its `detached` event with `reason:"disconnected-by"` and `by` when the target transport is still writable, then the socket closes. The kicked viewer must not reconnect automatically. Detaching the requesting client is allowed; the server writes that command's success response before its `detached` events and transport close.

`client` may also be a shared-sizing participant id from `size-state`. A
relay sub-view id (`c<client>/<view>`) detaches only that sub-view: the relay
stays connected and receives `detached {surface, reason:"disconnected-by", by,
view}` on its attach stream for that surface to forward to the leaf. The own
view of a client that sent `sizing-view-detach-v1` in `set-client-info`
detaches only that view: the client stays connected with its attachments and
relay sub-views, its view stops counting toward the grid, and it receives
`detached {surface, reason:"disconnected-by", by, scope:"view"}`.
`reattach-view` restores it. Participant ids are per terminal, so `surface`
resolves `client` on that terminal only.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `client` | `uint64` or `string` | required | Client id from `list-clients`, or a participant id |
| `by` | `object{user_id?,display_name?,device_name?}` | default: the requester's identity | Actor shown to the detached viewer; asserted, not verified |
| `surface` | `Id` | optional | Resolves a participant id on this terminal only |

Result: `object{}`.

Errors:

| Error | Condition |
| --- | --- |
| `unknown client <id>` | Client id is not currently connected |
| `unknown participant <id>` | Participant id names no current view |
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

Requests the server owner and attached TUI frontends to re-read the cmux-tui config from the same source as startup config loading (`CMUX_TUI_CONFIG`, then legacy `CMUX_MUX_CONFIG`, then `cmux-tui.json` with legacy `mux.json` fallback). Interactive owners redraw; headless owners apply server-owned settings without a TUI frame.

Params: none.

Result:

```text
object{reloaded:true,path:string|null}
```

Live reapply: theme/colors, tab display settings, sidebar width settings, scrollbar placement, and keybindings apply on the next TUI frame. Browser config updates server launch options for future browser surfaces; existing browser runtimes and already-open browser surfaces may require restart for browser endpoint/profile/binary changes.

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
| `terminal_id` field | `terminal-input-while-creating-v1` additive extension |
| `expect_foreground` field | `send-expect-foreground-v1` additive extension |
| `expect_agent`, `submit` fields | `send-expect-agent-v1` additive extension |

Writes input to a PTY surface. `text`, when present, is UTF-8 encoded and written as bytes. `bytes`, when present, is standard base64 decoded and written as raw bytes. If both are present, v5 writes `text` first and `bytes` second. If neither is present, v5 returns success and writes nothing.

Protocol v7 adds `paste`. The payload is the concatenation of encoded `text` followed by decoded `bytes`. With `paste:true` and a non-empty payload, the server checks the target terminal's current DEC private mode 2004 while holding the terminal/input lock. If enabled, it writes `ESC [ 200 ~`, the payload, then `ESC [ 201 ~`; if disabled, it writes the payload unchanged. `paste:false` is the exact v5/v6 path. The server does not inspect or remove caller-supplied bracketed-paste markers.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required unless `terminal_id` | Must identify a live PTY surface |
| `terminal_id` | `string` | default null | `terminal-input-while-creating-v1`; the host terminal id (32 hex digits) instead of `surface`, also of a terminal still being created |
| `text` | `string` | default null | Written before `bytes` when both are present |
| `bytes` | `Base64` | default null | Decoded with standard base64 |
| `paste` | `boolean` | default false | Protocol 7; conditionally wraps the combined non-empty payload when DEC mode 2004 is enabled |
| `expect_foreground` | `string` | default null | `send-expect-foreground-v1`; needs `surface`; write only while the foreground executable is this one |
| `expect_agent` | `{session: string}` | default null | `send-expect-agent-v1`; needs `surface`; write only while the terminal's agent is `idle` in `session` |
| `submit` | `boolean` | default false | `send-expect-agent-v1`; needs `surface`; Return after the payload, in the same request |

With `send-expect-foreground-v1`, `expect_foreground` names the executable the caller saw in the
foreground (`process-info`'s `foreground_executable`, compared byte for byte). Right before the write the
server reads the surface's foreground process-group leader again; when it is a different executable, or
cannot be read, the request fails with `foreground changed: ...` and writes nothing. A reply typed to an
agent therefore never runs as a shell command after that agent exited. It needs `surface`: with
`terminal_id` the request fails with `bad request`. A server without the capability ignores the field.
The check is best effort: the program can still exit between the read and the write, a window of
microseconds instead of a client round trip.

With `send-expect-agent-v1`, `expect_agent` makes the write wait for nobody: right before it, the
server reads the agent record of the surface's own terminal, and unless its state is `idle` and its
`agent_session_id` equals `expect_agent.session` (required; a surface with no terminal id fails
too), the request fails with `agent not waiting: ...` and writes nothing. `submit:true` writes Return
(`\r`) after the payload in the same request, so no input can land between the text and its submit;
a Return that fails after the text was written says `submit failed after the text was written`. The phone's Feed reply uses
both, with `expect_foreground` and `paste:true`, so a reply typed where the screen is not in view
never answers an approval or question, a running turn or a new agent session.

With `terminal-input-while-creating-v1`, `terminal_id` addresses the terminal by its host id. A
`split`, `new-pane`, `new-pane-right` or `new-tab` that names a caller-minted `terminal_id` makes that id
*creating* when the daemon receives the request, before its host starts. (A request whose id a live
terminal or an earlier creation still in flight already has does not.) Input for a creating id is not
written yet: it is queued in one FIFO per id, in arrival order across connections, and the result is
`{queued:true}`. At most 65536 bytes wait for one id; a request that would take the queue over that fails
with error code `input.overflow` and queues nothing. When the creation committed and its terminal is live,
the queue is written to it in order. Until that write ended, input by `terminal_id` still joins the queue
(`{queued:true}`), and input to the new terminal by any other path (`send {surface}`, `send-key`, the
`terminal.input.*` resource operations, an image paste commit, `clear-history`) waits for it, so queued bytes precede all later input. When the
creation fails, its connection closes first, or it has not ended 10 seconds after the first queued byte,
nothing of the queue is written: each connection that queued bytes gets them back, in order, in one
`terminal-input-unclaimed` control event ([events.md](events.md#terminal-input-unclaimed)) with `reason`
`failed`, `cancelled` or `expired`, so the client can give them to the terminal that has focus. When a write
of the queue fails, the bytes before it were written and the rest come back with `reason` `write-failed`.
After an expiry the creation itself may still commit; until it does, `terminal_id` gets `unknown terminal`.
Authority is the same as for a live `send {surface}`: a local connection may queue input for a creating id;
a remote relay connection may not send in either form (the relay refuses `send` before it is parsed).
After the queue was written, `terminal_id` writes to the live terminal at once. An empty payload writes
nothing but still fails with `unknown terminal` for an id that is neither live nor creating.

Result:

```text
object{queued?:boolean}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` | Surface id does not exist |
| `unknown terminal <id>` | `terminal_id` names no live or creating terminal |
| `input.overflow` (error code) | The request would take the creating terminal's queue over 65536 bytes; nothing was queued |
| `browser surface does not support PTY/VT socket commands` | Surface is a browser |
| base64 decode error | `bytes` is not valid standard base64 |
| IO error string | PTY write fails |
| `bad request: ...` | Not exactly one of `surface` and `terminal_id`, a malformed `terminal_id`, or wrong JSON type |

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
| `shell_args` | `string[]` | default null | With `terminal-shell-args-v1`: arguments for the terminal's shell, its `SHELL` in `env` or else the daemon's default shell; none or empty keeps the bare shell |

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

With `terminal-env-v1`, `new-tab`, `split`, and `create-terminal` accept an
optional `env` object of extra environment variables for the new terminal's
child only (at most 1024 entries and 256 KiB; names nonempty without `=` or
NUL, values without NUL). A frontend passes the user's login-shell
environment this way even to a daemon that started with a minimal launchd
environment. `split` also accepts `cwd`. The environment is applied at spawn
and kept with the creation receipt in the local state directory, like `argv`
and `cwd`; `create-terminal` with `env` always takes the receipted path.

With `terminal-reap-v1`, `new-tab`, `split`, and `create-terminal` accept
`keep` (boolean, default false). `keep:true` marks the new terminal kept, so
the owner does not end it when its last tab closes; see `set-terminal-keep`.

With `terminal-placement-env-v1`, `new-tab`, `split`, `new-pane`, and
`new-pane-right` accept `terminal_id`, a lowercase UUIDv4 in 32 hex digits
that becomes the new terminal's host id. A frontend picks it first and puts it
in `env` (for example `CMUX_SURFACE_ID`), so the child starts with its own id
and no create-then-move step is needed. A malformed id, or one that already
names a terminal, is rejected and nothing is created; with
`split-client-keys-v1` the same `split`, `new-pane` or `new-pane-right`
request again returns its first result instead (see "Client-minted pane ids"). `new-pane` and
`new-pane-right` also accept `cwd`, `env`, and `keep` with the same meaning as
on `new-tab`, and all four reply with `surface`, `terminal_id`, and
`terminal_incarnation`.

#### Client-minted pane ids

With `split-client-keys-v1`, `split`, `new-pane`, and `new-pane-right` accept
`pane_id` and `tab_id`: the public ids the new pane and its tab get, so a
frontend can show the pane before the reply under the ids the daemon will use
(plans/cmux-next/remote-state-ownership.md, S1). The ids are fixed when the
creation is prepared, so a creation resumed after a restart makes the same
pane and tab. A request that names `pane_id` (else `terminal_id`) is keyed by
it: a retry of the same request returns the first result with
`replayed:true` and creates nothing; another request with the same key is
refused with resource error `creation.conflict`. An id that names an existing
or deleted resource is refused with `pane_id_exists: <id>` or
`tab_id_exists: <id>`, and a malformed id with `bad request: ...`, before
anything is created. The results carry the new pane's `pane_id` and its tab's
`tab_id`. With `cols` and `rows`, these commands adopt the spare terminal host
(R81) like `new-tab`, started at that size. Uniqueness is global; a per-client
namespace for the ids is a later step.

#### Client-minted split ids

With `split-client-split-id-v1`, `split` accepts `split_id` (`split_` and 32
lowercase hex digits): the public id of the split it makes. A split node of a
layout carries its split's public id as `split_id`, beside the numeric `split`,
so a frontend that shows the split before the reply keys it by the id the
daemon will use, and the daemon's layout names the split the frontend already
shows (plans/cmux-next/perf-speed-of-light.md, I3). `layout-changed` and
`screen-changed` name every split of their screen; `list-workspaces` and
`layout` carry `split_id` for every split the daemon has named, which is each
split a `split` made and each split of a screen it has sent. The id is fixed when the
creation is prepared; without `split_id` the daemon picks one then. An id that
names an existing or deleted resource is refused with `split_id_exists: <id>`,
and a malformed id with `bad request: ...`, before anything is created. Public
split ids are stable across daemon restarts (the stored layout keeps them);
numeric `split` ids are not. The `split` of `new-conversation-tab`
(`conversation-tab-split-v1`) takes `split_id` the same way.

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

### new-conversation-tab

| Field | Value |
| --- | --- |
| name | `new-conversation-tab` |
| status | implemented |
| since | protocol 12 additive extension; capability `conversation-tabs-v1` (`agent_session`: `agent-session-tabs-v1`; `page`: `page-tabs-v1`; `route`: `page-tab-route-v1`; `split`: `conversation-tab-split-v1`) |

Creates a tab that shows one source, in `pane`, in `workspace` (its active
pane, or a first pane when the workspace is empty, as the home workspace is),
or in the focused pane. The source is either one conversation
(`conversation`, a `conv_` id) of the `local` or `cloud` conversation owner,
or, with `agent-session-tabs-v1`, an acpmux agent session (`agent_session`:
`host` is `install:` and the stable install id of the machine whose acpmux
runs the session, or `chief:` and the 8 lowercase hex digit id of the Chief
home whose own acpmux runs it on the app's machine (a Chief subagent; the app
attaches the tab to that home's acpmux), or `registry:` and this store's
`identify.session_id` (the session daemon's own machine runs it; the chat
starts with `agent-session-start`; see below for `session`), `session` the acpmux session id or absent for a new chat,
`harness` the agent kind (1 to 64 letters, digits or `_`, `.`, `-`, such as `claude`), optional; `host_name` the host machine's display
name, 1 to 255 bytes without control characters, optional), or, with
`page-tabs-v1`, one of the app's own pages (`page`: its id, 1 to 64
lowercase letters, digits or `-`, `_`, `.`; for example `app-store` or
`settings`; the app draws the page; with `page-tab-route-v1` an optional
`route`, 1 to 4096 bytes without control characters, names what the page
shows, such as a viewer's file or folder, and is kept with the tab and in
its closed-history record, so a reopened page shows it again; the store
never interprets it; `route` without `page` is a bad request). Sending more than one source or none
is a bad request. The store records the source with the tab's frontend record in one
commit and never reads conversation or session content. The tab is an
ordinary store tab: move, split, drop, tear-off and reopen keep its source.
A closed page tab's `closed.list` record names its `page`, so Recently Closed
can title it by the page rather than its `about:blank` placeholder.
With `origin` and `mutation_id` (sent together) a retry returns the tab the
first request created with `replayed:true` and its current record; a retry
after a crash creates the tab under the recorded content id; a retry after
the tab closed fails with `error_code:"frontend_browser_key_closed"` and
creates nothing (send a new key for a new tab). With
`conversation-tab-transaction-v1`, an optional `transaction` (1 to 128
printable ASCII characters, as on `close-tabs`) is echoed on the raw
`tab-added` delta of the created tab and in the result, so a client
replaces its provisional tab on whichever arrives first; a keyed replay
echoes it in the result and emits nothing. With
`conversation-tab-split-v1`, an optional `split` (`{direction, pane_id, split_id}`,
only with `pane`) creates the tab in a new pane on the `direction` side of
`pane` (`right`, `down`, `left` or `up`) instead of in `pane`: one
`pane.split` commit, so a client sees one `pane-added` delta whose pane holds
the tab (and carries `transaction`), then the `layout-changed` that places it;
`pane` never lists the tab and no `tab-added` is sent. The optional
`pane_id` is the caller-minted public id of the new pane, as on `split`
(`split-client-keys-v1`), and is refused when it exists or ever existed. A
refused `split` (an agent chat dock takes a new pane only below, by a split toward `down`) creates no tab. The key
names the source and the target (`pane` or `workspace`, and `split`); the same key with
another one fails with `idempotency.conflict`. Concurrent requests with one
key create one tab. The CLI has no verb for it.

A session never leaves its machine: a `registry:` tab created with a
`session` fails with `error_code:"conversation_tab.machine_mismatch"`, and
`bind-conversation-tab-session` refuses every `registry:` tab the same way,
since that machine's `agent-session-start` binds its chats. The one
exception is a chat this daemon itself landed through `agent-transfer-finish`:
a `registry:` tab whose `host` is this store's own and whose `session` is the
session id acpmux's finish answered (never an id a client sent) is created,
so Move to Cloud opens the moved chat on the machine it landed on. The
daemon keeps the 16 most recent landed chats, each for 24 h, in the
owner-only `agent-transfer-landed.json` next to its registry, rewritten
atomically, so a retried open after a daemon restart still works (an
in-memory session keeps them in memory only). The file counts only as a
regular file owned by the daemon's user, opened without following a
symlink, and a record dated more than a minute ahead is ignored. A chat this
daemon begins (or commits) moving away again with `agent-transfer-begin` is
forgotten, so it never opens here again unless it lands here again. The
other exception is a chat an attached tab's session started here, as
`agent-session-children` listed or followed it (the 1024 most recent, in
memory only; see "agent-session-children"). Any other session, another
store's `registry:` host, and every bind stay refused.

Closing the tab deletes its frontend and source records in the close's
commit (closing any frontend browser tab deletes its frontend record and
session history the same way). Reopen Closed restores the tab with the same source from the closed
history record.

On the wire the tab's canonical kind is `conversation`: raw tree tabs carry
`kind:"conversation"` and `conversation`, and resource API tab snapshots
carry `content_kind:"conversation"` and `extra.conversation`. The record is
`{conversation, owner}` for a conversation source and
`{agent_session:{host, session, harness, host_name}}` (all four keys, `null` when
absent) for an agent session source, and `{page}` for a page source. A connection that did not declare
`conversation-tabs-v1` (raw `set-client-info` or `client.metadata.update
{capabilities}`) reads `browser` in both places, in responses and in
`session.events` and `session.journal.subscribe` stream items alike. Every
browser command and browser operation refuses the tab.

Closed agent chat tabs use the same canonical `conversation` kind in
`closed.list` and closed snapshot/event records, with only safe
`agent_session:{session,harness}` metadata. This requires the separate
`closed-conversation-tabs-v1` declaration: older connections, including
clients that understand live conversation tabs, retain `browser` and the
safe metadata. Merged history similarly uses `closed_kind:"conversation_tab"`
only for declared connections, otherwise `browser_tab`. Private host/install
identity stays in the daemon's restore record; reopening still restores the
original conversation source.

Params: `conversation` and `owner`, `agent_session`, or `page` (one source required);
`pane` or `workspace`, `split` (with `pane`), `origin`, `mutation_id`, `cols`, `rows`, `transaction` (optional).

Result: `object{surface, tab_resource_id, content_resource_id, conversation, replayed, transaction?}`

### bind-conversation-tab-session

| Field | Value |
| --- | --- |
| name | `bind-conversation-tab-session` |
| status | implemented |
| since | protocol 12 additive extension; capability `agent-session-tabs-v1` |

Sets the acpmux session of an agent session tab (`surface`) to `session`
when its current session is `expected_session` (JSON null: no session yet),
a compare-and-swap checked and applied in one commit. A new chat binds with
`expected_session: null`; a tab moves to another session by naming the one
it has. When the tab already has `session` the call returns
`replayed:true` and commits nothing, whatever `expected_session` says.
Another current session fails with `conversation_tab.session_conflict:
current session is <id|null>` and changes nothing; a tab without an agent
session source is a bad request. Concurrent binds commit at most one
change. A bind that applies commits a resource revision: `session.events`
upserts the tab with the new `extra.conversation`, and raw clients get
`tab-changed`.

An optional `harness` (as on `new-conversation-tab`) is the agent the session
runs, as its machine's acpmux reports it (`harness` of the session's summary
in the `session/new` or `_acpmux/attach` reply, a profile such as
`providers/deepseek` by its last part, else `family`); it is written in the same
commit as the session, so a tab's brand mark follows the chat it shows. A
bind that names the tab's own session with another `harness` changes the
harness alone and commits (whatever `expected_session` says); with the same
harness, or without one, it is the replay above. A bind without `harness`
keeps the recorded harness. A daemon from before this field ignores it.

Params: `surface`, `session` (1 to 128 letters, digits or `_ . : -`),
`expected_session` (required; a session id or null), `harness` (optional).

Result: `object{surface, conversation, replayed}`

### new-frontend-browser-tab

| Field | Value |
| --- | --- |
| name | `new-frontend-browser-tab` |
| status | implemented |
| since | protocol 12 additive extension; capability `frontend-browser-tabs-v1` |

Creates a browser tab whose page the frontend renders with WebKit or CEF. The
tab is an ordinary `kind:"browser"` placement in the durable tree, so it
restores after a restart and moves like any tab, but the daemon never waits
for, attaches, or drives a CDP target for it and never renders frames.
`attach-surface` on it fails. The frontend reports navigation with
`update-frontend-browser-tab`. Existing CDP browser tabs (`new-browser-tab`)
are unchanged.

The daemon registers the record before the tab commits, under the browser id
the creation uses, so a daemon restart between the two steps never
bootstraps a CDP target for the tab.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `url` | string | required | Nonempty, at most 32 KiB, no control characters |
| `engine` | string | required | `"webkit"` or `"cef"` |
| `pane` | `Id` | default active pane | Destination pane |
| `title` | string | optional | At most 2048 characters |
| `favicon_url` | string | optional | As `url` |
| `profile_id` | string | optional | 1-128 printable ASCII characters; frontend profile (cookies, extensions) |
| `owner` | string | optional | Install id of the hosting app, 1-128 ASCII letters, digits, `-`, `_`, `.`, `:`; capability `frontend-browser-owner-v1` |
| `idempotency_key` | string | optional | 1-128 bytes, not blank, no control characters; capability `frontend-browser-tab-keys-v1` |
| `cols`, `rows` | uint16 | optional, together | Initial size hint |
| `activate` | bool | default `true` | `false`: the tab joins the pane without becoming its active tab (an automation's background tab); capability `frontend-browser-activate-v1` |
| `after` | `Id` | optional | A tab of the destination pane; the new tab goes right after it (a link's tab next to its opener), else at the end. A slot inside a tab group's run moves to the end of that run; capability `frontend-browser-insert-after-v1` |

Result:

```text
object{surface:Id, tab_resource_id:string, content_resource_id:string, replayed:bool}
```

With `activate:false` the pane's `active_tab` and its focus order stay as
they were, and no selection change is announced, so every client that reads
`active_tab` keeps showing the tab it showed. The browser host's `tabs.open`
through the app uses it.

With `after`, the tab takes the slot right after that tab, and the
`tab-added` delta names that index. A background tab put before the active
tab keeps the same tab active: `active_tab` grows by one and a selection
change is announced. The app sends the opener (or the opener's last child)
for links that open in a new tab, as Chrome places them.

With `idempotency_key`, the key commits with the browser record before the
tab commits, and keyed creations run one at a time, so a retry that arrives
while the first request still runs waits for it. A retry with the same key
and the same request returns the tab the first request created with
`replayed:true`; after a crash between the two commits it creates the tab
under the recorded browser id; after that tab was closed it fails with
`error_code:"frontend_browser_key_closed"` and creates nothing (send a new key
for a new tab). A browser id belongs to at most one tab, ever: a closed tab
keeps its id as a tombstone, and the daemon refuses any creation that would
bind a committed browser id to another tab
(`error_code:"frontend_browser_bound"`) before it records a receipt. The same key with a different
request (`url`, `engine`, `pane`, `title`, `favicon_url`, `profile_id`,
`owner`; the size hint and `activate` do not count) fails with an `idempotency.conflict`
error and creates nothing. Without a key every request creates a tab and
`replayed` is false.

### update-frontend-browser-tab

| Field | Value |
| --- | --- |
| name | `update-frontend-browser-tab` |
| status | implemented |
| since | protocol 12 additive extension; capability `frontend-browser-tabs-v1` |

Records the URL, title, favicon, or browser profile a frontend-rendered browser
reports. An absent field is unchanged and `favicon_url:null` or
`profile_id:null` clears the corresponding value. A change persists durably and
emits `title-changed` (when the title changed) and `tab-changed`. Fails for a
tab that is not frontend-rendered.

With capability `frontend-browser-tab-profile-v1`, `profile_id` moves the tab
to another browser profile in place: the surface, tab id and position stay,
the record's `profile_id` changes, and `tab-changed` carries the new
`browser_profile_id`. The hosting app then re-creates the page in that
profile's store (cookies, local and session storage, IndexedDB, cache,
service workers, permissions), which loads the URL again. The profile is named
by its id or exact name and must exist; an unknown or ambiguous one changes
nothing.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Frontend browser tab |
| `url` | string | optional | As in `new-frontend-browser-tab` |
| `title` | string | optional | As in `new-frontend-browser-tab` |
| `favicon_url` | string or null | optional | As `url`; null clears |
| `profile_id` | string or null | optional | As in `new-frontend-browser-tab`; null clears |
| `owner` | string | optional | As in `new-frontend-browser-tab` |

Result:

```text
object{surface:Id, url:string, title:string|null, favicon_url:string|null, profile_id:string|null, owner:string|null, changed:bool}
```

### restart-tab

| Field | Value |
| --- | --- |
| name | `restart-tab` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-restart-v1` (Unix owners) |

Restarts a terminal tab whose shell ended: a host loss the automatic respawn
gave up on (`restart_exhausted`, `restart_failed`) or never covers, a process end the tab kept
(`on_exit` keep), or a tab kept by `shutdown-daemon` `keep_layout`. It runs
the automatic respawn's worker: the same terminal id gets a new shell and a
new incarnation in every tab that shows it, below the previous screen and one
dim marker line; the tab id, placement, name, pin and group stay. An explicit
restart has no backoff and resets the respawn supervisor's attempt count for
the terminal. A tab kept by `keep_layout` (`tab-restart-kept-layout-v1`)
starts in its kept directory (else the terminal's launch directory, else
home) and stops being kept once the new shell is in the tab (`relaunch`
null; an exit closes it as for any terminal tab); a launch that fails first
leaves it kept.
The reply comes when the worker started; the tree shows the tab adopting,
then running, or dead again when the launch failed. Errors (`error_code`):
`tab-not-dead` (the terminal runs, launches or already restarts),
`tab-not-terminal` (the tab shows no daemon terminal) and
`tab-restart-unavailable` (the owner shuts down or cannot start hosts).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` (alias `tab`) | `TabRef` | required | A terminal tab: its numeric id or public `tab_...` id |

Result:

```text
object{surface:Id, terminal:string, previous_incarnation:string, state:"respawning"}
```

### park-tabs

| Field | Value |
| --- | --- |
| name | `park-tabs` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-park-v1` (Unix owners) |

Ends the shells of terminal tabs but keeps the tabs, as `shutdown-daemon`
`keep_layout` keeps them: every tab is recorded as kept before any shell is
asked to exit, and each tab then shows dead with
`relaunch: {cwd, on_show: true}` once its host exited. A frontend starts a
parked tab again with `restart-tab` (`tab-restart-kept-layout-v1`) when its
workspace is first shown. Tabs that are not terminals, or whose terminal
does not run, launch or adopt, are left as they are. Parking a terminal keeps
every tab that shows it, also one the request did not name. A terminal whose
shell could not be asked to exit keeps running and loses its kept record.
`parked` lists the named tabs whose terminal was chosen to park, before any
shell is asked to exit; it can name a tab whose terminal then kept running.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surfaces` (alias `tabs`) | `array<TabRef>` | required | Terminal tabs: numeric ids or public `tab_...` ids |

Result:

```text
object{parked:[Id]}
```

### set-frontend-browser-history

| Field | Value |
| --- | --- |
| name | `set-frontend-browser-history` |
| status | implemented |
| since | protocol 12 additive extension; capability `frontend-browser-history-v1` |

Stores the session history a frontend keeps for a frontend-rendered browser
tab (back/forward entries, scroll) so it can restore them after a relaunch.
The daemon treats the object as opaque: it checks only that it is a JSON
object and that its compact serialization is at most 64 KiB, then replaces
any stored history. `history:null` clears it. The history is not
presentation state: it is not journaled, emits no event, and never appears
in tab JSON, tree snapshots, or deltas. It lives as long as the browser's
frontend record. Fails for a tab that is not frontend-rendered.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Frontend browser tab |
| `history` | object or null | required | At most 64 KiB serialized; null clears |

Result:

```text
object{surface:Id}
```

### get-frontend-browser-history

| Field | Value |
| --- | --- |
| name | `get-frontend-browser-history` |
| status | implemented |
| since | protocol 12 additive extension; capability `frontend-browser-history-v1` |

Reads the session history last stored with `set-frontend-browser-history`.
`history` is null when none is stored. Fails for a tab that is not
frontend-rendered.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Frontend browser tab |

Result:

```text
object{surface:Id, history:object|null}
```

### new-remote-terminal-tab

| Field | Value |
| --- | --- |
| name | `new-remote-terminal-tab` |
| status | implemented |
| since | protocol 12 additive extension; capability `remote-terminal-tabs-v1` |

Creates a tab that references terminal `terminal_id` on another session
`session_id` (plans/cmux-next/data-model.md 1.2). The frontend attaches to
that session itself; this daemon stores only the reference, like a
frontend browser record, and never attaches, spawns, or bootstraps anything
for it. The command takes no idempotency key: a retry after a lost reply
creates a second tab. The tab is an ordinary placement in the durable tree: it restores
after a restart, and `move-tab`, `move-tab-to-workspace`,
`move-tab-to-split`, `move-tab-to-column`, `move-tab-to-new-workspace`,
pins, tab groups, `close-surface`, and `close-tabs` treat it like any tab. Reopen Closed Tab brings
it back as a remote-terminal tab; closing it deletes its stored snapshot.
`attach-surface` on it fails. Closing it tombstones the reference with the
tab. The reference is registered before the tab commits, so a restart
between the two steps never bootstraps a browser for it.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `session_id` | string | required | Lowercase UUID of the other session (`identify.session_id`) |
| `terminal_id` | string | required | That session's terminal host id, 32 lowercase hex digits |
| `session_name` | string | required | 1-255 bytes, no control characters; the name the frontend shows |
| `pane` | `Id` | default active pane | Destination pane |
| `title` | string | optional | At most 2048 characters, no control characters |
| `cols`, `rows` | uint16 | optional, together | Initial size hint |

Result:

```text
object{surface:Id, pane:Id, workspace:Id, tab_resource_id:string, content_resource_id:string}
```

### update-remote-terminal-tab

| Field | Value |
| --- | --- |
| name | `update-remote-terminal-tab` |
| status | implemented |
| since | protocol 12 additive extension; capability `remote-terminal-tabs-v1` |

Records a remote-terminal tab's title, session name, or text snapshot (the
frontend shows the snapshot while the other session is offline). An absent
field is unchanged; `title:null` falls back to `Terminal on <session_name>`
and `snapshot:null` clears the snapshot. A title or session name change
persists durably and emits `tab-changed` (and `title-changed` when the
displayed title changes); a snapshot is
stored durably but emits nothing and is not journaled. `changed` is true when
anything stored changed. Fails for a tab that is not a remote-terminal tab.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Remote-terminal tab |
| `title` | string or null | optional | As in `new-remote-terminal-tab`; null clears |
| `session_name` | string | optional | As in `new-remote-terminal-tab` |
| `snapshot` | string or null | optional | At most 65536 UTF-8 bytes; null clears |

Result:

```text
object{surface:Id, changed:bool}
```

### remote-terminal-snapshot

| Field | Value |
| --- | --- |
| name | `remote-terminal-snapshot` |
| status | implemented |
| since | protocol 12 additive extension; capability `remote-terminal-tabs-v1` |

Reads the text snapshot last stored for a remote-terminal tab. Fails for a
tab that is not a remote-terminal tab.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Remote-terminal tab |

Result:

```text
object{surface:Id, snapshot:string|null}
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
| `workspace` | `Id` | required unless `key` is supplied or `detached` is true | Mutually identifies the target with `key`; forbidden with `detached` |
| `key` | `string` | required unless `workspace` is supplied or `detached` is true | Lowercase canonical workspace UUID; must match `workspace` when both are supplied |
| `argv` | `string[]` | default shell | Mutually exclusive with `command`; must be non-empty when supplied |
| `command` | `string` | default null | Mutually exclusive with `argv`; must be non-empty when supplied |
| `shell_args` | `string[]` | default null | With `terminal-shell-args-v1`: arguments for the terminal's shell, its `SHELL` in `env` or else the daemon's default shell; mutually exclusive with `argv` and `command` |
| `cwd` | `string` | default inherited | PTY child working directory |
| `name` | `string` | default null | New terminal tab name |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |
| `terminal_id` | `string` | default generated | Caller-reserved canonical 32-character terminal UUID; requires mutation identity |
| `origin` | `string` | paired with `mutation_id` | Stable frontend/profile identity reused for retries |
| `mutation_id` | `string` | paired with `origin` | Stable logical creation id reused for retries |
| `expected_generation` | `string` | optional | Compare-and-swap guard for the daemon boot UUID |
| `expected_revision` | `uint64` | optional | Compare-and-swap guard for the resource projection revision |
| `detached` | `boolean` | default false | `detached-terminals-v1`; create a kept terminal with no workspace, pane, screen, or tab |

Result:

```text
object{
  surface:Id|null,terminal_id:string,terminal_incarnation:string|null,
  pane:Id|null,screen:Id|null,workspace:Id|null,key:string,
  lifecycle:"launching"|"adopting"|"running"|"exited"|"tombstoned",
  exit:TerminalExit|null,
  already_exited:bool,terminal_revision:uint64,replayed:bool,
  registry_id:string,generation:string,
  terminal_resource_id?:string
}
```

With `detached:true` (capability `detached-terminals-v1`; a client must not
send it to a server that omits the capability, because an older server
ignores the field and creates a tab) the terminal is created kept, enters
only the terminal catalog, and gets its durable resource-terminal row in the
same receipted mutation. It takes no `workspace` or `key` (supplying either
is an error). The result has null `surface`, `pane`, `screen`, and
`workspace`, `key:"detached"`, and `terminal_resource_id`, the public `term_`
id that `attach-surface {expected_terminal_id}`, resource API v2 terminal
operations, and `terminal.project` select. `cwd` defaults to the platform's
default terminal directory, since there is no pane to inherit from. The same
`origin` and `mutation_id` replay the same terminal. A retry after a failed resource commit replays the
terminal that commit ended: `already_exited:true` and a null
`terminal_resource_id`.

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

With `screen-metadata-v1`, the screen's name is set in the creating commit and its color, icon, pin, position, and group in one screen commit right after it (a `screen-changed` follows the `screen-added`). `cwd` starts the first terminal there.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | default null | Target workspace; unknown ids error |
| `cols` | `uint16` | default null | Paired with `rows`; final value clamped to at least 1 |
| `rows` | `uint16` | default null | Paired with `cols`; final value clamped to at least 1 |
| `cwd` | string | default null | Directory of the first terminal (`screen-metadata-v1`) |
| `screen_name` | string | default null | The screen's name; `name` names a terminal elsewhere |
| `color` | string | default null | Palette token or `#RRGGBB[AA]` |
| `icon` | string | default null | Icon value (see `put-blob`) |
| `pinned` | bool | default null | Pinned screens sort first |
| `index` | uint | default null | Insertion index among the workspace's screens |
| `group` | string | default null | Screen group of the same workspace (`screen-groups-v1`) |
| `env` | object<string,string> | default null | With `screen-terminal-env-v1`: extra environment for the first terminal, as on `new-pane` |
| `terminal_id` | string | default null | With `screen-terminal-env-v1`: caller-chosen terminal host id (UUIDv4 hex), as on `new-pane` |
| `shell_args` | `string[]` | default null | With `screen-terminal-env-v1`: arguments for the first terminal's shell, as on `new-pane` |

Result:

```text
object{surface:Id,screen?:Id,terminal_id?:string}
```

Errors:

| Error | Condition |
| --- | --- |
| `unknown workspace <id>` | Supplied workspace id does not exist |
| `workspace disappeared while creating screen` | Target workspace vanished after validation |
| `bad request: terminal_id must be a 32-character lowercase UUIDv4 hex value` | `terminal_id` is malformed (`screen-terminal-env-v1`) |
| `terminal_id_exists: <id>` | `terminal_id` names an existing terminal |
| invalid `env` error | `env` breaks the per-terminal environment limits, as on `new-pane` |
| `origin.forbidden: a page origin cannot send <fields> on new-screen` (`error_code` `origin.forbidden`) | A page relay connection (derived origin `page`) sent `cwd`, `env` or `shell_args`; nothing is created. The env merge of `new-pane` applies to every other origin: the daemon owns its keys and keeps the `claude` shim first on `PATH` |
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
| `shell_args` | `string[]` | default null | With `terminal-shell-args-v1`: arguments for the terminal's shell, its `SHELL` in `env` or else the daemon's default shell; none or empty keeps the bare shell |
| `pane_id` | `string` | default null | With `split-client-keys-v1`: caller-minted id of the new pane, `pane_` and 32 lowercase hex digits; see "Client-minted pane ids" |
| `tab_id` | `string` | default null | With `split-client-keys-v1`: caller-minted id of the new pane's tab, `tab_` and 32 lowercase hex digits; terminal panes only |

Result:

```text
object{surface:Id, terminal_id?:string, terminal_incarnation?:string, pane_id?:string, tab_id?:string, replayed?:bool}
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
| `side` | `string` | default `"right"` | With `column-left-v1`: `"left"` opens the column immediately left of `pane`'s column (New Column Left), `"right"` after it; `"left"` takes a PTY column only |
| `shell_args` | `string[]` | default null | With `terminal-shell-args-v1`: arguments for the terminal's shell, its `SHELL` in `env` or else the daemon's default shell; none or empty keeps the bare shell |
| `pane_id` | `string` | default null | With `split-client-keys-v1`: caller-minted id of the new pane, `pane_` and 32 lowercase hex digits; see "Client-minted pane ids" |
| `tab_id` | `string` | default null | With `split-client-keys-v1`: caller-minted id of the new pane's tab, `tab_` and 32 lowercase hex digits; terminal panes only |
| `kind` | `string` | default `"pty"` | With `pane-browser-kind-v1`: `"pty"` or `"browser"` |
| `url` | `string` | default null | With `pane-browser-kind-v1`: required and non-empty with `kind:"browser"`, refused otherwise |

Result:

```text
object{surface:Id, terminal_id?:string, terminal_incarnation?:string, pane_id?:string, tab_id?:string, replayed?:bool}
```

Errors:

| Error | Condition |
| --- | --- |
| `pane <id> has no workspace` | Target pane is not in a screen |
| `viewport pane width must be between 0.1 and 1.0` | `width` is outside the supported range |
| `pane creation failed` | PTY creation or child spawn fails; raw runtime details are logged internally only |
| `bad request: side ...` | `side` is not `"left"` or `"right"`, or `"left"` with `kind:"browser"`; nothing is created |
| `bad request: <cmd> kind ...` | Unknown `kind`, `kind:"browser"` without `url`, `url` without `kind:"browser"`, or `cwd`, `env`, `keep`, `terminal_id` or `shell_args` with `kind:"browser"`; nothing is created |
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
| `pane` | `Id` | required | Any pane; a screen without `columns` is one implicit column |
| `width` | `float32` | required | Finite value from 0.1 through 1.0 |
| `transaction` | `uint64` | default null | Samples with the same connection and transaction coalesce into one undo entry |

Result: `{"width": float32}`, the width of the column of `pane` after the commit. A lone column (one column with rows) always fills the screen, so it returns 1.0 whatever `width` was asked for, and its width stays 1.0. In every other layout it returns `width`. A client that shows a resize handle uses this value, not the requested one.

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
{"id":12,"ok":true,"data":{"width":0.5}}
```

### set-column-dock

| Field | Value |
| --- | --- |
| name | `set-column-dock` |
| status | implemented |
| since | protocol 12 additive capability `dock-columns-v1` |

Pins the horizontal viewport column containing `pane` to a viewport edge, or unpins it. Pinning an edge that another column holds unpins that column in the same commit. Pinning a column that holds the other edge moves it. Unpinning a column that is not docked succeeds and changes nothing; so does any request that matches the current flags. Width, column order, the splits and tabs inside the column, and focus are unchanged. A change is a structural layout change: it advances the screen's layout revision, records one `undo-layout` entry, persists, and emits `screen-changed` and then `layout-changed`. See `Screen.columns[].dock`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Must belong to a screen with viewport columns |
| `dock` | boolean | required | `false` unpins |
| `edge` | string | default `"right"` | `"left"` or `"right"`, and `"top"` or `"bottom"` with `edge-docks-v1`; validated even when `dock` is false |
| `mode` | string | default `"docked"` | `"docked"` or `"overlay"`; validated even when `dock` is false |
| `role` | string | default null | `"agent_chat"` with `dock-column-role-v1`; validated even when `dock` is false; a pin without it has no role |
| `transaction` | `uint64` | default null | Changes with the same connection and transaction coalesce into one undo entry |

Result:

```text
object{column:Id,dock:object{edge:"left"|"right",mode:"docked"|"overlay",role?:"agent_chat"}|null,transaction?:uint64}
```

`column` is the column's `Screen.columns[].id` and `dock` its flag after the request. A screen without `columns` is one implicit column: pinning it fails with `dock-column-last-scrolling` (at least one column must scroll) and unpinning succeeds with `column: 0` and no change. `transaction` echoes the request's value and is omitted when the request had none. The `screen-changed` delta of a change carries the same transaction as a decimal string (the delta's `transaction` field is a string).

Errors:

| Error | `error_code` | Condition |
| --- | --- | --- |
| `pane <id> has no viewport column` | `viewport-column-not-found` | Pane is unknown |
| `at least one column must scroll` | `dock-column-last-scrolling` | The change would leave no scrolling column |
| `bad edge ...` / `bad mode ...` / `bad role ...` | `invalid-argument` | `edge`, `mode` or `role` is not one of the listed strings |
| `bad request: ...` | none | Missing fields or wrong JSON type |

CLI mapping: none. The resource CLI has no verb for this command; frontends send it directly.

Example:

```json
{"id":13,"cmd":"set-column-dock","pane":15,"dock":true,"edge":"left","mode":"overlay","transaction":7}
{"id":13,"ok":true,"data":{"column":14,"dock":{"edge":"left","mode":"overlay"},"transaction":7}}
{"id":14,"cmd":"set-column-dock","pane":15,"dock":false}
{"id":14,"ok":true,"data":{"column":14,"dock":null}}
```

### new-row

| Field | Value |
| --- | --- |
| name | `new-row` |
| status | implemented |
| since | protocol 12 additive capability `rows-v1` |

Opens a new row of `height_permille` below the row of `pane`, in that pane's column, holding one new pane with one new terminal. On a screen without `columns` the screen's split tree first becomes the only row (height 1000) of one column. A column without `rows` first gets its one row (height 1000). The new pane is focused. The change records one `undo-layout` entry that closes the new pane, persists, and emits `screen-changed`. See `Screen.columns[].rows`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Live pane |
| `height_permille` | `uint64` | required | 100 to 1000 |
| `cols` | `uint16` | default null | Sizing hint; used only with `rows` |
| `rows` | `uint16` | default null | Sizing hint; used only with `cols` |
| `cwd` | string | default null | Working directory of the new terminal |
| `env` | object<string> | default null | Extra environment for the new terminal's child |
| `keep` | boolean | default false | Mark the new terminal `keep` |
| `terminal_id` | string | default null | Caller-chosen terminal host id, as on `new-pane-right` |
| `shell_args` | array<string> | default null | Arguments for the terminal's shell, as on `new-pane-right` |
| `transaction` | string | default null | 1-128 printable ASCII characters; echoed in the result and in the commit's `screen-changed` delta |
| `pane_id` | string | default null | `row-client-keys-v1`: caller-minted public id of the new pane (`pane_` and 32 hex digits), as on `split`; refused when it exists |
| `tab_id` | string | default null | `row-client-keys-v1`: caller-minted public id of the new pane's tab (`tab_` and 32 hex digits) |

Result:

```text
object{surface:Id,pane:Id,pane_id?:string,tab_id?:string,terminal_id?:string|null,terminal_incarnation?:string|null,transaction?:string}
```

Errors:

| Error | `error_code` | Condition |
| --- | --- | --- |
| `row height <h> must be between 100 and 1000 permille` | `row-height-out-of-range` | `height_permille` is out of range |
| `unknown pane <id>` | none | Pane is unknown |
| `bad request: ...` | none | Missing fields or wrong JSON type |

CLI mapping: none yet.

Example:

```json
{"id":15,"cmd":"new-row","pane":15,"height_permille":500}
{"id":15,"ok":true,"data":{"surface":31,"pane":32,"terminal_id":"...","terminal_incarnation":"..."}}
```

### set-row-heights

| Field | Value |
| --- | --- |
| name | `set-row-heights` |
| status | implemented |
| since | protocol 12 additive capability `rows-v1` |

Sets every row height of one column at once (a divider release, Equalize Rows). `heights` must name exactly the column's rows (`Screen.columns[].rows[].id`), in any order. With `fit`, the heights must sum to 1000. A refused request changes nothing. A request that matches the current heights succeeds and changes nothing. A change is a structural layout change: it advances the screen's layout revision, records one `undo-layout` entry, persists, and emits `screen-changed` and then `layout-changed`. The layout reducer validates the request on the model of the live state before it commits.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `column` | `Id` | required | `Screen.columns[].id` of a column with `rows` |
| `heights` | array<object{row:Id,height:uint64}> | required | Every row of the column exactly once; each height 100 to 1000 |
| `fit` | boolean | default false | Requires a sum of exactly 1000 |
| `transaction` | `uint64` | default null | Changes with the same connection and transaction coalesce into one undo entry, as viewport resizes do |

Result:

```text
object{screen:Id,column:Id,changed:boolean,transaction?:uint64}
```

`transaction` echoes the request's value and is omitted when the request had none. The `screen-changed` delta of a change carries it as a decimal string.

Errors:

| Error | `error_code` | Condition |
| --- | --- | --- |
| `unknown column <id>` | `row-column-missing` | No screen has this column |
| `the heights do not name exactly the rows of column <id>` | `row-set-stale` | The row set differs from the column's rows, or the column has no `rows` |
| `row height <h> must be between 100 and 1000 permille` | `row-height-out-of-range` | A height is out of range |
| `fitted heights sum to <s>, not 1000` | `row-fit-sum` | `fit` with a sum other than 1000 |
| `bad request: ...` | none | Missing fields or wrong JSON type |

CLI mapping: none yet.

Example:

```json
{"id":16,"cmd":"set-row-heights","column":14,"heights":[{"row":40,"height":600},{"row":41,"height":400}],"fit":true}
{"id":16,"ok":true,"data":{"screen":3,"column":14,"changed":true}}
```

### move-column

| Field | Value |
| --- | --- |
| name | `move-column` |
| status | implemented |
| since | protocol 12 additive capability `column-move-v1` |

Moves the whole viewport column holding `pane` one place left or right: it trades places with its neighbor, keeping every pane, split, row, tab and width inside both columns. Focus does not change. A docked column never moves, and a column next to a docked column cannot move across it. A screen stored as one split tree is one implicit column and has no neighbor. A refused request changes nothing. A move is a structural layout change: it advances the screen's layout revision, records one `undo-layout` entry, persists, and emits `screen-changed` and then `layout-changed`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Any pane of the column that moves |
| `direction` | string | required | `left` or `right` |

Result:

```text
object{screen:Id,column:Id,index:uint64,changed:true}
```

`column` is the moved column's id and `index` its place in `Screen.columns` after the move.

Errors:

| Error | `error_code` | Condition |
| --- | --- | --- |
| `unknown pane <id>` | `column-move-missing` | No screen has this pane |
| `no scrolling column on that side` | `column-move-edge` | The column is first or last, its neighbor on that side is docked, or the screen has no viewport columns |
| `a docked column does not move` | `column-move-docked` | The column holding `pane` is docked |
| `direction must be left or right, not "<value>"` | `invalid-argument` | Any other direction |
| `bad request: ...` | none | Missing fields or wrong JSON type |

CLI mapping: none yet.

Example:

```json
{"id":17,"cmd":"move-column","pane":15,"direction":"right"}
{"id":17,"ok":true,"data":{"screen":3,"column":14,"index":2,"changed":true}}
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
| `shell_args` | `string[]` | default null | With `terminal-shell-args-v1`: arguments for the terminal's shell, its `SHELL` in `env` or else the daemon's default shell; none or empty keeps the bare shell |
| `pane_id` | `string` | default null | With `split-client-keys-v1`: caller-minted id of the new pane, `pane_` and 32 lowercase hex digits; see "Client-minted pane ids" |
| `tab_id` | `string` | default null | With `split-client-keys-v1`: caller-minted id of the new pane's tab, `tab_` and 32 lowercase hex digits; terminal panes only |
| `split_id` | `string` | default null | With `split-client-split-id-v1`: caller-minted id of the new split, `split_` and 32 lowercase hex digits; see "Client-minted split ids" |
| `kind` | `string` | default `"pty"` | With `pane-browser-kind-v1`: `"pty"` or `"browser"` |
| `url` | `string` | default null | With `pane-browser-kind-v1`: required and non-empty with `kind:"browser"`, refused otherwise |

Result:

```text
object{surface:Id, terminal_id?:string, terminal_incarnation?:string, pane_id?:string, tab_id?:string, replayed?:bool}
```

Errors:

| Error | Condition |
| --- | --- |
| `bad dir "<value>" (want "right" or "down")` | `dir` is not allowed |
| `pane <id> not found` | Target pane is not in any screen split tree |
| spawn or PTY error string | PTY creation or child spawn fails |
| `bad request: <cmd> kind ...` | Unknown `kind`, `kind:"browser"` without `url`, `url` without `kind:"browser"`, or `cwd`, `env`, `keep`, `terminal_id` or `shell_args` with `kind:"browser"`; nothing is created |
| `split_id_exists: <id>` | `split_id` names an existing or deleted resource; nothing is created |
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
| `split <id> joins two rows; resize rows with set-row-heights` | `rows-v1`: the split is a synthetic split of a column's row chain; layout remains unchanged |
| `bad request: ...` | Missing fields or wrong JSON type |

Missing targets return `error_code:"layout-ratio-target-missing"`. Unsupported viewport widths return `error_code:"layout-ratio-out-of-range"`. A synthetic row split returns `error_code:"row-split-compat-readonly"`.

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

### terminal-ports

| Field | Value |
| --- | --- |
| name | `terminal-ports` |
| status | implemented |
| since | protocol 12 additive extension; capability `terminal-ports-v1` |

Returns the dev-server ports a terminal shows that accept a connect on this
machine's loopback, read when the request arrives (no poller, no cache). The
daemon never scans processes (plans/cmux-next/pty-holder.md section 4): it
reads the PTY it holds (the active screen with its scrollback, the last
1 MiB) for addresses on `localhost`, `127.x.y.z`, `0.0.0.0`, `[::1]`, `[::]`
or `*` with a port, newest mention first, at most 32 ports, and connects to
127.0.0.1, then ::1, for at most 150 ms each. Text a server prints in a tmux
pane reaches the terminal too, because tmux draws its panes into the client's
PTY. A program that prints nothing is not found. Clients use it to offer
"open in browser" (plans/cmux-next/workspace-proxy-DESIGN.md section 6); the
page then reaches the port through `loopback-forward-v1`.

Params: `object{surface:Id}`.

Result:

```text
object{
  surface:Id,
  listeners:array<object{port:uint16,host:string,url:string,bound:string}>,
  closed:array<uint16>
}
```

Example:

```json
{"id":9,"cmd":"terminal-ports","surface":3}
{"id":9,"ok":true,"data":{"surface":3,"listeners":[{"port":5173,"host":"localhost","url":"http://localhost:5173/","bound":"127.0.0.1"}],"closed":[3000]}}
```

Errors: `unknown surface <id>`, `browser surface does not support PTY/VT socket commands`, `bad request: ...`.

### terminal-resources

Requires the `terminal-resources-v1` capability. Clients must not send this command to a server that omits the capability.

| Field | Value |
| --- | --- |
| name | `terminal-resources` |
| status | implemented |
| since | protocol 12 additive extension; capability `terminal-resources-v1` |

Reports the CPU time and memory of each PTY terminal's process tree. The
daemon reads the operating system when the request arrives; it keeps no
background sampler, cache, or timer, so an idle daemon does no work for this
command. A client that shows usage rates sends the command again and divides
the `cpu_ns` difference by the `sampled_at_ns` difference.

For each terminal, `processes` lists the shell (`pid`, the value
`process-info` reports) first, then every descendant in breadth-first order,
each pid exactly once. A tree larger than 512 processes is cut at 512 and
reports `truncated: true`. A process that exits during the walk is left out.
`host` is the `__terminal-host` process that owns the PTY: the shell's parent
when that parent is not the daemon and runs the daemon's own executable. It is
null for a PTY the daemon owns itself.

`cpu_ns` is cumulative user plus system CPU time since the process started.
`memory_bytes` is the physical footprint on macOS (the Activity Monitor
figure) and the resident set size on Linux. `name` is the executable
basename. `sampled_at_ns` is a monotonic clock (macOS `CLOCK_UPTIME_RAW`,
Linux `CLOCK_MONOTONIC`) and is comparable only between replies of one
daemon host. On other platforms each terminal reports empty `processes` and a
null `host`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surfaces` | `array<Id>` | optional; omitted or null means every PTY surface | Duplicates are reported once |

Result:

```text
object{sampled_at_ns:uint64,terminals:array<object{surface:Id,terminal_id:string|null,pid:uint32|null,host:object{pid:uint32,cpu_ns:uint64,memory_bytes:uint64}|null,processes:array<object{pid:uint32,ppid:uint32,name:string,cpu_ns:uint64,memory_bytes:uint64}>,truncated:boolean}>,missing:array<Id>}
```

`terminals` follows the request order, or ascending surface id when
`surfaces` is omitted. `missing` lists requested surfaces that do not exist
or are not PTY surfaces; they do not fail the request. `terminal_id` is the
durable terminal id of a hosted terminal and null otherwise.

Errors: `bad request: ...` for a wrong JSON type.

CLI mapping: none. Frontends send it to show per-terminal CPU and memory.

Example:

```json
{"id":15,"cmd":"terminal-resources","surfaces":[3,99]}
{"id":15,"ok":true,"data":{"sampled_at_ns":81234567890123,"terminals":[{"surface":3,"terminal_id":"01b4f3c085ec451c8563e8a70cf89eb4","pid":4242,"host":{"pid":4240,"cpu_ns":18000000,"memory_bytes":9437184},"processes":[{"pid":4242,"ppid":4240,"name":"zsh","cpu_ns":52000000,"memory_bytes":4194304},{"pid":4250,"ppid":4242,"name":"sleep","cpu_ns":1000000,"memory_bytes":1048576}],"truncated":false}],"missing":[99]}}
```

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

A tab whose terminal ended with `shutdown-daemon` `keep_layout` has no runtime
surface after the restart (`dead: true`); it still closes by its `surface` id.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Must identify a live surface or a placed tab |

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

### close-tabs

Requires the `batch-close-v1` capability. Clients must not send this command to a server that omits the capability.

| Field | Value |
| --- | --- |
| name | `close-tabs` |
| status | implemented |
| since | protocol 12 additive extension; capability `batch-close-v1` |

Closes several tab placements, in any panes and workspaces, in one durable
commit: the tree, the resource stream, and the terminal registry change
once, with one journal fsync, instead of once per tab. Each tab closes as
`close-surface` closes it (panes and screens collapse, canonical workspaces
remain, browsers close). With `end_terminals`, the same commit also ends
every PTY terminal whose views are all in the closed set and that is not
kept (`set-terminal-keep`), as `close-terminal` ends it: its host is
signaled after the commit and exits in parallel with the others. A terminal
still shown in another tab, or kept, keeps running. Every surface is
validated first; an unknown surface fails the whole request and changes
nothing. Duplicates are ignored.

With `close-reason-v1`, `reason: "session_end"` marks the tabs a browser
session opened for itself and closes at its end: the close commits exactly
as without a reason (same transaction, rows, terminals and events) but is
not recorded in the closed history, so Reopen Closed never offers it. Any
other reason is a bad request. The reason is part of the request an
`origin` and `mutation_id` name.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surfaces` | `array<Id \| string>` | required | 1 to 4096 live tabs, by surface id or public `tab_` id |
| `end_terminals` | `bool` | default `false` | End terminals left with no view, unless kept |
| `transaction` | `string` | optional | Client id echoed in the result; 1-128 printable ASCII |
| `reason` | `CloseReason` (string enum) | optional | `session_end` only (`close-reason-v1`): not recorded in the closed history; another value fails to decode (`bad request`) |
| mutation fields | see common envelope | optional | `origin` and `mutation_id` for exactly-once retries; no CAS fields |

Result:

```text
object{closed:array<Id>,terminals:array<object{terminal_id:string,terminal_incarnation:string|null}>,closed_ids?:array<string>,resource_revision:uint64,replayed:bool,transaction?:string}
```

`closed` lists the removed placements in request order. `terminals` lists the
terminals the commit ended. `closed_ids` lists the `closed.list` groups the
commit stored, oldest first (a workspace the close emptied joins its group;
empty with `reason: "session_end"`): `closed.reopen` of each restores exactly
what this close closed, so an Undo never reopens another close of the same
name. It is absent only on a replay of a close committed before the field
existed. A retry with the same `origin` and `mutation_id` returns the original
result with `replayed: true` and changes nothing.

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` / `unknown tab <id>` | A surface is not a live tab placement |
| `close-tabs needs at least one surface` | `surfaces` is empty |
| `close-tabs takes at most 4096 surfaces` | `surfaces` is too long |
| `bad request: ...` | Missing `surfaces`, wrong JSON type, invalid `transaction`, or unknown `reason` |

CLI mapping: none. Frontends send it to close several tabs at once (close
others, close group, close workspace contents).

Example:

```json
{"id":14,"cmd":"close-tabs","surfaces":[1,5],"end_terminals":true}
{"id":14,"ok":true,"data":{"closed":[1,5],"terminals":[{"terminal_id":"01b4f3c085ec451c8563e8a70cf89eb4","terminal_incarnation":"03ec40cf8a1545a381eb1fc03bd36688"}],"resource_revision":9,"replayed":false}}
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
| `end_terminals` | `bool` | default `false` | With `batch-close-v1`: also end, in the same commit, every terminal whose views all close and that is not kept |

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

### set-screen-metadata

| Field | Value |
| --- | --- |
| name | `set-screen-metadata` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-metadata-v1` |

Sets or clears a screen's color and icon. A field sent as JSON null clears it; an absent field keeps its value. The values are durable, keyed by the public screen id. Emits `screen-changed` when anything changed.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `screen` | `Id` | required |  |
| `color` | string or null | absent keeps | Palette token `[a-z][a-z0-9-]{0,31}` or `#RRGGBB[AA]` |
| `icon` | string or null | absent keeps | Icon value (see `put-blob`) |

Result:

```text
object{screen:Id,color:string?,icon:string?,changed:bool}
```

### set-screen-pinned

| Field | Value |
| --- | --- |
| name | `set-screen-pinned` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-metadata-v1` |

Pins or unpins a screen. Pinned screens sort first in their workspace and cannot be grouped (pinning removes the screen from its group). Emits `tree-changed` and `screen-changed`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `screen` | `Id` | required |  |
| `pinned` | bool | required |  |

Result:

```text
object{screen:Id,pinned:bool,index:uint,changed:bool}
```

### move-screen

| Field | Value |
| --- | --- |
| name | `move-screen` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-metadata-v1` |

Moves a screen to `index` in its workspace, into `workspace` at `index`, or with `new_workspace` into a new workspace created in the same commit. The screen keeps its panes, tabs, and terminals (terminals are retargeted to the new workspace). The order is then normalized: pinned screens first, each group contiguous at its first member. A screen that changes workspace leaves its group. A workspace's last screen cannot move out. Emits `tree-changed` and `screen-changed`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `screen` | `Id` | required |  |
| `index` | uint | default null | Insertion index after removal; default the end |
| `workspace` | `Id` | default null | Default: the screen's workspace |
| `new_workspace` | bool | default false |  |

Result:

```text
object{screen:Id,workspace:Id,key:string,index:uint}
```

### create-screen-group

| Field | Value |
| --- | --- |
| name | `create-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Creates a group from screens of one workspace. Members become contiguous at the position of the first; screens leave any group they were in. Pinned screens cannot be grouped. Emits `tree-changed` and a `screen-changed` per member.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `screens` | array of `Id` | required | One workspace, at least one screen |
| `name` | string | default "" | At most 256 characters |
| `color` | string | default `grey` | One of the nine tab group colors or `#RRGGBB` |

Result:

```text
object{group:object{id:string,name:string,color:string,collapsed:bool,saved_id:string?}?,workspace:Id?,key:string?,screens:[Id]}
```

### update-screen-group

| Field | Value |
| --- | --- |
| name | `update-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Renames, recolors, collapses, or sets or clears the icon of a group. Collapse is shared by every client. A linked saved record follows.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `group` | string | required |  |
| `name` | string | default null |  |
| `color` | string | default null | One of the nine tab group colors or `#RRGGBB` |
| `collapsed` | bool | default null |  |
| `icon` | string | absent keeps it | `screen-group-icon-v1`: one emoji, an SF Symbol name, or a stored `image:sha256-<hex>` or `svg:sha256-<hex>` asset; null clears it |

Result:

```text
object{group:object{id:string,name:string,color:string,collapsed:bool,saved_id:string?,icon:string?}?,workspace:Id?,key:string?,screens:[Id]}
```

### add-screens-to-screen-group

| Field | Value |
| --- | --- |
| name | `add-screens-to-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Adds screens of the group's workspace to the group at `index` inside it (default: the end).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `group` | string | required |  |
| `screens` | array of `Id` | required |  |
| `index` | uint | default null | Position inside the group |

Result:

```text
object{group:object{id:string,name:string,color:string,collapsed:bool,saved_id:string?}?,workspace:Id?,key:string?,screens:[Id]}
```

### remove-screens-from-screen-group

| Field | Value |
| --- | --- |
| name | `remove-screens-from-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Removes screens from their groups; each lands right after its former group. A group left without members is deleted.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `screens` | array of `Id` | required |  |

Result:

```text
object{screens:[Id],groups:[string]}
```

### move-screen-group

| Field | Value |
| --- | --- |
| name | `move-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Moves a whole group to `index` in its workspace, into `workspace`, or into a new workspace. Members keep their order and stay grouped.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `group` | string | required |  |
| `index` | uint | default null | Insertion index of the first member after removal |
| `workspace` | `Id` | default null |  |
| `new_workspace` | bool | default false |  |

Result:

```text
object{group:object{id:string,name:string,color:string,collapsed:bool,saved_id:string?}?,workspace:Id?,key:string?,screens:[Id]}
```

### ungroup-screen-group

| Field | Value |
| --- | --- |
| name | `ungroup-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Dissolves a group; its screens stay in place.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `group` | string | required |  |

Result:

```text
object{group:string,screens:[Id]}
```

### close-screen-group

| Field | Value |
| --- | --- |
| name | `close-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Closes every member screen (`end_terminals` also ends their terminals). A linked saved record stays. Refused when it would leave the workspace without a screen.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `group` | string | required |  |
| `end_terminals` | bool | default false |  |

Result:

```text
object{group:string,closed:[Id]}
```

### list-saved-screen-groups

| Field | Value |
| --- | --- |
| name | `list-saved-screen-groups` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Lists saved screen groups in order. `open_group` names the live group linked to a record.

Params: none.

Result:

```text
object{groups:[object{id:string,name:string,color:string,profile_id:string?,members:[object{name:string?,color:string?,icon:string?,cwd:string?}],updated_at_ms:uint,open_group:string?}]}
```

### save-screen-group

| Field | Value |
| --- | --- |
| name | `save-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Saves a group as a session-wide record linked to the live group (members' names, colors, icons, and directories).

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `group` | string | required |  |

Result:

```text
object{group:object{id:string,name:string,color:string,collapsed:bool,saved_id:string?}?,workspace:Id?,key:string?,screens:[Id],saved:string}
```

### unsave-screen-group

| Field | Value |
| --- | --- |
| name | `unsave-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Deletes the saved record linked to a live group.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `group` | string | required |  |

Result:

```text
object{group:object{id:string,name:string,color:string,collapsed:bool,saved_id:string?}?,workspace:Id?,key:string?,screens:[Id]}
```

### delete-saved-screen-group

| Field | Value |
| --- | --- |
| name | `delete-saved-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Deletes a saved screen group and unlinks its live group.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `saved` | string | required |  |

Result:

```text
object{}
```

### reopen-saved-screen-group

| Field | Value |
| --- | --- |
| name | `reopen-saved-screen-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `screen-groups-v1` |

Reopens a saved group into `workspace` (default: the active one): one new screen per member in its saved directory with its name, color, and icon, grouped and linked to the record. An open group is returned as it is.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `saved` | string | required |  |
| `workspace` | `Id` | default null |  |

Result:

```text
object{group:object{id:string,name:string,color:string,collapsed:bool,saved_id:string?}?,workspace:Id?,key:string?,screens:[Id]}
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
| `end_terminals` | `bool` | default `false` | With `batch-close-v1`: also end, in the same commit, every terminal whose views all close and that is not kept |

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
views; only `terminal.close` ends them, or the opt-in reaper (see
`set-terminal-keep`). Single-view browser runtimes close.
Terminal or pane exit alone never invokes this operation. The active
workspace selection is adjusted to keep a remaining workspace active when
possible. The workspace may be selected by stable key or numeric id, and the
common mutation envelope provides revision CAS and exactly-once retries.
The registry revision orders the workspace list only: a tab added to an
existing workspace does not advance it. A client that closes a workspace it
saw empty (for example the source of a move that took its last tab) sends
`if_empty: true`, so a tab another client opened there in the meantime keeps
the workspace open instead of being deleted. The guard is checked in the same
step that commits the close; like the other guards it is not part of the
mutation fingerprint, and a refusal records nothing, so a retry re-checks.
Stable-key selection, revision CAS, and the mutation result require
`workspace-registry-v1`; the legacy numeric-id form remains available without
it. After provider ownership is enabled, this ordinary command fails without
changing workspace state.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | one of id/key | Must identify a live workspace |
| `key` | `string` | one of id/key | Lowercase canonical workspace UUID |
| `end_terminals` | `bool` | default `false` | With `batch-close-v1`: also end, in the same commit, every terminal whose views all close and that is not kept |
| `reason` | `CloseReason` (string enum) | optional | With `end_terminals`: `session_end` only (`close-reason-v1`), not recorded in the closed history (the app closing a workspace whose first tab did not start); without `end_terminals` it is a `bad request` |
| `if_empty` | `bool` | default `false` | With `close-workspace-if-empty-v1`: close only when the workspace has no tab when the close commits; otherwise fail with `workspace_not_empty` and change nothing |
| `report_closed_ids` | `bool` | default `false` | With `end_terminals`: the result names `closed_ids`. Opt-in, so older decoders (which refuse an unknown result field) keep the result shape; a daemon that predates it ignores it |
| mutation fields | see common envelope | optional | Exactly-once retry and CAS |

Result:

```text
object{workspace:Id,key:string,index:usize,workspace_revision:uint64,changed:bool,replayed:bool,registry_id:string,generation:string,closed_ids?:array<string>}
```

With `end_terminals` and `report_closed_ids: true`, `closed_ids` lists the
`closed.list` groups the close stored, oldest first (empty for an ephemeral
workspace or with `reason`), so `closed.reopen` of each restores exactly this
workspace even when another closed workspace has the same name. A replay
names the same ids. It is absent otherwise, and on a replay of a close
committed before the groups were recorded.

Errors:

| Error | Condition |
| --- | --- |
| `unknown workspace <id>` | Workspace id does not exist |
| `unknown workspace key <key>` | Workspace key does not exist |
| `workspace id and key do not identify the same workspace` | Supplied selectors identify different workspaces |
| `workspace revision conflict: ...` | Compare-and-swap guard is stale |
| `workspace_not_empty: ...` (`error_code` `workspace_not_empty`) | `if_empty` is true and the workspace has a tab at commit time |
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
| `surface` | `Id` | required | Must identify a live surface, or a kept tab (`shutdown-daemon` `keep_layout`) without one |
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
| `source` | `"user"` or `"auto"` | optional, default `user` | `workspace-name-source-v1`; `auto` never replaces a non-empty user name and cannot store an empty or whitespace name |
| `expected_name_revision` | decimal `string` | optional; required with `source: "auto"` unless `release` | `workspace-name-source-v1`; the workspace's `name_revision` the caller read |
| `release` | `boolean` | optional, default `false` | `workspace-name-source-v1`; with `source: "auto"`, hands the current name back to the automatic namer: `name` must equal it, the source becomes `auto` and `name_revision` advances |
| mutation fields | see common envelope | optional | Exactly-once retry and CAS; `source: "auto"` also requires `expected_generation` |

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
| `the resource revision changed` | `expected_name_revision` is not the workspace's current `name_revision` |
| `an explicit user name cannot be replaced by an automatic title` | `source: "auto"` over a non-empty user name |
| `automatic names cannot clear a title` | `source: "auto"` with an empty or whitespace name |
| `automatic names require a generation and name revision` | `source: "auto"` without `expected_generation` or `expected_name_revision` |
| `release hands a name to source auto` | `release: true` without `source: "auto"` |
| `a release keeps the current name` | `release: true` with a `name` other than the current one |
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
cell grid and, for a daemon-hosted page, CDP device metrics asynchronously
through the legacy reducer (a natively hosted page keeps its own viewport; see
`register-browser-provider`).
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

Fixed-grid handhelds (`host-grid-view-v1`, advertised in `identify`): a
phone or tablet connection (`device_kind` `iphone` or `ipad`) that does not
list `host-grid-view-v1` in `set-client-info` `capabilities` never gets a PTY
grid larger than the size it reported for a terminal while it is attached
with that size and counts: the daemon caps the applied grid per dimension at
it, under every policy. The published size state stays the engine's
decision. A client lists the capability only once it shows a larger grid
correctly (letterbox or pan).

Size lease (`size-lease-v1`, advertised in `identify`): a client that lists
`size-lease-v1` in `set-client-info` `capabilities` keeps each size it reports
(`resize-surface`, a sized `attach-surface`) for 45 s after the last report.
A `resize-surface` at the same size renews the lease and never resizes the
terminal. When a lease ends unrenewed the daemon releases that size as this
command would: the view stays attached and stops counting, so the grid
follows the other views at once. When the client disconnected without
releasing, the departed-view grid hold of that terminal ends at the lease's
end instead (docs/shared-terminal-sizing.md, "Phone viewers"). A client that
releases and then closes waits for this command's answer first; an end of
file the daemon reads before it is a dropped view, which holds.

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

With `shared-sizing-v1`, `view:string` (1-128 printable characters, for
example `mobile:<client_id>`) replaces `lease` and creates or updates a relay
sub-view keyed by this connection and `view`, with optional
`identity:object{user_id?,display_name?,device_kind?,device_name?,device_id?}`. An
omitted `identity` keeps the previous one. The connection must be attached to
the terminal. Its result adds `participant:string`, the host participant id
(`c<client>/<view>`); `accepted` is whether the sub-view now sets a dimension
of the grid. Terminals only.

### release-attached-view-size

| Field | Value |
| --- | --- |
| name | `release-attached-view-size` |
| status | implemented |
| since | protocol 10 with `view-attachment-lease-v1` |

Removes one attachment's geometry contribution while retaining its stream for
cached rendering. A retired lease returns `outcome:"superseded"`.

Params: required `surface:Id` and exactly one of `lease:string` or
`view:string` (a relay sub-view; it stays a participant without a viewport).

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

Params: required `surface:Id` and exactly one of `lease:string` or
`view:string`. With `view`, the relay sub-view leaves shared sizing and the
next owner takes the grid.

Result:

```text
object{outcome:"applied"|"superseded"}
```

### set-size-policy

| Field | Value |
| --- | --- |
| name | `set-size-policy` |
| status | implemented |
| since | protocol 12 with `shared-sizing-v1` |

Sets the shared sizing policy of one terminal (an override) or the default of
one workspace. A terminal without an override uses its workspace default, else
`latest`. Every participant of an affected terminal receives `size-state`.
Policies are in memory and reset when the daemon restarts.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | exactly one of `surface`/`workspace` | Terminal surface |
| `workspace` | `Id` | exactly one of `surface`/`workspace` | Existing workspace |
| `policy` | `object{mode,priority?,fixed?}` or `null` | required | `mode`: `latest`, `smallest`, `largest`, `priority`, `fixed`; `priority`: array of priority keys; `fixed`: `object{cols,rows}`; `null` clears |

Result: `object{state}` for a surface (the new size state), `object{}` for a
workspace.

```json
{"id":7,"cmd":"set-size-policy","surface":4,"policy":{"mode":"smallest"}}
{"id":7,"ok":true,"data":{"state":{"generation":5,"cols":118,"rows":30,"reason":"smallest","owners":["c1","c3"],"policy":{"mode":"smallest","priority":[],"fixed":null},"participants":[]}}}
```

### set-size-counts

| Field | Value |
| --- | --- |
| name | `set-size-counts` |
| status | implemented |
| since | protocol 12 with `shared-sizing-v1` |

Sets (`true`/`false`) or clears (`null`) one participant's counts-toward-size
override. At most one selector: `client:uint64` (that client's view of this
placement), `lease:string` (the caller's own leased view), `view:string` (the
caller's relay sub-view), or `participant:string`. Without a selector it
targets the caller's own view.

Params: required `surface:Id` and `counts:bool|null`, plus the optional
selector.

Result: `object{outcome:"applied"|"superseded",changed?:bool,participant?:string}`.
Errors: `unknown participant <id>`.

### note-size-activity

| Field | Value |
| --- | --- |
| name | `note-size-activity` |
| status | implemented |
| since | protocol 12 with `shared-sizing-v1` |

Records explicit activity (keyboard, paste or mouse input, or a focus click)
for shared sizing. Without `view` it marks the caller's own view of the
terminal. With `view` it marks that relay sub-view of this connection, so a
relay forwarding a phone's input credits the phone instead of itself. Under
`latest` the marked participant takes the grid when it counts. The command
requires the client capability `shared-sizing-v1`. Plain `send`/`send-key`
already mark the caller's own view.

Params: required `surface:Id`, optional `view:string`.

Result: `object{participant:string,changed:bool}`. Errors: `unknown
participant <id>`, and a capability error for a client without
`shared-sizing-v1`.

```json
{"id":9,"cmd":"note-size-activity","surface":4,"view":"mobile:p1"}
{"id":9,"ok":true,"data":{"participant":"c3/mobile:p1","changed":true}}
```

### reattach-view

| Field | Value |
| --- | --- |
| name | `reattach-view` |
| status | implemented |
| since | protocol 12 with `sizing-view-detach-v1` |

Restores the caller's own view of a terminal after `detach-client` detached
that view only (`detached` with `scope:"view"`). The view rejoins shared
sizing with its latest report. `counts:false` reattaches it as a viewer that
does not count toward the grid; `counts:true` makes it count; omitted keeps
the automatic rule.

Params: required `surface:Id`, optional `counts:bool`.

Result: `object{participant:string,state:object}` with the view's participant
id and the terminal's size state. Errors: `view of surface <id> is not
detached`, `surface <id> is not a terminal`.

```json
{"id":10,"cmd":"reattach-view","surface":4,"counts":false}
{"id":10,"ok":true,"data":{"participant":"c3","state":{"surface":4,"generation":7}}}
```

### get-size-state

| Field | Value |
| --- | --- |
| name | `get-size-state` |
| status | implemented |
| since | protocol 12 with `shared-sizing-v1` |

Returns the terminal's current size state (the `size-state` event payload) and
the caller's own participant id when it has one.

Params: required `surface:Id`.

Result: `object{state,self_participant:string|null}`.

### get-host-size-policy

| Field | Value |
| --- | --- |
| name | `get-host-size-policy` |
| status | implemented |
| since | protocol 12 with `host-size-policy-v1` |

Returns the host sizing policy: how this host's terminals are sized when
several devices show them (cmux-next-ios/PROTOCOL.md "Terminal sizing
policy"). It applies to every terminal without a `set-size-policy` override
or workspace default. With `surface`, also the size-state participant ids of
that terminal that are this host's own views: a desktop device kind on a
connection that did not send `set-client-info remote:true`.

Params: optional `surface:Id`.

Result: `object{policy:object{mode,order},mac_participants:[string]}`.
`mode` is `smallest` (the default), `mac`, `latest` or `priority`; `order` is
a list of device tokens, highest first: `mac` (this host's own views) or
`device:<id>` (the views whose `device_id` is `<id>`).

```json
{"id":3,"cmd":"get-host-size-policy","surface":4}
{"id":3,"ok":true,"data":{"policy":{"mode":"mac","order":[]},"mac_participants":["c2"]}}
```

### set-host-size-policy

| Field | Value |
| --- | --- |
| name | `set-host-size-policy` |
| status | implemented |
| since | protocol 12 with `host-size-policy-v1` |

Stores the host sizing policy in the host's settings file
(`mobile.terminalSizing`, and `mobile.terminalSizingOrder` when `order` is
given) and applies it to every live terminal that follows it. A hand edit of
either key, or a settings write, applies the same way. Each terminal expands
the policy into an engine policy whenever its participants change:
`smallest` and `latest` as themselves, `mac` as `priority` over this host's
own views, `priority` as `priority` over the views each token names, in
order. Every participant of a terminal whose policy changed receives
`size-state`.

Params: required `policy:object{mode,order?}`. `order`: at most 32 tokens,
each `mac` or `device:` followed by 1 to 128 of `[A-Za-z0-9_.:-]`; omitted
keeps the stored order. A bad mode or token is refused with `bad request`.

Only the verified cmux app (origin `user`) and a connection the daemon
accepted from the `cmux-mobile-host` executable beside its own (a phone's
lane) may write it; any other connection gets `forbidden`. "This host's own
views" are desktop-kind views on the in-process frontend or on a local Unix
connection with no link peer record, not accepted from that executable and
not marked `remote` in `set-client-info`.

Result: `object{policy:object{mode,order}}`.

```json
{"id":4,"cmd":"set-host-size-policy","policy":{"mode":"priority","order":["device:A1B2","mac"]}}
{"id":4,"ok":true,"data":{"policy":{"mode":"priority","order":["device:A1B2","mac"]}}}
```

### set-terminal-idle-policy

| Field | Value |
| --- | --- |
| name | `set-terminal-idle-policy` |
| status | implemented |
| since | protocol 12 additive extension; capability `terminal-idle-close-v1` |

Sets or clears the idle-close policy of one hosted terminal. The policy is
stored durably with the terminal in the session registry, so it survives owner
restarts. While a policy is set, the owner closes the terminal once it has had
no attach stream (`attach-surface` or resource `terminal.attach`) on any of its
views or its unplaced runtime for at least `idle_close_seconds`. The close uses
the same path as `close-terminal`: the terminal is tombstoned, its host is
terminated, and its placements are removed. The reaper evaluates policies every
15 seconds, so a close can land up to that much later than the deadline.

Unattached time is measured by the running owner. It restarts at every attach,
including an attach and detach that both happen between two reaper ticks, and
at owner start, so an owner restart can delay a close but never make it early.
Terminals without a policy are never closed for idleness.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` or null | exactly one of `surface`/`terminal_id` | A PTY surface backed by a hosted terminal |
| `terminal_id` | string or null | exactly one of `surface`/`terminal_id` | Host id (32 lowercase hex) or public `term_` id |
| `idle_close_seconds` | integer or null | default null | 1 through 315360000 (ten years); null clears the policy (never close) |

Errors: `terminal_not_found` for an unknown or closed terminal,
`terminal_not_hosted` for a surface without a terminal host, and `bad request`
for invalid bounds or when both or neither target is given.

Result:

```text
object{terminal_id:string, idle_close_seconds:uint64|null}
```

### set-terminal-keep

| Field | Value |
| --- | --- |
| name | `set-terminal-keep` |
| status | implemented |
| since | protocol 12 additive extension; capability `terminal-reap-v1` |

Marks (`keep:true`) or unmarks one hosted terminal as kept. Closing a tab,
pane, screen, or workspace detaches a PTY terminal without ending it. Reaping
is opt-in per daemon: an owner started with `--terminal-reap-grace-seconds <n>`
(`cmux daemon ensure --terminal-reap-grace-seconds <n>` passes it to the owner it spawns)
ends a terminal that is not kept once it has had no tab placement for `n`
seconds (0 ends it at once). Without that option no terminal is reaped, so
clients that rely on detached terminals surviving a close keep working, and
the keep flag is stored but has no effect. The end uses the same path
as `close-terminal` and emits `terminal-reaped`. A placement restored within
the grace period (layout undo, `terminal.project`, `move-terminal`) cancels it,
and an attached stream on the unplaced terminal postpones it by another grace
period. The grace period restarts when the owner restarts, so a restart can
delay a reap but never make it early.

The keep flag is stored durably with the terminal and survives owner restarts.
Terminals default to not kept. When a build with this capability first opens a
registry written before it, every live terminal without a live tab is marked
kept, so an upgrade never ends detached work.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` or null | exactly one of `surface`/`terminal_id` | A PTY surface backed by a hosted terminal |
| `terminal_id` | string or null | exactly one of `surface`/`terminal_id` | Host id (32 lowercase hex) or public `term_` id |
| `keep` | boolean | required | true keeps the terminal with no tab; false lets the owner end it |

Errors: `terminal_not_found` for an unknown or closed terminal,
`terminal_not_hosted` for a surface without a terminal host, and `bad request`
when both or neither target is given.

Result:

```text
object{terminal_id:string, terminal_resource_id:string|null, keep:bool}
```

`terminal_id` is the host id (32 lowercase hex digits) and
`terminal_resource_id` the terminal's public `term_` id, a separate random id
that `attach-surface` identity needs. A frontend that knows only the host id
(a remote-terminal reference on another session) keeps the terminal by host
id and attaches with the returned public id and `identify.generation`; a
kept terminal with no tab placement attaches this way and takes geometry
like a placed one (`set-client-sizing`, `resize-attached-view`,
`release-attached-view-size`): its attached views are not treated as views of
a closed tab.

### terminal-resume-command

| Field | Value |
| --- | --- |
| name | `terminal-resume-command` |
| status | implemented |
| since | protocol 12 additive extension; capability `resume-command` |

Reads, sets, or clears the resume command of one hosted terminal: a line a
person chose for that terminal. When the owner respawns the terminal (after an
owner restart, an update, or a reboot) it types the resume command on the new
prompt without a newline, so it never runs on its own; it takes the place of
the agent resume or command line the owner would otherwise offer. The command
is stored durably with the terminal and survives owner restarts; the row of a
closed terminal is removed.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` or null | exactly one of `surface`/`terminal_id` | A PTY surface backed by a hosted terminal |
| `terminal_id` | string or null | exactly one of `surface`/`terminal_id` | Host id (32 lowercase hex) or public `term_` id |
| `command` | string or null | absent reads | A string sets (trimmed; one line of 1-4096 bytes without control characters); null clears |

Errors: `terminal_not_found` for an unknown or closed terminal,
`terminal_not_hosted` for a surface without a terminal host, and `bad request`
when both or neither target is given or the command is empty, too long, or
holds a control character.

Result:

```text
object{terminal_id:string, command:string|null}
```

`command` is the stored resume command after the request, null when none is set.

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

Moves an existing tab, identified by `surface`, into `pane` at zero-based
`index`. The destination index uses the pre-move tab list's insertion
coordinates. For a same-pane move, the server removes the tab, subtracts one
from `index` when it is greater than the tab's current index, then clamps the
adjusted index to the last valid position in the shortened list. For example,
with tabs `[A,B,C]`, moving `A` with `index:2` produces `[B,A,C]`, while
`index:3` produces `[B,C,A]`; `index:0` and `index:1` leave the order unchanged.
A same-pane no-op returns `ok:true` and leaves the active tab unchanged. A
cross-pane move removes the tab from its source, collapses an empty source
pane, and inserts it at the clamped destination index.

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
| `unknown surface/pane` | The surface, destination pane, or the surface's current pane does not exist |
| `bad request: ...` | Missing fields or wrong JSON type |

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

With `tab-drag-v1`, `move-tab` accepts an optional `transaction` (echoed in the
moved tab's `tab-changed` delta) and returns `object{moved:bool, undoable:bool}`.
A move between two panes of one screen whose source pane keeps a tab records a
layout-undo entry that moves the tab back. Same-pane reorders are not
undoable. With `tab-metadata-v1`, the index is clamped so pinned tabs stay
first.

### create-tab-group

| Field | Value |
| --- | --- |
| name | `create-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Every tab group command names tabs by numeric surface id or public `tab_...`
id, and panes by numeric id or public `pane_...` id, so the noun-first CLI
(`cmux tab group ...`) can pass the ids `cmux tab list` prints. The
`surfaces` field also accepts the alias `tabs`.

Groups tabs of one pane. The members become contiguous at the strip position
of the first of them and leave any group they were in. Pinned tabs cannot be
grouped. The reorder and the group commit in one transaction. Each member's
`tab-changed` carries `transaction`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surfaces` | array of `Id` | required, nonempty | Tabs of one pane |
| `name` | string | default `""` | At most 256 characters; empty shows the color only |
| `color` | string | default `"grey"` | One of the nine tab group colors or `#RRGGBB` |
| `group` | string | default generated `tgrp_<32 hex>` | 1-64 ASCII letters, digits, `_`, `-`, `.`, `:` |
| `transaction` | string | optional | Client id echoed in `tab-changed` |

Result (every tab group command that returns a group):

```text
object{group:object{id:string, name:string, color:string, collapsed:bool, saved_id:string|null}|null, pane:Id|null, workspace:Id|null, surfaces:array<Id>}
```

### list-tab-groups

| Field | Value |
| --- | --- |
| name | `list-tab-groups` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Returns every group run with its `pane`, in the `Pane.tab_groups` shape.

Result: `object{groups:[...]}`.

### update-tab-group

| Field | Value |
| --- | --- |
| name | `update-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Renames, recolors, collapses, expands, or sets or clears the icon of a
group; absent fields are unchanged. A linked saved group follows. Collapse
is shared state; moving selection out of a collapsed group is the
frontend's client-local focus.

Params: `group` (string, required), `name` (string), `color` (string),
`collapsed` (bool), `icon` (string or null, `tab-group-icon-v1`: one emoji,
an SF Symbol name, or a stored `image:sha256-<hex>` or `svg:sha256-<hex>`
asset; null clears it).

### add-tabs-to-tab-group

| Field | Value |
| --- | --- |
| name | `add-tabs-to-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Adds tabs at the end of a group's run. Tabs in other panes, screens, or
workspaces move into the group's pane in the same commit. Pinned tabs are
refused.

Params: `group` (string, required), `surfaces` (array of `Id`, required),
`transaction` (string).

### remove-tabs-from-tab-group

| Field | Value |
| --- | --- |
| name | `remove-tabs-from-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Removes tabs from their groups; each lands just after its former group. A group left without members disappears.

Params: `surfaces` (array of `Id`, required), `transaction` (string).

Result: `object{surfaces:array<Id>, groups:array<string>}`.

### move-tab-group

| Field | Value |
| --- | --- |
| name | `move-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Moves a whole group, members in order, to insertion `index` among the other
tabs of `pane` (default: the group's own pane, at the end). Another pane's
strip, screen, or workspace works too. The index is clamped so pinned tabs
stay first. One commit; not layout-undoable.

Params: `group` (string, required), `pane` (`Id`), `index` (usize),
`transaction` (string).

### move-tab-group-to-split

| Field | Value |
| --- | --- |
| name | `move-tab-group-to-split` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Moves a whole group into a new split beside `pane`, in one commit.

Params: `group`, `pane`, `edge` (`left`/`right`/`top`/`bottom`), `ratio`,
`transaction`, as in `move-tab-to-split`.

### move-tab-group-to-column

| Field | Value |
| --- | --- |
| name | `move-tab-group-to-column` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Moves a whole group into a new strip column, in one commit.

Params: `group`, then `pane` or `screen`, `after_column`, `width`,
`transaction`, as in `move-tab-to-column`.

### move-tab-group-to-new-workspace

| Field | Value |
| --- | --- |
| name | `move-tab-group-to-new-workspace` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Moves a whole group into a new workspace created in the same commit,
optionally in the sidebar group `workspace_group` at final section index
`index`. Frontends tear a group off into a new window by opening the returned
workspace there.

Params: `group` (string, required), `workspace_group` (string), `index`
(usize), `transaction` (string).

### ungroup-tab-group

| Field | Value |
| --- | --- |
| name | `ungroup-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Deletes a group; its tabs stay in place. Result: `object{group:string,
surfaces:array<Id>}`.

### close-tab-group

| Field | Value |
| --- | --- |
| name | `close-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-groups-v1` |

Closes every member placement in one commit. Terminal processes keep
running, as with any closed view; browsers close with their only tab. A
linked saved group remains. Result: `object{group:string,
closed:array<Id>}`. With `end_terminals: true` (capability
`batch-close-v1`) the same commit also ends every member terminal with no
view left that is not kept, and the result adds
`terminals:array<object{terminal_id:string,terminal_incarnation:string|null}>`.

### save-tab-group

| Field | Value |
| --- | --- |
| name | `save-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `saved-tab-groups-v1` |

Saves (pins) a live group: a session-wide record of its name, color, and
members (terminal host id, directory, and title; browser URL, engine,
profile, and title) that outlives the placements. The live group stays
linked: renames, recolors, and membership changes update the record.

Params: `group` (string, required). Result: `object{group:string,
saved:string}`.

### unsave-tab-group

| Field | Value |
| --- | --- |
| name | `unsave-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `saved-tab-groups-v1` |

Deletes the saved record linked to a live group; the group stays. Result:
`object{group:string, unsaved:bool}`.

### delete-saved-tab-group

| Field | Value |
| --- | --- |
| name | `delete-saved-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `saved-tab-groups-v1` |

Deletes a saved record by id; a linked live group stays, unlinked. Result:
`object{saved:string, deleted:bool}`.

### list-saved-tab-groups

| Field | Value |
| --- | --- |
| name | `list-saved-tab-groups` |
| status | implemented |
| since | protocol 12 additive extension; capability `saved-tab-groups-v1` |

Result:

```text
object{saved_groups:array<object{id:string, room:string, name:string, color:string, updated_at_ms:uint64, members:array<object{kind:"terminal", terminal_id:string|null, cwd:string|null, title:string|null} | object{kind:"browser", url:string, engine:string|null, profile_id:string|null, title:string|null}>}>}
```

Saved tab groups are personal state of the home session
(plans/cmux-next/state-ownership.md) and belong to one room (`room`, the
`profiles-v1` room id; `default` for groups saved through these commands).
The first open of a registry copies every shared `saved_tab_groups` row into
the personal table in the `default` room; the shared table is read only by
that migration. The `cmux.protocol/2` operations `saved_tab_group.*` address
the same records.

### reopen-saved-tab-group

| Field | Value |
| --- | --- |
| name | `reopen-saved-tab-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `saved-tab-groups-v1` |

Reopens a saved group into `pane`. When a live group is still linked to the
record, it is returned unchanged. Otherwise each member is restored: a
terminal that is still running is reattached as a new view of the same
terminal, other terminals start in their saved directory, and browsers
reopen at their saved URL (frontend-rendered with the saved engine and
profile). The restored tabs form a new group linked to the record. Restoring
creates one tab per member, so a failure partway leaves the tabs created so
far.

Params: `saved` (string, required), `pane` (`Id`, required), `transaction`
(string).

### ack-tab-notifications

| Field | Value |
| --- | --- |
| name | `ack-tab-notifications` |
| status | implemented |
| since | protocol 12 additive extension; capability `notification-ack-v1` |

Acknowledges a tab's notifications without selecting or focusing it: clears
the unread marker of the tab's content (all views of one terminal share it)
and durably records every retained notification of that content as
acknowledged, so a daemon restart does not restore the marker. Frontends keep
focus client-local and call this when the user has seen the tab. With
`feed-local-owner-v1` this is the only clear: selection and focus never clear
unread, and the same transaction marks the tab's unread local feed items read
(items of the tab's terminal, or of the tab itself when it has no terminal).
Items owned elsewhere stay unread and are listed in `refused` (`feed.moving`
while handing off, `owner.unreachable` once moved; both retryable; nothing
queues), and the tab's unread marker stays while any unread item of the tab
is left (rings follow unread items); its notifications are then not recorded as
acknowledged, so a restart keeps the marker. A daemon without the capability still
clears on `select-tab`/`focus-pane` and omits `refused`. Emits `tab-changed`
for each view whose marker cleared. Acknowledging a tab with no marker succeeds with
`cleared:false`.

Params: `surface` (`Id`, required).

Result:

```text
object{surface:Id, cleared:bool, acknowledged:[string], refused?:[object{item:string, code:string, retryable:bool}]}
```

### feed-local-list

| Field | Value |
| --- | --- |
| name | `feed-local-list` |
| status | implemented |
| since | protocol 12 additive extension; capability `feed-local-owner-v1` |

Lists the daemon's local feed items, oldest first (plans/cmux-next/feed.md
sections 5 and 9.1). The daemon owns an item while it is `open`; the app
freezes it (`handing_off`) before it sends `feed.adopt` to the cloud owner and
moves it (`moved`, `home`) after, or reopens it (`open`) after
`feed.adopt.cancel` answered `cancelled: true`. At launch the app rebuilds its handoff queue
from `state:"handing_off"`, never from its own memory. A `moved` item is a
non-authoritative copy and is never a write target. The daemon keeps at most
500 items and prunes read and moved items 7 days after their last change; it
never prunes a `handing_off` item. A new notification for a terminal whose
newest item is still unread and `open` updates that item (latest text wins,
`count` + 1) instead of adding one.

Params: `state` (`open` | `handing_off` | `moved`, optional), `terminal_id`
(optional), `unread` (bool, default false).

Shapes:

```text
FeedLocalItem = object{id:string, dedupe_key:string, aliases?:[string], title:string, body:string, level:string, source:string, context:object{workspace?:string, tab?:string, terminal?:string}, actor?:object{kind:string, id:string, host?:string, agent?:string}, created_at_ms:uint64, updated_at_ms:uint64, read_at_ms?:uint64, state:"open"|"handing_off"|"moved", home?:string, count:uint32}
```

An item id is `fi_` plus the first 20 hex digits of
`sha256("cmux-feed-item:" + notification id)`, the cloud owner's item id shape,
so `feed.adopt` keeps the same id; `dedupe_key` is
`notify:<session id>:<notification id>`. `actor` (who posted) is the P8 actor
stamp (plans/cmux-next/identity.md section 3) of the request that posted the
notice: the actor's kind and id (`user`/`user_local`, `frontend`/install id,
`app`/app id, `peer`/peer id, or `daemon`/`daemon` for notices the daemon itself
posts, such as terminal output and agent hooks), with `host` for a local actor.
It is never derived from the notice's content and never part of an idempotency
fingerprint. A notice with no terminal and no tab posts read, because no tab
acknowledgement could read it. `notification.clear` reads the local items of the
cleared terminal (every item for a session-wide clear) and keeps the marker of
an item that stays unread; closing a terminal reads its items, and closing a
tab without a terminal reads that tab's items. On every start the daemon also
reads the unread items of terminals and tabs that are gone (a crash between a
close and its read). On every start the daemon
turns each retained notification it has not taken yet into an item, with the
tab and workspace of its terminal, read when any client acknowledged it
(`read_by` or a persisted ack) or when it has no terminal; this also picks up
notifications an older daemon wrote after a downgrade. The daemon records every
notification it took until the notification is cleared or its receipt is gone,
so a coalesced, moved or pruned item never comes back. For a notification it already took, only a persisted ack
counts: it reads the item when the item is still `open` here. Read is one-way.

Result: `object{items:[FeedLocalItem]}`

### feed-local-read

| Field | Value |
| --- | --- |
| name | `feed-local-read` |
| status | implemented |
| since | protocol 12 additive extension; capability `feed-local-owner-v1` |

Marks explicit local items read, all or nothing (at most 500 ids). A moved
item refuses with `owner.unreachable` and a handing-off item with
`feed.moving` (both retryable; nothing queues); an unknown id refuses with
`not_found`. Reading a read item changes nothing. When a terminal, or a tab
without a terminal, has no unread item left, its unread marker clears
(`tab-changed` for each placement) and its retained notifications are
acknowledged in the same transaction.

Params: `items` (`[string]`, required).

Result: `object{items:[FeedLocalItem]}`

### feed-local-handoff-begin

| Field | Value |
| --- | --- |
| name | `feed-local-handoff-begin` |
| status | implemented |
| since | protocol 12 additive extension; capability `feed-local-owner-v1` |

Only the verified cmux app connection (the `frontend` actor); any other connection is refused with `forbidden`. Freezes an `open` item as `handing_off` in its
own commit (section 5 rule 3a); the app then sends `feed.adopt` with the
idempotency key `adopt:<item>`. Repeating it on a handing-off item returns the
item unchanged; a moved item refuses with `feed.invalid_state`. The state
survives a daemon restart.

Params: `item` (string, required).

Result: `object{item:FeedLocalItem}`

### feed-local-handoff-abort

| Field | Value |
| --- | --- |
| name | `feed-local-handoff-abort` |
| status | implemented |
| since | protocol 12 additive extension; capability `feed-local-owner-v1` |

Only the verified cmux app connection (the `frontend` actor); any other connection is refused with `forbidden`. Reopens a `handing_off` item (`open`, owned
here again) after the app sent `feed.adopt.cancel` with key `adopt:<item>` and
the cloud owner answered `cancelled: true`: its tombstone then refuses any
delayed `feed.adopt` with that key, so the unfreeze keeps one writer. Never send
it on a timeout or a lost reply (section 5 rule 3e). On `cancelled: false` the
cloud owns the item: send `feed-local-handoff-done` with `home:"cloud"`
instead. Repeating it on an `open` item returns the item unchanged; a moved
item refuses with `feed.invalid_state`. A new handoff of a reopened item gets
`feed.adopt_cancelled` from the cloud owner until the tombstone expires.

Params: `item` (string, required).

Result: `object{item:FeedLocalItem}`

### feed-local-handoff-done

| Field | Value |
| --- | --- |
| name | `feed-local-handoff-done` |
| status | implemented |
| since | protocol 12 additive extension; capability `feed-local-owner-v1` |

Only the verified cmux app connection (the `frontend` actor); any other connection is refused with `forbidden`. Records that the new owner committed the item:
`handing_off` becomes `moved` with `home` (section 5 rule 3d). Repeating it
with the same `home` returns the item unchanged; an `open` item, or a moved
item with another home, refuses with `feed.invalid_state`.

Params: `item` (string, required), `home` (1 to 128 bytes, required, `cloud`
today).

Result: `object{item:FeedLocalItem}`

### list-notifications

| Field | Value |
| --- | --- |
| name | `list-notifications` |
| status | implemented |
| since | protocol 12 additive extension; capability `notification-ack-v1` |

Returns the retained notification ledger (at most 256), newest first.

Params: `limit` (usize, default 256).

Result:

```text
object{notifications:[object{id:string, title:string, subtitle:string|null, body:string, level:"info"|"warning"|"error", terminal_id:string|null, surface:Id|null, created_at_ms:uint64, acknowledged:bool}]}
```

### set-tab-pinned

| Field | Value |
| --- | --- |
| name | `set-tab-pinned` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-metadata-v1` |

Pins or unpins a tab placement. Pinned tabs sort first in their pane:
pinning moves the tab to the end of the pinned run, and unpinning moves it to
the start of the unpinned run. The flag is durable, keyed by the public tab
id, so it survives restarts and moves between panes. While tabs are pinned,
`move-tab` clamps its index so an unpinned tab cannot move ahead of the pinned
run and a pinned tab cannot move behind it. Emits `tab-changed` when the flag
changed, and the usual reorder events when the tab moved.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Tab placement |
| `pinned` | bool | required | |

Result:

```text
object{surface:Id, pinned:bool, index:usize, changed:bool}
```

### move-tab-to-workspace

| Field | Value |
| --- | --- |
| name | `move-tab-to-workspace` |
| status | implemented |
| since | protocol 12 |

Move an existing tab without restarting its terminal or browser. `surface` is
required. Optional `workspace` is a numeric workspace ID; omission creates a new
workspace. Existing nonempty destinations use their active pane. Empty and new
destinations create a screen and pane in the same durable transaction as the
move. The destination becomes selected. Unknown source/destination IDs fail.
Provider-owned workspace creation is rejected. The server advertises
`tab-workspace-move-v1`; clients hide these UI actions for older owners.

With `tab-drag-v1` the command accepts an optional `transaction`, echoed in
the moved tab's `tab-changed` delta, and returns
`object{surface:Id, workspace:Id, pane:Id, undoable:false}`.

```json
{"id":26,"cmd":"move-tab-to-workspace","surface":1}
{"id":26,"ok":true,"data":{}}
```

### move-tab-to-split

| Field | Value |
| --- | --- |
| name | `move-tab-to-split` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-drag-v1` |

Drops a tab on a pane edge: creates a pane beside `pane` on `edge` and moves
the tab into it, in one atomic commit. The tab keeps its terminal or browser;
nothing restarts. The source pane collapses when it loses its last tab. A tab
cannot be split out of a pane where it is the only tab, unless the request
carries `respawn`.

With `tab-split-respawn-v1`, `respawn` splits the tab's own pane when the tab
is that pane's only tab: the daemon first creates a fresh tab of the given
kind in the pane, then moves the dragged tab into the new pane. The fresh tab
is a new terminal (spawned like `new-tab` with `cwd`, `env`, `terminal_id`,
and `shell_args`) or a new frontend browser tab (`url` and `engine` required,
`profile_id`, as in `new-frontend-browser-tab`); it never copies the dragged
tab's state. The layout reducer validates the whole operation, the created
tab included, before either step runs. `respawn` on any other drop (another
pane, or a pane with more tabs) is a bad request. The move commits only while
the pane holds exactly the dragged and the fresh tab; if another client
changed the pane in between, or the move fails after the fresh tab exists,
the daemon closes the fresh tab again. A daemon that stops between the two
steps keeps the fresh tab beside the dragged one. `undo-layout` of a
respawn split moves the dragged tab back beside the fresh tab.

The new pane takes focus (it becomes its screen's active pane, and its
screen and workspace become active). With `tab-split-keep-focus-v1`,
`keep_focus:true` leaves focus where it was: the target screen keeps its
active pane, the active screen and workspace stay, and the new pane is the
least recently active pane, so closing the focused pane does not focus it.
An app uses it to open a pane for an agent while the user types in another
one. When the focused pane closes in the move (it held only the moved tab),
the new pane takes focus as without the flag. `keep_focus` with `respawn`
is a bad request. `move-tab-to-column` takes the same field (an app that
splits beside a pane without room moves the tab to a new column instead). A daemon without the
capability ignores the field and focuses the new pane, so clients check
the capability first.

When the source pane survives on the destination screen, the drag records one
layout-undo entry: `undo-layout` on that screen moves the tab back to its
original pane and index and removes the created pane, without confirmation
and without closing anything. Other drags clear the undo history of the
screens they touch and return `undoable:false`.

Emits `tree-changed`, `layout-changed`, and `tab-changed` for the moved tab;
`tab-changed` carries `transaction` when the request did.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Tab to move |
| `pane` | `Id` | required | Pane whose edge received the drop |
| `edge` | string | required | `"left"`, `"right"`, `"top"`, or `"bottom"` |
| `ratio` | float | default 0.5 | The new pane's share, 0.05 through 0.95 |
| `respawn` | `SplitRespawn` | optional; `tab-split-respawn-v1` | `{kind:"terminal", cwd?, env?, terminal_id?, shell_args?}` or `{kind:"browser", url, engine, profile_id?}`; only for the pane's only tab |
| `keep_focus` | bool | default false; `tab-split-keep-focus-v1` | The focused pane stays focused; the new pane does not take focus |
| `transaction` | string | optional | Client id echoed in `tab-changed`; 1-128 printable ASCII |

Result:

```text
object{surface:Id, pane:Id, screen:Id, workspace:Id, undoable:bool}
```

### move-tab-to-column

| Field | Value |
| --- | --- |
| name | `move-tab-to-column` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-drag-v1` |

Drops a tab between strip columns: creates a horizontal viewport column on the
screen and moves the tab into it, in one atomic commit, with the same undo,
event, and transaction rules as `move-tab-to-split`. A screen without columns
becomes a two-column screen.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Tab to move |
| `pane` | `Id` | exactly one of `pane`/`screen` | Any pane on the destination screen |
| `screen` | `Id` | exactly one of `pane`/`screen` | Destination screen |
| `after_column` | `Id` | default: after the last column | Column (`Screen.columns[].id`) to insert after |
| `width` | float | default 2/3 | Column width as a fraction of the viewport, 0.1 through 1.0 |
| `dock` | `ColumnPin` | optional; `edge-docks-v1` | `{edge:"left"\|"right"\|"top"\|"bottom", mode:"docked"\|"overlay", role?:"agent_chat"}`: pins the new column to that edge in the same commit, with the rules of `set-column-dock` (the column that held the edge scrolls again); `role` needs `dock-column-role-v1`, and an unknown role is dropped |
| `respawn` | `SplitRespawn` | optional; `tab-column-respawn-v1` | As in `move-tab-to-split`; only for the pane's only tab: the pane keeps a fresh tab of that kind, created before the move, so the column the tab leaves stays |
| `keep_focus` | bool | default false; `tab-split-keep-focus-v1` | As in `move-tab-to-split`: the new column's pane does not take focus |
| `transaction` | string | optional | As in `move-tab-to-split` |

Result: as `move-tab-to-split`.

### move-tab-to-new-workspace

| Field | Value |
| --- | --- |
| name | `move-tab-to-new-workspace` |
| status | implemented |
| since | protocol 12 additive extension; capability `tab-drag-v1` |

Drops a tab on the sidebar: creates a workspace holding the tab in one
durable transaction, like `move-tab-to-workspace` without a destination, and
optionally places it in a group at a final index among that section's
members (the group membership commits in the same transaction). Without
`index` the workspace goes after the section's last member. The move is not
layout-undoable. Frontends tear a tab off into a new window by opening the
returned workspace there.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Tab to move |
| `group` | string | optional | Existing group id |
| `index` | usize | optional | Final index among the section's members |
| `name` | string | optional | The new workspace's name, at most 1024 bytes (else the default `workspace-N`); capability `tab-workspace-name-v1` |
| `transaction` | string | optional | As in `move-tab-to-split` |

Result:

```text
object{surface:Id, workspace:Id, key:string, index:usize, group:string|null, pane:Id, undoable:false}
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

### set-workspace-metadata

| Field | Value |
| --- | --- |
| name | `set-workspace-metadata` |
| status | implemented |
| since | protocol 12 additive extension; capability `workspace-metadata-v1` |

Sets a workspace's shared presentation. For each of `color`, `icon`, and
`title`, an absent field is unchanged, `null` clears it, and a value sets it.
An absent or null `pinned` is unchanged and a boolean sets it (`workspace-pin-v1`); so is
`marked_unread` (`notification-mark-unread-v1`).
The write commits one workspace-registry revision without changing the
workspace order, so it takes the durable mutation envelope and emits
`workspace-changed` with the full workspace entity.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | one of id/key | Workspace to change |
| `key` | string | one of id/key | Workspace key |
| `color` | string or null | optional | Palette token `[a-z][a-z0-9-]{0,31}` or `#RRGGBB[AA]` |
| `icon` | string or null | optional | Icon value (see `put-blob`) |
| `title` | string or null | optional | 1-256 characters, no control characters |
| `pinned` | bool | optional | Sidebar pin; capability `workspace-pin-v1` |
| `marked_unread` | bool | optional | Manual unread mark; capability `notification-mark-unread-v1` |
| mutation fields | see common envelope | optional | Exactly-once retry and CAS |

Result:

```text
object{workspace:Id,key:string,color:string|null,icon:string|null,title:string|null,pinned:bool,marked_unread:bool,workspace_revision:uint64,changed:bool,replayed:bool,registry_id:string,generation:string}
```

### list-workspace-groups

| Field | Value |
| --- | --- |
| name | `list-workspace-groups` |
| status | implemented |
| since | protocol 12 additive extension; capability `workspace-groups-v1` |

Returns the durable sidebar groups in order. `list-workspaces` carries the
same array as its top-level `groups` field.

Result:

```text
object{groups:[WorkspaceGroup]}
WorkspaceGroup = object{id:string, name:string, color:string|null, collapsed:bool, index:usize}
```

### create-workspace-group

| Field | Value |
| --- | --- |
| name | `create-workspace-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `workspace-groups-v1` |

Creates a sidebar group. Groups are shared durable state in the session
registry, so every frontend sees them and they survive daemon restarts. A
caller-chosen `group` id makes a retry idempotent: the same id and name return
the stored group with `changed:false`; the same id with another name fails.
Emits `tree-changed`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `name` | string | required | 1-256 characters, no control characters |
| `group` | string | default generated `grp_<32 hex>` | 1-64 ASCII letters, digits, `_`, `-`, `.`, `:` |
| `color` | string | default null | Palette token `[a-z][a-z0-9-]{0,31}` or `#RRGGBB[AA]` |
| `collapsed` | bool | default false | Shared collapsed state |
| `index` | usize | default last | Insertion index among groups |

Result:

```text
object{group:WorkspaceGroup, changed:bool}
```

### update-workspace-group

| Field | Value |
| --- | --- |
| name | `update-workspace-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `workspace-groups-v1` |

Renames, recolors, or collapses a group. An absent field is unchanged, and
`color:null` clears the color. Emits `tree-changed` when something changed.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `group` | string | required | Existing group id |
| `name` | string | optional | As in `create-workspace-group` |
| `color` | string or null | optional | As in `create-workspace-group`; null clears |
| `collapsed` | bool | optional | |

Result: `object{group:WorkspaceGroup, changed:bool}`.

### delete-workspace-group

| Field | Value |
| --- | --- |
| name | `delete-workspace-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `workspace-groups-v1` |

Deletes a group. Its workspaces keep their place in the workspace order and
become ungrouped. Emits `tree-changed`.

Params: `group` (string, required).

Result: `object{group:string, ungrouped_keys:[string]}`.

### move-workspace-group

| Field | Value |
| --- | --- |
| name | `move-workspace-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `workspace-groups-v1` |

Moves a group to zero-based insertion `index` among groups, with the same
insertion-point rule as `move-workspace`. Emits `tree-changed` when the order
changed.

Params: `group` (string, required), `index` (usize, required).

Result: `object{group:WorkspaceGroup, changed:bool}`.

### move-workspace-to-group

| Field | Value |
| --- | --- |
| name | `move-workspace-to-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `workspace-groups-v1` |

Puts a workspace in a group, or ungroups it with `group:null`, and optionally
reorders it inside that section. Groups partition the one durable workspace
order: a section's order is the workspace order filtered by group. `index` is
the workspace's final zero-based position among the destination section's
other members (clamped to the end); an absent `index` keeps the workspace's
position. An empty destination keeps the position too.

The move commits one workspace-registry revision and emits `workspace-moved`
with the full workspace entity, so it takes the durable mutation envelope:
`origin`/`mutation_id` retries replay the original result and
`expected_revision` guards against stale clients.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `workspace` | `Id` | one of id/key | Workspace to move |
| `key` | string | one of id/key | Workspace key |
| `group` | string or null | required | Existing group id, or null for ungrouped |
| `index` | usize | optional | Final index among the section's members |
| mutation fields | see common envelope | optional | Exactly-once retry and CAS |

Result:

```text
object{workspace:Id,key:string,index:usize,group:string|null,workspace_revision:uint64,changed:bool,replayed:bool,registry_id:string,generation:string}
```

### list-personal

| Field | Value |
| --- | --- |
| name | `list-personal` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Personal-state commands (plans/cmux-next/data-model.md section 3) store the
home session's organization: rooms (wire name `profile`), the sessions they
follow, workspaces pinned to one room, the session registry, personal groups,
and the personal order and overrides of every qualified workspace
`{session_id, workspace_key}`. Every daemon serves them; the app writes them
only on its home session. Each change bumps `personal_revision` and emits
`personal-changed`; an unchanged retry emits nothing.

Shapes:

```text
Room = object{id:string, name:string, color:string|null, icon:string|null, theme:string|null, index:usize, browser_profile_id:string|null, default_session_id:string|null, defaults:object{cwd?:string, env?:object}|null, follows:[string]}
Session = object{session_id:string, machine_name:string|null, session_name:string|null, transport:object, last_seen_ms:uint64|null, capabilities:json|null, migrated:bool, icon?:string|null}
Pin = object{session_id:string, workspace_key:string, profile:string}
PersonalGroup = object{id:string, profile:string, name:string, color:string|null, collapsed:bool, index:usize, top_index:usize|null, icon:string|null, pinned:bool}
PersonalWorkspace = object{session_id:string, workspace_key:string, index:usize, group:string|null, browser_profile_id:string|null, theme:string|null, remote_localhost?:bool|null}
PersonalTerminal = object{session_id:string, terminal_key:string, theme:string}
BrowserProfile = object{id:string, name:string, color:string|null, icon:string|null, index:usize, source:object|null}
```

Room ids are `default` or 1-64 ASCII letters, digits, `_`, `-`, `.`, `:`
(generated `prof_<32 hex>`). Colors are palette tokens or `#RRGGBB[AA]`; icons
are icon values (see `put-blob`); `theme` is 1-256 characters without
control characters; `browser_profile_id` is `default` or a lowercase UUID;
`transport` and `capabilities` are JSON of at most 4 KiB; `defaults.env`
follows the per-terminal `env` rules. On first open the daemon creates the
`default` room, its own session row (`transport {"kind":"local"}`,
`migrated:true`) followed by `default`, and copies its shared workspace groups
and registry order into personal rows, once.
`list-personal` returns every personal record in order.

Result:

```text
object{personal_revision:uint64, sessions:[Session], profiles:[Room], pins:[Pin], groups:[PersonalGroup], workspaces:[PersonalWorkspace], terminals:[PersonalTerminal], browser_profiles?:[BrowserProfile]}
```

`terminals` (capability `personal-terminals-v1`, sorted by `session_id` then
`terminal_key`) holds the own theme of each session-qualified terminal that
has one; older servers omit it.

A `Session` record is the entry the app's sidebar shows as a machine: this
daemon's own record and one per remote session the app syncs with
`put-session`. With `session-icon-v1` it carries `icon`, the machine's icon
value (null when none; older servers omit it), set only by `set-session-icon`.

`browser_profiles` (capability `browser-profiles-v1`) always starts with the
`default` record in order; every open of the registry creates it when missing.

### create-browser-profile

| Field | Value |
| --- | --- |
| name | `create-browser-profile` |
| status | implemented |
| since | protocol 12 additive extension; capability `browser-profiles-v1` |

Creates a browser profile record (plans/cmux-next/data-model.md section 5).
The app keys each engine's storage by its id; the daemon keeps only the
record. `browser_profile` is `default` or a lowercase UUID (generated when
absent); an existing id returns the stored record unchanged with
`changed:false`, so an interrupted import finds the profile it made. `index`
is an insertion index (default last). `source` is the import origin, a JSON
object of at most 4 KiB. Colors and icons follow the personal-state rules.

Params: `name` (required), `browser_profile`, `color`, `icon`, `index`,
`source`.

Result: `object{browser_profile:BrowserProfile, changed:bool}`

### update-browser-profile

| Field | Value |
| --- | --- |
| name | `update-browser-profile` |
| status | implemented |
| since | protocol 12 additive extension; capability `browser-profiles-v1` |

Renames a browser profile or changes its color or icon. An absent field is
unchanged; JSON null clears `color` or `icon`.

Params: `browser_profile` (required), `name`, `color`, `icon`.

Result: `object{browser_profile:BrowserProfile, changed:bool}`

### move-browser-profile

| Field | Value |
| --- | --- |
| name | `move-browser-profile` |
| status | implemented |
| since | protocol 12 additive extension; capability `browser-profiles-v1` |

Moves a browser profile to an insertion index among browser profiles.

Params: `browser_profile`, `index` (both required).

Result: `object{browser_profile:BrowserProfile, changed:bool}`

### delete-browser-profile

| Field | Value |
| --- | --- |
| name | `delete-browser-profile` |
| status | implemented |
| since | protocol 12 additive extension; capability `browser-profiles-v1` |

Deletes a browser profile record; `default` is refused. Every
`personal_workspaces.browser_profile_id` and room `browser_profile_id` naming
it is cleared in the same commit. With `bookmarks-v1` the same commit deletes
the profile's bookmarks, reports their number in `deleted_bookmarks`, and,
when there were any, emits `bookmarks-changed`. The app moves its tabs and
removes its engine data.

Only a person deletes a browser profile: the command needs the verified
cmux app connection (origin `user`, request-origin.md), always. Any
other connection (an agent, a script, the CLI, a page relay) gets
`error_code: "origin.forbidden"` and nothing changes. The app runs it only
after the person's own palette, menu, keyboard or Settings click and the
confirmation sheet.

Params: `browser_profile` (required).

Result: `object{browser_profile:string, cleared_workspaces:[object{session_id:string, workspace_key:string}], cleared_rooms:[string], deleted_bookmarks?:usize}`

### list-bookmarks

| Field | Value |
| --- | --- |
| name | `list-bookmarks` |
| status | implemented |
| since | protocol 12 additive extension; capability `bookmarks-v1` |

Bookmark commands (plans/cmux-next/bookmarks.md sections 1 and 2.1) store
one bookmark tree per browser profile in the home session. Every
daemon serves them; the app writes them only on its home session. The two
roots, the Bookmarks Bar (`bar`) and Other Bookmarks (`other`), are reserved
`parent` values, not nodes. Each change bumps the session's
`bookmarks_revision` (separate from `personal_revision`) and emits
`bookmarks-changed`; an unchanged retry emits nothing.

Shapes:

```text
Bookmark = object{id:string, browser_profile_id:string, parent:string, kind:"url"|"folder", index:usize, title:string, url?:string, favicon_key?:string, source_key?:string, created_ms:uint64, last_used_ms?:uint64, icon?:string}
ImportNode = object{kind:"url"|"folder", title:string, url?:string, created_ms?:uint64, children?:[ImportNode]}
```

A null optional field is omitted. A bookmark id is `bm_` and 32 lowercase hex
digits; the request field that names one is `bookmark`, because the request
envelope owns `id`. `parent` is `bar`, `other`, or a folder of the same
profile. `index` is a dense 0-based position among the node's siblings.
`title` is at most 4096 UTF-8 bytes without NUL and may be empty. `url` is
required for a `url` node and refused for a folder: an absolute URL (it has a
scheme), at most 65536 bytes, without control characters. `favicon_key` and
`source_key` are at most 4096 bytes without control characters; only a folder
carries `source_key`. With `bookmark-icon-v1` a folder may carry `icon` (see
"Icon values" under `put-blob`); a `url` node never does, and the `bar` and
`other` roots are not nodes, so they have none. Times are
milliseconds since the Unix epoch, at most `i64::MAX`. A node one level under
a root has depth 1; no node is deeper than 64, and a profile holds at most
100,000 nodes. Nodes never move between profiles. The browser profile must
exist (`list-personal.browser_profiles`).

Errors carry `error_code`: `invalid_params` for a bad id, parent, kind, URL,
icon, size, cycle, limit or idempotency key, `unknown_icon_asset` for an asset
icon the blob store does not hold, and `not_found` for an unknown bookmark or
browser profile. A rejected command changes nothing.

Every mutation (`create-bookmark`, `update-bookmark`, `move-bookmark`,
`delete-bookmark`, `import-bookmarks`) is one typed op and takes an optional
idempotency key: `origin` and `mutation_id`, both or neither, following the
durable mutation envelope's identifier rules. The daemon looks the key up
before anything else and stores it with the op's result in the op's
transaction. A retry with the same key and request returns the original
result with `replayed:true`, writes nothing and emits nothing; the same key
with another request is refused with `invalid_params`. The daemon keeps the
replay records of the last 10,000 keyed ops; a key older than that, or a
key whose op was refused, runs as a new op. Every mutation result carries
`replayed:bool`.

Params: `browser_profile_id` (required).

Result: `object{bookmarks_revision:uint64, bookmarks:[Bookmark]}`

`bookmarks` is the profile's whole tree in depth-first pre-order: the `bar`
tree, then the `other` tree; each folder is followed by its subtree, and
siblings follow `index`.

### create-bookmark

| Field | Value |
| --- | --- |
| name | `create-bookmark` |
| status | implemented |
| since | protocol 12 additive extension; capability `bookmarks-v1` |

Creates a URL or folder node. `index` is the insertion position among the
parent's children, clamped; absent appends. `created_ms` defaults to now.
`bookmark` is the new node's id (generated when absent); an existing id
returns the stored node unchanged with `changed:false`, so a retry is
idempotent.

Params: `browser_profile_id`, `parent`, `kind`, `title` (required); `index`,
`url`, `favicon_key`, `source_key`, `created_ms`, `bookmark`, `origin`,
`mutation_id`.

Result: `object{bookmark:Bookmark, changed:bool, replayed:bool}`

### update-bookmark

| Field | Value |
| --- | --- |
| name | `update-bookmark` |
| status | implemented |
| since | protocol 12 additive extension; capability `bookmarks-v1` |

Changes a node's title, URL (`url` nodes only), favicon key, last use or icon
(folders only, capability `bookmark-icon-v1`). An absent field (or a null
`title` or `url`) is unchanged; JSON null clears `favicon_key`,
`last_used_ms` or `icon`. `icon` on a `url` node, null included, is refused
with `invalid_params`. An asset icon must name a stored blob of the matching
kind, checked in the update's transaction. A request that changes nothing
(the same icon again, say) returns `changed:false` and emits nothing.
`create-bookmark` and `import-bookmarks` take no icon; a replacing import
keeps its folder's icon.

Params: `bookmark` (required), `title`, `url`, `favicon_key`, `last_used_ms`,
`icon`, `origin`, `mutation_id`.

Result: `object{bookmark:Bookmark, changed:bool, replayed:bool}`

### move-bookmark

| Field | Value |
| --- | --- |
| name | `move-bookmark` |
| status | implemented |
| since | protocol 12 additive extension; capability `bookmarks-v1` |

Moves a node and its subtree under `parent` in the same profile. `index` is
the node's final position among the destination's children after the move,
clamped, in the same parent too. A folder cannot move into itself or a
descendant, and the move must keep every node within depth 64.

Params: `bookmark`, `parent`, `index` (required); `origin`, `mutation_id`.

Result: `object{bookmark:Bookmark, changed:bool, replayed:bool}`

### delete-bookmark

| Field | Value |
| --- | --- |
| name | `delete-bookmark` |
| status | implemented |
| since | protocol 12 additive extension; capability `bookmarks-v1` |

Deletes a node and its whole subtree; the node's later siblings close the gap.

Params: `bookmark` (required); `origin`, `mutation_id`.

Result: `object{deleted:[string], replayed:bool}`, the deleted node's id
first, then its descendants.

### import-bookmarks

| Field | Value |
| --- | --- |
| name | `import-bookmarks` |
| status | implemented |
| since | protocol 12 additive extension; capability `bookmarks-v1` |

Writes an imported tree in one transaction, so a rejected node writes
nothing. `nodes` become new nodes at `parent`, starting at the insertion
position `index` (clamped; absent appends); `created_ms` defaults to now.
`nodes[0]` carries `source_key` when it is a folder.

With `replace:true`, `source_key` is required and `nodes[0]` must be a folder.
When the profile has a folder carrying that `source_key`, the folder keeps its
id, parent, position and icon, takes `nodes[0]`'s title and children (its old
subtree is deleted), and `nodes[1..]` are inserted right after it. Otherwise
the import proceeds as without `replace`. When several folders carry the
`source_key`, the oldest by `created_ms` is refilled. The HTML import and the onboarding
import use this so a re-import replaces its folder.

The request line is subject to the JSON nesting limit (128), which bounds one
import to about 60 nested levels; import a deeper tree in parts.

Params: `browser_profile_id`, `parent`, `nodes` (required); `index`,
`source_key`, `replace` (default false), `origin`, `mutation_id`.

Result: `object{root_ids:[string], count:usize, replayed:bool}`: the ids of the top-level
nodes written (in replace mode the kept folder first), and the number of
nodes in `nodes`, descendants included.


### put-blob

| Field | Value |
| --- | --- |
| name | `put-blob` |
| status | implemented |
| since | protocol 12 additive extension; capability `icon-assets-v1` |

Stores one asset for icons in the home session's blob store. `media_type` is
`image/png`, `image/jpeg`, `image/webp` or `image/svg+xml`; `data` is the
asset in standard base64. A PNG, JPEG or WebP is at most 262144 bytes and
must start with its format's signature (the declared type alone is not
trusted); its bytes are stored as given. An SVG is at most 65536 bytes before
and after sanitizing: the daemon parses it as XML, keeps only an allowlist of
shape, paint-server, clip and mask elements and their geometry, paint and
transform attributes, keeps `href` and `xlink:href` only when they start with
`#`, requires every `url()` to name `#id`, drops scripts, styles, event
attributes, foreign content, images, links, animation, text, comments,
processing instructions, CDATA and the DOCTYPE, refuses any entity other than
the five predefined ones, and stores the re-serialized document. A blob is
keyed by the SHA-256 of its stored bytes, so the same asset again returns the
same result and only refreshes the blob's age.

The store keeps at most 67108864 bytes. A blob that no icon field names and
that nobody put for 7 days is deleted by a sweep at daemon start and before
each new put; a new put that does not fit after that sweep is refused.

Params: `media_type`, `data` (required).

Result: `object{ref:string, icon:string, media_type:string, size:usize}`:
`ref` is `blob:sha256-<64 lowercase hex>` and `icon` is the icon value that
names the asset (`image:sha256-<hex>` or `svg:sha256-<hex>`).

Errors carry `error_code` `invalid_params` (media type, base64, size,
signature, or a refused SVG) or `asset_store_full`.

Icon values: the workspace, screen, saved screen group member, room, browser
profile, workspace status entry, tab, personal workspace group, bookmark
folder (`bookmark-icon-v1`) and session (`session-icon-v1`) icon fields take an SF Symbol name
(lowercase letters, digits and dots, at most 128 bytes), exactly one emoji
(at most 32 bytes), `image:sha256-<64 lowercase hex>` or
`svg:sha256-<64 lowercase hex>`. A command that sets an asset icon value
requires the store to hold that blob with a matching media type (a raster
type for `image:`, `image/svg+xml` for `svg:`); otherwise it is refused with
`error_code` `unknown_icon_asset` (the v2 `workspace_group.update` refuses it
as `validation.invalid`). When the store is full, a put first deletes unreferenced
blobs older than 10 minutes, so a client sets the icon soon after its put.
An older daemon (before `icon-assets-v1`) refuses asset icon values: after a
downgrade, a stored asset icon makes that daemon refuse writes to the table
that holds it (downgrade is not supported for this data).

### get-blob

| Field | Value |
| --- | --- |
| name | `get-blob` |
| status | implemented |
| since | protocol 12 additive extension; capability `icon-assets-v1` |

Returns one stored asset. `blob` is a `ref` (`blob:sha256-<hex>`) or an asset
icon value (`image:sha256-<hex>`, `svg:sha256-<hex>`). An icon value whose kind
does not match the stored asset (`svg:` for a raster) is `not_found`.

Params: `blob` (required).

Result: `object{ref:string, icon:string, media_type:string, size:usize, data:string}`
with `data` in standard base64. Errors carry `error_code` `invalid_params` (a
malformed `blob`) or `not_found`.


### conversation-list

| Field | Value |
| --- | --- |
| name | `conversation-list` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-conversations-v1` |

Lists the local conversations (plans/cmux-next/home.md sections 1 and 2),
newest `updated_at` first. The local conversation owner is its own store,
`conversations.sqlite3` in the session state directory (in memory for an
in-memory session), next to the workspace registry. Every `conversation-*`
command is accepted on trusted local (Unix-classified) connections; with
`ws-conversations-v1` also on authenticated WebSocket connections as
`user_local`, except `conversation-bind`, `conversation-agent-token`,
`conversation-import` and the attachment commands, which stay Unix-only.

```text
Participant = object{id:string, kind:"human"|"agent", display_name:string, agent_class?:"mux"|"agent", acp_session?:string}
PartRef = object{message_id:string, part_index:uint32}
TextRun = object{start:uint32, length:uint32, mention?:string, link?:string}
Part = object{type:"text", text:string, runs?:[TextRun]} | object{type:"work", session:string, host?:string, status:"running"|"done"|"failed"|"waiting", preview?:string} | object{type:"attachment", hash:string, name:string, mime_type:string, byte_count:uint64, width?:uint32, height?:uint32, duration_ms?:uint64, poster?:DerivedImage, preview?:DerivedImage} | Question | object{type:"link_preview", url:string, title?:string, site?:string, image?:DerivedImage}
Question = object{type:"question", harness:"claude"|"codex"|"acp"|"chief", session:string, permission?:string, agent?:string, items:[QuestionItem], state:QuestionState}
QuestionItem = object{id:string, header?:string, prompt:string, options:[object{id:string, label:string, detail?:string, preview?:object{text:string, format:"monospace"|"markdown"}}], multi_select:bool, allows_other:bool}
QuestionState = object{kind:"pending"} | object{kind:"cancelled"} | object{kind:"answered", answer:QuestionAnswer}
QuestionAnswer = object{selections:map<string, object{option_ids:[string], other?:string}>, respondent?:object{participant:string, display_name:string, device?:string, remote:bool}, answered_at?:string}
DerivedImage = object{hash:string, mime_type:"image/jpeg"|"image/webp", byte_count:uint64}
Reaction = object{author:string, part_index:uint32, kind:object{tapback:"love"|"like"|"dislike"|"laugh"|"emphasize"|"question"}|object{emoji:string}, at:string}
Message = object{id:string, conversation:string, seq:uint64, client_msg_id:string, author:string, parts:[Part], reply_to?:PartRef, thread_root?:string, thread?:ThreadState, answers?:[string], answers_pending?:[string], created_at:string, edited_at?:string, retracted_at?:string, reactions:[Reaction]}
ThreadState = object{title?:string, owner?:string, resolved?:object{by:string, at:string, seq:uint64}}
Summary = object{id:string, owner:"local", title:string, participants:[Participant], last_seq:uint64, rev:uint64, created_at:string, updated_at:string, last_message?:Message, read_cursors:map<string,uint64>}
```

Ids are `conv_` or `msg_` plus 26 Crockford base32 characters, assigned by
the owner. Participant ids are `user_<id>` (humans) or `agent_<name>`
(agents). Times are RFC 3339 UTC with milliseconds. Text run offsets are
UTF-16 code units. `seq` is 1-based and dense per conversation; `rev`
increases by exactly one per committed op (a new conversation has `rev` 1).

Params: none.

Result: `object{conversations:[Summary]}`. With `conversation-inbox-state-v1`
each item also carries the CALLER's own list state of it (never another
participant's): `pinned:bool`, `pin_position?:uint64` (while pinned) and
`marked_unread:bool` (see `conversation-inbox-op`).

### conversation-create

| Field | Value |
| --- | --- |
| name | `conversation-create` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-conversations-v1` |

Creates a conversation. The actor (the connection's principal; an `actor` param, when given, must equal it) must be one of the 1-64 `participants`;
`title` has 1-200 characters. A retry with the same `idempotency_key` and the
same request returns the conversation it created with `replayed:true`; the
same key with a different request is rejected with `idempotency_conflict`. A
new conversation publishes `conversation-changed` with change kind
`conversation`.

Params: `idempotency_key`, `actor`, `title`, `participants` (all required).

Result: `object{conversation:Summary, replayed:bool}`

### conversation-snapshot

| Field | Value |
| --- | --- |
| name | `conversation-snapshot` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-conversations-v1` |

Returns the summary and the last `tail` (1-500) messages in ascending seq.

Params: `conversation`, `tail` (both required).

Result: `object{conversation:Summary, messages:[Message]}`

### conversation-history

| Field | Value |
| --- | --- |
| name | `conversation-history` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-conversations-v1` |

Returns up to `limit` (1-500) messages with seq below `before_seq`, the
newest of them, in ascending seq.

Params: `conversation`, `before_seq`, `limit` (all required).

Result: `object{messages:[Message], threads?:[ThreadSummary]}`. With
`conversation-thread-v1`, `threads` holds the stats of each message in the
page that is a thread root with at least one reply (with
`conversation-thread-objects-v1`, or a `thread` object), in page order;
`conversation-snapshot` carries the same field for its `messages`.

### conversation-thread

| Field | Value |
| --- | --- |
| name | `conversation-thread` |
| status | implemented |
| since | protocol 12 additive extension; capability `conversation-thread-v1` |

Returns thread root `root` and up to `limit` (1-500, default 50) of its
replies with seq above `after_seq` (default 0), in ascending seq. Trusted
local connections only (a paired remote device is refused). A root that is
unknown, in another conversation or itself a thread reply is refused with
`conversation_rejected` `unknown_message`. Stats are computed at read time
over the replies that are not retracted: a retracted reply stays in `replies`
(the client shows it as deleted) but does not count in `reply_count`,
`last_reply_seq`, `last_reply_at` or `authors`.

Params: `conversation`, `root` (required); `after_seq`, `limit` (optional).

Result: `object{root:Message, replies:[Message], has_more:bool, thread:ThreadSummary}`
where `ThreadSummary` is `object{root, reply_count, last_reply_seq|null,
last_reply_at|null, authors:[participant id]}` (`authors`: the first 3
distinct reply authors by seq). With `conversation-thread-objects-v1` it
also has `status` (`open` | `resolved`) and, from the root's `thread`,
`title?` and `owner?`; `status` is `resolved` only while the root's
`thread.resolved.seq` is at least `last_reply_seq` (a live reply after the
resolution reopens the thread), and then `resolved_by` and `resolved_at` name
who resolved it and when.

### conversation-link-resolve

| Field | Value |
| --- | --- |
| name | `conversation-link-resolve` |
| status | implemented |
| since | protocol 12 additive extension; capability `conversation-tree-v1` |

Opens a permalink. Every conversation and message has one stable link:
`<scheme>://conversation/<conversation id>` and
`<scheme>://conversation/<conversation id>/message/<message id>`, where the
scheme is the build's link scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`; any
cmux build's scheme is accepted, and an id this owner does not have is
`unknown_conversation`). A query or fragment is ignored, so a link never carries a command. Every UI
(the Messages Home, the Channels page, the CLI) copies links in this form and
opens them through this command. Trusted local connections only. A `url` that
is not such a link (or is longer than 512 bytes) is a bad request; an unknown
conversation is `conversation_rejected` `unknown_conversation`; a message
that is unknown or in another conversation is `unknown_message`.

Params: `url` (required).

Result: `object{url, conversation:Summary, message?:Message, thread_root?,
path:[message id], truncated?:bool}`. `url` is the canonical link.
`thread_root` is the message's top thread root (absent when the message is not
in a thread). `path` runs from the thread root down to the message, both
included, along `reply_to` parents in the thread (a parent outside the thread
steps straight to the root): `[message]` for a message not in a thread, empty
for a conversation link. A path longer than 256 starts below the root and sets
`truncated`.

### conversation-inbox-op

| Field | Value |
| --- | --- |
| name | `conversation-inbox-op` |
| status | implemented |
| since | protocol 12 additive extension; capability `conversation-inbox-state-v1` |

Sets the caller's own list state of one conversation: a pin with its
position, or a "marked unread" flag. The same op shapes as the Cloud owner's
person inbox (`inbox.pin`, `inbox.mark_unread`): `op` is
`{kind:"inbox.pin", pinned:bool, position?:uint64}` or
`{kind:"inbox.mark_unread", unread:bool}`. The actor is the connection's
principal (a person, or an agent such as a Chief: each participant keeps its
own state) and must be a participant (`conversation_rejected`
`not_participant`; an unknown conversation is `unknown_conversation`). This is
not a conversation op: the state is kept beside the conversation (no `rev`,
no `conversation-changed`, no idempotency ledger; values are absolute, so a
retry writes the same state), and only the participant reads it (its
`conversation-list` items and its connections' `conversation-inbox-changed`
events). A pin without `position` keeps an existing position, else goes after
the participant's last pin. `position` is at most 2^53-2. Clients that merge
local and Cloud pins send the pin time in milliseconds as `position`, so one
list orders both owners' pins by when they were pinned. Unpinning drops the
position; marking read does not move the read cursor (a client sends
`read_cursor.set` too). Trusted local connections only; cmux-mobile-host's
`chief` channel relays `inbox.pin` and `inbox.mark_unread` (never `inbox.mute`)
for the owner's paired iPhone, for a conversation in that channel's scope only.

Params: `conversation`, `op` (both required).

Result: `object{conversation, participant, pinned:bool, pin_position?:uint64,
marked_unread:bool}` (the new state).

### cloud-inbox-op

| Field | Value |
| --- | --- |
| name | `cloud-inbox-op` |
| status | implemented |
| since | protocol 12 additive extension; capability `conversation-inbox-state-v1` (with `cloud-conversations-v1`) |

The Cloud form of `conversation-inbox-op`: forwards `inbox.pin`,
`inbox.mark_unread` (the same `op` shapes) or `inbox.mute`
(`{kind:"inbox.mute", muted:bool, until?:uint64}`, `until` in Unix ms; the
owner refuses an `until` in the past; approvals still notify a muted
conversation) for one conversation to the
person's UserDO inbox with the client's `idempotency_key` (`POST /v1/ops`) and
answers from a worker thread with the `cloud-conversation-op` reply shape
(`value` is the inbox entry). Other kinds are refused before anything is sent
(`cloud_conversation_rejected`, `reason` `unsupported_op`). Only the person's
clients send it: the verified cmux app, or an authenticated page with
`ws-cloud-conversations-v1`; any other connection gets `forbidden`. The
change comes back as `cloud-inbox-changed`.

Params: `conversation`, `idempotency_key`, `op` (all required).

Result: `object{value, replayed, transaction, stream, sequence}`.

### home-inbox

| Field | Value |
| --- | --- |
| name | `home-inbox` |
| status | implemented |
| since | protocol 12 additive extension; capability `home-inbox-v1` |

The Home list as the caller sees it, over the local conversations and the
person's Cloud inbox (through this daemon's Cloud lease, as `cloud-inbox-list`): the owner
derives each row once, so every view (the Messages view, the Channels page,
the CLI) shows the same list. A read model: it adds facts to the
`conversation-list` summaries and changes nothing. Trusted local connections
only, never a relayed remote device; the caller is the connection's principal.
The one relay is cmux-mobile-host's `chief` channel for the Mac owner's paired
iPhone: it forwards only `owners: ["local"]` and drops every row outside that
channel's scope (conversations between the owner and agents;
`cmux-next-ios/rust/crates/cmux-mobile-host/src/chief_policy.rs`).

Rules. `kind`: a conversation with one other participant is `chief` (that
participant is an agent of class `mux` or one the Chief registry knows) or `direct`, except a titled later
conversation with the same one participant as an older one (by `created_at`,
then id), which is a `channel`; any other conversation is `channel` when it has
a title, else `group`. `name`: a `chief` row's Chief's current registry name
(`chief.profile`), else the title, else the other participants' display names
(a Chief with none is "Chief") joined by ", ". `unread`: `last_seq` minus the caller's read cursor, 0 when the
caller wrote the last message. `activity_at`: the last message's `created_at`
(a deleted message too), else `updated_at`. `preview`: the last message's text
parts joined by a space (else its attachment names joined by ", "), at most 200
characters, absent for a deleted message. `chief_state` (a `chief` row only):
`working` while the Chief types (its posted message ends its typing), while one
of its runs (`conversation-runs-v1`) runs (status `running`, started in the last
day, written in the last 30 minutes), or when its last message's `work` part is
`running`; `waiting` when that part is `waiting`; else `idle`. A Chief's live
reply text (`conversation-draft`) is not stored, so a view that shows it adds
that state itself. `pinned`,
`pin_position` and `marked_unread` are the caller's own list state
(`conversation-inbox-state-v1`). Order: pinned rows by `pin_position` (none
last), then by `activity_at` newest first; ties by id ascending.

Cloud rows come from the person's Cloud inbox entries (the Cloud owner keeps
their counts, preview and the person's pins and marks): a removed or archived
entry is not a row; `dm` is `direct`, a `group` is a `channel` when it has a
title; `name` is the title, else "Chief" for a `chief` entry, else the direct
peer's id (the view names people from the conversation); `chief` is the peer of
a `chief` entry; `muted` is the person's Cloud mute (until `muted_until`); a
Cloud row has no `last_author` and no `chief_state`. One page of the Cloud
inbox comes (its newest 200 entries); a malformed entry is skipped. Local and
Cloud rows share one order (a time's fraction counts as three digits); the two
owners number their pins separately, so pinned rows of both owners mix by
number. A view keys rows by `(owner, id)`.

Params: `owners?:[local|cloud]` (default both). In the app the local
conversations' owner and the daemon that holds the person's Cloud lease can be
two daemons: a view asks each for its own owner.

Result: `object{me, rows:[HomeInboxRow], cloud}`. `me` is the caller's participant
id (local). `cloud` is `included`; `signed_out` when this connection is not the
person with the app's lease (only the verified app and the person's
authenticated page get Cloud rows), or there is no lease or no Cloud here;
`unavailable` when the Cloud did not answer; or `not_asked`. The local rows come
in every case. `HomeInboxRow`: `{id, owner:local|cloud, kind:chief|direct|channel|group, name, unread,
activity_at, preview?, last_author?, chief?, chief_state?:working|waiting|idle,
pinned, pin_position?, marked_unread, muted}`. A view reads the conversation itself
(participants, title) from `conversation-list` or `conversation-snapshot`, and
asks again (coalesced) on `conversation-changed`, `conversation-inbox-changed`,
`conversation-typing`, `conversation-run-changed` and `chief-changed`. A pinned
row without a position sorts after the pinned rows that have one.

### conversation-search

| Field | Value |
| --- | --- |
| name | `conversation-search` |
| status | implemented |
| since | protocol 12 additive extension; capability `conversation-search-v1` |

Home-only search with the read model the cloud owner shares
(`backend/packages/home-core/conformance/conversation-search-cases.json`):
a case-insensitive substring (lower case per code point) of the text parts
of every message that is not retracted, in the conversations where the
caller's principal is a participant. Work cards are not searched. `query`
is trimmed, 1-200 characters, no control characters; `limit` is 1-100.
Hits are ordered newest `created_at` first, then conversation id, then seq
descending. An edit or a retraction changes the results with its own commit.

Params: `query`, `limit` (both required).

Result: `object{hits:[{conversation, title, seq, message_id, author,
created_at, snippet}]}`. `snippet` is the message text (text parts joined by
one space, whitespace collapsed), or 120 characters of it centered on the
match with `…` where it is cut.

Errors: `error_code` `conversation_rejected` with `reason` `invalid_query` or
`invalid_limit`.

### history-search

| Field | Value |
| --- | --- |
| name | `history-search` |
| status | implemented |
| since | protocol 12 additive extension; capability `history-search-v1` |

One query over the daemon's history search index: agent chat messages,
terminal commands and scrollback lines, and tab and workspace names, in one
SQLite file on this machine that is never synced. A background worker fills
it from the binary's feeds in bounded steps; a query reads its own
connection and never waits for that worker. Trusted local connections only.

Every word of `query` must match. Words of three or more characters match
anywhere in the text, folding case and diacritics; a query of only shorter
words matches tab and workspace names. Hits are newest first.

Params: `query` (required; trimmed, 1-200 characters, no control
characters), `kinds` (optional; any of `chat`, `command`, `scrollback`,
`tab`, `workspace`; absent or empty means every kind), `limit` (optional;
1-100, default 20).

Result: `object{hits:[{key, kind, target, position, title, snippet,
highlights:[{start, end}], at_ms}], took_us}`. `target` and `position` name
the jump: a chat session and its turn, a terminal and its line, or a tab or
workspace id with `position` null. `snippet` is the text around the match
and `highlights` are UTF-16 offset ranges of the matched words in it.
`took_us` is the query's time in the daemon.

Errors: `history search requires a trusted local connection`, `history
search is unavailable` (no index installed), and `bad request: ...` for an
invalid `query`, `kinds` or `limit`.

### conversation-op

| Field | Value |
| --- | --- |
| name | `conversation-op` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-conversations-v1` |

Applies one op, validated by the pure `cmux-conversation` reducer. The write,
the new `rev` and the idempotency ledger row commit in one SQLite
transaction; `conversation-changed` is published only after the commit and
carries the request's `transaction`. A replay with the same
`idempotency_key` and the same `actor` and `op` returns the stored result
with `replayed:true` and publishes nothing. `op` is tagged by `kind`:

| kind | fields | rule |
| --- | --- | --- |
| `message.send` | `client_msg_id, parts, reply_to?, thread_root?, answers?, answers_pending?` | `idempotency_key` equals `client_msg_id`; 1-16 parts, at most 64 KiB of text; `reply_to` names an existing part; `thread_root` names a message of this conversation that has no `thread_root` itself (`invalid_thread_root` otherwise; `thread_root` is always the top root of the thread tree), and the new message carries it; with `conversation-tree-v1` threads nest without a limit: `reply_to` is the parent, a `thread_root` sent with `reply_to` must be the parent itself or the parent's own `thread_root` (`invalid_thread_root` otherwise), and a send with a `reply_to` parent in a thread and no `thread_root` gets the parent's `thread_root`, so a reply of a reply stays in its thread (for every sender of the local owner: this command, the v2 `conversation.send`, and paired devices); when the sender's read cursor was at the conversation's last seq before the send, the send moves it to the new message's seq, so no client counts its own messages as unread; a sender behind the last seq keeps its cursor, so a message it has not read stays unread (cx-59n8.4); `answers` names at most 64 distinct message ids this reply answers (an agent's turn reply; `cmux chief -p` prints the replies that answer its message), `answers_pending` the ids of `answers` whose subagents still work; a malformed list is `invalid_parts` |
| `message.edit` | `message_id, parts` | author only; not retracted |
| `message.retract` | `message_id` | author only; parts and reactions become empty |
| `reaction.add` / `reaction.remove` | `message_id, part_index, reaction` | `reaction` is a reaction `kind` object; one per (author, part, kind) |
| `read_cursor.set` | `seq` | the actor's own cursor; monotonic; at most `last_seq` |
| `participants.add` | `participant` | id unique; at most 64 participants |
| `title.set` | `title` | 1-200 characters |
| `thread.update` | `root, title?, status?, owner?` | with `conversation-thread-objects-v1`; any participant (a person or an agent); `root` names a message of this conversation (`unknown_message`) that is not a thread reply (`invalid_thread_root`); at least one of `title`, `status`, `owner` (`invalid_thread_update`); `title` is 0-200 characters with no control characters (`invalid_title`), empty clears it; `owner` is a participant id, never a pending invited address of a Cloud owner (`invalid_thread_owner`), empty clears it, and an owner who later leaves stays named until an update changes it; `status` `resolved` stores `resolved {by: actor, at: now, seq: last_seq}`, `open` clears it; the root's `thread` object holds the result (absent when empty); `updated_at` stays; the change is `message-updated` with the root |
| `question.answer` | `message_id, part_index, answer` | human participants only (`human_only`); the part is a pending question (`question_closed` otherwise); every item answered with known options, one choice on single select, `other` only where `allows_other` (`invalid_answer`); the owner stamps `respondent` (a paired device answers as its person, `remote:true`) and `answered_at` |

A `question` part (plans/cmux-next/agent-questions.md) is sent only by an
agent and only as `pending`. A `message.edit` keeps every question part at
its index with the same content; it may only move a pending question to
`cancelled`.

Rejects use `error_code` `conversation_rejected` with the reason as the
error text: `not_participant`, `not_author`, `unknown_message`,
`invalid_parts`, `idempotency_conflict`, `cursor_regression`,
`unknown_conversation`, `cursor_out_of_range`, `retracted`,
`invalid_client_msg_id`, `invalid_part_index`, `duplicate_reaction`,
`unknown_reaction`, `invalid_reaction`, `duplicate_participant`,
`invalid_participant`, `invalid_title`, `human_only`, `question_closed`,
`invalid_answer`, `invalid_thread_root`, `invalid_thread_update`,
`invalid_thread_owner`. A malformed request (an unknown op
kind, a bad `transaction` or idempotency key) is a plain bad request.

Params: `conversation`, `idempotency_key`, `op` (required), `actor` (optional; the owner stamps the connection's principal and refuses a different value with `actor_mismatch`),
`transaction`.

Result: `object{transaction?:string, rev:uint64, seq?:uint64, replayed:bool, change:Change}`, where `seq` is the seq of the message the op created or changed and `Change` is the `change` object of `conversation-changed` (events.md).

### conversation-typing

| Field | Value |
| --- | --- |
| name | `conversation-typing` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-conversations-v1` |

Publishes `conversation-typing` for a participant. Typing is never stored and
does not change `rev`.

Params: `conversation`, `on` (required), `actor` (optional, as for `conversation-op`).


### conversation-draft

| Field | Value |
| --- | --- |
| name | `conversation-draft` |
| status | implemented |
| since | protocol 12 additive extension; capability `conversation-draft-v1` |

Publishes a draft of a bound agent participant's running reply: the same
admission (an agent participant of the conversation, replay and rate gate,
text limit) and the same `conversation.events` draft item as the
`conversation.draft` operation of `resource-api-v2.md`. Drafts are never
stored and do not change `rev`; on the raw `subscribe` stream they go only
to a connection that echoed `conversation-draft-events-v1` in
`set-client-info` (the `conversation-draft` event). The
connection's principal (`conversation-bind`) is the participant.

Params: `conversation`, `turn`, `segment`, `seq`, `kind` (`talk` or
`thought`), `text`, `fresh`, `done` (required); `truncated`, `harness`
(optional).

Result: `object{published:boolean}`; `published` false is a replay.


### conversation-bind

| Field | Value |
| --- | --- |
| name | `conversation-bind` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-conversations-v1` |

Binds the connection to agent `participant` for its lifetime, proven by the
token `conversation-agent-token` minted. Writes on the connection then carry
that principal as their actor. An unbound trusted local connection is
`user_local`. With `conversation-person-credentials-v1`, `participant` may
also be a person other than `user_local` (a `user_` id); `user_local` and
`remote_` devices are refused.

Params: `participant`, `token` (required).

Result: `object{participant:string}`


### conversation-agent-token

| Field | Value |
| --- | --- |
| name | `conversation-agent-token` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-conversations-v1` |

Mints the credential of agent `participant` (an `agent_` id). Only a
connection whose principal is `user_local` may call it. The owner stores the
token's SHA-256; a new token replaces the old one and ends the bindings made
with it. With `conversation-person-credentials-v1`, `participant` may also be
a person other than `user_local` (a `user_` id), never a `remote_` device.
For a Chief record other than `agent_mux` (`chief.profile.create` or
`chief.profile.adopt`), only its brain holds the credential when the daemon
runs a Chief brain supervisor (the supervisor mints it in process; this
command is refused), and on a daemon with no supervisor only the person's own
terminal mints it: a page (WebSocket or the host's page relay), a paired or
remote device and an agent are refused. `chief.profile.adopt` revokes every
credential issued for the participant before the adopt, and `conversation-bind`
checks the credential and binds under one lock, so a revoked credential never
binds after it.

Params: `participant` (required).

Result: `object{participant:string, token:string}`

### conversation-import

| Field | Value |
| --- | --- |
| name | `conversation-import` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-conversations-v1` |

Appends history moved from another store to `conversation` once, keeping each
message's `author`, `created_at` and `id` (the one time the owner keeps them;
plans/cmux-next/home-state-ownership.md section 7). The owner still assigns
every `seq` and one `rev` for the whole import, and commits it in one
transaction. A message whose author and `client_msg_id` (or `id`) the
conversation already holds is skipped, so a retry imports nothing twice.
Refused: a `created_at` that goes backward within the batch, passes the
newest message the conversation holds (`import_out_of_order`), lies in the
future, or is not `YYYY-MM-DDTHH:MM:SS.mmmZ`; an author who is not a
participant (`not_participant`). Only a trusted local connection whose
principal is `user_local` may call it; an agent-bound connection is refused,
and the remote relay never admits it. One `conversation-changed` event
(`change.kind:"conversation"`) follows a commit that imported anything.

Params: `conversation` (required), `messages` (required, in order; each
`{id?, client_msg_id, author, parts, created_at}`).

Result: `object{conversation:ConversationSummary, imported:array<uint64>, skipped:uint64}`

### chief-inspect

| Field | Value |
| --- | --- |
| name | `chief-inspect` |
| status | implemented |
| since | protocol 12 additive extension; capability `chief-inspect-v1` |

The Chief memory inspector's API for the Chief's owner
(plans/cmux-next/optchat-inspector.md, plans/cmux-next/memory-inspector-native-DESIGN.md).
The daemon forwards one line, `{"tool":"inspect","method","path","query"}`, to the brain host's tools
socket named by `CMUX_TUI_CHIEF_TOOLS_SOCKET` (a Unix socket, not a symlink,
owned by the daemon's user) and answers the brain's reply. Only the owner's
trusted connection may call it: a registered Unix client with no link peer
record whose principal is `user_local`, which is a local client or the link's
`owner_session` splice. A link-stamped or relayed (`Remote`), WebSocket,
unregistered or agent-bound connection is refused with `origin.forbidden`
before anything is forwarded, and the remote relay never admits it. `path` must
be a read path, forwarded with `GET` (`/api/status`, `/api/turns`, `/api/turn`,
`/api/node`, `/api/level`, `/api/date`, `/api/search`, `/api/view`,
`/api/memory/changes`), or one of the owner's memory change paths, forwarded
with `POST` (`/api/memory/edit`, `/api/memory/delete`, `/api/memory/undo`; the
brain refuses them to the Chief's own turn and subagent sessions). The reserved
`query` key `chief` names a Chief other than the default (chief-brains-v1): the
request goes to that Chief's brain socket and the key is not forwarded. A reply
line above 5 MiB is refused, never cut.
Every daemon advertises the capability (it speaks the command); without the
environment variable the daemon answers the owner with
`error_code:"chief.not_configured"` and forwards nothing. The daemon reads the variable once at startup and
removes it from its environment, so no terminal shell, agent or hook it spawns
inherits the brain's tools path.

Params: `path` (required), `query` (optional map of strings).

Result: `object{status:uint64, body?:JsonValue, error?:string}` (the brain's
HTTP-like status, its JSON answer, or its reason).

### conversation-attachment-upload

| Field | Value |
| --- | --- |
| name | `conversation-attachment-upload` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-attachments-v1` |

Uploads one attachment's bytes by SHA-256 so a `message.send` may name it in
an `attachment` part (the local counterpart of the cloud owner's upload
intent, home-messaging.md section 10.1). Trusted local connections, and
authenticated WebSocket connections with `ws-attachments-v1`; the caller's
principal must be a participant of `conversation`. Bytes are stored
once by hash in the session state directory (`attachments/`, in memory for an
ephemeral session); each conversation keeps its own record of a hash with
its uploaders. `op` selects the step:

- `begin`: `conversation`, `sha256` (64 lowercase hex), `byte_count`,
  `mime_type`, `name`, and optional `width`, `height`, `duration_ms`, and a
  `poster` (video) or `preview` (image) `{sha256, byte_count, mime_type}`.
  The same allow list, name rule, denied extensions and limits as the cloud
  owner: at most 100 MB per file, a poster at most 2 MB and a preview at most
  512 KB, both JPEG or WebP. Result `object{upload:string|null,
  needs:["original"|"poster"|"preview"], stored:StoredAttachment|null}`: when
  the conversation already holds the hash, `upload` is null, the caller
  becomes an uploader, and `stored` is the kept record (the first record of a
  hash wins).
- `chunk`: `upload`, `piece`, `offset` (exactly the bytes received so far),
  `data` (base64, at most 4 MiB decoded). Result `object{received:uint64}`.
- `commit`: `upload`. Every piece must be complete and match its hash. Result
  `object{stored:StoredAttachment}`.
- `cancel`: `upload`. Result `object{}`.

`StoredAttachment = object{hash:string, mime_type:string, byte_count:uint64,
poster?:DerivedImage, preview?:DerivedImage}`. An upload belongs to the
connection that began it, ends with that connection, and expires after 15
minutes. At most 32 uploads are open at once. A record no message references
is removed after 24 hours, with its bytes when no other record names them.
The store has an advisory 10 GB (decimal) budget across every conversation,
including uploads in flight. A `begin` above that budget logs a warning and
continues. Budget pressure never removes fresh unsent or referenced attachments;
the normal 24-hour sweep still removes abandoned uploads. Filesystem failures,
including a full disk, remain errors when creating, writing or syncing bytes.
Refusals have `error_code` `attachment_rejected` and one of the reasons
`validation_invalid`, `type_refused`, `too_large`, `poster_refused`,
`preview_refused`, `unknown_upload`, `unknown_piece`, `bad_offset`,
`chunk_too_large`, `incomplete`, `hash_mismatch` or `too_many_uploads`;
`unknown_conversation` and `not_participant` are `conversation_rejected`.

A `message.send` or `message.edit` with an `attachment` part commits only
when the conversation holds a record of the hash that the author uploaded or
that a message already references, with the same `mime_type`, `byte_count`
and claimed poster or preview; otherwise it is rejected with
`unknown_attachment` or `attachment_mismatch`.

A `link_preview` part is a link with the preview its sender fetched;
receivers render it from the part and never fetch the URL. `url` is an
`http://` or `https://` URL (scheme case-insensitive) of 1-2048 bytes with a
non-empty host, no user info, and no whitespace, control characters or
backslashes; `title` has 1-300 characters and `site` 1-253, neither with
control characters; otherwise the op is rejected with `invalid_parts`. Its
`image`, when present, is an ordinary attachment the sender uploaded with
`conversation-attachment-upload` (`image/jpeg` or `image/webp`, at most
512000 bytes): it commits under the same record rule as an `attachment`
part's hash (same `mime_type` and `byte_count`), counts as referenced by the
message, and is read with `conversation-attachment-read` by `image.hash`.
The local owner advertises `link_preview` parts with `link-preview-v1`; a
sender checks it first and sends plain text to an owner without it. A
`null` `title`, `site` or `image` is the same as an absent one. A message
with a `link_preview` part counts as an agent turn for the loop guard, as
text does. Paired installs (the remote relay) receive a `link_preview` part
as a text part holding its `url`.

A reader keeps a part of a type it does not know (or one whose fields it
cannot read) as it is and shows or skips it; it never fails the whole
message. The owner refuses such a part on a write with `invalid_parts`.

### conversation-attachment-read

| Field | Value |
| --- | --- |
| name | `conversation-attachment-read` |
| status | implemented |
| since | protocol 12 additive extension; capability `local-attachments-v1` |

Reads stored bytes of an attachment of `conversation`: `hash` (the part's
hash), `variant` (`original` by default, or `poster` or `preview`), `offset`
(default 0) and `length` (default and at most 4 MiB). The caller's principal
must be a participant, and the hash must be referenced by a message of the
conversation or uploaded there by the caller. A part without the variant is
refused with `no_poster` or `no_preview`; an unknown or unusable hash with
`unknown_attachment` (both `attachment_rejected`).

Result: `object{hash:string, mime_type:string, byte_count:uint64,
offset:uint64, data:string, eof:boolean}`: `hash`, `mime_type` and
`byte_count` describe the variant read (a preview's own hash), `data` is
base64.

Trusted local connections, and authenticated WebSocket connections with
`ws-attachments-v1`.

### conversation-attachment-link

| Field | Value |
| --- | --- |
| name | `conversation-attachment-link` |
| status | implemented |
| since | protocol 12 additive extension; capability `ws-attachments-v1` |

A download link to one variant of an attachment of `conversation` (the local
counterpart of the cloud owner's signed download URL): `hash`, `variant`
(`original` by default, or `poster` or `preview`) and an optional `name`, the
file name the download offers (the attachment name rule and denied extensions;
otherwise `attachment_rejected` `validation_invalid`). The caller and the hash follow the
`conversation-attachment-read` rule and refusals. Trusted local and
authenticated WebSocket connections.

Result: `object{path:string, expires_in_ms:uint64}`. `path` is
`/attachments/<token>` on this daemon's WebSocket listener (transports.md, the
listener section): HTTP `GET` or `HEAD`, one byte range per
request, so a browser can show an image or play and seek a video from it. The
token is random, names nothing, lives in memory only and answers for
`expires_in_ms` (10 minutes) or until the daemon restarts, also after the
connection that asked for it closed; every request checks the participant and
the record again. A client asks for a new link when one stops answering (a
video player that seeks after the link ended).

### conversation-run-append, conversation-runs, conversation-run

| Field | Value |
| --- | --- |
| name | `conversation-run-append`, `conversation-runs`, `conversation-run` |
| status | implemented |
| since | protocol 12 additive extension; capability `conversation-runs-v1` |

An agent run is the trajectory of one agent turn as the conversation shows it
to its participants: its tool calls with inputs and outputs, its reply
segments and thought summaries, the files it changed, its pictures and
recordings, and links to its session. The agent that works writes it; it is
not conversation state (no `rev`, no `conversation-changed`, no message, no
corpus case), and it lives beside the reducer head in the same store. A run's
`turn` is the `client_msg_id` of the reply the turn ends with, so a client
shows the run on that reply, and a running run with no reply yet as live work.
Trusted local connections only (Unix, or an authenticated WebSocket with
`ws-conversations-v1`); never the remote relay.

`conversation-run-append` `{conversation, run, steps?}` writes the caller's
own run. The caller's principal must be an agent participant of the
conversation (`conversation_rejected` `unknown_conversation`,
`not_participant`; `run_rejected` `not_agent`), and a run another agent
started is `not_run_author`. `run` is `object{id, turn?, answers?:[message id],
thread_root?, status?:"running"|"done"|"failed"|"cancelled", title?,
started_at?:uint64 ms, usage?:{input?, output?, cache_read?, cache_write?},
cost_usd?:number, model?, harness?, error?, session?:{kind, id, host?},
workspace?}`: `id` and `turn` are 1-128 of `[A-Za-z0-9_.:-]`, `title` one line
of at most 200 characters, `error` at most 2000; an absent field keeps its
value and `""` clears `title` and `error`. A new run starts `running`; the
owner stamps `ended_at` when the status leaves `running` and clears it when a
run goes back to `running`. `steps` (at most 64, at most 1 MiB together, ids
unique in one append) are each `object{id, kind:"talk"|"thought"|"tool"|"note",
status?:"running"|"done"|"failed", text?, truncated?, tool?:{name, kind?,
title?, input?:json, output?, output_truncated?, exit_code?, started_at?,
ended_at?, files?:[{path, old_text?, new_text?, added?, removed?, line?}]},
attachments?:[attachment record], links?:[{label, url}]}`, and replace the step
of the same id whole. `text`, `tool.output` and a step's file texts together
are at most 32 KiB each, `tool.input` at most 16 KiB as JSON; a link is http,
https or a cmux scheme (at most 2048 bytes); an attachment is an `attachment`
part's fields without `type`, checked like a message part's
(`conversation_rejected` `unknown_attachment`, `attachment_mismatch`) and
kept usable while the step names it. A run keeps at most 2000 steps
(`run_full`), and a conversation its newest 200 runs: a new run drops the
oldest finished ones with their steps and attachment references. Any other bad field is `run_rejected` `invalid_run` or a bad
request. Values are absolute, so a retried append writes the same rows.

Result and event: `object{run:Run, steps:[Step]}`, the run after the append
and the steps it wrote. `Run` is the merged summary plus `conversation`,
`author`, `status`, `started_at`, `ended_at?`, `updated_at`, `rev` and
`step_count`; `Step` is the step plus the owner's `seq` (its place, 1-based,
kept when it changes), `at` (when it was first written, ms) and `rev`. `rev`
increases by one for every step written and every summary change, so a step's
`rev` is unique in its run. Each append publishes
`{event:"conversation-run-changed", conversation, run, steps}` on `subscribe`
to the connections that echoed `conversation-runs-v1` in `set-client-info`.

`conversation-runs` `{conversation, turns?:[key], answers?:[key],
before_started_at?, limit?}` answers `{runs:[Run], has_more}`: with `turns` (at
most 200 keys) the runs of those replies. With `answers` (at most 200 message
keys), a local owner advertising `conversation-run-answers-v1` returns runs
whose `answers` include those messages; this exact lookup is for silent runs
whose start predates the visible message window. Otherwise it returns the
newest runs that started before `before_started_at` (`limit` 1-200, default 50).

`conversation-run` `{conversation, run, after_rev?, limit?}` answers
`{run:Run, steps:[Step], has_more}`: the steps written after `after_rev`
(default 0, every step), oldest write first, `limit` 1-500 (default 500). A
client that missed events reads again with the highest `rev` it holds. An
unknown run is `run_rejected` `unknown_run`.

### cloud-conversation-runs, cloud-conversation-run

| Field | Value |
| --- | --- |
| name | `cloud-conversation-runs`, `cloud-conversation-run` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-conversation-runs-v1` |

A Cloud Chief's runs through the daemon, with the same Run and Step JSON as
`conversation-run` (the Cloud owner keeps them with the Chief's brain and
serves them as plain reads to the conversation's members). Same admission
and lease as `cloud-conversation-snapshot`. `cloud-conversation-runs
{conversation, agent, before_started_at?, limit?}` answers the owner's
`{runs, has_more}` of Chief `agent` in the conversation, newest first
(`limit` 1-100). `cloud-conversation-run {conversation, agent, run,
after_seq?}` answers the owner's `{run, steps, has_more}` (steps after
`after_seq`). `agent` is `agent_` and 1-64 letters or digits, `run` is `run_` and 1-15
digits. A run the caller may not see answers like a missing one
(`not_found`). A subscribed conversation's run changes arrive as
`{event:"cloud-conversation-run-changed", conversation, run, steps}` (the
steps that changed) on `subscribe`, only to connections that echoed
`conversation-runs-v1` in `set-client-info`; they are never replayed, so a
client reads the run again after a gap.

### conversation-live-publish, conversation-live

| Field | Value |
| --- | --- |
| name | `conversation-live-publish`, `conversation-live` |
| status | implemented |
| since | protocol 12 additive extension; capability `chief-live-v1` |

A Chief's live run frames: while its run (`conversation-run-append`) is
`running`, the agent streams the text of its talk and thought steps and a
compact "working on" line, the same frames the Cloud Chief brain sends on a
Cloud conversation's socket. The owner keeps only the text so far of each
running run, in memory, so a client that joins or reconnects mid-run reads it;
the run's end frees it. Never stored: not a message, not a run step, not in a
snapshot of the log, never the remote relay or `conversation.events`. Trusted
local connections only.

`conversation-live-publish` `{conversation, frame}` sends one frame of the
caller's own running run. The caller must be an agent participant
(`conversation_rejected` `unknown_conversation`, `not_participant`;
`run_rejected` `not_agent`), the run must exist (`unknown_run`), be its own
(`not_run_author`) and be `running` (`run_not_running`). `frame` is one of:

- `{type:"step.delta", conversation, run, step, kind:"talk"|"thought", seq,
  text, final?:true}`: `text` (1-4096 characters) is appended to the step's
  text; `seq` starts at 0 for each (run, step) and grows by one per frame, so a
  skipped or repeated `seq` is `seq_gap`; `seq` 0 on a step that is streaming
  starts it again (a producer that retried): its text is replaced and the
  clients get the conversation's `run.live` instead of the frame. After a frame
  with `final` the step takes no more frames (`step_final`); its step row with
  the whole text follows on the run, and that row frees the step's live text
  (a later frame of it stays `step_final`). A run streams at most 256 steps
  (`too_many_live_steps`).
- `{type:"run.activity", conversation, run, line, since, at}`: `line` (1-80
  characters, one line) is what the run works on now, newest wins; `since`
  (at most `at`) is when that work began and `at` the frame's time (ms); a
  client shows the elapsed time itself.

Order: before it posts the run's reply message (`message.send` with
`client_msg_id` = the run's `turn`), a producer sends every streaming step's
last frame (`final`; a step whose stream stopped early, its row carrying the
text, has none) and then the run's end (`conversation-run-append` with a
terminal status), so a client sees the reply only after them and the reply
replaces the streaming text with no jump.

`frame.conversation` must be `conversation`, and `run` and `step` are keys
like a run id; any other bad frame is `run_rejected` `invalid_live` or a bad
request. A frame's `author` and `t` are the owner's to set: it stamps the run's
agent on every frame it sends and on each snapshot entry (Cloud run ids repeat
across Chiefs, so clients key live text by conversation, author and run), and
`t` (= `type`) on every frame and snapshot, as the Cloud socket keys its frames. The owner
sends each accepted frame as `{event:"conversation-live", conversation,
frame}` on `subscribe` to the connections that echoed `chief-live-v1` in
`set-client-info`. A run that sent no frame for 30 minutes is dropped from the
buffer, and a conversation keeps at most 16 streaming runs (the least recent
goes first).

`conversation-live` `{conversation}` answers the `run.live` snapshot, the
same answer the Cloud owner gives to `run.live.get`: `{type:"run.live",
conversation, runs:[{run, author, steps:[{step, kind, seq, text, final?}],
activity?:{line, since, at}}]}`, the runs that are `running` now (by run id;
none is an empty array); `final` marks a step whose last frame came. A step's `text` is at most its last 64 KiB (older text is dropped from
the buffer only) and `seq` is its last frame's. A client reads it when it opens
a conversation, after a reconnect, and when it sees a `seq` gap, and replaces
its live text with the answer.

### cloud-conversation-live

| Field | Value |
| --- | --- |
| name | `cloud-conversation-live` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-chief-live-v1` |

A Cloud Chief's live frames through the daemon. The owner's `step.delta`,
`run.activity` and `run.live` frames of a subscribed Cloud conversation (named
by `type`, or `t`) reach the person's connections that echoed `chief-live-v1`
as `{event:"cloud-conversation-live", conversation, frame, account?}`, the
frame unchanged with both `type` and `t`; the daemon keeps none of them.
`cloud-conversation-live {conversation}`, from a subscriber of the
conversation (else `cloud_conversation_rejected` `not_subscribed`), asks the
owner for its `run.live` snapshot on the shared socket (`run.live.get`, sent
once the socket is live); the answer arrives as a `cloud-conversation-live`
event. It answers the subscription's state, like `cloud-conversation-subscribe`.

### cloud-conversation-typing

| Field | Value |
| --- | --- |
| name | `cloud-conversation-typing` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-conversation-typing-v1` |

`cloud-conversation-typing {conversation, on}` says that the lease's
participant (the person, or the Chief of a chief lease) is typing (`on: true`)
or stopped (`on: false`) in a Cloud conversation. The daemon sends the owner's
ephemeral `{t:"typing", on, conversation}` frame on the conversation's shared
socket (the owner takes it from any member's socket); the owner broadcasts it
to the other members as `conversation-typing` and turns it off when the socket
closes. Nothing is stored. While on, the daemon sends it again on each new
socket after a reconnect, and sends it off when the sending connection closes. Any trusted client of the daemon
with the lease may send it while some client subscribes the conversation (a
Chief brain subscribes on one connection and writes on another), else
`cloud_conversation_rejected` `not_subscribed`. The newest state replaces one
that has not gone out yet, and it goes out once the socket is live (within
the socket's poll interval). The owner limits the indicator per participant
(typing.ts `typingGate`) and drops a repeat silently; a sender that is not a
current participant gets `auth.forbidden` on the socket, which ends the
subscription as `forbidden`, as for any other owner refusal of the principal. It answers the
subscription's state, like `cloud-conversation-subscribe`.

The owner's `conversation-typing {conversation, participant, on}` broadcast
of a subscribed conversation (a Cloud Chief's reply, or another person
typing) reaches the person's connections that echoed
`cloud-conversation-typing-v1` as the `cloud-conversation-typing` event
(`events.md`); the others never get it.

### cloud-conversation-presence

| Field | Value |
| --- | --- |
| name | `cloud-conversation-presence` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-conversation-presence-v1` |

`cloud-conversation-presence {conversation, viewing}` says that the sending
connection views a Cloud conversation (`viewing: true`) or stopped. The
lease's person views it while any client of the daemon does, so only a change
of that goes out, as the owner's ephemeral
`{t:"presence.set", conversation, viewing}` frame on the conversation's shared
socket; the owner broadcasts a change of the set to the members as
`conversation-presence`. Nothing is stored. While viewing, the daemon sends it
again on each new socket after a reconnect, and sends `viewing: false` when
the last viewing connection closes or unsubscribes. Any trusted client of the
daemon with the lease may send it while some client subscribes the
conversation, else `cloud_conversation_rejected` `not_subscribed`. The newest
state replaces one that has not gone out yet, and it goes out once the socket
is live. A sender that is not a current participant gets `auth.forbidden` on
the socket, which ends the subscription as `forbidden`. It answers the
subscription's state, like `cloud-conversation-subscribe`.

The owner's `conversation-presence {conversation, participants}` set of a
subscribed conversation reaches the person's connections that echoed
`cloud-conversation-presence-v1` as the `cloud-conversation-presence` event
(`events.md`); the others never get it.

### cloud-attachment-upload, cloud-attachment-read, cloud-attachment-link

| Field | Value |
| --- | --- |
| name | `cloud-attachment-upload`, `cloud-attachment-read`, `cloud-attachment-link` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-attachments-v1` |

A cloud conversation's attachments through the daemon, with the same fields,
steps, results and refusals as `conversation-attachment-upload`,
`conversation-attachment-read` and `conversation-attachment-link`, so a page
handles files the same way for both owners. The cloud owner's attachment
routes need the person's lease and answer no cross-origin request, so the
daemon calls them and carries the bytes. Only the person's own clients with the
app's lease (the verified app, an authenticated page with
`ws-cloud-conversations-v1`) may use them, like every lease command; they run
off the request loop.

- `cloud-attachment-upload` `begin` checks the declaration by the same rules,
  then asks the cloud owner for an upload slot (`POST /v1/home/attachments/intent`).
  A hash the conversation already holds answers `upload: null` and the owner's
  record in `stored`. `chunk` collects the bytes in the daemon (the same
  per-connection, 15-minute upload). `commit` checks every piece against its
  hash, sends the poster or preview to its slot, then the file (through the
  Worker slot, or a presigned PUT and `POST /v1/home/attachments/commit` above
  32 MB), and answers `stored`: the owner's record of the hash (the first
  upload of a hash wins its derived image). No byte of a cloud upload is kept
  after the commit.
- `cloud-attachment-read` reads through a signed URL the owner mints
  (`POST /v1/home/attachments/url`) for the lease's person, kept for 8
  minutes and minted again once when it stops answering (`401`/`403`; a
  second failure is `attachment.forbidden`, a `404` is `attachment.not_found`,
  neither retryable). The result differs from the local read in four points:
  `hash` is the part's hash also for a poster or preview, `mime_type` is the
  type the owner serves (text types as `text/plain`), `length` 0 reads one
  byte, and an `offset` at or past the end is refused with `attachment.range`.
- `cloud-attachment-link` has the owner sign a URL first (its access check),
  then answers a local `/attachments/<token>` path like
  `conversation-attachment-link`; the listener reads the signed URL with the
  app's lease for each request (`404` when the app holds no lease, or a lease
  of another person than the link's). A type off the allow list is served as
  `application/octet-stream`.

Upload slot URLs must be on the lease's API origin; only a presigned object
URL (above 32 MB) may be elsewhere, and then only `https` and not loopback.
Only `content-type`, `content-length`, `if-none-match` and `x-amz-*` headers of
the owner's plan are sent, no request follows a redirect, and the bearer goes
only to the intent, commit and URL calls. A begin that would pass the
daemon's 32 open uploads is refused before the owner is asked for a slot.
`chunk` and `cancel` run in the connection's request loop; `begin` and
`commit` call the cloud. A commit whose cloud send fails drops the bytes; the
page uploads again.

Cloud refusals keep their `cloud_*` error codes and `reason`.

### cloud-participant-avatar-get

| Field | Value |
| --- | --- |
| name | `cloud-participant-avatar-get` |
| status | implemented |
| since | protocol 12 additive extension; capability `participant-avatars-v1` with `cloud-conversations-v1` |

A Cloud participant's picture through the daemon: `cloud-participant-avatar-get
{participant_id, conversation?}` answers the Cloud owner's `participant.avatar.get`
(`{participant_id, avatar}`; `avatar` is `{sha256, media_type, bytes, data}` with
base64 `data`, or null). `participant_id` is a person (`user_`) or a Chief
(`agent_`) id. Same admission and lease as `cloud-conversation-snapshot`. The
person reads their own picture and their Chiefs' pictures; another participant's
picture needs `conversation`, a conversation both are in; any other read is
`selector.not_found`, the same answer as an unknown participant.

### cloud-session-set, cloud-session-clear, cloud-session-status

| Field | Value |
| --- | --- |
| name | `cloud-session-set`, `cloud-session-clear`, `cloud-session-status` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-conversations-v1` |

The trusted local client that signed in to cmux Cloud leases its session to
the daemon: `cloud-session-set {api_base_url, access_token, expires_at,
client_version?}`. The daemon keeps the lease in memory only and never returns
it. `api_base_url` is an `https` origin (`http` only for a loopback host).
`cloud-session-status` returns `object{state:"signed_out"|"active"|"expired",
api_base_url?, expires_at?, participant?}`; `cloud-session-clear` returns
`object{state:"signed_out"}`. `participant` (only for the verified app and,
with `ws-cloud-conversations-v1`, a paired WebSocket connection, while
the app holds a person's lease whose token names `sub` and `aud`) is the
person's Worker user id, `user_` and the first 20 hex digits of
sha256("stack:<aud>:<sub>"): the participant id of the person in cloud
conversations. `cloud-session-set` and `cloud-session-clear` are refused on a
WebSocket connection.

With `cloud-selfhost-v1`, `cloud-session-set {api_base_url, auth: "tailscale",
client_version?}` leases a self-hosted chat server (plans/cmux-next/dm-group-chat-DESIGN.md
4.5) instead of cmux Cloud. `auth` is `"bearer"` (the default, the fields
above) or `"tailscale"`. A tailscale lease carries no `access_token` (a
non-empty one is a bad request) and no expiry (`expires_at` is ignored). Its
`api_base_url` is an `http` or `https` origin whose host is a MagicDNS
`*.ts.net` name, an IPv4 address in `100.64.0.0/10` or an IPv6 address in
`fd7a:115c:a1e0::/48`; any other host, from any connection, is
`cloud_conversation_rejected` with `reason` `unknown_api_origin` (the known
origin list below applies to bearer leases only). The daemon sends no
Authorization header to it on any request or socket: the server identifies the
caller by Tailscale. The lease never expires and never asks for a new one
(`cloud-session-needed` is never sent for it); an HTTP 401 answers
`cloud_unauthenticated` and a socket refused with 401 reports `disconnected`
(`unauthenticated`) and tries again after its backoff. `cloud-session-set` and
`cloud-session-status` answer `object{state, api_base_url, auth: "tailscale"}`
(no `expires_at`), with `participant` (status, the person's clients) once
`cloud-selfhost-info` named the person.

With `cloud-lease-app-only-v1`, a lease that the verified cmux app connection
set (the `frontend` actor: a role-main `client-hello` whose code signature or
install key was proved) belongs to the app. While it exists, `cloud-session-set`
and `cloud-session-clear` from any other connection are refused with
`error_code` `cloud_conversation_rejected`, `reason` `forbidden`,
`retryable` false, and the lease does not change. When no app lease exists
(signed out, or a daemon that only a headless brain uses), any trusted local
connection may set or clear the lease; the app's next `cloud-session-set`
replaces it.

A lease from a connection that is not the app must name a known cmux Cloud
origin (`https://cloud-api.cmux.dev`, `https://cloud-api-staging.cmux.dev`,
the development and staging Workers, a loopback host, or an origin the daemon
operator lists in `CMUX_CLOUD_API_ORIGINS`), else `cloud_conversation_rejected`
with `reason` `unknown_api_origin`. The app never uses a lease another
connection set: for the app, `cloud-session-status` answers `signed_out` and
the lease commands answer `cloud_signed_out` until the app sets its own lease.

While the app's lease exists, `cloud-*` events reach only the app's
`subscribe` stream, never another connection's. Without an app lease they
reach every trusted local `subscribe` stream.

While the app's lease exists it is the human's: every command that uses it
(`cloud-inbox-list`, `cloud-requests-list`, `cloud-conversation-snapshot`, `cloud-conversation-history`,
`cloud-conversation-thread`, `cloud-conversation-op` with any origin,
`cloud-inbox-subscribe`, `cloud-conversation-subscribe`, `cloud-mux-subscribe`,
`cloud-mux-ack`) from another connection is refused the same way and sends
nothing. `cloud-session-status` and the unsubscribe commands stay open. With
`ws-cloud-conversations-v1`, a WebSocket connection that authenticated with a
pairing-store credential (an approved pairing or a `page-credential`) is one of
the person's own clients: it may use the app's lease like the app (and gets
its `cloud-*` events), but never a lease another connection set. A WebSocket
connection with the static or file token gets no `cloud-*` command or event.

### cloud-host-replica-set, cloud-host-replica-clear, cloud-host-replica-status

| Field | Value |
| --- | --- |
| name | `cloud-host-replica-set`, `cloud-host-replica-clear`, `cloud-host-replica-status` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-host-replica-v1` |

The host's read replica publisher (plans/cmux-next/object-sync/DESIGN.md
phase 3). `cloud-host-replica-v1` is advertised when the daemon has a cloud
transport. Only the verified cmux app connection (the `frontend` actor) may
use these commands; any other connection gets `cloud_conversation_rejected`
with `reason` `forbidden`.

`cloud-host-replica-set {api_base_url, install_token, expires_at,
client_version?, host_name}` leases the app's install token. The daemon keeps
it in memory only and never returns it; a chief token (`agt`) is refused. A
lease for the same user, install and origin is a renewal: the token is swapped
in place and the open socket stays. The daemon asks for a renewal with the
`cloud-host-replica-needed` event (spec/events.md): `expiring` within two
minutes of `expires_at`, `unauthenticated` when the cloud refused the token. The
daemon enrolls the host (`host.enroll`, idempotent per install), opens
`/v1/wire/host/<host>` and publishes `host:<host>/session`: a projection of
the `list-workspaces` tree with, per workspace, only `id`, `resource_id`,
`short_id`, `name`, `name_revision`, `group`, `color`, `icon`, `pinned`,
`marked_unread`, `unread_count` and `active`, plus `registry_id` and
`generation` (no screens, tabs or titles). A snapshot after each connect, then
one event per settled change, each with the whole new state in
`effects.state`.
It also answers the ops the cloud forwards from the host's owner. Only
`workspace.rename` with the fields `workspace`, `name`,
`expected_name_revision` and `expected_generation` runs, through the daemon's
own command path, and only for the token's own user; any other op, field or
user is refused, and nothing runs. A decided key answers again and never runs
twice. Every forwarded op is answered with `result` or `reject`, then
`request-settled`; a change is published before its answer.

`cloud-host-replica-clear {purge?}` drops the lease. With `purge: true` (the
host's off switch), the cloud copy is deleted first (`replica.purge`), and the
lease goes when the cloud confirms. `cloud-host-replica-status` returns
`object{state:"off"|"connecting"|"online"|"unauthenticated"|"forbidden"|"purging"|"backoff"|"replaced",
api_base_url?, expires_at?, host_name?, host?, stream?, seq?, purge_pending?,
purge_unconfirmed?, last_error?}`. On `unauthenticated` the app sets a new
lease; `forbidden` means this install is not the host's publisher or the
cloud removed the host (or the owner deleted the replica with `host.replica.purge`). A removed host stays `forbidden` through later leases
of the same install (a token refresh never enrolls it again) until
`cloud-host-replica-clear`. `replaced` means another socket of the same
install publishes the host now; the daemon waits for a new lease.
`purge_unconfirmed` means the cloud refused the install during the off switch,
so it did not confirm the purge (the cloud drops a removed host's copy
itself). The stream's `seq` never goes back in one daemon; a stream the cloud
does not hold starts at the wall clock in milliseconds.

### page-credential

| Field | Value |
| --- | --- |
| name | `page-credential` |
| status | implemented |
| since | protocol 12 additive extension; capability `page-credential-v1` |

`page-credential` (no fields) returns `object{credential, expires_in}` to the
verified cmux app connection (the `frontend` actor) only; every other
connection is refused. The credential is a single-use pairing-store
credential: it authenticates one WebSocket handshake within 2 minutes
(`expires_in`), lives in memory only, and has its own bound (16), so it never
evicts an approved pairing. The app asks for one on every connect and hands it
to its own page (host verb `cmux.host.credential.load`), and a
WebSocket connection that presents it is the person's own client
(`ws-cloud-conversations-v1`). The file token next to the socket stays the
listener's endpoint credential for local clients and never carries the
person's Cloud lease.

With `page-credential-scoped-v1`, `page-credential {page}` names a page id of
the page-router table (spec/page-router.json). Any trusted local (Unix)
connection may ask, not only the verified app; a WebSocket connection never
may. It returns `object{credential, expires_in, page}`: a credential of the
same single-use, 2-minute page store, bound to that page. A WebSocket
handshake that presents it must carry that page's Origin
(`cmux-page://cmux.<page>`); with any other Origin, or none, the handshake is
refused and the credential is used up. The connection then gets only that
page's commands: its `cmux.protocol/2` allow list (spec/page-router.json) and
the page's raw commands (for `home-channels`: `identify`, `set-client-info`, a
plain `subscribe`, `conversation-list`, `conversation-create`,
`conversation-snapshot`, `conversation-history`, `conversation-thread`,
`conversation-op`, `conversation-typing`, `conversation-search`, `conversation-link-resolve`,
`conversation-runs`, `conversation-run`, `conversation-inbox-op` and the
`conversation-attachment-upload`, `-read` and `-link` commands, with the
`conversation-changed`, `conversation-typing`, `conversation-draft`,
`conversation-run-changed` and `conversation-inbox-changed` events, and
`chief-changed` and `participant-avatar-changed` for a connection that echoes
their capability; for every other page none); any other line is
refused with `origin.forbidden`. It is never the person: no `cloud-*` command
or event, like the file token. Page-bound credentials have their own bound
(16), so they never evict the verified app's page credentials. A client checks
`page-credential-scoped-v1` before it sends `page`: an older daemon ignores
the field. It lets an owner whose app connection is not the
verified app (the Chief home's conversation owner) hand its page a
credential narrower than the file token. An unknown page id is refused.

### ws-listen

| Field | Value |
| --- | --- |
| name | `ws-listen` |
| status | implemented |
| since | protocol 12 additive extension; capability `ws-listen-v1` |

`ws-listen {allow_origin?, allow_origins?}` opens the owner's loopback page listener on a
running daemon that started without one (transports.md "App listener and page
files"): it binds `127.0.0.1:0`, mints a 256-bit credential into
`<socket>.websocket.json` (mode 0600, atomic rename, removed with the daemon)
and serves the page files on the same listener. `allow_origin`
(`scheme://host[:port]`, never `null`) is one page origin the listener admits
besides its own; `allow_origins` (capability `ws-listen-origins-v1`) is a list
of them (the app's first-party pages), joined with `allow_origin`. Returns `object{url, pages, opened}`: `opened` is false when
the listener already existed (from `server ensure --ws-loopback` or an
earlier `ws-listen`) and, with `ws-listen-origins-v1`, `origins` (the extra
origins the listener admits). The admitted origins are fixed when the listener
binds: a request whose origins the existing listener admits none of is refused
with an error that says so; one that names some admitted origins gets the
endpoint, and the client reads `origins` for the rest. The credential
is never in the reply. Trusted local (Unix) connections only; a WebSocket
connection is refused. A daemon whose listener uses a configured credential
(`--ws-token`, `server.ws_token`) refuses, because it has no credential file
to share. A client that finds the credential file missing calls `ws-listen`
when `identify` lists `ws-listen-v1`; an older owner lacks it, and the client
restarts that owner (the app hands it off to its bundled build) or tells the
person how to, never waits on it forever.

### cloud-inbox-list, cloud-conversation-snapshot, cloud-conversation-history, cloud-conversation-op

| Field | Value |
| --- | --- |
| name | `cloud-inbox-list`, `cloud-conversation-snapshot`, `cloud-conversation-history`, `cloud-conversation-op` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-conversations-v1` |

Forward to the cloud owners (ConversationDO, UserDO inbox) with the lease and
answer from a worker thread, so replies may arrive out of order (match by
`id`). `cloud-conversation-op {conversation?, idempotency_key, origin?, op}`
forwards one op tagged by `kind` (`dm.open`, `conversation.create`,
`participants.add`, `participants.remove`, `participants.set_role`,
`participants.unban`, `ownership.transfer`, `grant.create`, `grant.revoke`,
`message.send`, `message.edit`,
`message.retract`, `reaction.add`, `reaction.remove`, `read_cursor.set`,
`title.set`, `thread.update`, `invite.create`, `invite.accept_verified`,
`request.dismiss {block?}`) with the client's key and origin and returns
`object{value, rev?, seq?, change?, replayed, transaction, stream, sequence}`.
Errors carry `error_code` (`cloud_conversation_rejected`, `cloud_signed_out`,
`cloud_session_expired`, `cloud_unauthenticated`, `cloud_unavailable`),
`reason` and `retryable`. With `cloud-lease-app-only-v1`, an op with
`origin: "user"` from a connection that is not the verified cmux app is
refused before anything is sent, with `cloud_conversation_rejected`,
`reason` `forbidden`, `retryable` false. Shapes:
plans/cmux-next/home-cloud-proxy.md.
`cloud-conversation-snapshot` and `cloud-conversation-history` pass the
owner's `threads` field through unchanged when it sends one.
`cloud-inbox-list {limit?, include_archived?, cursor?}` returns one page of
UserDO `inbox.list` as `object{entries, revision, next_cursor}`: `limit` (1-200,
default 200) entries from `cursor` (the `next_cursor` of the page before; absent
for the first page). `next_cursor` is null on the last page. One page per call,
so every reply is one bounded read; a client reads the whole inbox by following
`next_cursor`. `home-inbox`'s Cloud rows do: every page, at most 50, asking for
no page after 8 s from the start of the read, an entry a later page lists again kept once where it was
first listed; any page's failure, a refusal included, leaves the Cloud rows
`unavailable` (`signed_out` only without a usable lease).

### cloud-requests-list

| Field | Value |
| --- | --- |
| name | `cloud-requests-list` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-conversations-v1` |

The lease person's open message requests (plans/cmux-next/home-messaging-invites/DESIGN.md
2.3): `POST /v1/read home.requests.list {}` with the lease. Takes no fields (an
unknown field is refused). Returns `object{requests}`, each row
`{conversation, inviter, kind, title?, preview, created_at, expires_at, trusted}`
as the owner sent it; a row whose `conversation` is not a conversation id is
dropped. Accept with `cloud-conversation-op` `invite.accept_verified` and
dismiss (or block, `block: true`) with `request.dismiss`, both naming the
conversation. Errors as `cloud-inbox-list`.

### cloud-selfhost-info

| Field | Value |
| --- | --- |
| name | `cloud-selfhost-info` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-selfhost-v1` with `cloud-conversations-v1` |

The self-hosted chat server's identity of the person: `GET /v1/selfhost/info`
on the lease's origin, without an Authorization header. Takes no fields. Needs
a tailscale lease (`cloud-session-set` with `auth: "tailscale"`), else
`cloud_conversation_rejected` with `reason` `not_selfhost`. Returns
`object{kind: "selfhost", user_id, login?, display_name?, server_name?}`. A
reply whose `kind` is not `selfhost` or whose `user_id` is not `user_` and
6-80 characters of `[A-Za-z0-9_.-]` is `cloud_unavailable`. The `user_id`
becomes the lease's account: every later `cloud-*` event carries it as
`account`, `cloud-session-status` names it as `participant`, and open
subscriptions reconnect to carry it. Same admission as `cloud-inbox-list`.

### cloud-conversation-thread

| Field | Value |
| --- | --- |
| name | `cloud-conversation-thread` |
| status | implemented |
| since | protocol 12 additive extension; capabilities `cloud-conversations-v1` and `conversation-thread-v1` |

`POST /v1/read conversation.thread {conversation, root, after_seq?, limit?}`
(limit 1-200) with the lease; returns the owner's value unchanged, the same
shape as `conversation-thread`. Answers from a worker thread like the other
cloud reads; errors as `cloud-conversation-history`.

Params: `conversation`, `root` (required); `after_seq`, `limit` (optional).

### cloud-inbox-subscribe, cloud-inbox-unsubscribe, cloud-conversation-subscribe, cloud-conversation-unsubscribe

| Field | Value |
| --- | --- |
| name | `cloud-inbox-subscribe`, `cloud-inbox-unsubscribe`, `cloud-conversation-subscribe`, `cloud-conversation-unsubscribe` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-conversations-v1` |

Register this connection's interest in the cloud inbox or one conversation.
The daemon keeps one upstream socket per target for all local clients and
publishes the `cloud-*` events on the subscribe stream. A closed connection
releases its interests.

A subscribe replies with the shared socket's current state,
`object{conversation?:string, state:string, reason?:string, account?:string}`
(`connecting`, `live`, `disconnected` or `closed`; a later subscriber to a
live socket gets `live`), and then emits the same state as a
`cloud-subscription-state` event, so a change that raced the reply never
leaves the client on an older state. Every later change of the shared socket
is a `cloud-subscription-state` event.

### cloud-mux-subscribe, cloud-mux-unsubscribe, cloud-mux-ack

| Field | Value |
| --- | --- |
| name | `cloud-mux-subscribe`, `cloud-mux-unsubscribe`, `cloud-mux-ack` |
| status | implemented |
| since | protocol 12 additive extension; capability `cloud-conversations-v1` |

The leased chief's MuxDO wake queue (`mux:<agent>`, plans/cmux-next/cloud-chief-vm.md).
The agent is the lease token's `agt` claim, never a request field: the
subscribe commands take no fields and `cloud-mux-ack` takes only
`conversation` and `seq` (an unknown field is refused). A person's lease is
refused with `mux_needs_chief`.

Events on the subscribe stream: `cloud-mux-wake {seq, wakes, account?}` for
new wakes and `cloud-mux-resynced {seq, pending, account?}` after a
(re)subscribe, so a wake missed while the socket was down is delivered. A
wake is ids only: `{conversation, seq, reason}`, never message text; the
brain reads the message through its own authorized conversation read.

`cloud-mux-ack {conversation, seq}` sends `mux.ack` for the lease's chief
with idempotency key `mux-ack:<conversation>:<seq>`: a repeated ack is a
replay and changes nothing.

### create-profile

| Field | Value |
| --- | --- |
| name | `create-profile` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Creates a room. A caller-chosen `profile` id makes a retry idempotent: the
same id and name return the stored room with `changed:false`.

Params: `name` (required), `profile`, `color`, `icon`, `theme`, `index`
(insertion index, default last), `browser_profile_id`, `default_session_id`,
`defaults`, `follows` (session ids).

Result:

```text
object{profile:Room, changed:bool}
```

### update-profile

| Field | Value |
| --- | --- |
| name | `update-profile` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Updates a room. An absent field is unchanged; JSON null clears `color`,
`icon`, `theme`, `browser_profile_id`, `default_session_id`, or `defaults`.

Params: `profile` (required), `name`, `color`, `icon`, `theme`,
`browser_profile_id`, `default_session_id`, `defaults`.

Result:

```text
object{profile:Room, changed:bool}
```

### move-profile

| Field | Value |
| --- | --- |
| name | `move-profile` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Moves a room to an insertion index among rooms (the `move-workspace` rule).

Params: `profile`, `index` (both required).

Result:

```text
object{profile:Room, changed:bool}
```

### delete-profile

| Field | Value |
| --- | --- |
| name | `delete-profile` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Deletes a room. `default` is refused. With `move_to`, its pins and groups move
to that room; without it, its pins are removed (the workspaces return to the
rooms that follow their sessions) and its groups are deleted, their members
ungrouped. Its follows are removed.

Params: `profile` (required), `move_to`.

Result:

```text
object{profile:string, moved_to:string|null, unpinned:[object{session_id:string, workspace_key:string}]}
```

### set-profile-follows

| Field | Value |
| --- | --- |
| name | `set-profile-follows` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Replaces the sessions a room follows.

Params: `profile`, `session_ids` (both required).

Result:

```text
object{profile:Room, changed:bool}
```

### pin-workspace

| Field | Value |
| --- | --- |
| name | `pin-workspace` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Pins a qualified workspace to one room, replacing any pin. The workspace key
need not exist on any session yet. A personal group of another room is
cleared from the workspace.

Params: `session_id`, `workspace_key`, `profile` (all required).

Result: `object{changed:bool}`

### unpin-workspace

| Field | Value |
| --- | --- |
| name | `unpin-workspace` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Removes a workspace's pin; it returns to the rooms that follow its session.

Params: `session_id`, `workspace_key` (both required).

Result: `object{changed:bool}`

### put-session

| Field | Value |
| --- | --- |
| name | `put-session` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Records a session in the home session registry and stamps `last_seen_ms`
when its content changes. Absent `machine_name`, `session_name`, and
`capabilities` keep stored values. Repeating the same effective content
returns the stored record without writing, advancing `personal_revision`,
or emitting `personal-changed`. A new session is followed by `default`
and by `follow_with`. It never changes the session's `icon` (`session-icon-v1`).

Params: `session_id` and `transport` (required object), `machine_name`,
`session_name`, `capabilities`, `follow_with`.

Result: `object{session:Session, created:bool}`

### forget-session

| Field | Value |
| --- | --- |
| name | `forget-session` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Forgets a session: its registry row, follows, and personal workspace rows.
Refused while a room pins one of its workspaces unless `force`, which also
removes those pins.

Params: `session_id` (required), `force` (default false).

Result: `object{changed:bool}`

### set-session-icon

| Field | Value |
| --- | --- |
| name | `set-session-icon` |
| status | implemented |
| since | protocol 12 additive extension; capability `session-icon-v1` |

Sets or clears the icon of a known session in the home session registry, the
icon the app's sidebar shows for that machine. `icon` is required: an icon
value (see "Icon values" under `put-blob`) sets it and JSON null clears it.
The same icon again returns `changed:false` and emits nothing; a change bumps
`personal_revision` and emits `personal-changed`. `put-session` keeps the
icon; `forget-session` removes it with the record.

Params: `session_id`, `icon` (both required; `icon` is a string or null).

Result: `object{session:Session, changed:bool}`

Errors: a bad session id or icon value; `unknown session <id>` for a session
the registry does not hold; `error_code` `unknown_icon_asset` for an asset
icon the blob store does not hold. A rejected command changes nothing.

### import-session-organization

| Field | Value |
| --- | --- |
| name | `import-session-organization` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

The app's one-time copy of a remote session's shared groups and sidebar
order. When the session is already `migrated` it does nothing and returns
`imported:false`. Otherwise, in one transaction, it adds the groups as
personal groups of room `default` (an id that collides gets a session prefix),
appends the workspaces in the given order with their mapped groups, and marks
the session migrated. The session must be known (`put-session`).

Params: `session_id` (required), `groups` (`[object{id, name, color?,
collapsed?}]`), `workspaces` (`[object{workspace_key, group?}]`).

Result: `object{imported:bool}`

### create-personal-group

| Field | Value |
| --- | --- |
| name | `create-personal-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Creates a personal group in a room (default `default`) at an insertion index
among all personal groups. A caller-chosen `group` id with the same name is an
idempotent retry.

Params: `name` (required), `group`, `profile`, `color`, `collapsed`, `index`.

Result: `object{group:PersonalGroup, changed:bool}`

### update-personal-group

| Field | Value |
| --- | --- |
| name | `update-personal-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Renames, recolors (null clears), collapses, or moves a group to another room.
Moving it pins every member workspace to that room in the same transaction.

Params: `group` (required), `name`, `color`, `collapsed`, `profile`.

Result: `object{group:PersonalGroup, changed:bool}`

### delete-personal-group

| Field | Value |
| --- | --- |
| name | `delete-personal-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Deletes a personal group; its workspaces become ungrouped. It is the same
delete as `workspace_group.delete`: the group is stored in closed history, so
`closed.reopen` forms it again.

Params: `group` (required).

Result: `object{group:string, ungrouped:[object{session_id:string, workspace_key:string}]}`

### move-personal-group

| Field | Value |
| --- | --- |
| name | `move-personal-group` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Moves a personal group to an insertion index among personal groups.

Params: `group`, `index` (both required).

Result: `object{group:PersonalGroup, changed:bool}`

### set-personal-workspace

| Field | Value |
| --- | --- |
| name | `set-personal-workspace` |
| status | implemented |
| since | protocol 12 additive extension; capability `profiles-v1` |

Creates or updates the personal row of a qualified workspace. A new row is
appended last unless `index` is given; `index` is the final position in the
personal order. JSON null clears `group`, `browser_profile_id`, `theme`, or
`remote_localhost`. The daemon does not check that the group belongs to the
room showing the workspace; the app evaluates membership.

`remote_localhost` (capability `personal-remote-localhost-v1`) is the
workspace's own remote-localhost choice: whether its browser tabs open its
machine's localhost (plans/cmux-next/remote-localhost.md section 6). null
follows the app's `browser.remoteLocalhost` setting. The app sets it only for
a person; the daemon does not check who sends it.

Params: `session_id`, `workspace_key` (required), `index`, `group`,
`browser_profile_id`, `theme`, `remote_localhost`.

Result: `object{workspace:PersonalWorkspace, changed:bool}`

### set-personal-terminal

| Field | Value |
| --- | --- |
| name | `set-personal-terminal` |
| status | implemented |
| since | protocol 12 additive extension; capability `personal-terminals-v1` |

Sets the own theme of a session-qualified terminal `{session_id,
terminal_key}` (plans/cmux-next/data-model.md section 6). `terminal_key` is
the terminal's id on its session (its tab id when it has none), 1-128
printable ASCII characters; the daemon does not check that it exists. A
`theme` of JSON null, or no `theme`, removes the row. `theme` follows the
`theme` rules of `list-personal`. `forget-session` removes the session's
rows.

Params: `session_id`, `terminal_key` (required), `theme`.

Result: `object{terminal:PersonalTerminal|null, changed:bool}`

### snapshot-request

| Field | Value |
| --- | --- |
| name | `snapshot-request` |
| status | implemented |
| since | protocol 12, capability `terminal-snapshot-v1` |

Asks the host for one READY `snapshot` on this connection's snapshot attach of
`surface`. It is the raw form of the terminal channel message
`snapshot_request` (sync-and-transport.md). A request while a snapshot is
pending for that viewer collapses into it. A viewer gets at most one requested
snapshot per 500 ms; an earlier request answers `snapshot_throttled`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | A PTY surface this connection attached with `snapshot:"ghostsnp"` |
| `reason` | `string` | optional | `digest_mismatch`, `gap`, `generation_mismatch` or `attach`; any other value is `invalid` |
| `have` | `{generation?, offset?, snapshot_version?}` | optional | A `snapshot_version` other than the host's is `unsupported_version` |
| `request_id` | `string` | optional | At most 128 bytes; echoed; repeats while a snapshot is pending collapse |

Result:

```text
object{status: "accepted" | "collapsed" | "snapshot_throttled", surface, retry_after_ms?, request_id?, reason?}
```

Errors:

| Error | Condition |
| --- | --- |
| `not_attached` | This connection has no snapshot attach of `surface` |
| `unsupported_version` | `have.snapshot_version` differs from the host's |
| `unknown surface <id>` | Surface id does not exist |

### terminal-history

| Field | Value |
| --- | --- |
| name | `terminal-history` |
| status | implemented |
| since | protocol 12, capability `terminal-snapshot-v1` |

Returns GHOSTSNP HISTORY pages of a PTY surface's primary screen, newest
first, that start above the row marker `before` (absent: the top of the
active area). Row markers stay on their row while output scrolls; rows
that left scrollback, or markers of another `marker_epoch`, answer
`range_evicted`. A reflow starts a new epoch. Each call encodes the whole
scrollback once under the terminal lock.

Params: `surface` (Id, required), `marker_epoch` (uint64, required),
`before` (uint64, optional), `max_bytes` (default 1048576, 1..=8388608;
at least one page is returned when any exists).

Result: `{surface, marker_epoch, snapshot_version, pages: [{marker, rows,
data}], next_before, done}`. `data` is one base64 GHOSTSNP PAGE record;
`marker` is the page's first row. Pass `next_before` as `before` until
`done`.

### terminal-read-range

| Field | Value |
| --- | --- |
| name | `terminal-read-range` |
| status | implemented |
| since | protocol 12, capability `terminal-snapshot-v1` |

Reads the primary screen range `from..=to`, each `{row_marker, col}`, as
`text` (default; unwrapped lines joined with a newline) or `vt`.

Params: `surface` (Id, required), `marker_epoch` (uint64, required),
`from`, `to` (required), `format` (`text` or `vt`), `max_bytes` (default
1048576, 1..=8388608).

Result: `{surface, text, truncated}`; a longer range is cut at a
character boundary and answers `truncated: true`. Errors: `range_evicted`,
`invalid: ...`, `unknown surface <id>`.

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

Servers advertising `attach-identity-v1` accept paired `expected_generation`
and `expected_terminal_id`. Both must match before any stream or lease is
created. With this pair, clients may omit `surface`: the daemon resolves the
public terminal ID in the same attachment operation. The first `vt-state`
identifies its numeric surface. Clients must wait for the successful attach
response and lease before sending input. Creation receipts keep their existing
shape; their generation and terminal ID provide the identity fence. Older
servers require the existing separate surface-resolution path.

When the client sent `shared-sizing-v1` in `set-client-info`, a terminal
attach response also includes `participant` (this view's host participant id)
and `size_state` (the state after this view joined). A `size-state` event for
the same join may reach the attach stream before the response; order states by
`generation`.

When both peers negotiate `view-attachment-lease-v1` through `identify` and
`set-client-info`, the response includes an opaque `lease`. The lease names
this exact connection-local attach stream. Use it with
`resize-attached-view` and `release-attached-view-size`. When both peers also
negotiate `view-attachment-detach-v1`, use `detach-attached-view` to close the
stream without disconnecting or affecting another view of the terminal.

Servers advertising `terminal-snapshot-v1` accept `snapshot:"ghostsnp"` with
`snapshot_version` on a `mode:"bytes"` PTY attach. When the version equals the
host's GHOSTSNP version, the stream is `snapshot -> (output | snapshot |
colors-changed | digest)* -> detached` instead of the replay stream:

- `snapshot {surface, phase:"ready", generation, offset, version, cols, rows,
  colors, data}`: `data` is the base64 GHOSTSNP READY prefix (envelope through
  the READY record). The viewer restores it atomically into a fresh terminal.
- `output` carries `generation` and `offset` (the host's published byte offset
  after this frame). A viewer drops output whose generation is older than the
  last snapshot it restored.
- A grid change, a viewer backlog over `viewer_backlog_bytes`
  (default 8388608 = 8 MiB, set per attach by the viewer, no daemon setting,
  clamped to 65536..8388608)
  and `snapshot-request` reach the viewer as a new `snapshot`; a slow viewer
  is never disconnected for its backlog. `resized` is never sent.
- `snapshot` also carries `marker_epoch` and `active_top_marker` (the row
  marker of the active area's top row), so `terminal-history` pages line up
  with the restored READY.
- Servers that also advertise `terminal-snapshot-history-v1` follow every
  READY with `snapshot {surface, phase:"history", generation, offset,
  version, compression:"deflate", raw_bytes, data, done}` chunks at that
  READY's `generation` and `offset`. Each chunk holds at most 1048576 bytes
  of history (`raw_bytes`), compressed alone as raw DEFLATE (RFC 1951, no
  zlib or gzip framing); `data` is its base64. The inflated chunks
  concatenated are the rest of the same COMPLETE encode after the READY record (HISTORY
  manifests, scrollback PAGE records, FINISH), so READY plus history is one
  complete GHOSTSNP snapshot taken at one cut. `done` is true on the last
  chunk. History is lower priority than live output: `output` events may
  arrive between chunks and keep their own `generation` and `offset`. A newer
  READY ends the older READY's history; no further chunk of it is sent. A
  viewer feeds the chunks to its restore after the READY they follow and
  drops history whose `generation` and `offset` differ from its last READY.
- Servers that also advertise `terminal-snapshot-local-history-v1` accept
  `snapshot_local_history: true` on a snapshot attach (ignored without
  `snapshot`). Such a viewer reflows its own copy of the history at a resize.
  While it holds every frame since its last READY, a resize reaches it as
  `snapshot {surface, phase:"ready", history:"local", generation, offset,
  version, cols, rows, colors, marker_epoch, active_top_marker,
  history_rows, history_digest, data}`: the READY of the new grid, taken
  under the terminal lock at the resize. It follows every `output` sent
  before the resize, its `generation` is the resize's new generation and its
  `offset` is the offset at the resize; no `output` before the resize is
  dropped, and no history chunk follows it. A burst of resizes gives one such
  READY per resize, in order. `history_rows` is the host's primary-screen
  history row count after the resize and `history_digest` (lowercase hex) is
  the digest of the 64 history rows directly above the READY's seam
  (codepoints and wrap flags, no styles) as libghostty-vt
  `ghostty_terminal_history_digest` (digest version 2) computes it on the
  same terminal directly after the READY encode. The
  viewer computes both from its reflowed history and sends `snapshot-request`
  on a mismatch. A local READY ends the history of an older READY. A viewer
  that is behind (a snapshot pending or deferred, a backlog overflow) or is
  still receiving the history of an older READY gets a READY with history at
  a later cut instead, as do attach, overflow and `snapshot-request`; so does
  every viewer when the host cannot compute the history check. A host replay
  replacement and a Kitty-limit resync also send a READY with history.
- Servers that also advertise `terminal-snapshot-images-v1` accept
  `snapshot_images: true` on a snapshot attach (ignored without `snapshot`).
  Such a viewer gets, after the last history chunk of every READY that has
  history (attach, overflow, `snapshot-request`, a grid change without a
  local READY), `snapshot {surface, phase:"images", generation, offset,
  version, data, done, skipped_images?}` chunks. Every images chunk has
  exactly these fields: `event:"snapshot"`; `surface`; `phase:"images"`;
  `generation`, `offset` and `version` (uint16), each equal to the READY it
  follows (a decoder may require all three); `data` (base64 of at most
  1048576 stream bytes); `done` (bool); and, on the last chunk only and only
  when the cap left images out, `skipped_images` (uint64). It has no
  `compression`, `raw_bytes`, `cols`, `rows` or `colors`.
  `spec/fixtures/terminal-snapshot-dogfood-png.jsonl` holds the host's real
  READY, history, images and local READY lines for one PNG image
  (`surface` and `marker_epoch` set to 0). The chunks
  concatenated are one libghostty-vt `ghostty_terminal_kitty_replay_encode`
  stream encoded under the same terminal lock hold as the READY, at the same
  cut: a per-screen reset, every stored image (pixels for the selected
  ones, metadata only for the rest), the placements that show, and the
  implicit image-ID cursor. Each chunk holds at most 1048576 bytes of the
  stream; `data` is its base64 and there is no `compression` field (the
  pixels are already zlib, Kitty `o=z`). `done` is true on the last chunk.
  The viewer applies the complete stream with the trusted apply function
  (`ghostty_terminal_kitty_replay_apply` or
  `ghostty_surface_apply_kitty_replay`) after the READY and its history
  (a placement above the active area needs its row), never as PTY output,
  and drops images whose `generation` and `offset` differ from its last
  READY. Images have the priority of history: `output` events may arrive
  between chunks, and a newer READY ends the older READY's images. The host
  selects at most 33554432 bytes (32 MiB) of decoded pixels per READY per
  viewer, newest image first; when the cap leaves images out, the last
  chunk carries `skipped_images` (their count) and the host logs one line.
  A terminal without images (its image storage never changed, or no image
  and no placement is left) sends no images phase, so a viewer clears its
  images at every READY with history and keeps none when no images phase
  follows. A viewer that did not opt in gets no images. A local READY
  (`history:"local"`) is never followed by images: on a history match the
  viewer keeps its own images; on a mismatch it sends `snapshot-request`
  (`reason:"gap"`) and gets a READY with history and then images. A viewer
  that is still owed the images of an older READY gets a READY with history
  at a resize, not a local READY.
- `digest {surface, generation, offset, version, sha256}` follows 2 s after
  output goes idle, only when the viewer has every byte up to that offset.
  `sha256` (hex) covers, for each SCREEN, PAGE and CONTINUATION record of the
  host's READY encoding in order, the `u16` tag, `u32` payload length and
  payload, with the SCREEN history extent (payload bytes 4..12) zeroed; the
  TERMINAL record is excluded because it carries per-device scrollback and
  pixel sizes. A viewer with the same version hashes its own READY the same
  way and sends `snapshot-request` on a mismatch.
- `generation` is the host's grid generation for this terminal: it starts a
  new value at every resize, host replay replacement and Kitty-limit resync.
  It is not the `size-state` generation.
- When the host cannot encode a snapshot (an unfinished escape sequence over
  1 MiB), it retries at the next output; the viewer stays attached.

Snapshot format version 1 carries no Kitty images (`terminal-snapshot-images-v1`
sends them after the history). Another `snapshot_version`
gets the replay stream above (capability fallback).

Browser attach requires `browser-pointer-frame-guard-v1` in both the server's `identify` response and the client's earlier `set-client-info` request. This prevents an older client from rendering browser frames that it cannot address with an authoritative sequence. PTY attach does not require this capability.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required unless identity pair supplied | Must identify a live PTY or negotiated browser surface |
| `expected_generation` | `string` | default null | `attach-identity-v1`; paired with `expected_terminal_id` |
| `expected_terminal_id` | `string` | default null | Public terminal ID, validated against the live surface |
| `mode` | `string` | default `"bytes"` | Protocol 7: `"bytes"` or `"render"` |
| `cols` | `uint16` | default null | `attach-initial-size` capability; paired with `rows`, clamped to at least 1 |
| `rows` | `uint16` | default null | `attach-initial-size` capability; paired with `cols`, clamped to at least 1 |
| `snapshot_local_history` | `bool` | default false | `terminal-snapshot-local-history-v1`; only with `snapshot` |
| `snapshot_images` | `bool` | default false | `terminal-snapshot-images-v1`; only with `snapshot` |

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

A wait with a nonzero `timeout_ms` does not hold the connection: it starts after the requests sent before it, and later requests on the same connection are answered while it waits (they may run during its first check), so its reply can arrive after theirs (match replies by `id`). Each such pending `wait-for` takes one terminal-wait worker, from the budget `terminal.wait` uses (8 per connection, 64 per daemon); a `wait-for` over that budget fails at once and is not run. A one-shot check (`timeout_ms` 0) runs in request order and takes no worker. When the connection closes, its pending waits end at once; when the client only half-closes (shuts down its write side), they still run to their end and reply.

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
| `timeout_ms is too large` | The deadline is past what the platform clock can represent |
| `too many wait-for requests are already waiting on this connection (limit 8); request was not executed` | The connection already has 8 pending waits (`daemon` and its limit when the daemon-wide budget is full) |
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
| `source` | `string` | default `"cli"` | With `notification-source-v1`: `"cli"`, `"terminal"`, `"agent"`, or `"daemon"`; who posted it |

Result:

```text
object{notification:Id}
```

With `notification-source-v1` the daemon also posts, with source `terminal`, every desktop notification a program asks for in its terminal output, whether or not any client shows or attaches the terminal: OSC 9 text that Ghostty does not parse as a ConEmu command (`9;1;`, `9;10`, `9;11;`, `9;12`, `9;2;`..`9;9;` forms, `9;4;<0-4>` progress, `9;5`), OSC 777 `notify;<title>;<body>`, and kitty OSC 99 (`p=title|body`, `d=0` chunks with `i=<id>`, `e=1` base64). Text is bounded (title 256, body 1024 characters, control characters removed); a notification with only body text shows it as the title. Each terminal posts at most one per second and the same text at most once per five seconds, as Ghostty does. Agent-hook notifications have source `agent`.

Errors:

| Error | Condition |
| --- | --- |
| `title is required` | Title is empty |
| `bad level <level>` | Level is not allowed |
| `bad source <source>` | Source is not allowed |
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
    source: "plugin"|"detected"|"socket"|"hook",
    session: string|null,
    agent?: string|null,
    agent_session_id?: string|null,
    updated_at_ms: uint64,
    since_ms?: uint64,
    last_prompt?: string|null
  }>
}
```

`agent_session_id` is the harness's own session id that the agent's hooks reported
(a `claude` or `codex` session id, at most 256 bytes of `[A-Za-z0-9._:-]`), or null.
A hook report keeps `session` for a human label, so a client finds the terminal of an
agent session (a `cmux://agent` link) by this id.

`last_prompt` is the terminal agent's last prompt (at most 200 characters), which the
hook helper sends beside a turn-start event (`session.journal.append` `live_prompt`).
The daemon keeps it in memory only: it is never journaled, persisted or logged, and a
daemon restart, a closed terminal or an ended agent session forgets it.

A finished or failed turn's last agent message rides the same way (`live_reply`), as do
the error text of a failed tool or turn and, for `live_prompt`, the whole prompt: the hook
keeps them whole (markdown with its line breaks, at most 4000 characters). The turn's
`notification` event carries the message as `preview` (folded, at most 200 characters, the
banner text the app shows per its Show Previews setting) and whole as `message`, the turn's
prompt as `prompt`, the posting agent's harness session as `session` and the ledger row's id
as `id` (for the phone's Feed). The daemon drops the message once that event is sent. The
durable notification row never holds any of them.

`since_ms` is when the agent entered `state` (Unix ms): a report that keeps
the state keeps it, so a client can show how long an agent has worked or
waited. After a daemon restart it is the last report's time. Older daemons omit
it; use `updated_at_ms` there.

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
{"id":107,"ok":true,"data":{"agents":[{"surface":1,"state":"blocked","source":"hook","session":"abc","updated_at_ms":1710000000000,"since_ms":1709999940000}]}}
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
authority over socket reports. A socket report that does not change the
effective projection is a replay-equivalent no-op at the current revision and
does not publish another event. A socket report received after an unchanged
hook therefore retains the hook value without advancing the resource
revision. Restart restores the current projection. Closing the terminal
deletes it, so historical reports cannot recreate an agent. Browser surfaces,
surfaces without durable terminal identity, and terminal-less default reports
are rejected.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `IdRef` | required | Surface associated with the agent |
| `state` | `string` | required | `"working"`, `"blocked"`, `"idle"`, `"done"`, or `"unknown"` |
| `source` | `string` | required | `"socket"` or `"hook"` for `report-agent`; list responses can also contain `"detected"` or `"plugin"` |
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

`dock-columns-v1` is additive within protocol v12. Clients must require the capability before sending `set-column-dock`. Clients without it ignore `Screen.columns[].dock` and render every column in order. The flag is stored in the screen's durable viewport record only while set; a daemon that predates the capability cannot open a registry that holds a docked column, so roll back only before any column was pinned.

`layout-undo-v1` is additive within protocol v9. Clients must require the capability before sending `undo-layout`. A binding must preserve both result variants and must not set `confirm_close` without the exact revision returned by the confirmation preview.

## Temporary terminal image paste

`paste-image` is an authenticated, lease-bound control operation gated by
`terminal-image-paste-v1` on protocol 12. A protocol-12 daemon without that
capability must not receive image data. Each request contains `surface`, the
exact public `terminal_id`, the current attachment `lease`, a 32-hex-character
`upload_id`, and one operation:

| `op` | Additional fields | Effect |
| --- | --- | --- |
| `begin` | `mime`, `size` | Reserve an upload slot and create a private daemon-owned file. |
| `chunk` | `offset`, `data` | Append one sequential, standard-base64 chunk (at most 48 KiB decoded). |
| `commit` | none | Verify byte count and MIME, then invoke the authoritative terminal paste operation once. |
| `cancel` | none | Remove an unpublished upload; idempotent when already absent. |

Success is `{ "accepted": true }`. Request IDs use the normal control envelope.
Await each acknowledgement before sending the next operation. The connection,
lease, surface, terminal, and authoritative workspace must still match. No
destination path is accepted and no image path or content is returned in an
acknowledgement. Stable error codes begin with `image-`; clients must treat a
lost commit acknowledgement as uncertain delivery and must not retry it blindly.

The policy is PNG/JPEG/GIF/WebP images of any size, eight images per connection
and 32 retained uploads per daemon, with no byte budget. A pending upload expires
two minutes after its last accepted chunk; committed uploads expire in ten minutes. Ownership receipts permit
restart cleanup with a twelve-minute expiry from creation and recurring bounded
recovery sweeps. Receipts match a persistent random file ownership marker as well
as inode identity; the filesystem must support extended attributes. See
[Cloud image paste](../../docs/cloud-image-paste.md) for cleanup and compatibility.

## Loopback forwarding

`loopback-forward-v1` carries browser traffic from a frontend to services on
the daemon's own loopback interface, like an SSH `-L` tunnel with no listening
socket on either side. It is off for a connection until that Unix client sends
`set-client-info` with `capabilities:["loopback-forward-v1"]` and receives the
reply. WebSocket clients are refused. The daemon configuration can turn it off
or restrict ports: `server.loopback_forward` in cmux-tui.json is `true`,
`false`, or `{"enabled":bool,"allow_ports":[3000,"5000-5999"],"deny_ports":[..]}`
(deny wins; an invalid value turns forwarding off). These commands bypass the
ordered surface queue so forwarded bytes never use its budget.

### loopback-open

`{id, cmd:"loopback-open", stream, host, port, window?}`. `stream` is a
client-chosen id, unique among the connection's open streams (clients never
reuse one). `host` must be `localhost`, a name under `.localhost`, or a
loopback IP literal (`127.0.0.0/8`, `::1`, bracketed or IPv4-mapped); the
daemon never resolves DNS and checks the connected peer again. `localhost`
tries `127.0.0.1`, then `::1`. `window` is the client's receive window
(16 KiB to 4 MiB, default 256 KiB). The result is
`{stream, address, window}`, where `window` is the daemon's receive window
(256 KiB). Errors carry `error_code`: `loopback.not-enabled`,
`loopback.disabled`, `loopback.denied-host`, `loopback.denied-port`,
`loopback.limit` (128 streams per connection, 512 per daemon),
`loopback.refused`, `loopback.timeout` (3 s), `loopback.duplicate-stream`,
`loopback.bad-request`.

### loopback-data

`{cmd:"loopback-data", stream, data}` with base64 `data` of at most 64 KiB
decoded, usually without `id` (no reply). The client may have at most the
daemon window in flight; the daemon returns credit with
`{event:"loopback-credit", stream, bytes}` after writing to the target.
Exceeding the window ends the stream with error `window-exceeded`. Target bytes
arrive as `{event:"loopback-data", stream, data}` and never exceed the credit the
client granted with `loopback-open.window` plus `loopback-credit`.

### loopback-credit

`{cmd:"loopback-credit", stream, bytes}` grants the daemon more send window
after the client consumed target bytes.

### loopback-shutdown

`{cmd:"loopback-shutdown", stream}` half-closes: after the queued bytes are
written the daemon shuts down the target socket's write side. The target's own
end of stream arrives as `{event:"loopback-eof", stream}`. When both directions
are done the daemon sends `{event:"loopback-closed", stream}`. Data, EOF and the
final close of one stream stay in order.

### loopback-close

`{cmd:"loopback-close", stream}` aborts a stream. Any failure ends a stream with
`{event:"loopback-closed", stream, error}`; `error` is one of
`closed-by-client`, `read-failed`, `write-failed`, `window-exceeded`,
`bad-frame`, `data-after-shutdown`, `overflow`, `unknown-stream`. Closing the
control connection ends all of its streams.

### loopback-status

`{id, cmd:"loopback-status"}` returns `{enabled, open_streams,
client_streams, opened, refused, limits, audit}`. `audit` holds the last 256
finished or refused connections (`client`, `stream`, `host`, `port`,
`outcome`, byte counts, duration). The daemon also writes one log line per
record.

## Browser runtimes

`browser-runtime-v1` lets a trusted local (Unix) client run a browser on the
daemon's own machine: the daemon starts the remote browser host
(`cmux-remote-browser-host`), and the client reaches the host's loopback port
through `loopback-forward-v1` on the same link, so a cmux app on another
machine shows a page that runs here (an SSH machine's browser tab). No
listening socket leaves the machine. It is off for a connection until that
client sends `set-client-info` with `capabilities:["browser-runtime-v1"]`;
otherwise every command answers `browser-runtime.not-enabled`. WebSocket
clients and the remote relay are refused. These commands bypass the ordered
surface queue.

The host comes only from the install directory: `<data dir>/cmux-tui/browser-host`
(macOS `~/Library/Application Support`, else `$XDG_DATA_HOME` or
`~/.local/share`), or `CMUX_TUI_BROWSER_HOST_DIR`. `current` names the
installed version's directory; its executable is
`host.app/Contents/MacOS/cmux-remote-browser-host` on macOS and
`cmux-remote-browser-host` elsewhere. No command takes a path or a host
argument. A runtime belongs to its connection: the end of the connection stops
its runtimes. Limits: 4 runtimes per connection, 16 per daemon
(`browser-runtime.limit`).

### browser-runtime-status

`{id, cmd:"browser-runtime-status"}` returns `{installed, platform,
runtimes}`: `installed` is the installed version (the name of the directory
that `current` names) or null, `platform` is `<os>-<arch>` of the daemon
(for example `macos-aarch64`), and `runtimes` lists this connection's runtimes
as `{runtime, port}`.

### browser-runtime-start

`{id, cmd:"browser-runtime-start", url?}` starts the host with
`--serve --listen 127.0.0.1:0 --lifeline [--url URL]`. `url` is the first
page (http or https, at most 8 KiB; else `browser-runtime.bad-url`). The
daemon writes a new 32-byte secret (64 hex characters) as the first line of
the host's stdin and keeps the pipe open as its lifeline; the secret is never
in argv, the environment, a log or an event. The reply comes when the host
prints `{"listening":"127.0.0.1:PORT"}`:
`{runtime, port, secret, installed}`. The client sends `secret` as the
`cmux.rd/1` hello token through a `loopback-open` stream to `port`. Errors:
`browser-runtime.not-installed`, `browser-runtime.start-failed` (the host
exited or did not listen within 45 s; the message ends with the end of the
host's log).

### browser-runtime-stop

`{id, cmd:"browser-runtime-stop", runtime}` closes the host's lifeline and
answers `{stopped:true}`; a host still running 5 s later is killed with its
process group. A runtime of another connection, or one already stopped, is
`browser-runtime.unknown`.

## Agent session attach

`agent-session-attach-v1` lets a trusted local (Unix) client show and drive an
agent chat tab of this daemon's store whose acpmux session runs on this
machine: it streams the session (history replay and live records) and sends
prompts, cancels and permission answers through the daemon, which is a local
client of this machine's acpmux unix socket (`ACPMUX_SOCKET`, else the home
`cmux acp` uses). An app on another machine reaches it through the SSH or
server carrier; no acpmux port is opened. The daemon advertises the
capability when it resolved that path at start; an attach while nothing listens there answers `agent_session.unavailable`. WebSocket clients and the
remote relay (`cmux link`) are refused. These commands bypass the ordered
surface queue.

Every command names the tab by `surface`. The tab must be an `agent_session`
tab of this store with a bound session, and acpmux must resolve it to a
session whose id or full name is exactly that string (never a prefix);
otherwise `agent_session.unknown_tab`. The session always
comes from the store record: no command takes a session id, a cwd, a command,
an agent or an MCP server, and every unknown param is
`agent_session.bad_request`. Other error codes: `agent_session.not_trusted`,
`agent_session.unavailable` (no acpmux), `agent_session.not_attached`,
`agent_session.limit` (8 attachments per connection, 64 per daemon, 8 calls in
flight per attachment), `agent_session.timeout` (5 s), `agent_session.refused`
(acpmux refused), `agent_session.bad_list` (acpmux's session list could not be
read whole: a bad or repeated cursor, a page with no `sessions`, or a page after
the first that failed; an attach whose watch list does so is refused, and
attaches again),
`agent_session.unknown_permission`,
`agent_session.read_only` (a mutation sent to an observation attachment),
`agent_session.mode_conflict` (an `agent-session-attach` or
`agent-session-observe` for a surface this connection already has attached in
the other mode; detach first to switch modes), `agent_session.not_shared` (a
teammate's frame for a surface that no longer shows the chat its share named;
see `agent-session-proxy-bind`).

### agent-session-attach

`{id, cmd:"agent-session-attach", surface, after_seq?, before_seq?, limit?, kinds?}`
subscribes the connection to the tab's session and answers acpmux's attach
page `{session, events, hasMore, lastSeq}` (`limit` 1 to 500, default 200;
`kinds` at most 32 acpmux record kinds or categories; at most 8 MiB of
records, the rest left for the next page with `hasMore`). On an attached tab
it only pages. Live records then arrive as
`{event:"agent-session-record", surface, record}` (one acpmux record in its
`eventStream` form), permission requests as
`{event:"agent-session-permission", surface, request}`, and the session's
status and queue changes as `{event:"agent-session-changed", surface, change}`
(acpmux `session_changed` of that session only). The attachment ends with
`{event:"agent-session-closed", surface, reason}`: `detached` (the tab closed
or now shows another session), `lagged` (acpmux dropped records), `overflow`
(the client did not read its stream), `acpmux_closed`, or `too_large` (an
acpmux line over 32 MiB). The close is a control message and can arrive before
records still queued, which may be dropped; what the client received is
always a gap-free prefix of the log, so it attaches again with `after_seq` set
to the newest seq it holds. A record never overtakes the attach reply.

### agent-session-observe

`agent-session-observe-v1` is advertised with `agent-session-attach-v1` when
the daemon resolved its acpmux socket. `{id, cmd:"agent-session-observe",
surface, after_seq?, before_seq?, limit?, kinds?}` creates a read-only
attachment and answers the same page as `agent-session-attach`. It emits the
same `agent-session-record`, `agent-session-changed`, and
`agent-session-closed` events, and clients resume from the newest received
`seq` after a `lagged`, `overflow`, `acpmux_closed`, `too_large`, or `detached`
close. `agent-session-prompt`, `agent-session-cancel`, and
`agent-session-permission` are refused before acpmux is called. An observe on a
surface this connection already attached with `agent-session-attach`, or an
attach on one it observes, answers `agent_session.mode_conflict` and keeps the
existing attachment unchanged; the same mode again only pages.

### agent-session-events

`{id, cmd:"agent-session-events", surface, after_seq?, before_seq?, limit?, kinds?}`
pages the log of an attached tab, as acpmux's `_acpmux/events`
(`{events, hasMore, lastSeq}`), with the same bounds.

### agent-session-prompt

`{id, cmd:"agent-session-prompt", surface, prompt_id, text}` sends one text
prompt (at most 64 KiB; `prompt_id` 1 to 128 letters, digits, `-` or `_`) as a
single ACP text content block and answers once acpmux recorded it:
`{prompt_id, turn_id, queued}`. The reply streams as records.

### agent-session-cancel

`{id, cmd:"agent-session-cancel", surface}` cancels the running turn.

### agent-session-permission

`{id, cmd:"agent-session-permission", surface, permission_id, option_id,
answers?, annotations?, decision_nonce?, person_decision?, answered_by?}`
answers a permission request acpmux announced on this attachment (pending at
attach or sent as `agent-session-permission`), once (a failed answer can be
sent again). The daemon never answers a request by itself.

`answers` is a question's answers, a JSON object of at most 64 KiB, passed to
acpmux unchanged as `answers`; acpmux checks them against the question, and a
decision proof for that answer covers them (`acpmux-person-decision-answers-v1`).
Any other value is a bad request. `annotations` (Claude Code's chosen preview
and notes, by question) goes the same way, only beside `answers`, and the proof
covers it too.

`decision_nonce` and `person_decision` (64 lowercase hex characters each) are
the person's decision proof for this answer, which the app makes with the
person key it gave acpmux (acpmux `hub/person.rs`); `answered_by`
(`{device, feed_item}`, each 1 to 128 characters of `[A-Za-z0-9_.:-]`) names the device the person
answered on. The daemon checks only their shape, holds no person key, and
passes them to acpmux unchanged as `_meta.acpmux` `decisionNonce`,
`personDecision` and `answeredBy {device, feedItem}`; acpmux decides. A
request announced as `agent-session-permission` carries acpmux's
`decisionNonce` and `personInstance`.

### agent-session-detach

`{id, cmd:"agent-session-detach", surface}` ends the attachment. Closing the
connection ends all of its attachments.

### agent-session-children

`agent-session-children-v1`: `{id, cmd:"agent-session-children", surface}` on an
attached (or observed) tab answers `{sessions}`: the chats the tab's session
started on this machine, as acpmux summarizes them (`_acpmux/sessions`, in its
order), at most 256 and 8 MiB. A chat is listed when its `startedBy` (a
sub-session's link, at any depth) or its `spawnedBy` (`acpmux new` run in the
session) names the tab's session or another chat listed. Never the session
itself, another chat of the machine or a peer daemon's session; the command
names no session (any other param is `agent_session.bad_request`).

From the attach on, the attachment follows those chats: their acpmux
`session_changed`, and that of a new chat whose summary names the session or
a followed chat as its parent, also arrive as `agent-session-changed` on the
tab (`change.sessionId` names the chat). Every chat listed or followed may be
filed under this store's `registry:` host with its session in
`new-conversation-tab`, as a chat this machine started (the app opens a child
chat in a tab of its own and shows it with `agent-session-attach`); any other
session there is `conversation_tab.machine_mismatch`.

### agent-session-typing, agent-session-view

`agent-session-presence-v1` (advertised with `agent-session-attach-v1`): who is
in an attached chat (chat multiplayer, hq#4389). On an attached (or observed)
tab, `{id, cmd:"agent-session-typing", surface, on}` tells acpmux the person
starts or stops typing (`_acpmux/typing`, at most 2 a second per attachment;
past it acpmux's `typing.rate_limited` answers `agent_session.limit`; an `on`
expires after 8 s), and
`{id, cmd:"agent-session-view", surface, visible}` whether the person's window
shows the chat (`_acpmux/view`; a new attachment counts as shown). Both answer
`{}` and name no session: `on` and `visible` are booleans and any other param
is `agent_session.bad_request`. An observation attachment may send
`agent-session-view` but never `agent-session-typing` (`agent_session.read_only`).

A connection that echoed `agent-session-presence-v1` in `set-client-info` then
gets `{event:"agent-session-presence", surface, presence}` on every change (one
that did not never gets it), where `presence` is acpmux's `_acpmux/presence`
`{sessionId, participants}` of that session only. The attach page carries the
set at attach in `presence`, as acpmux answers it.

### agent-session-set-model, agent-session-set-mode, agent-session-set-config

`agent-session-settings-v1` (advertised with `agent-session-attach-v1`): the
person's picks in an attached chat's model, mode and option menus. On an
attached tab, `{id, cmd:"agent-session-set-model", surface, model_id}`,
`{id, cmd:"agent-session-set-mode", surface, mode_id}` and
`{id, cmd:"agent-session-set-config", surface, config_id, value}` send acpmux's
ACP `session/set_model {sessionId, modelId}`, `session/set_mode {sessionId,
modeId}` and `session/set_config_option {sessionId, configId, value}` on the
tab's own session, and answer acpmux's result unchanged (a
`session/set_config_option` answers the agent's whole `configOptions`). Each id
and `value` is a string of 1 to 256 ASCII letters, digits and `._-/:@[]+` not
starting with `-`; anything else, and any other param (a session id, `_meta`), is
`agent_session.bad_request`. acpmux and the agent decide whether the value is
one the chat offers (a refusal is `agent_session.refused`). An observation
attachment gets `agent_session.read_only`, and a teammate's or link guest's
attachment `agent_session.not_trusted`: only the chat's owner changes how its
agent runs. The app checks the person's gesture (and its full-access rule)
before it sends one; an app without the capability says the pick needs that
machine's cmux-tui updated.

### agent-session-login

`agent-session-login-v1` (advertised with `agent-session-attach-v1`): a Cloud
chat's own sign-in on this machine, from the app's sign-in card. On an attached
tab, `{id, cmd:"agent-session-login", surface, op, ...}` sends acpmux's
`_acpmux/agent_login/<op>`: `op:"start"` with `agent` (`claude` or `codex`)
sends `{agent, sessionId}`; `op:"finish"` with `login_id` and optionally Claude's `code`
sends `{loginId, sessionId, code?}` and may wait up to 15 minutes (Codex waits
for the person's approval); `op:"api_key"` with `agent` and `key` sends `{agent,
key, sessionId}`; `op:"cancel"` with `login_id` sends `{loginId,
sessionId}`. `sessionId` is always the tab's own session. acpmux's result comes back unchanged; its
refusal comes back as an answer, `{refused:{reason}}` with its `data.reason`
(`unsupported` from an acpmux without the method). A missing or oversized field,
another agent, another `op` or any other param is `agent_session.bad_request`.
An observation attachment gets `agent_session.read_only`, and a teammate's or
link guest's attachment `agent_session.not_trusted`: only the chat's owner signs
its agent in. The code and key are never logged.

### agent-session-proxy-bind, agent-session-of

A shared chat (`cmux host share`, chat multiplayer) reaches a teammate through
the owner's own host proxy, never by a teammate's own connection to this
daemon. `{id, cmd:"agent-session-proxy-bind", author:{login, node}}` makes a
same-user Unix connection that proxy's link for one teammate: `login` (at most
320 bytes, lower-cased) and `node` (at most 255) are the tailnet identity the
proxy checked, and the daemon fixes the author to
`{id:"tailnet:<login>", name, login, node}`. It is refused
(`agent_session.not_trusted`) on a WebSocket or remote-relay connection, a
second time on the same connection, as anything but the connection's first
line, or with any `_host_` field; it answers `{app, protocol, version, generation, capabilities}` and nothing
about the machine's sessions or paths.

Every later `agent-session-*` frame on a bound connection carries
`_host_author` (exactly the bound author, else `agent_session.not_trusted`)
and, except `agent-session-detach`, `_host_session`: the chat the owner shared.
The frame is refused as `agent_session.not_shared` unless the surface shows
that chat now, so a tab rebound to another chat is not shared. An unbound
connection sending either field, or any connection sending another `_host_`
field, is `agent_session.not_trusted`. A bound
attachment stamps the author on every acpmux call (`_meta.acpmux.author`),
pages and streams only the `transcript` kinds, never gets a `composer` record
(a draft), a `presence` set or event, a descendant's change, or the session
summary's folder, parent, children, tags, tools, rules, MCP servers, peer or
pull requests (the change keeps `sessionId`, `kind`, `recordKind`, `seq` and
the cut summary). A bound connection may send only `agent-session-attach`,
`-observe`, `-events`, `-prompt`, `-cancel` and `-detach`; any other frame
(`agent-session-start`, `-trust`, `-media`, `-children`, `-permission`,
`-typing`, `-view`, `-of`, or any other daemon command, resource or page
line) is `agent_session.not_trusted`. Each request uses the chat its check
validated: an attach, a page or a command on an attachment of another chat,
and a page acpmux answers after the tab was rebound, are refused as
`agent_session.not_shared`. A rebind waits for any write to or for a teammate's
attachment that has checked its tab, so nothing of the old chat reaches the
teammate (and no prompt or cancel reaches the old chat) after the tab shows
another chat; the attachment ends at its next event.

`{id, cmd:"agent-session-of", surface}` answers `{surface, session}`, the
agent session the tab shows, so `cmux host share` can pin it; only the owner's
own unbound same-user Unix connection may ask (otherwise
`agent_session.not_trusted`; a tab with no session is
`agent_session.unknown_tab`).

### agent-session-start

`agent-session-start-v1`: `{id, cmd:"agent-session-start", surface, cwd, harness?}` (and, when `agent-session-start-model-v1` is advertised, optional `model`)
starts a new chat for an agent tab of this store in this machine's own
acpmux and binds it to the tab, then answers
`{surface, session, conversation}` (the tab's record, as
`bind-conversation-tab-session` answers). The client then shows it with
`agent-session-attach`. The tab must be an `agent_session` tab of this store
whose `host` is `registry:` and this store's `identify.session_id` (so a tab
recorded for another machine never starts here) and that has no session yet;
otherwise `agent_session.unknown_tab`, or `agent_session.bound` when it has
one (also when another start bound it first: the new session is then ended).
The bind records the harness acpmux answered for the new session (its
`session/new` reply's `_meta.acpmux.harness`, a profile by its last part,
else the family it runs).
`harness` is the agent kind acpmux resolves from its own config (1 to 64
letters, digits or `_`, `.`, `-`); `cwd` is an absolute folder (at most 4096
bytes; acpmux checks that it exists). `cwd` follows `agent-session-trust`'s
home folder rule: `/` and folders above the home folder are
`agent_session.above_home`, the home folder needs `home_confirmed: true`
(else `agent_session.home_unconfirmed`). The folder must already be trusted on
this machine (acpmux's folder trust decision, else the agent's own level for
Claude and Codex), checked before the agent starts and again for the family
it runs; otherwise `agent_session.untrusted_folder` (the daemon never answers
the trust question; the person answers it on the machine or through
`agent-session-trust`). There is no command, env, policy, mode,
peer, preset or MCP server param; `model` is only accepted with the additive
`agent-session-start-model-v1` capability and is passed to the first session; an unknown param is
`agent_session.bad_request`. The machine kind decides first, read again at
each start: a team VM (kind `team` in the root-owned `/etc/cmux/vm-kind` that
cmux-host writes at a team enroll, or the team files root `/srv/team`,
root:`cmux-ssh`) goes on only with `vm_kind: "owner"` (the Cloud API gives
that answer to the machine's creator alone) and otherwise answers
`agent_session.team_vm_blocked`; Macs and SSH hosts go on; any other Cloud VM
goes on only with `vm_kind: "owner"` and otherwise answers
`agent_session.host_unverified`. `vm_kind`
(`agent-session-start-vm-kind-v1`) is the Cloud API's `vmKind` for the
caller, as the caller read it on its link to this machine (attach-endpoint);
only the exact string `owner` counts. Any other value says the caller knows
this machine is a Cloud VM it does not own, so it answers
`agent_session.host_unverified` on any host (a guest's root can remove every
Cloud sign the daemon reads). The app starts a chat on a machine it knows as
Cloud only on the `owner` answer for the link the start goes over, through any
daemon. The VM's own
kind `owner` (written at a machine bind) never allows a start by itself: the
agents there keep sudo and can write it. A chat move in
(`agent-transfer-receive`, `-finish`) and `agent-session-trust` take the same
rule with their own `vm_kind`. The session starts with permission policy `ask`
whatever the daemon default is. It must then be in a mode that acpmux's
remote table (`_acpmux/web_modes`) says asks before acting: a family that
table refuses (Codex, opencode) is refused, and a session that starts in a
mode that does not ask moves to its family's asking default; otherwise it is
ended and the answer is `agent_session.not_asking`. When nothing listens on
the acpmux socket the daemon starts acpmux once (one start at a time), as
`cmux acp` does, and answers `agent_session.acpmux_unavailable` if it still
cannot connect (always, while acpmux is down, under `ACPMUX_SOCKET`). At
most 8 starts run at once per daemon and one per tab
(`agent_session.limit`); acpmux has 60 s to create the session
(`agent_session.timeout`). Trust is the attach verbs': trusted local (Unix)
connections only. The session is a local-control acpmux session (the
daemon is acpmux's unix client): only the refused-family, start-mode and
folder-trust checks repeat acpmux's remote rules; its remote approval floor,
sandbox, folder-profile refusal and agent tools rules do not apply, and later
prompts and permission answers through the attach verbs are local control
(plans/cmux-next/remote-agent-attach.md, "Remote start").

`agent-session-start-keyed-reason-v1` (cx-0w0jj): a client that signs the
person's relayed allows with a person key of its own (the app's keyed acpmux
restart, `acp daemon start --person-key-fd`) sends `require_person_key: true`
and, when it holds one, `person_instance` (the acpmux run, `personInstance`,
it holds a key for; 1 to 128 letters, digits or `_`, `.`, `:`, `-`). The
daemon then reads its acpmux's `_acpmux/status` after the request, machine,
tab and home folder checks and before acpmux is contacted for the start (it
never starts acpmux for this check), and the start goes on only
when that run holds a person key and is the named run. Otherwise the answer
is `agent_session.needs_keyed_start` with
`data: {reason: "needs_keyed_start", safe_to_restart, live_agents, remote_sessions}`:
`safe_to_restart` is true only when acpmux does not run, or it is `ready`,
keeps agent hosts across a restart (`agentHosts`) and runs no live agent
(`liveAgents` 0) and no session proxied from a peer (`remoteSessions` 0);
`live_agents` and `remote_sessions` are those counts (0 when acpmux does not
run; null when the status lacks one, which is never safe). Only nothing
listening on the socket counts as acpmux not running; any other connect
error, or a status that cannot be read, answers `safe_to_restart: false`
with null counts. The refusal never
carries the run id or any key material. The client restarts acpmux with its
key itself (and only on `safe_to_restart`, or after the person's click), then
starts again; this check does not close the race with an agent that starts
between the check and a restart (cx-ofowe).

### agent-session-trust

`agent-session-trust-v1`: `{id, cmd:"agent-session-trust", surface, cwd, level?}`
reads or records the trust of a folder of this machine for a chat of this
store (cx-1bhjj), so a chat that `agent-session-start` refused with
`agent_session.untrusted_folder` starts once the person trusts the folder.
Without `level` it answers acpmux's `acp.trust.get {cwd}` reply
(`{cwd, level, harnesses?, decided?}`); with `level` (`trusted`, `untrusted`
or `unknown`, which forgets the answer) it answers acpmux's
`acp.trust.set {cwd, level}` reply. Any other level, a `cwd` that is not
absolute (at most 4096 bytes, no control characters) or an unknown param is
`agent_session.bad_request`; acpmux checks that the folder exists. A
`trusted` answer for `/` or a folder above this user's home folder is
`agent_session.above_home`; the home folder itself takes `trusted` only with
`home_confirmed: true` (the person chose it as the chat's folder first, as
Use Home Folder on the Mac), else `agent_session.home_unconfirmed`. The tab
must be an `agent_session` tab of this store whose `host` names this store
(bound or not), else `agent_session.unknown_tab`; the machine kind gate
(with `vm_kind`, `agent-session-trust-vm-kind-v1`), the trusted local
connection rule and the acpmux start are those of `agent-session-start`. A
page cannot vouch for the Cloud API's answer: the routed operations take no
`vm_kind` (`agent_session.bad_request`), so they reach no Cloud VM's trust. The daemon never answers by itself: a client sends a
`level` only for the person's own answer (the app's agent pane relay needs
a fresh gesture for a set that trusts, as for a chat on the Mac's own
acpmux). Pages reach the same verb only as the routed v2 operations
`agent_session.trust.get {surface, cwd}` and `agent_session.trust.set
{surface, cwd, level}` (page-router.md, namespace
`agent_session`, hq-6d): only page `agent` (the agent pane and its New Tab
page) may read, every other page gets `origin.forbidden` (the trust state
tells a page which folders the person works in), and a set needs the
person's gesture, a host confirmation the daemon checks for exactly that
request (`origin.forbidden {reason: "gesture_required"}` without it), and
origin user. A page never trusts a home folder (`home_confirmed` is a bad
request there: a page cannot prove the person chose the home folder first).
The legacy `agent-session-trust` command stays local-Unix only: a page relay
cannot send it, WebSocket and remote relay connections are refused; the
page path is only the v2 names through the page router. Known limit (hq-6d):
a plain trusted local unix client keeps acpmux's own rule and answers
without a gesture, as it can on acpmux's own socket (same uid); the app's
chat on another machine reaches the verb that way, behind its relay's
fresh-gesture rule. A WebSocket client of acpmux still cannot
answer (`trust.remote`). At most 8 calls run at once (`agent_session.limit`).

## Machine catalog publication

On Unix builds, `identify` advertises `machine-catalog-publish-v1`. The verified
local cmux app may send `{id, cmd:"machine-catalog-publish",
expected_machine_id:"machine_…", sequence:1, machines:[...]}` on its existing
connection. This is an internal host publication handshake, like app-provider
registration; callers continue to discover machines through the existing
`machine.list` and `machine.get` catalog operations, CLI and SDK surfaces.
It is not another machine-list operation or an enrollment command.

Readers explicitly request `catalog:true` on `machine.list/get` to receive owner
metadata and projected remote origins. `identify` advertises
`machine-catalog-read-v1` for this option. Without it, or with `catalog:false`,
these reads retain the original local-only shape so strict older machine
decoders remain usable even while a publisher is active. Session snapshots retain that original
shape too. The CLI exposes the option as `--catalog`; MCP exposes the typed
boolean `catalog`. A machine-prefix lookup forwards the same opt-in on its
existing connection. This parameter changes the response format and catalog
visibility, never execution authority.

The required owner ID must match this daemon's persisted public ID. Each remote
record has a canonical `id`, bounded display `name`, `origin` (`cloud`, `ssh`,
`server`), `status` (`running`, `connecting`, `unavailable`, `sleeping`, `stopped`),
optional `platform:{os?,arch?}`, and up to 16 bounded capability tokens. A snapshot
has at most 256 records and a 128 KiB frame. Unknown fields, local impersonation,
duplicate IDs, malformed tokens, control characters, paths and command fields
are refused atomically. No credentials or connection endpoints are published.

Exactly one live verified-app connection owns the projection. A positive,
increasing `sequence` replaces it atomically; exact replay is harmless and an
older or conflicting sequence is `machine_catalog.stale`. A competing connection
gets `machine_catalog.taken`. Disconnect removes the entire publication under
the client-registry lock. Unverified, agent-bound, WebSocket and remote relay
clients cannot publish (`machine_catalog.not_trusted`); a wrong daemon is
`machine_catalog.owner_mismatch` and malformed data is `machine_catalog.bad_request`.

The native local record always remains first and authoritative. Remote metadata
is read-only: it never opens a connection, creates a session, supplies routing
credentials or grants command execution. Remote session operations still require
their own authenticated owner path; catalog membership never falls back to a local
session. Without a publisher the existing local-only behavior is preserved.
The app observes existing policy-admitted registry routes and publishes on its
captured local connection. A new handshake starts a new lease; temporary source
loss or restarting the observer preserves the sequence of a still-live lease.
Removed or denied routes are withdrawn, and late acknowledgements from an old
owner cannot become current. Platform and capabilities come only from each
owner's handshake. Legacy owners remain unknown and never receive an
unnegotiated publication. This transitional projection does not enroll or dial
machines, and it is not the final shared machine registry.

## Agent CLI inventory

`agent-inventory-v1` is advertised when the daemon has its own acpmux socket
configured. A trusted native connection (the app's local, SSH or Cloud carrier)
may send `{id, cmd:"agent-inventory"}`. WebSocket clients and the
conversations-only remote relay cannot use it. This command reads this daemon's
machine only; it accepts no machine, session, socket or command selector.

With `agent-inventory-owner-v1`, a client selecting a public machine ID sends
`{id, cmd:"agent-inventory", expected_machine_id:"machine_…"}`. The daemon
validates the canonical ID and compares it to its own persisted machine ID
before checking or opening acpmux. A different owner returns
`agent_inventory.owner_mismatch` without an owner call or local identity in the
response. The field is an identity fence, never a routing selector. Clients must
negotiate this capability separately, require a known public machine ID and
propagate a mismatch instead of removing the fence or retrying elsewhere.
All other fields remain refused.

The daemon first calls `initialize` on its own acpmux socket and requires the
exact `harnessInventory` feature in a string array at `_meta.acpmux.features`.
Only then, on that same connection, it calls
`_acpmux/harness/health {view:"inventory"}`. Older owners never receive the health
request: an older acpmux can ignore `view` and run checks or updates. There is no
legacy fallback, daemon start, handoff, PATH scan, registry lookup or refresh.

The response's `data` is `{view:"inventory", cached:true, harnesses:[...]}`.
Each row contains only `id`, optional `family`, `channel`, `version`, `latest`,
`latestCheckedAt`, `outdated`, `auth` and `checkedAt`. `family` is a recognized
CLI family inferred from the executable and package saved by the same health
check, never from the profile id or current configuration. Old owners omit it;
missing executables, launchers, ACP adapters and conflicting evidence leave it
null. Native forwarding also leaves unknown future families null. A family does
not make this partial cache exhaustive. Versions and latest-check times may be null;
times are milliseconds since the epoch. Channels are `npm`, `bun`, `brew`,
`brewCask`, `native`, `launcher`, `standalone` or `missing`. Sign-in evidence is
`signedIn`, `signedOut` or `unknown`, without account labels. No program paths,
commands or diagnostic output are forwarded. Empty rows mean no cached
observations, not proof that the machine has no installed agents. At most 256
rows and eight concurrent reads per daemon are accepted.

Failures have an `agent_inventory.*` error code: `not_trusted`, `bad_request`,
`unavailable` (including a stopped or unresponsive owner), `unsupported` (no
negotiated view), `owner_mismatch`, `busy` or `invalid_response`. An unavailable remote owner is
never replaced with this computer's inventory.

### Explicit registry refresh

`agent-inventory-refresh-v1` adds the internal native carrier
`{id, cmd:"agent-inventory-refresh", expected_machine_id:"machine_…"}`.
The canonical owner condition is required, checked before socket lookup or
worker admission, and never selects another machine. Trust and relay admission
precede params. Successful replies use the same sanitized partial-cache shape
as `agent-inventory`, with an additional `machine` echo from the handling daemon.
This is a machine identity condition, not a daemon-incarnation or job receipt.

On its captured acpmux link, the daemon requires `harnessInventoryRefresh`, then
calls exactly `_acpmux/harness/inventory/refresh {}`. No caller params reach
acpmux, and no legacy health fallback, acpmux start or handoff is allowed.
Both carriers and watch handshakes share the eight-worker budget. The refresh
RPC waits at most 25 seconds; its acpmux operation is bounded at 20 seconds and
refuses overlapping health checks/refreshes without queueing.

The raw operation is local-socket-only, accepts only an empty object, and is
never forwarded to a peer. It asks the owner's fixed registries for the
installations already represented in the visible cached inventory, deduplicating
URLs with at most four requests in flight. It never runs a CLI or auth check,
reads sign-in files, rescans profiles, changes auto-update preferences or
schedules an update. Empty caches remain unknown. Failed sources retain their
older latest version and timestamp; only successful comparable answers update
`latest`, `latestCheckedAt` and `outdated`. Installed-version/auth observations
and `checkedAt` remain cached, so `cached:true` remains accurate. A configuration
replacement refuses an answer from its former source.

This carrier supports the existing proposed app operation
`agent_cli.list {check_latest:true}`; it is not a separate generic SDK, CLI or
MCP command. App/provider wiring still requires its own verification. Ordinary
reads and subscription invalidations stay cache-only and never request this
refresh implicitly. Registry observations cannot complete an execution job.

## Agent CLI updates

### Cached owner-job plan

The internal acpmux operation `_acpmux/harness/update/plan {cli}` requires
`harnessUpdatePlan` on the captured link. It accepts only a bounded CLI family
identifier, never a profile, machine, session, command, prefix or package. It is
local-socket-only and never forwards to a peer. This is an internal carrier,
not a generic SDK command or permission to execute.

The response is exactly `{cached:true, cli, argv:[...]}`. Selection uses one
cached snapshot, comparable installed/latest versions and an outdated plan
that does not need elevated rights. Identical targets across profile aliases
deduplicate; distinct targets refuse as ambiguous. Bound npm plans preserve
the recorded package or fork and absolute prefix. Native plans require the
cached absolute executable and its known update verb. Bun and Homebrew plans
refuse until they bind their installation explicitly. A cache above 256 rows
refuses rather than silently omitting another target.

Planning never probes a CLI or credentials, checks registries, starts an owner,
rescans profiles, changes preferences or schedules an update. An empty cache is
unavailable. Unknown or unusable version/target evidence is not updatable;
neither means an already-current success. Execution must separately admit the
caller, revalidate the actual installation, and create a visible job on this
owner. A cached argv is advisory and must not be treated as execution authority.

Malformed params return invalid params; nonlocal origins refuse before params.
Selection failures use `harness_update_plan.unavailable`, `.not_updatable` or
`.ambiguous` in the RPC error's `data.reason`. No legacy fallback is permitted.

The separately negotiated `harnessUpdatePrepare` operation
`_acpmux/harness/update/prepare {cli}` uses the same strict input, origin and
selection rules. It revalidates every matching cached installation against
the filesystem, refuses a changed channel, package, prefix or native target,
and captures an absolute npm manager from this owner. It returns only
`{cli, argv}`. A cache or home change during preparation refuses as
`harness_update_plan.busy`. It never probes versions/auth, queries registries,
writes preferences or executes the plan. The admitted job owner must persist
the exact argv and audit context before execution. Preparation is not a grant
and cannot complete a job.

### Native visible update job

`agent-cli-update-job-v1` adds the internal native carrier
`{id, cmd:"agent-cli-update-job", expected_machine_id, expected_session_id, cli, idempotency_key}`.
Only a proved main-app Unix connection without an agent binding may call it.
The canonical machine and session conditions are required and checked before
worker admission or socket access. A machine can host multiple daemon sessions;
the same machine ID cannot authorize a replacement session to execute a job.
An enriched `identify {machine_metadata:true}` includes `session_resource_id`
alongside `machine_id`; the legacy registry UUID is not a public session ID.
Unknown fields, including argv, shell, socket, session selectors and
actor claims, refuse. The daemon derives the audit actor from the connection.
App `agent_cli.update` execution scopes remain unsupported; this carrier does
not grant one or upgrade an opaque actor forwarded by a provider.

The Rust owner serializes preparation, then looks up stable intent in its
existing correlated workspace-creation journal before requiring acpmux. The
intent binds machine, session, CLI, operation and actor to the original mutation key.
A receipt replays with acpmux offline or inventory changed; a changed intent
conflicts. A new job negotiates `harnessUpdatePrepare` on one captured local
link and sends only `{cli}`. There is no legacy update, owner start, handoff,
focused-pane or shell-typing fallback. The exact prepared argv and original
audit actor are journaled before a dedicated terminal workspace is executed.

Successful data is `{machine, session, cli, path, revision, replayed}`, where path is
the existing public created-terminal path and revision is decimal text. This
acknowledges creation, not update completion. The same owner's
`terminal.wait_exit` supplies the durable outcome; inventory invalidations
cannot settle the job. A disconnected observer does not end the owner job.
Executing-unknown recovery stays `mutation.indeterminate` and never triggers
an automatic new-key run. An unexecuted reservation can resume only when fresh
preparation still matches its exact persisted argv. Worker admission shares
the bounded inventory budget; concurrent job preparation may refuse busy.

`agent-update-v1` (advertised with `agent-session-attach-v1`) lets a trusted
local (Unix) client, the app's Update Everything on this Mac or through the
SSH or Cloud carrier, update this machine's agent CLIs and move its chats
onto the new versions. The daemon asks the machine's own acpmux as its unix
client; no command travels: acpmux builds every update from how each CLI was
installed (npm, bun, Homebrew, the vendor's own updater) and never runs one
that needs elevated rights (an install folder this user cannot write, or a
program such as `sudo`). The remote relay does not list these verbs and a
WebSocket client is refused (`agent_update.not_trusted`); an unknown param is
`agent_update.bad_request`.

With `agent-update-owner-v1`, a client selecting a machine captures its
canonical `machine_id` from `identify {machine_metadata:true}` on that
connection and includes `expected_machine_id` on either update verb. The
condition verifies this exact daemon before socket lookup, health calls,
acpmux startup or apply-slot admission; it never selects another machine.
A malformed or null condition (including aliases such as `current`) is
`agent_update.bad_request`. A foreign canonical ID is
`agent_update.owner_mismatch`, with no result data or disclosure of the
actual owner. Trust checks and default-denied relay admission still precede
the condition.

Successful opted-in replies add `machine`, the daemon's canonical ID.
Omitting the condition preserves the exact legacy response shape. A client
requiring a selected owner must negotiate this capability before using the
condition; an unsupported owner cannot become an unfenced update. This is
an identity condition, with existing execution admission unchanged. It
creates no job or idempotency receipt; a lost apply reply remains uncertain.

### agent-update-plan

`{id, cmd:"agent-update-plan"}` answers
`{harnesses:[{id, name?, version?, latest?}], live_threads, running_threads}`.
`harnesses` are the rows of acpmux's last agent CLI health check
(`_acpmux/harness/health`) that are outdated and whose update needs no
elevated rights; `name` is the profile's display name, `version` the
installed one and `latest` the newest its channel offers. `live_threads`
counts the chats with a running agent (status `ready`, `running` or
`waiting`), `running_threads` those in a turn (`running` or `waiting`),
leaving out chats mirrored from a peer and the Home Chief's (tag
`cmux.chief`, a name starting `optchat-`, or a harness starting
`optchat-compact-`). When nothing listens on the acpmux socket the answer is
no harness and no thread: a plan never starts acpmux.

### agent-update-apply

`{id, cmd:"agent-update-apply", ids, continue_threads?}` updates the named
harnesses (at most 64 ids) and answers
`{results:[{id, ok, version?, error?}], threads_restarted, threads_after_turn, threads_failed, threads_error?}`.
acpmux checks its harnesses again, runs now the update of each named one that
is still outdated (one at a time, each command once, whatever its
auto-update choice), waits for it (each may take 15 minutes) and checks
again: `ok` with the installed `version`, or `error` with the update's last
output line or why it did not run (an update that needs elevated rights
names the command to run by hand). A harness already current is `ok`
without a run only when its installed and latest known versions are
comparable and the installed version is at least the latest. Missing or
unparseable latest-version evidence cannot turn a false `outdated` flag
into success; the named harness is refused without running an updater.
With `continue_threads: true` every live chat (as counted by
the plan) of a harness that ended `ok` then restarts its agent process on
the installed version and resumes the same conversation: a chat between
turns now (`threads_restarted`), a chat in a turn when that turn ends
(`threads_after_turn`; the turn is never cancelled). A chat acpmux could
not restart keeps running its old agent and counts in `threads_failed`, with
the first one's reason in `threads_error`. When the restart call itself
fails the answer still carries `results`, with `threads_error` (a string
saying why) and every count 0; clients ignore the field when absent. When
nothing listens on the acpmux socket the daemon starts acpmux as
`agent-session-start` does (`agent_update.acpmux_unavailable` if it cannot).
Only when the running acpmux does not know the update method (JSON-RPC
-32601, a build from before it) does the daemon hand it off to the installed
binary's build: acpmux stops with its agents kept running (`cmux acp daemon
shutdown --keep-agents`) and the installed binary's acpmux starts, under the
same lock as the daemon's other acpmux starts, and adopts them; if that
acpmux does not answer or still does not know the method the apply is
`agent_update.acpmux_unavailable`. A running acpmux of another build that
knows the method is used as it is, so an apply never moves acpmux to an
older build. The update call waits 15 minutes per named id plus a margin,
at most two hours. One apply runs at a time per daemon
(`agent_update.busy`); `agent_update.timeout` and `agent_update.refused`
report an acpmux that did not answer or refused, and `agent_update.bad_list`
one whose session list could not be read whole.

## Agent chat transfer

`agent-transfer-v1` lets a trusted local (Unix) client move an agent chat
from one daemon's acpmux to another's (Move to Cloud and back). The daemon
forwards acpmux's `acpmux.transfer.v1` calls (`_acpmux/transfer_*`, which
acpmux serves on its local socket only) to its own acpmux as a local client,
and every receive it forwards carries a guard the daemon builds itself, so
the chat arrives with its folder held to the guard's roots and asking for
permission (acpmux `transfer_in.rs`). The client copies the bundle between
the two daemons; neither daemon reaches the other. The daemon advertises the
capability when it resolved an acpmux socket path and its host (the binary
sets both at start). These commands bypass the ordered surface queue.

Who: trusted local connections only, as `agent-session-attach`. WebSocket
clients and connections that carry a link stamp get
`agent_transfer.not_trusted` before their frame is read, and the remote
relay (`cmux link`) answers `remote_denied`. No command takes a guard, roots,
control, env, MCP server, session id or command param; such a param or any
unknown one is `agent_transfer.bad_request`, before anything reaches acpmux.
Other error codes: `agent_transfer.unavailable` (no acpmux or host),
`agent_transfer.outside_roots`, `agent_transfer.unknown_tab`,
`agent_transfer.unknown_receive`, `agent_transfer.unknown_transfer`,
`agent_transfer.unguarded`, `agent_transfer.limit` (8 calls at once, 16
receives and 16 moves remembered for 24 h), `agent_transfer.timeout`,
`agent_session.team_vm_blocked` and `agent_session.host_unverified` (the
machine kind rule of `agent-session-start`, below), and
`agent_transfer.refused` (acpmux refused; the error text carries acpmux's
message, such as `transfer.exists` or `transfer.incomplete`). Pages carry at
most 4 MiB of data (base64).

### agent-transfer-receive

`{id, cmd:"agent-transfer-receive", manifest, cwd}` starts taking a chat:
`manifest` is the source's `agent-transfer-begin` manifest, `cwd` the
absolute folder the chat runs in here. The daemon builds the guard from its
own host: on a cmux Cloud host (the `fs-v1` test) `{control:"peer",
roots:[$HOME/work]}`; on any other host (a Mac taking a chat back)
`{control:"web", roots:[cwd]}`, where `cwd` must be an existing folder
strictly under `$HOME` and not in a dot folder of `$HOME`. Paths are
canonical, and `cwd` must be under the roots on every host; otherwise
`agent_transfer.outside_roots`. It sends `_acpmux/transfer_receive
{manifest, guard}` and answers `{receive_id, session_id}`. An acpmux that
does not answer `guarded:true` is refused (`agent_transfer.unguarded`). The
daemon keeps the receive's folder in memory for its finish; at most 16
receives are kept, checked before acpmux makes one.

Machine kind: receive and finish read this machine's kind at each call, as
`agent-session-start` does, each with its own `vm_kind`
(`agent-transfer-vm-kind-v1`, only `owner` counts), and answer
`agent_session.team_vm_blocked` on a team VM without the caller's
`vm_kind: "owner"` and
`agent_session.host_unverified` on any other Cloud VM without the caller's
`vm_kind: "owner"` (its own `owner` record never counts) or on a daemon never
told its kind. `cmux link agent move --vm-kind KIND` (the caller says the
target is a Cloud machine) sends it to a daemon that serves it; to an older
one it sends none and refuses any kind but `owner` before the chat freezes,
whatever that daemon advertises. Without the flag the caller says the target
is not a Cloud machine. With `--to-pid PID` (the Cloud link process the
caller read the kind from) the pump sends the receive and the finish only over
a connection whose peer is that process, else it refuses before the receive
and gives the chat back. A chat under peer control keeps its
permission policy and mode and runs its queue at once, so it lands only on
a Mac, an SSH host or a personal (owner) Cloud VM; under web control
acpmux also requires a policy and mode that ask.

A running turn: `agent-transfer-begin {interrupt: true}` stops it, and this
daemon's acpmux queues its continuation first, so the turn goes on where the
chat lands, or here if the move does not happen
(`agent-transfer-continues-v1`). `cmux link agent move --interrupt` asks for
the Stop only from a source that lists that capability; an older one would
stop the turn for good, so there the begin is refused while the turn runs. A
chat that is compacting is refused too (`transfer.busy`): a Stop then would
withdraw its queued prompts.

A receive id is not tied to the connection that made it: another trusted
local connection of the same user may write, finish or abort it (the pump
may reconnect). That grants nothing new: the folder comes from the daemon's
own record of the receive, never from the frame, and acpmux checks it again
against the guard it stored with the receive.

### agent-transfer-write

`{id, cmd:"agent-transfer-write", receive_id, path, offset, data}` writes one
page (`data` base64, at most 4 MiB decoded; `path` a relative bundle path)
of a receive this daemon guarded, and answers `{next}`.

### agent-transfer-receive-abort

`{id, cmd:"agent-transfer-receive-abort", receive_id}` forgets a receive
this daemon guarded; later writes and finishes of it are
`agent_transfer.unknown_receive`. It sends acpmux
`_acpmux/transfer_forget {transferId, sessionId}` with the ids of the
receive's own manifest (never from the frame), so acpmux drops the
receive's files and refuses that move from then on, and answers
`{dropped:true, forgotten, landed}` (`landed`: the chat had already arrived
here). An acpmux that cannot forget (an error or no answer) leaves the
receive as it was, live or settled, and answers `{dropped:false,
forgotten:false, landed:null}`: whether the chat landed is unknown, and the
question can be asked again. While a finish of the receive is running, a
receive-abort sends no forget and answers the same "cannot say yet". acpmux's forget is not a daemon command. A receive whose
manifest lacks a plain `transferId` and `sessionId` is
`agent_transfer.bad_request`.

A receive its finish ended (the finish succeeded, failed for good, or met a
team VM) stays askable: its receive-abort sends the same forget again and
answers `landed`, so a pump whose finish answer was lost learns whether the
chat arrived before it commits or aborts the source. Writes and finishes of a
settled receive stay `agent_transfer.unknown_receive`.

Every receive acpmux answered here stays askable the same way after it was
dropped and after a daemon restart: the daemon records its move and chat ids
(from the receive's manifest) in `agent-transfer-receives.json` next to the
session's registry, the 40 most recent for 24 h each, owner-only and read
only when it is this user's regular file (an in-memory session keeps them in
memory). A receive-abort of a receive the daemon no longer holds sends the
recorded forget again; acpmux's forget mark is on disk, so the answer is
real and a late finish can never land the chat. Writes and finishes of such
a receive stay `agent_transfer.unknown_receive`; a receive id this daemon
never recorded is `agent_transfer.unknown_receive` too.

### agent-transfer-finish

`{id, cmd:"agent-transfer-finish", receive_id, name?}` imports the chat in the
receive's own folder (sent as `cwd`; the client cannot name another) and
answers `{session}` (acpmux's session summary). Its queue then runs here, and
the summary's `sessionId` is remembered as landed here (see
`new-conversation-tab`). A
finish that fails for good (anything but a timeout, an unreachable or busy
acpmux, or `transfer.incomplete`) also forgets the receive.

### agent-transfer-begin

`{id, cmd:"agent-transfer-begin", surface, interrupt?, ask_first?}` freezes the chat of
an agent tab of this store (the session comes from the tab's store record,
as `agent-session-attach`; any other surface is `agent_transfer.unknown_tab`)
and answers `{transfer_id, source_session, manifest}` (`source_session` as
`agent-transfer-source`). The bundle's `manifest.json` is served
without the absolute `source` paths of its native files, and its
`session.json` without the source machine's launch settings (`sessionEnv`,
`harnessArgv`, `harnessRoots`, `preset`, `tags`); its `cwd` stays, since the
target's import needs a folder and its finish replaces it. These names
compare case-insensitively, and the manifest lists the scrubbed sizes. The
event logs still carry the source machine's paths; the guarded finish never
runs them.

With `ask_first: true` (Bring Back Local's "Ask first, then bring back",
after a Mac's guard refused the chat as `transfer.policy` or `transfer.mode`)
the daemon first narrows the chat in its own acpmux, each step only when
needed: a policy (the chat's own, else acpmux's default) other than `ask` or
`deny-all` becomes `ask` (`_acpmux/set_policy`); permission rules keep only
`autoDeny`, `ask` and a `default` of `ask` or `deny` (`_acpmux/set_rules`); a
mode, or `mode` config option, that this acpmux's asking table
(`_acpmux/web_modes`) does not list for the chat's family becomes the first
mode of the table's list that the chat offers. A chat already in a move is
not narrowed, so its begin is refused as without `ask_first`. The receiving
daemon's guard is unchanged. A step acpmux refuses fails the begin with that
refusal, and the chat stays, unmoved, keeping what was narrowed so far.

A begin of a chat that is already in a move is `agent_transfer.refused`
(acpmux's `transfer.moving`) with `error_details: {transfer_id}`, the id of
that move, so a pump that lost its begin answer can commit or abort the move
it began. Only that refusal carries details.

### agent-transfer-source

`{id, cmd:"agent-transfer-source", surface}` answers `{session}`, the session
an agent tab of this store is bound to, read from the tab's store record
without reaching acpmux; any other surface is `agent_transfer.unknown_tab`.
Unlike `agent-session-attach` it does not mark the chat seen or touch its
log, so a pump can tell the tab still shows the chat its recorded move took.

### agent-transfer-read

`{id, cmd:"agent-transfer-read", transfer_id, path, offset, limit?}` pages a
bundle file of a move begun through this daemon (`limit` 1 to 4 MiB, default
1 MiB) and answers `{data, next, eof}`. Only a path the begin manifest lists
is served, exactly as listed; any other is `agent_transfer.bad_request`.

### agent-transfer-commit

`{id, cmd:"agent-transfer-commit", surface, transfer_id, to}` ends the move on
this side once the target has the chat: the chat closes here. `to` (any JSON
up to 4 KiB) is recorded in the chat's log. Answers `{committed:true}`.

### agent-transfer-abort

`{id, cmd:"agent-transfer-abort", surface, transfer_id}` gives the chat back
as it was, only when the target does not have it. Answers `{aborted:true}`.
The daemon forgets the move even when acpmux refuses the abort.

## Access requests

`access-request-v1` keeps a Cloud machine's agents' requests for files and
secrets of the person's Mac (Move to Cloud, slice 6). An agent on the machine files a
request and polls its status; the app on the Mac lists the pending requests
through its machine link, decides on the Mac (a folder the chat was granted,
or the person's answer on an inline card), copies what it shares itself
with `fs-v1`, and answers. The daemon only keeps the requests: it never
reaches the Mac and grants nothing. Only a daemon on a cmux Cloud host
advertises and serves it (its `agent-transfer-v1` host, set at start);
elsewhere every command answers `access_request.unavailable`. The CLI on
both sides is `cmux link access` (`request` on the machine, `triage` and
`answer` on the Mac).

Who: trusted local (Unix) connections that are not remote clients. Others
get `access_request.not_trusted`; the remote relay (`cmux link`) answers
`remote_denied`. A command-bearing or unknown param is
`access_request.bad_request`. 64 requests are kept, pending or answered;
each is forgotten 15 minutes after it was made or answered
(`access_request.limit` when full; the machine's own agents can fill it, which only stalls that machine's requests). Other codes:
`access_request.unknown_request` and `access_request.answered`.

- `{cmd:"access-request", kind:"file", path, session?, reason?}` or
  `{cmd:"access-request", kind:"secret", name, session?, reason?}`: `path`
  is absolute (at most 4096 bytes), `name` a secret's name (`A-Za-z0-9._-`,
  at most 128 bytes), `session` the asking chat's agent session (plain, at
  most 200 bytes), `reason` at most 1000 bytes. Answers `{request_id}` (32
  hex digits).
- `{cmd:"access-request-status", request_id}`: `{state:"pending"}`,
  `{state:"delivered", path}` (where the Mac put a file on this machine),
  `{state:"delivered", value}` (a secret, to the first status read only;
  later reads get `{state:"delivered", taken:true}`) or
  `{state:"denied", reason}`.
- `{cmd:"access-request-list"}`: `{requests:[{request_id, kind, path, name,
  session, reason, age_ms}]}`, the pending ones, oldest first.
- `{cmd:"access-request-answer", request_id, outcome:"delivered", path}` (a
  file request), `{..., outcome:"delivered", value}` (a secret request, at
  most 64 KiB) or `{..., outcome:"denied", reason?}`: a pending request
  only. Answers `{}`.

A secret value is kept in memory only, never written or logged, and wiped
when the request is forgotten; its first status read takes it (best effort:
the frame and reply lines are plain buffers while read and written). The
Mac shares one only for one request the person answered
(`cmux link access answer --share-secret NAME`, the value on stdin byte for
byte, no newline removed). An agent's `request --secret` that stops waiting
withdraws its request (denies it), so a later answer is
`access_request.answered`.

## File system (fs-v1)

Servers advertising `fs-v1` serve file ops on their machine. In this
version only a daemon on a cmux Cloud host serves them (a Linux host whose
daemon carries the Cloud model-plane identity, `CMUX_CODEROUTER_URL` and
`CMUX_VM_ID`); its only root is the daemon user's home. Every other daemon
does not advertise `fs-v1` and answers every `fs.*` op with
`error_code:"fs.unavailable"`. The ops are accepted on the local socket and
on the link's remote entry, whose gate admits exactly these seven commands
and denies every other frame with `remote_denied`; WebSocket clients get
`fs.permission_denied`.
Access is granted only through the link's `daemon` service, and on a Cloud
host it covers the whole home of the daemon user. The team policy must
therefore never grant `daemon` to a principal that is not also allowed
`shell`/`ssh` on that machine. A remote dial must send its first line
within 10 seconds or it is closed. A byte stream is a registered remote
client bound to its stamped peer: a kick, the link closing the dial, a
revocation of the install, and the daemon's shutdown each end it at once
(a revoked install gets no new stream), and an unfinished write leaves no file. At start, the owner
removes its own leftover temporary files (`.<name>.cmux-<16 hex>.tmp`) that
are older than one hour, in a bounded walk of the root that follows no
symlink and stays on the root's file system.

Params are flat, next to `id` and `cmd`. Answers use the normal envelope;
a failure carries `error_code` and, where noted, `error_details`. Paths are
absolute. A path with a `.` or `..` component, a path outside the roots, and
a symlink whose target leaves the roots (in any component) are refused with
`fs.permission_denied`; a symlink that stays inside the roots is followed.
`revision` is `s<size>-m<mtime ms>`; entries are `{name, kind:
"file"|"dir"|"symlink"|"other", size (null for a folder), mtime (epoch ms
or null), hidden?, target_kind?}`.

| Command | Params | Data | Error codes |
| --- | --- | --- | --- |
| `fs.stat` | `{path}` | entry + `{mode_display, owner_display, revision}` | `fs.not_found` |
| `fs.list` | `{path, sort?, filter?, limit (1..1000, default 200), cursor?, listing?}` | `{entries, listing, cursor, total, revision}` | `fs.not_a_directory`, `fs.too_large`, `cursor.expired` |
| `fs.read` | `{path, offset?, max_bytes}` | `{text \| bytes_base64, truncated, size, encoding: "utf-8"\|"base64"}` | `fs.not_a_file` |
| `fs.write` | `{path, text \| bytes_base64, mode: "create"\|"overwrite"\|"replace"\|"append", expected?, permissions?}` (`append` adds the bytes in place to a regular, singly linked file while it has the revision `expected`, for files over the single-write limit; a failed append is cut back. `permissions` gives the written file 0644, 0755, 0600 or 0700, as a decimal number) | `{entry}` (with `revision`) | `fs.exists`, `fs.revision_mismatch` (`error_details.current`), `fs.too_large`, `fs.no_space`, `fs.read_only` |
| `fs.mkdir` | `{path, name}` | `{entry}` | `fs.exists` |
| `fs.rename` | `{path, name}` (same folder; never replaces) | `{entry}` | `fs.exists`, `fs.not_found` |
| `fs.delete` | `{paths, permanent: true}` | `{}` | `fs.not_found` |

`fs.list` hides dotfiles unless `filter.hidden` is true; a listing is a
snapshot kept 5 minutes after its last use and paged with `listing` and
`cursor`. `fs.read` returns at most 16 MiB (`truncated:true` when more
remains). A single `fs.write` takes at most 12 MiB; it writes a temporary
file in the same folder, fsyncs it, and renames it over the target, so the
target is either the old or the new file. `expected` is valid only with
`replace`. `fs.delete` removes folders with everything in them and never
follows a symlink.

Byte streams need a link dial of their own; on the line path a request with
`"stream":true` is `params.invalid`. A dial whose first line is
`{"id","cmd":"fs.read","path","offset"?,"stream":true}` answers a header
`{"size","length","revision"}`, then exactly `length` raw bytes, then an end
line `{"size","revision"}` (or `fs.revision_mismatch` when the file changed
while it was sent). A dial whose first line is
`{"id","cmd":"fs.write","path","mode","expected"?,"stream":true,"size"}`
answers `{"ready":true}` after the path, mode and free space are checked,
then reads exactly `size` raw bytes (at most 64 GiB) and answers `{entry}`.
A write stream that closes or stays idle for 60 seconds before `size` bytes
leaves no file at `path`.

## Guest browser opening

### url-open

A private, Unix-classified control request with `terminal_id` and `url` strings.
Only HTTP(S) URLs up to 16 KiB and a live terminal in this daemon are accepted.
The result is `{opened:boolean}`. At most 16 requests remain pending; a missing
frontend, disconnect, declined delivery, or five-second deadline returns false.
This command never starts guest Chrome, creates a resource, or writes a journal
entry. The guest OS opener prints the URL and exits successfully on false.
Several frontend subscriptions for the same terminal also return false: the
guest request cannot identify a physical Mac, so the daemon never guesses.

### url-open-subscribe

A private frontend connection registers up to 256 exact `terminal_ids`. It
receives `{url_open_ready:true}`, then targeted `url-open` control events
containing `request_id`, `terminal_id`, and the original `url`. It must keep the
connection open (`raw command --stream`); disconnect rejects pending requests.
Subscriptions and requests are transient and are never replayed.

### url-open-claim

The frontend sends the random `request_id` capability on the authenticated mux
connection before opening anything. `{claimed:false}` means it expired, was
already claimed, or no longer exists. A delayed event therefore cannot open a
stale authentication page. The source terminal is mapped to a live Mac panel;
no guest-supplied Mac workspace or surface selector is accepted.

### url-open-result

The frontend sends `request_id` and `opened` after actual delivery. The result
is `{accepted:boolean}`. The URL follows terminal-link policy, including browser
preferences and host allowlists, with focus disabled. Local Mac v2 socket methods
and the SSH relay authorization allowlist are unchanged. These operations are
exposed only in the SDKs' existing private `raw` namespace.

## Terminal clipboard reads

Capability `terminal-clipboard-read-v1`. OSC 52 clipboard reads are denied by
default: the user grants each one. A terminal host that negotiated clipboard
reads (terminal-host.md, `CLIPBOARD_READ`) defers every read and asks the
daemon, and the daemon asks one frontend. Only the frontend user path may take
part: a connection whose `set-client-info` kind is `frontend` and whose origin
derives `user` (the verified cmux app, see "client-hello"). Agents, page relays,
unverified connections, other client kinds and remote clients get
`error_code:"origin.forbidden"`, and nothing changes. No clipboard text is ever
logged, journaled or kept after it is forwarded.

Remote clients are refused on purpose: a remote reply would send the Mac's
clipboard text to another machine, which needs its own reviewed relay analysis
(only the user's own identity-bound app, never a second remote client, the app
always asking, a per-host deny). Until then a read in a terminal that no local
verified app can answer is refused. The `host` object of the event is always
`{kind:"local"}` from this daemon; the frontend owns the host label it shows,
because it knows which daemon (local, remote or Cloud) it is connected to.

### terminal-clipboard-subscribe

`{terminal_ids}` registers up to 256 exact terminal public ids for this
connection (each must be a valid `term_` id; a new call replaces the previous
set) and answers `{clipboard_read_ready:true}`. At most 16 connections may hold
a subscription. The connection then receives a targeted `terminal-clipboard-read`
event (events.md) for each read in those terminals and must stay open (`raw
command --stream`). The daemon refuses a read at once, without an event, when
zero or several live connections are subscribed to its terminal (it never
guesses which user is asked), when that terminal already has an open read, or
when the subscribed connection already holds 16 open reads. A refused read
answers the program with an empty clipboard. Closing the connection refuses
all of its open reads. Subscriptions and reads are transient and never
replayed.

### terminal-clipboard-reply

`{request_id, text?}` answers one read. A string `text` grants it; absent or
`null` refuses it; text over 1 MiB (UTF-8 bytes) is refused. The result is
`{accepted:boolean, granted:boolean}`: `accepted:false` when the request is
unknown, already answered, cancelled, or was sent to another connection (only
the connection that received the event may answer); `granted` is true only
when text was granted and reached the terminal host. When the host refuses a
read itself (its 60-second timeout or the terminal's end), or a newer read
from the same terminal replaces it, the frontend receives
`terminal-clipboard-read-cancelled` and the request id stops being accepted.
These operations are exposed only in the SDKs' private `raw` namespace.
