# One main-thread sequence manager (design, for review by cmux-ad)

Status: DESIGN ONLY, not reviewed. No product code may start from this file until cmux-ad has reviewed it
(audit-findings-2.md D3, binding). Covers D3, D4, D5, D6 and D10. Read at origin/perf/chrome-parity
`8a75e216703`. Paths are under `Packages/macOS/CmuxNext/Sources/` unless they say otherwise; `W/` is
`CmuxNextWakeups/`. Counts leave out `Tests/`, `TestSupport/` and `///` doc lines.

## 0. Summary

Today 12 objects decide when main-thread work runs. Most of them are layers of one design that was never
finished: `MainWorkScheduler` has the class queues; `MainTaskQueue`, `MainDeadline`, `StartupScheduler`,
`IdleScheduler`, `ContentPresentationScheduler` and `MainActorWorkQueue` each post into it or wrap it with a
second queue; `FrameScheduler` runs it on a frame tick; `MainJobGate` reorders the main executor because a large
part of main-thread work (135 `Task { @MainActor`, the hop of 86 of the 88 `DemandTimer`s) does not go through it.

The target is Chrome's model, one level stricter:

1. One sequence manager on the main thread (Chrome `base/task/sequence_manager`), with typed task queues
   (`control`, `input`, `frame`, `userBlocking`, `startup`, `visible`, `automation`, `background`, `idle`), each
   queue with a priority, enable voters and an optional fence.
2. One post API: a `TaskRunner` (manager, queue, owner) that an owner gets in its init. Every post states its
   priority at the post site; delayed work is a delayed post on the same runner, timed by the injected `Clock`.
3. Input first by construction: event dispatch is never behind a task, the batch yields at the first pending
   input, and after a discrete input the input-response voter holds automation, background and idle until the
   frame (Blink `kWaitingForInputResponse`).
4. Fences: startup fences (Chrome `OnStartupComplete`) and one `CommitFence` for "show when ready, at most one
   frame" that replaces the hold types (D10).
5. Two time sources only: one `DisplayClock` per display (Chrome `BeginFrameSource` / `DisplayLinkMac`) for
   frames, one injected `any Clock<Duration>` for delays (D4). No executor reorder: `MainJobGate` goes, and the
   executor hook has one owner that only records (D6).

The migration is 10 steps (section 4). Each step is one reviewable branch, deletes the API it replaces, and adds
a pre-push guardrail rule that refuses the old API.

## 1. Inventory

### 1.1 The 12 work owners

"Callers" counts single-line matches of the post or construct API outside the owner's own files.

