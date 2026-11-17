# cmux NEXT: the main thread stays free under load (as Chrome keeps its UI thread free)

Status: DESIGN, approved 2026-11-10. Lawrence: "i want us to match chrome's smoothness, throughout the entire app,
don't stop until it's to chrome's quality" (the coordinator relayed this as the OK for this design). Section 6 gives
the PR and the state of each step. Owner of this doc: MAIN THREAD LIKE CHROME (perf lead task, 2026-11-10). Owners of
the code it names: PL-main (scheduler, [main-thread-budget.md](main-thread-budget.md); the `CmuxNextWakeups` row of
[OWNERS.md](OWNERS.md) says "Performance Lead"), PL-ghostty (terminals), PL-daemon (the cmux-tui daemon) and the
sidebar owner in OWNERS.md. The agent pane and the agent lanes have no OWNERS.md row.

Code read at feat `9e0c2ce826c`; file and line references checked again at `b7dfd714d4e` (2026-11-10), after #40038
and #40127 landed. No number in this doc comes from a bench: section 5 says what is measured (two production samples)
and what is not.

Lawrence (2026-11-10): "when there is high load in cmux, why does everything get laggy? fix it so it follows how
chrome does it: in chrome when one thing takes all the cpu, the rest of the app is not laggy".

## The problem in one paragraph

On NIGHTLY 85b099928a8a (pid 35142, 81-103 % CPU, 2.4 GB, Mac load 175), a 5 s sample at 03:03Z found the main
thread busy in 1803 of 1995 samples (90 %). 1678 samples (84 %) were in ONE derived-state walk:
`AgentPaneLinkPlaces.follow` -> `withObservationTracking` -> `places(in:)` (1546 samples at its main call site). Each tab title change
anywhere (agent title spinners, many per second) woke one observation that read every workspace and every tab
again, O(tabs^2) through a no-machine tab-key lookup. Terminals, keys and the sidebar waited behind it. PR #40038
(merged, `d1bf101b008`) fixed this one loop (one observation per workspace). This doc is the general model, so that the NEXT loop of this kind
cannot take the app: what may run on the main thread, in what order, how long, and where derived state is computed
instead.

Chrome is not laggy under the same load for three reasons, and cmux needs all three:

1. **Work that grows with the content never runs on the UI thread.** A page's script, layout and raster run in its
   renderer process and on the compositor and GPU threads; the browser UI thread gets small IPC messages.
2. **The UI thread's tasks have priorities and stay short.** Input first, then frame work, then visible work, then
   best effort; a long task is a bug that the jank and hang monitors find, not something the scheduler hides.
3. **Observers are per item.** A tab's change notifies the tab strip about that tab (and what changed), never "the
   model changed, read it all again".

cmux has reason 2 already in part (`MainWorkScheduler`, [main-thread-budget.md](main-thread-budget.md)). It lacks 1
and 3 for derived state, and the scheduler does not see the work that hurt us: observation re-evaluations run as
plain main-actor jobs outside it.

## 0. Chrome's model, with Chromium source references, mapped onto cmux

References are paths in chromium/src at `main` (read 2026-11-10 from the GitHub mirror). They name the mechanism;
line numbers change, so none are pinned.

