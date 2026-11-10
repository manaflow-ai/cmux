# xbench: cmux NEXT against every other browser

One reproducible benchmark for the rows of Ardia's 2026-10-19 comparison
(msg 2654): power idle hidden / in view / scrolling / video / switching tabs,
cold launch to window, new tab first paint, idle wakeups and CPU at 20 tabs,
memory at 1, 10 and 20 tabs. It measures cmux NEXT (a Chromium tab, a WebKit
tab, terminals only) and Chrome, Helium, Ardia, Dia and Safari on the same Mac,
the same way. The goal: every cmux cell at a tenth of the best other browser.

## Run it (fleet mini only, never a laptop)

```sh
cmux-ci run --class exclusive --measurement --pool perf-lead --label measure \
  --script scripts/measure/perf-bench.sh --ref <40-char sha> \
  --artifact artifacts/perf-bench/results.json \
  [--arg=rounds=3] [--arg=launches=2] [--arg=idle=60] [--arg=active=30] \
  [--arg=cmux=build|nightly] [--arg=browsers=cmux-chromium,chrome,helium] [--arg=gate=1] \
  [--target-worker <name>]
```

- `cmux=build` (default) builds a Release app at the ref (`reload.sh --release`);
  `cmux=nightly` measures the latest nightly-next DMG instead (no build).
- Competitors come from the vendors' DMGs (`fetch_browsers.py`), are verified with
  `codesign --verify --deep --strict` and made read-only. Safari is the system's.
- The log ends with `BENCH.md` (the tweet's table). `cmux-ci artifact <step> results.json`
  returns every sample, the machine, versions and the medians.
- `gate=1` fails the step when a cmux row is worse than
  `baseline/<chip>-macos<major>.json` by more than 15 % and the unit's floor
  (5 ms, 15 MB, 2 mW, 0.1 %, 2 wakeups/s). The nightly job
  (`.github/workflows/cmux-next-perf-bench.yml`) runs it.
- The gate also fails with `PERF-BENCH-GATE INCOMPLETE` when an expected row or
  browser cell is missing. The checked-in baseline defines expected rows, so a
  newly emitted row becomes expected after it is recorded in a baseline. An
  intentional unsupported surface may be listed as `"row|browser"` in an
  `unsupported` array in either JSON document.

Quick iteration for one area (about 10 minutes):
`--arg=rounds=1 --arg=launches=1 --arg=idle=20 --arg=active=15 --arg=browsers=cmux-chromium,helium`.

Local, against bundles you have: `python3 scripts/perf-bench/xbench.py run --out /tmp/xb
--app cmux=/path/cmux.app --app chrome=/path/Chrome.app --browsers cmux-chromium,chrome`,
then `xbench.py report --out /tmp/xb --md BENCH.md --json results.json`.

## Resource budget (`cmux-budget`)

The idle cost of cmux NEXT with hidden work, against fixed budgets (`budgets.json`), rather than
against other browsers. `budget.py` runs it as the browser `cmux-budget`, with xbench's isolated
launch and counters: launch, idle on Home (CPU, wakeups, footprint), then one workspace with 5 more
terminals and, per engine, one Chromium or WebKit tab of the local idle page plus 5 more, each
hidden behind the first terminal. Rows: footprint per hidden terminal, the first hidden tab of each
engine (its engine processes come with it), each further hidden tab, the whole app; then CPU % and
wakeups/s over the whole process tree (app, CEF and WebKit helpers, cmux-tui, acpmux, terminal hosts)
with the window in view and with the app hidden. The final sample in `results.json` keeps every
process (pid, kind, command, footprint, RSS, CPU %, wakeups/s), so a PR can quote before and after
per process from the same measurement.

```sh
cmux-ci run --class exclusive --measurement --pool perf-lead --label bench --target-worker cmux20-bench \
  --script scripts/measure/perf-bench.sh --ref <40-char sha> --artifact artifacts/perf-bench/results.json \
  --arg=browsers=cmux-budget --arg=launches=0 --arg=rounds=1 --arg=tabswitch=off --arg=palette=off
```

About 10 minutes per round after the Release build. The log prints one `PERF-BUDGET` line per
budget and BENCH.md gets a "Resource budget" table. A budget with `"enforce": false` is advisory
(reported, never fails); `xbench.py report` exits 1 when an enforced one is broken or not fully measured (missing, a session error, or fewer samples than rounds).
Budgets start advisory where the base breaks them; tighten the limit and enforce it once the base
holds it. The scenario's sizes and settle times are in `budgets.json`; the idle windows follow
`--arg=idle=` (60 s). `xbench.py gate` skips the `budget-*` rows: budgets.json gates them. The
nightly runs it with the other browsers (about 11 minutes a round on cmux20).

Overhead rows (plans/cmux-next/speed-of-sound-DESIGN.md, floor 0 at idle): disk writes KB/s,
Mach messages/s, syscalls/s and context switches/s over the idle windows, process and thread
counts, and a `/usr/bin/sample` call tree of the hidden app's main thread (logged as `hidden main:`
lines and kept in results.json), so a Release build's idle wakeups get a named owner. The heavy
scenario, `--arg=budgets=scripts/perf-bench/budgets-heavy.json`, adds 150 workspaces and 20 hidden
terminals and Chromium tabs, and the `budget-memory-per-workspace` row.