| # | Owner | Definition, size | Mechanism | API | Callers | Order and priority | Guarantees | Rules it implements |
|---|---|---|---|---|---|---|---|---|
| 1 | `FrameScheduler` | `W/FrameScheduler.swift:37`; 437 lines, 1274 with its extensions, `FrameClient.swift` (235) and `FrameBatchQueue.swift` (255) | One per window (`forWindow`/`forView`, `FrameScheduler+Windows.swift:10,36`), the static `FrameScheduler.app` (`:49`, a mutable global) and one budgeted instance that `MainWorkScheduler` owns. Subscribes to its display on `DisplayClock` only while a `FrameClient` is active. Tick: `beginFrame` (`:369`), input stage, `.frame` clients (`deliverFrameLocked`, `:408`), then budgeted classes on the budget holder only (`+Budgeted.swift:5`), `endFrame` (`:420`). Held while occluded or in Energy Saver display sleep. | `FrameClient.init(owner:isAnimation:rate:visibleOnly:onFrame:)` (`FrameClient.swift:94`), `init(owner:budgeted:on:onFrame:)` (`:117`), `activate()`/`deactivate()`; `FrameBatchQueue.init(owner:scheduler:)` (`:80`), `init(owner:budgeted:on:)` (`:99`), `enqueue` (`:112,126`); `FrameScheduler.install(displays:energy:)` (`:57`) | `FrameClient(` 35 sites in 31 files; `FrameBatchQueue(` 7 in 6; `FrameBatcher(` 6 in 5; `FrameScheduler.forWindow/forView/app` 25 in 22. Main: `MotionClock.swift:34` (all springs), `DaemonService.swift:128` (store drain), `TerminalFrameHold.swift:42`, `GhosttyActionMailbox.swift:172`, `PredictiveEchoSlot.swift:162`, `SidebarDragAutoscroll.swift:13`, `TabDragSession.swift:148`, `ResizeCoordinator.swift:57`, `W/FrameInputCoalescer.swift:74`, `W/StartupScheduler.swift:135` | Input stage, frame clients (dictionary order), other window schedulers of the display, then budgeted classes userBlocking > visible > automation > background, least-recently-run client first in a class (`:80`). A budgeted queue drains one task at a time; the first task of a frame always runs. | Idle app: 0 frame wakeups; each tick carries `targetTimestamp`. | PATTERNS.md P6a "One frame clock per display" (PATTERNS.md:16); P5 "one coalesced batch per display frame" (:14); threading-model.md "Frame clock" (:137) |
| 2 | `MainWorkScheduler` | `W/MainWorkScheduler.swift:48`; 342 + `+Post` 309 + `+Classed` 242; `MainWorkClass.swift` 68, `BudgetedWorkClass.swift` 20, `WorkPriority.swift` 113 | One FIFO `FrameBatchQueue` per budgeted class (`classQueue`, `+Post.swift:299`). The first post on an idle scheduler queues one `MainRunLoopBlock` turn (`enqueue`, `+Post.swift:227`); while the link runs, the class queues tick on `frames`. userBlocking and automation also run on the next turn (`runsOnNextTurn`, `:291`). `postFromAnyThread` performs a common-modes run-loop block (`:248`). Owns `IdleScheduler`, `MainWakeUpQueue` (`wakeUps`), `StartupPhase`, `CPUTimeBudgetPool`, `RenderPassMeter`. With `mainJobGate`, budgeted posts also wait in a classed hold (`+Classed.swift:150`). | `post(_:owner:file:line:_:)` (`+Post.swift:95,102`), `postContinuation` (`:122,129`), `postFromAnyThread` (`:138,145`), `apply` (`:154`), `reply(as:owner:)` (`:181`), `postIdle` (`MainWorkScheduler.swift:331,338`); `post(class:)`, `postFromAnyThread(class:)`, `callbackClass` (`+Classed.swift:73,100,119`) | `postFromAnyThread(` 211 in 158 files (visible 105, background 36, userBlocking 29, automation 21); `.post(.class` 47 in 41; `.apply(.class` 88 in 60; `.reply(on:` 39 in 26 (`W/BackgroundWork.swift:359` posts with `postFromAnyThread`); `postIdle` 6; `postContinuation` 4; `callbackClass` 6; `post(class:)` and `postFromAnyThread(class:)` 0 | input < frame < userBlocking < visible < automation < background < idle (`MainWorkClass.swift:11`); FIFO per class, continuations at the front. Budgets visible 2.5 ms, automation 1 ms, background 0.5 ms, userBlocking up to visible + automation. `MainFrameBudget.mayRun` (`MainFrameBudget.swift:403`) holds a class while input is pending or a response is open, for at most one frame per class. StartupPhase holds background until revealed and idle until settled. | A post never runs inline. | PATTERNS.md P5 (:14) and P15 "Main-thread work is posted with a class" (:28); threading-model.md "Main-thread scheduler" (:133); main-thread-budget.md sections 1-3 |
| 3 | `LaneScheduler` (off main) | `W/LaneScheduler.swift:91`; 773 + `LaneStats.swift` 174; internal | The thread-pool side: each slot is a serial `DispatchQueue` with the item's QoS (`:378`), state in a `Mutex`. Files lane: slots per `WorkPriority`; system and cpu lanes: shared width with a userBlocking reserve. Best-effort fence, may-block threshold (one-shot `DemandTimer`, `:363`), raises, shutdown policy. | `submit` (`:426`), `requeue`, `move`, `remove`, `raise(_:to:awaited:)` (`:517`), `fence()`/`unfence()` (`:594,600`) | Only `BackgroundWork` (3 lanes, `W/BackgroundWork.swift:191`); `BackgroundWork` itself: `.run/.post(.priority` 126 in 94 files, `.task(.priority` 107, `.sequence(` 6 | `WorkPriority` userBlocking > userVisible > bestEffort > idle, FIFO per level; `bestEffortCap = 2`, `idleCap = 1` (`:101,103`) | userBlocking queue wait p99 <= 2 ms target | threading-model.md "Lanes" (:213), "Startup fence", "Sequence rule"; PATTERNS.md P14 "Task traits" |
| 4 | `MainActorWorkQueue` | `CmuxNextControl/Concurrency/MainActorWorkQueue.swift:43`; 454; with `ControlFrameSource.swift` (81) | Control-socket requests per connection in a `Mutex`, round robin across connections, scheduled through a `ControlFrameSource`: in the app a `FrameBatcher(owner: "Control.frames", budgeted: .automation, on: mainWork)` (`CmuxNextApp/Control/AppControl.swift:91`); default `MainQueueFrameSource` (a run-loop hop). `drainFrame` (`:409`) runs while the class may run. Each request deadline is a `Task { @concurrent }` (`:~222`). | `run(connection:method:owner:workClass:deadline:countingFrom:file:line:_:) async throws` (`:168`) | 3 sites: `ControlRouter.swift:342`, `ControlRouter+ActionRun.swift:135`, `ControlRouter+ActionBatch.swift:123` | FIFO per connection; injected input goes to an `urgent` lane at the head of its connection (`:257`); the rest automation. 1024 pending, 256 per connection; full: `busy`; expired: `timeout`, never runs. | Fair, bounded, never runs after its deadline; injected keys keep their order. | threading-model.md :133 (the `MainActorWorkQueue` clause); PATTERNS.md P5 "Socket and CLI requests are parsed on an I/O executor"; main-thread-budget.md section 14 |
| 5 | `ContentPresentationScheduler` | `CmuxNextApp/ContentPresentationScheduler.swift:29`; 185 | Coalesces "show the selected content" per pane to frame time with two `FrameBatcher`s: budgeted visible on `MainWorkScheduler` (`:60`) and unbudgeted on `mainWork.frames` (`:61`). A person or frontend cause goes through the unbudgeted one. At most one new surface per frame (`mayCreate`, `:148`), a person's pane may take a frame automation used. | `setNeedsShowSelected(_:)` (`:68`), `showNow(_:) -> Bool` (`:83`), `cancel(_:)` (`:96`) | 13 sites in 6 files: `PaneController.swift:126,190,373,589,591`, `PaneSelectionPresenter.swift:15,27,84`, `PaneContentView+LaunchImage.swift:148,156`, `NewTabPage+Open.swift:82`, `Remote/RemoteTerminalService.swift:108` | FIFO per lane (person, other); a pane held by the create cap keeps its place | Transient selections create no surface; automation's creates never delay a person's | PATTERNS.md P4 "Instant create" (`showNow`), P5 |
| 6 | `IdleScheduler` | `W/IdleScheduler.swift:46`; 404 + `+Records` 190 + `IdleTask.swift` 105 | Chrome `IdleHelper`. Long periods after 50 ms of quiet (no link, no budgeted work, no input), at most 50 ms, armed by `IdlePeriodTimer` (a precise `CFRunLoopTimer`); short periods after a frame's render pass when >= 2 ms remain to vsync. Runs tasks one at a time through `budget.run(.idle)` with an `IdleDeadline`. | internal `post(owner:site:maxDelay:node:_:)` (`:155`); public through `MainWorkScheduler.postIdle`; `noteInput()` (`:201`) | `postIdle(` 6 sites in 6 files: `ChromiumWarmupIdle.swift:51`, `W/VisibleObservation.swift:189`, `HiddenWorkspaceMemory.swift:89`, `ExtensionActionToolbar.swift:120`, `SidebarSnapshotRecorder.swift:118`, `BookmarkChromiumSync.swift:39` | FIFO; a period ends on higher work, a link coming up, input, or the deadline; nested posts wait for the next period; past `maxDelay` a task moves to background; periods stop 10 s after hide | Never runs while higher work or input waits; 0 wakeups when empty | zero-latency.md (g) "idle callbacks" (:56); threading-model.md :133, :448; PATTERNS.md P15 |
| 7 | `StartupScheduler` | `W/StartupScheduler.swift:50`; 475; with `StartupPhase.swift` (304), `StartupTaskTag.swift` (131), `StartupTaskLog.swift` (156), `StartupMainHop` | Chrome after-startup queue. `.critical` runs inline; `.afterFirstFrame` main tasks go to a `FrameBatchQueue(budgeted: .visible)`; `.afterStartup` main tasks to a `FrameClient(budgeted: .background)`, one per frame; lane tasks to `BackgroundWork`. Completion is a reference count posted through `StartupMainHop.userVisible`, a raw `Task(priority: .userVisible) { @MainActor }` with a `main-hop-allow`. Failsafe `DemandTimer` (`:178`). `StartupPhase` (launching, revealed, settled) gates whole classes in `MainWorkScheduler`. | `post(_:_:on: .Main, _:)` (`:201`), `post(_:_:on: .Lane, _:)` (`:214`), `hold` (`:231`), `firstFrameCommitted` (`:250`), `whenComplete` (`:303`), `afterFirstFrame() async` (`:321`) | 51 posts in 30 files, 4 `hold(`. Main: `AppActions.swift:20`, `MainMenu.swift:19`, `Startup+Core.swift:64`, `SettingsController+LaunchRead.swift:91`, `LaunchWindowQueue.swift:46,50`, `ControlLaunch.swift:55,69`, `Startup+Settings.swift:22`, `CrashForwarders.swift:91`, `LaunchFirstOpenWarmups.swift:57-62` | 4 priorities (critical, afterFirstFrame, afterStartup, onDemand = afterStartup), FIFO in each; a 14-entry critical allowlist (`:59`) is logged, not enforced | No afterStartup task before completion; one completion; quit drops what has not started | Not named in the three docs; main-thread-budget.md section 4 (StartupPhase) |
| 8 | `MainDeadlineScheduler` + `MainDeadline` | `W/MainDeadlineScheduler.swift:32` (217), `W/MainDeadline.swift:28` (207); the app's instance `AppServices.swift:791` | A `MainDeadline` holds one wake on `MainWakeUpQueue` through `AlignedWakeups` (precise, flexible, hidden). At the wake it posts its action with `work.post(workClass, owner:)` (`MainDeadline.swift:185`), so it waits behind input and higher classes. Hidden-node deadlines charge `CPUTimeBudgetPool`; a repeating deadline hidden 5 min joins a per-node pool, one wake a minute (`:151-202`). | `MainDeadline.init(owner:workClass:alignment:scheduler:file:line:)` (`:76`), `schedule(after:)` (`:104`), `scheduleIfIdle` (`:109`), `start(every:)` (`:116`), `cancel()` (`:121`); scheduler `nextFire`, `nextFireNanos` (`:81,88`) | `MainDeadline(` 153 in 119 files; `MainDeadlineScheduler(` 21 sites, about 12 of them default arguments that build a private `MainWorkScheduler`. Main: `AgentActivitySocketSource.swift:78`, `HomeService.swift:42`, `WindowRecordSaver.swift:55`, `UpdaterService.swift:237`, `SocketTasksSource.swift:67`, `PagePreloads.swift:119`, `AgentPaneFrameClocks.swift:28` | Class from `BudgetedWorkClass`; wakes aligned (8 ms, 32 ms in Energy Saver, whole seconds hidden, a minute in the pool); actions FIFO in their class | No sooner than the delay; cancel works after the wake posted; a released deadline never runs | threading-model.md :133, :434, :441 "every page deadline is a `MainDeadline`"; PATTERNS.md P15 "a `MainDeadline` for a delay"; main-thread-budget.md section 10; guardrail `timer-class` (`scripts/cmux-next/guardrails.py:2673`) |
| 9 | `MainWakeUpQueue` | `W/MainWakeUpQueue.swift:38` (409), `MainWakeUpHeap.swift` (150), `MainWakeUpTimer.swift` | One `CFRunLoopTimer` (common modes, parked between arms) per queue; two heaps by latest time (visible, hidden at whole uptime seconds); a `Mutex` so inserts come from any thread; a fire runs due entries for at most 2 ms (`fireBudget`, `:54`) then arms a continuation | `insert(owner:after:policy:_:)` (`:176`), `insert(owner:at:window:ledgerReason:_:)` (`:223`), `insertHidden` (`:192`), `cancel` (`:270`) | 11 direct inserts in 7 files: `AlignedWakeups.swift:80-108`, `DemandTimer.swift:217`, `MainJobGate+RunLoop.swift:87`, `MainWorkScheduler+Classed.swift:203`, `CEFPumpTimer.swift:93`, `CEFEnergySaver.swift:47`, `GhosttyEnergySaver.swift:42` | Earliest latest-time first; precise entries under 36 ms never aligned; no classes (what an entry posts carries the class) | 0 wakes when empty; hidden entries never ride a visible fire | threading-model.md :134 "The one main run-loop `CFRunLoopTimer`"; idle-wakeups.md section 9. **Not true in code:** 7 `MainWakeUpQueue(` sites, only `CmuxNextApp.swift:40` is the app's; `MainWorkScheduler.swift:150`, `CEFRuntime.swift:236`, `CEFEngine.swift:107`, `DaemonStore.swift:234`, `WebKitEngine.swift:136`, `MockBrowserEngine.swift:29` make a private one (with its own timer) when none is passed |
| 10 | `MainTaskQueue` (+ `MainTaskBoard`) | `W/MainTaskQueue.swift:39` (276), made only by `VisibilityNode.queue(_:owner:on:)` (`VisibilityNode+Queues.swift:12`); `MainTaskBoard.swift:27` (415) | Blink per-frame queue on a `VisibilityNode`: each pending item becomes one pump posted with `work.post(workClass, owner:)` (`:215`). Visible: runs in order; hidden: visible and automation held, background only at the 1 s hidden wake and charged to the hidden budget; frozen: nothing; any voter disabled: nothing (Chrome `QueueEnabledVoter`). Keyed posts replace the pending body in place. The board is not a queue: atomics that publish the running task for the watchdog, and the `pendingInput` count. | `post(file:line:_:)` (`:99`), `post(key:)` (`:111`), `makeVoter()` (`:139`), `setEnabled(_:by:)` (`:146`) | 5 `node.queue(` sites in 4 files (`CEFMergedEvents.swift:85-86`, `PageTabReplies.swift:67`, `W/FrameObservation.swift:114`, `W/VisibleObservation.swift:233`; the last two are generic, so the reach is larger); 58 `// node-free:` escapes post without a node | FIFO per queue; class order and budget come from `MainWorkScheduler` | Held tasks run in post order before later ones | PATTERNS.md P15 "`node.queue(class, owner:, on: mainWork).post`"; threading-model.md :133 "per-node `MainTaskQueue`" |
| 11 | `MainJobGate` (and `MainJobRing`, the other hook) | `W/MainJobGate.swift:31` (413), `MainJobGateHook.swift:27` (146), `+RunLoop` (148), `+Switch` (100), diagnostics; 1923 lines in all. `CmuxNextCompat/MainJobRing.swift:35` (338, `#if DEBUG \|\| CMUX_BENCH_HOOKS`) | Gate: writes `swift_task_enqueueMainExecutor_hook` (`MainJobGateHook.swift:38,47`). While input is pending or in dispatch, every main-actor job that is not exempt (enqueued on main during dispatch, from a `MainWork.input`/`.frame` task, or in a nested loop) appends to one `Mutex` FIFO, by origin, never by priority (`MainJobGate.swift:14-15`); released one per pass after each CA commit (`AfterFrameCommit.everyPass`), all at one refresh (a precise `MainWakeUpQueue` entry, `+RunLoop.swift:87`), at a nested loop's entry and at uninstall. Ring: the census (`CMUX_NEXT_MAIN_JOB_CENSUS=1`, `CmuxNextApp.swift:60`, `MainJobCensus.swift:77-78`) writes the same hook (`MainJobRing.swift:314`), records a slot and re-posts with `DispatchQueue.main.async` (`:261-268`). | `MainJobGateHook().install(gate)`, `MainJobGateSwitch.setEnabled` (`+Switch.swift:66`); `MainJobRing.install()` | Gate: built once (`CmuxNextApp.swift:278`) when feature `mainJobGate` is on, then follows setting `debug.mainJobGate` (`CmuxApplication.swift:307-312`); also holds `MainWorkScheduler` classed work (`+Classed.swift:57,228`). Ring: `MainJobCensus` only. `DemandTimer`'s fire looks the ring up (`DemandTimer.swift:231`). | Neither hook chains: the first install wins, the other refuses (`.busy`, `.otherHookInstalled`). The ring installs in `main()`, so on a census launch the gate is silently absent (`+Switch.swift:80` logs it). | Gate: at most about one refresh of delay; held jobs stay FIFO | threading-model.md "Main job gate" (:135; :141 is a stale second row that says task 076 has not landed); PATTERNS.md P5 "input first". Feature `mainJobGate` is off in dev, nightly and release, and not in the chrome-parity dogfood set: the gate does not run by default anywhere. |
| 12 | `RenderStarvationGuard` | `W/RenderStarvationGuard.swift:44` (219) | Not a queue. `isStarved()` is asked before every budgeted task (`MainFrameBudget+Starvation.swift:6-16`, `MainFrameBudget.swift:406`): a shown, active, link-paced scheduler whose last tick is older than 100 ms plus one refresh. If it holds work, `mayRun` refuses every budgeted class; `admitsSlice` caps the CEF pump at one slice per late frame (`CEFMessagePump.swift:296`); `afterLateFrame` resumes at the next tick. Reports `stall.render_starved`. | `init(holdsWork:...)` (`:103`), `watch` (`:114`), `isStarved` (`:125`), `admitsSlice` (`:148`), `afterLateFrame` (`:160`) | 1 construction (`CmuxNextLaunch/LaunchOrder.swift:114`), watches at `LaunchOrder.swift:123`, `FrameScheduler+Windows.swift:20`; about 10 sites in 6 files | Binary hold of the budgeted classes; input and frame never held | **Today it only reports:** `holdsWork: false` is hard-coded at `LaunchOrder.swift:114`, and no code reads feature `renderStarvationGuard` (only `FeatureDogfoodSet.swift:98` lists it). Its header names a per-display check timer that the file does not have. | main-thread-budget.md section 5; not named in the three docs (PATTERNS.md P5 is the closest) |

