"""Percentiles, result-v1 series and the app lookup of the resize benches (p12-perf-process-059).

Plain data in, plain data out (no app, no socket), so scripts/cmux-next/tests/test_resize_bench_report.py checks the
statistics, the report keys and the series names the lab stories claim on any host. Every percentile comes from
scripts/perf-lab/perf_stats.py (linear interpolation, catapult's and the Chromium perf dashboard's definition).

| Bench | Story (scripts/perf-lab/stories.d) | Series | Engine, session |
| --- | --- | --- | --- |
| resize-frames-live.py | window-live-resize | `window_resize.<metric>` | webkit (the New Tab page), light |
| bench-terminal-resize.py | terminal-resize, terminal-resize-stress | `terminal_resize.<layout>.<metric>`, `terminal_split_resize.<session>.<metric>` | none, the layouts' session |
| column-resize-live.py | column-resize-live | `column_resize.<metric>` | webkit (two New Tab pages), light |
| devtools-resize-live.py | devtools-resize-live | `devtools_resize.<mode>.<metric>` | chromium, light |

A bench writes result-v1 only under an explicit `--story` (``story_problem``: the story's engine and session are the
run's), so a split-spring or manual run keeps writing its report only. Each run also records its failures as a count
(a run that measured nothing reads as a regression, never as a missing point), as the sidebar drag benches do.
"""
import collections
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, account_home, load_by_path  # noqa: E402
from bench_story import STORIES  # noqa: E402
from bench_story import story_problem as engine_problem  # noqa: E402
from new_tab_bench_report import record_all  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

WINDOW_STORY = "window-live-resize"
TERMINAL_STORY = "terminal-resize"
TERMINAL_STRESS_STORY = "terminal-resize-stress"
COLUMN_STORY = "column-resize-live"
DEVTOOLS_STORY = "devtools-resize-live"

# bench-terminal-resize.py's layouts and the result-v1 session each one measures in.
TERMINAL_LAYOUT_SESSIONS = {"idle-cursor": "light", "light": "light", "split-resize": "light",
                            "stress": "stress", "split-resize-stress": "stress"}
# Its split-resize per-terminal times: the report's field and the series' metric.
SPLIT_TIMES = (("first_send_ms", "key_to_first_grid_sent"), ("final_send_ms", "key_to_final_grid_sent"),
               ("owner_final_ms", "key_to_owner_final_grid"), ("drawn_final_ms", "key_to_first_frame_at_final_grid"))
# The per-frame arrays of a `debug.frames` stop with `raw`: recorded as result-v1, never put in a report, which keeps
# the app's summary statistics.
RAW_FRAME_KEYS = ("intervals_ms", "main_ms")

Series = collections.namedtuple("Series", "story metric unit engine session samples")


def numbers(values):
    """The numeric values (bool is not a number here)."""
    return [v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool)]


def pct(values, q, digits=2):
    """perf_stats.pct at quantile `q` (0-1), rounded to `digits`; None when no value is a number."""
    value = perf_stats.pct(numbers(values), q)
    return None if value is None else round(value, digits)


def spread(values):
    """bench-terminal-resize.py's split-resize block: {n, p50, p95, p99, max}; None when no value is a number."""
    values = numbers(values)
    if not values:
        return None
    return {"n": len(values), "p50": pct(values, 0.5), "p95": pct(values, 0.95), "p99": pct(values, 0.99),
            "max": max(values)}


def event_rpc_block(latencies):
    """resize-frames-live.py's `event_rpc_ms`: {p50, p95, p99, max}."""
    values = numbers(latencies)
    return {"p50": pct(values, 0.5), "p95": pct(values, 0.95), "p99": pct(values, 0.99),
            "max": round(max(values), 2) if values else None}