| # | Chrome | Source | cmux today | cmux target (this doc) |
|---|---|---|---|---|
| C1 | The browser UI thread does input, UI model updates, layout of browser views and the commit. "Do not perform expensive work on the main thread, the IO thread or any sequence that is expected to run tasks with a low latency"; expensive work goes to the thread pool with `PostTaskAndReply`. | `docs/threading_and_tasks.md` ("Keeping the Browser Responsive"; "Posting to the Main Thread or to the IO Thread in the Browser Process": "The main thread and the IO thread are already super busy") | The rule is written ([threading-model.md](threading-model.md), P5 in [PATTERNS.md](PATTERNS.md)) and enforced for blocking calls (checked seams, `main-blocking` guardrail). It is NOT enforced for CPU work: an O(session) walk on main is legal code. | Section 1 (budget and attribution) and section 2 (derived state off main). |
| C2 | Page work runs in other processes: renderer (Blink main thread, compositor thread), GPU/viz, network and utility services. A slow page cannot block the browser UI thread; it gets IPCs. | `content/browser/renderer_host/render_process_host_impl.h`; `cc/trees/proxy_impl.h` (the compositor-thread side of the threaded proxy) | Terminals: Ghostty renderer and IO threads, cmux-tui daemon owns PTYs. Pages: Chromium processes. Agents: acpmux. BUT the app keeps a full `@Observable` mirror of every workspace and tab and derives link places, titles, rows and badges from it on main. | Rust derives (the daemon, or the in-app client core off main); the app applies per-item snapshots (section 2). |
| C3 | Task priorities: `base::TaskPriority` `BEST_EFFORT < USER_VISIBLE < USER_BLOCKING`. The browser UI thread runs a `SequenceManager` with typed queues: `kUserInput` ("higher priority than kUserBlocking", and it changes the priority of yielding to native to get input faster), `kUserBlocking`, `kUserVisible`, `kBestEffort`, and others; queue priorities `kControlPriority > kHighestPriority > kHighPriority > kNormalPriority > kLowPriority > kBestEffortPriority`. The selector always runs the highest non-empty queue. | `base/task/task_traits.h` (`enum class TaskPriority`); `content/browser/scheduler/browser_task_queues.h` (`BrowserTaskQueues::QueueType`); `content/browser/scheduler/browser_task_priority.h` (`BrowserTaskPriority`); `content/browser/scheduler/browser_ui_thread_scheduler.cc`; `base/task/sequence_manager/task_queue_selector.cc` | `MainWorkClass` input > frame > visible > automation > background, `MainFrameBudget` (visible 2.5 ms, automation 1 ms, background 0.5 ms per frame), `FrameBatchQueue` (CmuxNextWakeups), `MainActorWorkQueue` (CmuxNextControl). Yields to pending input (`SessionInputPending`). | Keep it. Close the gap: every main-actor job that is not input or the commit enters it with a class and an owner (section 1.2). |
| C4 | Frame work is prioritized in the renderer: the Blink main-thread scheduler raises the compositor queue for gestures and for frames that were waiting too long (use cases `kCompositorGesture`, `kMainThreadGesture`; `ComputeCompositorPriority`). | `third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc` | `frame` class (springs, terminal frame holds, the daemon store drain) is unbudgeted and runs before visible work. | Keep; the store drain must stay O(changed) (section 1.3). |
| C5 | Long tasks are bugs that are found, not scheduled around. The scheduler never preempts a task. `base::HangWatcher` samples a thread that stays in one scope too long (`WatchHangsInScope`); the responsiveness `JankMonitor` and `Browser.MainThreadsCongestion` metrics report long and queued tasks in the field. Renderers split their own long work (`scheduler.yield()`, `isInputPending`). | `base/threading/hang_watcher.h`; `content/browser/scheduler/responsiveness/jank_monitor_impl.h` (`OnCheckJankiness`); `third_party/blink/renderer/core/scheduler/dom_scheduler.h` (`scheduler.postTask` / `scheduler.yield()`) | `MainThreadWatchdog` records stalls over its threshold (default 50 ms; the benches set 8 ms with `CMUX_NEXT_HANG_THRESHOLD_MS=8`) with the scheduled task's owner (`MainTaskBoard`); per-task over-budget records only in diagnostics mode. The stall in the profile was a plain main-actor job: no scheduled owner. | Every main job has an owner on the board (section 1.2); a task over 8 ms is a recorded bug with its owner (section 1.4); the regression test fails on it (section 1.5). |
| C6 | Observers are per item and say what changed: `TabStripModelObserver::OnTabChangedAt(tab, TabChangeType)` with `kAll`, `kLoadingOnly`, `kAttentionOnly`, `kResourceUsageOnly`. A title change repaints that tab. | `chrome/browser/ui/tabs/tab_strip_model_observer.h`; `chrome/browser/ui/tabs/tab_change_type.h` | `@Observable` models with `withObservationTracking` / `ObservationStream`; the pattern for lists is `ObservedItems` (one observation per item). Several loops still read across all workspaces or tabs (section 3). | One observation per item, never one over the session (section 3). |
| C7 | Loading throbbers are a paint-level animation: one `BrowserView` timer (`kAnimationUpdateInterval` 30 ms) calls `TabStrip::UpdateLoadingAnimations`, which steps each tab's throbber. The tab's title does not change per throbber frame; the model is not touched. | `chrome/browser/ui/views/frame/browser_view.cc` (`loading_animation_timer_`, `LoadingAnimationTimerCallback`); `chrome/browser/ui/views/tabs/tab_strip.cc` (`UpdateLoadingAnimations`) | An agent's title spinner (`⠐ Fix the bug`) is a model write per frame: `DaemonStore.apply` -> `TabModel.setTitle` writes the raw `title` (`TabModel.swift:446-447`) and wakes every reader of `title`; only `titleText` and `titleActivity` are written when they change. | The daemon parses terminal titles into text + activity (Rust) and sends nothing when neither changed. The working mark animates in the view, under `Motion.indicators` (section 2, row D2). |
| C8 | Background tabs are throttled; hidden work is model-only. | `third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc` (background page throttling) | Written as a rule (CLAUDE.md "Go past Chrome where cmux is scripted"); partly done (`P10 Hidden costs nothing`). | Derived state for hidden workspaces is computed by the daemon and applied to the app only for visible rows (section 2). |
| C9 | Automation (extensions, DevTools protocol) uses the same task queues as everything else and never outranks input. | `content/browser/scheduler/browser_task_queues.h` (no automation queue above `kUserInput`) | `automation` class below `visible`; daemon threads of the person's keys at user-interactive (server/input_qos.rs). | Keep. Agent-caused title and status churn arrives as daemon events and is applied in the store drain (frame class); it must cost O(changed), and spinner frames must not arrive at all (C7). |

What cmux does past Chrome is already written ([PATTERNS.md](PATTERNS.md) "Go past Chrome where cmux is scripted").
This doc does not repeat it.

## 1. Main-thread budget

### 1.1 The rule

- **No main-thread task over 4 ms; input and frame tasks first.** A "task" is one main run loop job: an AppKit event
  dispatch, a scheduled `MainWorkClass` task, a main-actor job (a `Task` continuation, an `ObservationStream`
  re-evaluation, a SwiftUI update), a timer or a dispatch-main block. 4 ms leaves half of a 120 Hz frame (8.3 ms) for
  input dispatch and the commit, the same split as `MainFrameBudget.Budgets.total`.
- **8 ms is a failure.** A task over 8 ms on the main thread is a bug with an owner; the regression test of 1.5 fails
  on it.
- **Cost is bounded by construction, not by the scheduler.** As in Chrome (C5), the scheduler orders and batches
  tasks; it cannot cut a task. A task's cost must be O(what changed), never O(session). Work that is O(session) moves
  off main (section 2) or becomes per item (section 3).

### 1.2 What runs where (queues per priority on main)

The queues exist ([main-thread-budget.md](main-thread-budget.md)). This doc keeps them and closes four gaps.

