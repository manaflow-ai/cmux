# Durable object links (`cmux://tab/<id>` that always resolve)

Requested 2026-10-20 (user): "We need a type of link where you can link to a tab ... If the tab
gets closed the link will still take us back to the tab and recover it ... every single tab and
every single pane has its own identity, so we can recover it properly." Builds on a343
(plans/cmux-next/persistent-ids-DESIGN.md, open decision D1) and a295 / reopen-closed.md
(closed-history-v2). Coordinates with a327 (Home links open right).

## 1. What exists (feat-cmux-next 051f9cb2485)

- `DeepLink` (CmuxNextActions) parses `cmux://workspace/ws_…`, `pane/pane_…`, `tab/tab_…`,
  `session/<id>[#turn-…]`, `chief/<home>/session/<id>`. Copy Link writes them. `link.open`
  (`LinkHandlers`, `DeepLinkNavigator`) is the one path every link takes: OS URL handler,
  Home/agent-chat clicks (`CmuxAppLinks`), palette, `cmux link open`, MCP.
- `DeepLinkNavigator` only REVEALS a live object. A closed tab throws `linkTargetGone`.
- The daemon keeps every close in `closed_groups` (SQLite, forever). Each member records the
  closed tab's `tab_id`, kind, url/cwd/conversation, pane, index.
- `closed.reopen` rebuilds a tab through the create paths, so it gets a NEW `tab_` id
  (`Reopened::reopened_as`). That breaks any link to the old id (a343 D1).

## 2. Rules

1. A link names an object by its durable resource id only: `cmux://tab/tab_<32 hex>` (also
   `pane/`, `workspace/`). Never a numeric handle, never a title.
2. `link.open` resolves in this order, through one shared path:
   1. Live: reveal and focus it (unchanged).
   2. Closed: reopen it from closed history BY ITS ID (`closed.reopen {tab}`), with the SAME id,
      in its old place (its pane at its index; else its workspace's focused pane), else where the
      link was clicked from would open a new item (Home: the pane right of Home, `LinkOpener`).
   3. Neither: refuse with "This tab was closed and is no longer in Recently Closed" (existing
      `linkTargetGone`). Never open something else in its place.
3. Reopen keeps the id (a343 D1, tabs slice): the daemon passes the closed record's `tab_id` to
   the create path, and the registry brings the tombstoned `resource_tabs` row back to life for
   that id only. Rule 4 of persistent-ids holds: a retired id comes back only for the same object,
   only from its own closed record, never for a caller-supplied id.
4. Clicking a link twice never makes two tabs: the second click finds it live.
5. Restart: the closed record and the tab rows are in SQLite, so a link to an open tab works after
   an app or daemon restart (a343 guard), and a link to a closed tab still reopens it.

## 3. Daemon API

`closed.reopen` gains two optional fields (spec/resource-operations-v2.json):

| Field | Meaning |
|---|---|
| `tab` | A `tab_` id. Reopen the member of the newest closed group that holds this tab: a tab member alone, or the screen/workspace member that contains it (the whole container comes back, so its layout does). `closed` and `members` must be absent. `resource.not_found` when no group holds it (the tab is live, or its record was deleted). |
| `fallback_pane` | A `pane_` id. Where a reopened tab goes when its own pane and workspace are gone, instead of the session's focused pane. The app passes the pane a link from Home would open into. |

Same tab id: `mux/requested_tab_id.rs` scopes the closed tab's id around one `reopen_tab_record`.
The tab mint sites (`spawn_options::terminal_identity`, the running-terminal reattach in
`resource_content`, the browser reservation in `effect_execution`) take the requested id instead
of a random one. `upsert_resource_tab` finds the tombstoned row of that id and, only inside that
scope, clears its tombstone and takes the new content (a reopened terminal has a new `term_`
content incarnation; a browser a new `browser_`). Outside the scope a tombstoned id is refused as
before. A live row of that id is never touched by the scope (it is "used" after the first
resurrect, so a second create in the same scope mints a random id).

Not in this slice (a343 owns, same mechanism): panes (`pane_`), screens, workspaces keep their
ids on reopen. Until then a `pane/` link to a closed pane refuses as gone.

`workspace` (cmux#25572): a `ws_` id. A closing workspace's member records its id
(`closed_workspace_id`); `closed.reopen {workspace}` reopens the workspace member of the newest
group that recorded it, as a new workspace (its own id comes back with a343). Excludes `closed`,
`members` and `tab`; `resource.not_found` when no group holds it (open, closed before the id was
recorded, reopened already, or deleted).

## 4. App

`DeepLinkNavigator.open(.tab(id))`: reveal if live; else for each connected daemon (local
first) call `closed.reopen {tab: id, fallback_pane}` and select the returned tab when it is
reported (`PaneController.selectWhenReported`, the Cmd-Shift-T path); `resource.not_found` on
every daemon is the gone refusal. One shared path, so the OS handler, Home, agent chats, the
palette, the CLI and MCP all get it.

`DeepLinkNavigator.open(.workspace(id))`: reveal if live; else `DurableWorkspaceLink` asks each
connected daemon (local first, the same walk) for `closed.reopen {workspace: id}` and reveals the
workspace the reply names once the store lists it (both in `DurableTabLink.swift`).

## 5. Link convention for Chiefs and agents

- Link what you opened, by id: after `tab_create_browser`, `workspace_open_url`, `app_file_open`
  or a spawn, take the `tab_…` id from the result (or `cmux --json tab list`) and write
  `[short name](cmux://tab/tab_…)`. Workspaces: `cmux://workspace/ws_…`; panes:
  `cmux://pane/pane_…`.
- The link is durable: it works when the tab is closed (it reopens with the same id) and after a
  restart. So prefer a tab link over a raw URL for an artifact you showed the user (a preview, a
  report, a diff, a PR page): it brings back that exact tab.
- Files: `[REPORT.md](file:///abs/path)` opens the file beside the chat; once a file is open in a
  tab you showed the user, link the tab.
- The default Chief instructions (optchat-chief `prompt.rs`, "Links") say this.

## 6. Tests (failing first)

Daemon integration (`cmux-tui/tests/terminal_host_recovery/durable_tab_links.rs`):
1. A closed terminal tab reopens by `closed.reopen {tab}` with the same `tab_` id, and the tree
   lists that id.
2. After a daemon restart, a tab closed before it reopens by id with the same id.
3. A live tab's id, or one reopened already: `resource.not_found` (the app reveals it instead).

Swift (`CmuxNextAppTests/DurableLinkPlanTests`): the resolution order of section 2 as a pure
plan (live -> reveal, else reopen by id, else gone).

## 7. Left for later

- Pane, screen and workspace ids kept on reopen (a343 D1, same mechanism). Until then a
  workspace link opens a closed workspace once; after that reopen its old id names nothing.
- Artifacts that are not tabs (a file shown in a Home preview card) get a `cmux://tab/` link only
  once they are opened as a tab.
- Links across machines: `?machine=` is a hint; a closed tab on an offline machine refuses as
  gone until it reconnects.
