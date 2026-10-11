# cmux next: data model (sessions, ownership, spaces, browser profiles, themes)

Living design note for what cmux-tui owns and what the app projects
(architecture.md 1). Revised 2026-09-30 three times: profiles (user), two
kinds of profile (user), and ownership across many cmux-tui sessions (user:
"main use case is a bunch of cmux tuis on other computers that we want to be
able to connect to"; "it's ok if we change up a lot about cmux tui"). Screen
schema agreed with feat-cmux-next-screens (section 9).

## 1. Sessions and ownership

### 1.1 Sessions

Each cmux-tui daemon is a **session**:

- Identity: its durable `registry_id` (a UUID the registry already mints and
  every mutation result already returns; wire alias `session_id`). Stable
  across restarts, upgrades and renames.
- Name: `machine_name` + session name (for example `build-box` / `main`),
  shown as `build-box` when the session name is the default.
- Reach: the local Unix socket, SSH stdio (carrier authentication,
  remote-daemon.md), or a Cloud VM (existing provider path).

The app keeps a **session registry**: every session it knows, with its name,
how to reconnect (transport kind and route, never secrets), last connection
state, cached capabilities, and last seen time. The registry is personal
state (1.2c), stored in the home session. The app is the only federation
point: daemons never connect to each other and never learn about each other.

The **home session** is the user's local daemon on this Mac (today
`cmux-app` / `cmux-dev-<tag>`). There is exactly one per app install.

### 1.2 Three layers of ownership

(a) **Terminals** belong to the session whose machine runs the process. They
never migrate. "Move terminal to machine X" is an explicit re-create (new
process in the same directory on X), never a transfer.

(b) **Layout** of a workspace (screens, columns, splits, panes, tab order,
pinned tabs, tab groups, screen groups) belongs to exactly one session, the
workspace's **home session**. A tab in that tree is a reference:

| Tab kind | Reference | Rendered by |
| --- | --- | --- |
| terminal | a terminal on the same session (existing) | attach on that session |
| remote terminal | `{session_id, terminal_id}` of a terminal on another session | the app attaches on the other session |
| browser | a frontend browser record (existing `frontend_browser_tabs`) | the local app (browsers always run locally) |

Mixed workspaces are allowed (user choice): a split on the Mac can hold a
build-box terminal next to a local one. A tab whose terminal is not on this
Mac shows a very subtle machine badge (user choice).

(c) **Personal state** lives only in the home session and is never written to
a remote daemon: the session registry, spaces and their membership, browser
profiles, windows, sidebar order and workspace groups, saved tab and screen
groups, per-workspace browser profile and theme, shortcuts. Two Macs attached
to the same remote session therefore organize its workspaces independently.

Workspace identity (name, custom title, color, icon) stays shared on the
workspace's home session: it names the workspace on every client, like a tab
title. Organization (order, groups, space, browser profile, theme) is
personal.

### 1.3 Qualified IDs

Every object ID the app, CLI and palette show is qualified by session:
`<session>:<kind>:<id>`, for example `build-box:workspace:3` or
`build-box:tab:tab_9f…`. `<session>` is the session name when unique, else a
`registry_id` prefix. The home session may omit its prefix, so every current
ID keeps working. The CLI gains `--session <name|uuid>` (alias `--machine`),
which scopes unqualified IDs and creation commands. Window and space IDs are
personal and never qualified.

### 1.4 Unavailable references

A tab that references a session this app is not connected to (offline, or
never connected on this Mac) shows a placeholder: the machine name, the last
screen snapshot when one exists, and Connect or "Reconnecting…". The
reference is never dropped. The home session keeps, per remote-terminal tab,
the last title and a bounded text snapshot (64 KiB) so the placeholder
survives relaunch. Workspaces of an offline followed session (3.2) show
greyed with its status.

### 1.5 Moves

Moving a tab or a workspace between windows, spaces or workspaces moves
references, never processes. Moving a tab whose terminal lives on session S
into a workspace whose home is H != S turns it into a remote-terminal tab on
H that references S (and back into a plain terminal tab when it returns to a
workspace homed on S). Changing a workspace's home session re-creates its
layout on the target: every terminal tab becomes a remote reference to its
old session (and every remote reference to the target becomes local), so no
process restarts.

