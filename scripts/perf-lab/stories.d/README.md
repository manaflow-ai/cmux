# Perf lab stories

One JSON file per story, `stories.d/<id>.json` (rule R7 of
[p12-perf-process.md](../../../plans/cmux-next/chrome-parity/p12-perf-process.md)). Each task that adds a
bench adds its own file, so parallel tasks never edit the same file. `scripts/perf-lab/catalog.py` reads
them. Chrome does the same: every benchmark has owners and a bug component
(`@benchmark.Info`, `third_party/catapult/telemetry/telemetry/benchmark.py`), and `tools/perf/core/shard_maps`
binds each story to a device from its measured time.

```sh
python3 -I scripts/perf-lab/lab.py stories --lint        # or catalog.py stories --lint
python3 -I scripts/perf-lab/lab.py targets --check        # N/12 fixed targets mapped
python3 -I scripts/perf-lab/lab.py targets --uncovered    # MQ8: target rows that no story claims
python3 -I scripts/perf-lab/lab.py hot-paths --uncovered  # MQ9: perf-hot paths whose bench is not a story
python3 -I scripts/perf-lab/lab.py stories --orphans     # MQ12: perf scripts not in a story or ../retired.json
python3 -m unittest scripts/perf-lab/tests/test_catalog.py
```

## Fields

| Field | Meaning |
| --- | --- |
| `id` | Same as the file name. It is also the result-v1 `story`. |
| `tier` | `T0` (every batch, 480 s in total over all T0 stories), `T1` (every 2 h), `T2` (nightly), `linux` (no Mac), `builder` (a builder host). |
| `description` | What the story measures, in one sentence. |
| `command` | argv. The first item is a repository path that must exist. The runner (task 008) adds `--app APP --tag TAG --out DIR`, so the command must take those three flags, and the bench writes its result-v1 into `DIR` (subfolders too) with `BenchApp.record`. The session, config and host block come as `PERF_LAB_SESSION`, `PERF_LAB_CONFIG` and `PERF_LAB_HOST_FILE`, which `BenchApp` reads as its defaults. |
| `session` | `light`, `stress` or `corpus:<id>`. |
| `engine` | `chromium`, `webkit` or `none`. A browser story has one file per engine, or one per arm. |
| `config` | Exactly one of `bench`, `bench-checks` or `release` (R6). Debug is never a lab config. Only the blocking stories (blocking-sites, startup Q5) use `bench-checks`. A `builder` story times a build, not an app, and may say `debug` (`incremental-build`: the Debug edit loop). |
| `metrics` | `{name, unit, better, target_ref?, floor_ref?}`. `name` is a full-match regex over the result-v1 `metric` names that the story writes. |
| `repeats` | Interleaved repeats per run. |
| `seconds` | The measured wall time of one run. The shard map (task 011) bin-packs on this value. |
| `needs` | The capabilities that the measured build must have: `debug:<method>`, `signpost:<name>`, `env:<NAME>` (from `debug.capabilities`, task 211), `file:<path>` (the commit must have the file) or `privilege:<name>` (decision D3). If a build does not have a need, the Change is not-measurable. It is never a regression. |
| `hot_paths` | The ids in `scripts/cmux-next/perf-hot-benches.json` that this story benches. |
| `owner` | An owner from `plans/cmux-next/OWNERS.md`: a `PL-*` lane, the Performance Lead or an agent name. Alerts go to this owner. |
| `component` | `Area>Sub`, in the form of a Chrome bug component. |
| `perf_cron_part` | The `perf-cron.py` part that this story replaces. Each part must have one story. |
| `not_measurable` | Optional. The reason the lab cannot run the story yet, for example a build or a runner argument that does not exist. The lint checks the story as usual, and `lab.py stories` lists the reason. The shard map, the scheduler and the runner skip the story. Remove the field in the change that adds the missing support. |
| `runs` | Optional. The repository paths of the scripts that `command` runs on every run, besides its own paths: the bench that a session script starts, or the story module of a fleet step. `lab.py stories --orphans` (MQ12) counts a script as run by a story only when the command or `runs` names it. A suite branch that the command does not select, an imported module or a name in a help text is not a run. |

## Thresholds are references, never copies (R4)

