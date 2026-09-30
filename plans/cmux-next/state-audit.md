# cmux next: state and concurrency audit (2026-09-29)

Scope: every mutable stored property in `Packages/macOS/CmuxNext/Sources` (16 modules, ~63k lines) and the Swift daemon client (`CmuxNextDaemon`). Checked against architecture.md section 1 (one owner per fact) and 5a (never block main, deadlines, bounded buffers). Line numbers are at `origin/feat-cmux-next` eb10db93a2d plus this branch; files this branch edits are cited by symbol.

Owners of parallel work (findings routed, not fixed here): **focus** (FocusCoordinator, key routing), **window** (WindowState/WindowRegistry, WindowManager), **drag** (surface lifecycle during drags; SurfaceLedger landed in #15771), sidebar redesign, omnibar.

## 1. Summary table

Status: **fixed** in this PR (commit pair red→green unless noted), **routed** to a parallel owner, **open** (ranked backlog).

| # | Finding | Impact | Effort | Status |
| --- | --- | --- | --- | --- |
| D1 | First daemon connect failure was final: no window, "daemon is not connected yet" | hang (no UI) | M | fixed by crisp in #15766 (`DaemonStartup`, root cause: TMPDIR-dependent owner socket) |
| D2 | `DaemonService.identity` frozen at first connect; capabilities wrong after daemon restart/handoff | desync | S | **fixed** (store owns `identity`) |
| D3 | Store event inbox unbounded; reader thread never blocks, so the daemon never drops a slow app | leak, stall | S | **fixed** (4,096 cap, collapse to one resync, echoes kept) |
| D4 | Frame scheduler waits for a `CADisplayLink` bound to the first main screen; displays asleep or screen unplugged freezes store drain, pane presentation and every mutating CLI request | hang | S | **fixed** (100 ms stall deadline, rebuild after 3 stalls) |
| C1 | `CompatDeadline` raced in a task group: waits for a body that ignores cancellation | hang (CLI) | S | **fixed** (ControlDeadline) |
| C2 | v1 plain-text CLI lines had no overall deadline | hang (CLI) | S | **fixed** |
| K1 | Sign-out revoke could reach the server before an in-flight tunnel enrollment; later link starts re-enrolled while signed out | security, desync | S | **fixed** (hub phases + generation) |
| K2 | `CloudMachineLink.stop()` during `start()` still started the hub and spawned `remote connect` | leak | S | **fixed** |
| M1 | `MobileIrxHost.stop()` during provisioning was undone by `start()` resuming: orphaned phone listener for the old account | leak, security | M | **fixed** (lifetime token) |
| M2 | Endpoint task revived `.listening` and the accept loop after teardown | desync | S | **fixed** |
| B1 | CEF DevTools calls (hover preview, snapshot, occlusion, script) awaited forever when no result came | hang | S | **fixed** (5 s deadline, no red commit: needs CEF) |
| B2 | Second `CEFRuntime.shutdown()` replaced the first waiter | hang on quit | S | **fixed** |
| G1 | No static rule for unbounded streams, task-group deadlines, unowned service Tasks | regressions | S | **fixed** (check-concurrency.sh) |
| T1 | Terminal output backpressure defeated: bounded `TerminalEventQueue` drains into `.unbounded` `DaemonTerminalIO.events`, then an unbounded lane queue | leak, main stall | M | open → drag follow-up |
| T2 | Main thread `queue.sync` on the output lane (`TerminalSession` `lane.drain()`, `TerminalSurfaceView` deinit `lane.close()`) waits for the whole unparsed backlog | hang | M | open (depends on T1) |
| T3 | Keystrokes dropped while `DaemonTerminalIO.state.attachment` is nil (first attach, overflow reattach) | lost input | S | open → drag |
| T4 | Geometry claim/release are separate unordered `Task {}`s (`DaemonTerminalIO` settle/visibility) | PTY size desync | S | open → drag |
| T5 | `close()` during attach stores the attachment and claims geometry anyway; overflow reattach never `detach()`es the old transport | leak | S | open → drag |
| W1 | Window state: failed `load()` becomes an empty document and the next save wipes saved windows; `isTerminating` set after the save await; `removeWindow` races `saveNow` | data loss | S | routed → window |
| W2 | Selection has four copies (`WindowState.selection`, `stripModel.selectedID`, `PaneController.currentTabKey`, daemon default tab); `TabSelectionMemory.prune` never called | desync, leak | M | routed → focus/window |
| W3 | Focus copies `WindowState.focusedPane` and `LayoutModel.focusedPane`, single-slot `pendingFocusSurface` written by 3 async paths | desync | M | routed → focus |
| W4 | Tab drag can stay `.committing` (no app-side deadline on `daemon.commit`), group drags always use the local daemon (`TabGroupMoves`) | stuck UI | S | routed → drag |
| L1 | Divider drag: gesture stays active and the layout display link spins at 120 Hz if the handle view is removed mid-drag (`ScreenContentView+DividerDrag`) | CPU, stuck | S | open |
| L2 | Sidebar optimistic edits: some local-only intents snap back on the next unrelated delta; multi-row reorder is N non-atomic commands (`SidebarBridge+Intents`) | flicker, partial order | M | routed → sidebar |
| K3 | `CloudService.refresh()` calls are unordered; an older `/api/vm` list removes a just-created machine or re-adds a deleted one | desync | M | open |
| K4 | Live→not-live machine never disconnected (`CloudService.reconcile`) | leak, churn | S | open |
| K5 | `CloudAPIClient.send`: `tokens()` (may refresh over network) and `teamID()` run outside `withDeadline` | hang | S | open |
| M3 | `MobileIrxHost.teardown` drops `DaemonCompatBackend` without closing its `DaemonConnection`: one leaked daemon client per restart | leak | S | open (backend protocol has no `close`) |
| M4 | `MobileCompatTerminalStream.initialReplay()` has no deadline; phone control handling is serial, so one missing replay stalls the phone session | hang | S | open |
| U1 | Updater `channelSwitchPhase` set by unordered `Task { @MainActor }` hops; a late phase lands after completion (no UI reads it yet) | stuck spinner | S | open |
| S1 | `settings.set` then `settings.get` can return the old value: three copies (file, `SettingsController.snapshot`, `ControlSnapshot.settings`) | desync (CLI) | S | open |
| S2 | `SettingsController.reloadTask` clobbered after `stop(); start()`; `reload()` can resolve on a load that read the file before the caller's write | desync | S | open |
| P1 | Palette `pendingSubmit` not tied to a search generation: Enter mid-search, Esc, type again runs a command never confirmed | wrong action | S | open |
| P2 | Stale palette searches never cancelled; `install` + `search` are two actor calls (reentrancy mixes pages) | latency, wrong results | S | open |
| R1 | `RegistryControlBridge` detach→attach doubles observers (no epoch) | CPU | S | open |
| X1 | `DaemonService.reconcile()` applies a snapshot without the store's inbox hold and barrier, so a delta applied meanwhile can be overwritten | desync | M | open (unused `refresh()` with the same bug deleted) |

## 2. Implicit state machines

Converted in this PR:

| Where | Before | After |
| --- | --- | --- |
| `CloudTunnelHub` | `child?` + `socket?` + `starting?`, no stopped state | `Phase { idle, starting(Task), running(socket), revoked }` + generation; revoke waits for the in-flight start; `resume()` on sign-in |
| `MobileIrxHost` start/stop | `phase` + resources set across awaits; `.failed` reused for transient relay errors | `lifetime` token checked after every await; resources assigned with no suspension before `service.start()` |
| `DaemonStore` inbox | unbounded array + `framePending` | bounded, `collapsed` mode keeping lifecycle events and one echo per transaction |
| `DisplayLinkFrameScheduler` | link paused/unpaused only | pending → stall deadline → rebuild after 3 stalls |
| CEF DevTools calls | dictionary of bare continuations | `CEFReplyWaiters` (continuation + deadline per key) |

A general `DaemonLinkMachine` (idle, connecting, live, backingOff, failed, stopped) was written first and dropped when crisp's `DaemonStartup` merged. `DaemonService` still keeps first-connect state in `startup`, `lastStartupError`, `startupDeadlineTask`, and connection state in `store.connectionState`; a later cleanup can fold both into one enum owned by the store.

Candidates left (proposed enums):

- `DaemonTerminalIO.State` {attachment?, claimed, visible, closed, lastSize?}: `Phase { connecting(attempt), attached(att, geometry: owned|released), reattaching(attempt), ended(reason), closed }`, one serial command stream per IO (fixes T3-T5).
- `CEFTab` {browserID?, isCreationPending, pendingURL, pendingFocus, isClosed}: `Lifecycle { unrequested(url, focus), creating(url, focus), live(id), closing(id), closed }`. `CEFRuntime.state` needs `.shuttingDown`; `CEFPaneHost.window` + `windowTab` + `pendingWindows` + `tabBeingAdded` fold into `.creating(request, tab)` (fixes a window stuck `.creating` when its tab is removed).
- `WindowManager` {restored, isTerminating, saveTask}: `Phase { loading, restoring, live(saveTask?), terminating }` (W1). Routed to window.
- `PaneController` pending intents {pendingSelectSurface, pendingSelectTab, pendingAddressBarFocus, pendingClosed}: `PendingSelection { none, surface(id, focusAddressBar, deadline), tab(id) }` with a deadline. Routed to focus.
- `TabStripView` pointer {press, drag, detachedID, pendingDrop, dropPlaceholderIndex, phantomPoint, orderOverride, pressedNewTab}: `Interaction { idle, pressing, reordering, detached(id), receivingDrop(proposal), awaitingEcho(order, deadline) }`; leaving the window does not clear drag state today. Routed to drag.
- `SidebarListView` {press, drag, rename, external, pendingGroupToggle}: `Interaction { idle, press, drag, rename, externalDrop }`; a rename field survives its row being removed. Routed to sidebar.
- `TabHoverCard` {pendingID, pendingShow, shownID, lastHidden}: `hidden(last?) | pending(id, Task) | shown(id)`.
- `EmptyWorkspaceRepair` {claimed, populating}: per-workspace `RepairState` with a deadline (a claim can stick; deleted workspaces never leave `claimed`).
- `UpdaterService` {isProbing, probeTask, lastProbe, lastProbeError} and {channelSwitchPhase?, channelSwitchError, switchTask}: `ProbeState`, `SwitchState` (U1).
- `SettingsController` {reloadTask, reloadRequested, loadCount, loadWaiters}: `LoadPhase { idle, loading(rerun, task) }` + requested/completed generations (S2).
- `ControlConnection` 7 booleans: `Input { reading, suspended, finished }`, `Output { idle, armed }`, `Life { open, draining, closed }`.
- `CloudService` {hasLoadedMachines, lastError, creating, lastRefresh}: `ListState { notLoaded, loading(gen), loaded(gen), failed(gen) }` (K3); `CloudAuth` needs a `signingIn` state (double sign-in opens two browsers).

## 3. Duplicated state (one owner per fact)

| Fact | Owner | Second copies | Drift risk |
| --- | --- | --- | --- |
| Daemon identity/capabilities | daemon | `DaemonService.identity` (frozen) | **fixed**: store only |
| Connection liveness | `DaemonConnection.phase` | `store.connectionState`, `DaemonService.connection != nil` (used as "connected" in ~10 handlers), `startup`, `AppCompatFrontend.connectionBox` (async mirror) | a CLI call right after reconnect can use a dead connection |
| Selected tab per pane | app per window (arch. 1) | `WindowState.selection`, `stripModel.selectedID`, `currentTabKey`, daemon default tab | W2 |
| Focused pane | app per window | `WindowState.focusedPane`, `LayoutModel.focusedPane`, Ghostty/WebKit/CEF responders | W3 (focus agent) |
| Browser url/title/favicon | daemon tab record, engine writes back | `BrowserRecordWriter.recorded` (never refreshed from daemon), `CEFTab.machine`, `WebKitTab` | a CLI/other-client change is diffed against a stale base; no rule for who wins on a daemon-side URL change |
| Terminal title/cwd/size | daemon | `TerminalSurfaceModel` (parsed from the local mirror), `TerminalSession.canonicalGrid`, `DaemonTerminalIO.lastSize`, `TerminalAttachment.lastReported` | title stale after a surface swap |
| Geometry ownership | daemon lease | `DaemonTerminalIO.claimed`, `TerminalAttachment.ownsGeometry` (written, never read), `TerminalSession.ownsGeometry` (always true), `TerminalSurfaceView.ownsGeometry` | T4 |
| Visibility | SurfaceLedger (#15771) | `TerminalSession.isRenderingSuspended`, `DaemonTerminalIO.visible`, `CEFTab.isOccluded`, `CEFPaneHost.visibleTab` | improved by SurfaceLedger; CEF copies remain |
| Settings | cmux.json | `SettingsController.snapshot`, `ControlSnapshot.settings`, `SettingsApplier.appliedShortcutIDs` | S1 |
| Cloud machines | `/api/vm` | `MachineRegistry.cloud`, `session.machine` | K3 |
| Installation id | – | `CloudPaths` device-id and `MobileHostKeys` installation-id | low |

## 4. Concurrency hazard inventory

Counts at audit time: 15 `@unchecked Sendable` (all queue-, lock- or thread-confined; reviewed safe), 4 `nonisolated(unsafe)` (`TerminalSnapshot.context` CIContext is thread-safe; the 3 `onPress`/`onClose` closures on `TabAccessibilityElement`/`TabStripButtonGroupView` are set on main and read in AX callbacks that assert `MainActor.assumeIsolated`), no lock held across an `await`. `LineTransport.submit` writes under its socket lock, but `SocketWriter` is nonblocking.

Unstructured `Task {}` whose handle is not stored: ~60 in CmuxNextApp handlers and intents (full list in the audit transcript; representative: `WindowManager` 120/127/138, `WorkspaceContentController+Intents` 51/76, `SidebarBridge+Intents` resync, `Handlers/*` action bodies, `Drag/*` commits). UI handler Tasks are acceptable when the result only re-reads daemon truth; the risky ones write app state after an await into a controller captured before it (`PaneController+Intents` `pendingSelectSurface`, `ClosedTabTracker`, `TabGroupHandlers`), which a rebuilt pane never sees (W3/W4). `registry.track(Task {})` collects only while a control-socket capture is active, so those Tasks are also unowned in normal UI use. Service code now has a static rule (section 5).

Unbounded buffers left (annotated): `DaemonTerminalIO.events` (T1), the output lane's serial queue (T1), `ControlConnection` inbound (bounded by `maxQueuedLines`), `DaemonConnection.events` (drained at once into the bounded inbox), `TerminalSession` outgoing (user input), debug/demo terminal IO. `CompatSidebarStore` status map and `TabSelectionMemory` grow per workspace/pane and are never pruned.

Missing deadlines left: CEF find (`CEFTab+Events` find continuation, also not matched by request id), `MobileCompatTerminalStream.initialReplay`, `CloudAPIClient` token refresh, favicon fetch (URLSession 60 s default), app quit (`applicationShouldTerminate` waits on `prepareForTermination` with no bound), tab-drag commit.

Idle wakeups: `CEFMessagePump` fires at 1 Hz once CEF started (30 Hz with any browser, even occluded), against the 0.0% idle budget.

## 5. Rules added to scripts/cmux-next/check-concurrency.sh

- Unbounded `AsyncStream` buffer: `bufferingPolicy: .unbounded`, `makeStream()` without a policy, `AsyncStream { continuation in }`.
- Deadline raced in a task group: a `with(Throwing)TaskGroup` whose body sleeps within 8 lines. Use a continuation race (`ControlDeadline`).
- Unowned `Task {` statement in service code (Daemon, Cloud, Mobile, Control, App `*Service`/`*Store`/`Cloud/`): store and cancel the handle, or `// task-owner: <reason>`.

## 6. Suggested next order

T1+T2 together (demand-driven output: the session pulls from the attachment's bounded queue; no unbounded stream, no `queue.sync` on main), then T3-T5 as the `DaemonTerminalIO` phase enum, K3/K4, M3/M4, S1/S2, P1/P2, X1, L1, R1, U1.
