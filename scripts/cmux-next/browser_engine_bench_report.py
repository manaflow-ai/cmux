"""The result-v1 series of the browser engine benches (p12-perf-process-058).

Plain data in, plain data out (no app, no socket), so scripts/cmux-next/tests/test_browser_engine_bench_report.py
checks the names the lab stories claim on any host. Percentiles come only from scripts/perf-lab/perf_stats.py.

| Bench | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| bench_hibernation.py | browser-hibernation, browser-hibernation-webkit | `hibernation.<metric>` | the tabs' |
| bench_renderer_sharing.py | renderer-sharing | `renderer_sharing.<metric>` | chromium |
| chromium-host-bench.py | chromium-host | `chromium_host.<session>.<mode>.<metric>` | chromium (both modes) |
| remote-browser-local-live.py --stats | remote-browser-media | `remote_browser.<page>.<metric>` | chromium (the host) |

A per-event series has a `<series>.missed_runs` count next to it (the events that gave no value), so a lost wake or
key shows in the lab instead of leaving the percentiles of the ones that worked (as new_tab_bench_report.py). Each
session is its own result-v1 run (new_tab_bench_report.session_runs): perf-lab ingest stores one session per run.
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, RecordError, load_by_path  # noqa: E402
from new_surfaces_report import is_sample  # noqa: E402
from new_tab_bench_report import session_runs  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

HIBERNATION_STORY = "browser-hibernation"  # the WebKit arm is `<story>-webkit`
RENDERER_SHARING_STORY = "renderer-sharing"
CHROMIUM_HOST_STORY = "chromium-host"
REMOTE_BROWSER_STORY = "remote-browser-media"

# bench_hibernation.py's per-wake times (its wake rows' keys), in its report's order.
WAKE_TIMES = ("mounted_ms", "usable_ms", "restored_ms", "app_mounted_ms", "loaded_ms")

Series = collections.namedtuple("Series", "story metric unit better engine session samples")


def pct(values, q, digits=2):
    """perf_stats.pct over the numeric values (None and other non-numbers left out), rounded to `digits` (an int when
    `digits` is None); None when there is no value."""
    value = perf_stats.pct([v for v in values if is_sample(v)], q)
    return None if value is None else round(value, digits)


def percentiles(values, digits=3):
    """{n, p50, p95, p99, max} of the numeric values (perf_stats.pct), or None when there are none."""
    samples = [v for v in values if is_sample(v)]
    if not samples:
        return None
    return {"n": len(samples), "p50": pct(samples, 0.5, digits), "p95": pct(samples, 0.95, digits),
            "p99": pct(samples, 0.99, digits), "max": round(max(samples), digits)}


def per_event(story, metric, unit, engine, session, values, better="lower"):
    """A per-event value's series (its numeric samples, in order) and its `<metric>.missed_runs` count. No series for
    a value with no sample (result-v1 needs one); the count is there whenever any event was made."""
    values = list(values)
    samples = [v for v in values if is_sample(v)]
    out = [Series(story, metric, unit, better, engine, session, samples)] if samples else []
    if values:
        out.append(Series(story, f"{metric}.missed_runs", "count", "lower", engine, session,
                          [len(values) - len(samples)]))
    return out


def one(story, metric, unit, engine, session, value, better="lower"):
    """A run-level value as a one-sample series; none when the value is missing."""
    return [Series(story, metric, unit, better, engine, session, [value])] if is_sample(value) else []


def hibernation_story(engine, story=HIBERNATION_STORY):
    return story if engine == "chromium" else f"{story}-{engine}"


def hibernation_series(engine, tabs, gone, wakes, frozen=None, session="light", story=HIBERNATION_STORY):
    """bench_hibernation.py, one engine: `gone` the awake phase's rows of the processes that exited when the tabs
    hibernated, `frozen` the frozen phase's rows of the same pids (Chromium), `wakes` the engine's wake rows. Freed
    bytes per tab (higher is better), the hidden and frozen pages' CPU and wakeups, each wake's times and how many
    wakes lost their scroll or form."""
    name = hibernation_story(engine, story)

    def total(rows, key):
        values = [row[key] for row in rows if is_sample(row.get(key))]
        return sum(values) if values else None

    out = []
    if tabs:
        freed = total(gone, "footprint_bytes")
        out += one(name, "hibernation.freed_per_tab", "bytes", engine, session,
                   None if freed is None else freed / tabs, better="higher")
    out += one(name, "hibernation.hidden_cpu", "percent", engine, session, total(gone, "cpu_pct"))
    out += one(name, "hibernation.hidden_wakeups", "per_s", engine, session, total(gone, "wakeups_per_s"))
    if frozen is not None:
        out += one(name, "hibernation.frozen_cpu", "percent", engine, session, total(frozen, "cpu_pct"))
        out += one(name, "hibernation.frozen_wakeups", "per_s", engine, session, total(frozen, "wakeups_per_s"))
    for key in WAKE_TIMES:
        out += per_event(name, f"hibernation.wake.{key[:-len('_ms')]}", "ms", engine, session,
                         [w.get(key) for w in wakes])
    if wakes:
        out += one(name, "hibernation.wake.scroll_lost", "count", engine, session,
                   sum(1 for w in wakes if not w.get("scroll_ok")))
        out += one(name, "hibernation.wake.form_lost", "count", engine, session,
                   sum(1 for w in wakes if not w.get("form_ok")))
    return out


def renderer_sharing_series(new_tab_ms, renderers, tab_renderers, sample, session="light",
                            story=RENDERER_SHARING_STORY):
    """bench_renderer_sharing.py: each new tab's ms (None for one that showed no title), the renderer count, the
    renderers that hold a tab, and the settled sample's renderer and total footprint."""
    rows = [row for row in sample.get("processes") or [] if row.get("kind") == "cef-renderer"]
    return (per_event(story, "renderer_sharing.new_tab", "ms", "chromium", session, new_tab_ms)
            + one(story, "renderer_sharing.renderers", "count", "chromium", session, renderers)
            + one(story, "renderer_sharing.tab_renderers", "count", "chromium", session, tab_renderers)
            + one(story, "renderer_sharing.renderer_footprint", "bytes", "chromium", session,
                  sum(row.get("footprint_bytes") or 0 for row in rows) if rows else None)
            + one(story, "renderer_sharing.total_footprint", "bytes", "chromium", session,
                  sample.get("total_footprint_bytes")))


