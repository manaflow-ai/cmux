"""The result-v1 series of the sidebar document and drag benches (p12-perf-process-055).

Plain data in, plain data out (no app, no socket, no daemon), so scripts/cmux-next/tests/test_sidebar_bench_report.py
checks the names the lab stories match on any host. Percentiles come only from scripts/perf-lab/perf_stats.py; the
series, the missed-run counts and the writers are new_tab_bench_report.py's (one run per session, BenchApp.record or
perf_result for a bench with no app).

| Bench | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| sidebar-doc-bench.py | sidebar-doc | `sidebar_doc.<subscriber>.<request>` per request, ms | none |
| sidebar-v2-drag-record.py | sidebar-drag, sidebar-drag-stress | `sidebar_drag.<session>.<scenario>.<metric>` | none |
| sidebar-v2-drag-live.py | sidebar-drag-live | `sidebar_drag_live.<metric>` | none |
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
import bench_launch  # noqa: E402
from new_tab_bench_report import RecordError, Series, pct, perf_result, perf_stats, record_all, write_all  # noqa: E402,F401

SIDEBAR_DOC_STORY = "sidebar-doc"
SIDEBAR_DRAG_STORY = "sidebar-drag"
SIDEBAR_DRAG_LIVE_STORY = "sidebar-drag-live"

# sidebar-doc-bench.py's timed requests, in its report's order; each one's series name.
DOC_REQUESTS = ("workspace.create", "workspace.place", "workspace_group.update", "sidebar.move")


def measured_build(app, stated=None):
    """(result-v1 build, host) of the app bundle on this Mac, for a bench that starts only its daemon. Raises
    RecordError when the build cannot be named (as BenchApp.record)."""
    binary = bench_launch.main_binary(app)
    build = perf_result.Build(sha=bench_launch.build_sha(app), config=bench_launch.build_config(app, binary, stated),
                              measure_version=bench_launch.PERF_LAB_MEASURE_VERSION)
    return build, perf_result.Host.from_dict(bench_launch.read_host())


def distribution_line(name, samples):
    """One report line of sidebar-doc-bench.py: median, p95 and p99 (perf_stats.pct) and n."""
    return (f"{name}: median {pct(samples, .5):.2f} ms, p95 {pct(samples, .95):.2f} ms, "
            f"p99 {pct(samples, .99):.2f} ms, n={len(samples)}")


def doc_metric(subscriber, request):
    """`sidebar_doc.<subscriber>.<request>` with the request's dots as underscores (workspace.create ->
    workspace_create), so a metric name has one dot per level."""
    return f"sidebar_doc.{subscriber}.{request.replace('.', '_')}"


def doc_series(times, subscriber, session="light", story=SIDEBAR_DOC_STORY):
    """sidebar-doc-bench.py: {request: [ms per timed request]} -> one series per request that was timed. Every timed
    request answered (the bench stops on an error), so there is no missed-run count."""
    return [Series(story, doc_metric(subscriber, request), "ms", "none", session, list(times[request]))
            for request in DOC_REQUESTS if times.get(request)]


def drag_session(stress):
    """The result-v1 session of a sidebar-v2-drag-record.py run: `stress` with --stress workspaces, else `light`."""
    return "stress" if stress else "light"


def drag_story(session, base=SIDEBAR_DRAG_STORY):
    """The story of a drag recording in `session`: `base` for light, `base-<session>` otherwise. The session is not
    part of a lab series key, so a STRESS run under the light story would land in the light series."""
    return base if session == "light" else f"{base}-{session}"


def drag_series(scenario, result, work, session="light", story=None):
    """One scenario of sidebar-v2-drag-record.py: its analyse() result and the drag work samples it judged
    (sidebar_v2_motion_checks.drag_work). The main-thread drag update per frame (`work`, ms), the largest step of a
    view that is not dragged (`max_step`, pt), the jumps over JUMP_PT and the late frame gaps (counts), and `failed`
    (1 when a check of the scenario failed). A scenario that recorded nothing writes only `failed`."""
    story = story or drag_story(session)
    name = f"sidebar_drag.{session}.{scenario}"
    failed = Series(story, f"{name}.failed", "count", "none", session, [0 if result.get("ok") else 1])
    if not result.get("recorded"):
        return [failed]
    out = [Series(story, f"{name}.work", "ms", "none", session, list(work))] if work else []
    return out + [
        Series(story, f"{name}.max_step", "unitless", "none", session, [result["max_step_pt"]]),
        Series(story, f"{name}.jumps", "count", "none", session, [result["jump_count"]]),
        Series(story, f"{name}.late_frames", "count", "none", session, [result["frame_gaps_over_1_5x"]]),
        failed,
    ]


def drag_live_series(results, ffi_calls, session="light", story=SIDEBAR_DRAG_LIVE_STORY):
    """sidebar-v2-drag-live.py: its steps [(step, PASS|FAIL|SKIP)] and the FFI calls of each held drag (two when the
    drag begins once and drops once). `failed_steps` counts the FAILs, so a broken proof shows in the lab."""
    out = [Series(story, "sidebar_drag_live.ffi_calls_per_drag", "count", "none", session, list(ffi_calls))] \
        if ffi_calls else []
    failed = sum(1 for _, state in results if state == "FAIL")
    return out + [Series(story, "sidebar_drag_live.failed_steps", "count", "none", session, [failed])]