A story contains no limit and no noise floor. The only numbers in a story are `repeats` and `seconds`.
The lint refuses a number anywhere else in the file, and it also refuses a number that a command gives to
a `--*budget*`, `--*limit*`, `--*threshold*`, `--*floor*` or `--*target*` flag.

- A metric that one of the 12 program targets judges claims the target row:
  `"target_ref": {"target": "<row id>"}`. Its `name` and `unit` must be the same as one of the
  row's checks, and the story must meet the row's `engine`, `session` and `config`.
- Every other limit is a reference to the file that has the number already:
  `{"path": "scripts/cmux-next/perf-budgets.json", "key": "/rows/<pattern>/p95"}` (a JSON pointer).
  For a Python file, the key is `NAME/key`, for example
  `{"path": "scripts/cmux-next/perf-cron.py", "key": "LAUNCH_BUDGETS/sidebar_rows_shown"}`.
  The Python file is read with `ast` and is not run.
- `floor_ref` is the per-row noise floor. The anomaly detector (task 003) uses it as `MIN_ABSOLUTE_CHANGE`.

The lint resolves every reference. A reference to a path or key that does not exist, or to a value that
is not a number, is a lint failure.

## targets.json

`../targets.json` contains the 12 fixed targets of done check 3. The spec line of each target is copied
word for word into its `text`. Each target has one or more rows, and each row has checks: a metric
pattern, a statistic, an operator and the fixed value. Each row of a browser target names its engine, the
target has `chromium` rows and `webkit` rows, and the two engines' rows judge the same checks (F12): `targets
--check` fails otherwise. A browser story such as tab switch or omnibar typing has a WebKit arm next to its
Chromium arm (`tab-switch.json`, `omnibar.json`). A row with `hz: 120` is judged only from series measured
at 120 Hz (task 160). A target is mapped when a story claims every check of every one of its rows.

## Build configs (R6)

Each config is a `scripts/reload.sh --config <name>` build. A tagged app records its config name in
`Info.plist` as `CMUXBuildConfiguration`. `scripts/cmux-next/bench_launch.py` reads it to write
result-v1's `build.config`, and refuses a stated config that disagrees with it. The series key
includes the config, so two configs are never in one series. The app cache of
`scripts/measure/split-spring.sh` keeps each config apart (key `<sha>-<config>`).

| Config | Flags | Use it for |
| --- | --- | --- |
| `bench` | Release optimization + `-DCMUX_BENCH_HOOKS` (no DEBUG) | Latency, frame, launch, idle and memory stories. This is the default for a story. |
| `bench-checks` | `bench` + `-DCMUX_BLOCKING_CHECKS` | Only the blocking stories: the blocking-sites story and the startup queue Q5 (`startup-queue.py blocking`). The detector records each main-thread blocking call for `debug.blocking`. |
| `release` | The shipped stable Release flags | The parity story (bench against Release on `action.commit`). |

- Do not measure latency, frames, launch, idle or memory on `bench-checks`. The blocking detector
  does bookkeeping on each checked call and each `Mutex` lock, so its numbers are not the shipped
  app's numbers. Chrome's perf bots also measure a release build; DCHECKs are a separate config
  (`build/config/dcheck_always_on.gni`).
- Do not read blocking sites from a `bench` app. `debug.blocking` still answers there, but with no
  detector its `sites` list is always empty. Its report has `compiled_in: false`, and
  `startup-queue.py blocking` refuses such a report.
- No lab config is the Nightly-next binary. That build is Release + `-DCMUX_BLOCKING_CHECKS` with no
  bench hooks (`.github/workflows/nightly.yml`, Chromium's DCHECK-enabled Canary model). `release`
  is the stable Release build without the detector, and `bench-checks` adds the bench hooks.
- `scripts/cmux-next/check-no-bench-hooks.sh --expect <app>` passes for `bench` and `bench-checks`
  builds. Without `--expect` it refuses both, so neither can ship.
- The executables of a `bench` build and a `bench-checks` build carry the same bench-hooks marker.
  Read `CMUXBuildConfiguration` to tell them apart.
- `bench` had the detector before task 147. Results measured from then on carry
  `build.measure_version` 2, so a step at that commit reads as a harness change, not a product one.
  The regression detector (`alerts.py judged_points`) does not split a window by version yet: a follow-up.