# chromium-host-bench.py's raw event series: (metric, unit), filled by its drive() per mode. One per sent key or
# click (None for one the page never painted), so each has its `.missed_runs`.
CHROMIUM_HOST_EVENTS = (("key_to_paint", "ms"), ("click_to_paint", "ms"), ("key_to_raf", "ms"),
                        ("click_to_raf", "ms"))
# The pacing run's frame intervals: as many as the page drew, so no interval is ever missing. Its `.missed_runs` is
# the pacing run itself: 1 when a mode that ran gave no interval (the page never animated, or its title was lost).
CHROMIUM_HOST_PACING = "raf_interval"


def chromium_host_series(samples, modes, session="light", story=CHROMIUM_HOST_STORY):
    """chromium-host-bench.py: `samples` {mode: {event metric: [values, None for an event the page never
    painted]}} from drive(), and `modes` its RESULT["modes"] rows (long frames, and the pump share per session: only
    the run's own session is a series, so one story run is one session; --stress's share stays in the report)."""
    out = []
    for mode in sorted(samples):
        for metric, unit in CHROMIUM_HOST_EVENTS:
            if metric in samples[mode]:
                out += per_event(story, f"chromium_host.{session}.{mode}.{metric}", unit, "chromium", session,
                                 samples[mode][metric])
        if CHROMIUM_HOST_PACING in samples[mode]:
            name = f"chromium_host.{session}.{mode}.{CHROMIUM_HOST_PACING}"
            intervals = [v for v in samples[mode][CHROMIUM_HOST_PACING] if is_sample(v)]
            if intervals:
                out.append(Series(story, name, "ms", "lower", "chromium", session, intervals))
            out.append(Series(story, f"{name}.missed_runs", "count", "lower", "chromium", session,
                              [0 if intervals else 1]))
    for mode, row in sorted(modes.items()):
        if not isinstance(row, dict):
            continue
        out += one(story, f"chromium_host.{session}.{mode}.long_frames", "count", "chromium", session,
                   row.get("long_frames"))
        shares = (row.get("pump_share") or {}).get(session) or {}
        for phase in ("idle", "scroll"):
            out += one(story, f"chromium_host.{session}.{mode}.pump_share.{phase}", "ratio", "chromium", session,
                       (shares.get(phase) or {}).get("share"))
    return out


def remote_browser_series(numbers, input_to_frame_ms, clicks, session="light", story=REMOTE_BROWSER_STORY):
    """remote-browser-local-live.py --stats: the animated page's frame rate (higher is better), the still page's
    frames and bytes, and each click's input to frame sent (`clicks` sent; the missed ones are those the host
    answered with no frame)."""
    motion, still = numbers.get("motion") or {}, numbers.get("still") or {}
    out = (one(story, "remote_browser.motion.fps", "fps", "chromium", session, motion.get("fps"), better="higher")
           + one(story, "remote_browser.still.frames", "count", "chromium", session, still.get("frames"))
           + one(story, "remote_browser.still.bytes", "bytes", "chromium", session, still.get("bytes")))
    measured = [v for v in input_to_frame_ms if is_sample(v)][:clicks]
    return out + per_event(story, "remote_browser.tap.input_to_frame", "ms", "chromium", session,
                           measured + [None] * max(0, clicks - len(measured)))


def record_all(launcher, series):
    """Writes each series as one cmux-perf-result/v1 file through ``BenchApp.record``, each session as its own run
    (session_runs); returns {`story/metric`: path, or `not recorded: <reason>`}. A series the bench cannot describe
    truthfully (no build sha, no features snapshot) is not written, and its reason is printed. The launcher keeps its
    own session and run afterwards."""
    own = launcher.perf_session if launcher.run is not None else None
    runs = session_runs(series, launcher.run, own)
    base = (own, launcher.run) if own is not None else next(iter(runs.items()), (None, None))
    written = {}
    try:
        for entry in series:
            launcher.perf_session, launcher.run = entry.session, runs[entry.session]
            key = f"{entry.story}/{entry.metric}"
            try:
                written[key] = str(launcher.record(entry.story, entry.metric, entry.unit, entry.samples,
                                                   better=entry.better, engine=entry.engine))
            except (RecordError, perf_result.ResultError) as error:
                written[key] = f"not recorded: {error}"
                print(f"result-v1 {key}: {written[key]}", flush=True)
    finally:
        if base[1] is not None:
            launcher.perf_session, launcher.run = base
    return written


def out_paths(out, report_name):
    """(report file, result-v1 folder) of a bench's --out: a path ending in .json is the report file alone (as
    before the migration); any other path is the lab runner's folder, which gets the result-v1 files and the report
    as `<folder>/<report_name>`."""
    if not out:
        return None, None
    if out.endswith(".json"):
        return out, None
    os.makedirs(out, exist_ok=True)
    return os.path.join(out, report_name), out