## 2. Protocol changes (cmux-tui)

| Change | Where | Capability |
| --- | --- | --- |
| `identify` adds `session_id` (= `registry_id`) and `machine_name`; the remote attach reply carries both | identify, remote protocol 5 service setup | `session-identity-v1` |
| New tab kind `remote-terminal`: `new-remote-terminal-tab {pane?, session_id, terminal_id, session_name, title?}`, `update-remote-terminal-tab {surface, title?, session_name?, snapshot?}`, tab JSON `{kind:"remote-terminal", remote:{session_id, terminal_id, session_name}, title}`; the daemon stores it like a frontend browser record, never attaches or spawns, keeps it across restarts; `move-tab`, tab groups, pins and closes treat it like any tab | home session | `remote-terminal-tabs-v1` |
| Personal tables (section 3, 5, 6) and their commands, served by every daemon (one binary) but written by the app only on its home session | home session | `profiles-v1` |
| Per-client geometry claims (already built) | all | existing |
| Capability negotiation for older daemons and older apps | all | with the remote compat agent |

A remote daemon needs nothing new beyond `session-identity-v1` to take part:
the app attaches to its terminals by `{generation, terminal_id}`
(`attach-identity-v1`) and reads its shared tree.

### 2.1 Breaking changes

1. **Workspace groups become personal.** Groups and membership move from each
   daemon's shared tree to the home session. A new app ignores `groups` and
   the `group` field on remote daemons and stops calling the group commands on
   them. The TUI and shipped iOS keep reading the old shared groups of a
   daemon, which then go stale for workspaces the Mac regroups.
2. **Sidebar order becomes personal.** The app orders its sidebar from a home
   table and stops calling `move-workspace` on remote daemons for sidebar
   drags (the shared registry order stays as the order other clients see).
3. **Workspace IDs in the app control socket and CLI output become
   qualified** for non-home sessions (`build-box:workspace:3`). Scripts that
   parse IDs of Cloud workspaces see the prefix. Home IDs are unchanged.
4. **`no mixed-machine workspaces in v1` (REWRITE.md) is reversed**:
   remote-terminal tabs appear in home layouts; older apps and the TUI show
   them as an unknown tab kind (the TUI renders a labeled placeholder).
5. The `personal` window projection gains session-qualified workspace keys
   (`WindowRecord.workspace_keys` entries become `{session_id, key}`; old bare
   keys decode as home).

Nothing else breaks: every new field is additive and every old command keeps
its meaning.

### 2.2 Migration

- Home session: on first launch of the new app, current `workspace_groups`
  and `workspace_presentation.group_id` rows of the local daemon become
  personal group rows with the home `session_id` (same group ids; one
  transaction). Registry order seeds the personal sidebar order.
- Remote sessions (Cloud today): on the first connect after the upgrade, the
  app copies that daemon's groups and order into personal rows qualified by
  its `session_id` once (recorded per session in the home registry) and never
  writes groups to it again.
- Window records: bare keys decode as home keys; the next save writes
  qualified keys.
- Spaces start with one `default` space that follows every session (3.2), so
  every existing workspace is visible after the upgrade with no data change.

## 3. Spaces (the switchable set of workspaces)

### 3.1 Two kinds of profile

| | Browser profile | Space (3.4) |
| --- | --- | --- |
| Holds | browser data only: cookies, logins, history, extensions, site permissions | a switchable set of workspaces and groups with its own theme, a default browser profile, a default session for new workspaces |
| Switched | per tab, by where it was opened (section 5) | per window: sidebar dots, swipe, shortcuts |
| Like | Chrome and Arc profiles | Arc Spaces |

Both are personal state in the home session. Internal names: the wire and
Swift call a space a `profile` (`*-profile`, `profiles-v1`, `ProfileID`)
because the work started under that name and wire names must not follow
product naming; a browser profile is `browser_profile` / `BrowserProfile*`.
Strings, action IDs and CLI verbs use the product name.

### 3.2 Membership: follow sessions and pin workspaces (user choice "both")

