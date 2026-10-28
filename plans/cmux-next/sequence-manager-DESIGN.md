# One main-thread sequence manager (design, for review by cmux-ad)

Status: DESIGN ONLY, revision 2 (after one independent review, section 7). No product code may start from this file until cmux-ad has reviewed it
(audit-findings-2.md D3, binding). Covers D3, D4, D5, D6 and D10. Read at origin/perf/chrome-parity
`8a75e216703`. Paths are under `Packages/macOS/CmuxNext/Sources/` unless they say otherwise; `W/` is
`CmuxNextWakeups/`. Counts leave out `Tests/`, `TestSupport/` and `///` doc lines.

## 0. Summary

Today 12 objects decide when main-thread work runs. Most of them are layers of one design that was never
finished: `MainWorkScheduler` has the class queues; `MainTaskQueue`, `MainDeadline`, `StartupScheduler`,
`IdleScheduler`, `ContentPresentationScheduler` and `MainActorWorkQueue` each post into it or wrap it with a
second queue; `FrameScheduler` runs it on a frame tick; `MainJobGate` reorders the main executor because a large
part of main-thread work (131 `Task { @MainActor`, the `Task` hop of every `DemandTimer` that is not on the
wake-up queue) does not go through it.

The target is Chrome's model, one level stricter:

1. One sequence manager on the main thread (Chrome `base/task/sequence_manager`), with typed task queues
   (`control`, `input`, `frame`, `userBlocking`, `startup`, `visible`, `automation`, `background`, `idle`), each
   queue with a priority, enable voters and an optional fence.
2. One post API: a `TaskRunner` (manager, queue, owner) that an owner gets in its init. Every post states its
   priority at the post site; delayed work is a delayed post on the same runner, timed by the injected `Clock`.
3. Input first for every posted task: the batch yields at the first pending input, and after a discrete input
   the input-response voter holds automation, background and idle until the frame (Blink
   `kWaitingForInputResponse`), with today's progress rules as a floor. Main-actor jobs that are not posted (await
   resumes, framework tasks) stay FIFO on `DispatchQueue.main`, as they are in every shipped channel today.
4. Fences: startup fences (Chrome `OnStartupComplete`) and one `CommitFence` for "show when ready, at most one
   frame" that replaces the hold types (D10).
5. Two time sources only: one `DisplayClock` per display (Chrome `BeginFrameSource` / `DisplayLinkMac`) for
   frames, one injected `any Clock<Duration>` for delays (D4). No executor reorder: `MainJobGate` goes, and the
   executor hook has one owner that only records (D6).

The migration is 13 steps (section 4: S0-S10, with S2 in three parts); S3, S5, S7 and S10 split further into
one branch per package or per family. Every step that replaces an API deletes it at its end and adds a pre-push
guardrail rule that refuses it.

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
| 9 | `MainWakeUpQueue` | `W/MainWakeUpQueue.swift:38` (409), `MainWakeUpHeap.swift` (150), `MainWakeUpTimer.swift` | One `CFRunLoopTimer` (common modes, parked between arms) per queue; two heaps by latest time (visible, hidden at whole uptime seconds); a `Mutex` so inserts come from any thread; a fire runs due entries for at most 2 ms (`fireBudget`, `:54`) then arms a continuation | `insert(owner:after:policy:_:)` (`:176`), `insert(owner:at:window:ledgerReason:_:)` (`:223`), `insertHidden` (`:192`), `cancel` (`:270`) | 11 direct inserts in 7 files: `AlignedWakeups.swift:80-108`, `DemandTimer.swift:217`, `MainJobGate+RunLoop.swift:87`, `MainWorkScheduler+Classed.swift:203`, `CEFPumpTimer.swift:93`, `CEFEnergySaver.swift:47`, `GhosttyEnergySaver.swift:42` | Earliest latest-time first; precise entries under 36 ms never aligned; no classes (what an entry posts carries the class) | 0 wakes when empty; hidden entries never ride a visible fire | threading-model.md :134 "The one main run-loop `CFRunLoopTimer`"; idle-wakeups.md section 9. 7 `MainWakeUpQueue(` sites: `CmuxNextApp.swift:40` is the app's; `MainWorkScheduler.swift:150`, `CEFRuntime.swift:236`, `CEFEngine.swift:107`, `DaemonStore.swift:234`, `WebKitEngine.swift:136`, `MockBrowserEngine.swift:29` make a private one (own timer) when none is passed. The app always passes one (F2) |
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
- F2 Seven `MainWakeUpQueue(` constructions (row 9). The app passes its one queue everywhere it builds those
  owners (`DaemonService.swift:125`, `AppServices+Chromium.swift:170`, `TabContentCache.swift:240`,
  `CEFRuntime.swift:275`, `LaunchOrder`), so the six fallbacks are taken only by tests and default arguments. A
  trap for a new caller, not a second timer in the app today.
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

Delay mechanisms beside these: `DemandTimer` (88 `DemandTimer(` sites in 78 files; no class, node or alignment).
Only 2 are built with a wake-up queue (`ChromiumHostBusyDeadline.swift:16`, `BusyWatchdog.swift:136`), but 38
call sites in 34 files use `scheduleOnMain` / `scheduleOnMainIfIdle`: without a queue those sleep on the
cooperative pool (`Task { @concurrent }`) and then hop to main. Among them are scheduler timers that must never
wait behind the classes they measure: the reveal deadline (`StartupPhase.swift:176,272`), the display stall
deadline (`DisplayClock.swift:490`) and the coalescer fallback (`FrameInputCoalescer.swift:388`). Others: `MainDeadline` (row 8), `AlignedWakeups` (direct, CEF), `IdlePeriodTimer` /
`MainRunLoopPreciseTimer`, `CEFPumpTimer`, `DeadlineHeap` (daemon connection, `LineTransport+State.swift:11`, its
own timer), `HostPressureMonitor` (its own timer), `Deadline` (an async race helper, `W/Deadline.swift:19`).

