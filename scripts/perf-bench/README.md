# xbench: cmux NEXT against every other browser

One reproducible benchmark for the rows of Ardia's 2026-10-19 comparison
(msg 2654): power idle hidden / in view / scrolling / video / switching tabs,
cold launch to window, new tab first paint, idle wakeups and CPU at 20 tabs,
memory at 1, 10 and 20 tabs. It measures cmux NEXT (a Chromium tab, a WebKit
tab, terminals only) and Chrome, Helium, Ardia, Dia and Safari on the same Mac,
the same way. The goal: every cmux cell at a tenth of the best other browser.

## Run it (fleet mini only, never a laptop)

```sh
cmux-ci run --class exclusive --measurement --label measure \
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
cmux-ci run --class exclusive --measurement --label bench --target-worker cmux20-bench \
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
`--label bench --target-worker cmux20-bench`; the nightly job does. It has bun and node under
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

## Files

- `xbench.py`: run, report (BENCH.md + results.json), gate.
- `budget.py`, `budgets.json`: the resource budget session and its limits.
- `pages.py`, `procs.py`, `benchhelper.swift`, `fetch_browsers.py`.
- `baseline/<chip>-macos<major>.json`: the gate's reference (results.json of a run at a known sha).
- `../measure/perf-bench.sh`: the fleet entry.
