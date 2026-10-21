# Crash and hang classes: crash-only recovery

Owner: the crash-only lane (bead cx-1ret4). Started 2026-10-20 after Lawrence
asked to handle every way cmux NEXT can crash so that each one is easy to
recover from. Companion to [crash-elimination.md](crash-elimination.md), which
holds the prevention program (ratchet, bans, fuzz); this page is the class
inventory and the recovery side.

## Principle: crash-only software

After an Objective-C exception, a Swift trap or a fatal signal, the state of
the process is undefined, so the app never tries to go on in-process. For
every class:

1. **Prevent** it at build time (a lint, a ban, a fuzz target), where a
   prevention is possible.
2. **Bound** it: the process ends in a known number of seconds, whatever
   blocks.
3. **Restart** fast, without user action.
4. **Lose nothing**: durable and live state lives outside the UI process.
   Terminals live in cmux-tui terminal hosts, agents in acpmux agent hosts,
   pages in Chromium renderer processes, the layout in the daemon's SQLite
   registry (committed before each reply), drafts in acpmux and the
   recovery-draft store.

## How a run ends now (2026-10-21)

| Stage | Owner | Bound |
| --- | --- | --- |
| Uncaught Objective-C exception | `NSApplicationCrashOnExceptions` (every channel) | ends at the throw; the crash gate requires < 8 s with Sentry on |
| Fatal signal, Swift trap | `AppRunMarker` handler records the signal, then the default action | at once |
| Crash path that blocks (the 2026-10-20 freezes) | `CrashDeadline` thread (PR #22843) | 10 s |
| Crash path with every thread suspended (a crash reporter that blocks while it writes) | **out-of-process watcher** `cmux __app-watch` (#22844, this lane) | 15 s |
| Main thread that never returns to its run loop | **watcher** (this lane) | 2 s in-process report + 30 s |
| Requested quit that hangs | `QuitDeadline` (`_exit(0)` after 15 s) and a second SIGTERM/SIGINT/SIGHUP, both once the quit runs on the main thread; a quit asked for while the main thread already hangs never starts, and the watcher still ends that hang (`Q` stops only the relaunch) | 15 s, else the hang limit |
| Restart after a crash or a watcher ending | **watcher relaunches the app** (this lane) | see "Measured" |
| Force Quit, `kill -9`, jetsam, power loss | none: not relaunched (someone may have ended it on purpose); the next manual launch restores everything, no notice | user |

The watcher (cmux-tui `crates/cmux-tui/src/app_watch.rs`, app side
`CmuxNextCrashReporting/AppWatcher.swift` and `AppWatchChannel.swift`) is a
separate process in its own session, started at launch with a pipe. The app
writes one byte per event (`C` crash began, `H`/`h` hang began/ended, `Q`
quit began) with one non-blocking `write(2)`, async-signal-safe. The watcher
blocks in `kevent` on the app's exit, the pipe and the next deadline: no
polling. To end a run it writes `run.watch` (why, after how long), samples
the stacks where the system allows it (Debug and DEV builds), sends SIGABRT
(the app's handler records it and macOS writes a crash report with every
thread), then SIGKILL after 3 s. It never ends a process that a debugger
traces. It relaunches the app executable with the app's launch environment
when the run ended in a crash it saw or an ending it made, no quit began
(`Q`, also sent from the TERM/INT/HUP handlers), the run was not itself a
restart that died within 60 s, fewer than 3 relaunches happened in the last
10 min (`watch.restarts` in the run-marker folder), and the launch was not
an agent or test launch (`CMUX_NEXT_NO_ACTIVATE=1`). Knobs (tests and
diagnostics only): `CMUX_NEXT_APP_WATCH=0`, `CMUX_NEXT_APP_WATCH_HANG_SECONDS`
(0 = never end a hang), `CMUX_NEXT_APP_WATCH_CRASH_SECONDS`,
`CMUX_NEXT_APP_WATCH_RELAUNCH=0`, and `CMUX_NEXT_APP_WATCH_RELAUNCH=1` to
relaunch an agent launch.

## Inventory

Frequency: Sentry, `environment:nightly-next app:cmux-next`, all data
(first event 2026-10-10, read 2026-10-21; 14 d = 30 d). "Dev." = distinct
`app.device` tags (no user identity is sent). Users with telemetry off send
nothing, so every count is a lower bound. Re-run with the commands at the end.

Gate column: **yes** = a CI gate on feat-cmux-next blocks it; **part** = a
gate covers some of it; **no** = nothing. Time to window: see "Measured".

### Hangs (by far the most frequent class)

| Class | Events / dev. | Prevention gate | Runtime bound | Recovery | User loses |
| --- | --- | --- | --- | --- | --- |
| Main-thread stall 250 ms to 2 s (`MainThreadStall`) | 4,739 / 200 | part: check-concurrency BAN (waits, sleeps, sync hops, blocking reads), perf-gate counter budgets, main-actor-work ratchet (safe-push only, **not in CI**) | ends by itself | none needed | frames |
| Main-thread hang over 2 s (`MainThreadHang`) | 892 / 126 | same | **watcher: 2 s + 30 s** (was: none in Release, until Force Quit) | watcher relaunch, restore | layout changes of the last 500 ms; browser scroll since the app last lost focus |
| Sentry app hang over 8 s (`App Hanging`) | 279 / 38 | same | same | same | same |
| Lock wait on the main thread (`__ulock_wait2`, part of the hang rows; 41GD) | 231 / 31 | part: raw-lock BAN in check-concurrency; **no lock-order or deadlock check** | watcher | same | same |
| CEF work on the main thread (44ZD) | 145 / 12 | no | watcher | same | same |
| Crash path that blocks (2026-10-20) | 2 freezes before #22843 | yes: crash-ends-app gate `frozen` | 10 s | watcher relaunch | as a crash |
| Crash path with every thread suspended | not measurable from Sentry (the app froze) | yes (this lane): crash-ends-app gate `suspended` | 15 s | watcher relaunch | as a crash |

### Objective-C exceptions

| Class | Events / dev. | Prevention gate | Runtime bound | Recovery | User loses |
| --- | --- | --- | --- | --- | --- |
| Unrecognized selector (46NN `-[PageWKWebView draggingEnded:]`, 46P5 `-[CmuxApplication cancelTerminate:]`) | 8 / 2 | yes: super-call selector table (#22818), Chromium contract (#22873), `objc_selector` BAN; part: `dynamic_dispatch` ratchet (80). Gap: the table holds macOS 26.5, 26.7 and 27.0 only; the app deploys to macOS 14 | at the throw | watcher relaunch (new) | as a crash |
| AppKit layout loop (40Q3) | 1 / 1 | runtime only: `LayoutPassGuard` (37 non-fatal reports) | at the throw | same | same |
| NSRangeException, mutation during enumeration, nil in a collection | 0 seen | part: TextLayoutFuzzTests, `render_font`; NSRange/UTF-16 ban planned | at the throw | same | same |

### Swift traps

| Class | Events / dev. | Prevention gate | Runtime bound | Recovery | User loses |
| --- | --- | --- | --- | --- | --- |
| Concurrency runtime abort (`swift_task_dealloc`, 453Q) | 7 / 1 | part: `async_closure_default_arg` (heap overrun from a defaulted async closure; BAN in Irx, ratchet 23 elsewhere) is the known cause of this signature; not proven for 453Q | at once | same | same |
| Isolated deinit on executor (`swift_task_deinitOnExecutor`: 44XN `HomeCursorRectHold`, 43X8 `NewTabInputBuffer`) | 3 / 2 | part: check-concurrency bans an explicit `isolated deinit`; these sites have none, so the trap comes from another path (bead) | at once | same | same |
| Range construction / index (46RW `TiledBody.update` lowerBound, MessagesLab vendor code) | 1 / 1 | part: `index_subscript` BAN in 10 modules; **no gate for a `a..<b` built from runtime bounds**; PRs #22832/#22836 fixed two sites by hand | at once | same | same |
| Assertion with no message (450F) | 2 / 2 | unknown kind | at once | same | same |
| Force unwrap, `as!`, `fatalError`, `precondition`, `assumeIsolated`, `unowned`, IUO | 0 seen | yes: BAN in the app package closure | at once | same | same |
| Integer overflow (`+ - *`) | 0 seen | **no** (`int_conversion` covers conversions in 10 modules only) | at once | same | same |
| Exclusivity violation | 0 seen | no | at once | same | same |

### Memory and native code

| Class | Events / dev. | Prevention gate | Runtime bound | Recovery | User loses |
| --- | --- | --- | --- | --- | --- |
| CEF / Chromium in the browser process (455X, 46VH `cmux_shim_create_window` cef_log abort; 45RQ popup window host) | 6 / 5 (most devices of any crash class) | part: `dcheck_always_on=false` required by ensure-cef.sh; nothing for the create-window abort | at once | same | same; pages reload from their records |
| Bad access in Swift or AppKit (42E3 TaskGroup retain, 45GP null in `HistoryPalettePages`, 458K dangling `NSUndoManager` target) | 3 / 2 | **no**: TSan/ASan exist (`CMUX_SWIFT_SANITIZE`) but no workflow runs them | at once | same | same |
| libdispatch misuse (4543: suspended source released in `ControlConnection.deinit`) | 1 / 1 | no | at once | same | same |
| Unknown (46SM, no debug file) | 2 / 1 | n/a | at once | same | same |
| Rust panic across the app FFI (`cmux-app-ffi` 17 functions, `cmux-terminal-client` 33: no `catch_unwind`, so a panic aborts the app) | 0 seen | yes (this lane): crash ratchet class `ffi_unwind` (a ratchet, not a ban): an `extern "C" fn` body without `catch_unwind` may not be added; today 153 such bodies (app-ffi 17, terminal-client 33, rd-ffi 44, remote-browser-host 28, layout-reducer-ffi 12, ghostty-vt 10, others 9) | at once | same | same |
| Ghostty, C/C++ shim outside CEF | 0 seen | no ASan/UBSan lane, no libFuzzer target | at once | same | same |
| Stack overflow (deep JSON, layout trees) | 0 seen | no | at once (alternate signal stack records it) | same | same |

### Resource exhaustion

| Class | Events / dev. | Prevention gate | Runtime bound | Recovery | User loses |
| --- | --- | --- | --- | --- | --- |
| Memory (jetsam) | 0 seen (not reported) | no | the kernel | memory-pressure handlers hibernate pages, drop spares, release parked workspaces, drop the standby terminal host; a jetsam kill is not relaunched (no `C`) | the next manual launch restores |
| Disk full | 0 seen | no | n/a | registry fails the batch; launch snapshot backs off; acpmux and window saves only log; **no Swift handling** | unsaved window and draft writes |
| File descriptors | 0 seen | no | n/a | the daemon raises `RLIMIT_NOFILE` (hard limit, cap 65,536); **the app and acpmux do not** | n/a |
| Threads / connections | 0 seen | no | n/a | the daemon caps 64 connections (`server.busy`) | n/a |

### Child process death

| Child | Recovery today | Time | User loses | Gap |
| --- | --- | --- | --- | --- |
| cmux-tui daemon | the app reconnects and re-runs `server ensure` (50 ms to 30 s backoff, heartbeat every 15 s, 2 misses end a hung connection); terminal hosts outlive the daemon and are adopted; views reattach on the new connection epoch | restore-journey `daemon` variant reports it | output while no daemon ran comes back as a screen snapshot (`terminal.output.gap`) | no launchd supervisor; hosts adopt one at a time |
| terminal host | respawn with the old screen as seed (0, 2, 10, 30, 60 s; at most 5 per 10 min) | seconds | the running program | none |
| acpmux | agents live on in agent hosts; the next acpmux adopts them; the page reconnects with backoff (at most 2 s apart) and its reconnect starts a new acpmux when the old one crashed (`daemon.pid` names a dead process, cx-6bgzj); a daemon the user stopped (pid file removed) stays stopped (#16468) | seconds | nothing (drafts are in `session.json`) | none for a crash; a stopped acpmux needs a new chat |
| Chromium renderer | tab state machine `.processExited`, sad tab with Reload; a hidden tab reloads when shown | user action for a visible tab | page state (form input) | no auto-reload of the visible tab |
| Chromium GPU process | Chromium starts a new one; `CEFChildProcessMonitor` logs it | about 1 s | nothing | none |
| WebKit content process | pages host and agent pane reload by themselves (at most 3 in 600 s), browser tab shows the sad tab | at once | page state | browser tab not auto-reloaded |

### Update and quit

| Path | Bound | Recovery |
| --- | --- | --- |
| Quit hangs in the engine stop | `QuitDeadline` 15 s, then `_exit(0)` | next launch clean |
| Second quit signal | at once (`forceExit`) | same |
| Sparkle install and relaunch | normal quit path (`Q` sent, the watcher does not relaunch); a stale same-build update is refused (#22874) | Sparkle relaunches |

## Measured

Time from the end of a crashed run to the relaunched app's control socket
(`relaunch_s`) and to its restart notice on the first window (`notice_s`),
from `scripts/cmux-next/crash-ends-app-gate.py` on a fleet-built Debug app on
cmux-lawrence-2. Before this lane nothing relaunched the app: the time was
whatever the user took to notice and reopen it, and a hang or a crash path
with every thread suspended never ended (Force Quit).

| Run | Ends after | relaunch_s | notice_s |
| --- | --- | --- | --- |
| suspended (crash, all threads suspended): before | never (Force Quit) | no relaunch | no relaunch |
| suspended: now | 22.7 s (15 s grace, about 4 s stack sample, SIGABRT then SIGKILL) | 2.5 s | 2.5 s |
| hang (main thread blocked; gate limit 5 s, product 30 s): before | never in Release (Force Quit) | no relaunch | no relaunch |
| hang: now | 13.4 s (2 s report + 5 s + sample + SIGABRT) | 2.4 s | 2.4 s |
| exception (Sentry on) | 0.1 s | no watcher in this run (it proves the in-process path alone) | |
| frozen (blocked trap) | 10.1 s (crash deadline) | no watcher in this run | |

Source: nx-remote job 1021-000933-838d4f on cmux-lawrence-2, fleet app of
e70aee548793 (tag crashwatch-v4), `crash-ends-app-gate.py --runs
suspended,hang,exception,frozen`: PASS. The relaunched app came back as
`restarted` with `watch_ending` set, and its notice read "cmux restarted after
a problem. Your windows and terminals are back. Cause: a crash did not finish
in 15 s; ended by the watcher" (hang: "not responding for 5 s; ended by the
watcher"). The gate's app has an empty session; the restore time of a large
session is what perf-gate's `relaunch` scenario budgets.

## Next slices, by frequency

1. Hangs (126 devices): the watcher bounds them; the causes still need the
   hang reports (41GD lock waits, 44ZD CEF on main). Wire the main-actor-work
   ratchet into CI.
2. CEF create-window abort (5 devices): a cmux shim fix and an embedder case.
3. Unrecognized selector (2 devices, 8 events): extend the selector table to
   macOS 14 and 15 probes; check that 46NN's build has #22818.
4. Rust FFI: `catch_unwind` at every `extern "C"` of cmux-app-ffi and
   cmux-terminal-client (the `ffi_unwind` ratchet then lowers; app FFI
   changes need the FFI release and pin).
5. Sanitizer lane (TSan/ASan) for the bad-access class.
6. The restart notice wording names what was restored (issue #13742).

## Re-run the frequency data

```bash
sentry api "organizations/manaflow/events/?dataset=errors&environment=nightly-next&statsPeriod=30d&query=app%3Acmux-next%20%21tags%5Bmechanism%5D%3A%5Bmain_thread_watchdog%2CAppHang%5D&field=issue&field=tags%5Bmechanism%5D&field=count()&field=count_unique(tags%5Bapp.device%5D)&field=min(timestamp)&field=max(timestamp)&sort=-count()&per_page=100"
sentry api "organizations/manaflow/events/?dataset=errors&environment=nightly-next&statsPeriod=30d&query=app%3Acmux-next&field=tags%5Bmechanism%5D&field=level&field=count()&field=count_unique(tags%5Bapp.device%5D)&field=count_unique(issue)&sort=-count()"
sentry api "organizations/manaflow/issues/CMUXTERM-MACOS-XXXX/events/latest/"
```
