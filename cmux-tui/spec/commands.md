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
fields `color` (palette token or `#RRGGBB[AA]`), `icon` (SF Symbol name), and
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
    sticky?:object{edge:"left"|"right",mode:"docked"|"overlay"}
  }>,
  panes:array<Pane>
}
```

Servers advertising `viewport-splits-v1` include `viewport_splits` when a screen uses horizontal viewport columns. Each entry marks a right split whose second child is appended to a horizontal virtual canvas. `width` is the second child's width as a fraction of each frontend's viewport. Ordinary screens omit the field. Clients that do not implement the capability may ignore it and render the split's fallback ratio.

Servers advertising `viewport-column-resize-v1` include `viewport_base_width` when horizontal viewport layout is active. It is the width of the first column as a fraction of the frontend viewport. A missing value defaults to `1.0`.

`columns` lists the horizontal viewport columns in order while viewport layout is active and is omitted otherwise. `id` is the column's stable id (also `after_column` in `move-tab-to-column`), `width` its fraction of the frontend viewport, and `layout` the split tree inside it.

Servers advertising `sticky-columns-v1` add `sticky` to a column pinned with `set-column-sticky` and omit it for a scrolling column. `edge` is the viewport edge the frontend keeps the column at while the other columns scroll. With `mode:"docked"` the column's width is taken out of the scrolling area; with `mode:"overlay"` it floats above the scrolling columns. A screen has at most one sticky column per edge and always at least one scrolling column. `columns` keeps the stored order, so a client without the capability renders a sticky column in place. The flag moves with the column, persists across daemon restarts, is restored by `undo-layout`, and disappears with the column. A new column is never sticky. When removing columns would leave only sticky columns, the server clears their flags; when the screen collapses to one column, `columns` is omitted.

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

Servers advertising `frontend-browser-tabs-v1` add `browser_renderer` to
every tab: `"daemon"` for a CDP browser, `"frontend"` for a browser whose page
the frontend renders, and null for a PTY. Frontend browsers also report
`browser_engine` (`"webkit"` or `"cef"`), `favicon_url`, and
`browser_profile_id`, and report null `browser_status`/`browser_error`. Their
`url` and `title` are the values the frontend last recorded.

Servers advertising `remote-terminal-tabs-v1` report a tab that references a
terminal on another session (`new-remote-terminal-tab`) as
`kind:"remote-terminal"` with `remote:object{session_id:string,
terminal_id:string, session_name:string}` and `title` (the recorded title,
else `Terminal on <session_name>`). Such a tab has no `terminal_id`,
`terminal_resource_id`, or `terminal_incarnation` field and reports null
`url`, `cwd`, `git_branch`, and browser fields. Its snapshot is never in the
tree (`remote-terminal-snapshot` reads it).

Servers advertising `tab-groups-v1` add `tab_groups` to every pane, in strip
order: `array<object{id:string, name:string, color:string, collapsed:bool,
saved_id:string|null, start:usize, count:usize, surfaces:array<Id>}>`, and
`group:string|null` to every tab. `start` is the strip index of the group's
first tab. Group members are contiguous; a tab another path moved away from
its group's run is reported ungrouped. Colors are Chrome's nine: `grey`,
`blue`, `red`, `yellow`, `green`, `pink`, `purple`, `cyan`, `orange`.

The `dead` pane variant is serialized only if the tree references a pane missing from state. That should not occur in normal operation, but clients must tolerate it.

## Sizing

Every surface has one authoritative cell grid. Byte and render attach modes observe the same grid; attaching by itself never resizes it.

Each client reports the cell grid available for every surface it displays with
`resize-surface`. Terminals use the shared sizing reducer defined in
[`docs/shared-terminal-sizing.md`](../../docs/shared-terminal-sizing.md) and
implemented in `cmux-tui-core/src/sizing_policy.rs`. Every client view of a
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
object{app:"cmux-tui",version:string,build_commit?:string|null,ghostty_commit?:string|null,protocol:uint32,capabilities:array<string>,session:string,pid:uint32,session_id?:string,machine_name?:string,registry_id:string,generation:string,workspace_revision:uint64}
```

