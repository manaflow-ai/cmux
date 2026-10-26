"""The result-v1 series of the drag, layout loop, full screen and Chromium resize benches (p12-perf-process-060).

Plain data in, plain data out (no app, no socket, no daemon), so scripts/cmux-next/tests/test_drag_layout_bench_report.py
checks the names the lab stories match on any host. Percentiles come only from scripts/perf-lab/perf_stats.py; the
series, the missed-run counts and the writers are new_tab_bench_report.py's (one run per session, BenchApp.record or
perf_result for a bench whose app another script launches).

| Bench | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| drag-lag-live.py | drag-lag | `drag_lag.<drag>.move`, `drag_lag.daemon.<phase>.round_trip`, failures | none |
| layout-loop-stress-live.py | layout-loop-stress | `layout_loop.max_in_one_turn`, `layout_loop.failures` | chromium |
| fullscreen-transition.py | fullscreen-transition | `fullscreen.<trigger>.<enter or exit>.<metric>`, failed rows | webkit |
| cef-resize-sync-bench.py | cef-resize-sync, cef-resize-sync-stress | `cef_resize_sync.<mode>.<layout>.<action>.<metric>` | chromium |

cef-resize-sync-bench.py launches no app itself: pane-perf-terminal.py does, once per mode and bench. Its results
carry the build and host of the --app bundle on this Mac (sidebar_drag_bench_report.measured_build) and no features
(new_tab_bench_report.write_all), as a bench with no app of its own.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from new_tab_bench_report import Series, pct, per_run  # noqa: E402
from new_surfaces_report import is_sample  # noqa: E402

DRAG_LAG_STORY = "drag-lag"
LAYOUT_LOOP_STORY = "layout-loop-stress"
FULLSCREEN_STORY = "fullscreen-transition"
CEF_RESIZE_SYNC_STORY = "cef-resize-sync"

# drag-lag-live.py: a reply slower than one 60 Hz frame is counted in `over_16ms` (its report key).
FRAME_60HZ_MS = 16.7
# drag-lag-live.py's drags and the daemon probe phases, in its report's key order: (series part, report key).
DRAGS = (("column", "column_drag"), ("column_back", "column_drag_back"), ("tab", "tab_drag"),
         ("sidebar", "sidebar_drag"))
DAEMON_PHASES = (("column", "daemon_during_and_3s_after_column_drags"), ("tab", "daemon_during_tab_drag"),
                 ("sidebar", "daemon_during_sidebar_drag"))
# fullscreen-transition.py: each transition's values (report key, series part, unit).
FULLSCREEN_VALUES = (("did_ms", "did", "ms"), ("settle_ms", "settle", "ms"), ("after_did_ms", "after_did", "ms"),
                     ("layout_total_ms", "layout_total", "ms"), ("layout_max_ms", "layout_max", "ms"),
                     ("resizes", "resizes", "count"), ("layout_passes", "layout_passes", "count"),
                     ("missed", "missed", "count"), ("hangs", "hangs", "count"))
# cef-resize-sync-bench.py: each pane-perf-terminal.py run's values (report key, series part, unit).
CEF_RESIZE_VALUES = (("commit_p95_ms", "commit_p95", "ms"), ("commit_max_ms", "commit_max", "ms"),
                     ("frames_p95_ms", "frame_p95", "ms"), ("frames_p99_ms", "frame_p99", "ms"),
                     ("missed", "missed", "count"))
# cef-resize-sync-bench.py's benches and the result-v1 session each one measures.
CEF_RESIZE_SESSIONS = {"light": "light", "stress": "stress"}


def latency_block(samples):
    """drag-lag-live.py's report block of one drag or probe: n, p50, p95, p99 and max (perf_stats.pct, 2 decimals)
    and the replies over one 60 Hz frame; only n when there is no sample."""
    values = [v for v in samples if is_sample(v)]
    if not values:
        return {"n": 0}
    return {"n": len(values), "p50_ms": pct(values, .5), "p95_ms": pct(values, .95), "p99_ms": pct(values, .99),
            "max_ms": round(max(values), 2), "over_16ms": sum(1 for v in values if v > FRAME_60HZ_MS)}


def median_of(rows, key, digits=2):
    """fullscreen-transition.py's per-trigger summary value: the median (perf_stats.pct) of `key` over the rows that
    have it; None when none has. A whole median of counts stays an int (3, not 3.0), as the report printed it."""
    values = [r.get(key) for r in rows if is_sample(r.get(key))]
    value = pct(values, .5, digits)
    counts = values and all(isinstance(v, int) for v in values)
    return int(value) if counts and float(value).is_integer() else value


def median_line(transitions):
    """fullscreen-transition.py's summary line of one trigger and direction: each value's median over the rounds."""
    m = lambda key: median_of(transitions, key)  # noqa: E731
    return (f"did {m('did_ms')} settle {m('settle_ms')} after-did {m('after_did_ms')} resizes {m('resizes')} "
            f"layout {m('layout_passes')}x {m('layout_total_ms')} ms max {m('layout_max_ms')} "
            f"grids {m('grid_reports')}/{m('resizes_sent')} missed {m('missed')}")


def drag_lag_series(summary, moves, probes, session="light", story=DRAG_LAG_STORY):
    """drag-lag-live.py: `summary` is its drag-lag.json, `moves` {drag key: [reply ms of each move]} and `probes`
    {phase key: [daemon_round_trip results]}. Each move's reply time (`drag_lag.<drag>.move`, ms) and `.failed` (1 when
    the drag did not run: no column edge, no two-tab strip, too few rows); each probe's daemon round trip
    (`drag_lag.daemon.<phase>.round_trip`, the idle one included) with its failed probes; the app's `timed out` log
    errors. A phase whose drag did not run has no probe series."""
    out = []
    for part, key in DRAGS:
        times = [v for v in moves.get(key) or [] if is_sample(v)]
        if times:
            out.append(Series(story, f"drag_lag.{part}.move", "ms", "none", session, times))
        failed = 1 if "error" in (summary.get(key) or {"error": "not run"}) else 0
        out.append(Series(story, f"drag_lag.{part}.failed", "count", "none", session, [failed]))
    idle = summary.get("daemon_idle")
    phases = [("idle", [idle] if isinstance(idle, dict) else [])]
    phases += [(part, probes.get(key) or []) for part, key in DAEMON_PHASES]
    for part, results in phases:
        if not results:
            continue
        ok = [r.get("ms") for r in results if r.get("ok") and is_sample(r.get("ms"))]
        if ok:
            out.append(Series(story, f"drag_lag.daemon.{part}.round_trip", "ms", "none", session, ok))
        out.append(Series(story, f"drag_lag.daemon.{part}.failed", "count", "none", session, [len(results) - len(ok)]))
    errors = summary.get("app_errors")
    if isinstance(errors, dict) and is_sample(errors.get("timed_out")):
        out.append(Series(story, "drag_lag.app.timed_out", "count", "none", session, [errors["timed_out"]]))
    return out


def layout_loop_series(results, failures, session="light", story=LAYOUT_LOOP_STORY):
    """layout-loop-stress-live.py: the most layouts of one view in one window layout after each step
    (`layout_loop.max_in_one_turn`) and the run's failures (`layout_loop.failures`, the checks that failed; a run that
    stopped early still counts the ones it found). No step series when no step ran."""
    worst = [r.get("max_in_one_turn") for r in results if is_sample(r.get("max_in_one_turn"))]
    out = [Series(story, "layout_loop.max_in_one_turn", "count", "chromium", session, worst)] if worst else []
    out.append(Series(story, "layout_loop.failures", "count", "chromium", session, [len(failures)]))
    return out


def fullscreen_series(transitions, rows, session="light", story=FULLSCREEN_STORY):
    """fullscreen-transition.py: per trigger and direction, each round's transition values
    (`fullscreen.<trigger>.<enter|exit>.<value>`, with `.missed_runs` for a round that gave none), and the failed
    check rows of the run (`fullscreen.failed_rows`: layout rows, and the settle budget rows under --gate)."""
    out = []
    groups = {}
    for t in transitions:
        groups.setdefault((t.get("trigger"), "enter" if t.get("entering") else "exit"), []).append(t)
    for (trigger, direction), sel in groups.items():
        for key, part, unit in FULLSCREEN_VALUES:
            out += per_run(story, f"fullscreen.{trigger}.{direction}.{part}", unit, "webkit", session,
                           [t.get(key) for t in sel])
    out.append(Series(story, "fullscreen.failed_rows", "count", "webkit", session,
                      [sum(1 for r in rows if not r[3])]))
    return out


def cef_resize_story(session, base=CEF_RESIZE_SYNC_STORY):
    """The story of a cef-resize-sync bench session: `base` for light, `base-<session>` otherwise (the session is
    not part of a lab series key, as sidebar_drag_bench_report.drag_story)."""
    return base if session == "light" else f"{base}-{session}"


def cef_resize_series(mode, bench, runs, valid):
    """cef-resize-sync-bench.py, one mode and bench: pane-perf-terminal.py's report `runs` (one per layout, action
    and round) -> per layout and action, each round's commit and frame values with their `.missed_runs`, and
    `cef_resize_sync.<mode>.failed` (1 when the mode was not valid or the bench measured nothing)."""
    session = CEF_RESIZE_SESSIONS[bench]
    story = cef_resize_story(session)
    out = []
    groups = {}
    for run in runs:
        groups.setdefault((run.get("layout"), run.get("action")), []).append(run)
    for (layout, action), sel in groups.items():
        for key, part, unit in CEF_RESIZE_VALUES:
            out += per_run(story, f"cef_resize_sync.{mode}.{layout}.{action}.{part}", unit, "chromium", session,
                           [r.get(key) for r in sel])
    failed = 0 if valid and runs else 1
    out.append(Series(story, f"cef_resize_sync.{mode}.failed", "count", "chromium", session, [failed]))
    return out
