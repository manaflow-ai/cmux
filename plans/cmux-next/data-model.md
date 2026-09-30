# cmux next: shared tree data model (profiles, screens, appearance)

Living design note for the daemon tree that cmux-tui owns and every frontend
projects (architecture.md 1). It records the model for profiles (user
2026-09-30: "add profiles, dots bottom center of the sidebar to switch; may
have to rethink the data structure in cmux-tui") and the schema shared with
screen tabs and screen groups (feat-cmux-next-screens, agreed 2026-09-30).

## 1. The tree today

```
session (one daemon, one SQLite registry)
├── workspace groups          workspace_groups(group_id, name, color, position, collapsed)
├── saved tab groups          saved_tab_groups(saved_id, ..., members_json, position)
└── workspaces (one order)    workspaces + resource_workspaces; workspace_presentation(key, group_id, color, icon, title)
    └── screens               (in the mux state, journaled topology)
        └── columns / splits / stacks
            └── panes
                ├── tab groups    tab_groups(group_id, pane_id, ...), tab_group_members(tab_id, group_id)
                └── tabs          tab_presentation(tab_id, pinned); frontend_browser_tabs(browser_id, ..., profile_id)
```

Workspace groups are not a tree level. They are a partition over the one
durable workspace order: `workspace_presentation.group_id` tags a workspace,
and a group's members are the registry order filtered by that tag
(`move-workspace-to-group`). The presentation tables are additive and carry no
foreign keys, so an older binary that opens the registry ignores them and keeps
working.

## 2. Decision: a profile is a tag on workspaces, not a new tree level

A profile is a named set of workspaces and workspace groups with its own
browser data, appearance and terminal defaults (Arc Spaces plus Chrome
profiles).

Options considered:

| | New level (`profiles[].workspaces[]`) | Tag (`workspace.profile`) |
| --- | --- | --- |
| Wire shape | `list-workspaces` nests workspaces under profiles: breaks every existing client (shipped iOS compat adapter, the TUI, v2 SDKs, older app builds) | additive field; old clients see a flat list and keep working |
| Ordering | one order per profile; `move-workspace` needs a profile-local index and a cross-profile move | one global order, filtered per profile, exactly like groups; `move-workspace` stays valid |
| Registry | new parent key on `workspaces`, schema version bump, rollback breaks | one new table and one nullable column in `workspace_presentation`; no version bump, rollback keeps working (the older binary shows every workspace) |
| Remote daemons | an old Cloud daemon cannot express it | an old daemon simply has one implicit profile |

Chosen: the tag. It follows the proven workspace-group pattern, keeps the
registry backward and forward compatible (docs/cloud-guest-upgrades.md: open
every older schema, stay openable by older builds), and costs no migration.

Invariants:

- Every workspace belongs to exactly one profile. A workspace with no
  `profile_id` (every workspace created before profiles, or by a client that
  does not know profiles) belongs to the built-in profile `default`.
- A workspace group belongs to one profile (`workspace_groups.profile_id`,
  null = `default`). A workspace in a group is always in the group's profile:
  moving a workspace to another profile ungroups it unless the move names a
  group of the target profile; moving a group to another profile moves its
  members with it.
- Screens, screen groups, columns, panes, tabs and tab groups belong to a
  workspace and follow its profile. They carry no profile field.
- Session-wide records that are not under a workspace carry an optional
  profile: saved tab groups and saved screen groups (null = `default`), so each
  profile's saved bar lists only its own.
- The profile `default` always exists, is first in a fresh registry, can be
  renamed, recolored, iconed and reordered, and cannot be deleted (it is the
  home of untagged workspaces from older clients).

### Migration

None needed. Schema creation inserts the `default` row once (`INSERT OR
IGNORE`), and every existing workspace, group and saved group reads as
`default` because its column is null. Existing browser data stays with the
default profile (section 5).

## 3. Daemon schema and wire (capability `profiles-v1`)

Tables (additive, `workspace_registry/profile_store.rs`):

```sql
CREATE TABLE IF NOT EXISTS profiles (
  profile_id TEXT PRIMARY KEY NOT NULL,       -- 'default' or client/daemon id 'prof_<32 hex>'
  name TEXT NOT NULL,
  color TEXT, icon TEXT,                      -- shared appearance (section 6)
  position INTEGER NOT NULL CHECK(position >= 0),
  browser_profile_id TEXT,                    -- lowercase UUID; null = the frontend's default browser profile
  defaults_json TEXT                          -- {"cwd": "...", "env": {"K": "V"}} or null
);
ALTER TABLE workspace_presentation ADD COLUMN profile_id TEXT;   -- guarded by a column probe
ALTER TABLE workspace_groups ADD COLUMN profile_id TEXT;
ALTER TABLE saved_tab_groups ADD COLUMN profile_id TEXT;
```

Every mutation appends one `state` journal record with `advisory` replay,
like the other presentation records (`profile.created`, `profile.updated`,
`profile.deleted`, `profile.moved`, `workspace.presentation.updated` with the
profile, `workspace.group.updated`).

Wire additions (raw protocol v12):

- `list-workspaces` gains `profiles: [{id, name, color, icon, index,
  browser_profile_id, defaults}]` next to `groups`, in order.
- Every workspace entity gains `profile` (always present, `"default"` when
  untagged). Every group gains `profile`. Saved tab groups gain `profile`.
- Commands:

| Command | Fields | Result / event |
| --- | --- | --- |
| `list-profiles` | | `{profiles}` |
| `create-profile` | `name, profile?, color?, icon?, index?, defaults?` | `{profile, changed}`; a retried id with the same name is a no-op; the daemon mints `browser_profile_id`; `tree-changed` |
| `update-profile` | `profile, name?, color?, icon?, defaults?` (null clears) | `{profile, changed}`; `tree-changed` |
| `move-profile` | `profile, index` (insertion semantics of `move-workspace`) | `{profile, changed}`; `tree-changed` |
| `delete-profile` | `profile, move_to?` | with `move_to` its workspaces and groups move there; without it its workspaces close and their terminals end (one batch commit); groups and saved groups of the profile are deleted; `default` is refused; `tree-changed` |
| `move-workspace-to-profile` | `workspace\|key, profile, group?, index?, origin, mutation_id, expected_*` | durable workspace mutation (one registry revision, exactly-once), `workspace-moved` delta whose entity carries `profile`/`group` |
| `move-workspace-group-to-profile` | `group, profile` | moves the group and its members; `tree-changed` |
| `create-workspace` | new optional `profile`, `group` | the workspace is born in that profile (no second commit) |

Duplicating a workspace into a profile is a frontend composite: the app
creates a workspace in the target profile and replays the source layout with
new terminals in the same directories (the daemon has no duplicate command,
and a duplicate must not share running terminals).

Terminal defaults: `spawn_surface_with` receives the workspace key; when the
workspace's profile has defaults, a terminal created with no `cwd` starts in
`defaults.cwd`, and `defaults.env` is applied under the request's own `env`
(request keys win). The daemon applies them, not the app, so the plain
`cmux-tui` CLI, iOS and agents get the same behavior with the app closed.

Events: profiles are session-level like workspace groups, so profile commands
emit `tree-changed` and frontends refetch `list-workspaces`. A workspace that
changes profile emits `workspace-moved` with the full entity.

### Compatibility

- The app reads `profiles-v1` from `identify.capabilities`. Without it (an
  older local daemon, an older Cloud VM daemon), the app shows one implicit
  profile, hides the dots, and every profile action is typed unavailable
  (`ActionRegistry+Unavailable`). Nothing is written.
- Older clients against a new daemon (shipped iOS through the mobile compat
  adapter, the TUI, older app builds) ignore the `profile` field and list every
  workspace. That is safe: they never lose access to a workspace. iOS can
  filter by profile later by reading the same field.
- Resource API v2 (`cmux.protocol/2`) is unchanged in this pass; `profile` is
  a raw v12 field. Exposing it in v2 is an optional additive field later.
- Cloud machines: each machine's daemon has its own profiles. A window shows
  one profile of one machine; profiles do not span machines in v1 (same rule
  as "no mixed-machine workspaces").

## 4. Windows: the frontend projection

Which profile a window shows is per window and per user, so it lives in the
`personal` window document (`WindowStateDocument`), not the shared tree.

`WindowRecord` gains:

- `profile` (profile id the window shows; absent = `default`).
- `profile_workspace` (`{profile id: workspace key}`): the workspace this
  window last showed in each profile, so switching back restores it.

Membership stays as it is (each workspace owned by at most one window,
`WindowRegistry`). A window owns workspaces of several profiles and its
sidebar lists only those of its current profile. Switching window W to
profile P:

1. W shows the workspaces it owns in P, and selects `profile_workspace[P]`
   (else the first).
2. If W owns none in P, W takes every workspace of P that no open window
   currently showing P owns (workspaces hidden in other windows, in closed
   windows, or unowned). With one window, W owns everything, so a switch
   shows the whole profile.
3. If that is still none (P is new or empty, or every workspace of P is shown
   by another window), the app creates a workspace in P for W (the "no empty
   window" rule of REWRITE.md round 1 holds per profile).

When W loses the last workspace of its current profile (close, move, delete),
W switches to the most recently shown other profile it owns workspaces in; if
it owns none, the existing rule applies and the window closes.

Switching swaps the sidebar model and the content controller's workspace in
one main-actor turn. Terminal surfaces of the hidden workspaces go through the
normal hidden-tab path (released after the LRU, the daemon keeps the PTYs
running), so there is no flash and no terminal restart.

## 5. Browser profiles

The engines already key storage by `BrowserProfileID` (UUID):
`WKWebsiteDataStore(forIdentifier:)` and a CEF request context in
`Chromium/Profile-<uuid>` (browser.md "Per-profile data dirs"). Mapping:

- `default` profile -> `BrowserProfileID.default` (the existing fixed UUID), so
  existing logins, history, extensions and site permissions stay where they are.
- Other profiles -> `browser_profile_id` from the daemon (minted once at
  create, never reused), so renaming or reordering never moves data.
- A new browser tab records that id in `frontend_browser_tabs.profile_id`
  (the field exists). Rendering uses the tab's recorded id, so a live page
  never silently changes cookie jar.
- Moving a workspace to another profile re-homes its browser tabs: the app
  updates each tab's profile id and recreates the page in the target profile's
  store (the page reloads there). Duplicating opens new tabs in the target.
- Deleting a profile removes its browser data after its tabs close
  (`WebKitProfileStore.removeData`, and the CEF profile directory once no
  request context uses it).

## 6. Shared appearance shape (agreed with feat-cmux-next-screens)

One shape on every entity that has appearance: workspaces, workspace groups,
tabs (later), tab groups, screens, screen groups, profiles.

- Flat fields `color` and `icon` on the entity JSON, null when unset. No nested
  `appearance` object (workspaces already ship flat fields,
  `workspace-metadata-v1`).
- SQL: two nullable TEXT columns, `color` and `icon`.
- Updates follow `set-workspace-metadata`: a field sent as JSON null clears
  it, an absent field is unchanged (`present_nullable`).
- Color: the vocabulary frontends offer is the 9 Chrome names grey, blue, red,
  yellow, green, pink, purple, cyan, orange (spelled `grey`, as
  `TAB_GROUP_COLORS`), rendered as muted tints (user group colors are content,
  not accent). Where a color is required (tab groups, screen groups) the daemon
  checks the strict 9 names (`validate_tab_group_color`); where it is optional
  (workspaces, screens, profiles, workspace groups) it checks the permissive
  `validate_presentation_color` (token or `#RRGGBB[AA]`) so existing values
  stay valid.
- Icon: an SF Symbol name or exactly one emoji grapheme, checked by the one
  shared `validate_presentation_icon`.

Screen schema (owned by feat-cmux-next-screens, capabilities
`screen-metadata-v1` and `screen-groups-v1`): screen JSON gains `color`,
`icon`, `pinned`, `group`; workspace JSON gains `screen_groups: [{id, name,
color, icon?, collapsed, saved}]`; saved screen groups carry nullable
`profile_id`. Code in `mux/screen_groups.rs` and
`workspace_registry/screen_store.rs`; profiles in `mux/profiles.rs` and
`workspace_registry/profile_store.rs`. Both are additive to
`create_presentation_schema`; whoever lands second rebases.

## 7. App surfaces (action contract)

- Sidebar footer, bottom center: one dot per profile (the icon when it has
  one, tinted with its color), the current one filled. Click switches this
  window; right-click opens the profile menu (Rename, Icon and Color, Terminal
  Defaults, Move Up/Down, Delete...); drag reorders; `+` creates. Hidden while
  there is only one profile (the `+` stays reachable from the menu, palette
  and CLI). A two-finger horizontal swipe over the sidebar list switches to the
  previous/next profile.
- Actions (one descriptor each, palette + CLI + menu + bindable): `profile.new`,
  `profile.rename`, `profile.setAppearance`, `profile.setDefaults`,
  `profile.delete` (confirmation), `profile.moveUp`/`profile.moveDown`,
  `profile.next`/`profile.previous`, `profile.switch` (argument: profile, digit
  family for index), `workspace.moveToProfile`, `workspace.duplicateToProfile`.
- Default shortcuts: Cmd-Opt-] / Cmd-Opt-[ for next / previous profile (free:
  Cmd-Shift-[ ] is tabs, Cmd-Ctrl-[ ] is workspaces, Cmd-Ctrl-Opt-[ ] is
  workspace reorder), Ctrl-Opt-1..9 for profile by index (Cmd-1..9 is
  workspaces, Ctrl-1..9 is tabs and the right sidebar). All editable in
  Settings and `shortcuts.<actionID>` in cmux.json.

## 8. Open points for the user

- Delete without a target closes the profile's workspaces and ends their
  terminals (Chrome deletes a profile's windows). The confirmation offers
  "Move workspaces to <profile>" as the alternative.
- A workspace moved to another profile reloads its browser pages in the target
  profile's browser store (logins do not follow). The alternative, keeping the
  old store per tab, would mix cookie jars inside one profile.