def split_raw_frames(frames):
    """(summary, {intervals_ms, main_ms}) of a `debug.frames` stop reply with `raw`. The summary is the reply without
    the per-frame arrays (every `*_per_frame` key too): the keys a stop without `raw` gives."""
    frames = frames if isinstance(frames, dict) else {}
    raw = {key: numbers(frames.get(key) or []) for key in RAW_FRAME_KEYS}
    summary = {k: v for k, v in frames.items() if k not in RAW_FRAME_KEYS and not k.endswith("_per_frame")}
    return summary, raw


def series(story, metric, unit, engine, session, samples):
    """[Series] of the numeric samples, or [] when there is none (result-v1 needs one sample)."""
    samples = numbers(samples)
    return [Series(story, metric, unit, engine, session, samples)] if samples else []


def failed(story, metric, engine, session, count):
    """The failure count of a run: always one sample (0 when nothing failed)."""
    return [Series(story, metric, "count", engine, session, [int(count)])]


# ---------- stories ----------

def story_session(story, stories=STORIES):
    """The `session` that stories.d/<story>.json declares, or None when it cannot be read."""
    try:
        with open(os.path.join(stories, f"{story}.json")) as handle:
            return json.load(handle).get("session")
    except (OSError, ValueError):
        return None


def story_problem(story, engine, session, stories=STORIES):
    """None when `story` is a stories.d story of `engine` and `session`; otherwise why this run must not record
    result-v1 under it. Checked before the launch."""
    problem = engine_problem(story, engine, stories)
    if problem:
        return problem
    declared = story_session(story, stories)
    if declared != session:
        return f"--story {story!r} has session {declared!r} in stories.d; this run measures {session!r}"
    return None


def terminal_session(layouts):
    """The one session of bench-terminal-resize.py's `layouts`; raises ValueError for an unknown layout or for
    layouts of two sessions (perf-lab ingest stores one session per run and story)."""
    unknown = [name for name in layouts if name not in TERMINAL_LAYOUT_SESSIONS]
    if unknown:
        raise ValueError(f"unknown layout {', '.join(unknown)} (one of {', '.join(TERMINAL_LAYOUT_SESSIONS)})")
    sessions = sorted({TERMINAL_LAYOUT_SESSIONS[name] for name in layouts})
    if len(sessions) != 1:
        raise ValueError(f"layouts {','.join(layouts)} measure sessions {' and '.join(sessions) or 'none'}: a --story "
                         "run measures one session")
    return sessions[0]


# ---------- the app ----------

def tagged_app(app, tag, derived_data=None):
    """`app`, else the newest `cmux DEV <tag>.app` that a tagged reload built into DerivedData; None when neither."""
    if app:
        return app.rstrip("/")
    if not tag:
        return None
    root = derived_data or os.path.join(account_home(), "Library/Developer/Xcode/DerivedData")
    found = glob.glob(os.path.join(glob.escape(root), "*", "Build", "Products", "*", f"cmux DEV {glob.escape(tag)}.app"))
    return max(found, key=os.path.getmtime) if found else None


# ---------- per bench ----------

def window_resize_series(story, raw_frames, latencies, rounds, missed):
    """resize-frames-live.py: the drags' display-frame intervals and main-thread busy ms per frame (`raw_frames`, as
    ``split_raw_frames``), each drag event's round trip, the missed vsyncs and the rounds that did not resize."""
    engine, session = "webkit", "light"
    out = series(story, "window_resize.frame_interval", "ms", engine, session, raw_frames.get("intervals_ms") or [])
    out += series(story, "window_resize.main_busy", "ms", engine, session, raw_frames.get("main_ms") or [])
    out += series(story, "window_resize.event_rpc", "ms", engine, session, latencies)
    out += series(story, "window_resize.missed", "count", engine, session, [missed])
    not_resized = sum(1 for r in rounds if not (r.get("before") and r.get("after") and r["before"][2] != r["after"][2]))
    return out + failed(story, "window_resize.not_resized", engine, session, not_resized if rounds else 1)


