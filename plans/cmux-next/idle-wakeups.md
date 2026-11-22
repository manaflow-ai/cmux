# cmux next: idle wakeups and spin loops (2026-09-30)

User requirements: "make sure it doesn't spinloop", "all polling is bad". The error class is any code that wakes up when nothing changed (an idle wakeup), or loops without making progress (a spin). The budget is architecture.md section 5: 0.0% CPU over 60 s with nothing changing, window visible or hidden.

## 1. Root causes

The spins and idle wakeups found here are design gaps, not concurrency bugs:

1. **No sanctioned way to wait.** Each owner rolled its own display link (9 owners), timer, sleep loop or retry loop. Nothing counted wakeups, so nothing showed which owner woke the app.
2. **Safety-net and polling timers instead of events.** The CEF pump's fixed 30 Hz / 1 Hz fallback, ChromiumWarmup's 250 ms idle poll, fixed-period reconnect loops, and in cmux-tui a 50 Hz accept poll in every terminal host, 100 ms stream-disconnect polls, 250 ms / 500 ms / 1 s / 15 s supervisor ticks.
3. **Level-triggered sources that are not drained or stopped.** A read source on a listener whose `accept` fails with EMFILE, or on a hung-up PTY master, fires again at once forever.
4. **Retries without capped backoff and without a wake event.** Reconnect storms that spawn `cmux-tui server ensure` every 2 s forever, a flapping daemon reconnected at 20 Hz, a mobile accept cycle restarted at once.
5. **"Keep ticking while a flag is set" instead of "tick while something moves".** The layout ticked every vsync while a divider gesture was active even with a still pointer; a gesture that never ended spun at 120 Hz forever (state-audit L1).

## 2. Sanctioned primitives (CmuxNextWakeups)

These are the only allowed ways to wake up. `scripts/cmux-next/check-concurrency.sh` fails on any timer, raw display link, sleep, `while true`, `while !Task.isCancelled` or `repeat {` outside the module unless the line or the comment block above carries `// wakeup-allow: <reason>`.

| Primitive | Contract |
| --- | --- |
| `FrameScheduler` | One per window (`forWindow`, `forView`) plus `FrameScheduler.app` for window-less work. Owns the only display link, runs only while a `FrameClient` is active, drops the link when the last client goes idle. `activeClients` lists owners (debug.wakeups). Stall deadline and link rebuild when frames stop (state-audit D4). |
| `FrameClient` | A reason to receive frames (animation, autoscroll, settle, batch). The tick returns false to go idle. `isAnimation: false` marks batch work (store drain) so the busy watchdog does not excuse it. |
| `DemandTimer` | One-shot deadline on an injected clock: `schedule` (resets), `scheduleIfIdle`, `cancel`. Never repeats. Each fire is one ledger entry. |
| `Backoff` | Exponential, capped, jittered retry spacing; `wait(owner:)` records the wait. A retry first waits for an event that can make it succeed; Backoff only spaces attempts after a real failure. |
| `WakeupLedger` | Counts every primitive's wakeups per owner and reason; rate over the last 10 complete seconds, lazily rolled (no timer). |
| `assignIfChanged`, `UpdateCycleDetector` | Observation updates that settle: a set of the same value does not notify; re-entrant update cycles are counted and logged in debug builds. |
| `ExpectedActivity` | Input, animation-frame and terminal-output counters for the busy watchdog. |
| `ProcessUsage` | `proc_pid_rusage` CPU time and wakeups per process (app, helpers, daemon, hosts). |

cmux-tui gets the same rules (section 6): blocking reads and condvar waits with no timeout, one-shot computed deadlines, one shared Backoff.

## 3. Diagnostics