So the real frame sources are two link owners (`DisplayClock`, `VSyncHub`) and one relay (`FrameScheduler`).
Five types are views on frames, five are time readers or tests, and one is not a clock. D4 asks for exactly two
sources of main-thread time: one `DisplayClock` per display and one injected `Clock`. Off-main timers
(`DeadlineHeap`, `HostPressureMonitor`, off-main `DemandTimer`) are outside this design; they take the same
injected `Clock` but keep their own threads.

### 1.3 Hold and deadline types (D10 input)

42 types contain `Hold` (26 end in `Hold`); 31 end in `Deadline` (11 protocols, 8 of them satisfied by
`extension MainDeadline`). Only 4 holds are held work queues (`ClassedHold`, `PageDeliveryHold`, `SidebarRowHold`,
`StoreStage.Hold`). Most of the rest keep old pixels, or hide new ones, until something is ready, each with its own
limit and timer: `PanePaintHold` (`AgentPane/PanePaintHold.swift:18`), the workspace paint hold
(`WorkspaceContentView+PaintHold.swift:9`, up to 500 ms), `TerminalFrameHold` (`Terminal/TerminalFrameHold.swift:18`,
up to 3 s), `FirstTabHold` (2 s), `SidebarSelectionHold`, `LaunchImageHold` (3 s), `SpringPageHold`,
`FloatingChatFrameHold`, `WorkspaceAutoNameHold`. These are the targets of `CommitFence` (2.5). The `*Deadline`
protocols are seams over `MainDeadline`; they become seams over a delayed-task handle (S4).

### 1.4 Pieces that are not owners but that the model must place

| Piece | File | What it does today | In the model |
|---|---|---|---|
| `MainFrameBudget` | `W/MainFrameBudget.swift` (579 + 7 extensions) | `mayRun(class)`, the class shares, progress rules, input-response state, the starvation veto | Budget pools and the voters of 2.3 and 2.4 (kept code, new owner) |
| `InputResponsePass` | `W/InputResponsePass.swift` (181), `InputResponseRunLoop.swift` | A `beforeWaiting` observer at order 1,000,000 that applies person-caused work before the CA commit | Kept as is: the input-response policy's apply step (2.4) |
| `ObservationCause`, `mainWork.causes` | `W/ObservationCause.swift` (161) | The cause of a change (person, frontend, program, automation) routes a post: person to the pass, person or frontend to the next frame unbudgeted, others to the class queue (`FrameBatchQueue.enqueue(cause:)`, `FrameBatchQueue.swift:117-127`; main-thread-budget.md section 9) | Cause routing on every runner post (2.2) |
| `VisibleObservation`, `ServiceObservation` (211 sites), `FrameObservation`, `ObservationLoop`, `MainActorObservation` | `W/` | Observation primitives that post their apply in a class with a node | Unchanged API; they take a runner instead of `mainWork` + class (S3) |
| `MainRunLoopBlock` | `CmuxNextCompat/MainRunLoopBlock.swift:47` | Common-modes run-loop block; the scheduler's next-turn path and `postFromAnyThread` today | Private to the manager (its signal), refused elsewhere after S5 |
| `MainDelivery`, `callbackClass` | `W/MainDelivery.swift` | Runs inline when already on main (charged on the board), else posts | `runner.deliver { }` keeps the inline-on-main rule (S5) |
| `AfterFrameCommit` | `W/AfterFrameCommit.swift` | One-shot or every-pass observer after the CA commit (CEF deferred browsers, the gate's release, task 201's planned batch signal) | Kept as a run-loop seam; its users post with a fence: `queue.insertFence(.now)` removed after the commit |
| `FrameInputCoalescer` | `W/FrameInputCoalescer.swift` (398) | Per-window input stage that runs at the frame tick before frame clients, with its own fallback timer | The first observer of each window's frame (2.6), not an `input` queue; its fallback is a `control` delayed task |
| `CEFMessagePump` | `CmuxNextBrowser/CEF/CEFMessagePump.swift` | Chromium UI-thread slices on main, its own timer (`CEFPumpTimer.swift:93`, a direct `MainWakeUpQueue` insert) | A native callout like AppKit's that reads the manager's frame deadline and starvation state (R4, Q8) |
| Direct `MainWakeUpQueue` inserts | `CEFPumpTimer.swift:93`, `CEFEnergySaver.swift:47`, `GhosttyEnergySaver.swift:42` | Wakes on the shared timer with no class | `control`-queue delayed tasks (the manager exposes them to these three seams only) |
| `CPUTimeBudgetPool` | `W/CPUTimeBudgetPool.swift` (206) | Hidden-node CPU budget, 10 ms/s, 100 ms cap | Kept, as the hidden-queue throttler's budget (2.1) |
| `BackgroundWork` `.reply(on:)` | `W/BackgroundWork.swift:359` | Off-main work, main reply through `postFromAnyThread` | `.reply(on: runner)` |

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
| `TaskQueueSelector` + `ActivePriorityTracker` | Strictly the highest active priority first; oldest by enqueue order inside a priority, across queues and across the immediate and delayed work queues; `kMaxDelayedStarvationTasks = 3`. No protection across priorities. | `MainTaskSelector`, the same rule. The per-class frame budgets of `MainFrameBudget` stay (2.3). They are cmux's own rule: Blink's `BudgetPool` / `CPUTimeBudgetPool` throttle hidden and background frame queues, not foreground classes per frame. cmux uses that Blink mechanism only for hidden queues (2.1). Inside the automation priority cmux takes turns by queue, not oldest-first (2.1, a stated difference from Chrome). |
| `WakeUpQueue`, `TimeDomain`, `base/task/delay_policy.h` (`kFlexibleNoSooner`, `kPrecise`), `kDefaultLeeway = 8 ms`, `kDefaultMaxPreciseDelay = 36 ms`, `kAlignWakeUps` | Delayed tasks wait in the delayed incoming queue; the manager keeps one native wake-up at the earliest desired time, aligned by leeway. | A delayed post on a runner. One wake-up timer for the whole manager: today's `MainWakeUpQueue` heap and `CFRunLoopTimer`, made private to the manager. Time comes from the injected `any Clock<Duration>`. |
| `content/browser/scheduler/browser_task_queues.h` `QueueType` | `kUserInput` above `kUserBlocking`; `kDefault` = `kUserBlocking`; `kUserVisible`; `kBestEffort` (enabled at `OnStartupComplete()`); `kStartup`; a control queue "has maximum priority and will never be disabled"; all queues start disabled, `EnableAllExceptBestEffortQueues()` early in startup. | The queue types of 2.1. |
| Blink `MainThreadSchedulerImpl`: `RenderingPrioritizationState` (`kWaitingForInputResponse`, `kRenderingStarved`), `kDefaultRenderingStarvationThreshold = 100 ms`, `is_frame_expected_after_discrete_input`, `ShouldYieldForHighPriorityWork`, `IdleHelper`, `kEndIdleWhenHiddenDelayMillis = 10000` | Priorities and voters change with state: after a discrete input that expects a frame, input and frame work go first until the frame; starved rendering is raised until the next BeginMainFrame; idle periods with deadlines. | The manager's policy (2.4). One object, never a second scheduler. Stricter than Blink: Blink raises the priority of rendering and input in these states; cmux also disables the lower queues by voters (today's `MainFrameBudget.mayRun` behavior, kept). |
| `viz::BeginFrameSource`, `BeginFrameObserver::OnBeginFrame`, `BeginFrameArgs` (`frame_time`, `deadline`, `interval`, `frame_id.sequence_number`), `ui::DisplayLinkMac::GetForDisplay` | One source per display; observers add and remove themselves; with no observer the source stops its timer; a newly added observer can get the missed frame (`GetMissedBeginFrameArgs`); `LastUsedBeginFrameArgs` shows what an observer took. | `DisplayClock`, the only frame source (2.6). |

