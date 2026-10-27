"""Percentiles, result-v1 series and the app handle of the sidebar row benches (p12-perf-process-054).

Plain data in, plain data out, so scripts/cmux-next/tests/test_sidebar_bench_report.py checks the statistics, the
series names the lab stories match and the report keys on any host. Every percentile comes from
scripts/perf-lab/perf_stats.py (linear interpolation, Chromium's perf dashboard and catapult definition).

| Bench | Story (scripts/perf-lab/stories.d) | Series | Config |
| --- | --- | --- | --- |
| sidebar-rows-perf-live.py | sidebar-rows-live | `sidebar_rows_live.<count>.<phase>.<metric>` | bench |
| sidebar-rows-perf-release.py | sidebar-scroll-release | `sidebar_scroll_release.<count>.<mode>.<metric>` | release |
| sidebar-mirror-rebuild-perf.py | sidebar-mirror-rebuild | `sidebar_mirror_rebuild.<count>.<metric>` | bench |
| sidebar-stress-bench.py | sidebar-stress | `sidebar_stress.<size>.<scenario>.<metric>` | bench |

The benches make their own 1,000 (or --sizes) workspaces, so every series is session `stress`; the count is part
of the name, as the perf-budgets rows (`sidebar.400.scroll.frame`). Only a run of an app the bench launched through
BenchApp is recorded: an app it attaches to (`--tag`) has an unknown launch env, so that run writes its report JSON
only. Scroll hitches are a hitch time ratio per recording (percent of the gesture time spent in hitches; Chromium's
PercentDroppedFrames4 in cc/metrics/dropped_frame_counter.h, Apple's Animation Hitches hitch time ratio), so a
recording with no hitch counts as 0.
"""
import collections
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, RecordError, load_by_path  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

LIVE_STORY = "sidebar-rows-live"
RELEASE_STORY = "sidebar-scroll-release"
MIRROR_STORY = "sidebar-mirror-rebuild"
STRESS_STORY = "sidebar-stress"
SESSION = "stress"

Series = collections.namedtuple("Series", "story metric unit samples")


def numbers(values):
    """The numeric values (bool is not a number here)."""
    return [v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool)]


def pct(values, p, digits=2):
    """perf_stats.pct at percent `p` (0-100), rounded to `digits`; None when no value is a number."""
    value = perf_stats.pct(numbers(values), p / 100)
    return None if value is None else round(value, digits)


def latency_stats(values, frame_ms):
    """sidebar-rows-perf-live.py's reply-delay block: {samples, p50_ms, p95_ms, p99_ms, max_ms, over_frame}."""
    values = numbers(values)
    return {"samples": len(values), "p50_ms": pct(values, 50), "p95_ms": pct(values, 95), "p99_ms": pct(values, 99),
            "max_ms": round(max(values), 2) if values else None,
            "over_frame": sum(1 for v in values if v > frame_ms)}


def update_stats(updates):
    """The app-update percentiles of an Animation Hitches recording (hitches-updates durations, ms)."""
    return {"update_p50_ms": pct(updates, 50), "update_p90_ms": pct(updates, 90), "update_p95_ms": pct(updates, 95),
            "update_p99_ms": pct(updates, 99)}


def percentiles(values, digits=3):
    """sidebar-stress-bench.py's block: {n, p50, p95, p99, max, mean}; {} when no value is a number."""
    values = numbers(values)
    if not values:
        return {}
    stats = perf_stats.summary(values)
    return {"n": stats["n"], **{key: round(stats[key], digits) for key in ("p50", "p95", "p99", "max")},
            "mean": round(sum(values) / len(values), digits)}


def median(values):
    """perf_stats p50 (equal to statistics.median); None when no value is a number."""
    return perf_stats.pct(numbers(values), 0.5)


def hitch_ratio(total_ms, gesture_s):
    """The percent of a gesture's time spent in hitches; None when either is unknown or the gesture took no time."""
    if len(numbers([total_ms, gesture_s])) < 2 or gesture_s <= 0:
        return None
    return 100 * total_ms / (gesture_s * 1000)


def series(story, metric, unit, samples):
    """[Series] for the numeric samples, or [] when there is none (result-v1 needs one sample)."""
    samples = numbers(samples)
    return [Series(story, metric, unit, samples)] if samples else []


# ---------- per bench ----------