How they depend on each other (who posts into whom):

```
                         input dispatch (AppKit, CmuxApplication.sendEvent)
                                    |
MainJobGate (hook, off) --holds--> every main-actor job; also MainWorkScheduler classed posts
                                    |
StartupScheduler --> FrameBatchQueue/FrameClient --> MainWorkScheduler <-- MainDeadline <-- MainDeadlineScheduler
ContentPresentationScheduler --> FrameBatcher  -->        |   ^  ^  ^         |
MainActorWorkQueue --> ControlFrameSource/FrameBatcher -->|   |  |  +-- MainTaskQueue (per node)
IdleScheduler (owned by) ---------------------------------+   |  +----- BackgroundWork.reply(on:) <-- LaneScheduler
RenderStarvationGuard (veto inside MainFrameBudget) ----------+
         MainWorkScheduler.frames = FrameScheduler --> DisplayClock (--> VSyncHub, off)
         MainWorkScheduler.wakeUps = MainWakeUpQueue <-- DemandTimer (2 of 88), AlignedWakeups, CEF pump
```

Overlaps, in short: the automation FIFO exists twice (`MainWorkScheduler` automation queue and
`MainActorWorkQueue`); the visible batch three times (`MainWorkScheduler`, `ContentPresentationScheduler`,
`StartupScheduler.afterFirstFrame`); "input first" three times (`MainFrameBudget.mayRun`, `MainJobGate`,
`MainWorkScheduler` classed hold); launch gating twice (`StartupScheduler`, `StartupPhase`); main-thread delay
four times (`MainDeadline`, `DemandTimer` main path, `AlignedWakeups` used directly by CEF (11 sites),
`IdlePeriodTimer`).

Findings the inventory turned up (each one is a bug or a stale document, not a design question):
- F1 `IdleNextDeadlineSource` has no conformer outside tests and nothing sets `idle.deadlines`, so the next
  `MainDeadline` does not shorten a long idle period in the app.
- F2 Seven `MainWakeUpQueue` instances, not one (row 9).
- F3 `RenderStarvationGuard` never holds work in any build (row 12).
- F4 On a census launch the gate cannot install (row 11).
- F5 `MainWorkScheduler.post(class:)` and `postFromAnyThread(class:)` have no callers.
- F6 threading-model.md has two contradicting "Main job gate" rows (:135, :141).
- F7 `FrameScheduler.app` is a `public private(set) static var` (a global; PATTERNS.md P1).

### 1.2 Clocks and frame sources

The audit counts 9 clock types plus `FrameScheduler` and `VSyncHub`. Sorted by what they really are:

| Type | File | What it is | Users | Kind |
|---|---|---|---|---|
| `DisplayClock` | `W/DisplayClock.swift:54` (596) | One link per display (`screen.displayLink`, `:571`), ticks every `FrameScheduler` of the display in a fixed order, a 100 ms stall deadline per display and a rebuild after 3 stalls (`:64-66`), rate decision (`frameRateClasses`), occluded windows ticked on the stall deadline | 133 refs in 26 files | **frame source** |
| `VSyncHub` | `W/VSyncHub.swift:80` (332 + 489 in extensions) | Behind feature `vsyncHub` (off everywhere): the display's only link on a `cmux-next vsync <display>` thread (`:271`), off-main subscribers (Ghostty surfaces through `TerminalVSync`), one coalesced main post per vsync to `DisplayClock` | 75 refs in 13 files | **frame source** (second link owner) |
| `FrameScheduler` | row 1 above | Per-window client set on `DisplayClock`, and the budgeted tick | 352 refs in 111 files | **frame source** (relay) |
| `MotionClock` | `CmuxNextDesign/Motion/MotionClock.swift:25` (189) | The window's one spring clock: a `FrameClient` of its window scheduler, samples at `targetTimestamp` | 28 refs in 14 files | frame view |
| `DisplayLinkDriver` | `CmuxNextLayout/Views/DisplayLinkDriver.swift:10` (55) | Layout springs on the window's `MotionClock` | 3 refs | frame view |
| `PresentationClock` | `W/PresentationClock.swift:25` (299) | Presented-time estimates of input commits; subscribes a `FrameClient` for `holdFrames` after a tracked input | 21 refs in 7 files | frame view |
| `ControlFrameSource` / `MainQueueFrameSource` | `CmuxNextControl/Concurrency/ControlFrameSource.swift:8,54` (81) | "One main-actor callback per frame" for `MainActorWorkQueue`; default is a run-loop hop | 12 + 7 refs | frame view (scheduling seam) |
| `TerminalVSyncSource` / `GhosttyFrameSource` | `CmuxNextTerminal/TerminalVSync.swift`, `GhosttyFrameSource.swift:13` | The hub's off-main vsync for a surface (with its own `DemandTimer` stall, `TerminalVSync.swift:129`); the renderer's presented frame | 13 files | frame view (off main) |
| `TraceClock` | `CmuxNextTrace/TraceClock.swift:19` | `CLOCK_UPTIME_RAW` reads and conversions for traces | 40 refs in 20 files | time reader |
| `LaunchClock` | `CmuxNextTrace/LaunchClock.swift:18` | Process start and page-in reads | 31 refs in 14 files | time reader |
| `SpinnerClock` | `CmuxNextDesign/StatusIndicator/SpinnerClock.swift:16` | Wall-clock phase so all spinners agree | 12 refs in 4 files | time reader |
| `WebPageClock` | `CmuxNextInput/WebPageInputTiming.swift:198` | Maps a page's `performance.now()` to uptime | 5 refs | time reader |
| `PriorityClock` | `CmuxNextAgentLanes/SidebarPriorityFeed.swift:143` | An observed counter bumped on time-only changes (not a clock) | 2 refs | misnamed revision |
| `ManualClock` | `CmuxNextWakeupsTestSupport/ManualClock.swift:22` | The test `Clock` | 19 refs in 12 files | injected `Clock` (tests) |
| `ClockDeadline` | `CmuxNextDesign/Overlay/ComponentDeadlines.swift:62` | A `ComponentDeadline` asleep on a `DemandTimer` clock | 2 refs | delay |

Delay mechanisms beside these: `DemandTimer` (88 sites in 78 files; 86 sleep on the cooperative pool with
`Task { @concurrent }` and then hop to main or run off main, 2 use the wake-up queue; no class, node or
alignment), `MainDeadline` (row 8), `AlignedWakeups` (direct, CEF), `IdlePeriodTimer` /
`MainRunLoopPreciseTimer`, `CEFPumpTimer`, `DeadlineHeap` (daemon connection, its own timer), `Deadline` (an
async race helper, `W/Deadline.swift:19`).

So the real frame sources are two link owners (`DisplayClock`, `VSyncHub`) and one relay (`FrameScheduler`).
Five types are views on frames, five are time readers or tests, and one is not a clock. D4 asks for exactly two
sources: one `DisplayClock` per display and one injected `Clock`.

### 1.3 Hold and deadline types (D10 input)

42 types contain `Hold` (26 end in `Hold`); 31 end in `Deadline` (11 protocols, 8 of them satisfied by
`extension MainDeadline`). Only 4 holds are held work queues (`ClassedHold`, `PageDeliveryHold`, `SidebarRowHold`,
`StoreStage.Hold`). Most of the rest keep old pixels, or hide new ones, until something is ready, each with its own
limit and timer: `PanePaintHold` (`AgentPane/PanePaintHold.swift:18`), the workspace paint hold
(`WorkspaceContentView+PaintHold.swift:9`, up to 500 ms), `TerminalFrameHold` (`Terminal/TerminalFrameHold.swift:18`,
up to 3 s), `FirstTabHold` (2 s), `SidebarSelectionHold`, `LaunchImageHold` (3 s), `SpringPageHold`,
`FloatingChatFrameHold`, `WorkspaceAutoNameHold`. These are the targets of `CommitFence` (2.5). The `*Deadline`
protocols are seams over `MainDeadline`; they become seams over a delayed-task handle (S4).

## 2. The model

The reference is Chrome's `base/task/sequence_manager` (the browser UI thread and Blink's main thread run on it)
and viz's `BeginFrameSource`. cmux copies the structure, and copies a Chrome name only for a type that does the
same job.