### 2.1 Queues and priorities

Priority belongs to the queue, not to each task: a post site picks a runner, and the runner's queue has the
priority. A per-node queue (a pane, a tab, a page) is its own `MainTaskQueue` of a type, with that type's
priority and its own voters.

| Prio | Queue type | What goes there | Today | Chrome |
|---|---|---|---|---|
| 0 | `control` | The manager's own work: wake-up continuations, policy updates, the input-response cap, the starvation check, the idle period start. Never disabled, never fenced. | scheduler-internal timers and observers (main-thread-budget.md section 3, last paragraph) | control queue |
| 1 | `input` | What input posts and must run before any other task: `debug.key` from the Debug menu, an input subscriber's continuation. AppKit's own dispatch is not a task (2.4). A control connection's injected keys do not post here: its queue is raised to this priority (automation row). Coalesced pointer delivery is the first frame observer (1.4), not this queue. | `MainWorkClass.input` | `kUserInput` |
| 2 | `frame` | The display clock's observers for this frame: springs, drags, terminal frame holds, page script frames. Unbudgeted, once per frame of the observer's display, in registration order. | `FrameClient`, `FrameBatchQueue(scheduler:)`, `MotionClock` | BeginMainFrame |
| 3 | `userBlocking` | The async rest of a person's action: a `.waiting` effect's reply, a rollback, a person-caused flush that missed the input-response pass. | `MainWorkClass.userBlocking` | `kUserBlocking` |
| 4 | `visible` | Visible changes the person did not cause: the daemon store drain, sidebar row patches, PTY-driven changes, content presentation, visible pages. Budget 2.5 ms x scale. | `MainWorkClass.visible`, `ContentPresentationScheduler` | `kUserVisible` |
| 4 | `startup` | `StartupScheduler`'s `.afterFirstFrame` main steps. Today they are budgeted `visible` (`StartupScheduler.swift:180`), so the queue has visible's priority and shares visible's budget pool: the priority does not change. Fenced until the first frame commits. | `StartupScheduler` `.afterFirstFrame` | `kStartup` (Chrome puts it higher; cmux keeps today's level, R6) |
| 5 | `automation` | CLI, MCP, agent, socket and page automation. Budget 1 ms x scale. One queue per control connection, FIFO, holding that connection's injected keys too. While the head of a connection's queue is injected input, the manager raises that queue to `input` priority (Chrome `SetQueuePriority`); when the head is a request again, it goes back. So a key never passes its own connection's earlier requests (`MainActorWorkQueue.swift:24-28`: a focus change then a key types into the new focus), and a waiting key still goes ahead of every other connection and of visible work. | `MainWorkClass.automation`, `MainActorWorkQueue` (its urgent lane included) | none (cmux goes further) |
| 6 | `background` | Work nobody sees this frame. Budget 0.5 ms x scale. Fenced until `revealed`. `StartupScheduler`'s `.afterStartup` main steps are a background queue with its own frame-count pool of one task per frame (today's pacing, `StartupScheduler.swift:133-135`). | `MainWorkClass.background`, `StartupScheduler` `.afterStartup` | `kBestEffort` |
| 7 | `idle` | Idle tasks with a deadline. Enabled only inside an idle period and only after `settled`. | `IdleScheduler` | `IdleHelper` queue |

Rules:
- Selection: strictly the highest enabled priority with a runnable task (Chrome `TaskQueueSelector`). Inside a
  priority, two rules, chosen per queue type:
  - oldest enqueue order first across queues (Chrome's rule): `control`, `input`, `userBlocking`, `visible`,
    `startup`, `background`, `idle`;
  - round robin by queue, least recently run first, FIFO inside each queue: `automation`. This is today's
    fairness (`MainActorWorkQueue.swift:13`: "a client that floods the queue delays only its own requests";
    budgeted frame clients are least recently run first, `FrameScheduler.swift:78-80`). Chrome's oldest-first
    would let a connection that posted 256 requests first hold a later one-request connection for all 256.
- A delayed task becomes runnable when it ripens and takes its enqueue order then.
- A continuation (`postContinuation`) goes to the front of its own queue but takes a new enqueue order, so across
  queues of the same priority it does not keep its old place, and a task that keeps yielding cannot hold its
  priority.
- Queues of type `background`, `idle` and `startup` are created with the startup fence while the fence is up,
  including per-node queues made during launch.
- Hidden queues: a node queue whose node is hidden gets a wake-up throttler (Chrome `TaskQueue::Throttler`, Blink
  `WakeUpBudgetPool`): its background tasks become runnable only at the node's aligned hidden wake (1 s, or one a
  minute after 5 minutes hidden) and are charged to `CPUTimeBudgetPool`. Its visible and automation tasks are held
  by the visibility voter and coalesced by key, as today (`MainTaskQueue`). An enable voter alone cannot express
  "run only at the aligned wake"; the throttler can.
