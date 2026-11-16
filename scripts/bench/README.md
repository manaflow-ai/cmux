# cmux-bench: one entry point for every measurement

Every cmux measurement runs through `scripts/bench/cmux-bench`, writes rows in one schema, and
records them in one ledger, so "before and after" and "against last NIGHTLY" are a query.

```sh
scripts/bench/cmux-bench list                                   # every bench: what, units, hosts, owner
scripts/bench/cmux-bench launch                                 # newest NIGHTLY, on a fleet Mac
scripts/bench/cmux-bench launch --build 3a731ce7c22... --json   # a commit
scripts/bench/cmux-bench footprint --host local-readonly        # read-only probes of a running app
scripts/bench/cmux-bench bundle --host anywhere --compare-zip https://example.com/Other.zip
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
