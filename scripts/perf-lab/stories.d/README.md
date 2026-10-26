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
python3 -m unittest scripts/perf-lab/tests/test_catalog.py
```

## Fields

| Field | Meaning |
| --- | --- |
| `id` | Same as the file name. It is also the result-v1 `story`. |
| `tier` | `T0` (every batch, 480 s in total over all T0 stories), `T1` (every 2 h), `T2` (nightly), `linux` (no Mac), `builder` (a builder host). |
| `description` | What the story measures, in one sentence. |
| `command` | argv. The first item is a repository path that must exist. The runner (task 008) adds `--app`, `--tag`, `--out` and the session. |
| `session` | `light`, `stress` or `corpus:<id>`. |
| `engine` | `chromium`, `webkit` or `none`. A browser story has one file per engine, or one per arm. |
| `config` | Exactly one of `bench`, `bench-checks` or `release` (R6). Debug is never a lab config. Only the blocking-sites story uses `bench-checks`. |
| `metrics` | `{name, unit, better, target_ref?, floor_ref?}`. `name` is a full-match regex over the result-v1 `metric` names that the story writes. |
| `repeats` | Interleaved repeats per run. |
| `seconds` | The measured wall time of one run. The shard map (task 011) bin-packs on this value. |
| `needs` | The capabilities that the measured build must have: `debug:<method>`, `signpost:<name>`, `env:<NAME>` (from `debug.capabilities`, task 211), `file:<path>` (the commit must have the file) or `privilege:<name>` (decision D3). If a build does not have a need, the Change is not-measurable. It is never a regression. |
| `hot_paths` | The ids in `scripts/cmux-next/perf-hot-benches.json` that this story benches. |
| `owner` | An owner from `plans/cmux-next/OWNERS.md`: a `PL-*` lane, the Performance Lead or an agent name. Alerts go to this owner. |
| `component` | `Area>Sub`, in the form of a Chrome bug component. |
| `perf_cron_part` | The `perf-cron.py` part that this story replaces. Each part must have one story. |

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
pattern, a statistic, an operator and the fixed value. Each browser target has a `chromium` row and a
`webkit` row (F12). A row with `hz: 120` is judged only from series measured at 120 Hz (task 160). A
target is mapped when a story claims every check of every one of its rows.