A space has `follows` (session IDs) and `pins` (qualified workspaces). Rule for
workspace W on session S:

- W is in space R when W is pinned to R, or R follows S and W is pinned to no
  space.
- A workspace is pinned to at most one space. "Move Workspace to Space R" pins it
  to R (exclusive). New workspaces created in the app in space R are pinned to
  R.
- A workspace in no space (its session followed by none, not pinned) shows in
  `default`, so nothing is ever unreachable.
- `default` follows every session unless the user edits it; a new session
  (first connect) is followed by `default` and by the space active when it was
  added.
- New workspaces on a followed session made elsewhere (CLI on build-box,
  another Mac) appear in its followers automatically.

A space has a **default session** for New Workspace (home when unset); every
create action accepts an explicit session ("New Workspace on build-box").

Workspace groups are personal and belong to one space; members are qualified
workspaces of that space. Pinned tabs, tab groups and screens stay in the
workspace layout (1.2b).

### 3.3 Home tables and commands (capability `profiles-v1`)

```sql
CREATE TABLE IF NOT EXISTS profiles (                 -- spaces
  profile_id TEXT PRIMARY KEY NOT NULL,               -- 'default' or 'prof_<32 hex>'
  name TEXT NOT NULL, color TEXT, icon TEXT, theme TEXT,
  position INTEGER NOT NULL CHECK(position >= 0),
  browser_profile_id TEXT,                            -- default browser profile; null = 'default'
  default_session_id TEXT,                            -- null = home
  defaults_json TEXT                                  -- {"cwd","env"} for new terminals
);
CREATE TABLE IF NOT EXISTS profile_follows (profile_id TEXT NOT NULL, session_id TEXT NOT NULL,
  PRIMARY KEY(profile_id, session_id));
CREATE TABLE IF NOT EXISTS profile_pins (session_id TEXT NOT NULL, workspace_key TEXT NOT NULL,
  profile_id TEXT NOT NULL, PRIMARY KEY(session_id, workspace_key));     -- at most one space
CREATE TABLE IF NOT EXISTS sessions (                 -- the session registry
  session_id TEXT PRIMARY KEY NOT NULL, machine_name TEXT, session_name TEXT,
  transport_json TEXT NOT NULL, last_seen_ms INTEGER, capabilities_json TEXT, migrated INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS personal_groups (          -- replaces shared workspace groups
  group_id TEXT PRIMARY KEY NOT NULL, profile_id TEXT NOT NULL, name TEXT NOT NULL,
  color TEXT, collapsed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS personal_workspaces (      -- order, group, browser profile, theme per qualified workspace
  session_id TEXT NOT NULL, workspace_key TEXT NOT NULL, position INTEGER NOT NULL,
  group_id TEXT, browser_profile_id TEXT, theme TEXT, PRIMARY KEY(session_id, workspace_key));
```

Commands (home session; all emit `tree-changed` or a new `personal-changed`
event with no body, refetch `list-personal`):

- `list-personal` returns sessions, spaces (with follows), pins, personal
  groups, personal workspaces and browser profiles in one read.
- Spaces: `create-profile`, `update-profile` (name, color, icon, theme,
  browser_profile_id, default_session_id, defaults; null clears),
  `move-profile`, `delete-profile {profile, move_to?}` (`default` refused;
  pins move to `move_to` or are removed, which returns those workspaces to
  their followers; with `close_workspaces:true` the app closes them on their
  sessions first), `set-profile-follows {profile, session_ids}`,
  `pin-workspace {session_id, workspace_key, profile}` (exclusive; replaces a
  pin), `unpin-workspace {session_id, workspace_key}`.
- Sessions: `put-session {session_id, machine_name, session_name, transport}`,
  `forget-session {session_id}` (refused while a space pins its workspaces
  unless `force`).
- Groups and order: `create-personal-group`, `update-personal-group`,
  `delete-personal-group`, `move-personal-group`, `set-personal-workspace
  {session_id, workspace_key, position?, group?, browser_profile_id?,
  theme?}`.

Terminal defaults (`defaults.cwd` / `defaults.env`) are applied by the app
when it creates a terminal in a space's workspace (it knows the space; a remote
daemon never does). A terminal created without the app (CLI on a machine)
gets none.

