"""The numbers and result-v1 series of the split and pane-scale benches (p12-perf-process-062).

Plain data in, plain data out (no app, no socket), so scripts/cmux-next/tests/test_split_pane_bench_results.py checks
the statistics and the names the lab stories match on any host. Percentiles come only from
scripts/perf-lab/perf_stats.py (linear interpolation, the one definition the lab judges with), as Chrome's benchmarks
hand raw samples to one histogram implementation (third_party/catapult/tracing/tracing/value/histogram.py).

| Bench | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| app-split-bench.py | app-split | `app_split.{action_run_wait,snapshot_has_pane}` (ms) | none |
| split-latency-bench.py | split-latency | `split_latency.<step>` (ms), `split_latency.<view count>` (count) | none |
| app-perf.py | app-perf | `app_perf.<n>ws.<gesture>.{frame_interval,main_busy,commit}` (ms), `.drop120` (count) | none |
| bench_pane_scale.py | pane-scale | `pane_scale.<shape>.<n>.<phase>.{op,frame_interval}`, `.create.{rtt,visible}` (ms); `.idle.app_cpu` (percent), `.idle.app_wakeups` (per_s), `.app_footprint` (bytes) | none (grid, nested), chromium (mixed) |

Each bench writes result-v1 only under an explicit --story whose engine is the run's (bench_story.story_problem), only
for an app it launched through BenchApp (an attached app's launch env is unknown), and only from a run that finished:
a failed gesture, a refused split or a stopped run keeps its report and writes no series.
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, RecordError, load_by_path  # noqa: E402
from typing_report import is_sample  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

Series = collections.namedtuple("Series", "metric unit samples")

MIB = 1048576


def samples(values):
    """The numeric values of `values` as floats (None, bools and text left out)."""
    return [float(v) for v in values if is_sample(v)]


def percentile(values, q, digits=None):
    """perf_stats.pct of the numeric values, rounded to `digits` (None: unrounded); None when there is none."""
    value = perf_stats.pct(samples(values), q)
    return value if value is None or digits is None else round(value, digits)


def kept(series):
    return [s for s in series if s.samples]


def record_all(bench_app, story, engine, series, log=print):
    """Writes each series as one cmux-perf-result/v1 file through ``BenchApp.record`` (better is lower for every
    series of these benches); returns {metric: path, or `not recorded: <reason>`}."""
    written = {}
    for entry in kept(series):
        try:
            written[entry.metric] = str(bench_app.record(story, entry.metric, entry.unit, entry.samples,
                                                         better="lower", engine=engine))
        except (RecordError, perf_result.ResultError) as error:
            written[entry.metric] = f"not recorded: {error}"
            log(f"result-v1 {story}/{entry.metric}: {written[entry.metric]}")
    return written


def any_written(written):
    return any(not str(path).startswith("not recorded") for path in (written or {}).values())


# ---------------------------------------------------------------- app-split-bench.py

APP_SPLIT_KEYS = ("action_run_wait_ms", "snapshot_has_pane_ms")


def app_split_failures(rows):
    """Why an app-split run is not a full set: a split the app refused, or a new pane the snapshot never showed."""
    failures = [f"run {r['run']}: action.run splitRight failed ({r.get('error')})" for r in rows if not r["ok"]]
    failures += [f"run {r['run']}: the new pane never showed in snapshot.get" for r in rows
                 if r["ok"] and r.get("snapshot_has_pane_ms") is None]
    return failures


def app_split_series(rows):
    """`app_split.<key>` (ms) per run, from the ok runs."""
    ok = [r for r in rows if r["ok"]]
    return kept([Series(f"app_split.{key[:-3]}", "ms", samples(r.get(key) for r in ok)) for key in APP_SPLIT_KEYS])


# ---------------------------------------------------------------- split-latency-bench.py

def split_latency_series(rows, latency_keys, count_keys):
    """`split_latency.<key>`: each run's ms of a step, and each run's count of a view's cost."""
    return kept([Series(f"split_latency.{key}", "ms", samples(r.get(key) for r in rows)) for key in latency_keys]
                + [Series(f"split_latency.{key}", "count", samples(r.get(key) for r in rows)) for key in count_keys])


# ---------------------------------------------------------------- app-perf.py

def app_perf_series(runs):
    """Per (workspace count, gesture label): the ok gestures' display frame intervals and main-thread busy ms per
    frame (pooled raw frames), their 120 Hz drops (one count per gesture) and the app's own press-to-commit ms (new-top
    and switch only). A gesture that did not do what it names (ok false) adds nothing."""
    groups = collections.OrderedDict()
    for run in runs:
        if run.get("ok"):
            groups.setdefault((run["workspaces"], run["scenario"]), []).append(run)
    series = []
    for (count, label), group in groups.items():
        base = f"app_perf.{count}ws.{label}"
        series += [Series(f"{base}.frame_interval", "ms", samples(v for r in group for v in r["intervals_ms"])),
                   Series(f"{base}.main_busy", "ms", samples(v for r in group for v in r["main_ms"])),
                   Series(f"{base}.drop120", "count", samples(r["drop120"] for r in group)),
                   Series(f"{base}.commit", "ms", samples(r.get("app_commit_ms") for r in group))]
    return kept(series)


# ---------------------------------------------------------------- bench_pane_scale.py

def pane_scale_engine(shape):
    """The mixed shape opens Chromium splits; grid and nested hold terminals only."""
    return "chromium" if shape == "mixed" else "none"


def pane_scale_complete(checkpoint):
    """A checkpoint measured the layout its name says: it was not skipped, every create landed and the focused
    workspace holds `target` panes."""
    build = checkpoint.get("build") or {}
    return ("skipped" not in checkpoint and not build.get("refused")
            and checkpoint.get("panes") == checkpoint.get("target"))


def pane_scale_series(shape, checkpoint, raw):
    """A complete checkpoint's series. `raw` holds its raw samples (bench_pane_scale.Bench keeps them out of the
    report): `create_rtt` and `create_visible` (ms per created pane), and per phase `op` (ms per op) and
    `frame_interval` (ms per displayed frame). The idle window's app CPU, wakeups and the app's footprint are one
    sample each."""
    base = f"pane_scale.{shape}.{checkpoint['target']}"
    series = [Series(f"{base}.create.rtt", "ms", samples(raw.get("create_rtt") or [])),
              Series(f"{base}.create.visible", "ms", samples(raw.get("create_visible") or []))]
    app = ((checkpoint.get("idle") or {}).get("processes") or {}).get("app") or {}
    series += [Series(f"{base}.idle.app_cpu", "percent", samples([app.get("cpu_percent")])),
               Series(f"{base}.idle.app_wakeups", "per_s", samples([app.get("wakeups_per_s")])),
               Series(f"{base}.app_footprint", "bytes",
                      [round(v * MIB) for v in samples([app.get("footprint_mb")])])]
    for phase, phase_raw in (raw.get("phases") or {}).items():
        if phase != "status":  # status is one timed wait while the tickers print: its frames count, it has no op
            series.append(Series(f"{base}.{phase}.op", "ms", samples(phase_raw.get("op") or [])))
        series.append(Series(f"{base}.{phase}.frame_interval", "ms", samples(phase_raw.get("frame_interval") or [])))
    return kept(series)
