# Projects: one durable list, owned by the daemon

Status: design 2026-10-09 (cx-m0p7, follow-up of cx-e2aa). Binding: layer-ownership.md (L1-L5, section 4 checklist), OWNERSHIP-PRINCIPLES.md.

Lawrence (2026-10-09, via the chief): "we need to store projects somewhere too"; then: auto-read and import projects from Claude Code, Codex (CLI and the ChatGPT/Codex desktop app), OpenCode, t3code and the other common tools (Cursor, Zed, VS Code, JetBrains, Conductor, Pi, Gemini CLI, ...); customizable after import; resync smartly when the user later makes a project in one of those tools.

## 1. What exists (tip 29ad65d3ddaa)

No project list is stored. Every list the app shows is rebuilt:

- Swift `AgentProjectScan` / `RecentProjectScan` (`CmuxNextOnboarding/System/AgentProjectScan.swift`): Claude, Codex, Pi and OpenCode session files plus a bounded git walk under `~/Projects`-style roots, at launch (`OnboardingService.projectFolders`) and again on each `project.list` query from the New Tab page. Never saved.
- `cmux-chat-index` (Rust, used by acpmux): 23 harness adapters (Claude Code, Codex incl. the desktop app's `originator`, OpenCode, Pi, Gemini, cursor-agent, ...) with per-OS roots and env overrides (`roots/table.rs`), and a `ChatEntry {harness, cwd, updated_ms, source_path}` per chat. acpmux owns the merged index and one FSEvents/inotify watcher (`acpmux/src/chats/watch.rs`).
- cmux-tui-core: `workspace.agent_folder.set` (chosen folder per workspace) and, coming, `workspace.agent_start.get` (cx-nn3e / cx-9aps). No project table.
- A second list in a webview: acpmux web `localStorage["acpmux.sidebar.projects.v1"]` (L7 violation).

## 2. Model

The cmux-tui-core store owns one project table (one writer). A project:

| Field | Meaning |
| --- | --- |
| `path` | canonical key: absolute, `realpath`-resolved, no trailing slash, case as on disk |
| `name` | display name; defaults to the last path component |
| `sources[]` | `{source, first_seen_ms, last_seen_ms, last_used_ms}` per source that reported the path |
| `overlay` | the user's edits: `rename?`, `pinned`, `hidden`, `order?` |
| `state` | `present` or `missing` (gone from every source and from disk) |

`source` is one of the adapter ids (section 3) or `user` (added by hand, Choose Folder, a picker's typed path) or `workspace` (a cmux workspace was made there).

Derived for readers: `last_used_ms = max(sources[].last_used_ms)`; the list orders pinned first (by `order`), then `last_used_ms` descending; hidden projects are left out unless asked.

## 3. Source adapters

Each adapter yields `(path, source, last_used_ms)` records and nothing else. They reuse `cmux-chat-index` knowledge (roots per OS, env overrides, cwd extraction) instead of a second copy:

- From the chat index (agent harnesses): claude-code, codex (CLI and desktop app, same `CODEX_HOME`), opencode, pi, gemini, cursor-agent, and the other chat-index harnesses. The path is `ChatEntry.cwd`, `last_used_ms` is `updated_ms`.
- New adapters in `cmux-chat-index` (a `projects` module beside the chat adapters, same roots table style):
  - VS Code family (Code, Insiders, Cursor IDE, Windsurf, VSCodium): `User/globalStorage/storage.json` and `state.vscdb` `history.recentlyOpenedPathsList` (folders and `.code-workspace` folders).
  - Zed: its `db` workspace table (`~/Library/Application Support/Zed/db/0-stable/db.sqlite` and Linux/Windows equivalents).
  - JetBrains: `options/recentProjects.xml` of each product config dir.
  - t3code, Conductor: their workspace/repo lists (paths verified from the installed app before the adapter lands; an adapter without a verified fixture does not land).
- Each adapter has a red test with a fixture dir per OS layout (macOS, Linux, Windows paths), including a missing file and a corrupt file.

Single watcher rule: acpmux already watches the chat roots. The store does not start a second watcher on them. acpmux sends what its index learns as a `project.observe` batch (source, path, last_used) to the store over the daemon socket; the store owns the merge. The editor adapters have no watcher yet, so the store watches their few files itself (section 4). Strongest objection: this couples acpmux to the store protocol. Accepted: acpmux is already a daemon peer (layer-ownership 1.1) and moves in-process later (cx-ncc.27), at which point the batch becomes a direct call.

## 4. Resync (event-driven, never a timer)

- At daemon start: one full scan of every enabled source.
- File watches: the editor adapters' source files (FSEvents/inotify through `notify`, debounced like `chats/watch.rs`: 300 ms quiet, 2 s max burst); acpmux pushes chat changes as they happen.
- On app activation: the app sends `project.sync` (a new intent from `didBecomeActive`), which rescans only the sources whose files changed since the last scan (mtime + size check), so a project made in the ChatGPT app while cmux was in the background shows on the next switch to cmux.
- No polling interval anywhere.

## 5. Merge rules (the reducer, invariant-tested)

1. A new path from any source: add it, `state = present`, the source's times set.
2. A known path: update that source's `last_seen_ms`/`last_used_ms` only. Never touch `overlay`.
3. `hidden` stays hidden on every resync; a hidden project is never re-added as visible.
4. A path that no source reports any more and that is gone from disk: `state = missing` (shown dimmed, removable). Never deleted automatically.
5. A `user` source is never dropped by a resync.
6. Disabling a source removes that source entry from every project; a project left with no source and no overlay is removed, one with an overlay (pinned, renamed) stays.
7. Refused paths are never projects: `/`, the home folder itself, temp dirs, agent homes (cmux agent-home and each harness's own config dir), and anything the protected-folder rule refuses to look into is kept only if a source reported it, never walked (`acpmux/src/protected_folders.rs`, one copy).

## 6. Ops (spec `resource-operations-v2.json`, capability `project-list-v1`)

- `project.list {query?, include_hidden?, limit?}` -> projects (section 2 shape).
- `project.observe {source, entries: [{path, last_used_ms}]}` (acpmux and the store's own adapters; idempotent by `(source, path, last_used_ms)`).
- `project.sync {}` (app activation).
- `project.add {path}` (source `user`), `project.update {path, rename?, pinned?, hidden?, order?}`, `project.remove {path}` (drops `user`, sets `hidden` for a path a source still reports, so it does not come back).
- `project.sources.get` / settings: per-source on/off lives in `settings.projects.sources` (schema, generated), read by the store.
- Typed rejects: `invalid_path`, `refused_path`, `unknown_project`.
- Events: `session.events` `state_upsert` for the `projects` resource, as `sidebar_layout` does.

## 7. Privacy

Local only: the table lives in the daemon store; nothing is sent to Cloud, telemetry never carries a path (only counts per source). `~` and `/` are never projects. A source is read only while enabled.

## 8. UI

- Settings: a Projects page (React settings page) listing projects (rename, pin, hide, remove, add folder) and per-source toggles with each source's project count. First import runs silently; onboarding reads the list as detection input (hq-b1).
- New Tab and composer project pickers read `project.list`; picks and Choose Folder send `project.add`/`project.touch` intents. Swift keeps no copy.

## 9. Slices (one landing each)

1. Store + ops + reducer (CORE window): table, `project.list/observe/add/update/remove/sync`, merge invariants, capability, generated types. Red tests: reducer invariants (rules 1-7), protocol tests.
2. Adapters: chat-index harness sources via acpmux `project.observe`; editor adapters (VS Code family, Zed, JetBrains), then t3code and Conductor once fixtures are verified. Red test per adapter with fixture dirs.
3. Resync: daemon-start scan, editor file watches, app activation `project.sync`.
4. UI: Swift `project.list` reads the store (scan becomes an adapter only); Settings Projects page; acpmux web drops its localStorage list.
