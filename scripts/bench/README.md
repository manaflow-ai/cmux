# cmux-bench: one entry point for every measurement

Every cmux measurement runs through `scripts/bench/cmux-bench`, writes rows in one schema, and
records them in one ledger, so "before and after" and "against last NIGHTLY" are a query.

```sh
scripts/bench/cmux-bench list                                   # every bench: what, units, hosts, owner
scripts/bench/cmux-bench launch                                 # newest NIGHTLY, on a fleet Mac
scripts/bench/cmux-bench launch --build 3a731ce7c22... --json   # a commit
scripts/bench/cmux-bench footprint --host local-readonly        # read-only probes of a running app
scripts/bench/cmux-bench bundle --host anywhere --compare-zip https://example.com/Other.zip
scripts/bench/cmux-bench bundle --host anywhere --arg unpack=1     # newest NIGHTLY unpacked on Linux, by kind too
scripts/bench/cmux-bench compare launch@nightly~1 launch@nightly
scripts/bench/cmux-bench compare <run id> <run id> --markdown   # paste into a PR
```

**The rule.** A measurement lands as a registered bench in `benches/`, or extends one; never as a
one-off script. Perf PRs cite `cmux-bench compare` output (`--markdown`).

## Options

- `--build nightly` (default: the newest NIGHTLY in the live feed), `DEV`, a commit sha, `release:VERSION`,
  or `local`.
- `--host fleet` runs the bench's harness on a fleet Mac through `cmux-ci run --class exclusive --measurement`,
  alone on its worker. `--host local-readonly` only reads processes and files already on this machine; it
  never builds, launches, quits or attaches to anything, so it is the only mode allowed on a person's Mac.
  `--host anywhere` needs no app (bundle listings of a URL).
- `--arg KEY=VALUE` (repeatable), or a bench's own flag (`--compare-zip URL` is `--arg compare_zip=URL`).
- `--import PATH` records a harness output you already have (a log or an artifact) as a run.
- `--json` prints the rows; `--no-ledger` records nothing; `--dry-run` prints the fleet command.

## The row schema (`cmux-bench/v1`)

One row per metric per run (`benchlib/schema.py`):

| field | meaning |
|---|---|
| `run_id`, `bench`, `metric` | one id per run; the registered bench; a stable metric name |
| `value`, `unit`, `better` | the number compare reads (the median when there are samples); `lower`, `higher` or `none` |
| `p50`, `p95`, `n` | when the metric has samples |
| `labels` | extra dimensions: `arm`, `target`, `component`, `kind` |
| `build` | `channel` (nightly, DEV, sha, release, local), `version`, `sha` |
| `host` | `name`, `role` (fleet, local-readonly, anywhere), `os`, `chip` |
| `harness` | the script it wraps and `bench@version+<script blob>` |
| `timestamp` | UTC |

A metric is (bench, metric, labels). Compare matches rows on that key.

## The ledger

The `bench-ledger` branch of manaflow-ai/cmuxterm-hq holds one JSONL file per run
(`runs/YYYY/MM/<run id>.jsonl`). Runs append through git, not the GitHub API, so they spend no API
quota, and unique file names mean two writers never conflict. The local copy is
`~/.cache/cmux-bench/ledger`; a run that could not push is kept there and goes out with the next
one (`cmux-bench ledger push`). `CMUX_BENCH_LEDGER=DIR` uses a plain directory instead (tests).

## Compare

Selectors: a run id (or a unique prefix), `BENCH@latest`, `BENCH@latest~N`, `BENCH@nightly`
(newest run on the newest measured NIGHTLY), `BENCH@nightly~N`, `BENCH@sha:PREFIX`,
`BENCH@version:V`. A delta is a regression when the metric got worse by more than its threshold
(10 % unless the bench sets `thresholds`) and by more than the unit's noise floor (5 ms, 15 MB, 2 fps...,
or the bench's `floors`). Compare warns when the two runs used different harness versions or chips.
`--fail-on-regression` exits 1 on a regression.

## Nightly

`cmux-bench nightly` runs every bench marked `nightly` (a `*` in `list`) against the newest NIGHTLY,
compares each with the NIGHTLY before it, and opens one issue in cmuxterm-hq listing the regressions
with both numbers. It skips an issue with the same title that is still open.

## Adding a bench