- Bounded queues: a queue may have a capacity. `MainActorWorkQueue`'s 1024 / 256 limits and its `busy` reply become
  properties of the automation queues. The `timeout` reply stays off main, as today (`MainActorWorkQueue.swift:222`):
  an off-main deadline completes the caller at its time even while a voter, the starvation policy or a nested loop
  holds the queue, and marks the task dead so it never runs. The `MainThreadEngineStart` exclusion from the
  deadline (`:37`) stays.
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

**Cause routing.** The queue gives the priority, but some work also has a cause (`ObservationCause`: person,
frontend, program, automation; main-thread-budget.md section 9). The post keeps today's routing
(`FrameBatchQueue.enqueue(cause:)`, `FrameBatchQueue.swift:117-127`):

```swift
rows.post(cause: change.cause) { apply(patch) }
// person:   applied in the input's own turn by InputResponsePass, before the commit (unbudgeted)
// frontend: runs in the next frame of the queue's display, unbudgeted (today's unbudgeted batcher)
// program, automation, none: the runner's queue, in its budget
```

`mainWork.causes` (the mutation-id match) moves onto the manager unchanged. A cause never raises work above
`frame` and is never used for authorization (main-thread-budget.md rule 5).

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
  x (refresh interval / 16.7 ms), reset at each frame of the main display's clock. As today
  (main-thread-budget.md:66-68), a pool's share limits its queue only while a key or a click is pending; with no
  input pending, a queue past its share may use the frame time the others left, up to the frame deadline.
- Progress rules (main-thread-budget.md:70-72), as voter overrides that the manager applies before it consults the
  voters:
  - visible: a visible queue that yielded in one frame runs at least its first task in the next frame, even if
    input is pending (today `yieldedLastFrame`, `MainFrameBudget.swift:436`);
  - automation and background: for 500 ms after the last discrete input, each runs at least 1 task per 100 ms and
    at most 10 per second, even while the input-response voter or pending input would hold it. So continuous
    typing or dragging cannot starve automation, whose requests have deadlines.
  The input-response voter (2.4) and the "no task while input is pending" rule yield to these floors; nothing else
  does.
- Frame-count pools: some owners limit work per frame by count, not time: one surface create per frame
  (`ContentPresentationScheduler.mayCreate`, `:148`) and one `.afterStartup` step per frame. These are pools
  counted against the frame sequence of the queue's display clock (after S8 each display has its own
  sequence).
- A long task asks `main.shouldYield()` and continues with `runner.postContinuation { }` (the front of its queue).
- The frame queue is not part of the batch: it runs in the display clock's callout. Where the budgeted batch runs
  relative to the frame (in the tick, as the default is today, or right after the frame's commit, the
  `mainBudgetTurn` path) is a placement of the batch source, not a second scheduler. The design keeps today's
  default and leaves the change to a measured decision (Q2); either way one of the two code paths is deleted.

### 2.4 Input always first

1. AppKit event dispatch is not a task. The batch returns at the first pending event (2.3), so a pending event
   waits for at most the one posted task that is running. This bound covers posted work only. Main-actor jobs
   that are not posted (2.7) run in the main dispatch queue's drain, outside the batch.
2. The work that dispatch does is a direct call (zero-latency.md: the synchronous change in the input's turn).
   It is never posted.
3. After a discrete input whose turn expects a frame (`ActionEffect` `.applied`, `.intentEffect`, `.waiting`; a
   view asked for display; Ghostty asked to draw), the manager enters `waitingForInputResponse` (Blink's
   `kWaitingForInputResponse`): `InputResponsePass` applies the dirty person-caused work before the CA commit of
   that turn, and the input-response voter disables automation, background and idle until the end of the first
   render pass after the input, at most 100 ms, within the progress floors of 2.3. Visible keeps its budget;
   frame runs.
4. `input` queue tasks are priority 1, and every budget pool reports spent while one waits.
5. Rendering starvation (Blink `kRenderingStarved`): when a shown window's display clock is more than 100 ms
   late, the starvation voter disables userBlocking, visible, automation, background and idle until that clock's
   next frame. That is today's set (every budgeted class, `MainFrameBudget.swift:409`) plus idle.
   It is a policy of the manager; whether it is on by default is Q6 (it holds nothing today, F3).
6. Only the input path may post to `input`: a guardrail refuses `runner(.input` outside `CmuxNextInput`. The control
   socket's injected keys reach input priority only by the per-connection raise (2.1). Nothing off main can raise
   its own work above userBlocking.
7. The scheduler's own timers never wait behind the queues they measure (main-thread-budget.md section 3, last
   paragraph): the reveal deadline (`StartupPhase.swift:176,272`), the display stall deadline
   (`DisplayClock.swift:490`), the coalescer fallback (`FrameInputCoalescer.swift:388`), the input-response cap,
   the idle period start and the starvation check are `control`-queue delayed tasks. They run in the wake-up
   queue's fire, ahead of every other queue, and are never disabled.

### 2.5 Fences: startup, and "show when ready, max 1 frame" (D10)