With `launch-snapshot-v1`, `launch_snapshot_path` is the absolute path of the session's launch snapshot, or `null` when the session has no durable registry. The daemon keeps that owner-only JSON file next to its registry: `{schema_version:1, app:"cmux-tui", version, session, registry_id, generation, written_at_ms, tree, frontend_projections}`, where `tree` is the `list-workspaces` result and `frontend_projections` lists every native frontend projection (`{frontend, scope, subject_key, schema_version, projection_revision, projection}`; omitted as `[]` when the file would exceed 8 MiB). It is rewritten atomically (temporary file and rename) once changes to the tree, layout or projections settle (a title change alone does not rewrite it, so titles are those of the last write) (500 ms after the last change, at most 3 s after the first), once at daemon start, and never while nothing changes. A frontend may read it before it connects, to draw the last known layout, and must replace it with live state after `identify`; the daemon never reads it, so it is never a second source of truth.

`build_commit` and `ghostty_commit` are additive build-stamp fields. They are omitted or `null` when the binary was built without the corresponding stamp, so clients must preserve compatibility with older servers and unstamped local builds.

`capabilities` is additive build-level feature negotiation within a protocol version. Clients must treat a missing field as an empty list. `daemon-handoff-force-v1` advertises the optional `force` field on `shutdown-daemon`. `browser-provider-v1` advertises the trusted-local, connection-scoped native browser provider lease used by cmux-browser and local automation. `browser-pointer-frame-guard-v1` advertises authoritative `pointer_frame_seq` and `pointer_frame_floor_seq` browser attach/frame state plus the additive `browser-frame-presented`, `browser-mouse-guarded`, and `browser-wheel-guarded` commands. Each admitted bitmap receives a new guard even when its document and dimensions match the previous bitmap. The reported floor through latest range proves route membership only. `browser-frame-presented` advances one exact acknowledged token for that connection, and only that token authorizes a new guarded pointer action. A guarded pointer command implicitly acknowledges its own token. Each connection retains one token, while the bounded browser input queue owns actions admitted before a later presentation. Navigation or geometry changes clear the range and all acknowledgements. An accepted press keeps its original guard for motion across ordinary repaints while document and geometry remain valid; invalidation suppresses further motion but retains its balancing release. A capable client echoes that value in `set-client-info`; browser attach requires the bilateral capability while PTY attach remains available without it. The legacy `browser-mouse` and `browser-wheel` schemas retain their optional guard, but guarded servers reject a missing guard before surface lookup. `viewport-splits-v1` advertises `new-pane-right` and the `Screen.viewport_splits` field. `viewport-column-resize-v1` advertises `set-viewport-pane-width` and `Screen.viewport_base_width`. `sticky-columns-v1` advertises `set-column-sticky` and the optional `Screen.columns[].sticky` field. `layout-undo-v1` advertises server-owned structural layout history and `undo-layout`. `view-attachment-lease-v1` returns a connection-owned lease for each attach and enables lease-fenced sizing. `view-attachment-detach-v1` enables targeted stream cleanup. `creation-receipts-v1` enables idempotent destination creation, `creation-attempt-keys-v1` separates a stable correlation from the same-key or new-key execution attempt selected by `session.creation.resolve`, and `creation-selector-fallbacks-v1` adds bounded ordered destination continuations. `provider-managed-workspace-authority-v2` advertises pre-provisioned provider ownership and authority-gated post-provider rename and close commits. `terminal-idle-close-v1` advertises `set-terminal-idle-policy` and the owner-side reaper that closes a terminal after its policy elapses with no attached view. `terminal-pending-sequence-v1` advertises the separate `pending` field on byte-attach `vt-state` and `resized` events; a client that echoes it in `set-client-info` receives it (see `events.md`). `terminal-placement-env-v1` advertises a caller-chosen `terminal_id` on `new-tab`, `split`, `new-pane`, and `new-pane-right`, `cwd` and `env` on `new-pane` and `new-pane-right`, and `terminal_id`/`terminal_incarnation` in all four results. `terminal-resources-v1` advertises `terminal-resources`, which reads the CPU time and memory of each terminal's shell, descendants, and terminal host at request time. `batch-close-v1` advertises `close-tabs` and the optional `end_terminals` field on `close-pane`, `close-screen`, `close-workspace`, and `close-tab-group`: many placements and the terminals they end close in one durable commit. `end-terminals-keep-layout-v1` advertises `keep_layout` on `shutdown-daemon`: with `end_terminals`, placed terminals keep their tabs across the handoff. `terminal-reap-v1` advertises the owner-side reaper that ends a terminal after it has had no tab placement for the reap grace period (active only when the daemon was started with `--terminal-reap-grace-seconds`), `set-terminal-keep`, the `keep` field on `new-tab`, `split`, and `create-terminal`, the `terminal-reaped` event, and `end_terminals` on `shutdown-daemon`. `terminal-env-v1` advertises the per-terminal `env` object on `new-tab`, `split`, and `create-terminal`, and `cwd` on `split`. `tab-groups-v1` advertises Chrome-style tab groups: the `*-tab-group` commands, `Pane.tab_groups`, and `Tab.group`. `saved-tab-groups-v1` advertises saved groups: `save-tab-group`, `unsave-tab-group`, `delete-saved-tab-group`, `list-saved-tab-groups`, and `reopen-saved-tab-group`. `notification-ack-v1` advertises `ack-tab-notifications`, `list-notifications`, durable notification acknowledgement, and `Workspace.unread_count`. `tab-drag-v1` advertises the single-command tab drag outcomes `move-tab-to-split`, `move-tab-to-column`, and `move-tab-to-new-workspace`, layout undo for same-screen tab drags and cross-pane `move-tab`, and the optional `transaction` field on every drag command, echoed in the resulting `tab-changed` delta. `frontend-browser-tabs-v1` advertises `new-frontend-browser-tab`, `update-frontend-browser-tab`, and the frontend browser tab fields. `tab-metadata-v1` advertises `set-tab-pinned`, pinned-first tab order, the `Tab.pinned`, `Tab.cwd`, `Tab.git_branch`, and `Tab.git_detached` fields, and the `tab-changed` delta. `workspace-metadata-v1` advertises `set-workspace-metadata`, the `Workspace.color`, `Workspace.icon`, and `Workspace.title` fields, and the `workspace-changed` delta. `workspace-pin-v1` advertises the `pinned` field on `set-workspace-metadata` and `Workspace.pinned`. `notification-mark-unread-v1` advertises the `marked_unread` field on `set-workspace-metadata` and `Workspace.marked_unread`. `workspace-groups-v1` advertises durable sidebar groups: the `*-workspace-group` commands, `move-workspace-to-group`, `Tree.groups`, and `Workspace.group`. `loopback-forward-v1` advertises multiplexed TCP streams to the daemon machine's own loopback services (see "Loopback forwarding"); a Unix client echoes it in `set-client-info` before its first `loopback-open`. `session-identity-v1` advertises `identify.session_id` (the durable `registry_id`, stable across restarts and upgrades) and `identify.machine_name` (the host name, at most 255 bytes, no control characters). `remote-terminal-tabs-v1` advertises `new-remote-terminal-tab`, `update-remote-terminal-tab`, `remote-terminal-snapshot`, and the `kind:"remote-terminal"` tab with its `remote` object. `profiles-v1` advertises the home session's personal state: `list-personal`, the `*-profile` room commands, `set-profile-follows`, `pin-workspace`, `unpin-workspace`, `put-session`, `forget-session`, `import-session-organization`, the `*-personal-group` commands, `set-personal-workspace`, and the `personal-changed` event. `personal-terminals-v1` advertises `set-personal-terminal` and `list-personal.terminals`. `screen-metadata-v1` advertises `set-screen-metadata`, `set-screen-pinned`, `move-screen`, the `screen_name`, `color`, `icon`, `pinned`, `index`, `group`, and `cwd` fields on `new-screen` (whose result then also carries `screen`), the `Screen.color`, `Screen.icon`, `Screen.pinned`, and `Screen.group` fields, and the `screen-changed` delta. `screen-groups-v1` advertises Chrome-style screen groups: the `*-screen-group` commands, saved screen groups, and `Workspace.screen_groups`. `browser-profiles-v1` advertises browser profile records in personal state: `browser_profiles` in `list-personal` and `create-browser-profile`, `update-browser-profile`, `move-browser-profile`, and `delete-browser-profile`. `notification-source-v1` advertises `source` on `notify`, the `notification` event, the tab `notification` marker, and `list-notifications` rows (`extra.source` in resource notification snapshots), and daemon-side desktop notifications from terminal output (OSC 9, OSC 777 `notify`, kitty OSC 99) with source `terminal`. `terminal-shell-args-v1` advertises `shell_args` on `new-tab`, `split`, `new-pane`, `new-pane-right`, and `create-terminal`: the terminal runs its `SHELL` from `env` (else the daemon's default shell) with those arguments, so a frontend can apply Ghostty's argv-based shell integration (bash `--posix` with `ENV`, nushell `--execute`). `launch-snapshot-v1` advertises `launch_snapshot_path` in `identify` and the launch snapshot file described there. `bookmarks-v1` advertises one bookmark tree per browser profile: `list-bookmarks`, `create-bookmark`, `update-bookmark`, `move-bookmark`, `delete-bookmark`, `import-bookmarks`, the `bookmarks-changed` event, and `deleted_bookmarks` in the `delete-browser-profile` result.

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