| Class (`MainWorkClass`) | Runs | Budget per frame | Who may enqueue |
|---|---|---|---|
| input | AppKit event dispatch; injected input (`debug.key`) | none; first | AppKit, `MainActorWorkQueue` input lane |
| frame | display-link clients: springs, terminal frame holds, the daemon store drain (`DaemonStore.drain`, one batch) | none; must stay O(changed) | `FrameScheduler` clients |
| visible | store-derived view updates: sidebar row patches, tab strip items, link places, badges, `ObservationStream` re-evaluations (gap G1) | 2.5 ms | `FrameBatchQueue`, `MainDelivery`, the observation hop |
| automation | control-socket requests (CLI, MCP, agents) | 1 ms | `MainActorWorkQueue` |
| background | idle work (spares, warm-ups) | 0.5 ms, idle frames only | `FrameBatchQueue(.background)` |

Off main (unchanged): daemon I/O and line split (`cmux-tui reader`), terminal output lanes, Ghostty renderer and IO
threads, `BackgroundWork` lanes (`.files`, `.system`, `.cpu`), the cmux-tui daemon and acpmux processes. New in this
doc: derived state in Rust, in the daemon or the in-app client core off main (section 2).

Gaps this doc closes:

- **G1. Observation re-evaluations are outside the scheduler.** `ObservationStream`'s legacy path hops to the main
  actor after `onChange` and runs `emit` there as a plain job (CmuxNextCompat/ObservationStream.swift, step 2 of its
  header). On macOS 26+ it forwards to the system `Observations`, which does the same. That job has no class, no
  budget and no owner on `MainTaskBoard`; the watchdog sees only a stack. The 03:03Z loop was this kind of job.
  Design: on both paths, `emit` runs inside `MainFrameBudget.run(.visible, owner:)` with its `ObservationSite`
  (`#fileID:#line`, interned once when the stream is made) as the `MainTaskOwner`. So the board names it, its time is
  recorded (G3), and the budgeted work after it in that frame yields when it was long. The hop itself stays where it is
  (on macOS 26+ it is inside Apple's `Observations`, which this doc does not replace), so there is no added delay and
  coalescing stays one re-evaluation per burst. This does not make a long evaluation short: sections 2 and 3 do.
- **G2. `onChange` closures run inside the writer.** A `withObservationTracking(_:onChange:)` will-set callback runs
  synchronously inside the write (the store drain). Rule: an `onChange` only marks dirty and enqueues; it never reads
  the model or computes. The guardrail rule `observation-onchange` (#40127, merged; pre-push, added lines only, not a
  CI gate) refuses an `onChange:` body that does more than literal dirty marks, `guard let self else { return }` and
  one call; escape `// onchange-allow: <why this work must run inside the write>`.
- **G3. A task's cost has no always-on record.** Today an over-budget task is recorded per task only in diagnostics
  mode (`CMUX_NEXT_MAIN_TASK_DIAGNOSTICS=1`), because the per-task record wakes the watchdog. Design: `MainFrameBudget.run`
  already reads the clock at the start and the end of each task (the G1 hop runs inside it); it adds the task's time to a
  per-owner fixed-size histogram (interned owner index, the `ActionBudgetMonitor` ring design: no allocation, no lock,
  no string). Only a task over 8 ms wakes the watchdog for a stack. `debug.main_budget` (today: per class task counts, yields, deferrals and the longest
  task) also reports per-owner p50/p95/max and count. This is a measurement, not a switch: there is no setting and no off path.
- **G4. The store drain (frame class) is unbudgeted and unmeasured per batch.** It must stay one batch (no half
  transactions, main-thread-budget.md). Design: it gets the same per-owner record (owner `DaemonStore.drain`), and
  section 2 makes its cost O(changed items) by removing the derived work its writes wake.

### 1.3 Order of one frame (target)

1. Input dispatch (AppKit), unbudgeted.
2. Frame clients: springs, terminal holds, `DaemonStore.drain` (applies only per-item value snapshots: section 2).
3. Visible: observation re-evaluations of the items the drain changed (G1), sidebar and strip patches; 2.5 ms; yields
   to pending input.
4. Automation: control-socket requests; 1 ms.
5. Background: idle frames only.
6. AppKit layout, display and the Core Animation commit (`RenderPassMeter` charges it to the next frame's budget).

Terminal frames do not wait for any of these (section 4).

### 1.4 Enforcement (no CI gate)

- **Construction:** sections 2 and 3. A loop over all workspaces or tabs on main is a review finding at least major
  (REVIEW-STANDARD.md), the same as a blocking call.
- **Pre-push (early warning, added lines only; landed in #40127):** G2's rule `observation-onchange`, and the rule
  `observation-scope`: an `ObservationStream` / `ObservationLoop` / `withObservationTracking` / `track(shape:)`
  closure that walks a session-wide collection (`workspaces`, `allWorkspaces`, `tabs`, `allTabs`, `liveTabs`,
  `screens`, `.values` of a map) is refused unless it is an `ObservedItems` owner that reads only the list (ids), not
  item fields. Escape `// observation-scope-allow: <why the read set is bounded>`. The two escapes are not
  `// observation-allow:`, which is the escape of the older rule `raw-observation` (a direct
  `withObservationTracking` outside the tracked wrappers): one comment for all three would let a reviewed raw tracking
  hide a session-wide walk. These are `guardrails.py` rules (`scripts/cmux-next/guardrails.py --list`); they are not
  CI jobs, steps or perf-gate rows. The rule is lexical: it does not find a walk in a function that the closure calls
  (`Self.chats(models)`, O1-O7 below), so the runtime check stays the proof.
- **Runtime (Debug, bench builds and NIGHTLY):** G3's per-owner record; a task over 8 ms writes one `stall` record with
  its owner and stack (the watchdog does this today for scheduled tasks at its threshold: 50 ms by default, 8 ms in
  the benches; this design makes 8 ms the threshold in Debug, bench builds and NIGHTLY, which step 0 owns with G3; G1
  gives the observation jobs an owner).
  `ObservationWakes` already names the observations each change wakes, by site; the deterministic test of 1.5 uses it.
  Observation has no public API for an evaluation's access list, so the rule is checked by its effect (which changes
  wake an observation), not by counting entries.

### 1.5 BENCH and REGRESSION TEST: the large session

**Session (`large`):** 60 workspaces x 6 tabs = 360 tabs (per workspace: 3 terminals, 1 agent chat, 1 Chromium page,
1 WebKit page), all restored; the window shows workspace 60. 5 terminals in 5 different hidden workspaces stream
agent-like titles: each prints `ESC ] 0 ; <spinner glyph> <text> BEL` every 80 ms (12.5 Hz, the Claude Code spinner
rate) and changes `<text>` every 2 s, and 5 agent status changes per second go through `cmux workspace set-status`. The
person types in the terminal of workspace 60 (`cat`, so the tty echoes each key) with real HID keys
(`--input real`, CGEventPost at the HID tap).

**Regression test (a normal regression test, not a CI test):** `tests/test_cmux_next_main_thread_large_session.py`
(step 0, #40132, open: not on the tip), which step 0 registers with `lane = "manual"` in
`tests/test-execution.d/cmux.toml` (manual = no CI lane runs it). The author runs
it on the fleet before and after each step of section 6:

```
# the script builds a bench app at SHA itself (Release optimization, debug.* kept: reload.sh --config bench)
cmux-ci run --class exclusive --measurement --label measure --key mts-<step> --ref SHA \
  --script scripts/measure/main-thread-large-session.sh --artifact artifacts/main-thread/report.json \
  --arg=--config=bench --arg=--mode=test
```

It FAILS when, during 120 typed keys:
- any main-thread task is over 8 ms (`debug.main_budget` per-owner max, G3, and `debug.hangs` stall records);
- any refresh is missed while typing: a display frame interval over 1.5 refreshes (`debug.frames`), counting only
  frames between a key-down and the frame that shows its echo;

It prints the owner and stack of each failure. It fails on base `9e0c2ce826c` (the #40038 loop is there: 84 % of main
in one owner, tasks far over 8 ms; expected red, not run yet) and is the red-first test of step 0 and the before row of every later step.

A second, deterministic test needs no GUI and no timing (which observations a change wakes does not depend on the
host): `LargeSessionObservationTests` (target `CmuxNextAppTests`; not on the tip yet, its cases come with the PRs of
steps 3 and 4) builds a `DaemonStore` from a 60 x 6 fixture snapshot,
starts every session-wide observer through its real init, applies 5 x 100 title events through `DaemonStore.apply`,
and asserts, with `ObservationWakes`: (a) a spinner-only title change wakes 0 observations; (b) a title text change
wakes only observations of that tab and its workspace; (c) a probe changes one field of each of the 360 tabs in turn,
and no observation outside a list owner (`ObservedItems` list streams, which read ids only) is woken by changes in more
than one workspace. (c) is the "one observation per item" rule of section 3, checked by its effect.
It runs where every CmuxNext test runs; it adds no CI job, step or gate.

**Bench (the same script, `--mode=bench`):** prints, light session (1 workspace, 2 terminals) and large session,
host / macOS / refresh rate, and per owner: task count, p50 / p95 / max ms; key to frame p50 / p95 / p99 / max; missed
refreshes while typing; main-thread busy %. Run before and after each step by its author, interleaved arms
(`bench_arms.py`), on a quiet GUI mini with the input grant. Never on a person's Mac.

The wrapper `scripts/measure/main-thread-large-session.sh` and the `large` session builder are step 0 (section 6).
They reuse `sidebar-churn-typing.py` (typing with real keys, churn thread, `debug.hangs`, `debug.frames`) and
`perf-stress-session.py` (the builder and its shape check); they add the session shape and the title streams.

## 2. Derived state off main

**Rule (written):** [layer-ownership.md](layer-ownership.md) section 1, rule 1: "Rust owns every state, list, sort,
filter, search and rule ... it also owns every list a client shows: the order, the filter, the search, the grouping
and the paging run in Rust, and a client asks for its visible window and gets row diffs with a revision". Rule 2:
Swift "never mirrors a whole daemon list: a native Swift list holds only its visible rows, as value snapshots from the
Rust window, and applies the row diffs on the main thread in O(changed rows)". Also code-quality.md G10.

The app today keeps a full `@Observable` mirror (`DaemonStore`: `WorkspaceModel`, `TabModel`, ...) and derives on main.
The target: the daemon derives each item's display state and sends immutable per-item snapshots; the app applies them
in the store drain (frame class, O(changed)), at most one batch per frame (the inbox already coalesces whole-value
surface events: the newest per surface replaces the older one).

Where each derived state is computed today, and its target. `S/` = `Packages/macOS/CmuxNext/Sources/`. The end
state for app-side projections is the R-SWIFT-MIRRORS rewrite (its design is not in this repo: `cmux-view-rows`' `lib.rs` names it as `handoff/rewrites/R-SWIFT-MIRRORS/DESIGN.md`; one Rust `cmux-client-core` in the app process; its
contract crate `cmux-tui/crates/cmux-view-rows` landed in #33902, `Rows` / `Diff` / `Window` / `Applied`; the core
itself is not built yet). This doc does not redesign that rewrite. It names, per derived state, the Rust owner,
the snapshot and the seam, and the steps that can land before the core exists.

| # | Derived state | Today (thread) | Owner module (Rust) | Snapshot type | Delivery seam (at most one per frame) |
|---|---|---|---|---|---|
| D1 | Link places (agent pane links to workspaces and tabs) | `S/CmuxNextAgentPane/AgentPaneLinkPlaces.swift:111` `follow` -> `:148` `places(of:)`: since #40038 one `ObservedItems` item per workspace (before it: one `ObservationStream` over every machine x workspace x pane x tab, `places(in:)`); titles through `S/CmuxNextApp/SidebarBridge.swift:380` -> `S/CmuxNextApp/TabTitleResolver.swift:14` (`@MainActor`). Main. | `cmux-client-core` projection `link_places` (proposed here: a new window kind, not yet in R-SWIFT-MIRRORS); the tab title rule from D2. Swift-only inputs (incognito page titles, Home titles) enter the core as platform facts, one writer each (R-SWIFT-MIRRORS 3.2). | `cmux-view-rows` `Diff` of `LinkPlaceRow { key, workspace, title, resource_id, kind }`, keyed by tab key | The core's window for each agent pane page, taken at the frame owner's tick (V4: one frame per refresh) and passed to the page through the page bridge with no Swift transform (layer-ownership.md rule 3). Until the core: #40038, unchanged. |
| D2 | Tab titles: spinner glyph parse and "which title" | Raw OSC title in `title-changed` (`cmux-tui/crates/cmux-tui-core/src/mux/events.rs:55` `TitleChanged { surface, title }`). Swift parses the glyphs (`S/CmuxNextDaemon/Store/TerminalTitle.swift:17`) in `TabModel.applyTitle` (`S/CmuxNextDaemon/Store/TabModel.swift:446`), inside the store drain, main; the raw `title` is written on every spinner frame (`:447`). The "which title" rule is `TabTitleResolver` (main, per read). | Glyph parse: `cmux-tui-core/src/terminal_title.rs` (next to `TitleTracker` and `sanitize`). Which title: a pure function in `cmux-layout-reducer` beside `sidebar_face.rs` (which already shortens tab titles). | `TabTitle { text: Arc<str>, activity: Option<TitleActivity> }` on the tab entity; `TitleChanged { surface, text, activity }` | Today's seam: daemon event -> `DaemonConnection` decode off main -> `EventInbox` (newest per surface wins) -> `DaemonStore.drain` (frame class, one batch per frame). The daemon sends `TitleChanged` only when `text` or `activity` changed: a spinner frame sends nothing (C7). The raw `title` leaves `TabModel`. |
| D3 | Sidebar rows (face, order, sections) | Per-row observation `S/CmuxNextSidebar/Store/SidebarRowFeed.swift:43` (good); face in Rust through FFI `cmux_sidebar_face_rows` (`S/CmuxNextBridge/SidebarFaceBatch.swift:200` -> `cmux-layout-reducer-ffi/src/sidebar_face.rs`; rules in `cmux-layout-reducer/src/sidebar_face.rs`), called on main for changed rows; structural pass `SidebarBridge.sections` (`SidebarBridge.swift:389`) -> `SidebarMapping.sections` (`S/CmuxNextBridge/SidebarMapping.swift:103`), main, whole list. | `cmux-client-core` sidebar window; rules in `cmux-layout-reducer` (`sidebar_face.rs`, `sidebar_layout.rs`, `rows.rs`) | `CmuxSidebarFrame` (R-SWIFT-MIRRORS 4.2: revision, ops, changed rows) | `cmux_view_sidebar_frame(core, window)` at the frame owner's tick; the view applies ops in O(changed rows). Until the core: the face batch stays (O(changed rows)); the structural pass is measured in step 0 before any change. |
| D4 | Unread badges and the Dock count | `S/CmuxNextDaemon/Store/DaemonStore+Unread.swift:20` `recountUnread`: integer adds over 60 workspaces, assigned only on a change; read by `NotificationCenterService+Lookup.swift:67` -> `AppDockTile.swift:12`. Main, O(workspaces), cheap (60 adds). | `cmux-tui-core/src/mux/notifications.rs` (the notification ledger) | `UnreadTotals { app, per_workspace }` on the notification event | The notification event through the same inbox and drain. Low priority: not in the samples; listed so the rule has no exception. |
| D5 | Agent lanes: waiting, working, priority order | `S/CmuxNextAgentActivity/AgentLaneStore.swift:56` `set` -> `withMutation(\.lanes)` on every agent step: each reader of `lanes` wakes on every step. `ChiefSidebar.swift:171` and `SidebarPriorityFeed.swift:86` -> `AgentPriorityChats.swift:71` (sort `:75`) run O(lanes) on main per wake. `SidebarApprovals.swift:66` runs O(waiting). `RemoteMachinesSidebar.swift:126` arms one rebuild per refresh interval. `DockMenuController.swift:68` builds off main with a throttle. | acpmux (owner PL-acpmux), the same shape as `_acpmux/chats_window` (`cmux-tui/crates/acpmux/src/chats/window.rs`) | a priority window `Diff` keyed by session | acpmux window events -> decode off main -> applied at the frame like `AcpmuxChatWindows` (its test `ChatsWindowMainThreadTests` is the model: O(1) rows per chat change over 3,000 chats). Interim: readers read per-session cells (`lane(_:)`, `links(_:)`), never `lanes`. |

Rules for every row:
- Off main means in Rust: the daemon process or the client core's ingest thread. A Swift `Task.detached` that walks a
  copy of the `@Observable` mirror is not the target (it copies the mirror on main first, and the rule is Rust-owns).
- Snapshots are immutable values. The main thread adopts the newest one at the frame and applies it in O(changed
  items). It never waits for a projection: if the newest is not ready, the frame shows the previous one.
- Hidden workspaces: their rows change in Rust only; the app gets rows only for windows a view opened (V8, PATTERNS.md
  "Changes to hidden or background workspaces update the model only").

## 3. Observation granularity

Rule: one observation per item, never one over all workspaces x tabs. A list owner observes the list (ids and
order) without reading item fields; each item has its own observation (`ObservedItems`, CmuxNextCompat/ObservedItems.swift).
Access-list size is the number of tracked property reads in one evaluation; "large" is the session of 1.5 (60
workspaces, 360 tabs, 5 agents). Numbers are counts from reading the code (formula given), not measured.

Loops that read across workspaces or tabs on main (all `emit` closures run on the main actor, on macOS 14-15
through `withObservationTracking` and on 26+ through the system `Observations`). O1 is fixed on the tip (#40038);
O2-O9 are on the tip as written; each of O2-O7 and O9 has an open PR, not merged (state 2026-11-10), and O8 stays:

| # | Site (`S/` = `Packages/macOS/CmuxNext/Sources/`) | Walks | Access list, large session (estimate) | Re-runs on | Plan (step) |
|---|---|---|---|---|---|
| O1 | At `9e0c2ce826c`: `S/CmuxNextAgentPane/AgentPaneLinkPlaces.swift:97` (`follow`), `:107` (`places(in:)`). On the tip: `follow` `:111`, `places(of:)` `:148`, one item per workspace. Wired `S/CmuxNextApp/AppServices+AfterFirstFrame.swift:51` | before #40038: every machine x workspace x pane x tab | before #40038: 60 x 20 + 60 x 16 + 360 x 13 = about 6,800; with the restored New Tab walk (`AgentHistoryPage.title` -> `listTabsScoped`) about 12,000 to 70,000 | before #40038: any title, name, kind, URL or resource id of any tab; any workspace name; any tab list; any selection. The profiled loop. | DONE: #40038 (merged, per workspace); then D1 |
| O2 | `S/CmuxNextAgentLanes/SidebarSessionTreeFeed.swift:59` -> `chats` `:116` | every workspace, screen, pane, tab | 180 + 360 x 3 + lanes = about 1,300 | tab add, remove, move; kind or conversation; lane links | step 4 (#40126): `ObservedItems` per workspace; then a Rust window |
| O3 | `S/CmuxNextAgentPane/AttentionTabsWatch.swift:87` (snapshot walks `:35-36`, `items(in:)` `:102`); wired `AppServices+AfterFirstFrame.swift:46` | every tab, twice per machine | 2 x (180 + 360 x 2) = about 1,800 per machine | any tab's attention or resource id; the title of a marked tab | step 4 (#40130): per workspace; then the attention set from the notification ledger (D4's owner) |
| O4 | `S/CmuxNextBridge/SidebarDocMachines.swift:132` -> `byOrigin()` `S/CmuxNextApp/Favicons/AppServices+SiteFavicon.swift:25`; wired `SidebarSections/SidebarDocWiring.swift:53` | every tab of the local store | 180 + 360 + 60 x 2 = about 660 | any navigation or favicon change in any browser tab; posts `itemFaviconsChanged` on every value, also when equal | step 4 (#40213, replaces #40142): per workspace, emit only on a change |
| O5 | `S/CmuxNextMobileHost/IPhoneHostService.swift:374` -> `workspaceFolders` (`IPhoneHostService+Wiring.swift:107`) | every tab's `cwd` | 180 + 360 = about 540 | any `cd` in any terminal; the tree. Only while iPhone access is on and signed in. | step 4 (#40146): per workspace in the app; end state: the daemon sends the folder set (cwd is Rust-owned) |
| O6 | `S/CmuxNextAgentLanes/SidebarChatHistoryFeed.swift:44` -> `liveChats` `:103` -> `DaemonStore.liveTabs` (`S/CmuxNextDaemon/Store/DaemonStore.swift:262`) | every live tab of every machine | 1 + 360 x 3 + agents = about 1,100 | tab list revision; kind or conversation; lanes. Only while the session tree is on. | step 4 (#40137): per item |
| O7 | `S/CmuxNextAgentActivity/AgentLaneStore.swift:21`, `:56`: `withMutation(\.lanes)` per agent step; readers in D5 | every lane | 1 to 3 (small), but each wake of the Chief status and of the priority feed costs O(lanes), and O(lanes log lanes) per window for the priority sort | EVERY agent step of ANY session, many per second per agent | step 4 (#40154: the approvals reader first): readers use per-session cells; then D5 |
| O8 | `S/CmuxNextApp/Themes/ThemeCoordinator.swift:177` | personal workspaces and profiles | about 60 + profiles | a theme change (rare) | keep (rare trigger) |
| O9 | Waits until a match (all in `S/CmuxNextApp/`): `Handlers/ChiefInspectorHandlers.swift:192`, `SessionTransfer/SessionTransferService.swift:258`, `Home/HomeService+Workspace.swift:171`, `DeepLinks/DurableTabLink.swift:73`, `Cloud/CloudMachineCreation.swift:424` | all tabs or workspaces until a match | up to about 400 | a tab or workspace list change while the wait is open (ChiefInspector and SessionTransfer: also tab fields); each ends at its match, its time limit or its task's cancel (the Home and Cloud waits have no time limit) | step 4 (#40220, replaces #40149): wait on the one id (a per-id cell), not on the list |

Formula: an evaluation that reads `k` fields of each of `n` items tracks `k x n` entries, and Observation pays a key
path hash and a set insert per entry (the samples' `generateAccessList`, `_AccessList.addAccess`,
`AnyKeyPath._rawHashValue`, `Set._Variant.insert`). One change anywhere re-runs all of it.

Already per item (the pattern to copy): `S/CmuxNextSidebar/Store/SidebarRowFeed.swift:318` (one tracking per row,
dirty rows flushed once per frame); `S/CmuxNextCompat/ObservedItems.swift:5` and `ObservedItemsFeed.swift:9`, used by
`PaneController.swift:46` (strip tabs) and `NewTab/NewTabPlacesFeed.swift:20`; one observation per workspace in
`Notifications/NotificationCenterService+StatusRuns.swift:49`, `CmuxNextControl/Topology/ControlWorkspaceInfoCache.swift:93`,
`WorkspaceContentController.swift:246`, `CmuxNextWorkspaceNaming/WorkspaceAutoNamer.swift:182` (its list stream `:163`
reads only the list).

The access-list sizes are estimates from the code for the large session. `LargeSessionObservationTests` (1.5)
checks the rule by its effect: which tab changes wake each observation.

## 4. Terminals

Rule: a terminal frame presents on Ghostty's renderer thread and never waits for the app's main thread. cmux keeps
no app-level display link for terminals and no manual `ghostty_surface_draw` loop.

[ghostty-integration.md](ghostty-integration.md) (#40040) owns this: its section 2
lists the 27 present, hold, draw and wake paths (P1-P27) and moves P1-P8, P10-P12, P17, P18 and P23 into Ghostty's
renderer; PR #40055 (S-P3, open) fixes a terminal that stays main-routed after its watch runs out (Ghostty
`mainPending`, ghostty-next `src/renderer/metal/IOSurfaceLayer.zig`). This doc does not change either.

What this doc adds:

- **The main thread is still on the terminal's input path** (key and scroll dispatch, in Ghostty.app too). Sections
  1-3 are what keeps that path free: under the 03:03Z load a key waited behind the link-places walk, whatever the
  renderer did.
- **Until #40040's steps land, P3 routes frames through main** (EMBEDDER mode: every frame from the mode's start and
  after each main-thread size change until `committed`). Those presents are `frame` class work. The 1.5 test counts
  missed refreshes on the typed terminal, so it sees a main-routed terminal under load; it does not test the
  renderer itself (that is #40040's parity table).
- **Terminal title and bell events are terminal-stream facts that the daemon parses** (section 2, D2). The app
  never parses a terminal title on main for a hidden workspace.

## 5. Today's main-thread hot paths, measured cost

**Fleet bench: not measured** (still true on 2026-11-10 when this doc merged: step 0, #40132, is open and no GUI
host ran it). At 03:20Z the fleet controller (`http://100.89.225.106:18765`) did not answer
(`cmux-ci status` timed out); the office minis and controller are down (status/LEAD.md 02:48Z-03:19Z: the only
working routes are GitHub Actions runners on cmux-lawrence-2-light and the ultra1 pool, build-only, with no GUI
session or input grant). The large-session bench needs a GUI host with the input grant and step 0's script.

Exact commands, when a GUI route is back (step 0 adds the wrapper; until then the closest existing bench):

```
# closest bench that exists today (60 workspaces, sidebar churn, real keys, stalls and frames):
nx-remote --needs input --app-from-fleet cmux --tag mts-base --ref 9e0c2ce826c -- \
  python3 scripts/cmux-next/sidebar-churn-typing.py --app "$NX_APP" --tag mts-base --out "$NX_ARTIFACTS" \
  --session stress --workspaces 60 --samples 120 --churn-hz 10 --input real --trace
# after step 0:
cmux-ci run --class exclusive --measurement --label measure --key mts-base --ref 9e0c2ce826c \
  --script scripts/measure/main-thread-large-session.sh --artifact artifacts/main-thread/report.json \
  --arg=--config=bench --arg=--mode=bench --arg=--session=light,large
```

**What IS measured: the NIGHTLY samples.** These are production samples (`sample`, 1 ms interval asked), not the
bench. They give the share of main-thread time per path, not the time per task. They are not symbolicated; the cmux frames are offsets, named by #40038's symbolication with
the dSYM of nightly run 42709495104 (UUID 8C036144). Percent of main-thread samples; the 03:03Z sample is 5 s.
Counts are per symbol and inclusive, so rows overlap and do not add up to the total. #40038's description gives 1156
of 1387 for the 01:19Z `follow` row; this table has the count read for this doc.

| Path | 03:03Z (1995 main samples, load 175) | 01:19Z (1387 main samples) | Per task p50 / p95 / max ms | How often |
|---|---|---|---|---|
| `AgentPaneLinkPlaces.follow` -> `places(in:)` (O1) | 1678 (84 %): about 4.2 s of the 5 s | 1157 (83 %) | not measured: `sample` gives no task boundaries | each tab title change anywhere (agent spinners: many per second) |
| inside it: `withObservationTracking` / `generateAccessList` (tracking cost) | 1679 / 1552 | 1161 / 1066 | not measured | same |
| inside it: `cmux+0x10eee4` (probably `SidebarBridge.tabTitle` / `TabTitleResolver`; not symbolicated) | 1162 | 758 | not measured | per tab per evaluation |
| AppKit commit (`stepTransactionFlush`) | 163 (8 %) | 146 (11 %) | not measured | per frame |
| idle (`NSApplication run` / `__CFRunLoopRun` waiting) | 192 (10 %) | 18 leaf `mach_msg2_trap` | - | - |

Light session: not measured. O2-O9, D3's structural pass and the store drain: not measured (they are below the
samples' noise while O1 takes 84 %; after #40038 they are the next candidates). The ICU regex in the sample is the
Sentry lag-spike scrubber on a utility thread, not main (#40038).

Per-path rows to fill in step 0 (light / large, host, macOS, refresh rate):

| Owner (MainTaskBoard) | count | p50 ms | p95 ms | max ms |
|---|---|---|---|---|
| `DaemonStore.drain` | not measured | | | |
| O1 `AgentPaneLinkPlaces.swift:111` (after #40038) | not measured | | | |
| O2 `SidebarSessionTreeFeed.swift:59` | not measured | | | |
| O3 `AttentionTabsWatch.swift:87` | not measured | | | |
| O7 readers of `AgentLaneStore.lanes` | not measured | | | |
| D3 `SidebarBridge.sections` | not measured | | | |
| AppKit layout + commit (`RenderPassMeter`) | not measured | | | |

## 6. Migration plan

Each step: its own red-first test (committed before the fix, red on the base, green after, run on the fleet by the
author), and a before/after bench table from 1.5 (light and large; host, macOS, refresh rate; per owner p50/p95/max
ms and count; key to frame p50/p95/p99/max; missed refreshes while typing). A step lands ON, with the old path
deleted (no switch: the perf lead's rule m54 of 2026-11-07). No step changes #40038, #40040 or #40055.

State of the steps on 2026-11-10 (feat `b7dfd714d4e`). Only step 2 is merged. An open PR is not compiled, not run
on a Mac and not measured unless its own description says so; this doc claims no result for it.

| Step | PR | State |
|---|---|---|
| 0 | #40132 | open |
| 1 | #40134 | open |
| 2 | #40127 | merged (`ace25f3de93`): rules `observation-onchange` and `observation-scope` |
| 3 | #40141 | open |
| 4 | O2 #40126, O3 #40130, O4 #40213 (replaces #40142), O5 #40146, O6 #40137, O7 #40154, O9 #40220 (replaces #40149) | open; the other six are stacked on O2's branch (#40126) |
| 5 | none | not started |
| 6 | none (R-SWIFT-MIRRORS W3) | not started |

Bench table every step fills (from 1.5, `--mode=bench`, interleaved arms):

| Session | Arm | key to frame p50 / p95 / p99 / max ms | missed refreshes while typing | max main task ms (owner) | main busy % | top 3 owners p95 ms |
|---|---|---|---|---|---|---|
| light | before | | | | | |
| light | after | | | | | |
| large | before | | | | | |
| large | after | | | | | |

| Step | Change | Red-first test (committed before the change; fleet, before and after) | Owner |
|---|---|---|---|
| 0 | Measurement only. The `large` session (1.5) in `perf-stress-session.py` and `sidebar-churn-typing.py --session large` with the 5 title streams; `scripts/measure/main-thread-large-session.sh`; G3's per-owner task record in `MainFrameBudget.run` and `debug.main_budget`; G4's `DaemonStore.drain` owner; the 60 x 6 store fixture of `LargeSessionObservationTests` (its cases come with steps 3 and 4, each red first in its own PR). Fills section 5. | `tests/test_cmux_next_main_thread_large_session.py` (`lane = "manual"`): red on base `9e0c2ce826c` (O1; expected, not run). #40038 has landed since: on the tip it names the next owner, or it is green and step 1+ are measured-only. `MainFrameBudgetOwnerTimesTests` (the name in #40132): an owner's task time lands in its histogram with no allocation (red: no histogram). | PL-main |
| 1 | G1: every `ObservationStream` evaluation runs inside `MainFrameBudget.run(.visible, owner: site)` on both paths (the legacy hop and the system `Observations` closure), so the board names it, its time is recorded and the budgeted work after it in that frame yields. | `ObservationStreamSchedulingTests`: during an evaluation `MainTaskBoard` shows the stream's site as owner and class `visible` (red: no owner). | PL-main |
| 2 | G2 and 1.4's pre-push rules: an `onChange:` does only an enqueue; no session-wide read in an observation closure outside `ObservedItems`. Added lines only; not CI. | `tests/test_cmux_next_guardrails_observation.py` (`lane = "manual"`): a session-wide `ObservationStream` and a computing `onChange:` are refused, an `ObservedItems` list read passes (red: both pass). Landed with #40127. | PL-main with PL-arch |
| 3 | D2: the daemon parses the title glyphs (`terminal_title.rs`); `TitleChanged` carries `text` and `activity` and is not sent for a spinner-only change; `TabModel` drops the raw `title` and `TerminalTitle.swift`'s glyph rule. | Rust: `cmux-tui-core/tests/terminal_titles.rs`: 20 spinner frames of one text give 1 `TitleChanged` (red: 20). Swift: `LargeSessionObservationTests` (a): a spinner frame wakes 0 observations (red: every `title` reader wakes). Run with `cmux-ci run --class isolated` (cargo and swift test on the fleet). | PL-daemon (OWNERS.md, the cmux-tui daemon row) with PL-main |
| 4 | Section 3 rows O2-O7 and O9 to per item, one PR per row, by the row's area owner (OWNERS.md, where the area has a row). | `LargeSessionObservationTests` (b) and (c) per row: a change of one tab wakes only that row's item, and no item observation is woken from two workspaces (red: the row's whole-session evaluation wakes on every tab). | area owners; PL-main reviews the pattern |
| 5 | D4 and D5 from their Rust owners (notification ledger; acpmux priority window). | D4: one notification changes 1 workspace total and the app total, 0 other reads. D5: an agent step changes at most 1 priority row (the `ChatsWindowMainThreadTests` shape). | PL-daemon; PL-acpmux |
| 6 | D3 through a `cmux-client-core` window (R-SWIFT-MIRRORS W3.2); D1 needs a new window kind (`link_places`) that R-SWIFT-MIRRORS does not list yet. This doc adds only the main-thread contract: the frame take is O(changed rows), at most one frame per refresh (V4), measured by step 0's owners. | R-SWIFT-MIRRORS I5 (fan-out) with the large session's fixture, plus this doc's 1.5 test. | R-SWIFT-MIRRORS owner |

Order: 0 first (it measures everything else). 1 and 2 are small and independent. 3 removes the trigger rate (about
5 x 12.5 = 62 title writes per second in the large session down to the text changes, about 2.5 per second). 4 and 5
remove the remaining O(session) loops. 6 is the end state and belongs to its rewrite.

Done when: the 1.5 test passes on the large session on two fleet minis (120 Hz), and the bench shows no main task
over 4 ms p95 per owner and none over 8 ms.

## Not in this doc

- The #40038 fix itself (NIGHTLY LOOP owner; merged).
- Ghostty present paths (#40040) and S-P3 (#40055).
- CEF's message pump slice (2 ms, threading-model.md): unchanged.
- Process isolation of browser pages and Memory Saver rules: [PATTERNS.md](PATTERNS.md), unchanged.