**Startup.** `startup` starts with a `.beginningOfTime` fence, removed at the first frame commit (today's
`firstFrameCommitted`). `background` and `idle` start with a `.beginningOfTime` fence. `revealed` removes the
background fence, `settled` removes the idle fence (Chrome `EnableAllExceptBestEffortQueues()`,
`OnStartupComplete()`). The `startup` queue is never disabled at `settled`: a task still queued then runs in its
turn, so nothing is stranded; after `settled`, a post to it is refused by the guardrail and asserted in Debug.
`StartupPhase` (the reference count with its failsafe) stays; its only outputs are these fence changes and
`LaneScheduler`'s best-effort fence. `StartupScheduler`'s `.critical` steps stay direct calls in `main()`; its
`.afterFirstFrame` and `.afterStartup` main steps become posts to `startup` and to the paced background queue
(2.1). Quit drops every launch task that has not started (today's rule).

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

How main-actor jobs reach the main thread: the Swift runtime enqueues every main-actor job on
`DispatchQueue.main` (`MainJobRing.swift:265` re-posts that way). The run loop drains the main queue in one
callout (`_dispatch_main_queue_callback_4CF`), which runs every job queued when the drain starts, back to back,
with no check for pending events between them, and each job runs until its next suspension. The manager's batch
source never sees these jobs.

In the model:
- Priority is set at the post site (2.2). Everything that the app itself sends to main as an unclassed job (131
  `Task { @MainActor`, main-inherited `Task {}`, `MainActor.run`, `DispatchQueue.main.async`, `StartupMainHop`,
  the `Task` hop of every `DemandTimer` with no wake-up queue) becomes a runner post (S4, S5).
- What stays on the main executor and cannot be converted: the resume of an `await` on the main actor, calls into
  `@MainActor` functions from off-main async code, main-actor `AsyncSequence` consumers, SwiftUI `.task`, and
  framework tasks. These stay FIFO in the main queue's drain. **Input can wait for the whole snapshot of those jobs,
  not for one job**, and the jobs are unbudgeted.
- The gate is deleted: `MainJobGate*`, `MainJobGateHook`, the classed hold in `MainWorkScheduler+Classed.swift`,
  the gate bits of `InputPendingState`, feature `mainJobGate` and setting `debug.mainJobGate` (two switches, D1).
  **The guarantee that goes with it:** "main-actor jobs, including the ones that start off main, wait behind a
  pending input until its frame commits". The gate is off in every channel and not in the chrome-parity dogfood
  set, so no build a person runs has this guarantee today, and deleting the gate changes no default.
- What replaces it is not a global reorder but fewer unposted jobs: S5 converts the app's own hops, and for the
  rest the main-actor code that runs often under load (store observers, page replies, automation replies) moves to
  the reply form (`.reply(on: runner)`), so its main part is a posted task. The census (`MainJobRing`,
  `CMUX_NEXT_MAIN_JOB_CENSUS=1`) finds those sites: the unposted main jobs that ran between an event's arrival and
  its dispatch during an automation storm, by enqueue site.
- One hook owner: `MainJobRing` (CmuxNextCompat, Debug and bench builds only), and it only records. Its
  `DispatchQueue.main.async` re-post (`MainJobRing.swift:266`, D12) is how a hook forwards a job with its QoS and
  stays inside the recorder. A guardrail refuses the hook symbol outside `MainJobRing.swift`.
- Mapping job priority onto the queues through a supported custom main executor, if the toolchain offers one, is
  Q4. Until then cmux does not reorder the main queue.

## 3. The mapping

### 3.1 Owners

| Owner | Becomes | Kept | Deleted |
|---|---|---|---|
| `MainWorkScheduler` | The sequence manager (same type name): queues, selector, voters, fences, batch source, budget pools, delayed tasks, `runner(...)` | `MainFrameBudget` as the budget pools and progress rules; `MainTaskBoard`, `MainOwnerLedger`, `MainTurnMeter` as task observers | `post(_:owner:)`, `postFromAnyThread`, `post(class:)`, `postFromAnyThread(class:)`, `callbackClass` (moved to runners); the per-class `FrameBatchQueue`s; the classed hold |
| `FrameScheduler` | Per-window observer sets on `DisplayClock` (a view) | `FrameClient` as the frame observer type (`frame` queue) | The budgeted `FrameScheduler` and `FrameClient(budgeted:)`, `FrameBatchQueue(budgeted:)`; `FrameScheduler.app` |
| `LaneScheduler` | Unchanged (off main, the thread pool) | All | none |
| `MainActorWorkQueue` | Automation queues, one per connection, with capacity; the queue is raised to `input` priority while its head is an injected key (2.1); round robin across connections | Its request contract (`busy`, order per connection, keys never pass their connection's earlier requests); the off-main `timeout` deadline and the `MainThreadEngineStart` exclusion | The type, `ControlFrameSource`, `MainQueueFrameSource` |
| `ContentPresentationScheduler` | A keyed `visible` queue per window with cause routing (2.2: person in the pass, frontend unbudgeted next frame) plus a frame-count pool of one create per frame, where a person's pane may take a frame automation used | `showNow` (the synchronous path) | The type and its two batchers |
| `IdleScheduler` | The `idle` queue; the idle-period policy moves into the manager | `IdleDeadline`, the period rules | The scheduler object, `IdlePeriodTimer` (the manager's wake-up timer arms periods); F1 is fixed by construction (the manager knows its next delayed task) |
| `StartupScheduler` | The `startup` queue (visible priority and budget, fenced until the first frame) and the paced background queue (one step per frame); `.critical` stays direct calls; lane steps stay on `BackgroundWork` | `StartupPhase`, `StartupTaskLog` | Its arrays, its `FrameBatchQueue`/`FrameClient`, `StartupMainHop`, its failsafe `DemandTimer` |
| `MainDeadlineScheduler` + `MainDeadline` | `runner.postDelayed` / `postRepeating` with a `DelayPolicy` (`.precise` under 36 ms, `.flexible`, `.whenHidden`) | Alignment rules, the hidden 5-minute pool, `CPUTimeBudgetPool`; the 8 `*Deadline` protocols as seams over the delayed-task handle | Both types, after the codemod |
| `MainWakeUpQueue` | The manager's private wake-up queue (one timer) | Heap, alignment, `fireBudget`, hidden heap | Public construction and the six fallbacks (F2); direct inserts move to `control` delayed tasks (1.4) |
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
| `postFromAnyThread(` | 215 sites in about 160 files | `runner.postFromAnyThread` (same semantics, priority from the runner) | S3 (codemod) |
| `mainWork.post(.class` / `.apply(.class` / `.reply(on:)` | 47 / 88 / 39 | `runner.post` / `runner.apply` / `.reply(on: runner)` | S3 (codemod) |
| `MainDeadline(` | 152 in 119 files | `runner.postDelayed` / `postRepeating` | S4 (codemod) |
| `DemandTimer` main path: `scheduleOnMain` / `scheduleOnMainIfIdle` | 38 sites in 34 files (2 timers built with `wakeUps:`, 0 with `mainWork:`) | `runner.postDelayed`; the scheduler's own timers (2.4 item 7) become `control` delayed tasks | S4 |
| `DemandTimer` with `schedule(after:)` in main-actor code | counted per site in S4 (the 20 main-actor files that build one are the start) | `runner.postDelayed` | S4 |
| `DemandTimer` off main | the rest of the 88 | Stays as the off-main delayed task (Q3) | none |
| `Task { @MainActor` | 131 in about 100 files (App 48, Browser 23, Pages 12, Wakeups 8, Design 5, Control 5) | a runner post, or `.reply(on:)` for an async body | S5 |
| `MainActor.run` 3, `DispatchQueue.main.async` 2, `CFRunLoopPerformBlock` 5, `RunLoop.main.perform` 1, `MainDelivery(` 30, `StartupMainHop` | | a runner post (`MainDelivery` keeps its inline-on-main rule as `runner.deliver { }`) | S5 |
| `// main-hop-allow:` | 337 | each converted, or kept only for an AppKit order (focus, menu tracking), with the list cut below 50 (D8) | S5 |
| `// timer-class-allow:` | 106 | reviewed in S4; only off-main ones stay | S4 |

After S5 there is one way to post main-thread work (a runner) and one way to delay it (a delayed post), and the
guardrail refuses every old form with no escape except a closed file list.

## 4. Migration plan

Rules for every step:
- One branch per step (`cp/seqmgr-sN-...`), cut from the train tip, small enough for one review. A mechanical
  step has two commits, the script and its output; the reviewer reads the script and samples the output. A step
  that changes owner `init`s (S3) is split per package, one branch each.
- Red then green: the step's behavioral test is committed first, fails on the base and passes on the head, run on
  the fleet (`cmux-ci run --class isolated --script ... --ref SHA`), never on a person's Mac. No CI test, job or
  gate is added; the step's tests are suite tests run by the agent.
- Benches before and after on the same fleet host, optimized build (`cmux-ci build cmux --builder mac --release
  --ref SHA --tag chrome-parity-...`, the bench configuration), 120 Hz virtual display, light and STRESS:
  - first-5s: `scripts/cmux-next/first-5s-typing.py` (lands in S0; today it exists only on the scratch ref
    `cp/first5s-measure-f`, `3ffa92040cb`): 0 terminal keys with `dispatchStart` > 50 ms in the first 5 s, and no
    worse p95/p99 than the base.
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
| S0 | Land the first-5s bench from `cp/first5s-measure-f` as `scripts/cmux-next/first-5s-typing.py` and its `split-spring.sh --suite=first5s` case (a bench the agent runs; no CI job). Record the base numbers of every bench above at the program's base sha. | The bench's own check: a planned 1-key-per-50-ms sender reports its real send time (the 50 ms step artifact of first-seconds-lag-result.md is gone) | all, base numbers only | none |
| S1 | F1 and F2, F6: wire `MainDeadlineScheduler.nextFireNanos` into the idle period (the app's `IdleNextDeadlineSource`); remove the six `MainWakeUpQueue` fallbacks and the default `MainDeadlineScheduler(work: MainWorkScheduler(...))` arguments so a new caller cannot get a second timer; fix the two "Main job gate" rows of threading-model.md | Red on the base: in an app-shaped rig, a long idle period with a `MainDeadline` due in 20 ms ends before the deadline (today it runs to 50 ms) | bench_idle, first-5s | `MainWakeUpQueue(` and `MainDeadlineScheduler(` outside the composition root and TestSupport |
| S2a | Manager core, no behavior change: `MainTaskQueue` as the general queue (priority, voters, fence, continuation order), `MainTaskSelector` (oldest-first and round-robin types, 2.1), with tests only on a `ManualClock`; nothing in the app uses it yet | Selector tests: strict priority; oldest-first across two `visible` queues; round robin across two `automation` queues where the first has 256 queued; a fence holds later posts and keeps earlier ones; a disabled voter holds a node queue; a continuation goes to its queue's front with a new order | none (no app change) | none |
| S2b | The batch source and budget pools: the class queues of `MainWorkScheduler` move onto S2a's queues; the batch runs from the source at today's placement (in the tick) | Red on the base where the base differs, else a pin: with input pending, no posted task starts; shares apply only while input is pending; the visible and automation progress floors under continuous typing (a fake `SessionInputPending` held true for 2 s still runs automation at least every 100 ms) | key-to-frame (light, STRESS), frame-time, bench_cli_storm | The per-class `FrameBatchQueue`s inside the scheduler |
| S2c | Node queues on the manager: today's `MainTaskQueue` pump layer removed; the hidden-queue throttler (2.1) | Hidden node: background runs only at the aligned 1 s wake and is charged to `CPUTimeBudgetPool`; visible posts coalesce by key while hidden and run in order on show | bench_idle (hidden workspaces), key-to-frame | The pump layer |
| S3 | Runners, one branch per package (CmuxNextWakeups first, then the domain packages, CmuxNextApp last): every `post` / `postFromAnyThread` / `apply` / `.reply(on:class:)` / `post(cause:)` site to a runner its owner takes in `init` (about 200 constructors in all; a script does the call sites, a person the inits) | A post from another thread lands in its runner's queue with its owner and line on the board; a person-caused post applies in the input's turn (cause routing, 2.2) | key-to-frame, first-5s (last branch only; the others are mechanical) | After the last branch: `mainWork.post(`, scheduler `postFromAnyThread(`, `post(class:`, `callbackClass(` |
| S4 | Delayed tasks: `postDelayed` / `postRepeating` on the manager's wake-up queue; the `control` delayed tasks for the scheduler's own timers (2.4 item 7) and the three direct inserts (1.4); codemod of the 152 `MainDeadline(` sites; the 38 `scheduleOnMain` sites and main-actor `schedule(after:)` sites; the 106 `timer-class-allow` escapes reviewed | A flexible delayed post fires no sooner than its delay, on the 8 ms grid; a precise one under 36 ms is exact; a hidden node's repeating post joins the minute pool after 5 min; cancel after ripening runs nothing; the reveal deadline fires on time while a `visible` flood holds its budget (it is `control`) | bench_idle (idle and hidden), first-5s, launch stories | `MainDeadline`, `MainDeadlineScheduler`; `DemandTimer` in main-actor code and its `wakeUps:` / `mainWork:` / `scheduleOnMain*` |
| S5 | Raw hops: 131 `Task { @MainActor`, main-inherited `Task {}`, `MainActor.run`, `DispatchQueue.main.async`, `CFRunLoopPerformBlock`, `RunLoop.main.perform`, `MainDelivery(` and `StartupMainHop` to runner posts; the 337 `main-hop-allow` escapes cut below 50. One branch per package, as S3 | Per migrated family, the order test it needs (a notification click still runs after the event that caused it; a pipelined control request still runs in order) | key-to-frame with automation, first-5s, `MainTurnMeter` `unattributed_share` | The raw forms, with no escape except the closed list |
| S6 | The executor hook: delete `MainJobGate` and its files, the classed hold, the gate bits, feature `mainJobGate` and setting `debug.mainJobGate`; `MainJobRing` is the one hook owner. Independent of S2-S5: the gate is off in every channel, so S6 can land at any time | The gate's tests are deleted with it. New, in the census rig (bench build): during a storm of main-actor awaits, it records the unposted main jobs that ran between an event's arrival and its dispatch, by enqueue site. This is a measurement, not a pass or fail: it picks the reply-form sites of 2.7 | key-to-frame with automation, first-5s (gate off on both sides: the default) | `swift_task_enqueueMainExecutor_hook` outside `MainJobRing.swift` |
| S7 | Owners into queues, one sub-branch each: S7a `MainActorWorkQueue` to per-connection automation queues with the input raise, capacity and the off-main timeout; S7b `ContentPresentationScheduler` to a keyed visible queue with cause routing and the create pool; S7c `IdleScheduler` to the idle queue; S7d `StartupScheduler` to the startup queue, the paced background queue and the fences; S7e `RenderStarvationGuard` to the starvation voter (default per Q6) | Per owner, its contract tests against the queue form: S7a busy at 1024 / 256, timeout at its deadline while the queue is held, a focus request then a key types into the new focus, a flooding connection does not delay another; S7b one create per frame and a person's pane takes automation's frame; S7c idle deadline and the 10 s hidden stop; S7d no afterStartup task before completion, one per frame, none stranded at settle; S7e starvation holds userBlocking to idle until the next frame | S7a automation-typing and bench_cli_storm; S7b key-to-frame and tab switch; S7c bench_idle; S7d launch stories and first-5s; S7e frame-time | The five types, `ControlFrameSource`, `IdlePeriodTimer`, `StartupMainHop` |
| S8 | One frame source: `FrameScheduler` as observer sets on `DisplayClock`, with `FrameInputCoalescer` as the first observer of each window; `FrameScheduler.app` deleted; `VSyncHub` internal to `DisplayClock`; `TerminalVSyncSource` as the clock's off-main seam; frame-count pools per display sequence | Two windows on two displays (60 and 120 Hz) get frames from their own display only; no observer: 0 links; a late observer gets the missed frame | frame-time, key-to-frame, bench_idle | `check-concurrency.sh` display-link owners = `DisplayClock.swift` only; `FrameScheduler.app`; public `VSyncHub` |
| S9 | The daemon drain leaves the frame (D9): a `visible` post on inbox readiness; with change fences (PL-daemon's wire) a whole change in one batch; then the `DisplayClock` stall and rebuild rule reviewed | With the link stalled (display asleep), a daemon event still applies within one batch; a fenced 40-event change applies whole under a 1-event budget | key-to-frame under a CLI storm, frame-time | The store drain as a `FrameClient` |
| S10 | `CommitFence` (D10) and the holds, one family per sub-branch: paint holds (`PanePaintHold`, workspace paint hold, tab switch), `TerminalFrameHold`, `FirstTabHold` and `NewTabSuccession`, `SidebarSelectionHold`, `LaunchImageHold`, the rest | Per family: the switch shows content or the stand-in within one frame of the clock; keys typed during the fence reach the new destination (hold-class.md rule 1) | first-5s (extended to Cmd-T and switches, hold-class.md item a), key-to-frame, frame-time | Each converted hold type; a rule refuses a new `*Hold` or `*Deadline` type that arms its own timer |

Order: S0 first (every later step needs its bench). S1 and S6 are independent and small; they can land at any time
after S0. S2a, then S2b, then S2c. S3 needs S2b (S2c for node queues). S4 and S5 need S3's Wakeups branch and run
in parallel per package (different files). S7a-S7e need S2b-S4 and are independent of each other. S8 needs S7a
(it removes `ControlFrameSource`) and S2b. S9 needs S8 and PL-daemon's change fences. S10 needs S8 (the fence's
limit is a clock frame).

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
  at a nested loop's entry). Each S2b and S7 test set includes a nested-loop case.
- R4 The CEF message pump. `CEFMessagePump` runs Chromium's UI-thread work in slices on main and is not a task of
  the manager. Its slice policy (`cefPumpFrameDeadline`, `admitsSlice`) has to read the same frame deadline and
  starvation state. The design treats the pump as a native callout like AppKit's (it yields between slices), not
  as a queue; that is Q8.
- R5 `postFromAnyThread` cost. Today one run-loop block per post. The manager uses one lock-free MPSC push plus
  one source signal per empty-to-non-empty change; this has to be measured (the hot path of 215 sites), and the
  push must not allocate per post beyond the closure.
- R6 Behavior changes hidden in a refactor. Budget placement, the starvation voter and the create cap change what
  a person sees. Each is a separate, measured decision (Q2, Q6), never part of a codemod. The design keeps
  today's levels where Chrome differs: `startup` stays at visible's priority and budget (Chrome's `kStartup` is
  higher), `.afterStartup` keeps one step per frame, and the starvation voter holds userBlocking as today. A
  change to any of these is its own branch with its own bench.
- R7 Unposted main-actor jobs (await resumes, `@MainActor` calls from off-main async code, SwiftUI `.task`,
  framework tasks) stay FIFO in the main queue's drain: input can wait for all the jobs queued when the drain
  starts, and they are unbudgeted. This is today's behavior in every shipped channel (the gate is off). The model
  reduces them (S5, the reply form at the sites S6's census names); it does not bound them.
- R8 The one-frame fence limit can show a stand-in where a hold showed nothing for up to 3 s. That is the intended
  trade (show at once, reconcile), but it needs a good stand-in per family (S10).

Open questions for cmux-ad (each one is self-contained):
- Q1 Type name: keep `MainWorkScheduler` as the manager's name (no rename in 884 files), or rename it to
  `MainSequenceManager` with a codemod in S3. Recommendation: keep the name.
- Q2 Budget batch placement: keep the batch in the display tick (today's default), or move it to its own run-loop
  turn right after the frame's commit (today's `mainBudgetTurn`, off). S2b keeps today's placement and changes no
  behavior; the deletion of the losing path and of the `mainBudgetTurn` switch is a later branch of its own, after
  a key-to-frame and frame-time measurement. Recommendation: measure after S2b; keep the tick placement unless the
  after-commit turn wins.
- Q3 Off-main `DemandTimer` (the sites that remain after S4): keep it as the off-main delayed task, or fold it into
  `BackgroundWork` as `work.postDelayed(priority, after:)` (Chrome `ThreadPool::PostDelayedTask`) in a later step.
  Recommendation: keep it now, fold it later.
- Q4 A custom main executor: if the Swift 6.2 toolchain has a supported API to replace the main executor, map main
  job priority onto the queues there (one owner, no hook), or keep the hook record-only and never reorder.
  Recommendation: record-only now; check the toolchain separately.
- Q5 Deleting `MainJobGate` removes the guarantee "main-actor jobs that start off main wait behind a pending
  input until its frame". No shipped channel has it (the feature is off everywhere). Decide: delete the gate in S6
  and reduce unposted jobs with the reply form (this design), or first turn the gate on in a dogfood build and
  measure what it buys on key-to-frame under automation before deleting it. Recommendation: delete; the gate
  reorders by origin, which is the global reorder D6 removes.
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

## 7. Review record

Revision 1 (`9215e5c0bbf`) had one independent review subagent. It read the code, not the author's notes.
Verdict: REWORK. Revision 2 (this file) answers each finding:

| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | Inventory: F2 overstated (the app passes its one queue); the `DemandTimer` main path is 38 `scheduleOnMain` sites in 34 files, not 2; small count drifts | major | Fixed: F2, row 9, 1.2, 3.3 and S1/S4 rewritten; counts corrected |
| 2 | 2.7's bound "one job between batches" is false: the main queue drains every queued job in one callout | blocker | Fixed: 2.4 item 1, 2.7 and R7 rewritten; the lost guarantee is named (Q5); S6 is independent and its test is a census measurement |
| 3 | Injected keys on a separate `input` queue would pass their connection's earlier requests | blocker | Fixed: per-connection queue raised to input priority while its head is a key (2.1) |
| 4 | Oldest-first across queues is not round robin; connection fairness lost | major | Fixed: round robin inside `automation`, stated as a difference from Chrome (2.1) |
| 5 | Cause routing (`ObservationCause`, `enqueue(cause:)`) missing | major | Fixed: cause routing on every post (2.2), 1.4 row |
| 6 | Share-only-under-input and the progress rules contradicted | major | Fixed: 2.3 states both, progress rules as voter overrides |
| 7 | The scheduler's own timers would wait behind classes | major | Fixed: `control` delayed tasks (2.4 item 7), S4 test |
| 8 | Request timeout weakened | major | Fixed: off-main deadline kept (2.1, 3.1) |
| 9 | Startup priority and pacing changed silently; stranded tasks at settle | major | Fixed: `startup` at visible priority, paced background queue, never disabled at settle (2.1, 2.5, R6) |
| 10 | Missing pieces (observation primitives, `AfterFrameCommit`, `MainRunLoopBlock`, `FrameInputCoalescer`, direct inserts, `DeadlineHeap`, `HostPressureMonitor`) | major | Fixed: 1.4 table; "two sources" limited to main-thread time (1.2) |
| 11 | Hidden-node throttling not modelled | major | Fixed: hidden-queue wake-up throttler (2.1), S2c |
| 12 | First-5s bench not on the branch; S1 red would pass; S2 and S3 too large | major | Fixed: S0 lands the bench; S1 red is F1; S2 split into S2a-c; S3 and S5 per package |
| 13 | Chrome descriptions: budget pools, voters stricter than Blink, starvation includes userBlocking; `kStartup` doubted | minor | Fixed: stated in the Chrome table and 2.4. `kStartup` checked: it is in `content/browser/scheduler/browser_task_queues.h` ("Tasks that are critical for startup performance"); `kMaxDelayedStarvationTasks = 3` is in the current `task_queue_selector.h` |
| 14 | Continuation order; create cap is a count | minor | Fixed: 2.1 rule, frame-count pools (2.3) |

Revision 2 had a second review of the changes only (section 7.1).