A normal shutdown keeps terminal hosts alive for the next owner. With `end_terminals`, the daemon ends every terminal through the `close-terminal` path, waits for their hosts to exit, and reports the count in `ended_terminals`. A host still running after its close deadline (it ignored termination) is killed, and the call succeeds only once every terminal host of the session is provably dead; otherwise it fails and the daemon keeps serving. Test harnesses use it so a run leaves no terminal host or PTY behind. A failure to end a terminal cancels the handoff and the daemon keeps serving.

With `keep_layout` as well, every terminal still ends, but a terminal shown in a tab keeps its tabs. Before any terminal ends, the workspace store records each kept tab with the directory its shell is in (`kept_tabs`, keyed by tab resource id; the session host supplies the directory: the foreground process's, else the OSC 7 or launch directory). A tab in `kept_tabs` is never removed by its terminal's exit, now or at the next owner's startup reconciliation. Each terminal's own exit records its outcome as usual; no layout decision reads it. If the handoff fails, the records of terminals that did not end are removed. The next owner shows the same workspaces, screens, split layout, ratios, panes and tab resource ids; each kept tab is `dead`, has no terminal behind it, and carries `relaunch: {cwd}` in `list-workspaces` (only while its terminal has ended). A frontend starts a new shell there (cmux opens a new tab in the same pane, in `cwd`, and closes the dead one); a closed kept tab's record is inert and pruned on the next write. Terminals without a tab end as with `end_terminals` alone. `keep_layout` without `end_terminals` is refused with `bad request: keep_layout requires end_terminals`.

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
| since | protocol 12, capability `terminal-command-journal-v1` |

Turns terminal command history on or off for this daemon. Off by default, and
off again after every daemon start (the setting is never persisted), so a
client that wants history turns it on after each connect. Trusted local
(Unix-classified) connections only.

While on, the daemon tracks OSC 133 shell-integration marks in each terminal's
output (`A` prompt start, `B` input start, `C` command start, `D[;exit]`
command end) and appends one `shell.command.finished` journal record per
finished command, from the reserved producer `cmux_shell` (class observation,
sensitivity sensitive, subject the terminal and its ancestors):
`{command, cwd, exit_code, started_at_ms, duration_ms}`. `command` is the text
of the newest block of cells Ghostty marks as input (after `B`, until `C`),
read at `C`: the semantics are assigned byte by byte while the output is
parsed, so typeahead, prompt redraws and reflow do not change it. It is
trimmed, without control characters and cut at 1 KiB; null on the alternate
screen or when no input cell is found. `cwd` is the local path of the OSC 7
directory at `C` (null when it names another host); times are decimal
strings. A `D` without a `C` (an empty Enter) records nothing; an `A` while a
command runs ends it with a null `exit_code`. A terminal records at most 10
commands a second; one daemon worker appends them in order from a queue of
256 (more drop with a diagnostic). While off, marks are dropped and the
screen is never read. Only the daemon writes `cmux_shell` records:
`session.journal.append` refuses that producer and it cannot be installed
or replaced as a plugin. The switch is one daemon-wide value that any
trusted local client sets (not per client), and turning it off keeps the
records already written.

Params: `{enabled: bool}`. Result: `{enabled: bool}`.

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
reads atomics and never touches SQLite or the journal, so it is safe to poll.

Params: none.

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
  connections:object{active:uint64,peak:uint64,limit:uint64,accepted:uint64,refused:uint64}
}
histogram = object{count:uint64,mean:uint64,max:uint64,p50:uint64,p90:uint64,p99:uint64}
```

`schema` is `1`. Latency histograms are in microseconds; `batch_size` counts
events. Percentiles are log-linear bucket upper bounds and overestimate by at
most 25%. `site` values are `file:line` of the code that acquired the registry
lock. `contended_acquisitions` counts waits of at least 1 ms and `stalls`
counts waits of at least 100 ms. `journal_writer` is `null` for ephemeral
sessions. `connections.refused` counts sockets dropped at `limit`; for hook
producers each one is a lost event.

Errors: `bad request: ...`.

CLI mapping: `cmux server stats [--session <name>] [--socket <path>]`; plain
stdout renders the object as nested `key: value` lines; `--json` prints the
exact result object. Against a server without `server-stats-v1` the CLI exits
1 with `server.stats_unsupported`.

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
| `device_kind` | `string` | default unchanged | `mac`, `iphone`, `ipad`, `tui`, `browser`; anything else is `unknown`; defaults to `kind` |
| `device_name` | `string` | default unchanged | Shared sizing identity |
| `device_id` | `string` | default unchanged | Stable per-install device id; tells two devices of one user apart and extends the priority key |

Identity fields are clamped like `name`. A connection that sends
`shared-sizing-v1` in `capabilities` receives `size-state` events on its
subscribe and attach streams and `participant`/`size_state` in terminal
`attach-surface` responses.

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
names a terminal, is rejected and nothing is created. `new-pane` and
`new-pane-right` also accept `cwd`, `env`, and `keep` with the same meaning as
on `new-tab`, and all four reply with `surface`, `terminal_id`, and
`terminal_incarnation`.

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
| `cols`, `rows` | uint16 | optional, together | Initial size hint |

Result:

```text
object{surface:Id, tab_resource_id:string, content_resource_id:string}
```

### update-frontend-browser-tab

| Field | Value |
| --- | --- |
| name | `update-frontend-browser-tab` |
| status | implemented |
| since | protocol 12 additive extension; capability `frontend-browser-tabs-v1` |

Records the URL, title, or favicon a frontend-rendered browser reports. An
absent field is unchanged and `favicon_url:null` clears the favicon. A change
persists durably and emits `title-changed` (when the title changed) and
`tab-changed`. Fails for a tab that is not frontend-rendered.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surface` | `Id` | required | Frontend browser tab |
| `url` | string | optional | As in `new-frontend-browser-tab` |
| `title` | string | optional | As in `new-frontend-browser-tab` |
| `favicon_url` | string or null | optional | As `url`; null clears |

