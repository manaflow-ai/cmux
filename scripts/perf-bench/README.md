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

Quick iteration for one area (about 10 minutes):
`--arg=rounds=1 --arg=launches=1 --arg=idle=20 --arg=active=15 --arg=browsers=cmux-chromium,helium`.

Local, against bundles you have: `python3 scripts/perf-bench/xbench.py run --out /tmp/xb
--app cmux=/path/cmux.app --app chrome=/path/Chrome.app --browsers cmux-chromium,chrome`,
then `xbench.py report --out /tmp/xb --md BENCH.md --json results.json`.

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
- `pages.py`, `procs.py`, `benchhelper.swift`, `fetch_browsers.py`.
- `baseline/<chip>-macos<major>.json`: the gate's reference (results.json of a run at a known sha).
- `../measure/perf-bench.sh`: the fleet entry.
