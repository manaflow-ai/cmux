# The perf loop: profile, patch, compare, under load

`cmux perf` measures the running app against a 120 Hz frame (8.33 ms), tries a patch in it, and
says what the patch changed. `cmux perf sim` gives it a heavy session to measure without anyone
using the machine. All of it is Rust in `cmux-tui/crates/cmux-tui/src/cli/app/perf/`.

```sh
cmux --app-socket "$SOCK" perf sim --profile cosmic-gray --seconds 600 &   # load, in its own workspaces
cmux --app-socket "$SOCK" perf profile --seconds 20 --probe --out before.json --label base
cmux --app-socket "$SOCK" perf ab --patch SHA --probe --rollback          # profile, hot-apply, profile, compare
cmux perf compare before.json after.json
```

## `cmux perf profile [--seconds N] [--out FILE.json] [--label L] [--probe]`

Samples the app behind the socket for N seconds (default 10, at most 600) and prints a table; with
`--out` it also writes the report (schema `cmux.perf.report/1`), `--json` prints it.

| Group | Rows | Source | In Release |
| --- | --- | --- | --- |
| frames | count, p50/p95/p99, % over 8.33 ms, longest, main-thread time per frame p95 | `debug.frames` (CADisplayLink) | no |
| frames, stalls, layout | chat page frames, long tasks, layout shift (CLS) | `agent.chat.perf` on visible chat pages | yes |
| stalls | main-thread wait p50/p95/p99, stalls over 50 ms, longest | `system.ping` (off main) vs `agent.acpmux` (main actor), every 100 ms | yes |
| stalls | count, total, longest, attributions by kind with frames | `debug.hangs` | no |
| stalls | hangs of 2 s or more with the main thread's frames | `~/Library/Logs/<bundle id>/hangs/hang-*.txt` | yes |
| layout | root layouts, workspace applies, pane snapshots, topology sends | `debug.layout_counters` | no |
| responsiveness | terminal typing, tab, workspace, sidebar, palette (action round trip) | `action.run`, with `--probe` | yes |
| responsiveness | tab and workspace switch, intent to the frame that shows it | `debug.tab_switch`, `debug.workspace_switch` | no |
| responsiveness | composer typing | none yet: always unmeasured | - |
| host | CPU average and peak second, RSS peak, footprint peak, disk read/write, GPU | `proc_pid_rusage` on the app process, `ioreg` | yes |

Every `debug.*` method is registered only in Debug and bench-hook builds (`AppControl.swift`), so a
Release or NIGHTLY app gives no native frame timings. The report says so in its notes and marks
each source with `release` and `available`. GPU busy is host-wide; there's no per-process number
without a tracer. Host numbers cover the app process only: cmux-next never scans processes, so its
web renderers and the terminal daemon aren't counted.

`--probe` drives the interactive elements there and back (next/previous tab, workspace, sidebar
toggle, palette open and close) and types one space into at most two terminals that a running
`cmux perf sim` on the same socket made. It never types into anyone's own terminal; with no sim it
says so and skips typing.

## `cmux perf compare BEFORE.json AFTER.json`

One row per metric: before, after, the change and a verdict. With a budget: `FIXED` (over before,
within after), `BROKE`, `within` or `over`. Without one: `better`, `worse` or `same`; a change under
5% or under 0.01 counts as `same`. `--json` gives `cmux.perf.compare/1`.

## `cmux perf ab --patch SHA [--rollback] [--seconds N] [--probe] [--out-dir DIR] [--repo DIR] [--parts P]`

1. Profiles the app as `before.json`.
2. Runs `scripts/cmux-next/hot-apply.py plan SHA` and prints each part of SHA that needs a build
   (Swift signatures, resources). If nothing can go in live, it stops: it won't compare an
   unchanged app with itself.
3. Runs `hot-apply.py apply SHA --socket SOCK` (with `--parts` when given), then profiles `after.json`
   and compares.
4. With `--rollback`, runs `hot-apply.py rollback`.

Everything lands in `--out-dir` (default a new `cmux-perf-ab-<time>` in the temp dir) with `ab.json`
listing each step and whether it worked. Over ssh on macOS, hot-apply can't restart sessions
(`--restart-sessions`); the daemon swap and web bundle still go in, and the summary says so.

## `cmux perf sim [--profile cosmic-gray|unreasonable] [--seconds N] [--events N] [--shape FILE]`

It needs `--app-socket` or `--socket` and refuses without one: it never picks an app for you.

It drives this load:

- New workspaces of split terminals, with extra tabs.
- Busy output loops.
- Fake agent sessions printing scripted agent-like output. No model runs.
- Browser tabs on an animated page it serves from a loopback port.
- A burst of `--events` lines (default: the shape's, 10,000) spread over all its terminals, again
  every `burst_every_s`.
- Layout churn every `churn_interval_ms`: tab and workspace switches, sidebar toggles, splits up to
  `max_panes_per_workspace`, equalize and pane resizes.

Window resizing isn't driven.

On exit or Ctrl-C it closes the workspaces it made, and only those. It restores the sidebar and
the workspace that was shown, and removes its state file (`cmux-perf-sim-<hash>.json` in the temp
dir), which `profile --probe` reads to find its terminals.

The shape is data. The first of these that exists is used:

1. `--shape FILE`
2. `$CMUX_PERF_SIM_DIR/<profile>.json` (default `~/.local/share/cmux-perf-sim/`), which a mirror
   tool may overwrite from a real session
3. the built-in `perf/profiles.json`

A file is either one bare shape or `{"profiles": {name: shape}}`. Missing fields take defaults.

| Field | Meaning |
| --- | --- |
| `workspaces`, `splits_per_workspace`, `max_panes_per_workspace`, `extra_tabs_per_pane` | layout |
| `busy_terminals`, `busy_sleep_s`, `busy_command` (`{sleep}`) | output loops |
| `agents`, `agent_sleep_s`, `agent_command` (`{name}`, `{sleep}`) | fake agent sessions |
| `browsers` | local page tabs |
| `burst_lines`, `burst_every_s` (0: once), `burst_command` (`{lines}`) | bursts |
| `churn_interval_ms`, `churn` (`tab`, `workspace`, `sidebar`, `split`, `equalize`, `resize`) | churn |

## Tests

`cmux-ci test -- cargo test -p cmux-tui perf` runs the unit tests in `perf/tests.rs`. They cover
percentiles, host sampling math, the `ioreg` parser, verdicts, the report round trip,
the hang-file parser, argument parsing, the built-in shapes and burst splitting.