| Chrome | What it is | cmux |
|---|---|---|
| `SequenceManager` (`base/task/sequence_manager/sequence_manager.h`), `ThreadControllerWithMessagePumpImpl` | One per thread. Owns the queues, selects the next task, runs a work batch per native callout (`SetWorkBatchSize`, `SetCanRunTasksByBatches`), reports to task observers (`AddTaskObserver`), takes time from an injected tick clock (`Settings::clock`, `SetTickClock`). | The manager. One per app, built in the composition root, passed by init. The type keeps the name `MainWorkScheduler` (Q1), so the 884 files that name it (tests included) do not change. |
| `TaskQueue` + `TaskQueue::Handle` (`task_queue.h`) | A FIFO with a priority (`SetQueuePriority`, `QueuePriority = uint8_t`, lower is higher), an optional fence and enable voters; immediate and delayed incoming queues; destroyed with its handle. | `MainTaskQueue` (the name moves from today's per-node queue to the general queue; a node's queue is one of them). Dropped with its owner, as today. |
| `TaskQueue::QueueEnabledVoter` (`CreateQueueEnabledVoter`, `SetVoteToEnable`) | A queue runs only if every voter votes to enable it. | `QueueVoter`. Voters: node visibility and freeze (today's `MainTaskQueue` voters), startup phase, input response, rendering starvation. |
| `InsertFence(InsertFencePosition::kNow / kBeginningOfTime)`, `InsertFenceAt`, `RemoveFence`, `BlockedByFence` | A barrier in enqueue order: tasks posted after the fence wait until it goes; one fence per queue; a delayed task gets its order when it ripens. | `queue.insertFence(.now / .beginningOfTime)`, `removeFence()`; and the display-side `CommitFence` (2.5). |
| `TaskQueueSelector` + `ActivePriorityTracker` | Strictly the highest active priority first; oldest by enqueue order inside a priority, across queues and across the immediate and delayed work queues; `kMaxDelayedStarvationTasks = 3`. No protection across priorities. | `MainTaskSelector`, the same rule. The per-class frame budgets of `MainFrameBudget` stay as budget pools (2.3): the one cross-priority rule, as Blink's `BudgetPool` / `CPUTimeBudgetPool` and `TaskQueue::Throttler`. |
| `WakeUpQueue`, `TimeDomain`, `base/task/delay_policy.h` (`kFlexibleNoSooner`, `kPrecise`), `kDefaultLeeway = 8 ms`, `kDefaultMaxPreciseDelay = 36 ms`, `kAlignWakeUps` | Delayed tasks wait in the delayed incoming queue; the manager keeps one native wake-up at the earliest desired time, aligned by leeway. | A delayed post on a runner. One wake-up timer for the whole manager: today's `MainWakeUpQueue` heap and `CFRunLoopTimer`, made private to the manager. Time comes from the injected `any Clock<Duration>`. |
| `content/browser/scheduler/browser_task_queues.h` `QueueType` | `kUserInput` above `kUserBlocking`; `kDefault` = `kUserBlocking`; `kUserVisible`; `kBestEffort` (enabled at `OnStartupComplete()`); `kStartup`; a control queue "has maximum priority and will never be disabled"; all queues start disabled, `EnableAllExceptBestEffortQueues()` early in startup. | The queue types of 2.1. |
| Blink `MainThreadSchedulerImpl`: `RenderingPrioritizationState` (`kWaitingForInputResponse`, `kRenderingStarved`), `kDefaultRenderingStarvationThreshold = 100 ms`, `is_frame_expected_after_discrete_input`, `ShouldYieldForHighPriorityWork`, `IdleHelper`, `kEndIdleWhenHiddenDelayMillis = 10000` | Priorities and voters change with state: after a discrete input that expects a frame, input and frame work go first until the frame; starved rendering is raised until the next BeginMainFrame; idle periods with deadlines. | The manager's policy (2.4). One object, never a second scheduler. |
| `viz::BeginFrameSource`, `BeginFrameObserver::OnBeginFrame`, `BeginFrameArgs` (`frame_time`, `deadline`, `interval`, `frame_id.sequence_number`), `ui::DisplayLinkMac::GetForDisplay` | One source per display; observers add and remove themselves; with no observer the source stops its timer; a newly added observer can get the missed frame (`GetMissedBeginFrameArgs`); `LastUsedBeginFrameArgs` shows what an observer took. | `DisplayClock`, the only frame source (2.6). |

### 2.1 Queues and priorities

Priority belongs to the queue, not to each task: a post site picks a runner, and the runner's queue has the
priority. A per-node queue (a pane, a tab, a page) is its own `MainTaskQueue` of a type, with that type's
priority and its own voters.

| Prio | Queue type | What goes there | Today | Chrome |
|---|---|---|---|---|
| 0 | `control` | The manager's own work: wake-up continuations, policy updates, the input-response cap, the starvation check, the idle period start. Never disabled, never fenced. | scheduler-internal timers and observers (main-thread-budget.md section 3, last paragraph) | control queue |
| 1 | `input` | What input posts and must run before any other task: injected keys (`debug.key`, the control socket's injected input), coalesced pointer delivery. AppKit's own dispatch is not a task (2.4). | `MainWorkClass.input`, `MainActorWorkQueue` urgent lane, `FrameInputCoalescer` | `kUserInput` |
| 2 | `frame` | The display clock's observers for this frame: springs, drags, terminal frame holds, page script frames. Unbudgeted, once per frame of the observer's display, in registration order. | `FrameClient`, `FrameBatchQueue(scheduler:)`, `MotionClock` | BeginMainFrame |
| 3 | `userBlocking` | The async rest of a person's action: a `.waiting` effect's reply, a rollback, a person-caused flush that missed the input-response pass. | `MainWorkClass.userBlocking` | `kUserBlocking` |
| 3 | `startup` | Launch steps the first window needs. Same priority as userBlocking; a voter disables it at `settled`. | `StartupScheduler` `.afterFirstFrame` | `kStartup` |
| 4 | `visible` | Visible changes the person did not cause: the daemon store drain, sidebar row patches, PTY-driven changes, content presentation, visible pages. Budget 2.5 ms x scale. | `MainWorkClass.visible`, `ContentPresentationScheduler` | `kUserVisible` |
| 5 | `automation` | CLI, MCP, agent, socket and page automation. Budget 1 ms x scale. One queue per control connection: inside the priority, oldest first across queues gives the round robin. | `MainWorkClass.automation`, `MainActorWorkQueue` | none (cmux goes further) |
| 6 | `background` | Work nobody sees this frame. Budget 0.5 ms x scale. Fenced until `revealed`. | `MainWorkClass.background`, `StartupScheduler` `.afterStartup` | `kBestEffort` |
| 7 | `idle` | Idle tasks with a deadline. Enabled only inside an idle period and only after `settled`. | `IdleScheduler` | `IdleHelper` queue |

Rules:
- Selection: strictly the highest enabled priority with a runnable task, oldest enqueue order first (Chrome
  `TaskQueueSelector`). Queues of one priority compete by enqueue order, so one node or one connection with a
  backlog cannot hold the others.
- A delayed task becomes runnable when it ripens and takes its enqueue order then.
- Bounded queues: a queue may have a capacity and a per-task expiry. `MainActorWorkQueue`'s 1024 / 256 limits and
  its `busy` / `timeout` replies become properties of the automation queues, not a second scheduler.
- Off the main thread, `WorkPriority` and `LaneScheduler` stay (Chrome's `ThreadPool` is a separate object from the
  `SequenceManager` too). `WorkPriority(queueType)` keeps today's table (`W/WorkPriority.swift:52`).

### 2.2 One post API

An owner gets a runner in its init. The queue type in that call is the priority; the owner names the work on the
board (`MainTaskBoard`, `MainOwnerLedger` stay as the task observer). Every post records `#fileID` and `#line`.

```swift
// Composition root: one manager, one DisplayClock per display, one injected Clock.
let main = MainWorkScheduler(clock: ContinuousClock(), displays: displays, input: sessionInputPending)

// Owners take a runner in init: the queue type is the priority.
let rows = main.runner(.visible, owner: "sidebar.rows")              // a shared queue of the type
let title = node.runner(.visible, owner: "pane.title", on: main)     // a per-node queue, voted by visibility

rows.post { apply(patch) }                                            // from the main actor
rows.postFromAnyThread { apply(patch) }                               // from any thread: one MPSC push + signal
title.post(key: .title) { show(title) }                               // replaces the pending one while held
let wake = rows.postDelayed(after: .milliseconds(300), policy: .flexible) { retry() }
wake.cancel()                                                          // also cancels a ripe task still queued
let tick = rows.postRepeating(every: .seconds(60), policy: .flexible) { refresh() }
main.idle.post(owner: "warmup", maxDelay: .milliseconds(500)) { deadline in warm(until: deadline) }
work.run(.userVisible, mayBlock: .files) { load() }.reply(on: rows) { value in show(value) }
```

What it replaces (section 3 has every row): `mainWork.post(class, owner:)`, `postFromAnyThread`, `apply`,
`node.queue(...).post`, `MainDeadline`, main-actor `DemandTimer`, `MainDelivery(class:owner:)`,
`MainRunLoopBlock(class:owner:on:)`, `FrameBatchQueue(budgeted:)`, `FrameClient(budgeted:)`, `postIdle`,
`StartupScheduler.post(.afterFirstFrame/.afterStartup, on: .Main)`, `MainActorWorkQueue.run`,
`Task { @MainActor in }`, a main-inherited `Task {}`, `MainActor.run` and `DispatchQueue.main.async`.

`await runner.apply { }` stays for the callers that must await a main-actor result; the caller's resume is still
one main-actor job (2.7).

### 2.3 The work batch, budgets and yielding

- The manager runs from one `CFRunLoopSource` (version 0, common modes). It is signaled when a queue goes from
  empty to non-empty, a fence goes, a voter enables a queue or a delayed task ripens. One callout is one work
  batch (Chrome `SetWorkBatchSize`).
- A batch takes tasks while: no input is pending (`SessionInputPending`), the selected queue is enabled and inside
  its budget pool, and the frame deadline (the main display clock's next `targetTimestamp` minus the measured
  render pass, `RenderPassMeter`) is not reached. Then it returns to the run loop, so AppKit dispatches and Core
  Animation commits. This is Chrome's yield to native between tasks.
- Budget pools: visible 2.5 ms, automation 1 ms, background 0.5 ms, userBlocking up to visible + automation, each
  x (refresh interval / 16.7 ms), reset at each frame of the main display's clock. The progress rules of
  main-thread-budget.md section 2 stay unchanged.
- A long task asks `main.shouldYield()` and continues with `runner.postContinuation { }` (the front of its queue).
- The frame queue is not part of the batch: it runs in the display clock's callout. Where the budgeted batch runs
  relative to the frame (in the tick, as the default is today, or right after the frame's commit, the
  `mainBudgetTurn` path) is a placement of the batch source, not a second scheduler. The design keeps today's
  default and leaves the change to a measured decision (Q2); either way one of the two code paths is deleted.

### 2.4 Input always first

1. AppKit event dispatch is not a task. The batch returns at the first pending event (2.3), so a pending event
   waits for at most the one task that is running.
2. The work that dispatch does is a direct call (zero-latency.md: the synchronous change in the input's turn).
   It is never posted.
3. After a discrete input whose turn expects a frame (`ActionEffect` `.applied`, `.intentEffect`, `.waiting`; a
   view asked for display; Ghostty asked to draw), the manager enters `waitingForInputResponse` (Blink's
   `kWaitingForInputResponse`): `InputResponsePass` applies the dirty person-caused work before the CA commit of
   that turn, and the input-response voter disables automation, background and idle until the end of the first
   render pass after the input, at most 100 ms. Visible keeps its budget; frame runs.
4. `input` queue tasks are priority 1, and every budget pool reports spent while one waits.
5. Rendering starvation (Blink `kRenderingStarved`): when a shown window's display clock is more than 100 ms
   late, the starvation voter disables visible, automation, background and idle until that clock's next frame.
   It is a policy of the manager; whether it is on by default is Q6 (it holds nothing today, F3).
6. Only the input path may post to `input`: a guardrail refuses `runner(.input` outside `CmuxNextInput` and the
   control socket's injected-input path. Nothing off main can raise its own work above userBlocking.

### 2.5 Fences: startup, and "show when ready, max 1 frame" (D10)

**Startup.** `background` and `idle` start with a `.beginningOfTime` fence. `revealed` removes the background
fence, `settled` removes the idle fence and turns off the `startup` queue's voter (Chrome
`EnableAllExceptBestEffortQueues()`, `OnStartupComplete()`). `StartupPhase` (the reference count with its
failsafe) stays; its only outputs are these fence and voter changes and `LaneScheduler`'s best-effort fence.
`StartupScheduler`'s `.critical` steps stay direct calls in `main()`; its `.afterFirstFrame` and `.afterStartup`
main steps become posts to `startup` and `background`.

**`CommitFence`.** Holds today implement "keep the old pixels or hide the new ones until X is ready, with a limit
of N ms", each with its own timer, limit and release path (1.3; audit-findings-1.md B1-B15). The model has one
primitive:

```swift
let fence = main.commitFence(on: paneNode, owner: "pane.switch")   // in the input's own turn
surface.onFirstFrame { fence.ready() }                              // a readiness event, never a poll
// The node's next display commit waits for ready() or for the end of the next frame of the node's
// DisplayClock, whichever comes first. Never longer. held_by and the held time go to debug.input.
```

- A `CommitFence` holds display, never input: keys go to their destination at once by id (hold-class.md rule 1).
  It never fences `control`, `input` or `frame`.
- Its limit is one frame of the node's display clock (8.3 ms at 120 Hz), not a duration, so it needs no timer: the
  clock's next frame releases it.
- When the limit releases it, the node shows what it has (a stand-in or the last frame) and the manager counts
  `fence.expired` by owner. A fence that expires often is a missing readiness event, never a reason to raise the
  limit.
- Work that truly cannot show anything in one frame is not a fence: it is a `.waiting` effect with its own count
  (zero-latency.md), and the review asks for a stand-in.

### 2.6 One frame source: `DisplayClock` per display (D4)

- `DisplayClock` is the only frame source, one per display (Chrome `DisplayLinkMac::GetForDisplay`, viz
  `BeginFrameSource`). With `vsyncHub` on, the link lives on the display's vsync thread; that is an implementation
  inside `DisplayClock` (`VSyncHub` becomes internal to it), and off-main subscribers (Ghostty surfaces) register
  on the clock's off-main observer list.
- A frame is today's `FrameTick` (`timestamp`, `targetTimestamp`, `refreshInterval`, `sequence`; Chrome
  `BeginFrameArgs`). Observers register per window; with none armed, the link pauses.
- `FrameScheduler` stops being a source: a window's frame work is a set of observers on its display's clock, and
  the window only supplies its display and its visibility. `FrameScheduler.app` (F7) goes; window-less frame work
  observes the main display's clock through the manager.
- `MotionClock`, `DisplayLinkDriver`, `PresentationClock` stay as views over a `DisplayClock` observer.
  `ControlFrameSource` goes with `MainActorWorkQueue`. The time readers (`TraceClock`, `LaunchClock`,
  `SpinnerClock`, `WebPageClock`) are not schedulers and stay; `PriorityClock` is renamed to what it is (a
  revision).
- Delays, timeouts and caps take time from the manager's injected `any Clock<Duration>`, never from a frame, and
  frames never come from that `Clock`. Two sources in all.
- The daemon store drain leaves the frame (D9). Today it is a frame client, so a stalled link stalls daemon data,
  which is why `DisplayClock` has a 100 ms stall deadline and rebuilds a link after 3 stalls. In the model the
  drain is a `visible` post when the inbox goes from empty to non-empty, and whole daemon changes apply together
  (change fences, handoff `change-fences-proposal.md`). After that the stall deadline only keeps animations
  moving through display sleep, and the rebuild rule gets its own review.

### 2.7 What replaces the executor hook (D6)

Today two code paths write `swift_task_enqueueMainExecutor_hook`: `MainJobRing.install()` (census) and
`MainJobGateHook.install(_:)` (gate). The first wins. The gate holds every unexempt main-actor job while input is
pending and releases the FIFO after the frame, because those jobs carry no class it can trust.

In the model:
- Priority is set at the post site (2.2). Everything that reaches main today as an unclassed job (135
  `Task { @MainActor`, main-inherited `Task {}`, `MainActor.run`, `DispatchQueue.main.async`, `StartupMainHop`,
  the hop of the 86 off-queue `DemandTimer`s) becomes a post to a runner (S4, S5). What stays on the main executor
  is the resume of an `await` on the main actor, and Swift's own jobs.
- Those resumes are bounded by the batch's yield: the manager starts no posted task while input is pending, and a
  resume is one job between two batches, so input waits for at most one job, not a FIFO.
- The gate is deleted: `MainJobGate*`, `MainJobGateHook`, the classed hold in `MainWorkScheduler+Classed.swift`,
  the gate bits of `InputPendingState`, feature `mainJobGate` and setting `debug.mainJobGate` (two switches, D1).
  The gate is off in every channel today, so the deletion changes no default behavior.
- One hook owner: `MainJobRing` (CmuxNextCompat, Debug and bench builds only), and it only records. Its
  `DispatchQueue.main.async` re-post (`MainJobRing.swift:266`, D12) is reviewed with it: it is how a hook forwards
  a job with its QoS, and it has to stay inside the recorder. A guardrail refuses the hook symbol outside
  `MainJobRing.swift`.
- If the census then shows that resumes still delay input (input `dispatch_start` minus the event's timestamp
  during an automation storm, optimized build), the fix is a reply form for those awaits (`.reply(on:)`), not a
  global reorder. Mapping job priority onto the queues through a supported custom main executor, if the toolchain
  offers one, is Q4.

## 3. The mapping

### 3.1 Owners

| Owner | Becomes | Kept | Deleted |
|---|---|---|---|
| `MainWorkScheduler` | The sequence manager (same type name): queues, selector, voters, fences, batch source, budget pools, delayed tasks, `runner(...)` | `MainFrameBudget` as the budget pools and progress rules; `MainTaskBoard`, `MainOwnerLedger`, `MainTurnMeter` as task observers | `post(_:owner:)`, `postFromAnyThread`, `post(class:)`, `postFromAnyThread(class:)`, `callbackClass` (moved to runners); the per-class `FrameBatchQueue`s; the classed hold |
| `FrameScheduler` | Per-window observer sets on `DisplayClock` (a view) | `FrameClient` as the frame observer type (`frame` queue) | The budgeted `FrameScheduler` and `FrameClient(budgeted:)`, `FrameBatchQueue(budgeted:)`; `FrameScheduler.app` |
| `LaneScheduler` | Unchanged (off main, the thread pool) | All | none |
| `MainActorWorkQueue` | Automation queues, one per connection, with capacity and expiry; injected input posts to `input` | Its request contract (`busy`, `timeout`, order per connection) | The type, `ControlFrameSource`, `MainQueueFrameSource`, its deadline `Task` |
| `ContentPresentationScheduler` | A keyed `visible` queue per window plus a "one create per frame" budget pool; a person's cause goes through the input-response pass | `showNow` (the synchronous path) | The type and its two batchers |
| `IdleScheduler` | The `idle` queue; the idle-period policy moves into the manager | `IdleDeadline`, the period rules | The scheduler object, `IdlePeriodTimer` (the manager's wake-up timer arms periods); F1 is fixed by construction (the manager knows its next delayed task) |
| `StartupScheduler` | The `startup` queue and the startup fences; `.critical` stays direct calls; lane steps stay on `BackgroundWork` | `StartupPhase`, `StartupTaskLog` | Its arrays, its `FrameBatchQueue`/`FrameClient`, `StartupMainHop`, its failsafe `DemandTimer` |
| `MainDeadlineScheduler` + `MainDeadline` | `runner.postDelayed` / `postRepeating` with a `DelayPolicy` (`.precise` under 36 ms, `.flexible`, `.whenHidden`) | Alignment rules, the hidden 5-minute pool, `CPUTimeBudgetPool`; the 8 `*Deadline` protocols as seams over the delayed-task handle | Both types, after the codemod |
| `MainWakeUpQueue` | The manager's private wake-up queue (one timer) | Heap, alignment, `fireBudget`, hidden heap | Public construction (F2: the six private instances) |
| `MainTaskQueue` | The general `MainTaskQueue` of the manager; a node's queue is one with node voters | Voters, keyed posts, freeze | The pump-into-`MainWorkScheduler.post` layer |
| `MainJobGate` | Deleted | none | All gate files, the feature and the setting |
| `RenderStarvationGuard` | A manager policy (the starvation voter) | `isStarved` logic, `stall.render_starved` | The type and its veto inside `MainFrameBudget` |

### 3.2 Clocks and frame sources

| Type | Becomes |
|---|---|
| `DisplayClock` | The only frame source, one per display |
| `VSyncHub` | Internal to `DisplayClock` (its vsync-thread link); no public type |
| `FrameScheduler` | A per-window observer set on `DisplayClock` |
| `MotionClock`, `DisplayLinkDriver`, `PresentationClock` | Views over a `DisplayClock` observer (unchanged API) |
| `ControlFrameSource`, `MainQueueFrameSource` | Deleted with `MainActorWorkQueue` |
| `TerminalVSyncSource` | `DisplayClock`'s off-main observer seam; its stall `DemandTimer` goes with D9 |
| `TraceClock`, `LaunchClock`, `SpinnerClock`, `WebPageClock` | Unchanged time readers (not schedulers) |
| `PriorityClock` | Renamed (a revision counter) |
| `ManualClock` | The test `Clock` injected into the manager |
| `ClockDeadline` | A delayed post |

### 3.3 The half-done migrations converge (D5)

| Old | Count now | Goes to | Wave |
|---|---|---|---|
| `postFromAnyThread` | 211 sites in 158 files | `runner.postFromAnyThread` (same semantics, priority from the runner) | S3 (codemod) |
| `mainWork.post(.class` / `.apply(.class` / `.reply(on:)` | 47 / 88 / 39 | `runner.post` / `runner.apply` / `.reply(on: runner)` | S3 (codemod) |
| `MainDeadline(` | 153 in 119 files | `runner.postDelayed` / `postRepeating` | S4 (codemod) |
| `DemandTimer(` in main-actor code | 20 files hold one (of 78 files with a `DemandTimer`) | `runner.postDelayed` | S4 |
| `DemandTimer` main path (`wakeUps:`, `mainWork:` init, `scheduleOnMain`) | 2 users (`ChromiumHostBusyDeadline.swift:16`, `BusyWatchdog.swift:136`), 0 for `mainWork:` | Deleted; those 2 become delayed posts | S4 |
| `DemandTimer` off main | about 66 sites | Stays as the off-main delayed task (Q3) | none |
| `Task { @MainActor` | 135 in 103 files (App 48, Browser 23, Pages 12, Wakeups 8, Design 5, Control 5) | a runner post, or `.reply(on:)` for an async body | S5 |
| `MainActor.run` 5, `DispatchQueue.main.async` 2, `CFRunLoopPerformBlock` 7, `RunLoop.main.perform` 1, `MainDelivery(` 30, `StartupMainHop` | | a runner post (`MainDelivery` keeps its inline-on-main rule as `runner.deliver { }`) | S5 |
| `// main-hop-allow:` | 337 | each converted, or kept only for an AppKit order (focus, menu tracking), with the list cut below 50 (D8) | S5 |
| `// timer-class-allow:` | 106 | reviewed in S4; only off-main ones stay | S4 |

After S5 there is one way to post main-thread work (a runner) and one way to delay it (a delayed post), and the
guardrail refuses every old form with no escape except a closed file list.

## 4. Migration plan

Rules for every step:
- One branch per step (`cp/seqmgr-sN-...`), cut from the train tip, small enough for one review. A step that is a
  codemod has two commits: the script and its output; the reviewer reads the script and samples the output.
- Red then green: the step's behavioral test is committed first, fails on the base and passes on the head, run on
  the fleet (`cmux-ci run --class isolated --script ... --ref SHA`), never on a person's Mac. No CI test, job or
  gate is added; the step's tests are suite tests run by the agent.
- Benches before and after on the same fleet host, optimized build (`cmux-ci build cmux --builder mac --release
  --ref SHA --tag chrome-parity-...`, the bench configuration), 120 Hz virtual display, light and STRESS:
  - first-5s: `first-5s-typing.py` through `scripts/measure/split-spring.sh --suite=first5s`: 0 terminal keys with
    `dispatchStart` > 50 ms in the first 5 s, and no worse p95/p99 than the base.
  - key-to-frame: `sidebar-churn-typing.py --input real` and `typing-frame-bench.py`; for automation steps also
    `automation-typing-bench.py` and `bench_cli_storm.py` (throughput).
  - frame-time: `bench_frames.py` with the `frame_pacing.*` lab stories (dropped frames, p99 frame interval).
  - timer and idle steps: `bench_idle.py` (wakeups per second, idle app and hidden workspaces).
  - startup step: the `launch-*` lab stories.
  "No regression" means no worse than the base beyond the lab's noise band (`perf_stats.py` compare) at p50, p95
  and p99; numbers go in the commit and in perf-lead.md section 5 with sha, host, macOS and refresh rate.
- The old API is deleted in the step's last commit, and a `guardrails.py` rule refuses it with no `-allow`
  escape, outside a closed file list in the rule. guardrails.py runs only in the pre-push hook
  (`prepush-gate.py`), not in CI, so this adds no CI gate. In-flight branches get the step's codemod script.
- Every public signature change in CmuxNextWakeups needs the Performance Lead's OK (main-thread-budget.md
  section 12); approving this plan is asked as Q9.

| Step | Scope | Behavioral test (red first) | Benches | Deleted, and the rule that refuses it |
|---|---|---|---|---|
| S1 | One wake-up queue, one injected `Clock` (F2). Remove the six private `MainWakeUpQueue` fallbacks and the default `MainDeadlineScheduler(work: MainWorkScheduler(...))` arguments; inject the app's. Fix F1 (wire `nextFireNanos` into the idle period). Fix F6 in threading-model.md. | An app-shaped rig with CEF, WebKit and the store: one wake-up timer for all their deadlines (`WakeupLedger` count == 1); an idle period ends at the next deadline | bench_idle, first-5s | `MainWakeUpQueue(` and `MainDeadlineScheduler(` outside the composition root and TestSupport |
| S2 | The manager core inside `MainWorkScheduler`: `MainTaskQueue` as the general queue (priority, voters, fence), `MainTaskSelector`, the batch source, budget pools from `MainFrameBudget`, `runner(...)`. The class queues move onto it; the public post API is unchanged in this step. `MainTaskQueue` per node becomes a queue of the manager (no pump layer). | Selector: with input pending, nothing posted runs; oldest-first across two queues of one priority; a fence holds later posts and keeps earlier ones; a disabled voter holds a node queue; budgets: a visible flood leaves the automation share, all with `ManualClock` and a fake `DisplayClock` | key-to-frame (light, STRESS), frame-time, bench_cli_storm | The node pump layer; the per-class `FrameBatchQueue`s inside the scheduler |
| S3 | Codemod 1: every `post` / `postFromAnyThread` / `apply` / `.reply(on:class:)` site to a runner taken in its owner's init. | A post from another thread lands in the runner's queue with its owner and line on the board (existing board tests, moved to runners) | key-to-frame, first-5s | `mainWork.post(`, `postFromAnyThread(` on the scheduler, `post(class:`, `callbackClass(` |
| S4 | Delayed tasks (D5, timers): `postDelayed` / `postRepeating` on the manager's wake-up queue; codemod of the 153 `MainDeadline(` sites; the 20 main-actor `DemandTimer` files; the `DemandTimer` main path; the 106 `timer-class-allow` escapes reviewed. | A flexible delayed post fires no sooner than its delay and on the 8 ms grid; precise under 36 ms is exact; a hidden node's repeating post joins the minute pool after 5 min; cancel after ripening runs nothing | bench_idle (idle and hidden), first-5s | `MainDeadline`, `MainDeadlineScheduler`; `DemandTimer` in main-actor code and its `wakeUps:` / `mainWork:` / `scheduleOnMain` |
| S5 | Raw hops (D5): 135 `Task { @MainActor`, main-inherited `Task {}`, `MainActor.run`, `DispatchQueue.main.async`, `CFRunLoopPerformBlock`, `RunLoop.main.perform`, `MainDelivery(` and `StartupMainHop` to runner posts; the 337 `main-hop-allow` escapes cut below 50 | Per migrated family, the order test it needs (for example a notification click still runs after the event that caused it); a census run (`CMUX_NEXT_MAIN_JOB_CENSUS=1`, bench build) shows unattributed main jobs during an automation storm at or below an agreed number (Q5) | key-to-frame with automation, first-5s, `MainTurnMeter` `unattributed_share` | The raw forms, with no escape except the closed list |
| S6 | The executor hook (D6): delete `MainJobGate` and its files, the classed hold, the gate bits, feature `mainJobGate` and setting `debug.mainJobGate`; `MainJobRing` is the one hook owner | A held-job test is deleted with the gate; a new test: the batch starts no posted task while input is pending (the property the gate stood in for) | key-to-frame with automation (gate off on both sides: the default), first-5s | `swift_task_enqueueMainExecutor_hook` outside `MainJobRing.swift` |
| S7 | Owners into queues: `MainActorWorkQueue` to automation queues with capacity and expiry; `ContentPresentationScheduler` to a keyed visible queue and a create pool; `IdleScheduler` to the idle queue; `StartupScheduler` to the startup queue and fences; `RenderStarvationGuard` to the starvation voter (default per Q6). One sub-branch per owner (S7a-S7e). | Per owner, its existing contract tests run against the queue form (busy and timeout; one create per frame; idle deadline; no afterStartup task before completion; starvation holds visible work until the next frame) | per sub-branch: automation-typing and bench_cli_storm (S7a); key-to-frame and tab-switch (S7b); bench_idle (S7c); launch stories and first-5s (S7d); frame-time (S7e) | The five types, `ControlFrameSource`, `IdlePeriodTimer`, `StartupMainHop` |
| S8 | One frame source (D4): `FrameScheduler` as observer sets on `DisplayClock`; `FrameScheduler.app` deleted; `VSyncHub` internal to `DisplayClock`; `TerminalVSyncSource` as the clock's off-main seam | Two windows on two displays (60 and 120 Hz) get frames from their own display only; no observer: 0 links; a late observer gets the missed frame | frame-time, key-to-frame, bench_idle | `check-concurrency.sh` display-link owners = `DisplayClock.swift` only; `FrameScheduler.app`; public `VSyncHub` |
| S9 | The daemon drain leaves the frame (D9): a `visible` post on inbox readiness; with change fences (PL-daemon's wire) a whole change in one batch; then the `DisplayClock` stall and rebuild rule reviewed | With the link stalled (display asleep), a daemon event still applies within one batch; a fenced 40-event change applies whole under a 1-event budget | key-to-frame under a CLI storm, frame-time | The store drain as a `FrameClient` |
| S10 | `CommitFence` (D10) and the holds, one family per sub-branch: paint holds (`PanePaintHold`, workspace paint hold, tab switch), `TerminalFrameHold`, `FirstTabHold` and `NewTabSuccession`, `SidebarSelectionHold`, `LaunchImageHold`, the rest | Per family: the switch shows content or the stand-in within one frame of the clock; keys typed during the fence reach the new destination (hold-class.md rule 1) | first-5s (extended to Cmd-T and switches, hold-class.md item a), key-to-frame, frame-time | Each converted hold type; a rule refuses a new `*Hold` or `*Deadline` type that arms its own timer |

Order: S1 and S2 first (S1 is independent and small). S3 needs S2. S4 and S5 need S3 and can run in parallel
(different files, two codemods). S6 needs S5's census number. S7a-S7e need S2-S4 and are independent of each
other. S8 needs S7a (it removes `ControlFrameSource`) and S2. S9 needs S8 and PL-daemon's change fences. S10 needs
S8 (the fence's limit is a clock frame).

## 5. Risks and open questions

Risks:
- R1 Train conflicts. S3, S4 and S5 change hundreds of files that in-flight branches also change. Mitigation: each
  codemod is a script that in-flight branches run on themselves; the deleting commit lands when the train is
  drained; the guardrail tells a late branch which script to run.
- R2 Rebuild cost. CmuxNextWakeups is under most of the 98 targets; every public change rebuilds them. Mitigation:
  new API first, codemod second, deletion last; at most one public-surface change per step.
- R3 Nested run loops. Menu tracking, modal panels, live resize and drag sessions run the run loop in their own
  modes. The batch source and the wake-up timer must be in common modes (as today's blocks and timer are), and the
  input-response and starvation voters must not hold work forever inside a tracking loop (today the gate releases
  at a nested loop's entry). Each S2 and S7 test set includes a nested-loop case.
- R4 The CEF message pump. `CEFMessagePump` runs Chromium's UI-thread work in slices on main and is not a task of
  the manager. Its slice policy (`cefPumpFrameDeadline`, `admitsSlice`) has to read the same frame deadline and
  starvation state. The design treats the pump as a native callout like AppKit's (it yields between slices), not
  as a queue; that is Q8.
- R5 `postFromAnyThread` cost. Today one run-loop block per post. The manager uses one lock-free MPSC push plus
  one source signal per empty-to-non-empty change; this has to be measured (the hot path of 211 sites), and the
  push must not allocate per post beyond the closure.
- R6 Behavior changes hidden in a refactor. Budget placement, the starvation voter and the create cap change what
  a person sees. Each is a separate, measured decision (Q2, Q6), never part of a codemod.
- R7 Main-actor resumes stay unattributed. The model bounds their wait (one job) but does not class them. If the
  census number after S5 is high, more await sites move to the reply form.
- R8 The one-frame fence limit can show a stand-in where a hold showed nothing for up to 3 s. That is the intended
  trade (show at once, reconcile), but it needs a good stand-in per family (S10).

Open questions for cmux-ad (each one is self-contained):
- Q1 Type name: keep `MainWorkScheduler` as the manager's name (no rename in 884 files), or rename it to
  `MainSequenceManager` with a codemod in S3. Recommendation: keep the name.
- Q2 Budget batch placement: keep the batch in the display tick (today's default), or move it to its own run-loop
  turn right after the frame's commit (today's `mainBudgetTurn`, off). Either way one path and the
  `mainBudgetTurn` switch are deleted in S2; the choice needs a key-to-frame and frame-time measurement first.
  Recommendation: measure in S2, keep the tick placement unless the after-commit turn wins.
- Q3 Off-main `DemandTimer` (about 66 sites): keep it as the off-main delayed task, or fold it into
  `BackgroundWork` as `work.postDelayed(priority, after:)` (Chrome `ThreadPool::PostDelayedTask`) in a later step.
  Recommendation: keep it now, fold it later.
- Q4 A custom main executor: if the Swift 6.2 toolchain has a supported API to replace the main executor, map main
  job priority onto the queues there (one owner, no hook), or keep the hook record-only and never reorder.
  Recommendation: record-only now; check the toolchain separately.
- Q5 The census bound for S6: what number of unattributed main-actor jobs per second during an automation storm
  is acceptable to delete the gate. Recommendation: delete the gate in S6 whatever the number (it is off in every
  channel), and use the number to pick the await sites for the reply form.
- Q6 Rendering starvation: today it holds nothing (`holdsWork: false` hard-coded, feature not read). Make it a
  manager voter that is on by default after a frame-time measurement, or delete it.
- Q7 `CommitFence` limit: one frame of the node's display clock for every family, or a second, longer limit for
  launch (the 1.5 s launch reveal). Recommendation: one frame everywhere; launch shows the launch picture as the
  stand-in.
- Q8 The CEF pump: treat it as a native callout that reads the manager's deadline (this design), or give it a
  queue type of its own (main-thread-budget.md section 10 plans input class while a page has focus, frame class
  otherwise).
- Q9 Approve the program as a whole under main-thread-budget.md section 12 (frozen CmuxNextWakeups API), so each
  step does not ask again; or ask per step.
- Q10 S9 (the daemon drain off the frame) needs PL-daemon's change fences: keep it in this program, or move it to
  D9's owner.

## 6. Sources

Chrome (chromium.googlesource.com, main): `base/task/sequence_manager/sequence_manager.h`, `task_queue.h`,
`task_queue_selector.h`; `content/browser/scheduler/browser_task_queues.h`;
`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.h`;
`components/viz/common/frame_sinks/begin_frame_source.h`; `base/task/delay_policy.h`,
`base/task/task_features.h`. cmux: main-thread-budget.md, threading-model.md (:128-145, :213-258),
zero-latency.md, PATTERNS.md (P5, P6a, P14, P15), chrome-parity/p06-scheduler.md section 3, the handoff notes
audit-findings-1.md (B), audit-findings-2.md (D3-D10), hold-class.md and change-fences-proposal.md.