### 3.4 Name

**Spaces** (Leo, 2026-10-02): cmux-next centers on one sidebar, and spaces are
the app-wide switching model (dots and a swipe at the sidebar's edge, as in Arc
and Zen). A space is a browser profile default, its workspaces and its browser
state. The working name was Rooms, chosen to avoid macOS Spaces; Leo's
direction settles it. Every verb reads well: New Space, Move Workspace to
Space, Switch Space.

The UI, action ids (`space.*`, `workspace.moveToSpace`, ...), CLI verbs
(`cmux space ...`, `--space`) and docs say space. The old action ids are
aliases (`ActionCatalog.legacyAliases`), and the old CLI names and the `room`
noun still resolve (`ControlCatalog.renamedCLIName`). The daemon calls a space
a profile (`create-profile`). Wire and stored names keep `room`: the action
target kind (`ActionTargetKind.profile = "room"`), the sidebar layout kind
(`LayoutItemRef.roomKind`), app permission selectors (`room`, `room_id`), and
window and section records. Swift type names (`RoomMembership`,
`RoomHandlers`) follow in a later rename.

## 4. Windows

Which space a window shows is personal (`WindowRecord.profile`, absent =
`default`; `profile_workspaces` remembers the last workspace per space). A
window owns qualified workspaces of several spaces (`WindowRegistry`) and
lists those in its current space. Switching window W to space R:

1. W shows the workspaces it owns in R and selects the one it last showed.
2. Else W takes every workspace of R that no open window currently showing R
   owns.
3. Else the app creates a workspace in R on R's default session.

When W loses the last workspace of its space it shows the most recent other
space it owns workspaces in, else the existing rule closes it. Selecting a
workspace of another space (palette, CLI, notification) switches the window.
New workspaces, windows and groups are born in the window's space. A switch
changes only what the window lists and shows, in one main-actor turn;
terminals keep running and hidden surfaces take the hidden-tab path.

## 5. Browser profiles

Records in the home session: `browser_profiles(browser_profile_id: 'default'
| lowercase UUID, name, color, icon, position, source_json)`. `source_json`
records an import origin; the onboarding import creates a record, then fills
the engine store for its id.

Cascade for a new browser tab: explicit choice (New Tab with Browser Profile
X, Open Link in Browser Profile X, `--browser-profile`), else the workspace's
personal browser profile, else its space's, else `default`. No window level: a
window's browser profile is its space's. The resolved id is stored on the tab
at creation (`frontend_browser_tabs.profile_id`) and never changes by
inheritance, so no live page silently changes cookie jar; Move Tab to Browser
Profile reopens its URL in the target.

Display: the omnibar shows the tab's browser profile (dot or icon, name in the
tooltip and Page Info) whenever more than one exists; a tab whose browser
profile differs from its workspace's effective one shows a small profile dot
on the tab and in its hover card.

Engines: `default` -> `BrowserProfileID.default` (existing data stays); a UUID
-> that UUID (`WKWebsiteDataStore(forIdentifier:)`, CEF
`Chromium/Profile-<uuid>`). Deleting one moves its tabs to `default`, then
removes its engine data. A new space shares the current space's browser profile
unless the user picks "new browser profile".

One exception to "the browser profile is the only storage key" (remote
localhost, plans/cmux-next/remote-localhost.md section 3): a tab whose
machine is a remote session and whose main-frame URL is a loopback origin
(`localhost`, `*.localhost`, `127.0.0.0/8`, `[::1]`) uses a derived store,
browser profile x that session's `registry_id` (CEF
`Chromium/Profile-<uuid>-m-<16 hex of sha256(registry_id)>`, whose request
context sends its traffic through the app's proxy). Every other URL of that
tab uses the profile's own store, so logins stay shared across machines; a
navigation across the boundary re-creates the engine tab in the other store.
Deleting a browser profile also removes its derived stores.

