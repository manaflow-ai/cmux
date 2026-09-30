# cmux next: shared tree data model (rooms, browser profiles, themes, screens)

Living design note for the daemon tree that cmux-tui owns and every frontend
projects (architecture.md 1). It records the model for the user's "profiles"
request (2026-09-30), revised the same day into two kinds of profile, and the
schema shared with screen tabs and screen groups (feat-cmux-next-screens).

## 0. Two kinds of profile (user, 2026-09-30)

| | Browser profile | Room (working name, section 1) |
| --- | --- | --- |
| What it holds | browser data only: cookies, logins, history, extensions, site permissions | a switchable set of workspaces and workspace groups, with its own theme and colors, and a default browser profile |
| Switched how | per tab, by where the tab was opened (section 5) | per window: the sidebar dots, a swipe, shortcuts |
| Like | Chrome profiles, Arc profiles | Arc Spaces |
| Created by | the user, a room creation, or an import from another browser (onboarding, later) | the user |

Internal names: the wire and Swift model call a room a `profile` (commands
`*-profile`, `profiles-v1`, `ProfileID`), because the daemon work started
under that name and a wire name must not follow product naming. A browser
profile is always `browser_profile` on the wire and `BrowserProfile*` in
Swift. User-visible strings, action IDs and CLI verbs use the product name.

## 1. Name for the switchable set

Candidates (avoid "Spaces": macOS Spaces):

| Name | Reason for | Reason against |
| --- | --- | --- |
| **Rooms** | spatial, like walking into another room: its own furniture (workspaces) and paint (theme); short; reads well in every verb ("New Room", "Move Workspace to Room", "Switch Room"); no collision in macOS or terminals | slightly playful |
| Hats | catchy ("wear another hat": work, personal, oncall) | reads badly in verbs ("Move Workspace to Hat") |
| Worlds | strong sense of full separation | grandiose for a work context |
| Contexts | precise | collides with kubectl/docker contexts that cmux users type daily |
| Modes | short | vague; collides with Vim modes and focus modes |

Pick: **Rooms**. The coordinator confirms with the user; until then code uses
the internal `profile`, and only strings, action IDs and CLI verbs say room.

## 2. The tree today and the decision: a tag, not a level

```
session (one daemon, one SQLite registry)
├── workspace groups          workspace_groups(group_id, name, color, position, collapsed)
├── saved tab groups          saved_tab_groups(saved_id, ..., members_json, position)
└── workspaces (one order)    workspace_presentation(key, group_id, color, icon, title)
    └── screens -> columns / splits / stacks -> panes -> tab groups, tabs
```

Workspace groups are a partition over the one durable workspace order
(`workspace_presentation.group_id`), not a tree level. A room is the same kind
of partition one level up:

| | New level (`rooms[].workspaces[]`) | Tag (`workspace.profile`) |
| --- | --- | --- |
| Wire | nests workspaces under rooms: breaks every existing client (shipped iOS adapter, TUI, v2 SDKs, older app builds) | additive field; old clients see a flat list and keep working |
| Order | one order per room, new cross-room move | one global order filtered per room, exactly like groups |
| Registry | new parent key, schema version bump, rollback breaks | one table, nullable columns; older binaries open it and show every workspace |
| Old remote daemons | cannot express it | one implicit room |

Chosen: the tag. Invariants:

- Every workspace belongs to exactly one room; no tag = the built-in room
  `default` (all workspaces from before this change, or created by a client
  that does not know rooms). No data migration.
- A workspace group belongs to one room; a workspace in a group is in the
  group's room. Moving a workspace to another room ungroups it unless the move
  names a group of that room; moving a group moves its members.
- Screens, screen groups, columns, panes, tabs and tab groups follow their
  workspace. Session-wide records not under a workspace carry an optional
  room: saved tab groups and saved screen groups (null = `default`).
- `default` always exists, can be renamed, recolored, themed and reordered,
  and cannot be deleted.

## 3. Daemon schema and wire (capability `profiles-v1`)

Tables (additive; `workspace_registry/profile_store.rs`):

