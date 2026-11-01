# cmux resource API v2

Status: normative, prelaunch, incompatible with every earlier control API.

## Model

The public hierarchy is:

```text
Machine
└── Session
    ├── Terminal
    ├── Workspace
    │   └── Screen
    │       └── Pane
    │           └── Tab
    │               └── Terminal view or Browser
    ├── Client
    ├── Notification
    ├── Agent
    ├── Projection
    └── SidebarView
```

A terminal is session-owned content with zero or more tab views. Every view
has its own tab ID and placement-local name; all views share one process,
ordered input stream, output history, and canonical grid. Closing a tab, pane,
screen, workspace, frontend projection, or client connection detaches views
without closing the terminal. `terminal.project` adds another view, and only
`terminal.close` terminates and tombstones the terminal. A browser remains
single-view tab content. Sidebar extensions are session-scoped auxiliary
resources and cannot become tabs.

One `cmux.protocol/2` endpoint executes session operations on exactly one local
mux session. Its machine and session resources provide stable routing handles
for that owner. Explicit catalog reads may also expose a bounded metadata
projection of admitted remote owners; they provide no remote carrier or session
authority. Cross-machine execution, aggregation of session state, and provider
lifecycle remain reserved for a later broker protocol.

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
| Pairing request | `pairing_` |
| Sidebar view | `sidebar_view_` |
| Sidebar plugin | `sidebar_plugin_` |

IDs are immutable and never reused. A durable session stores IDs with the
logical resource and restores every ID for every resource that remains alive
after daemon restart. Mux implementation indexes are private and cannot appear
in a v2 request, response, event, error, CLI value, or high-level SDK.

Names are labels. They are preserved byte-for-byte, may be empty, and need
not be unique.

## State resources

Workspace identity, tab and screen state, groups, rooms, closed history, and
workspace status (plans/cmux-next/state-ownership.md) are state resources of
the session. They are not topology nodes, so their IDs are durable `StateId`
strings of 1 to 64 bytes from `[A-Za-z0-9_.:-]`; the daemon mints
`tgrp_`, `sgrp_`, `grp_`, `prof_`, `saved_`, and `closed_` followed by 32
lowercase hexadecimal digits. Older records keep the IDs they already have
(`default` is the built-in room).

