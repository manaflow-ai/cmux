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
| `sources[]` | `{source, first_seen_ms, last_used_ms}` per source that reported the path (no "last seen": it would rewrite every row on every resync) |
| `overlay` | the user's edits: `rename?`, `pinned`, `hidden`, `order?` |
| `state` | `present` or `missing` (gone from every source and from disk) |

`source` is one of the adapter ids (section 3) or `user` (added by hand, Choose Folder, a picker's typed path) or `workspace` (a cmux workspace was made there).

Derived for readers: `last_used_ms = max(sources[].last_used_ms)`; the list orders pinned first (by `order`), then `last_used_ms` descending; hidden projects are left out unless asked.

## 3. Source adapters

Each adapter yields `(path, source, last_used_ms)` records and nothing else. They reuse `cmux-chat-index` knowledge (roots per OS, env overrides, cwd extraction) instead of a second copy:

- From the chat index (agent harnesses): claude-code, codex (CLI and desktop app, same `CODEX_HOME`), opencode, pi, gemini, cursor-agent, and the other chat-index harnesses. The path is `ChatEntry.cwd`, `last_used_ms` is `updated_ms`.
- Editor adapters in `cmux-tui-core::state::project_sources` (one module per editor family, same roots-per-OS style):
  - VS Code family (Code, Insiders, Cursor IDE, Windsurf, VSCodium): `User/globalStorage/state.vscdb` `history.recentlyOpenedPathsList` (local `folderUri` entries, newest first; the list has no times, so the file's mtime is the first entry's use and each later entry gets only its rank, so a write to the file never makes the whole list look just used), else, only when `state.vscdb` does not exist, the `profileAssociations.workspaces` folders of `User/globalStorage/storage.json`. Remote URIs, files and `.code-workspace` files are not projects.
  - Zed: its `workspaces` table (`~/Library/Application Support/Zed/db/0-stable/db.sqlite`, `$XDG_DATA_HOME/zed/...`, `%LOCALAPPDATA%\Zed\...`): local rows (`remote_connection_id` null), one root per line of `paths`, UTC `timestamp`. Zed keeps a file opened on its own as a root; the store reads no disk, so a root named like a source file (`main.rs`, `notes.md`) is left out by its extension (not `.js` or `.io`, which name real folders such as `three.js`).
  - JetBrains: `options/recentProjects.xml` of each product config dir. Not in the adapters slice: no JetBrains IDE is installed on the team Macs, so there is no verified fixture yet.
  - Codex desktop app (also the ChatGPT app's Codex), source `codex-app`: `local-projects` (`rootPaths`, `updatedAt` ms) and `electron-saved-workspace-roots` in `$CODEX_HOME/.codex-global-state.json`. A project made in the app shows up before it has a chat; its chats still arrive as source `codex` through the chat index, and the two merge on the path.
  - t3code, source `t3code`: `projection_projects` (`workspace_root`, ISO `updated_at`, rows with `deleted_at` left out) in `~/.t3/userdata/statev2.sqlite`, else `state.sqlite`.
  - Conductor, source `conductor`: `repos` (`root_path`, `updated_at`, `hidden` rows left out) in `com.conductor.app/conductor.db`.
  - All three verified read-only against the installed apps on 2026-10-10. Claude Code (`~/.claude/projects`), the Codex CLI (`$CODEX_HOME/sessions`) and OpenCode come through the chat index (each chat's cwd).
- Each adapter has a red test with a fixture dir per OS layout (macOS, Linux, Windows paths), including a missing file and a corrupt file.

Single watcher rule: acpmux already watches the chat roots and the app already mirrors that index (`ChatsFeed`, one `_acpmux/chats_watch` push connection). The store starts no second watcher on them, and acpmux gets no daemon client: the app relays what the index says. On every index change, `ProjectsImport` (CmuxNextApp) groups the chats by harness, takes each cwd with its newest `updatedAt`, and sends one `project.observe {source: <harness>, entries, complete: true}` per harness whose set changed (content hash; no timer). It sends nothing while the index is still scanning or is turned off (`ready`/`enabled` false): a partial list sent as complete would drop the harness from its projects. The relay holds no rule: refusals, merge and the overlay live in the store. Strongest objection: the import stops while the app is closed. Accepted: the index is acpmux's and survives, so the next app start relays everything; a headless import can move into the daemon when acpmux moves in-process (cx-ncc.27).

The editor adapters (VS Code family, Zed, JetBrains, later t3code and Conductor) read a few small files under `~/Library/Application Support` (never a privacy-protected folder), so the store runs them itself in `cmux-tui-core::state::project_sources`, with crates it already has (`serde_json`, `rusqlite`, `quick-xml`): on `project.sync` (the app sends one per daemon connection, so at every app launch and daemon restart), and through file watches in slice 3. Each editor's list is `complete`; a missing or unreadable file sends nothing for that editor, so a file caught mid-write never drops its projects. Each yields `(path, source, last_used_ms)` into the same reducer.

## 4. Resync (event-driven, never a timer)

- At daemon start: one full scan of every enabled source.
- File watches (`state::project_watch`, landed): one `notify` watch, non-recursive, on each folder the editor and app sources read (VS Code family `globalStorage`, Zed `db/0-stable`, `$CODEX_HOME`, `~/.t3/userdata`, Conductor's folder). An event on a source file name (`state.vscdb*`, `storage.json`, `db.sqlite*`, `.codex-global-state.json`, `statev2.sqlite*`, `state.sqlite*`, `conductor.db*`; an atomic rename counts) drains the queued burst, rescans, and commits only the sources whose list changed since the last import. No quiet-period timer: the drain is the coalescing. A folder that does not exist at daemon start is read on the next `project.sync`. acpmux pushes chat changes as they happen.
- On app activation: the app rescans only the sources whose files changed since the last scan (mtime + size check), so a project made in the ChatGPT app while cmux was in the background shows on the next switch to cmux, and sends `project.sync {existing, gone}`: the disk facts it checked with its own privacy rules (PrivacyFolder; a protected folder is never stat'ed unasked). The store reads no disk for observed paths: a read inside a privacy-protected folder raises a macOS prompt attributed to cmux, and a stale network mount would stall the store's locks.
- No polling interval anywhere.

## 5. Merge rules (the reducer, invariant-tested)

1. A new path from any source: add it, `state = present`, the source's times set.
2. A known path: update that source's `last_seen_ms`/`last_used_ms` only. Never touch `overlay`.
3. `hidden` stays hidden on every resync; a hidden project is never re-added as visible.
4. A path that no source reports any more and that is gone from disk: `state = missing` (shown dimmed, removable). Never deleted automatically.
5. A `user` source is never dropped by a resync.
6. Disabling a source removes that source entry from every project; a project left with no source and no overlay is removed, one with an overlay (pinned, renamed) stays.
7. Paths are normalized lexically (absolute, no trailing slash, no `.`/`..`, the `/System/Volumes/Data` firmlink removed) and compared case-insensitively. Refused paths are never projects: `/`, the home folder itself, temp dirs, agent homes (cmux agent-home and each harness's own config dir), and anything the protected-folder rule refuses to look into is kept only if a source reported it, never walked (`acpmux/src/protected_folders.rs`, one copy).

8. At most 1000 projects: past it, the least recently used imports with no user edit and no `user` source are dropped first.

## 6. Ops (spec `resource-operations-v2.json`, capability `project-list-v1`)

- `project.list {query?, include_hidden?, limit?}` -> projects (section 2 shape).
- `project.observe {source, entries: [{path, last_used_ms}], complete?}` (acpmux and the editor adapters; at most 10000 entries, a `complete` source sends everything in one batch; a re-observe with the same times changes nothing).
- `project.sync {existing?, gone?}` (app activation; the app's disk facts, at most 10000 paths).
- `project.add {path}` (source `user`), `project.update {path, rename?, pinned?, hidden?, order?}`, `project.remove {path}` (drops `user`, sets `hidden` for a path a source still reports, so it does not come back).
- `project.source.update {source, enabled}` (landed): per-source on/off lives in the store (table `project_sources_off`), and `project.list` returns `sources: [{id, enabled, projects}]` for the Settings page. Off: the source leaves every project (one with no other source and no user edit goes) and its reports are ignored. On: an editor or app source is read again at once; a chat-index source returns with the app's next relay. Decision: the store, not `settings.projects.sources`, because the off state must hold against every writer (the app relay, the daemon's own import, a CLI `project.observe`) at the one place that merges; the Settings page writes it through this op.
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