Status (stage 4, 2026-09-30): records live in the home session's personal
state when it serves `browser-profiles-v1` (table `browser_profiles`,
`create/update/move/delete-browser-profile`, `browser_profiles` in
`list-personal`; deleting one clears the workspace and space defaults naming
it). The app copies its local records
(`<Application Support>/<bundle id>/BrowserProfiles/profiles.json`,
`BrowserProfileBook`) there once, then uses the daemon's; with an older home
daemon the file stays the store. The file keeps what is this Mac's: engine
data of deleted profiles (`pending_cleanup`, removed at once when no engine
opened the profile in this process, else at the next launch), the import
migration flag, and workspace defaults while `profiles-v1` is missing.
Space defaults need `profiles-v1`. A deleted profile's tabs reopen in
`default`. Duplicate Workspace copies each browser tab's profile. New
Workspace with a profile starts with a terminal (coordinator decision).
Omnibar history is per profile (in memory). Onboarding imports create one
profile per source with its proposed id; imports made before profiles moved
into theirs once.

## 6. Themes and colors

| Level | Colors | Reason |
| --- | --- | --- |
| Space | every workspace and terminal without an override, and the window chrome (sidebar, titlebar, floating cards) unless the shown workspace has a theme of the same light/dark mode | a window shows one space and chrome is continuous with the terminal background; the recolor on a switch is the clearest cue of the current space |
| Workspace | its content area (terminals, pane tab strips, pane chrome, the screen bar) and, while shown, the window chrome when it is as light or dark as the space; its sidebar row shows its color | the sidebar background equals the content background beside it (Lawrence, 2026-10-01): a seam read as a wrong color, not as a signal. The window top never flips light in a dark space or dark in a light one (Leo, 2026-10-01), so a workspace of the other mode keeps the space's chrome. The chrome switches with the content in one frame |
| Terminal | only its surface (`terminal-color-overrides-v1`) | a pane-level cue, such as ssh to prod |

Precedence: terminal, workspace, space, Ghostty config. A theme is a Ghostty
theme spec (`theme` syntax, `light:A,dark:B`), resolved like the global
config: the user's config files, then `theme = <name>` for the current
light/dark variant, so explicit config colors, opacity and blur still win.
Space, workspace and terminal themes are personal (`profiles.theme`,
`personal_workspaces.theme`, and `personal_terminals(session_id,
terminal_key, theme)` with `set-personal-terminal`, capability
`personal-terminals-v1`; the terminal key is the terminal's id on its
session, else its tab id). Until the home daemon serves
`personal-terminals-v1` the app keeps terminal themes in
`<Application Support>/<bundle id>/terminal-themes.json` and moves them into
personal state once it does. A theme is any spec Ghostty accepts: a theme
name, an absolute path, or `light:A,dark:B`.

Stage 5 (landed): `ThemeScope` in CmuxNextDesign is a tree under
`ThemeScope.app` (the Ghostty config): each window adopts a space scope, each
workspace content view roots a workspace scope, each terminal host view a
terminal scope. A space scope `show`s its window's current workspace scope:
its own views and window draw in that scope's tokens when they share the
space's light/dark mode, while children keep inheriting the space's own theme
(`ownTokens`). A scope recomputes only when its theme or an ancestor's
changes and repaints only what it roots, behind a `Motion` `theme`
crossfade. Views resolve `Palette` inside `performWithTheme` (the nearest
scope); `scripts/cmux-next/check-theme-scope.sh` refuses any other color
read in a module. Every terminal surface takes the spec in effect for it
through `ghostty_surface_update_config` (palette, background, foreground,
cursor, selection) with no restart. A terminal with its own theme shows a
small swatch dot on its tab icon. Actions: `space.setTheme`,
`space.clearTheme`, `workspace.setTheme`, `workspace.clearTheme`,
`terminal.setTheme`, `terminal.clearTheme` (palette with live preview,
context submenus with hover preview, CLI, bindable, Settings). The palette
and the Settings theme picker list every Ghostty theme with type-to-search
and take a typed light/dark pair; context submenus list the Ghostty config
and the onboarding themes, then More… (the palette list).

## 7. App surfaces (action contract)

Sidebar bottom center: one dot per space (icon when set, tinted by its color),
current one emphasized; click switches this window, right-click opens the
space menu, drag reorders, `+` creates; hidden while there is one space. A
two-finger horizontal swipe over the sidebar switches spaces.

