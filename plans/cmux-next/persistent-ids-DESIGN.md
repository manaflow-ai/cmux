# Persistent ids: every id cmux-next gives is kept for all time

Requested 2026-10-20 (user): "Ensure workspace IDs, terminal IDs, pane IDs, and all the types
of IDs that are generated are persistent for all time." Coordinates with a187
(classic migration), a284 (Chief move), a248 (updates keep sessions), a278 (restore), a316
(subagent workspaces).

## Rules

1. An id is minted once, when its object is first made, and stored in the same transaction
   that makes the object durable. Nobody sees an id that is not stored yet.
2. Restore, restart, update, adoption, move and crash recovery read the stored id. They never
   mint one for an object that already has one.
3. An id is never derived from an index, a counter that lives only in memory, a pid or a path.
4. A retired id is never given to a different object. (Bringing the same object back, for
   example Reopen Closed, is not reuse; see open decision D1.)
5. A failed random source never yields a fixed or empty id.

## Audit (2026-10-20, feat-cmux-next at b137834bfce)

Columns: R = cmux-tui restart, U = update / terminal-host adoption, S = session restore,
C = Reopen Closed, M = move between workspaces or windows, X = crash, CH = Chief move.
"yes" means the id survives unchanged.

### Session resources (cmux-tui, `crates/cmux-tui-core`)

| Kind | Minted | Stored | R | U | S | C | M | X | Status |
|---|---|---|---|---|---|---|---|---|---|
| workspace `ws_` | `resource.rs` `public_id!`; reserved in topology intents | `resource_workspaces` | yes | yes | yes | **new id** | yes | yes | C open (D1) |
| screen `screen_` | same | `resource_screens` | yes | fallback | yes | **new id** | yes | yes | C open |
| pane `pane_` | `mux.rs` `make_pane`, intents | `resource_panes` | yes | fallback | yes | **new id** | single-tab pane moved: new pane (by design, the old pane is gone) | yes | C open |
| tab `tab_` | `spawn_options.rs`, `resource.rs` | `resource_tabs` | yes | fallback | yes | **new id** | yes | yes | C open |
| terminal `term_` | `spawn_options.rs` | `terminals` (lifecycle, tombstones) | yes | yes; a host with no stored binding gets a new one | yes | kept only while still running | yes | yes | ok |
| browser `browser_` | `presentation.rs` | `resource_browsers` | yes | n/a | yes | **new id** (closed id is a tombstone) | yes | yes | C open |
| split `split_` | `split_ids.rs`, intents | topology | yes | n/a | yes | n/a | n/a | yes | ok |
| tab group `tgrp_` | `presentation_store.rs` | presentation | yes | n/a | yes | closed: kept; saved reopen: **new** | yes | yes | saved open |
| screen group `sgrp_` | `screen_store.rs` | screen store | yes | n/a | yes | closed: kept; saved reopen: **new** | yes | yes | saved open |
| saved groups `saved_` `ssaved_` | stores | stores | yes | n/a | yes | yes | n/a | yes | ok |
| workspace group `grp_` | `presentation_store.rs` (app mints for sidebar) | personal groups | yes | n/a | yes | yes (archive) | n/a | yes | ok (app undo: see Swift) |
| space `prof_` | `personal_mutations.rs`, app `StringIDs.swift` | profiles | yes | n/a | yes | yes | n/a | yes | app retry: see Swift |
| sidebar item `itm_` | `sidebar_doc_legacy.rs` | sidebar doc | yes | n/a | yes | n/a | n/a | yes | **fixed**: random failure gave every item `itm_` |
| closed record `closed_` | `closed_history_store.rs` | `closed_groups` | yes | n/a | n/a | n/a | n/a | yes | ok |
| notification (durable string id) | registry | registry | yes | yes | yes | n/a | n/a | yes | ok |
| notification numeric handle | `public_projections.rs` (`index + 1`) | not stored | **renumbered** | | | | | | handle, not an id; the app must key on the string id (Swift S3) |
| legacy numeric `id` / `short_id` of screen, pane, tab | `restore.rs` from `max(workspace numeric_id)+1` | not stored | **renumbered and reused** | | | | | | open (D2) |
| machine `machine_`, session `session_` | registry | machine-id file, meta | yes | yes | yes | n/a | n/a | yes | ok |
| journal checkpoint | content digest | journal | yes | yes | n/a | n/a | n/a | yes | ok |
| git checkpoint `ckpt_` | `checkpoint/store.rs` | store | yes | n/a | n/a | n/a | n/a | yes | ok; `repo_`/`wt_` keyed by path, new after a folder rename (by design) |
| stream `stream_` | per connection | not stored | n/a | | | | | | ok (per connection by design) |

### Agents (acpmux, Chief host, tasks)

