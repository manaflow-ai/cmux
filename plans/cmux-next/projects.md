# Projects: one durable list, owned by the daemon

Status: decision 2026-10-09 (cx-e2aa, New Tab project picker). Binding: layer-ownership.md (L1-L5, section 4 checklist), OWNERSHIP-PRINCIPLES.md.

Lawrence (2026-10-09): "let's bring in the model selector into the new tab page, as well as project picker. we need to store projects somewhere too."

## 1. What exists (tip c0360988c23d)

No project list is stored anywhere. Every list the app shows is rebuilt:

- Swift `AgentProjectScan` / `RecentProjectScan` (`CmuxNextOnboarding/System/AgentProjectScan.swift`): agent session files (Claude, Codex, Pi, OpenCode cwds) plus a bounded git-repo walk under common roots. Never saved. It must stay in Swift: it is the code that knows which folders are privacy-protected (no TCC prompt).
- `OnboardingService.projectFolders`: the scan at launch, in memory; the New Tab handshake carries it as `newTab.projects`.
- The page bridge `project.list` (`NewTabPage.swift` handler): the scan again on every query, with session and tab cwds as hints. `project.browse` opens an NSOpenPanel; the folder picked is not remembered.
- acpmux sessions carry `cwd` and `updated_at` (the strongest "last used" signal for agent work).
- cmux-tui-core `workspace.agent_folder.set` (the chosen agent folder per workspace) and, on `feat-cmux-next-nn3e-folder`, the `workspace.agent_start.get` resolver (cx-nn3e). Neither is a list.
- A second, separate list: the acpmux standalone web UI keeps its sidebar project order in `localStorage` (`acpmux.sidebar.projects.v1`), a webview owning durable state (L7 violation).

## 2. Decision

The project list is daemon state owned by the cmux-tui-core store (the workspace store), one writer, exposed as v2 resource operations. Not acpmux: projects serve terminals and workspaces (onboarding `openProjects`) as well as agent chats, and the store already owns the per-workspace agent folder and the coming start-folder resolver, so the folder rules (canonical path, never `~` or above, never agent-home) are written once.

Record: `{path, name, last_used_at, pinned, source}`; `name` defaults to the last path component; `source` is `used | picked | scanned`.

Ops (spec `resource-operations-v2.json`, capability `project-list-v1`):

- `project.list {limit?, query?}` -> projects, pinned first, then `last_used_at` descending.
- `project.touch {path, source}` with an idempotency key: inserts or bumps `last_used_at`. The store calls it itself when `agent_start.get` resolves a folder and when a workspace is created with a cwd; the app sends it when the user picks a folder in a picker or the folder panel.
- `project.update {path, name?, pinned?}`, `project.remove {path}`.
- Typed rejects: `invalid_path`, `home_or_above`, `agent_home`.

Swift: the `project.list` bridge reads the store list first and appends `RecentProjectScan` results the store does not have (scan results stay hints; the app may `project.touch` them with source `scanned` only on a user pick). TS: `Project` gains `pinned` and `lastUsed` from the generated type; the picker renders, never orders.

## 3. Slices

1. (cx-e2aa, landed with this file) New Tab page: project picker and model/effort/speed chip on top, using the existing `project.list` path. No storage change.
2. Store resource: spec entry, `core/state/project*.rs` reducer with invariant tests, migration, generated Swift/TS types, `agent_start.get` touch (after cx-nn3e lands). Needs the CORE window token.
3. Swift `project.list` reads the store; picks and the folder panel send `project.touch`.
4. Remove the second list: acpmux web `acpmux.sidebar.projects.v1` reads the store list.

## 4. Open questions

- Pin and rename UI: the project picker's row menu (later, with slice 3).
- Remote machines: a project path is per machine; the record key becomes `(machine, path)` when the Cloud/SSH folder pickers use it. Slice 2 keys local paths only and reserves the column.
