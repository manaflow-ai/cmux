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

## `cmux perf profile [--seconds N] [--out FILE.json] [--label L] [--probe] [--probe-samples N]`

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
| responsiveness | terminal typing, tab, workspace, sidebar, palette (action round trip), p50 and p95 | `action.run`, with `--probe` | yes |
| responsiveness | tab and workspace switch, intent to the frame that shows it, p50 and p95 | `debug.tab_switch`, `debug.workspace_switch` | no |
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

It takes `--probe-samples N` timed samples per action (default 30, at most 500), in rounds spread
over the window: each round gives two per action (there and back; two terminals). A first warmup
round is timed too, kept in the report's `details.interactions` with `"warmup": true`, and left out
of the numbers. 30 samples take 16 rounds of about 1.2 s each; when they need longer than
`--seconds`, the profile runs on until they are done and its notes say how long it took.

Each responsiveness row has a p50 (no budget) beside its p95. A row records the `samples` its
percentile came from; a p95 from fewer than 20 samples is the top sample or next to it, so one
outlier decides it. The table marks it `low-n N` instead of `ok` or `OVER`. (A live run took 6
samples per action; one sidebar toggle of 31.71 ms among 2.35 to 2.84 ms made a false `BROKE`.)

## `cmux perf compare BEFORE.json AFTER.json`

One row per metric: before, after, the change and a verdict. With a budget: `FIXED` (over before,
within after), `BROKE`, `within` or `over`. Without one: `better`, `worse` or `same`; a change under
5% or under 0.01 counts as `same`. A row whose p95 came from fewer than 20 samples on either side
gets `low-n (n BEFORE -> AFTER), no verdict` with its trend, never `FIXED` or `BROKE`, and isn't
counted as over budget. Reports from before the sample counts were recorded are judged as before.
`--json` gives `cmux.perf.compare/1`, with `low_n` and `samples` on each row.

## `cmux perf ab --patch SHA [--rollback] [--seconds N] [--probe] [--probe-samples N] [--out-dir DIR] [--repo DIR] [--parts P] [--unsigned-daemon] [--allow-partial]`

1. Runs `scripts/cmux-next/hot-apply.py plan SHA`. When the plan puts part of SHA in live and
   leaves the rest out (Swift signatures, resources, a web ABI change), it refuses before
   profiling (`perf.ab_partial`, exit 2) and lists each file or reason it leaves out: the after
   profile would credit the whole patch with part of it. `--allow-partial` goes on and A/Bs the
   live part, listing the rest in the notes.
2. Profiles the app as `before.json`. If nothing of SHA can go in live, it stops there: it won't
   compare an unchanged app with itself.
3. Runs `hot-apply.py apply SHA --socket SOCK` (with `--parts` when given), then profiles `after.json`
   and compares.
4. With `--rollback`, runs `hot-apply.py rollback`.

`--unsigned-daemon` is passed to both `plan` and `apply`. A Team-signed NIGHTLY refuses the
ad-hoc-signed published daemon without it. With it the app verifies no connection to the daemon,
so Cloud machines, Cloud starts and every user-origin call fail until rollback; `perf ab` warns
when it starts and, without `--rollback`, says to pass it.

Everything lands in `--out-dir` (default a new `cmux-perf-ab-<time>` in the temp dir) with `ab.json`
listing each step and whether it worked. Over ssh on macOS, hot-apply can't restart sessions
(`--restart-sessions`); the daemon swap and web bundle still go in, and the summary says so.

## `cmux perf sim [--profile cosmic-gray|unreasonable] [--scale N] [--seconds N] [--build-seconds N] [--events N] [--shape FILE]`

It needs `--app-socket` or `--socket` and refuses without one: it never picks an app for you.

It builds first, then runs. `--seconds` (default 60) counts from the end of the build, so a slow
build never shortens or stretches the run. The build has its own hard deadline, `--build-seconds`
(default 180, at most 3600): what isn't made by then isn't made, and the run starts with what
is. Its summary gives `build_ms`, `build_cut_short` and `run_ms` apart.

Before it builds it caps its terminals so the host keeps PTYs for everyone else. On macOS it reads
`sysctl kern.tty.ptmx_max` (511 by default, shared by every terminal on the Mac) and counts the
`/dev/ttysNNN` nodes in use; on Linux it reads `/proc/sys/kernel/pty/max` and `nr`. The cap is
that pool less what is in use (when it can't be read, nothing) less 64 of headroom. Workspaces keep
their panes in order until the cap; the rest aren't made, and churn splits stop at it too. It logs
the pool, the cap and how many terminals the shape asked for; the summary has `terminal_cap` and
`terminals_wanted`. Anywhere else there is no cap.

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

A file is one bare shape, `{"profiles": {name: shape}}`, or a capture of a real session (schema
`cmux-perf-sim-profile/1`, what the mirror exports). Missing fields take defaults.

A capture gives the counts: `workspaces`, `panes_per_workspace` (one entry per workspace),
`busy_terminals`, `streaming_chats` and `browser_pages`. Streaming chats run as fake agent
terminals (no model runs), so the capture's agent chat tabs and `agent_sessions` aren't driven as
chats. The timings, commands, burst and churn come from the built-in profile. A count the profile
sets higher stays.

The built-in `cosmic-gray` is the capture in `perf/captures/cosmic-gray-2026-11-21.json`: 213
workspaces, 217 panes, 40 streaming chats, 16 pages and no busy terminals. `unreasonable` is
that capture times 4 (852 workspaces, 160 fake agents, 64 pages, 32 busy loops), with a
10,000-event burst every 5 s and churn every 120 ms. `--scale N` (1 to 100) multiplies every
count again: workspaces, busy terminals, agents and pages. The burst stays `--events` lines at once.

| Field | Meaning |
| --- | --- |
| `capture`, `scale` | a built-in capture's counts, times `scale` |
| `workspaces`, `panes_per_workspace`, `splits_per_workspace`, `max_panes_per_workspace`, `extra_tabs_per_pane` | layout |
| `busy_terminals`, `busy_sleep_s`, `busy_command` (`{sleep}`) | output loops |
| `agents`, `agent_sleep_s`, `agent_command` (`{name}`, `{sleep}`) | fake agent sessions |
| `browsers` | local page tabs |
| `burst_lines`, `burst_every_s` (0: once), `burst_command` (`{lines}`) | bursts |
| `churn_interval_ms`, `churn` (`tab`, `workspace`, `sidebar`, `split`, `equalize`, `resize`) | churn |

## Tests

`cmux-ci test -- cargo test -p cmux-tui --lib perf` runs the unit tests in `perf/tests.rs`. They
cover percentiles, p50 beside p95, warmup and low-n, host sampling math, the `ioreg` parser,
verdicts (no `FIXED` or `BROKE` at low n), the report round trip, the hang-file parser, argument
parsing, the built-in shapes, the captured session read as captured, scaling, burst splitting, the
sim's build and run timers, the PTY cap and the `ab` refusal of a partial plan.