## Tab switch in a real window

By default the step also builds a tagged Debug app and runs
`scripts/cmux-next/tab-switch-matrix.py` (a118's): one pane holding 2, 10 and 30 tabs of
each kind (browser Chromium and WebKit, Markdown, chat), warm, switched with Ctrl-Tab,
Cmd-Shift-] and strip clicks through the app's real key and mouse paths. Each row is end to
end: OS input event age + intent to the Core Animation commit that shows the tab (p50 / p90
ms), with frames missed. BENCH.md gets a "Tab switch" section and the gate gets
`tab-switch-<kind>-<count>-<input>` rows. `--arg=tabswitch=off` skips it;
`--arg=tabswitch=chromium,markdown --arg=tabcounts=2,30` narrows it.

## Palette open

The same Debug app also runs a182's `scripts/cmux-next/palette-open-stages.py --no-gate`:
Cmd-Shift-P and Cmd-P key-down to the palette's committed first frame from a terminal, Chromium page
(and its page window), WebKit page, Markdown and Home. BENCH.md gets a "Palette open" section and the
gate gets `palette-open-<surface>-<key>` rows (Debug only). `--arg=palette=off` skips it. a182's own
entry `scripts/measure/palette-open.sh` is allowlisted too.

## For the tab switch rewrite (a168) and other perf agents

- Tab switch only, fastest loop: `cmux-ci run --class exclusive --measurement --label measure
  --script scripts/measure/perf-bench.sh --ref SHA --target-worker <owned mini> --arg=browsers=cmux-terminal
  --arg=rounds=1 --arg=launches=0 --arg=tabswitch=chromium,webkit,markdown,chat --arg=tabcounts=2,10,30
  --artifact artifacts/perf-bench/tab-switch.json`. a118's direct entry
  `scripts/measure/tab-switch.sh --arg=--matrix ...` is allowlisted too.
- The matrix reads `debug.key`, `debug.mouse`, `debug.tab_switch` and `debug.window_snapshot`. A rewrite
  that changes those hooks keeps their reply shape, or updates `tab-switch-matrix.py` in the same
  commit, so before and after numbers compare.
- Before/after: `xbench.py report --out RUN --tabswitch tab-switch.json`, then
  `xbench.py gate --results new.json --baseline old.json`.

## Hosts

The step needs a logged-in console user: `open` fails on the AWS workers (aws-m4pro-*, no console
login; xbench exits 3 with `PERF-BENCH-NO-GUI`). The bench host is **cmux20-bench** (cmux20, Apple M6,
macOS 27.0, user `cmux` at the console): a controller worker that advertises only `bench`, so it takes
no CI step and no build (hq `build-fleet/mini-ops/bench-worker/bench-worker.sh`). Submit with
`--measurement --pool perf-lead --label bench --target-worker cmux20-bench`; the nightly job does (cmux20 is
owner-only for pool perf-lead, so the controller refuses any other `--label bench` step). It has bun and node under
`~cmux` for the Debug build. The owned M4 Pro minis (cmux7s-13s) can open apps too, but they are busy
CI hosts; `baseline/apple-m4-pro-macos27.json` came from one (cmuxs-Mac-mini 6, load 3 to 8). The aws-m4pro
minis start the app but its control socket never appears (a252), so they cannot run xbench.