Result:

```text
object{surface:Id, url:string, title:string|null, favicon_url:string|null, changed:bool}
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
for it. The tab is an ordinary placement in the durable tree: it restores
after a restart, and `move-tab`, `move-tab-to-workspace`,
`move-tab-to-split`, `move-tab-to-column`, `move-tab-to-new-workspace`,
pins, tab groups, `close-surface`, and `close-tabs` treat it like any tab.
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
persists durably and emits `title-changed` and `tab-changed`; a snapshot is
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
| `workspace` | `Id` | required unless `key` is supplied | Mutually identifies the target with `key` |
| `key` | `string` | required unless `workspace` is supplied | Lowercase canonical workspace UUID; must match `workspace` when both are supplied |
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
| `icon` | string | default null | SF Symbol name or one emoji |
| `pinned` | bool | default null | Pinned screens sort first |
| `index` | uint | default null | Insertion index among the workspace's screens |
| `group` | string | default null | Screen group of the same workspace (`screen-groups-v1`) |

Result:

```text
object{surface:Id,screen?:Id}
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
| `shell_args` | `string[]` | default null | With `terminal-shell-args-v1`: arguments for the terminal's shell, its `SHELL` in `env` or else the daemon's default shell; none or empty keeps the bare shell |

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
| `shell_args` | `string[]` | default null | With `terminal-shell-args-v1`: arguments for the terminal's shell, its `SHELL` in `env` or else the daemon's default shell; none or empty keeps the bare shell |

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