- `debug.wakeups`: ledger owners with rates, each FrameScheduler with its active clients, cumulative CPU and wakeups per process (app, `cef-renderer`, `cef-gpu`, other helpers, `daemon`, `terminal-host`). Diff two calls for rates.
- `debug.hangs` busy records (`kind: busy`, `busy_count`): a 10 s window in which the main thread (> 30% of a core), the process (> 50%) or a Chromium helper (> 50%) used CPU while no input, animation frame or terminal output happened. The record has a main-thread stack sample and the busiest ledger owners. Windows open on a main-run-loop wake and end with one DemandTimer, so an idle app costs nothing.
- `scripts/cmux-next/bench-idle.sh <tag>`: launches the tagged app and measures app, daemon, hosts and helpers in four scenarios (terminals; plus a static Chromium tab; with that tab's workspace hidden; window minimized). Dogfood builds report it.

## 4. Known incidents

| Incident | Root cause | Evidence |
| --- | --- | --- |
| App 1-3% CPU idle whenever a Chromium browser exists | **Proved.** CEFMessagePump re-armed its CFRunLoopTimer after every pass at `CEFPumpPolicy.busyFallback` (1/30 s) while any browser existed, even an idle, hidden or minimized page, and at 1 s forever once CEF started. Fixed by the CEF pump agent (23289d1437c): the pump runs when CEF asks (OnScheduleMessagePumpWork). Fork API 7 (cef-154.0.28-cmux.7, pinned in 190a3095b92) makes MessagePumpExternal demand-driven (it asks again when its slice ends with work left and reports its next delayed task), so with that pin the pump has no follow-ups at all (`SafetyNet.none`, gated on `cmux_cef_api_version() >= 7`). Older pins keep a finite chain of one-shot follow-ups after each pass (1/30, 2/30, 4/30, 8/30, 16/30 s, 1 s, then nothing). | Base bench: app 56-62 wakeups/s, 0.6-1.0% CPU with one static tab (terminals only: 0.35-1.35/s). Pump agent: old 28.8-31.4 pump wakeups/s at 0.58-1.33% app CPU; new 0.0-0.93/s after Chromium settles (2.7/s in the first minutes) at 0.02-0.27%; CEF started with no browser 0.27/s at 0.067%; DevTools open ~127/s (CEF asks); 120 fps page 8.8/s. With cmux.7 and `SafetyNet.none`: 0 follow-ups; idle static tab 1.3-2.2 pump wakeups/s, all CEF requests (Chromium's own delayed tasks, 1.1-2.2/s, which the old fork hid), 0.18-0.33% app CPU; 120 fps page 4.9/s. These cmux.7 numbers were taken at load average 270-320 and have no quiet re-measure. |
| Chromium Renderer 144-157% and GPU 15-70% after 20-26 min on idle pages | **Not proved.** Hidden tabs are not the cause: in base code a Chromium tab in another pane tab, another workspace, a terminal-selected pane and an offscreen strip column already reports `visibilityState: hidden`, rAF 0, timers ~0.3 Hz and 0% renderer/GPU (measured by the visibility agent). The observed pages were visible. DevTools blamed the page's own animation for one case (example.com now animates its text), and a fresh instance did not reproduce. Remaining candidates: a visible animating page (Chrome behaves the same), a Chromium bug after long uptime, GPU process contention on an overloaded machine (load average 308 during this work). The busy watchdog now records a helper busy for 10 s with no input. | Visibility agent measurements (section 7); no reproduction. |
| Machine load from long-lived test apps and leaked daemons | Leftover tagged apps with Chromium pages keep helpers busy, and every leaked cmux-tui terminal host woke 50 times a second (terminal_host_runtime accept poll), so N leaked hosts cost 50 x N wakeups/s machine-wide. Fixed: host accept blocks (section 6); cleanup rules in AGENT-BRIEF.md; bench-idle ends its daemon's terminals. | cmux-tui audit; `uptime` load 300+ during this work. |

## 5. Inventory: CmuxNext (Swift)

Status: **fixed** (this work), **ok** (event-driven, one-shot, or stops itself), **reviewed** (`wakeup-allow`).

| Site | Owner | Trigger | Stops | Could spin / idle wake | Status |
| --- | --- | --- | --- | --- | --- |
| DisplayLinkFrameScheduler x4 (store drain, presentation, control queue + snapshot publisher, 2 invariant monitors) | App | pending work | paused when empty | paused, not dropped; stall task per enqueue | fixed: `FrameBatcher` clients of `FrameScheduler.app` |
| Layout DisplayLinkDriver | LayoutRootView | springs, gestures | `onFrame` false | ticked while a gesture was active with a still pointer; forever if the gesture never ended (L1) | fixed: FrameClient; frames only while moving or intents pending (red/green IdleFramesTests) |
| ResizeCoordinator | App | pane size change | settle idle | ok (bound to main screen) | fixed: FrameClient on `.app` |
| TabStripView display link | Tabs | springs, drag autoscroll | settled | ok | fixed: FrameClient |
| SidebarListView autoscroll link | Sidebar | pointer in edge zone | zone left or content edge | ok | fixed: FrameClient |
| TabDragSession ghost link | App | drag motion | settled / landing | ok | fixed: FrameClient on the ghost panel |
| DebugFrameProbe | App | `debug.frames start` | `stop` only | ran every frame forever if no `stop` | fixed: FrameClient + 10 min DemandTimer expiry |
| TerminalMirrorView | Terminal debug window | shown | hidden | every frame while shown | reviewed: FrameClient, debug window only |
| ControlSocketServer accept | Control | listener readable | `stop()` | **spun at 100% on EMFILE/ENFILE** (1,070,431 accepts in 500 ms) | fixed: EAGAIN waits, other failures suspend the source with Backoff 50 ms-2 s (red/green ControlSocketAcceptTests) |
| ControlConnection read/write sources | Control | readable/writable | EOF, error, close | ok (EAGAIN keeps the source armed; backpressure suspends) | ok |
| ControlConnection drain timer | Control | half-close | fires once / close | one-shot | reviewed |
| Event stream heartbeat | Control | `events.stream` client | hangup | 15 s keepalive the client requested (`include_heartbeats`) | reviewed (protocol) |
| ControlDeadline, ControlSnapshot barrier, MainActorWorkQueue item deadline | Control | request | answer | one-shot | reviewed |
| MainThreadWatchdog thread | Control | main run loop awake | main asleep | wakes every 30-50 ms only while the main thread is awake; a nested run loop in a non-common mode would keep it waking | ok, noted |
| LocalPTYTerminalIO read source | Terminal (debug PTY) | readable | exit source | **spun after the slave side hung up while the shell lived** | fixed: hangup cancels the read source (no test target in CmuxNextTerminal) |
| ChromiumWarmup | App | Chromium likely | idle or 60 s | **polled every 250 ms** up to 240 times | fixed: DemandTimer re-armed for the rest of the quiet period; menu end notification |
| WindowManager save debounce | App | window state change | fires once | one-shot | fixed: DemandTimer |
| DaemonConnection reconnect | Daemon | connection lost | connected / close | **2 s forever, `server ensure` spawn per attempt; flapping daemon at ~20 Hz** | fixed (reconnect fork, 887b84df5ca): Backoff 50 ms-30 s, 10 timed attempts, then only socket-directory change or RetryWake events |
| DaemonStartup first connect | Daemon | launch | connected | **5 s forever on launch failure** | fixed: 250 ms-30 s, 10 attempts, then events |
| DaemonStore resync | Daemon | snapshot failed | success | **2 s forever while connected** | fixed: 100 ms-10 s, 8 attempts on a DemandTimer, then the next daemon event |
| DaemonService local/remote loops | App | lost connection | stop | remote: 1 s outer loop + inner 2 s, API call and `remote connect` spawn per attempt | fixed: RetryPacer, NWPathMonitor and app activation wake it; startup deadline is a DemandTimer |
| SocketWriter | Daemon | queued writes | error | 0-byte write counted as progress | fixed: failure |
| LineTransport reader | Daemon | blocking read | EOF/error | ok | reviewed; request deadlines are DemandTimers |
| WindowStateStore CAS | Daemon | save | 3 retries | bounded | reviewed |
| MobileIrxHost accept cycle | Mobile | endpoint ready | stop | **nil accept restarted at once with failures reset** | fixed: 250 ms-60 s, 10 cycles, then relay-state events (no red test: no seam in IrxEndpointSupervisor) |
| MobileIrxHost endpoint activation | Mobile | start | success | 5 s-300 s forever | fixed: 8 attempts, relay change cuts short |
| UnixSocketLane empty read | Mobile | read | final/error | empty non-final delivery looped the splice pump | fixed: ends the stream |
| ConfigFileWatcher | Settings | kqueue vnode on file and directory | stop | ok: already event-driven (no wait-for-file loop; it watches the nearest existing ancestor) | ok |
| CEFMessagePump | Browser | CEF schedule + fixed fallback | never | **30 Hz / 1 Hz forever** | fixed by the pump agent (23289d1437c): demand-driven. With fork API 7 (cef cmux.7) it wakes only when CEF asks (`SafetyNet.none`); older pins keep a finite one-shot follow-up chain (CEFPumpTimer.swift, wakeup-allow) |
| CEFReplyWaiters, CEF shutdown timeout | Browser | DevTools call / quit | reply | one-shot | reviewed |
| Hover card, click-and-hold, double-click, spring-load, record write-back | Tabs, Sidebar, App | UI event | fires once / cancelled | one-shot, injected sleep | reviewed |
| Agent pane render-rate re-apply | AgentPane | rate change (after a settled scroll) | fires twice, then stops | one-shot, injected sleep | reviewed |
| GhosttyRuntime wakeup_cb | Terminal | libghostty | per tick | coalesced by an atomic flag | ok |
| ~25 `for await` over `Observations` | App | model change | owner deinit | no self-writes found; Observations does not dedupe equal writes | ok; `assignIfChanged` for writers |
| ControlSnapshotPublisher `withObservationTracking` | App | model change + every frame after a batch | never cancelled | stacked registrations multiply work under compat reads (not idle) | open |

### Polling sites removed

CEF safety-net timer (pump agent), ChromiumWarmup 250 ms poll, DebugFrameProbe unbounded run, the four always-available display links' per-enqueue stall tasks (now one per scheduler), DaemonConnection 2 s reconnect, DaemonStartup 5 s retry, DaemonStore 2 s resync, DaemonService remote 1 s loop, MobileIrxHost activation 5-300 s loop and immediate accept restart, WindowManager ad hoc sleep debounce, and in cmux-tui the items in section 6.

## 6. Inventory: cmux-tui (Rust)

The daemon uses std threads, blocking IO, mpsc channels and condvars; each terminal is a separate `__terminal-host` process.

Fixed in dc5cb26c16d (failing idle test `cmux_next_daemon_idle_has_no_periodic_wakeups`) and 51b68635143 (fixes); hosted CI red run 36692729021 (macOS daemon 34.2 wakeups/s, host 43.4/s; Linux daemon 37/s, host 49.9/s), green on Linux run 36696885418 (daemon 0 and host 1 context switches in 10 s).

| Site | Before | After |
| --- | --- | --- |
| Server accept loop (server.rs `mux-server`) | `let Ok(stream) = listener.accept() else { continue }`: 100% CPU on EMFILE/ENFILE/ENOBUFS | shared capped, jittered `cmux_tui_core::backoff` for persistent errors (also provider-management, WebSocket and remote accept loops) |
| Terminal host accept loop (terminal_host_runtime.rs) | non-blocking listener + `poll(fd, 20 ms)` for the life of every terminal: 50 wakeups/s per host | polls the listener plus an accept waker (socket pair) written by exit and last-stream-close; the launch-owner deadline is a one-shot timeout until it passes |
| Headless main loop (main.rs) | `recv_timeout(250 ms)` on an All-events subscription (4 Hz plus every output) | condvar signalled by signals, shutdown requests and the remote runtime's end |
| Stream threads (terminal/browser/sidebar attach, notifications, events-out, attach-out, browser frames) | `recv_timeout(100 ms)` to notice a closed writer: ~10 wakes/s per stream | writer close, stream close and attach cancel fire a StreamInterrupt that wakes the blocked receive |
| Session event and journal streams | 1 s epoch waits | wait for a journal event or the stream's close |
| Journal fanout tailer, hook dispatcher | 1 s waits | wait for a commit, a worker completion, shutdown or a scheduled retry; backoff after failures |
| Journal plugin supervisor | 500 ms waits, 500 ms `try_wait` poll | condvar; a `waitid(WNOWAIT)` thread reports the child's exit |
| Idle-close reaper | 15 s tick with no policy | sleeps until the next policy deadline; woken by policy changes and detaches |
| Unplaced-terminal reaper | a failing scan left a past-due deadline: hot loop | due deadlines deferred with growing spacing |
| Hosted-surface reconnect | new backoff per loss; immediate reconnect on accept-then-drop or resync | losses within 10 s of a reconnect share one backoff |
| Host forced drain | busy loop on a hung-up waiter for 100 ms | waiter dropped from the poll set |
| Kitty image budget worker | identical wave re-ran at once | counts as a failure and backs off |
| Local PTY reader | WouldBlock slept 1 ms | Interrupted retries, WouldBlock backs off |
| Remote runtime bootstrap (50 ms), browser proxy parent check (250 ms), parent-exit wait (100 ms) | polls | select on the owner channel and signal pipe; kqueue NOTE_EXIT / pidfd |
| Writer waiting on a full stream | 100 ms re-check | left: only while a stream is full (backpressure), not idle |

## 7. Measurements

Idle benchmark, same machine, 60 s windows after 20 s settle. Machine load average was about 300 (shared by many agents), so absolute CPU numbers are noisy; wakeups per second are the stable signal.

### Base (`nospinb`, origin 4c2ec798a99: primitives only, no behavior change)

| Scenario | app | daemon | each terminal host | Chromium helpers |
| --- | --- | --- | --- | --- |
| terminals | 0.006-0.05% CPU, 0.35-1.35 wakeups/s | 0.03% CPU, 35-46 wakeups/s | 0.05% CPU, 47-48 wakeups/s | none |
| + static Chromium tab (selected) | 0.63% CPU, 61.9 wakeups/s | 0.03%, 36.7/s | 0.05%, 48.5/s | each < 0.04% CPU, < 2 wakeups/s |
| Chromium tab in a hidden workspace | 1.02% CPU, 56.1 wakeups/s | 0.05%, 56.4/s | 0.05%, 48.3/s | each < 0.03%, < 1/s |

The app's ~60 wakeups/s with Chromium is the CEF pump's fixed 30 Hz fallback (plus its twin wakeups); it does not drop when the tab is hidden. The daemon and every terminal host wake 35-66 and 47-49 times a second at idle: the cmux-tui polls in section 6.

### After (`nospina`, 98d5750d09e: Swift primitives and fixes, demand-driven CEF pump 23289d1437c, cmux-tui pin 51b68635143), `--fresh`

| Scenario | app | daemon | each terminal host | Chromium helpers |
| --- | --- | --- | --- | --- |
| terminals | 0.010-0.013% CPU, 0.28-0.45 wakeups/s | 0.000%, 0.03/s | 0.000%, 0.00/s | none |
| + static Chromium tab (selected) | 0.16% CPU, 2.95 wakeups/s | 0.000%, 0.03/s | 0.000%, 0.00/s | each <= 0.023% CPU, < 1 wakeup/s |
| + a second workspace selected | 0.011-0.021%, 0.38-0.65/s | 0.000%, 0.03-0.05/s | 0.000%, 0.00/s | (see note) |
| window minimized | 0.011-0.018%, 0.32-0.45/s | 0.000%, 0.03/s | 0.000%, 0.00/s | (see note) |

Every scenario meets the pass criteria. Note: in the two final bench runs the first Chromium tab did not open inside the bench (the action missed the 2 s control deadline during a cold CefInitialize on the loaded machine, and no renderer appeared in 90 s), so the hidden-workspace and minimized rows there have no Chromium tab; the static-tab row is a manual 60 s measure on the same build after opening the tab through the socket. With the pump fix alone (6ce646ac01a, old cmux-tui) a static tab measured 2.37-3.23 app wakeups/s at 0.35-0.38% CPU, and the pump agent measured 0.0-0.93 pump wakeups/s once Chromium settles. The busy watchdog opened one window per 10 s only while the old pump kept the main thread awake (ledger `BusyWatchdog.window` 0.1/s); with the new pump the app sleeps and it opens none.

cmux-tui hosted CI idle test (10 s, context switches per second): macOS daemon 34.2 -> 0, host 43.4 -> 0.1; Linux daemon 37.0 -> 0, host 49.9 -> 0.1 (red 36692729021, green 36699544372, pin verification 36704549440).

### Chromium visibility (visibility agent, tagged `nospincef`, base code, CEF 154.0.28-cmux.4, 60 s per case)

| Case | visibilityState | rAF | 10 ms timer | renderer / GPU CPU |
| --- | --- | --- | --- | --- |
| Animated page, selected | visible | 127 Hz | 105 Hz | 12.9% / 7.4% |
| Static page, selected | visible | 0 | 1 Hz (its own) | 0.02% / 0.0% |
| Other Chromium tab selected in the pane | hidden | 0 | 0.3-1.3 Hz | 0.03% / 0.0% |
| Terminal tab selected in the pane | hidden | 0 | 0.3 Hz | 0.05% / 0.0% |
| Tab in another workspace | hidden | 0 | 0.7-1.3 Hz | 0.03% / 0.03% |
| Window minimized | hidden | 0 | 0-0.5 Hz | 0.02% / 0.01% |
| Offscreen strip column | hidden | 0 | 0.8 Hz | 0.05% / 0.13% |

Every case returns to visible when shown. No visibility change was needed: the fork's tab strip hides inactive tabs (Chromium engine behavior), hidden content hides the page's host view, and a minimized parent hides the page window (occlusion). UNVERIFIED: fully covered window, window on another Space, app hidden, audio in a hidden tab (reaching them needs moving the user's windows or system input).

### Tab lifecycle (tagged `tlnext`, 2dbaac77833, `bench-idle.sh --fresh`, 30 s per case, load average about 275)

| Case | App wakeups/s | App CPU | Daemon wakeups/s | Renderers |
| --- | --- | --- | --- | --- |
| terminals | 0.63 | 0.010% | 0.03 | none |
| chromium-static | 3.07 | 0.242% | 0.03 | 0.33 and 0.93 wakeups/s, under 0.01% CPU |

Within the base range (0.28-0.45 and about 3). The ledger shows only `BusyWatchdog.window:deadline` (0.1/s): the content lifecycle, parked workspaces and hibernation add no periodic wakeup (hibernation arms one one-shot `DemandTimer` for the earliest page deadline, 60 min by default, and listens to the memory pressure dispatch source). chromium-hidden was skipped: its `workspace new` request missed the 2 s control deadline on the loaded machine.

## 8. Status and open items

Landed on feat-cmux-next: primitives 4c2ec798a99; display-link migration, L1 red/green, accept backoff red/green, local PTY hangup, ChromiumWarmup, debug.wakeups, busy watchdog, gate rules, bench (this agent, f2d6ff9e9d2 through the bench commits); reconnect and IO loops ad7db2fa600, 887b84df5ca, 2f862b32b3e; CEF pump 15d83591310, 23289d1437c; cmux-tui dc5cb26c16d, 51b68635143, pin 98d5750d09e; minimize action bd75453ec9b.

Open:
- Past the retry budget, a local daemon that fails with no event (no socket change, no app activation, no network change) stays disconnected until one happens (decision: no timed retry forever).
- A daemon crash loop is limited only by launch time: each new socket is a real event and retries at once.
- Closed: the CEF pump is purely demand-driven with the cmux.7 pin (fork API 7). The follow-up chain remains only for older pins. The remaining idle pump wakeups with a static tab (about 1-2/s) are Chromium's own delayed UI-thread tasks that CEF reports; reducing them is Chromium work, not the pump.
- The events.stream heartbeat (15 s, client-requested) and cmux-tui's backpressure re-check (100 ms, only while a stream is full), coderouter usage poll (5 min, remote API has no push), remote protocol heartbeats and the Windows plugin child-exit check remain.
- The busy watchdog does not know which tab a Chromium renderer serves (the record names the helper kind), and misses a background-thread spin that never wakes the main thread after its first window.
- ControlSnapshotPublisher stacks withObservationTracking registrations (extra work under compat reads, not idle).
- MainActorWorkQueue/ControlDeadline/ControlSnapshot deadlines and the UI one-shot delays still sleep in their own Tasks (reviewed `wakeup-allow`); moving them onto DemandTimer would put them in the ledger.
- The bench's first Chromium tab can miss the 2 s control deadline on a loaded machine (cold CefInitialize); the bench waits for a renderer but that also failed twice.
- UNVERIFIED: fully covered window, window on another Space, app hidden, audio in a hidden tab; cmux-tui remote, browser-proxy and Windows paths (compiled on CI only).
