# Swift to Rust audit (cmux-next, 2026-10-30)

Scope: every Swift type in `Packages/macOS/CmuxNext/Sources` (115 modules, about 700k lines,
the largest `CmuxNextApp` at 160k) and the shared `Packages/Shared` cores that hold **state or
non-view logic**. Pure SwiftUI/AppKit views are out of scope. Two questions per type:

1. Should it move to Rust, either **in process** (the app's one static library,
   `cmux-tui/crates/cmux-app-ffi`) or **into a daemon** (cmux daemon `cmux-tui-core`, or acpmux)?
2. Who owns its state, is that the only source of truth, and how far does a change fan out?

Rule of thumb used below: state that a Rust process already owns should not have a second
reducer in Swift. Swift keeps what is bound to AppKit, WebKit, CEF, Ghostty, Sparkle or the
Keychain, and the view models that project daemon state for one window.

## Findings in one paragraph

Swift already uses `@Observable` everywhere: there are zero `ObservableObject`/`@Published` left
in CmuxNext. The problems are elsewhere:

- **Swift mirrors of Rust state that add their own reducer.** Examples: the acpmux chat index,
  the turn and lane stores, the optimistic tree overlay, the old sidebar path, settings, history
  and bookmarks.
- **Logic implemented twice.** History, omnibox scoring, the bookmark edit rules, JSONC editing,
  the close-focus rules and phone permissions all exist in both Swift and Rust.
- **Status derived in Swift from mirrors that can go stale.** `StatusMapping` and the
  terminal's "Restoring…" are examples.
- **Too many `static let shared` singletons:** 141 in all.

The first item on the plan below is in progress. The Rust ACP chat index mirror has landed. The Swift switch onto it
(commit 336867f0ae20) lands with the next `CCmuxAppFFI` re-pin, because the app links the published library.

## First item: the ACP chat index mirror in Rust

| | Before (Swift `AcpmuxChatsStore` value) | After (`cmux-chats-mirror` through `CCmuxChatsMirrorFFI`) |
|---|---|---|
| Page decode, 5,000 chats, 3.3 MB (off main) | 36.4 ms median, 42.4 ms p95 | 5.2 ms median, 6.6 ms p95 (3.8 ms in Rust alone) |
| One change on the main actor, as the app was wired | **540 µs median, 1,129 µs p95** | **0.29 µs median, 0.75 µs p95** |
| Burst of 2,000 changes on the main actor | 1,261 ms | 0.73 ms |
| Mirror heap | 6.7 MB, plus a 4.2 MB `JSONSerialization` graph during each decode | 4.8 MB, no graph |
| Project list on each change | regrouped all 5,000 chats on every reply preview | only when membership changes (`generation`); 1.0 ms |
| `newest(24)` read | 4.8 µs | 12.8 µs (rows are converted to Swift structs) |
| Every chat read (palette chats page) | 1.2 ms | 2.8 ms |

Fixture: 5,000 synthetic chats in the daemon's `chat_value` shape, plus 2,000 changes (80%
activity, 15% upsert, 5% removal). The generator is
`cmux-tui/crates/cmux-chats-mirror/examples/fixture.py`; the Rust timings come from
`cargo run --release -p cmux-chats-mirror --example bench -- DIR`. The Swift timings come from
`swiftc -O` builds of the old and new store files, on an Apple M5 Max, macOS 27.0. In both, heap
is measured with `malloc_zone_statistics`.

**The root cause of the 540 µs was not Swift itself.**

- `SidebarChatHistoryFeed.chats` held the previous copy-on-write value of the store
  (`history.chats = feed.store` on each publish).
- So every `store.apply(change)` on the main actor copied the whole dictionary and key order:
  5,000 chats, about 75,000 refcounted strings.