### set-column-sticky

| Field | Value |
| --- | --- |
| name | `set-column-sticky` |
| status | implemented |
| since | protocol 12 additive capability `sticky-columns-v1` |

Pins the horizontal viewport column containing `pane` to a viewport edge, or unpins it. Pinning an edge that another column holds unpins that column in the same commit. Pinning a column that holds the other edge moves it. Unpinning a column that is not sticky succeeds and changes nothing; so does any request that matches the current flags. Width, column order, the splits and tabs inside the column, and focus are unchanged. A change is a structural layout change: it advances the screen's layout revision, records one `undo-layout` entry, persists, and emits `screen-changed` and then `layout-changed`. See `Screen.columns[].sticky`.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `pane` | `Id` | required | Must belong to a screen with viewport columns |
| `sticky` | boolean | required | `false` unpins |
| `edge` | string | default `"right"` | `"left"` or `"right"`; validated even when `sticky` is false |
| `mode` | string | default `"docked"` | `"docked"` or `"overlay"`; validated even when `sticky` is false |
| `transaction` | `uint64` | default null | Changes with the same connection and transaction coalesce into one undo entry |

Result:

```text
object{column:Id,sticky:object{edge:"left"|"right",mode:"docked"|"overlay"}|null,transaction?:uint64}
```

