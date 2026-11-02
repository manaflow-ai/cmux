# Swift to Rust audit (cmux-next, 2026-10-30)

Scope: every Swift type in `Packages/macOS/CmuxNext/Sources` (115 modules, about 700k lines,
the largest `CmuxNextApp` at 160k) and the shared `Packages/Shared` cores that hold **state or
non-view logic**. Pure SwiftUI/AppKit views are out of scope. Two questions per type:

1. Should it move to Rust? Per the binding
   [layer-ownership.md](../plans/cmux-next/layer-ownership.md), state, lists, sort, filter and
   rules go **into the daemon** (cmux-tui-core, or acpmux for agent sessions), and a native list
   holds only its visible window. **In process** (`cmux-tui/crates/cmux-app-ffi`) is only for pure
   reducers that compute an optimistic view or a gesture (checklist step 6), never for a mirror.
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

The first item on the plan below, the ACP chat index, is done by
[#28055](https://github.com/manaflow-ai/cmux/pull/28055) (9962e57684c3): acpmux owns the list
(`_acpmux/chats_window`), and the sidebar history holds only its window. The in-process Rust
mirror this audit first built was dropped: it is a client mirror, which the layer rules forbid.
The numbers below still measure the root cause both fixes remove.

## First item: the ACP chat index (done by #28055)

**Root cause** (the v2.2.9 hangs of 570 to 1,148 ms in `AcpmuxChatsStore.apply`):
- `SidebarChatHistoryFeed.chats` held the previous copy-on-write value of the store.
- So every change on the main actor copied all 5,000 chats (about 75,000 refcounted strings).
- Activity changes (each agent reply's preview) are the most frequent, so this ran constantly.

Measured on a 5,000-chat fixture with 2,000 changes (80% activity), on an Apple M5 Max, macOS 27.0:

| | Swift store as wired | Without the second holder |
|---|---|---|
| One change on the main actor (median / p95) | **540 / 1,129 µs** | under 1 µs (in-place apply) |
| Burst of 2,000 changes on the main actor | 1,261 ms | under 1 ms |
| Page decode (`JSONSerialization`, off main) | 36 ms, plus a 4.2 MB temporary graph | 4 to 5 ms with `serde` |

[#28055](https://github.com/manaflow-ai/cmux/pull/28055) fixed it the way the layer rules want:
- acpmux sorts, filters and pages each window;
- one change is a diff of one row;
- acpmux groups the projects per harness (since A14 the daemon reads them; the Swift `ProjectsImport` relay is gone).

ChatsFeed's private mirror (palette chats page, Open Chat, cookie import, New Tab cards) remains.
Removing it is P-RUST step 2 and is item 1 of the plan below.

**Dropped:** this audit first built `cmux-chats-mirror`, the same mirror as a Rust crate linked
into the app. Its FFI link was reverted in 643cd1a81f64, because it was pushed without a pinned
release. The crate is deleted here: with #28055 it has no consumer, and it would keep a whole
client-side index that layer-ownership.md rule 2 forbids.

## Inventory

Legend for cost and risk: S, M or L. "Mirror of" names the Rust owner of the same state.

### Agents, chats, Home (CmuxNextAgentPane, AgentLanes, AgentActivity, Bridge, Home, HomeEngine, HostedChief, Feed)

| Type | File | State | Owner | Mirror of (Rust) | Publishes | Recommendation |
|---|---|---|---|---|---|---|
| `AcpmuxChatsStore` + `ChatsFeed` | AgentPane/AcpmuxChatsStore.swift, AgentLanes/ChatsFeed.swift | chat index (5,000), private to the feed | `AppServices.chatsFeed` | acpmux `ChatIndex` (cmux-chat-index) | callback list | Windows done (#28055); delete the remaining mirror: readers ask acpmux for a window or one chat (P-RUST step 2, S–M) |
| `SidebarChatHistoryFeed` | AgentLanes/SidebarChatHistoryFeed.swift | two acpmux windows (Earlier, Pinned) | `.shared` | same | ObservationStream over workspaces, lanes, pins | **Done (#28055)**; inject instead of `.shared` |
| `ProjectsImport` | (deleted) | none | none | the daemon reads acpmux `_acpmux/chat_projects` itself (`mux/project_chats.rs`) | none | **Done (A14)** |
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
| `IntentOverlay` + `Provisional*` | Daemon/Store/IntentOverlay.swift, ProvisionalSplit.swift (~1,800 lines) | optimistic tree overlay | DaemonStore | re-implements `split_kind.rs` / cmux-layout-reducer | mutates records | Compute the optimistic view with `cmux_layout_reducer` over FFI, like `SidebarMirror` (pure reducer, allowed by checklist step 6) (L, high) |
| `SessionStateStore` / `SessionStateMirror` | Daemon/Store/, State/ | closed history, status, checklist | DaemonStore | daemon `session.events` | guarded @Observable | Keep (pure cache) |
| `SidebarDocStore` + `SidebarMirror` | Sidebar/Store/ | sidebar document, pending intents (Rust) | SidebarBridge | cmux-layout-reducer `sidebar_doc` (FFI) | @Observable `version`; NotificationCenter refused/settled | **Keep: this is the pattern to copy** |
| `SidebarEdits` / `SidebarPendingEdits` / `KeyboardReorder` | Sidebar/Logic/ | Swift tree reducer + pending edits | SidebarModel | duplicates `sidebar_drop` / `sidebar_doc` | — | **Delete** once `SidebarDocStore.isActive` is always on (S–M) |
| `SidebarModel` | Sidebar/Model/SidebarModel.swift | sections, selection, folds | per window | partly the daemon tree | revisions + callbacks | Keep the view state; feed only from `SidebarDocStore` (M) |
| `ClosingWorkspaces`, `PendingWorkspaceRows`, `WorkspaceLanes` | Sidebar/Logic/, App/Windows/, DaemonService/ | hidden or stand-in rows, create/close queues | `.shared` | shadow daemon membership | @Observable | Fold into DaemonStore intents; daemon numbers creates in order (M) |
| `LayoutModel` | Layout/Model/LayoutModel.swift | screens copy, `focusedPane`, overrides | per workspace view | tree; focus also in `FocusMachine` (Rust) | @Observable | Keep gesture state; read focus from FocusMachine (M) |
| `TabStripModel`, `SavedGroupsBarModel` | Tabs/ | copies of `PaneModel.tabs`, saved groups | per pane | daemon tree | whole-array observation | Bind to the pane model directly (S) |
| `SettingsController` + `CmuxConfigFile` + `JSONC` | Settings/ (~3,400 lines) | parsed snapshot, managed keys, file writes | composition root | **cmux-config + cmux-tui-core `mux/settings.rs`**: two writers of one file | @Observable → `DesignSettings` | Become a client of the daemon's `settings.*`: one writer (L, high: MDM, migrations) |
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
| `InMemoryBrowserHistory`, `OmniboxQuickIndex`, `OmniboxQuickScore`, `BrowserHistoryRanker`, `BookmarkRanker`, `TabSearchRanker` | Browser/Omnibox/ (~3,700 lines) | 20k-URL index, scoring | omnibar | cmux-history `VisitStore`, `search_index.rs` | The daemon's cmux-history answers the omnibox window (search in Rust; Swift holds the visible rows) (M, perf-sensitive) |
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

Ranked by main-thread time or bug class removed, per unit of cost. Every step follows
layer-ownership.md and the shape of `_acpmux/chats_window` (#28055):

- the daemon owns the state, the list, its order and its rules;
- Swift asks for its visible window and applies row diffs, or sends intents;
- a pure reducer crosses cmux-app-ffi only to compute an optimistic view;
- the step lands with failing tests first and before/after numbers.

| # | Item | Where it goes | Cost | Why first |
|---|---|---|---|---|
| 1 | Remove ChatsFeed's private mirror (P-RUST step 2) | acpmux windows and `chat` lookups | S–M | The windows landed in #28055 (the 540 µs / 1.26 s burst root cause); the last whole-index copy in the app goes |
| 2 | Tab status merge (`StatusMapping`) | cmux-tui-core publishes one status per tab | M | Removes the stale-spinner bug class (a868, 8a2b6905) at the source |
| 3 | acpmux session watch (`AgentTurnStateFeed` → one store) | acpmux sends each view's window of sessions with row diffs; delete the Swift title rules | M | Per-event O(cells) `syncCells` and whole-map invalidation; two stores fed by one watch |
| 4 | Delete Swift duplicates | — | S each | `CmuxSyncStore` (orphan), the history fallbacks, `LocalPaletteUsageStore`, the bookmark file fallback, `HomeConversationSession` and `HomeService.conversations`/`sessions`, the old sidebar path (`SidebarEdits`, `SidebarPendingEdits`, `sidebarSections`). About 5k lines and 4 duplicate truths |
| 5 | `unreadConversations` | memoize now; the daemon's `home_inbox` computes it | S then M | Full model rebuild per window per read |
| 6 | Terminal "Restoring…" | status from the daemon; `TerminalAttachMachine` next to cmux-terminal-client | M | Stuck-pane bug class (a792, a821) |
| 7 | Optimistic tree overlay | `cmux_layout_reducer` over a mirror handle | L | Removes the reducer copy and the drift checker |
| 8 | Omnibox index and scoring | the daemon's cmux-history answers the omnibox window | M | 3.7k lines of Swift ranking over 20k URLs |
| 9 | Settings | daemon `settings.*` client | L | Two writers of one file |
| 10 | `AgentSessionParents`, priority marks (`ProjectsImport` done, A14) | into acpmux / the daemon | M | The app relays between two Rust processes |
| 11 | `DaemonLanePolicy`, close-focus rules | daemon / cmux-focus-core | S–M | Security rules in one place |

**Keep in Swift:**

- AppKit, WebKit, CEF and Ghostty owners: window, surface and tab content caches, `CEFRuntime`,
  `GhosttyRuntime`, `TerminalSession`
- Sparkle (`UpdaterService`), Keychain auth (`CloudAuth`), process supervisors
- per-window view models (`SidebarModel`, `LayoutModel` gesture state, `PaletteModel`)
- the app's control socket, which drives AppKit
- `HomeStore`, until iOS can share a Rust core through cmux-mobile-ffi

## The pattern for the next items

Copy `_acpmux/chats_window` (#28055) and its tests:
- `chats_window.rs` (3,000 chats: one change is one row);
- `ChatsWindowMainThreadTests` (one change touches one row on main).

For an optimistic edit, copy `SidebarMirror` (the cmux-layout-reducer FFI): only the pending
intents and the pure reducer live in the app. A new C ABI joins cmux-app-ffi in the same push as
its published release and pin, never before (643cd1a81f64).
