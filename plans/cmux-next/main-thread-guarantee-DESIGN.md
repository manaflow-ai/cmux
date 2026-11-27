# cmux next: what we can guarantee about the main thread (2026-11-15)

Lawrence 2026-11-15: "how can we statically ensure that code that runs in main thread will never take longer than
X ms/ns/cycles? we need to be able to verify that the app will be buttery smooth, 120fps and never hang, even as
we add a ton of features in the future."

Related: `main-thread-budget.md` (the per-frame scheduler), `threading-model.md` (threads, seams, the runtime
blocking detector), `hang-reports-DESIGN.md` (field reports), `architecture.md` 5a ("the main thread never
waits"), `perf-lead.md` (fleet numbers), `idle-wakeups.md`.

## 1. The short answer

A static proof of "this main-thread code never takes more than X ms" is not possible for a macOS app, and no
amount of tooling changes that. A static proof of the **causes** of long main-thread turns is possible, and that
is the part we enforce at compile/CI time. The rest is a runtime budget that is measured, not proven.

Why the wall-clock bound cannot be proven (first principles):

- **The OS preempts us.** The main thread can lose its core at any instruction: a loaded Mac, a thermal clamp,
  App Nap, a higher-priority thread. A 1 ms function can take 40 ms of wall time with no change to its code.
- **Memory is not uniform.** A page fault on a compressed or swapped page costs 0.1 to 10+ ms; first touch of a
  framework's text costs dyld work. No source-level analysis sees this.
- **Swift is not a WCET language.** ARC release can cascade through an object graph of any size (a `deinit`
  chain), the allocator can take a slow path, generics and protocols dispatch dynamically, and Objective-C
  messages go to code we do not own (AppKit, Core Animation, WebKit, CEF).
- **AppKit's cost depends on state, not code.** Layout and the Core Animation commit cost what the view and
  layer tree costs at that moment. The same `needsLayout = true` costs 0.2 ms with 3 tabs and 30 ms with 300.
- **Halting.** Bounding loops in general code is undecidable. We can bound loops only by restricting the
  shapes of code we accept.

WCET tools exist for hard-real-time C on fixed hardware with no OS, no virtual memory and no dynamic
allocation. None of that holds for us. So "120 fps and never hang" becomes three properties we can hold:

| Property | How it is held | Static? |
|---|---|---|
| P1. The main thread never **waits** (on a lock, the disk, a socket, another process, the GPU, time) | ban the waiting calls in main-actor code | yes: lint/compiler, CI blocks |
| P2. Main-thread work is **O(what changed)**, never O(all state) or O(input size) | ratchet heavy constructs on the main actor; architecture (daemon owns state, batched deltas) | partly: ratchet + review |
| P3. Each frame's main-thread work fits the **budget** (4 ms scheduled + input + commit at 8 ms; 120 Hz frame is 8.3 ms) | the `MainWorkScheduler` per-frame budget, the watchdog, fleet benches | no: runtime, measured |

P1 is the only cause of unbounded (seconds-long) hangs: a pure CPU loop on small inputs does not hang, a wait
does. So P1 is where a static guarantee pays most, and it is the layer this design makes blocking in CI.

## 2. The layers, and what each one holds

### Layer 0: the type system (Swift 6 strict concurrency) — in place

- UI targets build with `.defaultIsolation(MainActor.self)` (`uiSwiftSettings`); everything else is
  nonisolated by default. The compiler proves which code runs on the main actor and refuses data races.
- Off-main work is written as a `nonisolated` type, a `@concurrent` function, an `actor`, a
  `BackgroundWork.run(_:mayBlock:)` lane, or the Rust daemon. The compiler, not a lint, makes sure that code
  does not touch main-actor state.
- What Swift cannot express: "this function is never called on the main actor" for a synchronous function, or
  "unavailable on the main actor" for a system API. `@available(*, noasync)` is about async contexts, not
  isolation, so it does not help. That gap is why layer 1 is a lint and not a compiler error.

### Layer 1: static bans and ratchets in CI — in place, completed by this change

Three scanners over `Packages/macOS/CmuxNext/Sources`. All three decide which lines are main-actor code with one
lexical scope tracker (`main_actor_lines` in `check-main-actor-work.py`), and read Package.swift's isolation through
`swift_scope.py`:

1. **`check-concurrency.sh`: zero tolerance.** Blocks the `cmux-next checks` job. Bans, everywhere:
   `DispatchQueue.main.sync`, semaphore/group/condition waits, sleeps, `waitUntilExit`, raw locks, nested run
   loops, synchronous XPC, blocking `FileHandle` reads, pipe writes on the caller's thread, `poll(-1)`,
   `Host.current()`, `dlopen`, `SecStaticCodeCheckValidity`, unbounded `AsyncStream` buffers, timers and
   spinning loops (`idle-wakeups.md`), synchronous `NSWorkspace` opens. On the main actor: descriptor
   `read/write/recv/send/connect/accept/select`, `poll`, `Data/String(contentsOf:)`, GPU readback waits.
   An exception needs `// concurrency-allow: <reason that proves it is safe>`.
2. **`check-main-actor-work.py`: ratchet.** Per file and rule, the count may not grow past
   `main-actor-work-baseline.json`. Heavy CPU (line splits of whole inputs, regexes, JSON/plist decodes,
   directory walks, string scans in loops, a main-actor `Task` per line or event) and, from this change, the
   **blocking system calls with no checked seam yet**: process launch, Keychain (`SecItem*`, securityd IPC that
   can wait on a prompt), `SecTrustEvaluate*` (can fetch revocation over the network), Accessibility IPC
   (`AXUIElement*`: waits up to 6 s on an app that does not answer), `CGWindowList*` (window-server IPC),
   DNS (`getaddrinfo`), `waitpid`, `fsync`, SQLite statements, and synchronous file writes and file-system
   changes through `FileManager`. A reviewed exception needs `// main-actor-ok: <reason>`.
3. **`guardrails.py` (pre-push only, by Lawrence's 2026-10-23 rule): the diff gate.** Refuses new raw
   blocking primitives and new main-thread seam calls in the lines a push adds.

What this change fixed in layer 1 (2026-11-15):

- The ratchet ran in **no** CI job and no hook. The pre-push gate leaves it out on the stated grounds that
  "their CI checks read the pushed tree's own copy", but no CI check did. Unguarded since about 2026-10-23,
  it drifted to 107 hits over its baseline in 91 files. It now runs in the `[concurrency]` group of the
  `cmux-next checks` job, next to `check-concurrency.sh` (no new job or step).
- Scope bugs: a `nonisolated` function with a default closure argument (`stillWanted: () -> Bool = { true }`)
  gave its isolation to that closure, so its body counted as main-actor code (false positive in
  `TerminalLaunchFrames.writeOne`, `ComputerUseHelperV2.logControlLines`). `BackgroundWork` lane closures
  (`mayBlock:`) counted as main-actor code. Both fixed, with tests (`tests/test_check_main_actor_work.py`,
  red on the old script, green on the new).
- The baseline was refreshed to the tree at landing (section 4 lists the debt it records).

What layer 1 proves after this change, and what it does not:

- Proven (CI blocks): no new wait, sleep, lock, sync hop, nested run loop, synchronous XPC, blocking pipe or
  descriptor IO, or synchronous file read lands in main-actor code without a written reason; no file gains
  more heavy-CPU or blocking-system-call sites on the main actor than it has today.
- Not proven: (a) calls made **through** a helper: the scanners are lexical, so a main-actor call to a
  nonisolated synchronous function that blocks inside is not seen (the runtime detector sees it if the call
  goes through a seam); (b) the lexical scope tracker is a heuristic (brace depth), not the compiler's
  isolation; (c) cost that comes from data size (a loop over every workspace on main), which no pattern
  catches; (d) AppKit/Core Animation cost; (e) the existing debt in section 4.

### Layer 2: the runtime detector of blocking calls — in place (Debug, bench, Nightly)

`CmuxNextCompat/Threading` seams (`FileManager.checked`, `Data(blockingContentsOf:)`,
`Process.blockingRun`, `DispatchSemaphore.blockingWait`, a contended `Mutex` over 2 ms, and the rest in
`threading-model.md`) call `assertBlockingAllowed`. On the main thread outside `allowBlocking(<reason>)` the call
is recorded once per call site: Debug menu "Main-Thread Blocking (N)", `debug.blocking`, unified log category
`blocking`; `CMUX_BLOCKING_TRAP=1` stops at the call. This catches what layer 1 cannot: blocking calls reached
through helpers. Its gap: raw calls that do not go through a seam (slice (c) of `threading-model.md`).

### Layer 3: the hang watchdog with stacks — in place (every build)

`MainThreadWatchdog` (`CmuxNextControl/Diagnostics`), started by `AppControl` in every build:

- `CFRunLoopObserver` heartbeats; any main-thread turn over 50 ms (`CMUX_NEXT_HANG_THRESHOLD_MS`, down to 4 ms
  for diagnostics) is a stall, recorded with a mid-stall stack sample of the main thread (`ThreadStackSampler`)
  into a ring of 128 (`debug.hangs`), symbolicated in-process (`StackSymbolicator`).
- A turn still running at 2 s is a hang, reported while it runs (a hang that never ends never becomes a
  stall): Sentry `MainThreadHang` with the stack, and the opt-in Nightly hang reports.
- Debug builds fail an assertion on a 10 s hang that used at least half its time on CPU.
- Each stall names the scheduled task it caught (`task_owner`, `task_class`, `task_budget_ms`);
  `CMUX_NEXT_MAIN_TASK_DIAGNOSTICS=1` also records every task that ran past its class budget, with a stack.
- Starvation probe, nested run-loop watch, signposts `stall.main_task` and `stall.over_budget`.

Nothing in this change alters the watchdog: the ask's "hang watchdog that reports stacks" is already met.

### Layer 4: the per-frame budget — in place (`main-thread-budget.md`)

The main thread does input dispatch, the minimal mutation of visible state and the CA commit. Everything else
is a task of `MainWorkScheduler` in a class (input, frame, visible 2.5 ms, automation 1 ms, background 0.5 ms
per frame), with the commit time measured (`RenderPassMeter`) and taken off the next frame's budget. This turns
P3 from "every function is fast" into "the scheduler stops at the budget", which holds as features grow
because a new feature's work queues behind the budget instead of extending the frame.

### Layer 5: fleet benches with budgets — in place, run by agents, not CI-gated

`cmux-next-frame-pacing.yml` (manual dispatch: flings, golden interactions, Cmd-N/T/D key to frame, launch),
`scripts/cmux-next/sidebar-churn-typing.py --input real`, `bench_cli_storm.py`, and the
`perf-hot-benches.json` map from `// perf-hot:` functions to their bench. Targets: action to committed frame
< 10 ms p95, key to frame p95 < 8 ms, max main-thread stall < 8 ms under load, motion 0 drops. Lawrence
2026-10-23: perf runs never slow a nightly or a dev build, and are not CI gates; each agent runs them on the
fleet before and after.

## 3. The other two stacks

**Rust daemon (cmux-tui, acpmux).** It has no UI thread; the property that matters is that the app's main
thread never waits for it (the socket client is async and off-main: `check-concurrency.sh` bans the synchronous
paths) and that the daemon answers the app in bounded time. Static: `await_holding_lock` is already a workspace
lint (`cmux-tui/Cargo.toml`); `spawn-owner-clippy/clippy.toml` uses `disallowed-methods`. Next step (not in this
change): a `disallowed-methods` set for async code (`std::thread::sleep`, `std::fs::*` and
`std::process::Command::output` in `async fn` outside `spawn_blocking`), since blocking a Tokio worker delays
every reply the app waits on. Runtime: `await-tree` (`scripts/cmux-next/await-tree-client.sh`) for stuck tasks.

**Webviews (React in WKWebView/CEF).** Each page has its own JS main thread; a long task there drops the page's
frames but not AppKit's, unless the app waits on the page. Static: the app never calls into a page
synchronously (`evaluateJavaScript` is async; no synchronous message reply on the main thread). Runtime: the
gallery's frame harness already measures "no long task over 50 ms after ready" (`webviews/src/gallery/`).
Next step (not in this change): a `PerformanceObserver('longtask')` in Nightly pages that reports each long task
over 50 ms with its page and the React component that rendered, through the same hang-report path.

## 4. The debt the baseline records (2026-11-15)

`check-main-actor-work.py --list` prints every site. Counts at landing, main-actor code only:

| Rule | Hits |
|---|---|
| JSON / property-list decode | 111 |
| synchronous file write or file-system change | 68 |
| line split of a whole input | 20 |
| process launch | 9 |
| a main-actor Task per line or event | 9 |
| Accessibility IPC | 8 |
| string scan inside a loop | 7 |
| regular expression | 4 |
| window-server list query | 1 |
| keychain call | 1 |
| directory walk | 1 |

Order to burn it down (each fix moves the work to a `BackgroundWork` lane, a `nonisolated` type or the daemon,
then lowers the baseline in the same commit): the waits first (Accessibility IPC, process launch, keychain,
window list: these can take seconds), then file writes, then input-sized CPU (decodes, splits, regexes) where the
input is not provably small. When a rule reaches zero it moves from the ratchet to `check-concurrency.sh`'s
zero-tolerance list.

## 5. What would make the guarantee stronger (not in this change)

1. **Compiler-isolation scope instead of brace depth.** Run the ratchet's rules on SwiftSyntax with the
   isolation the compiler infers (or on `-dump-ast` / the indexstore), so helpers and closures resolve exactly.
   This removes the heuristic gap (layer 1 b).
2. **Transitive blocking.** Mark blocking functions (`@Blocking` macro or a doc tag) and propagate through the
   call graph from the indexstore: a main-actor caller of a function that calls a blocking API is flagged. This
   closes layer 1 a, and is the closest thing to a static proof of P1 the toolchain allows.
3. **All raw calls through seams** (`threading-model.md` slice (c)), so layer 2 sees every blocking call.
4. **A stall gate on the fleet's end-to-end runs**: each run ends by reading `debug.hangs` and fails on a stall
   over 100 ms that is not on a reviewed list. That needs Lawrence's OK, since it is a CI gate.
