# cmux-next patterns

Status: binding for every change (lead, 2026-10-23). Each pattern has one shared implementation; use it, never a
private copy. A reviewer treats "this case did not use the pattern" as a finding (see
[REVIEW-STANDARD.md](REVIEW-STANDARD.md)). When you land the shared implementation of a pattern, replace "building"
with its file and add its guard. Counts are enforced by the pre-push ratchet (`arch-ratchet.json`, guardrails.py).

| # | Pattern | Rule | Shared implementation | Status / owner |
|---|---|---|---|---|
| P1 | Composition root | Objects with state are built once in the app's composition root (AppServices) and passed in through `init`. No `static shared` with state, no global container, no ambient fallback (`?? .app`). | AppServices + per-domain Host protocols | in progress (cmux-next-arch-targets) |
| P2 | Seam adapter | A C, ObjC, CEF, Ghostty or CFRunLoop callback enters Swift concurrency in one small adapter type; only there may `MainActor.assumeIsolated` appear, with a `// main-proof:` reason. | building | cmux-next-arch-targets |
| P3 | Targeted observation | No app-internal NotificationCenter names. State is `@Observable` or an `AsyncStream`; a system notification is observed once per app or window by an adapter that calls only the affected subscribers (example: WindowKeyFamily). `MainActorObservation` wrappers still count as observers. | WindowKeyFamily (key/active state) | in progress |
| P4 | Instant create | Every create (terminal, browser tab, pane, column, row, workspace, chat) shows a stand-in in the key's own turn through one intent path with client-minted ids, and reconciles with the daemon's reply by request id; failure rolls back. | DaemonService.intendNow + Intent + ProvisionalPane | New Column/Row and terminals done; browser tabs and the rest in progress |
| P5 | Main-thread budget | The main thread does input dispatch, the small visible-state change and the CA commit only. Socket and CLI requests are parsed on an I/O executor. One priority scheduler: input, then animation and visible updates (one coalesced batch per display frame), then background, each with a frame budget. | building (PL-main) | PL-main |
| P6 | Off-main frames | Content-only frames (terminal echo, page pixels) present without a main-thread commit; only geometry changes go through the CA commit. | building (PL-ghostty, PL-cef-layer) | cmux-b6 |
| P7 | Layer-hosted pages | Chromium pixels live in the cmux window's layer tree (CALayerHost on the fork's CAContext id); no page child windows; live resize synchronized with the pane in one transaction. | CEFHostedPageView (behind browserResize.layerHosting) | cmux-b6 PL-cef-layer |
| P8 | Motion | Per-frame work only for panes whose rect changed; content stays live and is laid out at each frame's size. | ScreenContentView motion (PL-motion-core) | cmux-b6 |
| P9 | Daemon request path | No I/O on a request path; one writer with snapshot readers; journal is best effort and coalescing; bounded per-connection queues; binary framing; event driven (no idle timers); client-minted ids and idempotent ops. Rules D1-D8 in [perf-lead.md](perf-lead.md). | building | cmux-b6 PL-daemon, PL-holder |
| P10 | Hidden costs nothing | A hidden thing keeps identity and the bytes to rebuild it; engines, renderers and timers stop. | hibernation (BrowserHibernation) | in progress |
| P11 | Always-on timing | Every action records `action.perform` / `action.commit` signposts (CmuxNextSignposts) in every build; perf claims cite them. | CmuxNextSignposts, scripts/cmux-next/perf-signposts.py | done |
| P12 | Benchmarks | GUI benches launch through `scripts/cmux-next/bench_launch.py`, use the STRESS session (`perf-stress-session.py`), report host, macOS and refresh rate, and check that Chromium pages are really Chromium. No new CI gates: run benches yourself on the fleet; the scheduled perf cron reports regressions. | bench_launch.py, perf-stress-session.py, perf-cron | done (migration of old scripts in progress) |
| P13 | Red then green | A fix lands with a guard that fails on the code before it and passes after, through runtime behavior; commit the guard first. | - | binding |
| P14 | Task traits | Off-main work states its priority (`WorkPriority`, derived from `MainWorkClass`; `Task.detached(priority:)`, queues with `qos:`; never `.userInteractive` off the main and frame threads, never `.unspecified`, `.background` only for work nothing waits for). Work that may block never runs on the cooperative pool: a process wait is awaited with no thread and the spawn runs on the run's own queue (`AsyncProcess`); file I/O, sync system calls and long CPU work run on `BackgroundWork` lanes (`.files`, `.system`, `.cpu`). No synchronous wait on lower-priority work; an awaiting caller boosts it at the call. No later escalation on any macOS (Swift's hook is macOS 26 only and its runtime symbol is strong-linked: a reference stops launch on 14/15), so work a person may wait for starts at that priority. | CmuxNextWakeups `BackgroundWork` (built once in AppServices as `work`), `AsyncProcess`, `OrderedWrites`; consumers so far: the 8 process-wait sites, UpdaterService's kept-versions listing and bundle clone; more in progress. Guard: guardrails rule `task-priority` checks only that a detached Task or a new queue states an allowed level; a blocking call inside a Task is not checked yet (it reuses PL-blocking's list once that lands). | PL-qos (Performance Lead) |

## Chrome performance model (Lawrence 2026-10-24)

Moved here unchanged from CLAUDE.md on 2026-11-08; CLAUDE.md keeps each rule as one sentence and links here.

- Copy Chrome's performance model (Lawrence 2026-10-24). Before you design a fast path, find how Chromium
  does the same job and do that, or write in the commit why cmux differs:
  - The main thread never blocks: no sync daemon, disk, network or lock wait on it (Chrome's UI-thread
    rule, `ScopedBlockingCall`). Input changes the model in the same turn; the backend reconciles later.
  - One frame per display refresh: input and changes coalesce to the frame (Chrome aligns input to the
    begin-frame), animation runs off the main thread where it can (compositor-driven), and an animation
    is interruptible from its current value. A layout or a reflow per animation frame is a bug.
  - Measure from the input to the frame shown, as distributions (p50, p95, p99, max), in lab benches and
    in opt-in field data (Chrome's EventLatency histograms and UMA). A mean alone proves nothing.
  - Memory: hidden pages are discarded by Memory Saver rules (never one with form input, audio, capture,
    a running download or a `beforeunload` handler; it reloads when shown), and renderer processes are
    shared per site above a limit set from physical memory, as Chrome does.
  - Process work by priority: what the person sees and touches first; hidden windows, background tabs
    and idle work are throttled (Chrome's background-tab timer throttling and task priorities).
    Throttling is only for work the person cannot see. It is never the fix for a slow visible action:
    remove that work, do not delay, debounce or throttle it.
- Go past Chrome where cmux is scripted. Scripts, the CLI, MCP and agents drive cmux far more than
  extensions drive Chrome, so automation must never compete with the person:
  - A scripted or agent change goes through the same action pipeline as a key press, and its local model
    change is O(changed items), never O(session).
  - Changes to hidden or background workspaces update the model only: no layout, no animation, no view
    work until the workspace shows, then one layout to its final state.
  - A burst of scripted changes (reorders, moves, splits) coalesces to one model update and at most one
    frame per window; batch requests apply as one transaction.
  - Input from the person always goes before automation (separate queues, the person's first), and the
    socket server parses, validates and coalesces off the main thread.