| Area | Actions (each: palette, context menu where targeted, CLI verb, bindable shortcut) |
| --- | --- |
| Spaces | New Space, New Window in Space, New Workspace in Space, Rename, Set Color (9) / Clear, Set Icon / Clear, Set Theme / Clear, Set Default Browser Profile, Set Default Session, Follow / Unfollow Session, Set Terminal Defaults, Move Left / Right / to Position, Delete (confirmation), Next / Previous (Cmd-Opt-] / [), Select 1-9 (Ctrl-Opt-1..9), Switch to Space |
| Workspaces | New Workspace on Session, Move to Space, Duplicate into Space, Set Browser Profile / Clear, Set Theme / Clear, Move to Session (re-home layout) |
| Groups | Move Group to Space |
| Browser profiles | New, Rename, Set Color / Icon, Delete (confirmation), New Tab with Browser Profile, Open Link in Browser Profile, Move Tab to Browser Profile, Duplicate Tab into Browser Profile |
| Sessions | Connect, Disconnect, Forget, Rename, Move Terminal to Session (re-create) |

## 8. Stages

1. Sessions registry and qualified IDs: `session-identity-v1`; the app's
   session registry (home table), qualified IDs in the control socket, CLI
   `--session`.
2. Remote terminal references in home layouts: `remote-terminal-tabs-v1`,
   placeholder and snapshot, machine badge, moves across sessions.
3. Spaces on personal membership rules (section 3), personal groups and
   order, the migration, dots, switching, actions.
4. Browser profiles (section 5).
5. Themes (`ThemeScope`, section 6).

Status (2026-09-30, federation agent): stage 1 app side is built
(qualified ids and `--session` in cli-compat.md "Sessions and qualified
ids"). Stage 2 app side is built against `remote-terminal-tabs-v1`:
`RemoteTerminalService` mounts a remote-terminal tab by attaching to the
terminal's session by its `term_` id with no tab there (a kept terminal;
`set-terminal-keep` reports the `term_` id), shows
`RemoteTerminalPlaceholderView` with the saved screen while that session is
away, saves the screen from the local mirror when the session drops and
before quit, and saves the title. `tab move-to-workspace` across sessions
moves the reference (keep, `new-remote-terminal-tab`, close the old tab; back
home through `terminal.project`); "Open Terminal on Machine Here…"
(`remote.openTerminalHere`) creates a kept terminal with no tab on the
machine (`create-terminal {detached}`) and references it. Closing a
remote-terminal tab ends its terminal when that has no tab on its session.
`send`, `send-key` and `read-screen` on a remote-terminal tab reach the
terminal on its session by its `term_` id (resource API). Not built: drag of
a tab onto a pane of another session, browser tabs across sessions.

The app work already written for spaces (dots, swipe, window switching,
actions) carries over; its membership test changes from a workspace tag to
the rules in 3.2.

## 9. Shared appearance and screen schema (feat-cmux-next-screens)

- Flat nullable `color` and `icon` on every entity with appearance; two TEXT
  columns; JSON null clears, absent keeps. Colors: the 9 Chrome names (grey,
  blue, red, yellow, green, pink, purple, cyan, orange) as muted tints; strict
  for required colors (tab and screen groups), permissive
  (`validate_presentation_color`) for optional ones. Icon: SF Symbol name or
  one emoji, one shared `validate_presentation_icon`.
- Screens (`screen-metadata-v1`, `screen-groups-v1`): screen JSON gains
  `color`, `icon`, `pinned`, `group`; workspace JSON gains `screen_groups`.
  Screens and screen groups are layout (1.2b) and live on the workspace's home
  session. Saved screen groups are personal (1.2c): they move to the home
  session like saved tab groups, keyed by space.

## 10. Open points for the user

- The space name (3.4).
- Delete Space: its pinned workspaces return to their followers by default;
  closing them is an explicit option in the confirmation.
- Breaking changes 2.1, above all workspace groups and sidebar order becoming
  personal (the TUI and iOS stop seeing the Mac's grouping).