| Kind | Minted | Stored | Restart | Chief move | Crash | Status |
|---|---|---|---|---|---|---|
| subagent `a<N>`, spawn `s<N>` | `optchat-chief/src/brain/spawns.rs` | `HostState.next_subagent` in `memory.sqlite3` | **reset to 0 when the field reads back unreadable or missing: `a1` again** | moves with the database | **ids handed out even when the save failed** | **fixed** |
| Chief home id (acpmux tags, preset and session name prefixes) | `optchat-chief/src/paths.rs` | **not stored: FNV of the `MUX_HOME` path** | yes | **changes**: the Chief loses its own sessions | n/a | **fixed**: kept in `optchat/home-id` |
| Chief `agent_` | `chief_registry.rs` | SQLite with tombstones | yes | yes | yes | ok |
| conversation `conv_`, message `msg_` | `conversation_store.rs` | SQLite, `synchronous=FULL` | yes | yes | yes | ok |
| acpmux session id (UUIDv7) | `acpmux/src/hub/lifecycle.rs` | `session.json` | yes | kept by transfer | **`write_atomic` never synced** | **fixed**: file and directory synced |
| acpmux session name (`agent`, `agent-1`…) | `hub/new_request.rs` lowest free | `session.json` | **reused once purged or unreadable** | `-N` suffix | | open (D3) |
| acpmux sub-session short name | `hub/subsessions.rs` | in memory | **reused after a daemon restart** | | | open (D3) |
| ACP harness session id | the harness | meta `agentSessionId` | **new id when a resume or `session/load` fails** | | lost between `session/new` and the save | open (D4) |
| CLI / UniiChat ACP session id `cli-<pid>-<n>` | `cli/cli_agent.rs`, `cli/uniichat_agent.rs` | not stored | **pid reused** | | | open (D4) |
| task `task_` | `cmux-tasks/src/engine.rs` (hash of actor and key from `owner.rs` `mint`) | task store | yes | yes | yes | **fixed**: a failed random source left 8 zero bytes, two mints in one ms made one task |

### App (Swift, `Packages/macOS/CmuxNext`)

| Kind | Minted | Stored | Status |
|---|---|---|---|
| window `win_` | `UUID()` in `WindowManager*.swift`, `win_` from `ControlTopology.swift` | daemon window-state document | S1: a failed `load()` (`WindowManager.swift` `restore`) becomes an empty document and the first save overwrites every stored window id. S2: the launch window shows a random id until `adoptLaunchWindow` re-keys it. Open |
| notification banners | numeric handle | | S3: banner ids, `lastSeen`, approvals keyed by the per-generation numeric handle; after a daemon restart new notifications at or below the old maximum are dropped. Open |
| workspace group on undo | `WorkspaceGroupUndo.swift` `newID: .make()` | | S4: undo with no closed-history entry gives a new `grp_`. Open |
| space `prof_`, `grp_`, `itm_` from the app | `StringIDs.swift` `ProfileID.generate()` | | S5: not derived from `DaemonCommandScope.nextDerivedUUID`, so a replayed request makes a second object. Open |
| classic migration | `ClassicMigration*.swift` | `ledger.json` | M1 lost ledger duplicates everything; M2 migrated windows get `UUID()` per run (classic `windowId` not mapped); M4 lost "created" write leaves one duplicate. Open, a187 |
| Home pins, browser profiles, conversations, Chiefs | daemon / defaults | | ok |

## Fixes landed in this change

- `a<N>` never repeats: the next id is `max(stored counter, highest a<N> in any recorded spawn + 1)`,
  and a spawn whose save fails returns an error and hands out no id.
- The Chief home id is written once to `optchat/home-id` at host start (its value is the path
  hash every home already had, so live sessions keep their names). A moved home keeps it.
- acpmux `write_atomic` syncs the file before the rename and the directory after it.
- `cmux-tasks` `mint` and the sidebar `itm_` mint never yield a fixed id when the OS random
  source fails.
- CI guard: `state/persistent_ids_tests.rs` seeds one of every session id kind (`ws_ screen_
  pane_ tab_ term_ tgrp_ sgrp_ grp_ prof_`), restarts the daemon twice and fails on any id
  lost or minted. `optchat-chief/tests/persistent_ids.rs` restarts the Chief host with a lost
  counter and moves a home. Existing guards that stay: `mux/host_death_tests.rs` (topology
  identical across restarts), `cmux-tui/tests/terminal_host_recovery.rs`
  (`interrupted_public_creation_publishes_once_and_replays_stable_ids_after_two_restarts`).

## Open decisions (defaults picked; next slices)

- **D1 Reopen Closed keeps ids (default: yes).** Today `closed.reopen` builds the workspace,
  screens, panes and tabs again through the create paths, so every id is new, and the registry
  refuses to resurrect a tombstoned `ws_`, `term_` or `browser_` on purpose. Plan: record the
  closed object's ids in its closed record (already there), pass them as requested ids to the
  create paths (`requested_public_id` exists for workspaces, `tab_id`/`pane_id` for splits), and
  add one registry path, `resurrect`, that clears the tombstone of the same object only when the
  closed record names it. Clients get an upsert after the delete, the same as a create. A
  reopened terminal keeps its `term_` with a new incarnation. Saved tab and screen groups store
  the live group id and reuse it when no live group holds it.
- **D2 Numeric handles.** The legacy `id`/`short_id` of screens, panes and tabs are renumbered
  at each start. Default: store them like workspace numbers, or mark them per-generation in
  the v1 API and never show them as ids.
- **D3 acpmux names.** Default: keep every name ever given in a stored `names` ledger and never
  give one twice (sessions and sub-sessions).
- **D4 ACP session ids.** Default: a failed resume keeps the cmux session id and records the
  new harness id beside the old one, so the chat index joins both; CLI agents mint UUIDv7
  instead of `cli-<pid>-<n>`.
- **Swift S1-S5, M1-M4.** Default: S1 retry the load and never save over a document that did
  not load; S2 adopt the saved id before the window is reported; S3 key banners and `lastSeen`
  on the durable notification id; S4 reuse the group id from the undo record; S5 derive ids
  from the command scope; M2 map the classic `windowId` in the ledger.
