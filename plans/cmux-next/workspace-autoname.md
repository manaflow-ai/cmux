# Workspace auto-naming that keeps up (hq#1957 follow-up to #20397)

Status: proposal (cg-lane-adopt, 2026-10-14). Leo asked for names like Dia's tab groups:
the name follows the work until someone renames it.

## Behavior

- Workspaces and tab groups carry an automatic name until a person renames them.
  A manual rename pins the name for good; clearing the name hands it back to auto.
- The name refreshes when the work changes: a chat is created, a chat title changes,
  the folder or branch changes, a PR opens, or every N agent turns. Refreshes are
  debounced (default 30 s quiet), at most one per 3 min per workspace, and skipped
  when the inputs did not change since the last call.
- Output is 1-3 words, title case, no punctuation, no quotes. If the model answer
  fails validation, the old name stays.
- Setting `workspaceList.autoName`: `off` / `onCreate` / `keepUpdated` (default
  `keepUpdated`). Debug tunables cover the debounce, the minimum interval and the
  turn count.
- When the name changes, the sidebar row and the tab-group header crossfade
  quietly (Motion token; no crossfade under Reduce Motion).

## Inputs (all app-side, short)

Chat titles (`AgentTurnStateStore`), the workspace folder name, the git branch,
open PR titles (the existing `gh pr view` path), and browser page titles.
Incognito pages are never included. The prompt is capped at about 1 KB.

## Model call (app)

`POST http://127.0.0.1:31415/v1/messages` (the local subrouter `sr` pool) with
`x-subrouter-agent: claude` and a Haiku-class model, `max_tokens` 16, 20 s timeout.
If `sr` is not listening, fall back to `claude -p --model haiku` (the classic
cmux path) as a one-shot process. With neither available, nothing runs. Event
driven only; no polling. The same namer titles untitled acpmux Claude chats
(no other lane has title work in flight).

## Ownership (daemon is the single writer)

Tabs already have `NameSource { User, Auto }` and `name_revision`
(`cmux-tui-core/src/resource_name.rs`). Workspaces get the same:

- `RegistryWorkspace.name_source` and `name_revision`, persisted with an
  additive SQLite migration. A missing value reads as `User`, so existing
  names stay pinned.
- `rename-workspace` / `workspace.rename` accept `source: "auto"` with
  `expected_generation` and `expected_name_revision`. The daemon refuses an
  auto rename when the current name is user-owned (`operation.failed`,
  `reason_code: name_pinned`; an empty auto name is `name_empty`), or when the
  name revision moved since the app read it (`revision.conflict`). The commit
  repeats both checks against the stored row inside its transaction, so a
  rename stored by another writer also wins. A stale callback loses; a
  person's rename always wins.
- `source: "auto"` with `release: true` hands a pinned name back to auto: the
  text stays, the source becomes auto, `name_revision` advances, and no
  expected revision is needed. v1 still requires `name` (it must equal the
  current name); v2 may omit it.
- Workspace projections expose `name_source` and `name_revision`, so every
  client (app, CLI, TUI, MCP) sees whether a name is pinned.
- `isUserNamed` (the #20397 `workspace-N` guess) is removed once this lands.

Compatibility the app must respect:

- Gate auto renames on the capability `workspace-name-source-v1`, or send them
  only over v2 `workspace.rename` (whose catalog rejects unknown fields). An
  older daemon ignores the unknown v1 `source` field and applies
  `rename-workspace` with `source: "auto"` as a plain user rename, which would
  pin the generated name.
- Workspaces that existed before the migration read as `user` at revision 0,
  so they are pinned and never auto-name until someone releases them (the
  palette or context-menu action below). New workspaces with a daemon-chosen
  default name start as `auto`; a workspace created with a requested name
  starts as `user`.

Tab groups are client view state in the app today; their auto name follows the
same rule locally (an `isAutoNamed` flag cleared by `update-tab-group` with a name).

## Surfaces

Proposed CLI shape (the daemon half in #20710, not yet on `feat-cmux-next`; today
`--source`, `--expected-generation` and `--expected-name-revision` exist only on
`cmux tab rename`):

- `cmux workspace [<selector>] rename <name> --source auto --expected-generation <g>
  --expected-name-revision <n>` for an automatic name (agents, the app's namer).
  `--source user` is the default.
- `cmux workspace [<selector>] rename --release-to-auto` returns a pinned name to
  auto (no name, no expected revision).

`RegistryWorkspace.name_source`, `name_revision` and the `name_pinned` /
`name_empty` refusals above are likewise proposed in #20710.

Still to build: the MCP tool's `source` param, a palette "Let cmux name this
workspace" action that sends the release, and the same item in the sidebar
row's context menu.

## Order

The app half landed first (#21441, #21445):

- `WorkspaceAutoNamer` (`CmuxNextWorkspaceNaming/WorkspaceAutoNamer.swift`)
  persist naming follows the focused chat's generated title until the user renames the workspace,
  with `source: auto`, the daemon generation and `expected_name_revision`. It
  only writes to a daemon that serves `workspace-name-source-v1`.
- `workspaces.autoName.variant` (`WorkspaceAutoNameTunables.swift`, Debug
  Settings, DEV and NIGHTLY) picks the prototype: `live` (sidebar label only)
  or `persist` (the daemon name follows the focused chat's generated title until user rename).
- The user setting is `workspaces.autoName`, a bool ("Name Workspaces from
  Tabs"). The `workspaceList.autoName` `off` / `onCreate` / `keepUpdated`
  setting proposed under Behavior would replace it once the variant is picked:
  `off` is today's `false`, `onCreate` is roughly `persist`, and `keepUpdated`
  is the model namer that does not exist yet.

Still to do:

1. Daemon: workspace name source + revision, protocol, projection, CLI (#20710).
   Rust tests (hosted verify). Review subagent before landing.
2. App: the model namer (sr client + fallback), its triggers, the three-way
   setting, crossfade, chat titles. Red/green Swift tests. Before/after
   recording. SHOW LEO.