- Activity changes (each agent reply's preview) are the most frequent kind, so this ran
  constantly while agents worked.
- `ProjectsImport` had the same hazard: a comment in its source warned about it.

The Rust mirror removes the whole class of bug. There is one owner, readers share a
reference, and Rust applies every change in place under its own lock. Line decode moves to
`serde` off the main actor. The seq, lag and early-change state machine, which had no Swift test,
now has 15 Rust tests.

**What changed in Swift.** The public API is the same: `chats`, `count`, `chat(id:)`,
`newest(_:)`, `newestFirst`, `reset(_:)` and `filtered(query:grouping:)`, plus `chat(sessionID:)`,
`projects()` and `generation`. Three things are different:

- `AcpmuxChatsStore` is now a `final class`, not a value. It is `@unchecked Sendable` because
  Rust locks inside.
- `ChatsFeed` lost its own seq bookkeeping.
- The sidebar history reads the feed's own store and observes a `revision` counter.

Trade-off: whole-list reads are slower (conversion from rows), but only the palette chats page
does them. Converting rows directly into palette items is the next step if that page ever shows
up in a trace.

## Inventory

Legend for cost and risk: S, M or L. "Mirror of" names the Rust owner of the same state.

### Agents, chats, Home (CmuxNextAgentPane, AgentLanes, AgentActivity, Bridge, Home, HomeEngine, HostedChief, Feed)

| Type | File | State | Owner | Mirror of (Rust) | Publishes | Recommendation |
|---|---|---|---|---|---|---|
| `AcpmuxChatsStore` + `ChatsFeed` | AgentPane/AcpmuxChatsStore.swift, App/AgentRecents/ChatsFeed.swift | chat index (5,000), seq | `AppServices.chatsFeed` | acpmux `ChatIndex` (cmux-chat-index) | callback list | **Done: Rust in process** |
| `SidebarChatHistoryFeed` | AgentLanes/SidebarChatHistoryFeed.swift | second copy of the index | `.shared` | same | ObservationStream over workspaces, lanes, pins | **Done:** shares the feed's store, no copy |
| `ProjectsImport` | App/Projects/ProjectsImport.swift | sent fingerprints | AppServices | relays acpmux to cmux daemon `project.observe` | feed observer | **Done:** skips activity, groups in Rust. Next: move the relay into the daemon (M) |
| `AgentTurnStateStore` | Bridge/AgentTurnStates.swift:224 | turn state, last message, title per session | `.shared` | acpmux `indicator`, `Lane.title` | per-session cells + `stateRevision` | Merge with `AgentLaneStore`; delete the Swift title rules (M) |
| `AgentLaneStore` (+cells) | AgentActivity/AgentLaneStore.swift | `[session: lane]` | `.shared`, `.chief` | acpmux `Lane` | whole map + cells; `syncCells` O(cells) per event | Keep as the one session mirror. Parse `_acpmux/watch` in Rust the way chats are now (M) |
| `AgentTurnStateFeed` | AgentLanes/AgentTurnStateFeed.swift | the watch socket | `static var shared` + 4 static hooks | acpmux `_acpmux/watch` | writes 2 stores | Inject; one store (S) |
| `StatusMapping` | Bridge/StatusMapping.swift | merges hook roster, OSC 7501, acpmux indicator, a client clock | `.shared` | cmux-tui-core roster + `program_status.rs` | read by every spinner | **Move the merge into cmux-tui-core** and publish one tab status (M) |
| `SidebarSessionTreeFeed`, `AgentSessionParents`, `RemoteAgentSessionLinks` | AgentLanes/, AgentPane/ | lineage in 4 places (UserDefaults included) | `.shared` | acpmux `spawned_by` | ObservationStream over every tab | Lineage from acpmux only; tree reduction via FFI (M) |
| `AgentPriorityChats` / `SidebarPriorityFeed` / `AgentPriorityMarks` | AgentLanes/ | marks, ranking | per window | "read" overlaps acpmux `unread` | sorts all lanes per lane change | Ranking via FFI, marks into acpmux (M) |
| `RemoteMachinesSidebar`, `ChiefSidebar` | AgentLanes/ | peers, Chief badge | `.shared` | acpmux peers, lanes | 2 s debounce; O(n) lanes scan | Keep (S fixes) |
| `HomeService` | App/Home/HomeService.swift | conversations, cloud Chiefs, sessions | composition root | daemon `local-conversations-v1`, `home-inbox-v1` | ~15 ObservationStream loops | Delete `conversations` and `sessions` (third mirror) (M) |
| `HomeConversationSession` | HomeEngine/ | per-conversation mirror + intents | HomeService | daemon conversation | observers | Delete: no external caller of `send`/`retry` (S) |
| `HomeStore` (+`HomeMirror`, `IntentLog`, `HomeLiveBook`) | Shared/CmuxHomeCore | rows, transcripts, drafts, live runs | HomeService; iOS too | daemon / cloud ConversationDO (cmux-conversation) | `rows`, `transcriptVersion` | Keep for now (shared with iOS); long term cmux-mobile-core FFI (L, high) |
| `HomeSidebarSource` / `unreadConversations` | HomeEngine/HomeSidebarSource.swift:222 | pins, unread, query | HomeService + per page | daemon `home_inbox` merge | rebuilt in full on every read, per window and per tab | Memoize now; daemon computes it later (M) |
| `HomeDirectory` | App/Home/HomeDirectory.swift | members, Chiefs | HomeService | API `chief.list` (read in 3 places) | @Observable | Merge with `cloudChiefs` (S) |
| `FeedModel` | Feed/FeedModel.swift | confirmed items, intents | Feed page | cmux-feed-core | @Observable + listeners | Move the local owner into the daemon (M) |
| `AgentPaneModel`, `DaemonUpdateBoard`, `AgentCLIUpdateActions`, `ChiefConversationOwner`, `HomeInboxSource` | various | view state, update UI, Chief link | per pane / root | — | @Observable | Keep |

### Daemon tree, sidebar, layout, terminal, settings (CmuxNextDaemon, Sidebar, Layout, Tabs, Terminal, Settings, Hibernation, Tasks, History)

| Type | File | State | Owner | Mirror of (Rust) | Publishes | Recommendation |
|---|---|---|---|---|---|---|
| `DaemonStore` (+records) | Daemon/Store/DaemonStore.swift | whole tree, unread, `sidebarSections`, presence | `DaemonService.store` per machine | cmux-tui-core `state.rs` | fine-grained @Observable records | Keep as a read-only mirror; delete `sidebarSections` (M) |
| `IntentOverlay` + `Provisional*` | Daemon/Store/IntentOverlay.swift, ProvisionalSplit.swift (~1,800 lines) | optimistic tree overlay | DaemonStore | re-implements `split_kind.rs` / cmux-layout-reducer | mutates records | **Rust in process** over a mirror handle like `SidebarMirror` (L, high) |
| `SessionStateStore` / `SessionStateMirror` | Daemon/Store/, State/ | closed history, status, checklist | DaemonStore | daemon `session.events` | guarded @Observable | Keep (pure cache) |
| `SidebarDocStore` + `SidebarMirror` | Sidebar/Store/ | sidebar document, pending intents (Rust) | SidebarBridge | cmux-layout-reducer `sidebar_doc` (FFI) | @Observable `version`; NotificationCenter refused/settled | **Keep: this is the pattern to copy** |
| `SidebarEdits` / `SidebarPendingEdits` / `KeyboardReorder` | Sidebar/Logic/ | Swift tree reducer + pending edits | SidebarModel | duplicates `sidebar_drop` / `sidebar_doc` | — | **Delete** once `SidebarDocStore.isActive` is always on (S–M) |
| `SidebarModel` | Sidebar/Model/SidebarModel.swift | sections, selection, folds | per window | partly the daemon tree | revisions + callbacks | Keep the view state; feed only from `SidebarDocStore` (M) |
| `ClosingWorkspaces`, `PendingWorkspaceRows`, `WorkspaceLanes` | Sidebar/Logic/, App/Windows/, DaemonService/ | hidden or stand-in rows, create/close queues | `.shared` | shadow daemon membership | @Observable | Fold into DaemonStore intents; daemon numbers creates in order (M) |
| `LayoutModel` | Layout/Model/LayoutModel.swift | screens copy, `focusedPane`, overrides | per workspace view | tree; focus also in `FocusMachine` (Rust) | @Observable | Keep gesture state; read focus from FocusMachine (M) |
| `TabStripModel`, `SavedGroupsBarModel` | Tabs/ | copies of `PaneModel.tabs`, saved groups | per pane | daemon tree | whole-array observation | Bind to the pane model directly (S) |
| `SettingsController` + `CmuxConfigFile` + `JSONC` | Settings/ (~3,400 lines) | parsed snapshot, managed keys, file writes | composition root | **cmux-config + cmux-tui-core `mux/settings.rs`**: two writers of one file | @Observable → `DesignSettings` | Become a client of the daemon's `settings.*`, or link cmux-config in process (L, high: MDM, migrations) |
| `DesignSettings` | Design/DesignSettings.swift | every live design setting | `.shared` | derived from cmux.json | one object read in 173 places in 87 files | Split by domain (M) |
| `TerminalAttachMachine` / `ContentLifecycle` | Bridge/ | link phase, "Restoring…", backoff | DaemonTerminalIO / App | client-derived; the daemon knows if the terminal runs | effects | Status from the daemon; port the machine next to cmux-terminal-client (M) |
| `TasksModel` | Tasks/TasksModel.swift | mirror, intents | host view | cmux-tasks-core | @Observable | Reducer via FFI (`tasks_preview` already crosses it) (M) |
| `BrowserVisitLog` + `HistorySQLite` | History/ | app-local visits SQLite | HistoryService | **cmux-history (daemon owns visits, R62)** | actor | Record through the daemon, then delete (M) |
| `WindowStateStore`, `SidebarSnapshotStore` | Daemon/Projection/, App/SidebarSnapshot/ | window doc, launch sidebar | DaemonService / root | daemon window-records, launch snapshot | — | Merge the snapshot into the daemon's launch snapshot (M) |
| `GhosttyRuntime`, `TerminalSession`, `WorkspaceHibernation`, `DaemonService`, `DaemonRecovery` | various | Ghostty, process, connection | root | — | — | Keep (OS-bound) |

### App, browser, control, cloud (CmuxNextApp, Browser*, Control, Actions, Palette, Cloud, Server, Mobile, Updater)

| Type | File | State | Owner | Mirror of (Rust) | Recommendation |
|---|---|---|---|---|---|
| `HistoryService` + `CmuxNextHistory` (`HiddenHistory`, `AgentSessionFold`, `HistoryQuery`, `HistoryEntry`), `AgentHistory`, `CommandHistory`, `HiddenHistoryStore` | App/History/, History/ (~750 lines) | local history path for daemons without `history-v1` | AppServices | **cmux-history** type for type | **Delete** the fallback (S–M) |
| `InMemoryBrowserHistory`, `OmniboxQuickIndex`, `OmniboxQuickScore`, `BrowserHistoryRanker`, `BookmarkRanker`, `TabSearchRanker` | Browser/Omnibox/ (~3,700 lines) | 20k-URL index, scoring | omnibar | cmux-history `VisitStore`, `search_index.rs` | **Rust in process** through a history FFI (M, perf-sensitive) |
| `BookmarkService` + `BookmarkTree+Apply` + `BookmarkFileStore` | App/Bookmarks/ | trees + a JSON fallback | AppServices | cmux-tui-core `personal_bookmarks/ops.rs` | Delete the fallback and the Swift edit rules (S) |
| `LocalPaletteUsageStore` | Palette/PaletteUsageStore.swift | usage history | App | daemon `palette-usage-v1` | Delete (S). The ranker is already Rust (`PaletteRankerBridge`). |
| `CmuxSyncStore` | Shared/CmuxSyncStore (1,661 lines) | SQLite sync mirror | **nothing links it** | cmux-cloud-wire `mirror.rs` | **Delete** (S) |
| `FocusAfterClose` | App/Focus/FocusAfterClose.swift:55,118 | tab/workspace close-focus rules | — | cmux-focus-core has only the pane rule | Move into cmux-focus-core (S) |
| `DaemonLanePolicy` | Mobile/DaemonLane/DaemonLanePolicy.swift | phone command allowlist | — | `cmux-tui/src/link/inbound.rs` authority | Move into the daemon (M, security) |
| acpmux clients (`AcpmuxConnection`, `AcpmuxCheckedLine`, `AcpmuxMailboxClient`, `AcpmuxSocketTransport`, `AcpmuxPaneSocket`, …) | AgentPane/ and ~22 modules | 8+ line-protocol clients | various | acpmux protocol | Collapse into one client (M) |
| `ControlSocketServer` / `ControlRouter` / `ControlSnapshotPublisher` | Control/, App/Control/ (~15k) | the app's own v2 socket | AppServices | a second control plane beside the daemon | Keep (it drives AppKit); stop growing it |
| `AppServices`, `WindowRegistry`/`WindowManager`, `TabContentCache`, `PaneController`, `SidebarBridge`, `KeyRouter` | App/ | composition, windows, surfaces | root | — | Keep; split `AppServices` (81 services) (M) |
| `CloudService`, `MachineRegistry`, `CloudAuth`, `CloudCodexBroker`, `SSHService`, `UpdaterService`, `CEFRuntime`, `MobileHostSupervisor`, `RemoteLocalhostService`, `SitePermissionStore` | various | network, Keychain, Sparkle, CEF, processes | root | — | Keep |

## State ownership and reactivity

### Duplicate sources of truth (one fact, two writers or two reducers)

1. **The chat index was held twice** (feed and sidebar history). Fixed here.
2. **One acpmux watch fills two Swift stores.**
   - It writes `AgentTurnStateStore` (from `indicator`) and `AgentLaneStore` (from `lane`).
   - `AgentChatDetail.laneState` holds a third copy.
   - Session lineage lives in four places: `startedBy`, `AgentLaneLinks`, `AgentSessionParents`
     (UserDefaults) and `RemoteAgentSessionLinks`.
3. **Home conversations are mirrored three times:** `HomeService.conversations`,
   `HomeStore.rows` and `HomeInboxSource.reply`. On top of that, `HomeConversationSession` keeps a
   transcript mirror per conversation. `chief.list` is read into three places.
4. **Sidebar order has three paths:** `DaemonStore.sidebarSections`, the Swift
   `SidebarEdits`/`SidebarPendingEdits` reducer, and the Rust `SidebarMirror`. The switch between
   them is `SidebarDocStore.isActive`.
5. **The optimistic tree overlay** is a Swift re-implementation of the Rust layout reducer.
   `DaemonStore+MirrorCheck.swift` exists only to catch drift between the two.
6. **Settings** have two writers and two JSONC parsers of `cmux-next.json` (Swift `CmuxConfigFile`
   and the daemon's `mux/settings.rs`). Swift never reads `settings-changed`.
7. **Fold state lives in four places:** the sidebar document, `SidebarCollapsedSections`
   (UserDefaults), `SidebarSessionTree.collapsed` (UserDefaults) and `SidebarSnapshot` on disk.
8. **Focus:** `LayoutModel.focusedPane` sits next to the Rust `FocusMachine`.
   **Selected tab:** `TabSelectionMemory` sits next to the daemon's `active_tab`.
9. **History, bookmarks and palette usage** have local fallback stores that pick a store per write.
   A daemon that gains the feature mid-session strands the local rows.

### Fan-out hot spots (one change wakes many readers, or O(n) work per change)

- **Chats feed publish.** Before this change it cost a full index copy per drain. Fixed. It still
  pushes `newest(24)` to every open agent pane view on each change (`AgentPageChats.follow`);
  skip the push when the 24 are unchanged.
- **`HomeService.unreadConversations`** builds a whole `HomeSidebarModel` on every read, per
  window, per Home tab and for the Dock count.
- **`AgentLaneStore.syncCells`** walks every cell on each `session_changed`. It also invalidates
  every reader of the whole map.
- **`SidebarPriorityFeed.panel()`** sorts and ranks all lanes on any lane change, once per window.
- **Whole-store ObservationStream readers** re-scan on every agent event: `ChiefSidebar`,
  `SidebarChatHistoryFeed` (walks every tab of every workspace) and `SidebarSessionTreeFeed`.
- **`DaemonStore`.**
  - `recomputeSidebar` is O(workspaces × groups) per structural change.
  - The `workspaces` `didSet` runs `adoptUnread()` over every workspace.
- **`DesignSettings.shared`** is one observable read in 173 places. Any key wakes every reader.
- **`TabStripModel.tabs`** is observed as a whole array, and `orderedTabs` normalizes O(n) on each
  access.
- **Hand-written listener lists and NotificationCenter broadcasts** filter per receiver. Examples:
  `browserChildWindowPagesNeedUpdate`, `GhosttyRuntime.configDidChange`, and SidebarDocStore's
  refused/settled notices.

### Stale-status risks

- **`StatusMapping`** merges four facts in Swift (the hook roster, OSC 7501 records, the acpmux
  indicator and a client-clock busy timer). 8a2b6905 fixed the idle spinner by dropping
  `working` records older than the latest hook. Three risks remain:
  - A record without `updatedAtMs` is treated as `.max`, so a stale `working` wins forever.
  - `outcome()` skips `current()`.
  - The recheck timer runs on the client clock.

  The daemon owns all four inputs and should publish one tab status.
- **"Restoring…" is decided by the client.**
  - `TerminalAttachMachine` holds `.restoring` through up to 45 quiet retries.
  - A hidden restored view waits with no deadline.
  - `ContentLifecycle` in `.restoring` waits for a completion that may never come.
- **`ClosingWorkspaces`** hides a row for as long as the daemon is unreachable.
  **`PendingWorkspaceRows`** orphans rows when a create reply is lost.
- **The Chief watch** never marks itself as not watching, so a dead watch reads as "idle" rather
  than "unknown".
- **`HomeLiveBook`** keeps a live bubble until `resync` when a run's last frame is lost.

### Singletons

There are 141 `static let/var shared` in CmuxNext. The project rules forbid ones that hold
runtime state. The ones that matter most:

- `AgentTurnStateStore`, `AgentLaneStore`, `AgentTurnStateFeed`, `StatusMapping`
- `SidebarChatHistoryFeed`, `SidebarSessionTreeFeed`, `SidebarChatHistory`, `SidebarSessionTree`
- `ChiefSidebar`, `RemoteMachinesSidebar`
- `ClosingWorkspaces`, `PendingWorkspaceRows`, `WorkspaceLanes`
- `DesignSettings`, `GhosttyRuntime`
- `DaemonUpdateBoard`, `AcpmuxMacApprover`, `AcpmuxPeerReconnects`, `AppProcessRoot`

About 25 of the 141 are stateless catalogs and are fine.

## Ranked migration plan

Ranked by main-thread time or bug class removed, per unit of cost. Every step follows one
pattern, the one already used by `SidebarMirror` and now the chats mirror:

- the Rust owner (a daemon, or a pure crate in cmux-app-ffi) holds the state and the reducer;
- Swift holds one handle and asks for rows;
- the step lands with failing tests first and before/after numbers.

| # | Item | Where it goes | Cost | Why first |
|---|---|---|---|---|
| 1 | ACP chat index mirror | Rust in process (`cmux-chats-mirror`) | M | **Rust landed; Swift switch lands with the re-pin.** 540 µs → 0.3 µs per change on main; 1.26 s → 0.7 ms per 2,000-change burst |
| 2 | Tab status merge (`StatusMapping`) | cmux-tui-core publishes one status per tab | M | Removes the stale-spinner bug class (a868, 8a2b6905) at the source |
| 3 | acpmux session watch (`AgentTurnStateFeed` → one store) | Rust in process, same shape as the chats mirror; delete the Swift title rules | M | Per-event O(cells) `syncCells` and whole-map invalidation; two stores fed by one watch |
| 4 | Delete Swift duplicates | — | S each | `CmuxSyncStore` (orphan), the history fallbacks, `LocalPaletteUsageStore`, the bookmark file fallback, `HomeConversationSession` and `HomeService.conversations`/`sessions`, the old sidebar path (`SidebarEdits`, `SidebarPendingEdits`, `sidebarSections`). About 5k lines and 4 duplicate truths |
| 5 | `unreadConversations` | memoize now; the daemon's `home_inbox` computes it | S then M | Full model rebuild per window per read |
| 6 | Terminal "Restoring…" | status from the daemon; `TerminalAttachMachine` next to cmux-terminal-client | M | Stuck-pane bug class (a792, a821) |
| 7 | Optimistic tree overlay | `cmux_layout_reducer` over a mirror handle | L | Removes the reducer copy and the drift checker |
| 8 | Omnibox index and scoring | cmux-history `search_index` through FFI | M | 3.7k lines of Swift ranking over 20k URLs |
| 9 | Settings | daemon `settings.*` client (or cmux-config in process) | L | Two writers of one file |
| 10 | `ProjectsImport`, `AgentSessionParents`, priority marks | into acpmux / the daemon | M | The app relays between two Rust processes |
| 11 | `DaemonLanePolicy`, close-focus rules | daemon / cmux-focus-core | S–M | Security rules in one place |

**Keep in Swift:**

- AppKit, WebKit, CEF and Ghostty owners: window, surface and tab content caches, `CEFRuntime`,
  `GhosttyRuntime`, `TerminalSession`
- Sparkle (`UpdaterService`), Keychain auth (`CloudAuth`), process supervisors
- per-window view models (`SidebarModel`, `LayoutModel` gesture state, `PaletteModel`)
- the app's control socket, which drives AppKit
- `HomeStore`, until iOS can share a Rust core through cmux-mobile-ffi

## How the chats mirror is built (the pattern for the next items)

- **Crate:** `cmux-tui/crates/cmux-chats-mirror`. It is pure (no I/O) and in the cmux-tui
  workspace. Its parts are `Line::parse`, `Feed::apply`, `Index`, and a C ABI in `src/ffi.rs`
  with the header `include/cmux_chats_mirror.h`. The tests are in `tests/mirror.rs`, red first
  in aaa31184e323, then green in 123cfaa557f2.
- **Linked through cmux-app-ffi** as module `CCmuxChatsMirrorFFI`, so there is still one Rust
  runtime in the app. Four files list it: `build-app-ffi.sh`, `app-ffi-release.yml` (test, smoke
  link, header parity), `macos-cross.sh` and the license gate.
- **Release:** the app pins the published `CCmuxAppFFI.xcframework`. A Rust change lands first;
  `app-ffi-release.yml` publishes it, and then the Swift change lands together with the re-pin.
- **Swift:** `AcpmuxChatsStore` (CmuxNextAgentPane) wraps the feed. Lines are parsed on the
  socket queue (`AcpmuxChatsStore.Line`) and applied on the main actor. Readers get owned row
  snapshots.