Baselines: `baseline/apple-m6-macos27.json` and `baseline/apple-m4-pro-macos27.json` (the gate's rows),
`baseline/BENCH-apple-m6-macos27.md`, `baseline/BENCH-apple-m4-pro-macos27.md`,
`baseline/tab-switch-apple-m6-macos27.json` (the matrix's full report).

A fleet ref must have a published cmux-tui tree for the Debug build. feat-cmux-next moves faster than
the publisher; re-run after a trusted feat-cmux-next publication, then wait until
`files.cmux.com/cmux-tui/tree/<key>/cmux-tui-aarch64-apple-darwin.sha256` answers 200
(`pin-cmux-tui.sh key --rev SHA`).

## Method

Follows Ardia's `docs/perf/vs-browsers.md` so the numbers compare:

- **Pages**: `pages.py`, served from 127.0.0.1. The idle page is native-bench's
  shape (60 boxes, 120 paragraphs, a 1 s timer). Pages beacon their first
  contentful paint, visibility changes (+2 rAF) and video playback to the harness.
  The scroll page scrolls itself 4 px per frame; the video page records a 720p
  clip from a canvas and loops it (no downloaded media, any engine). No network rows.
- **Profiles**: one template per browser (one launch, 45 s settle, quit); every
  launch runs on its own APFS clone. HOME and CFFIXED_USER_HOME point into the run
  folder. cmux runs with `CMUX_NEXT_NO_ACTIVATE=1`, a scratch config with updates off.
- **Driving**: Chromium browsers over CDP's HTTP endpoints (`/json/new`,
  `/json/activate`, `/json/close`) with `--remote-debugging-port --no-first-run
  --no-default-browser-check --password-store=basic --use-mock-keychain
  --mute-audio --window-size=1280,800`; cmux over its control socket
  (`openBrowser.chromium|webkit`, `selectSurfaceByNumber`, `closeTab`); Safari with
  `open` only (its switch and close rows are empty: they need Automation).
  Hidden = `NSRunningApplication.hide()` (`benchhelper.swift`).
- **Counters** (`procs.py`): `proc_pid_rusage(RUSAGE_INFO_V6)` summed over the
  whole instance: the app's descendants, every process running from inside the
  bundle, every process the app is responsible for (WebKit XPC), cmux's terminal
  hosts. mW = Δri_energy_nj / time (CPU energy; GPU and display are not in it, as
  in Ardia's per-process rows). CPU % is one core = 100 %. Wakeups = idle +
  interrupt wakeups. Memory = phys_footprint.
- **Launch**: `benchhelper wait-window` polls CGWindowList every 2 ms for the
  first on-screen layer-0 window ≥ 300×200 with alpha > 0 owned by a process of
  the bundle, from just before `open`.
- **Session order** (per browser per round): launch → 1 tab, settle →
  memory-1 → 60 s idle (1 tab) → 5× new tab → 10 tabs → memory-10 → 20 tabs →
  memory-20 → settle, 60 s idle in view (idle-cpu-20, idle-wakeups-20,
  power-idle-visible) → 30 s switching every 1.5 s (power-switch, tab-switch) →
  scroll tab 30 s → video tab 30 s → hide, 60 s (power-idle-hidden) → close to 1
  tab, 30 s → memory-closed → quit.
- **Machine state**: browsers interleave and rotate each round; each item waits
  (≤ 2 min) for the 1-minute load to fall under 4; `caffeinate -dimsu` holds the
  display awake. The step runs `--class exclusive`, alone on its worker.

## Chrome parity (`suite=parity`)

The CHROME PARITY BENCH (m91): one table of cmux NEXT against the host's own Google Chrome stable for every
interaction a person feels, each light and under load, at 120 Hz. It is a bench, never a CI gate or perf-gate row.

```
cmux-ci run --class exclusive --display --measurement --target-worker cmux22 \
  --script scripts/measure/perf-bench.sh --ref SHA --arg=suite=parity \
  --artifact artifacts/perf-bench/parity.json [--arg=vdisplay=120x1] [--arg=parity_rows=key-field,scroll-page]
```

`python3 scripts/perf-bench/chrome_parity.py rows` lists the rows and the surface each app uses.

- **Input**: real HID events from `scripts/journeys/hid_inject.swift` (keys, clicks, drags, pointer moves and wheel
  bursts, posted at the HID tap at mach deadlines and stamped on CLOCK_UPTIME_RAW). The same tool drives both apps.
- **Frames**: `framewatch.swift` streams the measured rectangle with ScreenCaptureKit (up to 240 frames/s, cursor
  hidden). Each frame gives its displayTime on the same clock and the box of the pixels that changed. The capture
  costs the same in both arms. There is no DevTools tracing and no app socket call in a timed span.
- **Set-up only**: cmux through its control socket, Chrome through the DevTools HTTP endpoints (`/json/new`).
  12 x 12 marker squares (#ff00ff top-left, #00ffff top-right) on the bench pages and in the terminal give the
  rectangles. Positions without a marker (tab strip, sidebar rows) are constants in `GEOMETRY`; override them with
  `--geometry FILE.json`. A hover probe that hits nothing is "not run", never a pass.
- **Display**: the main display must run at 120 Hz (`vdisplay120.m check`, interval within 0.35 ms).
  `vdisplay=120x1` makes the lease's own virtual display first. Else every row is "not run".
- **Load**: cmux = 5 terminals that print a line every 20 ms in another workspace (the agents) + the CPU page
  (2 busy web workers) in a background tab of the measured pane. Chrome = the same CPU page + 5 background tabs
  that stream a line every 20 ms. Light = the measured surface only.
- **Interleave**: per row and load, round 1 runs cmux then Chrome, round 2 Chrome then cmux. Before each arm the
  1-minute load must fall under 2.
- **Latency rows** (keys, Cmd-T, tab switch, hover, launch): input stamp to the displayTime of the first frame that
  shows the response before the next input. Late refreshes per input = max(0, ceil(latency / 8.33 ms) - 2). An input
  with no response frame is lost and counts 10.
- **Pacing rows** (scroll, resize, drag): the intervals between changed frames in each input span; an interval over
  1.5 refreshes misses round(interval / refresh) - 1 refreshes.
- **Verdict** per row: PASS when cmux p95 <= Chrome p95 AND cmux missed <= Chrome missed. Each arm's per-round p95
  range is in `parity.json` (its own spread).

Mappings and known asymmetries:

| Row | cmux | Chrome |
|---|---|---|
| key, text field | a cmux Chromium tab, `<input>` on the bench page | the same page |
| key, native field | command palette field (Cmd-Shift-P) | omnibox (Cmd-L) |
| key, terminal | Ghostty terminal at the shell prompt (PTY echo) | xterm.js 6 page from `cmux-tui/frontends/web`, local echo, **no PTY** |
| scroll | the long page; a terminal with 50k lines of scrollback | the long page; xterm.js with 50k lines |
| Cmd-T | new browser tab: first frame, then 3 keys in a row that show | New Tab page, the same |
| tab switch | Ctrl-Tab in one pane | Ctrl-Tab |
| split resize | divider between a page pane and its split | DevTools dock divider (DevTools docked right) |
| sidebar / tab strip | sidebar workspace rows; pane tab bar | the tab strip for both |
| launch | `open` to first frame and to interactive, restored session | the same with `--restore-last-session` |

The Chrome terminal arm has no PTY round trip, so it is a lower bound for a web terminal. Launch types keys from the
first moment; before the app's window is up they go to the app in front (Finder on a bench host).

### Where the bench process has no privacy right: the app-clock method

`chrome_parity.py` sends real HID events and reads a ScreenCaptureKit stream of the display, so the process that
starts it needs PostEvent and Screen Recording. Where it has neither (an ssh session on a mini: the responsible
process is `tailscaled`), `parity_appclock.py` measures 7 rows with no right:

```
python3 scripts/perf-bench/parity_appclock.py selfcheck --cmux APP --out DIR     # first: must print PASS
python3 scripts/perf-bench/parity_appclock.py run --cmux APP --out DIR --loads light,load --rounds 2
python3 scripts/perf-bench/parity_appclock.py report --out DIR --md table.md
```

- cmux arm: input through the debug socket (`debug.key`, `debug.mouse`, `debug.window_frame`); frames from the
  app's own recorder (`debug.motion record_*`). Chrome arm: `parity_chrome_cdp.py` (DevTools input, Chrome's trace).
- Each sample is the bench's send stamp to the frame's time. The hop from the keyboard through WindowServer to the
  app is in no number, and the two frame clocks are not the same clock: a difference under one refresh is inside the
  method's error. A before/after pair by this method is A/B evidence; it is not a parity proof by the HID method.
- Tab switch: the cmux pane holds the workspace's terminal tab (and the CPU page under load) before the 2 colour
  pages, so the row sends Ctrl-Shift-Tab and Ctrl-Tab in turn: each of the 20 switches is page to page between the 2
  colour pages, as `Target.activateTarget` in the Chrome arm. Ctrl-Tab alone went round 3 or 4 tabs and mixed 3 switch
  classes in one row (page to page, page to terminal, terminal to page).
- Key, text field: the cmux arm first calls CuaDriver `bring_to_front` for the bench app one time. A bench app started
  from ssh gives no key to a Chromium page with no such call (0 of 40 keys typed; 40 of 40 after it). The call runs
  with the account's home, not the bench's. A host with no CuaDriver, or a call that fails, gives `not run` for this
  row. The run's `front_step` field says that the step ran. The bench shell gets no right of its own.
- The report labels each run: method, display (id, size, rate), the refresh interval measured in that run, screen
  locked or not, load. A run on a locked screen, on a sleeping display or with a measured refresh that is not the
  `--hz` one is `invalid` and gives the table no number. No frame from the recorder is `not run`, never a number.
- Not possible by this method (9 rows stay "not run", each with its reason): native field key, Cmd-T to
  interactive, split resize, the 2 hover rows, the 2 drag rows, the 2 launch rows. They need the HID method.
- Blind inputs (cmux latency rows). The recorder's ScreenCaptureKit stream sometimes stops right after a change:
  no callback of any kind until the next change, and no frame for that change. The key is on the display (a film by
  another process shows it in its own frame) but the recorder has no frame of it. An input is `blind` when the
  stream called back after it, inside 4 refreshes, and then gave no callback for more than 50 ms up to the response
  frame or the end of the input's span. A blind input is no sample and is not `lost`; each result and the report's
  run list give the count (`n / lost / blind / inputs`). A window that shows nothing new keeps its idle callbacks, so
  it stays `lost`. More than 10% blind inputs in a run (and more than 2) is `not run`. Limit: a frame that the app
  shows with no change in it, right before the stream stops, reads the same; watch the blind count (measured: 40
  of 1360 keys).
- `chrome_parity.py selfcheck` proves the judge on made-up frames (a frozen arm is FAIL, an input that was not
  delivered is no sample). `parity_appclock.py selfcheck` proves the same on the real app with `debug.stall`, and
  the blind rule on made-up callback lists.

## Load arm `oversub` (`busy_holder.py`)

A developer's Mac can run all day at a load average of about 250 on 18 cores: about 14 runnable CPU-bound threads
per core (agents, node, cargo), all at the default priority. A bench "load" arm with a host load under 15 is a
quiet machine next to that. `busy_holder.py` is the one busy loop of the bench owners: N CPU-bound threads at the
default priority and QoS beside the app under test, for a short time.

```
BH="/usr/bin/python3 scripts/perf-bench/busy_holder.py"
PID=$($BH start --owner <task> --watch-pid $$ --threads 250 --procs 250 --max-seconds 120)   # prints the PID
$BH status $PID      # threads, running, priority, CPU, load
$BH stop $PID        # the summary: threads, processes, cores, threads per core, load at start and end
$BH cooldown --below 8 --max-seconds 300 && $BH status    # inside the same hold; must print `live 0`
$BH probe --label quiet    # the scheduling delay one thread of each QoS class gets (run quiet and under start)
$BH selftest               # the safety rules with 4 threads for at most 10 s each
```

- `--procs 1` is one process with N threads; `--procs N` is N processes. macOS shares the cores between
  processes' thread groups first, so the two are different loads; a real Mac has many processes. Write the shape
  next to each number: threads, processes, cores, threads per core, the 1-minute load at the start and the end.
- It is run-queue pressure only: no disk I/O, no memory pressure, no process churn, no GPU work.
- Safety, enforced by the tool: it ends itself after `--max-seconds` (default 240, hard limit 600); it ends when
  the process that started it is gone; it starts only where `~/perf-lead/tools/GUI-HOST` exists and
  the first word of `~/perf-lead/gui.lock/owner` is `--owner` (a bench host inside the caller's own GUI lock hold; never a
  build host, never a laptop), and it ends when that lock is gone; `stop` signals only a PID it can prove is its
  own; it refuses to start at a changed nice value.
- Priority trap: a process that ssh started has a QoS ceiling of utility (each thread at scheduler priority 20 for
  every QoS class), and a zsh login shell gives a `&` job nice 5. A person's Mac has the app's main thread at 46 or
  47 and a default thread at 31. Start the load, the app and the driver through LaunchServices: `open -W -n -g
  <Runner.app> --args job.sh`, where Runner.app is a background-only bundle whose executable is a copy of
  `/bin/bash`; the app itself with `open -n -W --env ...` so that it has an app role. `start` prints `sched_pri`
  (31 is right, 20 is the ssh ceiling). Write the main-thread priority of each arm (`ps -M`) next to each number.
- The row order is quiet, oversub, oversub, quiet in one hold. A row's driver runs at user-interactive QoS so that
  its own wait for a core is not in the number; the app's clocks are the result.

## Files

- `xbench.py`: run, report (BENCH.md + results.json), gate.
- `budget.py`, `budgets.json`: the resource budget session and its limits.
- `pages.py`, `procs.py`, `benchhelper.swift`, `fetch_browsers.py`.
- `baseline/<chip>-macos<major>.json`: the gate's reference (results.json of a run at a known sha).
- `chrome_parity.py`, `framewatch.swift`: the Chrome parity bench (`suite=parity`).
- `parity_appclock.py`, `parity_chrome_cdp.py`: the same rows by the app-clock method (no privacy right).
- `busy_holder.py`: the load arm `oversub` (N busy threads at the default priority, with hard self-limits).
- `../measure/perf-bench.sh`: the fleet entry.

## The shared `real` session (`session_real.py`)

One bench session of the size of the person who uses the app (read from his session daemon on
2026-11-10): 826 workspaces, 858 panes, 1600 tabs, 798 terminals, 170 agents, 13 clients. Every
bench that has a session-size arm uses this script; the count tests use the same mix rule
(`SessionFixtureSize.real`, the test fixture size of #40488). Fleet minis only.

```sh
S=scripts/perf-bench/session_real.py
# The saved session of one bench app, made by the bundle's own daemon with no app (1 to 3 minutes):
python3 $S build --app "/path/cmux DEV <tag>.app" --to /path/saved/<tag>
# One launch on it: restore time, read-back counts, agents and clients as his, then your steps:
python3 $S launch --app "/path/cmux DEV <tag>.app" --saved /path/saved/<tag> --out /path/out \
  --steps "counts,agents,clients:13,measure:--seconds 30,map"
# Or with your own bench driver: install, launch with BENCH_LAUNCH_KEEP_STATE=1, uninstall.
python3 $S install --saved /path/saved/<tag> --tag <tag>
python3 $S agents --app-socket /tmp/cmux-debug-<tag>.sock      # after every restore
python3 $S clients --app-socket /tmp/cmux-debug-<tag>.sock --total 13 &
python3 $S uninstall --tag <tag>
# Or make it live in a running bench app, through its daemon:
python3 $S make --app-socket /tmp/cmux-debug-<tag>.sock
```

- A saved session is tied to its tag: the registry names its session `cmux-app-<tag>` and the
  daemon refuses another one's. A clone of a bench app that keeps the bundle name uses the same one.
- PTY limit: macOS has `kern.tty.ptmx_max` PTYs for the whole machine (511). The script keeps a
  shell in the 170 agent terminals and in 30 plain ones and parks the other 598 (`park-tabs`: the
  tab stays, its shell starts when its workspace shows). It says so and never makes fewer silently.
- An agent is not a model session: `session_real_agent.zsh` draws like an agent TUI and reports
  through the hook helper (`$CMUX_TUI_HOOK claude <event>`), so the daemon lists 170 agents.
- `build` starts 200 shells in a minute: on a bench host run it only inside your own GUI hold.
- Only a tagged DEV build: each command refuses a daemon whose session is not `cmux-app-<tag>`
  (the release session, a shipped build's (`nightly`, `rc`, `staging`, `cmux-next`), an untagged build's, a person's own session).
- `launch` ends with exit 1 when the model did not load, a step failed or the `clients` step
  ended early; it quits the app and takes the installed session away first.
- `clients --total 13` reads the daemon's client list and holds what is missing. The list moves
  (a hook call is a client for a moment, the app's own connections come and go), so it prints
  the count it reached and `SESSION-REAL-CLIENTS-DIFFER` when that is not the count asked for.
  A held client reads its events at once: the daemon closes a subscriber that does not read.
- The daemon serves 64 connections. A start of 170 agents (about 500 hook calls) fills them for about
  2.5 s; in that time a new connection gets one `server.busy` line. The script's own connections
  try again for 20 s; a bench driver of your own must do the same.
- `map` gives, per action (20 runs): `commit_ms` (the action's start to its committed frame, from
  `debug.action_budget`), the longest frame and the main-thread gap, and the longest stall the
  watchdog recorded with its frames. `--sample-rows <row>` runs a row beside a `sample` of the app:
  those times are then not for a table. For the same map at another size, give `build` and `agents`
  the same counts in proportion, for example 60 workspaces:
  `--workspaces 60 --terminals 58 --agents 12 --tabs 116 --panes 62 --browser-tabs 37`.