def live_series(count, ticks, scrolls):
    """sidebar-rows-perf-live.py: `ticks` is the tick phase's raw samples {reply_ms: [...], cpu_us_per_tick,
    main_us_per_tick}; `scrolls` maps a mode (no_ticks, ticking) to {event_rpc_ms: [...], hitch_total_ms: [...] and
    hitch_ratio: [...] (``hitch_ratio``, percent) of the valid recordings}."""
    name = f"sidebar_rows_live.{count}"
    out = series(LIVE_STORY, f"{name}.ticks.reply_delay", "ms", ticks.get("reply_ms") or [])
    out += series(LIVE_STORY, f"{name}.ticks.app_cpu_per_tick", "us", [ticks.get("cpu_us_per_tick")])
    out += series(LIVE_STORY, f"{name}.ticks.main_per_tick", "us", [ticks.get("main_us_per_tick")])
    for mode, raw in scrolls.items():
        out += series(LIVE_STORY, f"{name}.scroll_{mode}.event_rpc", "ms", raw.get("event_rpc_ms") or [])
        out += series(LIVE_STORY, f"{name}.scroll_{mode}.hitch_total", "ms", raw.get("hitch_total_ms") or [])
        out += series(LIVE_STORY, f"{name}.scroll_{mode}.hitch_ratio", "percent", raw.get("hitch_ratio") or [])
    return out


def release_series(count, modes, tick_window=None):
    """sidebar-rows-perf-release.py, one app (its BenchApp names the build, so A and B of an A/B job share the
    names): `modes` maps a mode (noticks, ticks) to its valid runs (each with total_ms and the raw `updates_ms` of the
    recording); `tick_window` holds app_cpu_us_per_tick of the tick window without input."""
    name = f"sidebar_scroll_release.{count}"
    out = []
    for mode, runs in modes.items():
        out += series(RELEASE_STORY, f"{name}.{mode}.hitch_total", "ms", [r.get("total_ms") for r in runs])
        out += series(RELEASE_STORY, f"{name}.{mode}.app_update", "ms",
                      [u for r in runs for u in r.get("updates_ms") or []])
    out += series(RELEASE_STORY, f"{name}.ticks.app_cpu_per_tick", "us",
                  [(tick_window or {}).get("app_cpu_us_per_tick")])
    return out


def mirror_series(count, cycles):
    """sidebar-mirror-rebuild-perf.py: per create-and-close cycle, the main-thread ms of the mirror reads and of the
    list layout ({mirror_ms, main_ms})."""
    name = f"sidebar_mirror_rebuild.{count}"
    return (series(MIRROR_STORY, f"{name}.mirror_per_cycle", "ms", [c.get("mirror_ms") for c in cycles])
            + series(MIRROR_STORY, f"{name}.main_per_cycle", "ms", [c.get("main_ms") for c in cycles]))


def stress_series(samples):
    """sidebar-stress-bench.py: {(size, metric): [raw samples]} -> series `sidebar_stress.<size>.<metric>` (ms, or
    percent for a `hitch_ratio`)."""
    out = []
    for (size, metric), values in sorted(samples.items(), key=lambda kv: (int(kv[0][0]), kv[0][1])):
        unit = "percent" if metric.endswith(".hitch_ratio") else "ms"
        out += series(STRESS_STORY, f"sidebar_stress.{size}.{metric}", unit, values)
    return out


# ---------- writing ----------

def record_all(bench, entries, engine="none"):
    """Writes each series as one cmux-perf-result/v1 file through ``BenchApp.record`` (session `stress`); returns
    {`story/metric`: path, or `not recorded: <reason>`}. A series the bench cannot describe truthfully (no build sha,
    no features snapshot) is not written, and its reason is printed."""
    written = {}
    if bench is None:
        return written
    bench.perf_session = SESSION
    for entry in entries:
        key = f"{entry.story}/{entry.metric}"
        try:
            written[key] = str(bench.record(entry.story, entry.metric, entry.unit, entry.samples, better="lower",
                                            engine=engine))
        except (RecordError, perf_result.ResultError) as error:
            written[key] = f"not recorded: {error}"
            print(f"result-v1 {key}: {written[key]}", flush=True)
    return written


def bundle_of(command, tag):
    """The `cmux DEV <tag>.app` bundle path in a process command line, else None."""
    marker = f"cmux DEV {tag}.app/"
    head, found, _ = command.partition(marker)
    if not found:
        return None
    return head.lstrip() + marker.rstrip("/")


def running_bundle(tag, ps_output=None):
    """(pid, bundle path) of the running main app of `tag` (not a helper), or (None, None)."""
    if ps_output is None:
        ps_output = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in ps_output.splitlines():
        pid, _, command = line.strip().partition(" ")
        app = bundle_of(command, tag)
        if app and pid.isdigit() and command.lstrip().startswith(app + "/Contents/MacOS/") and "Helper" not in command:
            return int(pid), app
    return None, None