```sql
CREATE TABLE IF NOT EXISTS profiles (             -- rooms
  profile_id TEXT PRIMARY KEY NOT NULL,           -- 'default' or 'prof_<32 hex>'
  name TEXT NOT NULL, color TEXT, icon TEXT,
  theme TEXT,                                     -- Ghostty theme spec (section 6)
  position INTEGER NOT NULL CHECK(position >= 0),
  browser_profile_id TEXT,                        -- default browser profile of its workspaces; null = 'default'
  defaults_json TEXT                              -- {"cwd": "...", "env": {"K": "V"}} for new terminals
);
CREATE TABLE IF NOT EXISTS browser_profiles (
  browser_profile_id TEXT PRIMARY KEY NOT NULL,   -- 'default' or a lowercase UUID
  name TEXT NOT NULL, color TEXT, icon TEXT,
  position INTEGER NOT NULL CHECK(position >= 0),
  source_json TEXT                                -- import origin, e.g. {"browser":"chrome","profile":"Profile 1"}
);
-- guarded by a column probe:
ALTER TABLE workspace_presentation ADD COLUMN profile_id TEXT;
ALTER TABLE workspace_presentation ADD COLUMN browser_profile_id TEXT;  -- workspace override
ALTER TABLE workspace_presentation ADD COLUMN theme TEXT;               -- workspace theme
ALTER TABLE workspace_groups ADD COLUMN profile_id TEXT;
ALTER TABLE saved_tab_groups ADD COLUMN profile_id TEXT;
```

Schema creation inserts the `default` room and the `default` browser profile
once (`INSERT OR IGNORE`). Every mutation appends one advisory `state` journal
record.

Wire (raw protocol v12):

- `list-workspaces` gains `profiles: [{id, name, color, icon, theme, index,
  browser_profile_id, defaults}]` and `browser_profiles: [{id, name, color,
  icon, index, source}]`.
- Workspace entities gain `profile` (always present) and, when set,
  `browser_profile_id` and `theme`. Workspace groups and saved tab groups gain
  `profile`.

| Command | Fields | Result / event |
| --- | --- | --- |
| `list-profiles` | | `{profiles}` |
| `create-profile` | `name, profile?, color?, icon?, theme?, index?, browser_profile_id?, defaults?` | `{profile, changed}`; retry with same id and name is a no-op; `tree-changed` |
| `update-profile` | `profile, name?, color?, icon?, theme?, browser_profile_id?, defaults?` (null clears) | `{profile, changed}`; `tree-changed` |
| `move-profile` | `profile, index` | `{profile, changed}`; `tree-changed` |
| `delete-profile` | `profile, move_to?` | with `move_to` its workspaces, groups and saved groups move there; without it its workspaces close and their terminals end in one batch commit, its groups and saved groups are deleted; `default` refused. `{profile, workspace_keys, moved_to}`; `tree-changed` |
| `move-workspace-to-profile` | `workspace\|key, profile, group?, index?, origin, mutation_id, expected_*` | durable workspace mutation; `workspace-moved` with the entity |
| `move-workspace-group-to-profile` | `group, profile` | `{group, workspace_keys, changed}`; `tree-changed` |
| `create-workspace` | new optional `profile` | born in that room |
| `create-workspace-group` | new optional `profile` | born in that room |
| `set-workspace-metadata` | new optional `browser_profile_id`, `theme` (null clears) | `workspace-changed` |
| `list-browser-profiles` | | `{browser_profiles}` |
| `create-browser-profile` | `name, browser_profile?, color?, icon?, index?, source?` | `{browser_profile, changed}`; `tree-changed` |
| `update-browser-profile` | `browser_profile, name?, color?, icon?` | same |
| `move-browser-profile` | `browser_profile, index` | same |
| `delete-browser-profile` | `browser_profile` | `default` refused; rooms and workspaces that name it fall back to inherit (null); frontend browser tabs that use it are retagged `default`; `{browser_profile, retagged_tabs}`; `tree-changed` |
| `new-frontend-browser-tab` | `profile_id` absent: the daemon fills the effective browser profile of the target workspace (section 5) | unchanged otherwise |

Terminal defaults: when a terminal is created in a workspace whose room has
defaults and the request has no `cwd`, it starts in `defaults.cwd`;
`defaults.env` goes under the request's own `env`. The daemon applies them, so
the plain `cmux-tui` CLI, iOS and agents behave like the app.

Duplicating a workspace into a room is a frontend composite (create in the
target room, replay the layout with new terminals in the same directories and
new browser tabs with the same URLs); a duplicate never shares a terminal.