| Resource | Owner | Operations |
| --- | --- | --- |
| Workspace identity (title, color, icon), description, manual task status | shared | `workspace.update`, `workspace.create` |
| Workspace `ephemeral` flag (set only at creation) | shared | `workspace.create`, moves into a new workspace |
| Home workspace (`workspace-kind-v1`, one per store, created by the store) | shared | `workspace.ensure_home` |
| App workspaces (`app-screens-v1`, one per installed app), app tabs | shared | `workspace.ensure_app` |
| Workspace agent folder (where new agent chats start; set only by the user) | shared | `workspace.agent_folder.set` |
| Web links of a workspace (open on its right side, reuse its browser tab) | shared | `workspace.open_url` |
| Tab pin, zoom, user icon, manual unread mark, attention mark, browser back/forward, browser owner | shared | `tab.pin`, `tab.unpin`, `tab.update` |
| Tab groups | shared | `tab_group.*` |
| Screen pin, color, icon, order; screen groups | shared | `screen.update`, `screen.move`, `screen_group.*` |
| Closed history (one group per close gesture, kept until deleted) | shared | `closed.list`, `closed.reopen`, `closed.delete` |
| Workspace status (64 entries), progress, log (newest 200 lines) | shared | `workspace_status.*`, `workspace_progress.*`, `workspace_log.*` |
| Workspace checklist (50 items: text, state todo, in_progress or done, creator, image attachments by absolute path; `workspace-checklist-v1`) | shared | `workspace_checklist.list`, `workspace_checklist.add`, `workspace_checklist.update`, `workspace_checklist.remove` |
| Workspace groups, sidebar order, rooms, saved tab groups | personal (home session) | `workspace_group.*`, `workspace.place`, `workspace.placement.list`, `room.*`, `saved_tab_group.*` |
| Window records (one per app window, keyed install id and window id, one writer) | personal (home session) | `window_record.list`, `window_record.put`, `window_record.delete` |
| Settings (the settings file `cmux-next.json`, managed layers; one owner per daemon, `settings-v1`) | machine (config owner) | `settings.*` |
| Keybindings (`keybindings.json` beside the settings file, edited in place; one owner per daemon, `keybindings-v1`) | machine (config owner) | `keybindings.*` |
| Browser device emulation (the built-in device list compiled into the daemon, the user's custom devices, and each browser tab's emulated device shown as the tab's `extra.emulation`; `browser-devices-v1`) | personal (home session) and the tab | `browser.devices.list`, `browser.devices.add_custom`, `browser.devices.remove_custom`, `browser.tab.emulate`, `browser.tab.emulate.clear` |
| A browser tab's profile (its frontend browser record's, shown as the tab's `extra.browser_profile_id`; the app that shows the tab makes its page in that profile's store; `browser-profile-agent-v1`) | the tab | `browser.tab.set_profile` |
| Browser profiles (names, colors, icons and order in the home session's personal state; never cookies, history or site data, which each app engine keeps by profile id; `browser-profiles-v1`): an agent lists and creates them and opens a tab in one; only a person deletes one, in the app | personal (home session) and the new tab | `browser.profile.list`, `browser.profile.create`, `browser.profile.open` |
| Sidebar section layout (one per user: sections in top, middle and bottom regions; plans/cmux-next/sidebar-sections.md) | personal (home session) | `sidebar_layout.get`, `sidebar_layout.update` |
| Sidebar document (one per user: ordered sections of ordered items; every machine's workspace list, Pinned, custom, app and built-in sections; `sidebar-doc-v1`) | personal (home session) | `sidebar.get`, `sidebar.move`, `sidebar.pin`, `sidebar.unpin`, `sidebar.item.add`, `sidebar.item.remove`, `sidebar.item.remove_ref`, `sidebar.item.update`, `sidebar.section.add`, `sidebar.section.update`, `sidebar.section.move`, `sidebar.section.remove`, `sidebar.group.create`, `sidebar.group.update`, `sidebar.group.ungroup`, `sidebar.adopt`, `sidebar.apply`, `sidebar.reset` |
| Palette usage history (one per user: used rows and learned picks per query start; plans/cmux-next/palette-ranking.md 5.2) | personal (home session) | `palette_usage.get`, `palette_usage.record`, `palette_usage.import`, `palette_usage.hide`, `palette_usage.forget` |
| Stash (a native OneTab: groups of web pages closed on purpose and kept until restored or deleted; `stash-v1`) | personal (home session) | `stash.create`, `stash.list`, `stash.restore`, `stash.delete`, `stash.import` |
| Project list (the folders the user works in, imported from agent and editor sources, with the user's rename, pin, hide and order; plans/cmux-next/projects.md) | personal (home session) | `project.list`, `project.observe`, `project.add`, `project.update`, `project.remove`, `project.sync`, `project.source.update` |

Every state mutation takes an idempotency key and commits through the same
durable path as topology mutations: one transaction checks the replay record,
then the revision precondition, writes the rows, advances the resource
revision, and appends one `session.events` batch. A personal mutation also
advances the raw `personal_revision`. Reads return public IDs only; a
personal workspace reference carries the owning session's registry ID, an
opaque `workspace_ref`, and the public `workspace_id` for this session's live
workspaces.

Fields that belong to an existing snapshot travel in its `extra` map, so a
restated workspace, screen, tab, or terminal from any operation carries them:
workspace `title`, `color`, `icon`, `ephemeral`, `kind` (`home` for the home
workspace, absent for a normal one), `agent_folder` (absent until set), `description`
(`workspace-description-v1`, absent until set), `task_status` (`todo`, `working`,
`needs-attention`, `review` or `done`, `workspace-status-v1`; absent while automatic); tab `pinned`,
`tab_group_id`, `zoom`, `icon` (the user icon, absent until set), `marked_unread`
(`true` while the person marked the tab unread by hand, `tab-mark-unread-v1`; absent otherwise), `attention` (`{reason, at_ms, request_id}` while an agent needs the person in the tab, `tab-attention-v1`; absent otherwise), `back`, `forward`, `owner` (the install id of the app
that hosts a frontend-rendered browser, its record's only writer), `relaunch`
(`{cwd}` for a tab kept by `shutdown-daemon {end_terminals, keep_layout}`,
absent otherwise); screen `pinned`, `color`, `icon`,
`screen_group_id`; terminal `progress` (the parsed OSC 9;4 state and percent
of every terminal) and `program_status` (the OSC 7501 program status records
of the terminal, sorted by `id`: `{id, state, progress, kind, app, title, msg,
updated_seq, updated_at_ms, since_ms}`; `since_ms` is when the record entered
its current `state` and `kind` (a report that keeps both keeps it; a record a
daemon adopts from a terminal host starts at its `updated_at_ms`); `state` is `idle`, `working`, `done`, `blocked`
or `error`; `app` is the record's own app, else that of its nearest ancestor
record that has one (OSC 7501 app inheritance); `title` and `msg` are
untrusted display text without control or invisible formatting characters,
at most 256 and 1024 characters; a record that starts waiting on the user
(`blocked`), fails (`error`) or finishes (`done`, level `info`; clients show
it only for a terminal the user cannot see) posts one rate-limited `terminal`
notification on its terminal; a primary
prompt start removes `working`, `blocked` and `idle` records, an exited
terminal shows only `done` and `error`, at most 256 records; absent when
there are none; `cmux terminal <selector> status` prints it; the strongest
non-idle record is the tab's `program_status` in `list-workspaces` and the
`program-status-changed` subscribe event). Every status change also emits the
normal terminal upsert on `session.events`, so a socket client can update this
field without polling. Journal hooks filter the corresponding
`terminal.program_status` event; its explicit change envelope is documented in
[`session-journal.md`](session-journal.md). Other state resources travel as `state_upsert` and
`state_delete` changes whose `resource` is a `StateResourceKind`, and the
session snapshot lists them under `extra.state`. Clients that predate them
decode these changes as `Unknown`.

A closed tab, screen, or workspace is recorded where every close path meets,
in the transaction of its resource patch; a terminal that exits on its own
and anything inside an ephemeral workspace leave no record. The daemon closes
ephemeral workspaces at its next start and ends the terminals only they
showed. `workspace.create {ephemeral: true}` writes the flag in the transaction
that creates the workspace, so no read and no `session.events` change shows it
without `extra.ephemeral`; the flag is part of the request's fingerprint.
`workspace.update` does not change the flag. A move whose commit creates a
workspace for content of an ephemeral workspace (a tab, tab group, screen or
screen group moved to a new workspace, by a raw command or a v2 operation)
makes the new workspace ephemeral in that commit. A move between an
ephemeral workspace and an existing normal one is refused with a
`bad request` error and changes nothing.
`workspace.ensure_home {}` (`workspace-kind-v1`) is the only writer of
`extra.kind: home`. The hosting app sends it on every connect; the store
creates one empty home workspace with the fixed key `home`, places it first
and ungrouped in the personal order, and replays it after that. Every close
path that would remove the home workspace (`workspace.close`, `screen.close`,
`pane.close`, `tab.close`, `terminal.close`, the raw closes and batch closes)
refuses with `home.not_closable` before it ends a terminal (raw `error_code`
`home_not_closable`). A placement that moves the home workspace from the first
position or into a group, or puts another workspace before it, refuses with
`home.pinned_first` (raw `home_pinned_first`). `workspace.create` never
accepts `kind`, so TUI and CLI sessions never have a home workspace.
`workspace.ensure_app {app, route?, name?}` (`app-screens-v1`) is the only
writer of `extra.kind: app`. It makes the one workspace of an installed and
enabled app (`extra.app`) holding exactly one app tab, in one commit, and
replays the live workspace after that; an app that is not installed and
enabled refuses with `validation.invalid` (field `app`). The app tab is a
frontend-rendered tab (raw `Tab.app {app, route}`); the raw tree reports the
workspace as `Workspace.kind: "app"` with `Workspace.app`. `workspace.close`
closes the app; the next call makes a new workspace.
`personal-mixed-order-v1` puts personal groups and loose workspaces in one
sidebar order. A group's place is a position in the personal workspace order:
`workspace_group.update {top_index}` puts it right before the personal
workspace whose `workspace.placement.list` index is `top_index` (the count or
more: after every workspace), and `WorkspaceGroupSnapshot.top_index` reports
it. A group and a loose workspace at the same place show the group first.
`top_index: null` (every group before this capability) shows the group after
every loose workspace, in group order. A reorder of the workspaces keeps each
group at its place among the other workspaces, in the same transaction. A
group place at or before the home workspace refuses with `home.pinned_first`.
`workspace.list {order: "personal"}` returns the sidebar order: loose
workspaces, and each group's members (in personal order) at the group's place,
then this session's live workspaces without a personal row in session order;
the default `order: "session"` keeps the session order. To put a workspace
right after a group at a boundary, a client sends `workspace.place`, then the
group's `top_index`, in that order. Compatibility: a workspace this session
creates gets its personal row in the commit that creates it, by every
creation path and every client, at the place `workspaces.newPlacement` names
in the daemon machine's settings file (read by the daemon itself:
`CMUX_NEXT_CONFIG_FILE`, else `~/.config/cmux/cmux-next.json`, else classic
`cmux.json` before the app's first launch; the managed layer is not read):
`top` (the default, also for a missing or unknown value) right after the home workspace's row,
else first, ungrouped, so before every group at that place; `afterCurrent`
right after the session's active workspace before the commit, in its group
(`top` when there is none, it has no row, it is the home workspace, or the
new workspace is pinned to a room other than the group's);
`bottom` last, ungrouped. Several workspaces of one commit keep their order.
The home workspace (`workspace.ensure_home`) always takes the top, and a
reopened workspace is created last and then takes its closed row's place.
The creation's `session.events` batch carries a `workspace_placement`
change for each new row, the rows after them as a placement shift (below),
and a `workspace_group` change for each group whose `top_index` moved, and
no personal journal record of its own, so a group place counts it from the
start.
Placement shift: `index` is an ordinal, so a new row or a moved row changes
the `index` of the rows it passes, and nothing else of them. A commit
does not restate those rows; its journal record carries `placement_shift
{from_index, to_index}` (`to_index` null: through the last placement) beside
`changes`. A connection that echoed `placement-shift-v1` in `set-client-info`
or `client.metadata.update` (it does not order by `index`, for example
because it reads the order from the sidebar document) gets the batch as
stored: only the new or moved placement. `sidebar-doc-v1` alone does not
change placement delivery. Every other
connection gets, at the end of that batch's `changes`, a
`workspace_placement` upsert for each placement in the range, read from the
state when the batch is sent (a later write that moves a row again sends it
again, so a reader that applies the batches in order ends at the current
order; `forget-session`, which deletes a machine's rows outside a resource
batch, sends no placement change, as before). `workspace.place`, and a `sidebar.*` mutation that writes a
workspace's personal row back, do the same for the rows between the moved
row's old and new index. A caller that
wants another place sends `workspace.place` after the creation; that later
write wins. The commit bumps
`personal_revision` but sends no raw `personal-changed` event, so raw
`list-personal` readers see the row on their next refetch; a
workspace reopened with a key that already has a row keeps that row. Older
workspaces that have no row still follow every placement. Clients without the
capability ignore `top_index` and show every group after the loose
workspaces.
`workspace_group.delete` (and the raw `delete-personal-group`) keeps every
workspace open and stores the group as one closed-history item with no member
(`kind: "workspace"`, `member_count: 0`) and `ClosedItemSnapshot.group`
naming it. `closed.reopen` of that item (also after a restart) forms the group
again with its id, name, color, icon, pin, collapse, room and place, and puts back each
member whose personal row still exists and that is still ungrouped; a group
that exists again is left as it is. Its result names the session's active
workspace.
A window record put with `open: false` (`window_record.put`; the app closed
the window and keeps its workspaces) after an open one stores one closed-history
item of `kind: "window"` with no member, `window` naming the record
(`install/window`) and `name` the window's workspace. A put with `open` true
(or absent), and `window_record.delete`, remove the window's items. A window
whose record says `open: false` is not live: its groups and its window item
are in scope for every window (`closed.list`/`closed.reopen` with `window`).
`closed.reopen` of a window item reopens nothing in the daemon; its result's
`window` names the record for the app to show again and `workspace_id` the
session's active workspace.
`closed.reopen` with neither `closed` nor `window` skips window items: only
an app can show a window again, and it names its window.
`layout.bulk`, and `workspace.close` with `report_closed_ids: true`, answer
`closed_ids`: the closed-history items the call stored, oldest first (a
workspace that a close empties joins the close's item). Without the flag
`workspace.close` keeps its empty value, which older SDKs decode strictly. `closed.reopen` of each id restores exactly that close,
also when other closed workspaces have the same name, so an Undo of a bulk
close reopens what it closed and nothing else. `room.delete` keeps its single
`closed_id`.
`workspace-group-icon-v1` gives a personal group an icon:
`workspace_group.update {icon}` sets it to the shared icon string (one emoji,
an SF Symbol name, or a stored `image:sha256-<hex>` or `svg:sha256-<hex>`
asset, the rule every icon field uses) and `icon: null` clears it; anything
else, or an asset the daemon does not store, refuses with `validation.invalid`.
`WorkspaceGroupSnapshot.icon` and the raw `list-personal` groups report it
(null: no icon, and clients draw their default group glyph). Older daemons
omit the field.
`screen-group-icon-v1` and `tab-group-icon-v1` give screen groups and tab
groups the same icon: `screen_group.update {icon}` and `tab_group.update
{icon}` set it to the shared icon string and `icon: null` clears it, with the
same refusals. `ScreenGroupSnapshot.icon`, `TabGroupSnapshot.icon` and the
`state_upsert` changes on `session.events` report it. A saved group keeps its
live group's icon (`SavedTabGroupSnapshot.icon`, the raw saved screen
groups), and reopening a saved group, or the closed record of an ungrouped
tab group, restores it. The blob sweep keeps every asset a group or saved
group names. Older daemons omit the fields.
`workspace-group-pin-v1` pins (saves) a personal group:
`workspace_group.update {pinned: true}` pins it and `false` unpins it;
`WorkspaceGroupSnapshot.pinned` and the raw `list-personal` groups report it.
The daemon never removes a group because it is empty, pinned or not; the pin
tells clients to keep an empty group as a saved group (closing its
workspaces leaves it collapsed and empty, and opening it restores them)
instead of hiding it. Older daemons omit the field (not pinned).
`workspace.agent_folder.set {workspace, path}` (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE,
capability `workspace-agent-folder-v1`) sets the folder new agent chats of the workspace start in, for every client.
`path` is an absolute path of an existing directory in canonical form (the
filesystem's own resolution of it is the same string: no symlink, no `.` or
`..` step, no trailing slash), at most 4096 bytes; `null` clears it, and an
absent `path` is refused. Anything else fails with `validation.invalid`
(field `path`). Only origin `user` sends it (gate A2, "Request origin"): the
app sends it after a real user gesture, and an agent, a page or an app is
refused. The value is saved with the workspace state, so it survives a restart,
and travels as `extra.agent_folder`. The daemon never creates, moves or deletes
the folder. A workspace without one gets an app-owned agent-home folder for its
chats; that folder is not stored here. Neither the user's home folder nor a
folder above it is accepted (`validation.invalid`): an agent there could read
the whole home folder.
Every workspace snapshot also carries `extra.key`, the workspace key that its
terminals and agent chats get as `CMUX_WORKSPACE_ID` (in UUID form), so a client
can tell which acpmux chats run in a session's workspaces (`cmux agents chat`).
`workspace.agent_start.get {workspace, cwd?}` (capability
`workspace-agent-start-v1`, cx-9aps) is the one answer for where a new agent
chat of the workspace starts: `{cwd, kind, agent_home, skipped?}`. Rules, first
match wins: the proposed `cwd` (`seed`), the agent folder (`chosen`), the first
folder of the workspace's terminal tabs (`workspace`), the workspace's
agent-home folder `<data dir>/cmux/agent-home/<workspace key>` (`agent_home`).
A candidate counts only when it is an existing folder that is not the home
folder, above it, or inside agent-home; a proposed `cwd` that does not count is
returned in `skipped` with its reason (`home`, `above_home`, `agent_home`,
`missing`). Clients show the answer and start the chat there; they never decide
the folder themselves.
`workspace.open_url {workspace?, url}` (capability `workspace-open-url-v1`,
cx-ebm.59.3) opens a web link on the right side of a workspace, for every
client (the Chief chat in Home, a page, the CLI). It is one rule in the daemon:
`url` is an `http` or `https` URL with a host and no user name or password,
at most 8192 bytes, with no control, space or invisible format character
(bidi marks and overrides, zero-width characters; anything else is `validation.invalid`, field
`url`; a `cmux://` link stays the app's own action). An omitted `workspace` is the home
workspace (`selector.not_found`, scope `workspace`, without one). On the
workspace's focused screen, the right side is every pane outside a docked
column whose dock has role `agent_chat` or edge `left`. The selected browser tab
of the focused right-side pane, else of the right-side pane focused most
recently, else any browser tab there, navigates to `url` and becomes its
pane's selected tab; the keyboard focus does not move, so the person keeps
typing in the chat. A daemon-rendered tab's navigation is queued (raw
`browser-navigate` semantics), not confirmed: the reply means the navigation
is queued, not that the page loaded. A browser still starting loads it when
it attaches. A navigation that fails after the reply shows as the browser's
status, not as an error of this request, and a newer `workspace.open_url` or
navigation of the same browser supersedes one still pending. A frontend tab
navigates through its record (the app loads the new URL). Else a new browser tab (as `tab.create_browser`)
opens in the first of those panes, or in the screen `tab.create_browser` makes
for a workspace with none; with only the dock, it opens in a new viewport
column right of the dock, and the focus goes back to the pane that had it. The result is `{kind: "browser", workspace_id,
screen_id, pane_id, tab_id, browser_id, reused}`. Errors of the creation,
and a navigation the browser refuses before it is queued (a browser that
failed for good), are returned as they are (with no browser provider:
`operation.failed`, `extra.code` `engine_unavailable`). The request's key
records the result, so a retry answers it. Each creation, split, focus and
tab selection step runs under a key derived from the request's key, so a
retry replays it; the navigation has no step key, so a retry after a queued
navigation that the result missed queues the same URL again.
`closed.reopen` and `saved_tab_group.reopen` compose several creations; the request's key records the whole result, so a retry replays it.

A window record holds one app window's state (shown workspace, listed
workspaces, frame, selected tab per pane, focused pane). Its key is
`(install_id, window_id)` and its `owner` is the install that hosts the
window, its only writer. `window_record.put` and `window_record.delete`
compare `expected_revision` with the record's own revision (`0` = absent), so
windows and Macs never contend on one shared document. The daemon trusts the
`install_id` a request names until connections carry an authenticated install
identity. At the first open of a registry with these tables, the rows of the
`windows` frontend projection (frontend `cmux-next`, scope `personal`) become
records owned by `install_unadopted`; the first put of the same `window_id`
by an app adopts that record (its revision continues; the batch deletes the
unadopted record), and `window_record.delete` drops one the app does not
adopt. The projection stays readable and writable for older apps and is not
kept in sync after the migration.

The sidebar section layout is one document per user (`sidebar-layout-v1`):
ordered sections in the regions `top`, `middle` and `bottom`, each holding
items (references to apps, built-ins, workspaces, tabs and so on), the
workspace list (exactly one section), or an app's contributed section.
`sidebar_layout.update {op}` applies one op of the app's reducer
(`section.add`, `section.update`, `section.move`, `section.remove`,
`item.add`, `item.move`, `item.remove`, `item.remove_ref`, `item.update`,
`layout.reset`) under the request's idempotency key; a reject is
`validation.invalid` whose message is the reducer's reason and writes
nothing, and an op that changes nothing commits with no change. Sections and
items are carried as JSON objects, not closed catalog types: values and keys
a newer app writes (a new arrangement, item kind, built-in id or field) are
stored verbatim and come back unchanged. A new `region` or `content` value is
refused, because the app decodes those two strictly. A workspace item's ref
value is the qualified public id `<session>:ws_…` and a tab item's
`<session>:tab_…`; the store compares refs as opaque kind and value strings,
so one local id on two sessions is two refs, and it does not check that the
target exists. A change advances the layout's own
`revision` (a decimal string), publishes a `state_upsert` of resource
`sidebar_layout`, id `user`, and advances `personal_revision`, so raw
clients get `personal-changed` (`{event, personal_revision}` with no `kind`
field, because SDK decoders refuse unknown fields) and refetch with
`sidebar_layout.get`. Apps hold `sidebar_layout:read` with the app;
`sidebar_layout:write` is elevated (scope-classes.json): only an explicit user
grant adds it.

The sidebar document is one per user (`sidebar-doc-v1`): ordered sections
(`machine` with its `session_id`, one per machine; `pinned`, id `sec_pinned`,
the first section, with no title by default; `custom`; `app` with its
`contribution`; `builtin`) holding ordered items (`workspace` with its ref
`{session_id, workspace_id}`, `group`, `builtin`, `app`, `url`, `tab`,
`room`, `saved_group`), each with a fractional `order` key. A workspace or
group is placed exactly once; groups are one level deep and hold one
machine's workspaces; a workspace or group of one machine is refused in
another machine's section (`cross_machine`); an app section takes no items
(`provider_owned`); a machine section cannot be removed. Pinned and custom
sections keep a closed workspace or an empty group (`keeps_closed`); a
machine section shows only live workspaces. `sidebar.get` reads it as
`{revision, sections, items}` (each section and item carries its
forward-compatible keys in `extra`). Each section has `scroll`: `fixed`
(it stays visible, in the fixed stack at the top, or at the bottom for the
bottom region) or `flow` (it scrolls with the main list); the default is by
kind and region (built-in and Pinned fixed, machine flow, custom and app
fixed at the top and bottom and flow in the middle), and `section.move` into
another region moves a default value with it. `max_rows` (1 to 50) lets a
section grow with its content up to that many rows, then scroll inside
itself; without it the section grows without limit. `align` (`leading`,
`center`, `trailing` or `fill`; default `leading`) places an inline or grid
section's rows or tiles on their line, and `gap` (0 to 32 points; absent is
the look's default spacing) is the space between them: the old layout's
`arrangement.align` and `arrangement.gap`, migrated, copied once at open
into a document migrated before they existed, and followed when an old
client changes them through `sidebar_layout.update`. `sidebar.reset` (and
the old `layout.reset`) restores the default sections: Home and App Store
(`sec_top`), an empty Pinned, every machine section with its default look,
the recent agent chats and the account band; it keeps each workspace and
group (those in Pinned or a removed section go to the end of their machine
section) and removes this machine's closed workspaces and every other item
of the removed sections and Pinned. `sidebar.item.remove_ref {ref}` removes
every item that shows an old layout ref ("Remove from Sidebar"). `sidebar.item.update`
also takes `room` (the item's `extra.room`, null clears it): the space whose
windows draw a Pinned link, tab or app. A `url` item's body has
`icon_url` (its favicon, set by `sidebar.item.update`); an older client's
`extra.icon_url` moves into the body when the item is added and, for stored
items, once at open. `sidebar.move {items, to}`, `sidebar.pin`,
`sidebar.unpin` (to the item's own machine section), the `sidebar.item.*`,
`sidebar.section.*` and `sidebar.group.*` mutations and `sidebar.adopt
{refs, to?}` are one reducer op each; `sidebar.apply {ops}` applies a list
atomically, including the `close {refs}` op: a closed workspace leaves a
machine section (with a group there it empties) and stays in Pinned and
custom sections, where it draws dimmed; the daemon applies it itself when a
workspace of this machine closes. Each returns `{revision, inverse}`, where `inverse` is the list
of `item.put`, `item.delete`, `section.put` and `section.delete` ops that
`sidebar.apply` takes to undo it. A refusal is `validation.invalid` whose
reason is the reducer's and writes nothing. A change publishes, in its
`session.events` batch, a `state_upsert` or `state_delete` per changed
`sidebar_item` and `sidebar_section`, then a `state_upsert` of resource
`sidebar_doc`, id `user`, with `{revision, previous_revision,
idempotency_key}`; a client whose revision is not `previous_revision`
refetches with `sidebar.get`. When Pinned changes, the batch also restates
`sidebar_layout` and advances `personal_revision`. The daemon makes the
document once, when a registry without it opens, from the sidebar layout,
the personal order, pinned groups (into Pinned) and pin flags; the old
tables stay. The old verbs keep working on top of it: `sidebar_layout.get`
shows the Pinned items as the `sec_pinned` tiles (its revision is the
layout's plus the document's), a tile `sidebar_layout.update` adds, removes
or reorders is a Pinned op, personal group and placement writes, pin flags
and new workspaces' personal rows are followed into the document
(incrementally: triggers mark the changed rows), the items a `sidebar.*`
mutation changes are written back to the personal rows and groups (a
workspace in Pinned or a custom section is a loose row at its document
position, a group in Pinned is `pinned`), and
`workspace.list` (no `order`, or `order: personal`) is the document's order of this machine's workspaces: sections in display
order (Pinned before the machine sections), each group's members in place
after the group, and a live workspace the document does not place yet where
`workspaces.newPlacement` puts a new one. Only the array order changes (the
`index` field stays the session index); `order: session` keeps the session
order. The private `list-workspaces` tree keeps the session order, because
its `workspace-added` / `workspace-moved` deltas carry session indexes.

The palette usage history is one document per user (`palette-usage-v1`): the
palette rows the user ran (a decayed use count per row key, half-life three
days) and learned picks (per normalized query start of 1 to 8 characters, the
rows run for it, decayed with a seven-day half-life, and the latest of them).
The daemon is its one writer and stamps every use with its own clock.
`palette_usage.record {key, query?}` records one run and returns only
`{revision}`; `palette_usage.import {source, entries}` merges a former history
once per source and returns `{revision, imported}`. The `state_upsert` of
resource `palette_usage`, id `user`, carries only `{revision}`, and replay
fingerprints hold a SHA-256 of the key and query, so usage never reaches an
event or the journal. `palette_usage.hide {key, hidden?}` hides a row from
the palette (it shows only for a query that is its whole title) or shows it
again, and `palette_usage.forget {key}` (Reset Ranking) forgets a row's uses
and learned picks; both return only `{revision}`. `palette_usage.get` (a
read) returns the whole history, with the hidden keys. The ranking
rules that read it live in the shared palette ranker, not in the daemon. The
history stays on the Mac: MCP and the CLI do not offer these operations, and
`palette_usage:read|write` are restricted app scopes.

A stash (`stash-v1`) is a group of web pages the user closed on purpose,
kept until restored or deleted (no retention pruning). `stash.create {tabs}`
or `{workspace}` closes the pages in one commit and records them as one
stash named after their workspace instead of in the closed history; a tab
that is not a web page or is incognito refuses `{tabs}`, and `{workspace}`
leaves such tabs (and pinned ones) open as `skipped`. Members keep the
closed-history tab record (URL with secret query keys stripped, profile,
engine, back/forward history) and a stable member `id`; `members` names
members by those ids, and an id the stash no longer holds is
`resource.not_found` with nothing changed. `stash.restore {stash, members?,
target?, pane?}` reopens them like `closed.reopen` (`here`; a member whose
own pane is gone opens in `pane`, the pane the user acted from) or in one
new workspace (`new_workspace`); restored members leave the stash in the
same commit. A restore is all or nothing: when one member cannot reopen,
the pages it opened close again and every member stays, so a retry opens
each page once. App tabs and pages that are not http(s) are never stashed.
`stash.delete` drops members or a stash, `stash.import {source: onetab,
groups}` stores OneTab groups (http(s) pages only), and `stash.list` never
shows back/forward history. Every listed member has a `kind`: `tab` (a
page) or `workspace`. With `stash-workspaces-v1`, `stash.create {workspaces,
name?}` closes those workspaces whole, every tab and terminal, in one commit
as one stash (named `name`, else the workspace's name when there is one
workspace) of `kind: "workspace"` members in the closed-history workspace
record (screens, splits, presentation), and records nothing in the closed
history; an incognito workspace refuses the request and the home workspace
is `home.not_closable`, with nothing closed. Their terminals end and keep no
archived screen. `stash.list` shows a workspace member's `name`,
`tab_count` and its first 50 `tabs` (`kind`, `title`, and `url` for a web
page only). `stash.restore` reopens a workspace member as its own workspace
for either target, with its screens, splits, name, color, group, sidebar
place and tab groups; `new_workspace` takes only the pages. Deleting a
workspace member moves its agent-home folder to the Trash, as `closed.delete`
does. Changes are `state_upsert`/`state_delete` of resource `stash`. Restore opens URLs and every mutation changes local state,
so no remote relay may forward `stash.*`; MCP and the CLI do not offer them.

## Selectors

Every CLI instance selector accepts:

1. a typed opaque ID;
2. `current`;
3. an exact name.

`name:<value>` forces name interpretation. It is required for names equal to
`current`, names shaped like opaque IDs, and names containing `_`. The prefix
is syntax and is not part of the matched name.

An exact name with zero matches returns `selector.not_found`. More than one
match returns `selector.ambiguous` with every candidate ID. Resolution and
mutation use one snapshot, so an ambiguous request cannot partially mutate.
SDK `find_by_name` methods always return a list.

Session-resource requests always carry `machine` and `session` routing
selectors. Structural selectors after the session are flat fields named
`workspace`, `screen`, `pane`, and `tab`. An opaque nested target ID may omit
those ancestors. A `current` or name target requires the complete contiguous
structural chain through its parent, supplied by CLI or SDK context.

An opaque terminal ID resolves without a structural ancestor even when the
terminal has no tabs. Supplying a tab disambiguates one view for view
operations such as `terminal.move`; a terminal-only selector uses the first
durable view when one exists. Content operations, including input, history,
screen reads, projection, waiting, and explicit close, address the terminal
resource and continue to work with zero views.

A terminal an app's byte backend opens (`cmux.terminal.backend/1`) starts
with zero views and no durable record. Its first `terminal.project` writes
the durable terminal record in the destination workspace in the same commit;
later projections reuse that record.

Every supplied ancestor must contain the resolved descendant. A mismatch
returns `selector.wrong_parent` with the expected and actual parent before a
read or mutation runs. Selector resolution, containment validation, revision
validation, and mutation commit use one snapshot, so a failed containment
check cannot partially mutate.

## Protocol

Unix sockets use one UTF-8 JSON object per line. WebSockets use one UTF-8 JSON
object per text frame. Both transports carry identical envelopes.
`pairing_request.list` and `pairing_request.resolve` require a trusted local
Unix-socket connection and are unavailable over WebSocket. Request IDs are
connection-scoped and unique among pending requests. A caller may reuse an ID
only after consuming its response or completing the `request.cancel`
lifecycle.

Request:

```json
{
  "protocol": "cmux.protocol/2",
  "type": "request",
  "id": "request-owned-bounded-string",
  "operation": "workspace.list",
  "params": {
    "machine": "machine_…",
    "session": "session_…"
  }
}
```

Success:

```json
{
  "protocol": "cmux.protocol/2",
  "type": "response",
  "id": "request-owned-bounded-string",
  "ok": true,
  "result": []
}
```

Failure:

```json
{
  "protocol": "cmux.protocol/2",
  "type": "response",
  "id": "request-owned-bounded-string",
  "ok": false,
  "error": {
    "code": "selector.ambiguous",
    "message": "more than one workspace is named \"api\"",
    "details": {"candidates": ["ws_…", "ws_…"]},
    "retryable": false
  }
}
```

A request may carry `credential`, the caller's launch credential
(`CMUX_LAUNCH_CREDENTIAL` in a cmux terminal or ACP session). Only a local
Unix connection may present one. The server verifies it before any owner
sees the request and records the terminal or ACP session it names as the
request's actor beside `origin`; a caller can never send an actor. A
credential that is tampered, malformed, for another session, or for a closed
terminal is refused with `validation.invalid` on field `credential`
(`details.reason` `credential_invalid`, `credential_malformed`,
`credential_foreign_host`, `credential_closed` or `credential_not_local`); a
credential whose key was rotated away counts as absent. It is never part of
the idempotency fingerprint, so a replay keeps the first actor.

Reads omit `idempotency_key`. Every mutation requires a key containing 1 to
128 UTF-8 bytes, at least one Unicode scalar outside the Unicode `White_Space`
property, and no Unicode `Cc` control scalar. Leading, trailing, and internal
non-control whitespace is preserved.
Repeating the same key, operation, and canonical parameters returns the
committed result. Reusing a key with different parameters returns
`idempotency.conflict`. Replay lookup runs before selectors and revision
checks. SDKs never retry mutations implicitly.

### Request origin

Capability `origin-claim-v1`. The daemon derives one origin per request from
its connection: `page` on every request of a connection whose `client-hello`
role is `page_relay`; `user` only on a verified cmux app connection (role
`main` plus a proof; none exists before peer verification ships); `app` for an
app's calls through the app supervisor; `agent` on every other connection,
including one that sent no `client-hello`. `set-client-info` never changes it.

A request may carry `"origin": {"claim": "page"|"agent"|"app"|"user",
"confirmation"?: "<token>"}`. A claim may only narrow the derived origin
(`user` > `app` > `agent` > `page`). On a page relay connection the only
accepted claims are `{"claim": "page"}` and `{"claim": "user",
"confirmation": <token>}`, where the token comes from
`origin.confirmation.issue` and is consumed on first presentation. A request
with no `origin` keeps the derived origin. Any other claim, a spent, expired or
mismatched token, and `origin.confirmation.issue` on a page relay fail with
`origin.forbidden` before the request is parsed further; every transported
operation may return it.

`apps.install`, `apps.uninstall`, `apps.enable` and
`workspace.agent_folder.set` need origin `user`, whatever the spelling of
the operation name (a `\u` escape included). A
refusal is `origin.forbidden` with the message "needs a verified cmux app
connection" and details `{"required": "user", "derived": <origin>}`.

`origin.confirmation.issue {operation, params_sha256, relay_connection_id}`
returns `{token, expires_at}` to the verified app for a page relay connection
of the same peer: 32 random bytes in base64url, single use, valid 60 s, bound
to the operation, to `params_sha256` (SHA-256 of the request params in
canonical JSON: keys sorted by code point at every depth, no whitespace, UTF-8,
no escaping of `/` or non-ASCII) and to that relay connection. The digest is
over serde_json's compact re-serialization of the received params; a client
must hash the exact encoding it sends. Floats whose shortest form differs
between encoders (for example exponent notation) make the digest differ, and
the claim fails closed with `origin.forbidden`; confirmed page operations carry
integer params. Validity uses a monotonic clock: a wall clock step neither
extends nor cuts the 60 s; `expires_at` is wall-clock milliseconds for display.

The legacy `apps-set` command (install, uninstall, enable, disable, hide,
sandbox and grant changes, whatever `origin` it claims) and every legacy
`apps-*` request with `origin: "user"` (for example an `apps-run` gesture)
need origin `user` too, with the same refusal in the raw envelope:
`error_code` `origin.forbidden`, `error` "needs a verified cmux app
connection" and `error_details {"required": "user", "derived": <origin>}`. A
connection that only declares `set-client-info` kind `app` is not the verified
app. Hiding an app needs a verified app until P8 adds the verified-app path:
agents must not change what the user sees.

Completed pure mutations retain the newest 4096 ordinary replay records. A
running registry may retain at most 127 additional ordinary records between
batched pruning passes; startup removes that slack. The newest
`session.terminal_defaults.update` record remains pinned because it is the
current durable defaults projection. Records associated with pending,
executing, or indeterminate effect receipts, or prepared, executing, or
indeterminate creation receipts, remain pinned until those receipts reach a
terminal state. After an uncorrelated ordinary record leaves the window,
reuse of its key is a new mutation. Completed creation correlations and effect
outcomes remain authoritative in their separate receipt tables after a
mutation replay record expires, subject to the receipt retention policy below.

Interactive terminal, browser, and sidebar input payloads never enter durable
effect fingerprints or intents as plaintext. Their fingerprint uses
HMAC-SHA256 with a random 32-byte state-root pepper, the idempotency key,
operation, and canonical fields. SQLite stores only the digest, a redaction
marker, and the pepper identifier. The owner-only pepper file is shared by
sessions under one state root; a missing, corrupt, or mismatched pepper makes
the registry fail closed. `browser.navigate` is excluded because browser URLs
already persist as public browser topology, events, and outcomes.

Committed `terminal.input.*`, `terminal.viewport.scroll`, `browser.input.*`,
and `sidebar_view.input` receipts have a bounded replay window. The registry
retains the newest 4096 uncorrelated committed receipts, with at most 127
additional rows between batched pruning passes; startup removes that batching
slack. Pending, executing, indeterminate, and creation-correlated receipts are
never evicted. After a committed receipt leaves this window, reuse of its
idempotency key is treated as a new mutation. These finite retention windows
are the exceptions to the mutation replay guarantee above.

`agent.report` requires a live terminal and has no session-global or default
agent record. The registry stores one current projection row per live
terminal. Public `agent.report` and raw `report-agent` use the same durable
commit path. A report that changes the effective projection advances the
public resource revision and publishes one agent change to `session.events`.
A semantically identical socket report is recorded as a replay-equivalent
receipt at the current revision, without changing the projection or emitting
another event. A hook report replaces socket state; a socket report that is
retained by an unchanged hook therefore also takes this no-op path. Restart
restores agents from the current projection table rather than scanning report
history. Tombstoning a terminal deletes its projection in the same transaction,
so historical reports cannot resurrect it.

An agent value's `extra.agent` names the hook adapter (`claude`, `codex`, ...)
when one has claimed the terminal. `extra.agent_session_id` is the agent's own
session id from its hook events (Claude's `session_id`). It is opaque metadata
that a client can pass to the agent's own resume path (for Claude,
`claude --resume <id>`); this API does not define a resume operation. Both the
`agent` upsert change and the snapshot and `agent.list` values carry it, and it
is persisted with the projection, so it survives a restart. A later hook
session on the same terminal (for example after `/clear` or a resume) replaces
it. It is absent for socket, plugin, and screen-detected agents, for hook
adapters that report no session id, and for ids longer than 256 bytes or with
characters outside `[A-Za-z0-9._:-]`. Clients still pass it as a separate
argument, never through a shell string. The id is opaque
metadata at the same level as terminal IDs; remote clients receive it like the
rest of the agent value. An ended hook session still publishes a `delete`
change for the agent.

```json
{
  "id": "agent_4f0c9f2a8e1b3d5c7a9e0b2d4f6a8c1e",
  "session_id": "session_…",
  "terminal_id": "terminal_…",
  "state": "working",
  "source": "hook",
  "updated_at_ms": "1790000000000",
  "source_session": null,
  "extra": {"agent": "claude", "agent_session_id": "6f1d2c3e-…"}
}
```

`agent.message.send` stores a message from one agent (or a person) to others
before anything tries to reach them. A recipient is a terminal agent
(`term_…`) or an acpmux session (`acp:<session id>`). The message carries the
agent-rooms envelope (`plans/feat-agent-rooms/DESIGN.md`): an id
(`msg_<32 hex>`), a thread id, the sender address and an untrusted display
name, the body, and the parent and ancestor ids of a reply. The sender is the
request's verified actor: the terminal or ACP session its launch credential
names, else `cli` (the person: the local user or the verified app; any other
actor is addressed by its stored form and its workspace is never known). A
`sender` field that names anyone else is
refused (`validation.invalid`, reason `sender_mismatch`). The message and its
receipts live in the session registry, so they survive a daemon restart.

Each recipient has its own delivery, which starts by the workspace rule:
`queued` when the sender is the person or shares the recipient's workspace,
`held` (reason `workspace_unknown`) when the daemon cannot tell either
workspace (a terminal's from its placement, an acpmux session's from
`_acpmux/info`'s session env), and for agents of different workspaces as the
daemon's `CMUX_AGENT_MESSAGE_CROSS_WORKSPACE` says: `hold` (the default;
reason `cross_workspace`), `refuse` (the send fails, reason
`cross_workspace`) or `allow`. `agent.message.release` is the person's
decision on a held delivery, made in the verified cmux app: `approve` queues
it, `decline` declines it; any other request, a plain local connection or the
CLI included, is refused (reason `release_needs_app`), because any local
connection may be an agent that left out its launch credential. For the same
reason holds are advisory against such an agent: it sends as the person until
launch credentials are mandatory. A held delivery nobody
decides on for 24 hours is declined with reason `expired`; a read reports it
so at once, and the next agent message mutation stores it. The limits count
stored rows, so a restart keeps them; each refusal is `operation.failed` with
its `details.reason`: 5 sends in 10 seconds per sender and 20 a minute per
sender and recipient (`rate_limited`), 50 queued or held deliveries per
recipient (`queue_full`), replies at most 8 deep (`reply_depth`), 40 messages
per thread, counted apart from pruning (`thread_budget`), and the same body from the same sender to the
same recipient within 10 seconds (`duplicate`). A body over 32768 bytes is
`validation.invalid`, reason `body_too_large`. An agent puts a message or a
reply in an existing thread only when it sent one of the thread's messages or
one was addressed to it (`thread_not_joined`). Format errors and the burst and
per-recipient limits are checked before the daemon asks acpmux anything.

`agent.message.mark` moves a receipt to `delivered`, `acknowledged` or
`failed` and records the delivery path in `via`; receipts only move forward,
except that a queued or failed delivery may fail again or be delivered, and a
delivered one may fail when the path that claimed it could not hand it over.
A held delivery moves only by release; `declined`, `unsent` and `retracted`
are final. A reply without recipients goes to its parent's sender and stays
in the parent's thread. `agent.message.list` returns the newest messages first
(or the oldest, with `oldest_first`), filtered by recipient, sender, thread
and the recipient's delivery state; every delivery carries its state, reason
and timestamps. Messages are not published on `session.events`. Any local
caller may list or mark any message, and the body is untrusted input for the
recipient and never an authority grant. Messages beyond the newest 2000 are
pruned once no recipient is still queued or held.

The daemon delivers a queued message to an acpmux recipient itself: its
delivery pump hands it to the session as a prompt whose id is the message id,
with `_meta.acpmux.provenance` naming the sender, once acpmux runs that
session, and marks it `delivered` (`via` `acp.prompt`) when acpmux accepts the
prompt or `failed` with acpmux's error. A prompt acpmux never accepted stays
`queued` with the attempt counted (acpmux runs a prompt id once, so the retry
is safe). The pump runs on every send and release, at daemon start, whenever
it reaches acpmux again, and on a backoff timer (1 s doubling to 60 s) while a
delivery waits for acpmux; a held delivery waits for release. It is the one
acpmux delivery path: `cmux agent message` waits for it and reports how it
went. An agent acpmux starts carries a launch credential for
its own ACP session (acpmux mints it with `credential.mint` from the daemon its
`CMUX_TUI_SOCKET` names), so its messages have a verified sender; without a
daemon to mint one it starts without a credential.

`agent.message.unsend` takes a message back, for every recipient or only
`recipient`. Only its verified sender or the person in the verified cmux app
may, with no time limit; any other agent is refused (reason
`unsend_not_sender`), and so is a plain local connection, which may be an
agent that left out its launch credential (reason `unsend_needs_app`). Each delivery gets an outcome: `unsent` when it never
reached the agent (held, queued or failed, or still waiting in acpmux's queue;
the delivery becomes `unsent`), `retracted` when acpmux's turn ran it and
acpmux told the agent it was withdrawn, steered into the turn or queued next
for an agent that does not steer (the delivery becomes `retracted`), and
`too_late` when its turn ended or the delivery path cannot take it back (a
terminal agent's hooks; nothing changes), and `failed` when it cannot be taken
back now (nothing changes). An acpmux recipient's outcome is acpmux's
`_acpmux/prompt_withdraw` answer. When acpmux does not answer for a delivery a
hand-over may have reached, the outcome is `failed` with `error.reason`
`acpmux_unavailable`; a withdraw acpmux refuses is `failed` with
`error.reason` `withdraw_refused` and `error.acpmux_reason` (`withdraw.refused`
when acpmux names none). A queued delivery a pump hand-over went out for,
which acpmux never accepted, is asked too: when acpmux holds no such prompt
the outcome is `failed` with `error.reason` `acpmux_unavailable` (the
hand-over may still reach it, so try again), and when acpmux no longer knows
the session (it was deleted, and no peer daemon runs it) it is `unsent` (no
session can take it late). The other
deliveries' outcomes still commit. A retry under the same key replays, and a
reused key or stale `expected_revision` is refused, before acpmux is asked;
acpmux's answers then commit even when other state changed while it
answered.
The result names each delivery's outcome and the message; `outcome` is
`failed` when any delivery failed, else `too_late` when any was too late, else
`retracted` when any was retracted, else `unsent`. An unsend runs on this machine only; the remote CLI
relay does not allow it.

`terminal.viewport.scroll` changes the session's compatibility inspection
viewport. Interactive frontends keep scroll in their own terminal mirror and
must not call this operation for user scrolling. Its first success returns the
existing resource revision, inserts no resource mutation or event, and neither
advances nor wakes `session.events`. A real compatibility-viewport change
still emits the ordinary `scroll` item on `terminal.attach`. Same-key,
same-request replay returns the original value, generation, and revision with
`replayed: true` without applying the delta again. After bounded receipt
eviction, the key executes as a new mutation.

`sidebar_view.input` compares the complete public sidebar lifecycle snapshot
immediately before and after the PTY write. If the snapshot is unchanged,
success and replay return the current resource revision without inserting a
resource event or waking `session.events`. If `running`, `cols`, or `rows`
changes during the effect, the commit advances revision once and emits one
`sidebar_view` upsert containing the post-write snapshot. Failure to observe
the post-write snapshot returns `mutation.indeterminate`.

`session.shutdown` requires a trusted local Unix-socket connection and is
unavailable over WebSocket. With `force: false`, another connected client whose
kind is `native-browser` blocks shutdown. `force: true` bypasses only that
ownership check; it does not bypass transport, selector, revision, or
idempotency validation. On success, the server commits the durable receipt,
queues its response, and requests process exit only after the queue succeeds.
If queueing fails, the server cancels the shutdown handoff and does not request
exit. Repeating the same key replays the durable receipt, reserves a new
handoff, and may request exit after the replay response is queued.

Requests are limited to 4 MiB. Server responses and stream envelopes are
limited to 16 MiB. Newlines are framing and do not count toward either limit.
Each stream queue holds at most 256 messages and 16 MiB, with a separate
control-message reserve. A slow stream ends with reason `gap`, the current
cursor, and recovery instructions without breaking other requests or streams.

The client generates a connection-scoped `stream_` ID in every stream-open
request. The router installs the tap and stream registry before acknowledging
the request, enqueues the success response, then releases the initial
snapshot. `stream.cancel` is connection-local and idempotent. It purges queued
items, cleans up taps and sizing leases exactly once, queues one
`stream_end(canceled)`, then returns its response. No item may follow an end.

An SDK accepts a stream open only after validating its successful response and
matching `stream_id`. If dispatch of a complete request was confirmed but no
valid acknowledgement was accepted, the SDK must release the provisional
route within a fresh bounded lifetime. A shared transport does so by sending
`stream.cancel`, validating its response, and forbidding connection reuse
until confirmation. A stream that owns a dedicated transport may instead
explicitly close that transport within the same bounded lifetime. Cleanup
failure closes the owning transport. The original open error remains the
caller-visible error.

A valid `ok: false` structured error conclusively rejects the open, so the SDK
removes its provisional route without cancellation and may reuse a
framing-safe transport. An open that was not dispatched sends no cancellation.
If an outgoing frame may be partial or framing is otherwise uncertain, the SDK
must append no cancellation and must close the transport. Failed-open cleanup,
explicit cancellation, and overflow cleanup share one per-stream claim so at
most one cancellation request is sent.

Explicit cancellation succeeds only after both the exact empty
`stream.cancel` response and the matching canonical
`stream_end(canceled)` arrive within one absolute deadline. They may arrive in
either order. Earlier queued items do not extend the deadline. A missing,
malformed, or differently terminated end fails cancellation and closes the
owning transport.

A request deadline is one absolute deadline covering connection, writer
admission, complete dispatch, and response, including a stream-open
acknowledgement. After acknowledgement, ordinary stream idleness has no
implicit deadline. A caller may use a bounded poll without closing the stream;
only cancellation, a `stream_end`, transport failure, or an explicit
application-owned lifetime ends it.

`terminal.wait` and `terminal.wait_exit` may remain pending without a protocol
deadline. After a completely dispatched wait reaches a caller-local timeout or
abort, an SDK sends `request.cancel` on the same connection with the original
public request ID and a fresh bounded cleanup deadline. `{canceled: true}` is
the cancellation linearization point and guarantees that the target request
will send no response; the worker and its admission permits are released
before confirmation. For a fully dispatched target on the same connection,
`{canceled: false}` means the request left the active registry only after its
response queue attempt. The SDK retains and drains that exact target response
before reusing a shared connection. An absent target response, or missing or
malformed cancellation confirmation, closes the transport before reuse.

The server registers each pending screen wait before reading the viewport.
Terminal output, resize, reconnect, clear-history, request cancellation, and
connection close wake that registration. An unbounded wait performs no
periodic screen polling.

Stream items use decimal strings for sequences and cursors:

```json
{
  "protocol": "cmux.protocol/2",
  "type": "stream_item",
  "stream_id": "stream_…",
  "sequence": "42",
  "cursor": {"generation": "opaque", "revision": "105"},
  "item": {"event": "terminal.output", "data": {}}
}
```

Response, `stream_item`, and `stream_end` envelopes use exact field sets.
Responses require `protocol`, `type`, `id`, and `ok`, plus exactly one of
`result` or the exact structured `error` according to `ok`. Stream items
require `protocol`, `type`, `stream_id`, canonical decimal `sequence`, and an
object `item`; optional `cursor` is non-null and strict when present. Stream
ends require `protocol`, `type`, `stream_id`, and `reason`; optional `cursor`,
`recovery`, and `error` are non-null and strict when present, and `error` is
present exactly when reason is `error`.

`session.events` accepts an optional generation plus last-applied revision
cursor. With no cursor, it sends one snapshot then live batches. With a
covered cursor, it replays through the captured head before live delivery. A
generation mismatch or expired cursor sends a fresh snapshot with
`reset_reason`; a cursor ahead of head returns `cursor.invalid`. One atomic
transaction produces one `session.delta` batch with `previous_revision` and
the new revision. A batch need not restate unchanged resources: an upsert whose
value the journal already states may be left out, and a topology create
restates every workspace value but only the subtree of the workspace it changed
(and of the old and new active workspace when focus moved), plus terminals of
that subtree that live elsewhere. A consumer applies each batch on top of the
state it holds. Durable resource batches are append-only. A registry upgraded
from the earlier bounded store preserves its oldest retained revision and sends
a fresh snapshot when a requested cursor predates that boundary. Transport
stream queues remain bounded independently.

`session.journal.subscribe` is the append-only feed. Omitting a cursor tails
from the captured head; `start:"beginning"` replays retained history first.
`follow:false` bounds replay to the head captured when the stream opens and
ends it with reason `completed`; this is the primitive behind CLI `journal
read`.
Its cursor generation is the immutable session ID and its revision is the
journal sequence. Structured and compiled-regex filters are server-side and
never alter cursor order. Unix clients may read through `sensitive`; remote
clients are capped at `metadata`, receive redacted authority and causal fields,
and may run regex only on kind or subjects. A slow subscriber receives
`stream_end` with reason `gap` and the last recoverable cursor, then reconnects
from that cursor. Producer, hook, checkpoint, restore-preview, and segment
operations require a trusted local connection.

Terminal and browser attachments have independent decimal-string sequences.
Their initial snapshot is delivered after the open response. Overflow
requires a fresh attachment snapshot.

`terminal.screen.read` may include two optional terminal metadata fields. They
may be absent or null when the server cannot provide them. `revision` is a
coalesced PTY output counter, and `osc_progress` is bounded OSC 9 progress text.
These fields are generic protocol data. The daemon does not identify agents or
apply vendor rules. A userland plugin can combine the metadata with process
information and screen text before appending its own journal event.

Every `browser.attach` frame also carries a required nullable
`pointer_frame_seq`. A null token permits rendering but forbids pointer input.
`browser.input.mouse` and `browser.input.wheel` require the exact non-null
decimal token from the frame whose pixels supplied the coordinates. Repaint,
navigation, and geometry changes can invalidate earlier tokens; invalid input
fails closed instead of being retargeted to the latest frame.

Every domain stream item union is open for SDK decoding. `session.events`,
`terminal.attach`, `browser.attach`, and `sidebar_view.attach` expose an
`Unknown` variant that retains the unrecognized discriminator and complete
raw object. A recognized discriminator must decode against its exact known
schema; malformed known payloads are errors and never become `Unknown`.
Servers emit only cataloged known variants.

`terminal.attach` is the public server-rendered stream. Its snapshot and
patches contain styled rows and runs, cursor state, resolved default colors,
scrollback counts, resize metadata, and an atomic `full_reset` marker. Raw PTY
bytes remain in the raw protocol; `terminal.state.read` supplies VT replay for
raw clients. `sidebar_view.attach` reuses the same `RenderSnapshot`,
`RenderPatch`, and `RenderScroll` types so Ratatui/plugin sidebars preserve
styles, cursor state, wide-cell width hints, and palette changes. Styled
terminal history uses the same `RenderRow` and `RenderRun` model.

`session.events` sends typed ordered `ResourceChange` values. Upserts carry a
typed resource ID and matching snapshot; deletes carry the typed ID and no
value. A screen snapshot includes its complete typed layout. One transaction
produces one batch bounded by `previous_revision` and `revision`, so frontends
can apply it without parsing generic JSON or refetching layout.

`stream_end.error`, when present, is the full structured error object with
`code`, `message`, `details`, and `retryable`. End reasons retain optional
cursor and recovery instructions.

## Typed operation catalog

`resource-operations-v2.json` is normative for every transported operation's
class, flat selector scopes, parameter fields and requiredness, result type,
structured errors, and stream item/end types. `resource-operations-v2.schema.json`
defines the catalog format. Unknown parameter and result fields are rejected.

| Class | Semantics |
| --- | --- |
| `read` | Read only. No idempotency key. |
| `mutation` | Durable mutation. A non-empty idempotency key is required. |
| `stream_open` | Opens a stream. The client supplies stream_id. No idempotency key. |
| `connection_control` | Connection-local control. No idempotency key. |
| `local` | Filesystem-only plugin manager action. It never uses a protocol request envelope. The agent plugin manager is a CLI entrypoint; it is not a transported resource operation. |

Userland agent plugins use the normal journal operations. They register a
`JournalProducerManifest` with `session.journal.producer.put`, then append
`JournalIngress` events with `session.journal.append`. The manifest namespace is
`plugin.<producer_id>`, and the append permission is
`journal.append.<namespace>`. Core validates the manifest and event schema but
does not know the plugin's agent catalog or screen grammar. The Rust SDK names
these types generically. `Session::journal_producers` reads the installed
manifests for diagnostics. Bindings that exposed the preview `AgentPlugin*`
names retain source-compatible aliases.
There are deliberately no `agent_plugin.*` transport operation names. The
commands are local CLI plans, and the selected process uses the generic journal
operations after the server socket is bound.

| Class | Operations |
| --- | --- |
| read | `agent.list`, `agent.message.list`, `browser.devices.list`, `browser.get`, `browser.list`, `browser.profile.list`, `chief.engine.get`, `chief.profile.avatar.get`, `chief.profile.get`, `chief.profile.history`, `chief.profile.list`, `client.get`, `client.list`, `closed.list`, `conversation.get`, `conversation.history`, `conversation.list`, `conversation.search`, `credential.mint`, `credential.verify`, `frontend_projection.get`, `git.branches`, `git.checkpoint.diff`, `git.checkpoint.get`, `git.checkpoint.list`, `git.diff`, `git.files.list`, `git.files.search`, `git.status`, `history.entries.list`, `history.visit.summaries`, `keybindings.get`, `machine.get`, `machine.list`, `notification.list`, `pairing_request.list`, `palette_usage.get`, `pane.get`, `pane.list`, `pane.neighbor.get`, `participant.avatar.get`, `project.list`, `room.list`, `saved_tab_group.list`, `screen.get`, `screen.layout.export`, `screen.list`, `screen_group.get`, `screen_group.list`, `session.creation.resolve`, `session.get`, `session.journal.checkpoint.list`, `session.journal.hook.list`, `session.journal.producer.list`, `session.journal.restore.preview`, `session.journal.segment.list`, `session.list`, `session.ping`, `session.snapshot`, `settings.get`, `settings.list`, `settings.schema`, `settings.snapshot`, `sidebar.get`, `sidebar_layout.get`, `sidebar_view.get`, `stash.list`, `tab.get`, `tab.list`, `tab_group.get`, `tab_group.list`, `terminal.copy`, `terminal.get`, `terminal.history.read`, `terminal.list`, `terminal.output_read`, `terminal.process.get`, `terminal.screen.read`, `terminal.state.read`, `terminal.wait`, `terminal.wait_exit`, `window_record.list`, `workspace.agent_start.get`, `workspace.get`, `workspace.list`, `workspace.placement.list`, `workspace_checklist.list`, `workspace_group.list`, `workspace_log.list`, `workspace_status.list` |
| mutation | `agent.message.mark`, `agent.message.release`, `agent.message.send`, `agent.message.unsend`, `agent.report`, `browser.activate`, `browser.back`, `browser.close`, `browser.devices.add_custom`, `browser.devices.remove_custom`, `browser.forward`, `browser.input.key`, `browser.input.mouse`, `browser.input.text`, `browser.input.wheel`, `browser.navigate`, `browser.profile.create`, `browser.profile.open`, `browser.reload`, `browser.tab.emulate`, `browser.tab.emulate.clear`, `browser.tab.set_profile`, `chief.continue`, `chief.engine.set`, `chief.profile.adopt`, `chief.profile.avatar.set`, `chief.profile.create`, `chief.profile.delete`, `chief.profile.undo`, `chief.profile.update`, `chief.retry`, `chief.stop`, `closed.delete`, `closed.reopen`, `column.update`, `conversation.draft`, `conversation.send`, `conversation.typing`, `credential.rotate`, `frontend_projection.put`, `git.checkpoint.create`, `git.checkpoint.pin`, `git.checkpoint.unpin`, `git.commit`, `git.push`, `git.worktree.apply`, `git.worktree.create`, `git.worktree.remove`, `history.backups.purge`, `history.clear`, `history.entries.remove`, `history.restore`, `history.site.remove`, `history.trail.record`, `history.visit.import`, `history.visit.record`, `history.visit.remove`, `history.visit.title`, `keybindings.remove`, `keybindings.reset`, `keybindings.set`, `layout.bulk`, `notification.ack`, `notification.clear`, `notification.create`, `pairing_request.resolve`, `palette_usage.forget`, `palette_usage.hide`, `palette_usage.import`, `palette_usage.record`, `pane.close`, `pane.create`, `pane.focus`, `pane.focus_direction`, `pane.rename`, `pane.run`, `pane.split`, `pane.split_ratio.set`, `pane.swap`, `pane.viewport_width.set`, `pane.zoom`, `participant.avatar.set`, `project.add`, `project.observe`, `project.remove`, `project.source.update`, `project.sync`, `project.update`, `room.create`, `room.delete`, `room.follow`, `room.move`, `room.pin`, `room.unpin`, `room.update`, `saved_tab_group.delete`, `saved_tab_group.reopen`, `saved_tab_group.save`, `screen.close`, `screen.create`, `screen.focus`, `screen.layout.undo`, `screen.move`, `screen.rename`, `screen.update`, `screen_group.add_screens`, `screen_group.create`, `screen_group.remove_screens`, `screen_group.ungroup`, `screen_group.update`, `session.journal.append`, `session.journal.checkpoint.create`, `session.journal.hook.put`, `session.journal.producer.put`, `session.journal.segment.seal`, `session.open`, `session.reload_config`, `session.shutdown`, `session.terminal_defaults.update`, `session.window.title.clear`, `session.window.title.set`, `settings.reset`, `settings.reset_all`, `settings.set`, `sidebar.adopt`, `sidebar.apply`, `sidebar.group.create`, `sidebar.group.ungroup`, `sidebar.group.update`, `sidebar.item.add`, `sidebar.item.remove`, `sidebar.item.remove_ref`, `sidebar.item.update`, `sidebar.move`, `sidebar.pin`, `sidebar.reset`, `sidebar.section.add`, `sidebar.section.move`, `sidebar.section.remove`, `sidebar.section.update`, `sidebar.unpin`, `sidebar_layout.update`, `sidebar_view.ensure`, `sidebar_view.input`, `sidebar_view.reload`, `sidebar_view.resize`, `stash.create`, `stash.delete`, `stash.import`, `stash.restore`, `tab.close`, `tab.create_browser`, `tab.create_terminal`, `tab.focus`, `tab.move`, `tab.pin`, `tab.rename`, `tab.unpin`, `tab.update`, `tab_group.add_tabs`, `tab_group.close`, `tab_group.create`, `tab_group.move`, `tab_group.remove_tabs`, `tab_group.ungroup`, `tab_group.update`, `terminal.close`, `terminal.history.clear`, `terminal.input.focus`, `terminal.input.keys`, `terminal.input.mouse`, `terminal.input.write`, `terminal.move`, `terminal.project`, `terminal.viewport.scroll`, `window_record.delete`, `window_record.put`, `workspace.agent_folder.set`, `workspace.close`, `workspace.create`, `workspace.ensure_app`, `workspace.ensure_home`, `workspace.focus`, `workspace.layout.apply`, `workspace.move`, `workspace.open_url`, `workspace.place`, `workspace.rename`, `workspace.run`, `workspace.update`, `workspace_checklist.add`, `workspace_checklist.remove`, `workspace_checklist.update`, `workspace_group.create`, `workspace_group.delete`, `workspace_group.move`, `workspace_group.update`, `workspace_log.append`, `workspace_log.clear`, `workspace_progress.clear`, `workspace_progress.set`, `workspace_status.clear`, `workspace_status.set` |
| stream_open | `browser.attach`, `conversation.events`, `session.events`, `session.journal.subscribe`, `sidebar_view.attach`, `terminal.attach` |
| connection_control | `browser.viewer.release`, `browser.viewer.resize`, `client.cell_pixels.set`, `client.detach`, `client.metadata.update`, `client.sizing.release`, `client.sizing.set`, `origin.confirmation.issue`, `request.cancel`, `stream.cancel`, `terminal.renderer_grant.create`, `terminal.viewer.release`, `terminal.viewer.resize` |
| local | `sidebar_plugin.install`, `sidebar_plugin.list`, `sidebar_plugin.remove`, `sidebar_plugin.update`, `sidebar_plugin.use`, `sidebar_plugin.use_builtin` |

A selector is a flat object of scope strings. A nested target includes every
ancestor scope alongside its target scope. Names are exact labels and are not
unique. Workspace names are required strings. Screen, pane, tab, and client
snapshots always carry `name`, using null for unnamed. Their rename parameter
uses null to clear and a string, including empty, whitespace, or Unicode, to
set that exact value. Create operations keep an optional non-null string.
Client metadata updates use omission for no change and null to clear. A
non-null `name` or `kind` preserves its exact value, including empty,
whitespace, and Unicode, and contains at most 64 Unicode scalars with no
Unicode `Cc` control scalar. Validation runs before mutation, so rejection
leaves both fields unchanged.

`Cursor` contains a generation string and decimal-string revision.
`MutationResult<T>` is the flat
`{value,generation,revision,replayed}` result. Every committed mutation
returns generation and revision; `replayed` reports an idempotency replay.
The request already owns its idempotency key, so results do not echo it.

External effects use a durable three-state intent record. The server persists
the intent, marks it executing before invoking the effect, then records the
outcome. After restart, a persisted pre-execution intent may resume. An
executing intent without a recorded outcome returns the same non-retryable
`mutation.indeterminate` error for every request with that key and is never
repeated automatically. Its details contain `idempotency_key`, `operation`,
and `recovery: inspect_state_then_retry_with_new_key`. The caller inspects
resource state, then uses a new key only when repeating the effect is
appropriate.

The eight operations that return a `CreatedPath` accept a 1 through 128 byte
`correlation_key`: `workspace.create`, `workspace.run`, `screen.create`,
`pane.create`, `pane.split`, `pane.run`, `tab.create_terminal`, and
`tab.create_browser`. Omission defaults the correlation key to the request
idempotency key. A durable intent binds the key to the operation plus a
canonical semantic fingerprint before any external effect. The fingerprint
excludes `expected_revision`, `correlation_key`, and idempotency metadata.
Reusing the key for different semantics returns non-retryable
`creation.conflict`.

Every mutation, including `workspace.create`, accepts `expected_revision`
against the session resource cursor. A prepared creation re-checks that guard
before executing; a committed replay returns its original result regardless
of a now-stale guard.

`session.creation.resolve` reports `pending`, `created`, `not_applied`, or
`indeterminate` with one exact recovery action. A created resolution includes
the committed path, generation, and revision. Callers retry only when the
reported recovery is `retry_same_idempotency_key` or
`retry_new_idempotency_key`.

`CreatedPath` has explicit workspace-only, terminal-path, and browser-path
variants. Snapshots use only opaque resource IDs, exact names, positions, and
revision metadata. They never expose private workspace identity data, mux
positions as identity, alternate ID forms, or internal storage nouns.

`terminal.wait` remains the regex screen-content wait.
`terminal.wait_exit` waits for process completion and returns either pending
state or an exited outcome. Outcomes are strict exit-code, signal with
`core_dumped`, or unknown-reason variants. The terminal snapshot retains the
same exit record while the durable terminal is exited; `terminal.close`
tombstones it. Its required lifecycle is `launching`, `running`, or `exited`;
the legacy `running` convenience is true exactly for `running`, and `exit` is
present exactly for `exited`.
Public results expose the stable terminal ID and never expose the private
terminal-host generation token.

Client snapshots carry required nullable `name` and `client_kind`, transport,
self status, attached terminal IDs, and one size/participation record per
terminal. All `uint64` runtime values use decimal strings. Notification and
agent timestamps are decimal millisecond values. Pairing requests carry peer,
sensitive code, and remaining seconds; SDK string rendering and logs redact
the code.

Layout documents round-trip leaf, split, stack, and horizontal viewport
structures. Viewport columns retain stable IDs and widths. The document also
retains active and zoomed pane IDs. Nested same-direction splits are not
flattened. A rightward `pane.split` may include `viewport_width` from 0.1
through 1.0 to create the terminal as a separate scrolling viewport column;
ordinary splits omit it. `pane.split` keeps the caller's focus unless it sends
`focus: true`, like `tab.create_terminal`; only the user's own splits (raw
`split` from the app or TUI) focus the new pane. `pane.split` may send at most
one of `argv` or `shell` (same rules as `pane.run`) so the new pane runs that
command instead of a shell. `screen.create` returns the complete created
terminal path.

`workspace.create` requires `initial_content: terminal|empty`.
`workspace.run` and `pane.run` accept exactly one of a nonempty `argv`
array or a `shell` script. Only `argv[0]` must be nonempty; later values,
including empty strings, preserve exact bytes. The server runs `shell` with
its platform default shell and `-lc`; SDKs never inspect or expand `$SHELL`.
To choose a specific executable, callers send
`argv: [executable, "-lc", script]`.

By default, `machine.list/get` preserve the original local-only machine shape,
without top-level platform or capability fields. `identify` advertises
`machine-catalog-read-v1` when the endpoint accepts the optional boolean
`catalog` parameter on these two operations. Only `catalog:true` opts this
request into the extended shape. Omitted or false stays legacy-compatible,
including after a prior opt-in on the same connection. `session.snapshot` always
embeds the original machine shape. Unsupported endpoints may reject the new
parameter; callers can check the advertised capability before opting in.

With `catalog:true`, `machine.list` returns the authoritative local machine first,
followed by remote metadata published by its verified local app. The local origin is
`local`; projected origins are `cloud`, `ssh`, or `server`. `machine.get` resolves
the local machine or one unambiguous published record. Use canonical machine IDs
to distinguish owners; a display name is not an identity. Without a live, admitted
publisher, discovery still returns only the local owner. An unopted `machine.get`
cannot resolve a projected remote record. See
[machine catalog publication](commands.md#machine-catalog-publication) for the
negotiation, owner fence, bounds and connection-owned lease.

Machine snapshots may include `platform: {os?, arch?}` and machine-level
`capabilities`. These are non-secret observations from the selected owner, separate
from protocol feature negotiation. Omitted legacy metadata remains unknown.
Capability tokens and `connectable` describe the existing route; they are not
credentials, enrollment, or permission to execute. Reading the catalog never
opens a target connection. A remote record disappears when its publication is
withdrawn or its publishing connection closes.

Catalog projection does not extend session routing: `session.list`, `session.get`,
and `session.open` operate only on the mux session owned by this endpoint. A
projected remote ID cannot select a local session or supply a remote carrier.
Callers need that owner's separately authenticated transport for session work.

`machine.list` accepts no ancestor selectors. `machine.get` accepts its machine
selector, and `session.list` accepts only its machine ancestor. Clients must not
add a session default to these reads; explicit unsupported fields remain native
validation errors.

Sidebar plugin installation and selection are local filesystem operations.
Transported sidebar view operations never send a `sidebar_plugin_` ID.
Optional install names are filesystem slugs matching `[a-z0-9-_]+`.
Agent plugin installation and selection are also local filesystem operations.
They write `agents.plugin` and never send an `agent_plugin_` ID as a resource
selector. The selected background process uses the journal operations above
after the server socket is bound.

`screen.layout.undo` accepts `confirm_close`, default false, and an optional
opaque `confirmation_token` of 1 through 128 UTF-8 bytes. If the undo would
close created panes, false returns `confirmation.required` with the token,
global revision, and pane IDs without changing revision, layout, topology,
journal, or idempotency state. A confirmed retry uses that exact token,
revision, and a new mutation key.

The token is deterministic over the session generation, screen public ID,
layout revision, created pane IDs, and every closing pane's live tab IDs in
displayed order. Under the mutation lock, the server re-evaluates the undo and
accepts only an exact token for the locked state. A missing or stale token
returns a fresh read-only preview and closes nothing. The token is a
stale-state fence, not authentication.

Fields marked `sensitive: true` must be redacted from SDK Debug, `toString`,
exceptions, and logs. Pairing codes and renderer grant tokens are sensitive.
Renderer grants expose endpoint, terminal ID, token, rights, and TTL. They are
connection-bound, one-use capabilities.

`JsonValue` is limited to audited extension points: explicit snapshot `extra`
maps, frontend projection payloads, structured error details, operation
failure extras, and conversation message parts and reactions (the
conversation reducer validates them, and newer part kinds must survive a
round trip). Core resource, stream, layout, render, and session
change shapes never use generic JSON.

Input modifiers are `shift|control|alt|meta`; terminal transport maps public
`meta` to its raw `super` bit. Browser coordinates and wheel deltas must be
finite. Browser down/up require a typed button and move omits it. Terminal
mouse down/up, move, and wheel enforce their distinct button/delta fields.

## Conversations

The `conversation.*` operations expose the session's local conversation
owner (commands.md `conversation-list` and the other `conversation-*`
commands: Home, the Chief and paired devices) on this protocol. They are the
same owner and the same rules, with nothing added on the v2 path:

- Trusted local (Unix) connections, and with `ws-conversations-v1`
  authenticated WebSocket connections (static credential or approved
  pairing), whose principal is always `user_local` (a WebSocket connection
  cannot bind an agent). The caller's principal is the
  connection's conversation principal: `user_local`, or the agent
  participant the connection bound with `conversation-bind`. As on the raw
  commands, every unbound local connection is `user_local`: a process of
  the user's account can read and write the person's conversations; only
  MCP clients are kept off them (cli.md). A connection whose agent token
  the person replaced is no principal (not `user_local`) until it binds
  again. Every read names
  only conversations the principal takes part in: `list` filters, `get`,
  `history` and `events` refuse with `operation.failed` reason
  `not_participant`, and `search` searches only those conversations.
- Conversation and message ids are the owner's (`conv_` or `msg_` and 26
  Crockford base-32 characters), carried as bounded strings, not as public
  resource ids; `resource.not_found` names scope `conversation`.
- `send` writes one message as the principal. The envelope idempotency key is
  the message's `client_msg_id` (1 to 128 printable ASCII characters), so the
  owner's own ledger replays a retry; another request under the same key is
  `idempotency.conflict`. Its `MutationResult` carries the conversation id as
  `generation` and the conversation rev as `revision`.
- `typing` and `draft` publish ephemeral items for the caller itself; the
  conversation rev does not change. Only an agent participant publishes a
  draft (`not_agent` otherwise), at most 10 per second per turn (burst 10,
  `rate_limited`), a delta of at most 16 KiB and a whole segment of at most
  64 KiB (`text_too_large`); a seq at or below the turn's last published seq
  is a replay. Drafts appear only on `conversation.events`, never on the raw
  `subscribe` stream.
- `events` streams one conversation: a `snapshot` item (summary, the last
  `tail` messages and who is typing) unless the cursor is at the head, then `message`,
  `message_updated`, `read_cursor` and `conversation` items in commit order,
  each with the rev it produced, and live `typing` and `draft` items. The
  cursor is `{generation: conversation id, revision: rev}`. A cursor of
  another conversation or ahead of the head is `cursor.invalid`; an older one
  starts with a `snapshot` whose `reset_reason` is `cursor_expired`. A stream
  that misses a rev (its queue overflowed) ends with reason `gap` and the last
  delivered cursor. A stream also ends (reason `closed`) when its
  connection's principal changes or a `conversation` item no longer lists
  it. `conversation-import` raises rev once and sends one `conversation`
  item; its messages are read with `history`.

A client tells when the Chief has answered a message with seq `S` from the
items alone, the rule `cmux chief` uses and every client shares: the brain
moves its read cursor (`read_cursor` of `agent_mux`) to at least `S` when the
turn that answers `S` starts, then types (`typing` on), posts its replies
(`message` items of `agent_mux` with seq above `S`), and stops typing at the
turn's end. So that turn's `typing` off, after a `read_cursor` of at least
`S` and a `typing` on, ends it. A turn already running when `S` arrived stops
for it before the cursor moves, and does not count. A `draft` of turn `T` is
dropped when the posted message with `client_msg_id` `T` of the same author
arrives, on `done`, or on `typing` off. A client whose stream ended with
`gap` reopens it and takes the turn's state from the snapshot: the
Chief's read cursor, its replies after `S`, and whether it is still in
`typing` (`get` carries the same list); typing is memory only, and an agent
whose last bound connection ends stops typing (a `typing` off item).

Remote relay analysis. A paired device reaches conversations only through
the remote relay, whose frame gate refuses every `cmux.protocol/2` frame
before dispatch (`remote_relay/gate.rs`, `Denial::ResourceProtocol`), so no
`conversation.*` operation is reachable from a device and the relay
allowlist is unchanged; devices keep the existing `conversation-*` commands.
Local command or content execution: the operations run no command and
spawn nothing; a sent message is text the owner validates, the same as
Home's. Access to unowned objects: every operation is scoped to the
principal's own conversations as above, and a page origin is refused every
`conversation.*` operation. Local-state exposure: the items carry only what
the principal's own conversations already show it; drafts are the agent's
reply text for that conversation. The policy tests are in
`server/conversation_resource_tests.rs`.

## Chief control

`chief.engine.get`, `chief.engine.set` and `chief.stop` are the owner's
control of the Chief brain that runs with this session (risk: owner). The
daemon forwards one line to the brain host's tools socket
(`CMUX_TUI_CHIEF_TOOLS_SOCKET`, as `chief-inspect` does) and answers the
brain's JSON: the engine report (passed through unchanged) or `{stopped,
subagents?, note?}`. `chief.engine.set` also takes `speed` and
`compactor_speed` (`default` or `fast`, the codex priority tier; a Claude
harness refuses `fast` with `invalid_speed`), and `compactor_harness` and
`compactor_model` (by default the compactor runs Claude Haiku on the turns'
engine harness when it is a Claude one); the compactor fields apply at the
next brain start. `chief.stop` takes an optional
subagent `name` and then stops only that subagent.
With capability `chief-brains-v1` all three take an optional `chief`, the
Chief's id: for a live Chief other than the default, the daemon forwards to
that Chief's own brain (its tools socket in the brain directory the daemon's
brain supervisor gave it) and to no other Chief; absent, `null` or
`agent_mux` reaches the default Chief's brain as before. A Chief that does not
exist answers `operation.failed` reason `not_found`; a daemon that runs no
Chief brains, `not_configured`. A Chief whose brain does not run now (never
started here, stopped after 30 minutes idle, or between restarts):
`chief.engine.set` starts it as a message to that Chief would (a brain in
restart backoff starts only at its retry time), waits up to 15 s for its tools
socket and then forwards (`unavailable` at once when no brain process starts,
and when the socket does not answer in time); `chief.engine.get` and `chief.stop` never start a brain and
answer `unavailable`. With agents
off in the build session, the same agents-disabled refusal as the default
Chief. The daemon advertises `chief-brains-v1` only when it runs Chief brains.
Only the owner's trusted connection may call them: a registered Unix client
with no link peer record whose principal is `user_local`, which is a local
client or the link's `owner_session` splice. An agent-bound connection (the
Chief's own turns and subagents), a relayed, WebSocket or page connection is
refused with `origin.forbidden` before anything is forwarded, so no agent
changes the Chief's engine or stops its turn; there is no approval path for
agents yet. A daemon without the tools socket answers `operation.failed`
reason `not_configured`; a brain refusal keeps the brain's code as
`details.reason` and its text as `extra.message`. An app reaches a brain on
a paired server through its link to that server's daemon. They are not MCP
tools.

## Chief registry

`chief.profile.list`, `chief.profile.get`, `chief.profile.create`, `chief.profile.update`, `chief.profile.delete`,
`chief.profile.avatar.set` and `chief.profile.avatar.get` keep every Chief of this session's
Chief home: its name, role, personality, instructions (system prompt
additions, appended after the base rules, never instead of them), avatar,
the tools and harnesses the person granted, its engine, and `self_edit`, the
fields the Chief may change about itself without asking (default `avatar`).
The daemon owns the records in `chiefs.sqlite3` in the session state
directory. A Chief's id is its conversation participant id: the default
Chief is `agent_mux` and exists from the first read; a new Chief is `agent_`
and 26 Crockford base32 characters. A deleted id is never reused.
`chief.profile.list` answers `{chiefs, deleted}`: the live records and the ids
of deleted Chiefs, so a client hides their conversations. Deleting a Chief
stops its brain, ends its sessions and then removes its brain home
(`<home>/c/<id tail>`, its memory and state) when its `chief-id` names that Chief
and no brain holds its lock (a folder still locked stays); the default Chief is
never deleted.

With `chief-profile-history-v1` every committed state of a record is kept as a
revision (the newest 100 per Chief, dropped with a deleted Chief):
`chief.profile.history {chief, limit?}` lists them newest first with the actor
and operation that made each, and `chief.profile.undo {chief, to_rev?}` makes
the record equal to one of them again (default: the one before the current
rev) as a new rev, checked as `chief.profile.update` with the fields that
differ; `no_revision` when there is none. A record carries `locked`, the
person's switch: while true every Chief's write on it is `chief_locked`, and
only the owner sets it. `self_edit` takes `engine` (the Chief's own `harness`,
`model` and `effort`, the harness among its `harnesses`); the default Chief
and a new Chief get every item. A Chief with the `chiefs` tool changes every
profile field of another Chief within its own grant (the engine harness one it
may use). A committed change of a record's engine is written into that Chief's
brain engine file (`optchat/engine.json` in its brain home), which its next
turn reads.

`chief.profile.adopt` (capability `chief-profile-adopt-v1`) makes an existing
agent participant of the owner's conversations a Chief record under its own
id, so its conversations, history and credentials stay its own. Only the
owner calls it, from a trusted local Unix connection: a page (WebSocket or
the host's page relay), a paired or remote device and a bound agent get
`origin.forbidden`, and no page route lists it. The record gets
`chief.profile.create`'s defaults and only the fields given; from the
participant it takes its id and, without `display_name`, its display name.
`agent_mux` is `default_chief`, a live record `already_chief`, a deleted
Chief `deleted_chief` (an adopt never revives a deleted Chief or its kept
memory), an id whose brain directory (its last 8 characters, lowercased)
another live or deleted Chief already has `brain_home_taken`, and a person
or an unknown id `not_an_agent_participant`. A participant with a bound
connection is `participant_bound` ("stop its current agent session first"):
two processes never speak as one participant. In the same write every
credential issued for the participant is revoked; afterwards only the
supervisor-started brain's credential binds, or, on a daemon with no brain
supervisor, one the person mints with `conversation-agent-token` from a local
terminal (never a page, a paired or remote device or an agent)
(`operation.failed` `details.reason`). It is idempotent per key like
`chief.profile.create`, reaches the brain supervisor as a create does and
publishes `chief-changed` with change `created`.

The callers are the owner (the rule of Chief control above) and the Chiefs: a
Unix connection bound with `conversation-bind` to a live record's id. With
`chief-profile-ws-v1` the person's page is a caller too: an authenticated
WebSocket acting as `user_local` that is no remote client and no bound agent,
and is either page `home-channels` admitted with a credential bound to that
page (`page-credential {page}`: the app's Channels page on its Chief owner) or
a connection with no page Origin that presented the daemon's own credential.
A pairing-store credential (an approved pairing, and the app's person page
credential, which shares the store) is refused with or without a page Origin:
a native client can send any Origin. Without a host gesture the page can change only display_name, role and the
avatar. Create, and edits of instructions or personality, need the gesture,
like delete and the grant fields (tools, harnesses, engine/harness/model/effort,
self_edit): `origin.forbidden` reason `gesture_required` on the WebSocket,
which never carries a confirmation; the host's page relay of page
`home-channels` brings it (page-router.md). Only the host's confirmation on its page relay carries the
gesture; no request field or claim the page makes up stands in for it. The
operation ledger records a page's write as `user_local via page:<page>` (`user_local
via websocket` with no page id), so a page write is told apart from a terminal's.
Every other connection is refused with `origin.forbidden`. A Chief reads every
record and changes only its own fields that its `self_edit` lists; its own
tools, harnesses, engine and `self_edit` are the owner's only. Any other
change of itself is `operation.failed` reason `chief_self_edit_denied` with
`extra.fields`, before anything is written.

A Chief whose `tools` hold `chiefs` (on by default for a new Chief; a record
made before that default whose tools were still the old default set gets it
once, recorded in the ledger as `daemon via migration`) may also create
Chiefs and change other Chiefs' profile, grant and picture, never beyond its
own grant: the new or changed record's `tools` and `self_edit` are subsets of
the Chief's, its `harnesses` are any when the Chief's are empty (every
harness) and otherwise a non-empty subset, and each engine field the Chief has
set (harness, model, effort) is the same. An edit also needs the target's
current grant within the Chief's (`target_exceeds_caller`). On a Chief the person made
(every record no Chief created) a Chief changes only display_name, role and the
picture (`chief_person_made_fields`); the daemon records which Chief created a
Chief from the verified caller, never from a request. A create fills the
grant fields it omits from the Chief's own grant. Refusals, before anything is
written: `chief_manage_denied` (no `chiefs`), `grant_exceeds_caller` (with
`extra.fields`), `target_exceeds_caller`, `chief_default_grant` (a grant field
of the default Chief), `chief_delete_denied` (no Chief deletes a Chief) and `too_many_chiefs`. The ledger records such a write as `<agent id> via chief`. The answer of `chief.profile.create` and `chief.profile.adopt` (not a replay)
carries the new record's `brain`: `{state: "started"}` or `{state: "not_started",
reason}`, from the daemon's brain supervisor (`no_supervisor`: this daemon runs
no Chief brains; `launch_disabled`: agents are off in this build session;
`error`, see the daemon log; `unconfirmed`, the
supervisor did not answer in time).
An avatar is PNG, JPEG, GIF or WebP, at most 1 MiB, stored once by SHA-256.
The policy tests are in `crates/cmux-tui/tests/cli/chief_registry.rs`.

## Participant avatars

`participant.avatar.set {participant_id, bytes | clear}` and
`participant.avatar.get {participant_id}` (capability `participant-avatars-v1`)
keep one picture per conversation participant, a person or a Chief, in the
daemon's one avatar store (`chiefs.sqlite3`): bytes kept once by SHA-256 and
deleted when no participant references them. The media type comes from the
bytes (PNG, JPEG, GIF or WebP, at most 1 MiB), never from the caller. A person
sets only their own picture (the connection's principal is that person:
`user_local`, or a person bound with a person credential); nobody sets another
person's (`operation.failed` reason `avatar_not_yours`). A Chief's picture is
the `chief.profile.avatar.set` write with its callers and `self_edit` rule;
`chief.profile.avatar.set` and `chief.profile.avatar.get` stay as aliases with
their results unchanged. The person's own clients read any picture (the
Channels page through its page allow list). A committed change publishes
`participant-avatar-changed {participant, avatar}` on `subscribe` to the
connections that echoed `participant-avatars-v1` in `set-client-info`. The CLI
is `cmux avatar set|get`; it refuses an agent caller. The policy tests are in
`crates/cmux-tui/tests/cli/participant_avatars.rs`.

## Launch credentials

`credential.verify {credential}` answers `{valid, actor?, reason?}` and never
fails for a bad credential. `credential.mint {acp_session, agent?}` returns a
credential for one acpmux ACP session, and `credential.rotate` makes a new
current launch key, keeps one previous key, and drops the oldest. Mint and
rotate are the owner's: a request that carries any credential, or comes from
an agent-bound, relayed, WebSocket or page connection, gets
`origin.forbidden`. A retry of the last rotation's idempotency key answers its
key id with `replayed: true`. None of them is an MCP tool or a CLI verb.
Every terminal the daemon starts gets its own credential in
`CMUX_LAUNCH_CREDENTIAL`; acpmux, its agents and hooks never inherit one.

## CLI

The executable starts or attaches when no resource scope is supplied. Control
commands are noun-first:

```text
cmux workspace list
cmux workspace create --name api
cmux workspace api show
cmux workspace ws_… run -- cargo test
cmux workspace ws_… screen current pane current split --right
cmux terminal term_… screen read
cmux terminal term_… keys ctrl-c
cmux sidebar plugin list
cmux agent plugin list
```

Root control scopes are `machine`, `session`, `client`, `workspace`, `screen`,
`pane`, `tab`, `terminal`, `browser`, `notification`, `agent`, `sidebar`,
`pairing`, `projection`, `provider`, and `raw`. Sidebar resources
use the nested `sidebar view` and `sidebar plugin` grammars.
Hyphenated action-first commands are usage errors with exit code 2.

Global routing flags are `--machine`, `--session`, and advanced `--socket`.
`--session` and `--socket` select the endpoint. Session-scoped operations remain
owned by that endpoint's native machine and session; selecting a remote metadata
record does not reroute execution. For `machine.list/get`, an endpoint-selection
flag is not serialized as an unsupported session ancestor.

Human output follows the selected locale, currently English and Japanese.
`--json` prints one result object. `--jsonl` prints one object per result or
event. `--quiet` suppresses success output. Results use stdout. Diagnostics
use stderr. Exit codes are 0 success, 1 operation failure, 2 usage, and 3
transport.

Local filesystem actions are `sidebar plugin install|update|remove|use`,
`agent plugin install|list|update|remove|use`, and configuration discovery.
Their results use the same output modes but they do not cross the session
protocol. Agent plugin actions select the userland background detector and
write `agents.plugin`; they do not add agent implementation to core.

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

Client, Stream, Notification, Agent, PairingRequest, FrontendProjection, and
SidebarView are typed session auxiliary resources. They are not inserted into
the workspace tree. Split IDs appear only in raw layout documents.

## Separate protocols

Terminal-host, machine-agent, and machine-provider transports keep separate
version numbers. The machine-provider protocol remains an internal transport.
A future cross-machine broker must define a later public protocol instead of
extending this endpoint's session execution authority implicitly. The explicit
catalog metadata opt-in does not supply that authority.