def terminal_resize_series(story, session, layouts, raw):
    """bench-terminal-resize.py: the series of the `layouts` results of `session`. `raw` maps a drag layout (light,
    stress) to its rounds' raw frames ({intervals_ms, main_ms} each, in round order)."""
    engine, out = "none", []
    for result in layouts:
        name = result.get("layout")
        if TERMINAL_LAYOUT_SESSIONS.get(name) != session:
            continue
        if name in ("light", "stress"):
            base, rounds = f"terminal_resize.{name}", result.get("rounds") or []
            frames = raw.get(name) or []
            out += series(story, f"{base}.frame_interval", "ms", engine, session,
                          [v for r in frames for v in r.get("intervals_ms") or []])
            out += series(story, f"{base}.main_busy", "ms", engine, session,
                          [v for r in frames for v in r.get("main_ms") or []])
            out += series(story, f"{base}.display_main", "ms", engine, session,
                          [(r.get("display") or {}).get("total_ms") for r in rounds])
            out += series(story, f"{base}.missed", "count", engine, session,
                          [(r.get("frames") or {}).get("missed") for r in rounds])
            out += series(story, f"{base}.unsettled", "count", engine, session,
                          [len(r.get("unsettled_after") or []) for r in rounds])
            out += failed(story, f"{base}.failed", engine, session, 1 if result.get("error") or not rounds else 0)
        elif name == "idle-cursor":
            out += series(story, "terminal_resize.idle_cursor.frames", "count", engine, session, [result.get("frames")])
            out += failed(story, "terminal_resize.idle_cursor.failed", engine, session, 1 if "error" in result else 0)
        else:
            base, rounds = f"terminal_split_resize.{session}", result.get("rounds") or []
            for field, metric in SPLIT_TIMES:
                out += series(story, f"{base}.{metric}", "ms", engine, session,
                              [t.get(field) for r in rounds for t in r.get("terminals") or []])
            out += failed(story, f"{base}.problems", engine, session,
                          sum(1 for r in rounds if r.get("problems")) if rounds else 1)
    return out


def column_edge_lags(steps):
    """column-resize-live.py: per paced drag step, how far (pt) the dragged column edge is from the pointer, and the
    steps whose sample found no edge."""
    lags, missing = [], 0
    for step in steps:
        edges = step.get("edges_x") or []
        if edges and isinstance(step.get("pointer_x"), (int, float)):
            lags.append(round(abs(edges[0] - step["pointer_x"]), 1))
        else:
            missing += 1
    return lags, missing


def column_resize_series(story, steps, no_divider=False):
    """column-resize-live.py: the edge lag per drag step (unitless, points) and the failed steps (no edge sampled,
    or 1 when the layout had no divider to drag)."""
    engine, session = "webkit", "light"
    lags, missing = column_edge_lags(steps)
    out = series(story, "column_resize.edge_lag", "unitless", engine, session, lags)
    return out + failed(story, "column_resize.failed_steps", engine, session, 1 if no_divider else missing)


def devtools_resize_series(story, mode, drag_errors, failures):
    """devtools-resize-live.py: per divider drag, how far (pt) DevTools' new size is from the drag (unitless), and the
    failed checks. `mode` is `synthesized` (--background, debug.mouse) or `real` (cua-driver)."""
    engine, session = "chromium", "light"
    out = series(story, f"devtools_resize.{mode}.drag_error", "unitless", engine, session, drag_errors)
    return out + failed(story, f"devtools_resize.{mode}.failed_checks", engine, session, len(failures))


def record(bench, entries):
    """Writes `entries` through ``record_all`` (BenchApp.record) and prints each written path; returns the problems
    (each series not recorded and why, or that there was none). A --story run with a problem exits 1."""
    written = record_all(bench, entries)
    for key, where in written.items():
        if not where.startswith("not recorded"):
            print(f"result-v1 {key}: {where}", flush=True)
    return [f"{key}: {where}" for key, where in written.items() if where.startswith("not recorded")] \
        if written else ["no series to record"]