### Compatibility

- Without `profiles-v1` (older local or Cloud daemon) the app shows one
  implicit room, hides the dots, browser tabs use the default browser profile,
  and every room and browser-profile action is typed unavailable. Nothing is
  written.
- Older clients against a new daemon ignore the new fields and list every
  workspace: nobody loses access to a workspace. iOS can filter by `profile`
  later.
- Resource API v2 is unchanged in this pass (optional additive fields later).
- Rooms and browser profiles belong to one daemon. A window's room filters the
  workspaces of each machine that has a room with that id; a machine without it
  (an older daemon, or a Cloud machine with only `default`) shows all of its
  workspaces in every room. Rooms do not span machines in v1.

## 4. Windows: the frontend projection

Which room a window shows is per window and per user, so it lives in the
`personal` window document: `WindowRecord.profile` (absent = `default`) and
`profile_workspaces` (`{room id: workspace key}`, the workspace last shown
there). Membership stays in `WindowRegistry` (each workspace owned by at most
one window); a window owns workspaces of several rooms and lists those of its
current room.

Switching window W to room R:

1. W shows the workspaces it owns in R and selects the one it last showed there.
2. Else W takes every workspace of R that no open window currently showing R
   owns (hidden in other windows, in the closed window, or unplaced). With one
   window this is the whole room.
3. Else the app creates a workspace in R for W (no empty window).

When W loses the last workspace of its room, W shows the most recent other
room it owns workspaces in; with none, the existing rule closes the window.
Selecting a workspace of another room (palette, CLI, a notification) switches
the window to that room. New workspaces, new windows (Cmd-N) and new groups are
born in the window's room. The switch changes only what the window lists and
shows, in one main-actor turn: terminals keep running and hidden surfaces take
the normal hidden-tab path, so there is no flash and no restart.

## 5. Browser profiles: assignment and display

Cascade for a new browser tab (first set wins):

1. an explicit choice (New Tab with Browser Profile X, Open Link in Browser
   Profile X, a CLI `--browser-profile`),
2. the workspace override (`workspace.browser_profile_id`),
3. the room default (`profile.browser_profile_id`),
4. `default`.

No window level: a window's browser profile is its room's, so a workspace
looks the same in every window. The resolved id is stored on the tab at
creation (`frontend_browser_tabs.profile_id`, the existing field) and never
changes by inheritance: changing a room or workspace default, or moving a
workspace to another room, never moves a live page to another cookie jar (no
silent logout). A tab changes browser profile only by an explicit Move Tab to
Browser Profile, which reopens its URL in the target profile.

Display:

- The omnibar shows the tab's browser profile (color dot or icon, name in the
  tooltip and Page Info) whenever more than one browser profile exists.
- A tab whose browser profile differs from its workspace's effective one shows
  a small profile dot on the tab, and its hover card names it, so two tabs of
  one workspace with different browser data are always visible as such.

Engine mapping: `default` -> the app's `BrowserProfileID.default` (existing
data stays there); a UUID id -> that UUID
(`WKWebsiteDataStore(forIdentifier:)`, CEF request context
`Chromium/Profile-<uuid>`). Deleting a browser profile removes its engine data
after its tabs moved to `default`. A room created without a choice uses the
current room's browser profile (logins keep working); New Room offers "new
browser profile" as an option.

Import (onboarding agent, later): an import calls `create-browser-profile`
with `source` (browser and source profile) and then fills the engine store
for the returned id. The model needs nothing else.

## 6. Themes and colors

Levels and what each one colors:

| Level | Colors | Reason |
| --- | --- | --- |
| Room | the whole window: sidebar, titlebar, tab strips, pane chrome, floating cards, and every terminal without its own override | a window shows one room; chrome is continuous with the terminal background (REWRITE.md visual rules), so the room that owns the window owns its chrome; the recolor on a switch is the strongest cue of which room you are in (Arc) |
| Workspace | only its content area: its terminals, tab strips and pane chrome; its sidebar row shows its color swatch | the sidebar lists many workspaces: recoloring it on every selection would flash the whole window and hide the room cue. A seam between sidebar and content is the intended signal ("prod is red") |
| Terminal | only that terminal surface (the daemon's per-terminal color overrides, `terminal-color-overrides-v1`) | a pane-level cue such as an ssh session |

Precedence: terminal over workspace over room over the Ghostty config.
Storage: a theme is a Ghostty theme spec string (`theme` syntax, including
`light:A,dark:B`); the app resolves it through Ghostty's theme search path and
derives chrome tokens exactly as for the global config. `color` and `icon`
(section 7) are the small accents (dots, swatches), not themes.

Implementation risk: `Palette` resolves every chrome color from one
process-wide `ThemeSnapshot`. Room and workspace themes need window-scoped and
view-scoped tokens: a `ThemeScope` on each window (and each workspace content
view) that views resolve through their scope, replacing the global lookup.
That is a CmuxNextDesign change touching every module's color reads, so it is
its own stage with its own review.

## 7. Shared appearance shape (agreed with feat-cmux-next-screens)

One shape on every entity with appearance: workspaces, workspace groups,
tabs (later), tab groups, screens, screen groups, rooms, browser profiles.

- Flat nullable `color` and `icon` fields; two TEXT columns; updates like
  `set-workspace-metadata` (JSON null clears, absent keeps).
- Color vocabulary: the 9 Chrome names grey, blue, red, yellow, green, pink,
  purple, cyan, orange, as muted tints. Required colors (tab groups, screen
  groups) check the strict 9 names; optional ones use the permissive
  `validate_presentation_color`.
- Icon: an SF Symbol name or exactly one emoji grapheme, checked by the one
  shared `validate_presentation_icon`.

Screen schema (feat-cmux-next-screens, `screen-metadata-v1`,
`screen-groups-v1`): screen JSON gains `color`, `icon`, `pinned`, `group`;
workspace JSON gains `screen_groups`; saved screen groups carry nullable
`profile_id`. Code in `mux/screen_groups.rs` and
`workspace_registry/screen_store.rs`; rooms in `mux/profiles.rs` and
`workspace_registry/profile_store.rs`.

## 8. App surfaces (action contract)

Sidebar footer, bottom center: one dot per room (its icon when set, tinted
with its color), the current one emphasized. Click switches this window,
right-click opens the room menu, drag reorders, `+` creates. Hidden while
there is one room (New Room stays in the sidebar background menu, palette,
menu bar and CLI). A two-finger horizontal swipe over the sidebar switches to
the previous or next room.

Actions (one descriptor each: palette, context menu where it has a target,
CLI verb, bindable shortcut):

| Area | Actions |
| --- | --- |
| Rooms | New Room, Rename, Set Color (9) / Clear, Set Icon / Clear, Set Theme / Clear, Set Default Browser Profile, Set Terminal Defaults, Move Left / Right / to Position, Delete (confirmation, optional move target), Next / Previous (Cmd-Opt-] / Cmd-Opt-[), Select 1-9 (Ctrl-Opt-1..9), Switch to Room, New Window in Room |
| Workspaces | New Workspace in Room, Move to Room, Duplicate into Room, Set Browser Profile / Clear, Set Theme / Clear |
| Workspace groups | Move Group to Room |
| Browser profiles | New Browser Profile, Rename, Set Color / Icon, Delete (confirmation), New Tab with Browser Profile, Open Link in Browser Profile, Move Tab to Browser Profile, Duplicate Tab into Browser Profile |

Shortcut defaults avoid the existing families: Cmd-Shift-[ ] tabs, Cmd-Ctrl-[
] workspaces, Cmd-Ctrl-Opt-[ ] workspace reorder, Cmd-1..9 workspaces,
Ctrl-1..9 tabs and right sidebar.

## 9. Stages

1. Rooms: daemon tag, window switching, dots, swipe, room and workspace
   actions, strings in 21 languages.
2. Browser profiles: daemon records and cascade, engine mapping, omnibar and
   tab display, browser-profile actions.
3. Themes: `ThemeScope` in CmuxNextDesign, room and workspace themes.

## 10. Open points for the user

- The name (section 1).
- Delete Room without a target closes its workspaces and ends their terminals;
  the confirmation offers moving them instead.
- A new room shares the current room's browser profile unless the user picks
  "new browser profile" (logins keep working by default).
- Moving a workspace to another room keeps each live page in its browser
  profile; mismatches show the tab dot (section 5).