1. Write `benches/<name>.py` with a `Bench` subclass and `BENCH = ...` (see `benches/bundle.py`).
   Set `name`, `summary` (one line), `units`, `owner`, `hosts`, `harness`, `version`.
2. `run(ctx)` calls the harness (`ctx.fleet_step(script, args, artifact)` for a fleet Mac) and passes
   its output to `ingest(ctx, path)`, which adds rows with `ctx.row(metric, value, unit, samples=..., labels=...)`.
   Wrap the existing harness; keep its own output format.
3. Add a parse test with a real output in `tests/fixtures/<name>/` (`tests/test_<name>.py`).
4. Bump `version` when what a metric means changes, so compare never mixes the two.
5. Add the bench to `scripts/measure/README.md`.

Tests: `python3 -m unittest discover -s scripts/bench/tests -p 'test_*.py'` (pure Python, no app).

## Composer typing under load

The canonical browser diagnostic is `webviews/bench/composer-typing.bench.ts`, registered as the
`typing` bench (`benches/typing.py`), which runs it through `cmux-ci test --setup playwright` and
records one row set per engine and load in the ledger:

```sh
scripts/bench/cmux-bench typing --build SHA [--arg modes=L0,L1] [--arg engines=chromium] [--arg keys=500] [--arg gap_ms=20]
scripts/bench/cmux-bench typing --import composer-typing.log   # a saved run's log
```

The same command by hand:

```sh
cmux-ci test --setup playwright --timeout 2400 -- bash -lc 'cd webviews && bun install --frozen-lockfile && bun bench/composer-typing.bench.ts --mode L0,L1,L2,L3 --engines chromium,webkit --lengths 60 --keys 500 --gap 20'
```

The perf cron's `web-ui-typing` part (`scripts/cmux-next/perf-cron.py`) runs it through
`webviews/bench/web-ui-suite.ts` (`--only composer-typing`): rows `webui.composer_typing.<load>.<engine>.rows60`
`.invalid`, `.to_paint` (p95, target 16 ms) and `.to_paint_p99` (target 33 ms), from
`webviews/bench/composerTypingRows.ts`. Those targets are report-only: the cron lists rows over them and files its
regression issue; nothing gates a push or a pull request.

`--modes idle,stream` retains its Chromium render-cost comparison. `--mode L0,L1,L2,L3`
adds idle, focused reply/tool stream (60 chunks and 2,000 tool lines per second), ten
other streaming documents (five visible, five hidden), and a focused 100k-row stream.
`--stream` and `--tool-lines` change the focused load. Every load ends explicitly or
at its 120-second safety deadline. L2 is an iframe approximation, not native tab or
process placement; L4/L5 and daemon wakeups require the native Mac harness.

`COMPOSER-TYPING` rows include exact ordered key/text integrity, load continuity/rates,
p50/p95/p99/max, frame bursts, frame intervals over 16 ms, and raw samples. Invalid
load/cadence receipts never meet the target. Budgets are report-only (16 ms p95 and
33 ms p99, at least 200 keys); the browser clock starts at DOM keydown, so these
rows cannot certify native admission or physical presentation. Long Tasks observes
only tasks of at least 50 ms: zero means none observed above that threshold, and
unsupported engines (including WebKit) report null, never a fabricated zero.
`valid` establishes experiment integrity, not a latency pass. Short diagnostic runs remain
valid but are not `acceptance_eligible`; acceptance requires `target_met` (valid load,
at least 200 keys, and both latency limits). Consumers must never interpret `valid` alone
as a budget pass.
Tool output updates carry the accumulated output at each reply tick, matching the mock
tool-update format. This deliberately stresses growing frontend payloads; it does not
model native provider transport. Cross-document epoch receipts require wall-clock
agreement within 2 ms or invalidate the run.

## Native typing under load

`typing-native` (`benches/typing_native.py`) is the native Mac counterpart: it runs
`scripts/cmux-next/typing-frame-bench.py` in the real app through `scripts/measure/split-spring.sh
--suite=typing-frame` on a fleet Mac and ingests `artifacts/split-spring/report.json`. It covers the
shared L0-L5 load modes (`webviews/bench/load-modes.json`, L4 = every core saturated) and records
key-to-frame and dispatch-to-after-frame p50/p95/p99/max only for runs the harness proved complete:

```sh
scripts/bench/cmux-bench typing-native --build SHA [--arg modes=L0,L4] [--arg surfaces=agentpane] [--arg samples=200]
scripts/bench/cmux-bench typing-native --import report.json   # a saved typing-frame report
```

## The app under extreme stress

`stress` (`benches/stress.py`) runs the app under extreme stress from several angles. Leo, 2026-11-21: "i think
being able to test our app under extreme stress from various angles would be a good bench to be able to run
through". The harness is `scripts/cmux-next/stress-bench.py`, run by `scripts/measure/split-spring.sh --suite=stress`
(the allowlisted fleet entry: it builds the app at `--build SHA` and runs the suite on a 120 Hz virtual display).
Each angle is one fresh app launch: a baseline window on the quiet app, then the stressor, then the same window
again. Pick angles with `--arg angles=...`:

| angle | stressor |
|---|---|
| `cpu` | `stress_load.py cpu`: processes x threads hashing beside the app (default cores x 8 runnable threads) |
| `chats` | 12 mock agent chats (no model calls), 2 seeded with 100k-row transcripts and 10 with 20k, all streaming |
| `scale` | 40 workspaces of 4 terminals each, 16 of them printing as fast as the terminal takes it |
| `cli` | `scripts/stress-cli-socket-api.py` against the app's own CLI and socket, plus 16 socket client threads |
| `memory` | `stress_load.py memory`: 1.1 x RAM of incompressible dirty pages, until the machine swaps |

Every window gives rows labelled `{angle, arm}` (`arm` = `baseline` or `stress`): `frame_p50`, `frame_p95` (ms,
`debug.frames`), `dropped_frames` (%), `input_latency_p50`/`_p95` (ms, `debug.key` round trips into a focused
terminal), `daemon_rtt_p50`/`_p95` (ms, the window's share of `debug.daemon_requests`), `app_cpu` (%),
`footprint` (MB), `hangs` (main-thread stalls over `--arg hang_ms`, default 100), and the conditions
`load_avg_1m` and `swap_used` (`better: none`), so a compare shows the stress was really applied.

```sh
scripts/bench/cmux-bench stress --host fleet --build SHA [--arg angles=cpu,chats] [--arg window=20]
scripts/bench/cmux-bench compare stress@sha:BASE stress@sha:HEAD      # before/after a change
scripts/bench/cmux-bench stress --import report.json                  # a saved artifacts/split-spring/report.json
```

Knobs (`--arg`): `window`, `key_interval`, `hang_ms`, `cpu_procs`, `cpu_threads`, `chats`, `transcript_rows`,
`long_chats`, `long_rows`, `workspaces`, `panes`, `flood_terminals`, `cli_clients`, `cli_burst_workers`,
`memory_fraction`, `memory_cap_mb`, `vdisplay` (default 120; 0 for the real display), `labels`, `timeout`.

### Scheduling a bench onto the bench worker

Leo, 2026-11-21: "maybe een like... labels/scheduling and selecting for jobs which are specifying that they are
trying to bench stuff and thereby having specific speed related jobs pick them to see the before/after". The
existing fleet routing already does this; `stress` uses it, and any bench can:

- `--label bench` (`fleet_step`'s default `labels`): only workers advertising `bench` take the step. Today that is
  the dedicated bench Mac (cmux20-bench: 12 cores, 16 GB). It advertises `bench`, `measure` and `gui-session-v1`
  but no `ci-steps` and no builder label, so it takes no CI step and no app build of another job: a bench there
  runs on a quiet machine.
- `--class exclusive`: the step runs alone on an idle worker; nothing else is scheduled beside it.
- `--measurement`: marks the step a measurement; the controller queues measurements by priority, then age, apart
  from CI work.
- `--display` (`display=True`): the step needs the worker's console GUI session; the controller adds the
  `measure` and `gui-session-v1` labels, so the step asks for `[bench gui-session-v1 measure]`.

`.github/workflows/cmux-next-web-perf.yml` (workflow_dispatch: `suite=stress`, `base`, `head`, `angles`) runs `stress` at both
shas this way and posts the before/after table to the run summary. The head side runs `--target-worker W
--pin-strict` on the worker W the base side ran on, so the two numbers always come from one machine, even once a
second Mac advertises `bench`; the run's artifact lists both workers in `workers.txt`.