`column` is the column's `Screen.columns[].id` and `sticky` its flag after the request. `transaction` echoes the request's value and is omitted when the request had none. The `screen-changed` delta of a change carries the same transaction as a decimal string (the delta's `transaction` field is a string).

Errors:

| Error | `error_code` | Condition |
| --- | --- | --- |
| `pane <id> has no viewport column` | `viewport-column-not-found` | Pane is unknown or its screen has no viewport columns |
| `at least one column must scroll` | `sticky-column-last-scrolling` | The change would leave no scrolling column |
| `bad edge ...` / `bad mode ...` | `invalid-argument` | `edge` or `mode` is not one of the listed strings |
| `bad request: ...` | none | Missing fields or wrong JSON type |

CLI mapping: none. The resource CLI has no verb for this command; frontends send it directly.

Example:

```json
{"id":13,"cmd":"set-column-sticky","pane":15,"sticky":true,"edge":"left","mode":"overlay","transaction":7}
{"id":13,"ok":true,"data":{"column":14,"sticky":{"edge":"left","mode":"overlay"},"transaction":7}}
{"id":14,"cmd":"set-column-sticky","pane":15,"sticky":false}
{"id":14,"ok":true,"data":{"column":14,"sticky":null}}
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

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `surfaces` | `array<Id \| string>` | required | 1 to 4096 live tabs, by surface id or public `tab_` id |
| `end_terminals` | `bool` | default `false` | End terminals left with no view, unless kept |
| `transaction` | `string` | optional | Client id echoed in the result; 1-128 printable ASCII |
| mutation fields | see common envelope | optional | `origin` and `mutation_id` for exactly-once retries; no CAS fields |

Result:

```text
object{closed:array<Id>,terminals:array<object{terminal_id:string,terminal_incarnation:string|null}>,resource_revision:uint64,replayed:bool,transaction?:string}
```

`closed` lists the removed placements in request order. `terminals` lists the
terminals the commit ended. A retry with the same `origin` and `mutation_id`
returns the original result with `replayed: true` and changes nothing.

Errors:

| Error | Condition |
| --- | --- |
| `unknown surface <id>` / `unknown tab <id>` | A surface is not a live tab placement |
| `close-tabs needs at least one surface` | `surfaces` is empty |
| `close-tabs takes at most 4096 surfaces` | `surfaces` is too long |
| `bad request: ...` | Missing `surfaces`, wrong JSON type, or invalid `transaction` |

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
| `icon` | string or null | absent keeps | SF Symbol name or one emoji (at most 32 bytes) |

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

Creates a Chrome-style group from screens of one workspace. Members become contiguous at the position of the first; screens leave any group they were in. Pinned screens cannot be grouped. Emits `tree-changed` and a `screen-changed` per member.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `screens` | array of `Id` | required | One workspace, at least one screen |
| `name` | string | default "" | At most 256 characters |
| `color` | string | default `grey` | One of the nine tab group colors |

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

Renames, recolors, or collapses a group. Collapse is shared by every client. A linked saved record follows.

Params:

| Name | JSON type | Required/default | Constraints |
| --- | --- | --- | --- |
| `group` | string | required |  |
| `name` | string | default null |  |
| `color` | string | default null | One of the nine tab group colors |
| `collapsed` | bool | default null |  |

Result:

```text
object{group:object{id:string,name:string,color:string,collapsed:bool,saved_id:string?}?,workspace:Id?,key:string?,screens:[Id]}
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
(`cmux server ensure --terminal-reap-grace-seconds <n>` passes it to the owner it spawns)
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
like a placed one (`set-client-sizing`, `resize-attached-view`).

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
| `color` | string | default `"grey"` | One of the nine tab group colors |
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

Renames, recolors, collapses, or expands a group; absent fields are
unchanged. A linked saved group follows. Collapse is shared state; moving
selection out of a collapsed group is the frontend's client-local focus.

Params: `group` (string, required), `name` (string), `color` (string),
`collapsed` (bool).

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

Removes tabs from their groups; each lands just after its former group, as in
Chrome. A group left without members disappears.

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

Moves a whole group into a new niri column, in one commit.

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
object{saved_groups:array<object{id:string, name:string, color:string, updated_at_ms:uint64, members:array<object{kind:"terminal", terminal_id:string|null, cwd:string|null, title:string|null} | object{kind:"browser", url:string, engine:string|null, profile_id:string|null, title:string|null}>}>}
```

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
focus client-local and call this when the user has seen the tab. The legacy
clear on `select-tab`/`focus-pane` persists its acknowledgement the same way.
Emits `tab-changed` for each view whose marker cleared. Acknowledging a tab
with no marker succeeds with `cleared:false`.

Params: `surface` (`Id`, required).

Result:

```text
object{surface:Id, cleared:bool, acknowledged:[string]}
```

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
cannot be split out of a pane where it is the only tab.

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

Drops a tab between niri columns: creates a horizontal viewport column on the
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
| `icon` | string or null | optional | SF Symbol name: lowercase letters, digits, dots; at most 128 bytes |
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
Session = object{session_id:string, machine_name:string|null, session_name:string|null, transport:object, last_seen_ms:uint64|null, capabilities:json|null, migrated:bool}
Pin = object{session_id:string, workspace_key:string, profile:string}
PersonalGroup = object{id:string, profile:string, name:string, color:string|null, collapsed:bool, index:usize}
PersonalWorkspace = object{session_id:string, workspace_key:string, index:usize, group:string|null, browser_profile_id:string|null, theme:string|null}
PersonalTerminal = object{session_id:string, terminal_key:string, theme:string}
BrowserProfile = object{id:string, name:string, color:string|null, icon:string|null, index:usize, source:object|null}
```

Room ids are `default` or 1-64 ASCII letters, digits, `_`, `-`, `.`, `:`
(generated `prof_<32 hex>`). Colors are palette tokens or `#RRGGBB[AA]`; icons
are an SF Symbol name or one emoji; `theme` is 1-256 characters without
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

Params: `browser_profile` (required).

Result: `object{browser_profile:string, cleared_workspaces:[object{session_id:string, workspace_key:string}], cleared_rooms:[string], deleted_bookmarks?:usize}`

### list-bookmarks

| Field | Value |
| --- | --- |
| name | `list-bookmarks` |
| status | implemented |
| since | protocol 12 additive extension; capability `bookmarks-v1` |

Bookmark commands (plans/cmux-next/bookmarks.md sections 1 and 2.1) store
one Chrome-style bookmark tree per browser profile in the home session. Every
daemon serves them; the app writes them only on its home session. The two
roots, the Bookmarks Bar (`bar`) and Other Bookmarks (`other`), are reserved
`parent` values, not nodes. Each change bumps the session's
`bookmarks_revision` (separate from `personal_revision`) and emits
`bookmarks-changed`; an unchanged retry emits nothing.

Shapes:

```text
Bookmark = object{id:string, browser_profile_id:string, parent:string, kind:"url"|"folder", index:usize, title:string, url?:string, favicon_key?:string, source_key?:string, created_ms:uint64, last_used_ms?:uint64}
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
carries `source_key`. Times are
milliseconds since the Unix epoch, at most `i64::MAX`. A node one level under
a root has depth 1; no node is deeper than 64, and a profile holds at most
100,000 nodes. Nodes never move between profiles. The browser profile must
exist (`list-personal.browser_profiles`).

Errors carry `error_code`: `invalid_params` for a bad id, parent, kind, URL,
size, cycle, limit or idempotency key, and `not_found` for an unknown bookmark
or browser profile. A rejected command changes nothing.

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

Changes a node's title, URL (`url` nodes only), favicon key or last use. An
absent field (or a null `title` or `url`) is unchanged; JSON null clears
`favicon_key` or `last_used_ms`.

Params: `bookmark` (required), `title`, `url`, `favicon_key`, `last_used_ms`,
`origin`, `mutation_id`.

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
id, parent and position, takes `nodes[0]`'s title and children (its old
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

Records or refreshes a session in the home session registry and stamps
`last_seen_ms`. Absent `machine_name`, `session_name`, and `capabilities` keep
stored values. A new session is followed by `default` and by `follow_with`.

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

Deletes a personal group; its workspaces become ungrouped.

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
personal order. JSON null clears `group`, `browser_profile_id`, or `theme`.
The daemon does not check that the group belongs to the room showing the
workspace; the app evaluates membership.

Params: `session_id`, `workspace_key` (required), `index`, `group`,
`browser_profile_id`, `theme`.

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

`sticky-columns-v1` is additive within protocol v12. Clients must require the capability before sending `set-column-sticky`. Clients without it ignore `Screen.columns[].sticky` and render every column in order. The flag is stored in the screen's durable viewport record only while set; a daemon that predates the capability cannot open a registry that holds a sticky column, so roll back only before any column was pinned.

`layout-undo-v1` is additive within protocol v9. Clients must require the capability before sending `undo-layout`. A binding must preserve both result variants and must not set `confirm_close` without the exact revision returned by the confirmation preview.

## Temporary terminal image paste

`paste-image` is an authenticated, lease-bound control operation gated by
`terminal-image-paste-v1` on protocol 12. A protocol-12 daemon without that
capability must not receive image data. Each request contains `surface`, the
exact public `terminal_id`, the current attachment `lease`, a 32-hex-character
`upload_id`, and one operation:

| `op` | Additional fields | Effect |
| --- | --- | --- |
| `begin` | `mime`, `size` | Reserve bounded capacity and create a private daemon-owned file. |
| `chunk` | `offset`, `data` | Append one sequential, standard-base64 chunk (at most 48 KiB decoded). |
| `commit` | none | Verify byte count and MIME, then invoke the authoritative terminal paste operation once. |
| `cancel` | none | Remove an unpublished upload; idempotent when already absent. |

Success is `{ "accepted": true }`. Request IDs use the normal control envelope.
Await each acknowledgement before sending the next operation. The connection,
lease, surface, terminal, and authoritative workspace must still match. No
destination path is accepted and no image path or content is returned in an
acknowledgement. Stable error codes begin with `image-`; clients must treat a
lost commit acknowledgement as uncertain delivery and must not retry it blindly.

The policy is 20 MiB per PNG/JPEG/GIF/WebP image, eight images per connection,
32 retained uploads and 128 MiB reserved per daemon. Pending uploads expire in
two minutes; committed uploads expire in ten minutes. Ownership receipts permit
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
