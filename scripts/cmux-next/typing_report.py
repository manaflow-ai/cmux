"""What the typing benches share for their numbers (p12-perf-process-050): the distribution of a series from
scripts/perf-lab/perf_stats.py and the cmux-perf-result/v1 story and metric names each bench writes.

The benches: typing-frame-bench.py, automation-typing-bench.py, sidebar-churn-typing.py and bench-typing.py. Their
report keys stay as they were (n, p50, p95, max and mean, and now p99 in every one); only the percentile definition
changed, from each bench's own nearest rank to perf_stats.pct (linear interpolation, the one the lab judges with).
Chrome's benchmarks hand raw samples to one histogram implementation the same way
(third_party/catapult/tracing/tracing/value/histogram.py) instead of computing percentiles per benchmark.

Plain data in, plain data out (no app, no socket), so scripts/cmux-next/tests/test_typing_report.py checks the
statistics and the names that the stories in scripts/perf-lab/stories.d match.
"""
import os
import statistics

from bench_launch import PERF_LAB, load_by_path

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))


def is_sample(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def distribution(values, digits=2, mean=True):
    """{n, p50, p95, p99, max[, mean]} of the numeric values (perf_stats.pct), rounded to `digits`; None when empty."""
    vals = [float(v) for v in values if is_sample(v)]
    if not vals:
        return None
    out = {"n": len(vals)}
    for name, q in (("p50", 0.50), ("p95", 0.95), ("p99", 0.99)):
        out[name] = round(perf_stats.pct(vals, q), digits)
    out["max"] = round(max(vals), digits)
    if mean:
        out["mean"] = round(statistics.fmean(vals), digits)
    return out


# ---------------------------------------------------------------- result-v1 names

TYPING_STORY = "typing"  # typing-frame-bench.py, light session (stories.d/typing.json)
AUTOMATION_STORY = "automation-typing"
SIDEBAR_CHURN_STORY = "sidebar-churn-typing"


def session_story(base, session):
    """The story of a run in `session`: `base` for light, `base-stress` for STRESS. The session is not part of a lab
    series key (store.series_key), so a STRESS run under the light story would land in the light series."""
    return base if session == "light" else f"{base}-{session}"


def frame_metric(surface, phase):
    """typing-frame-bench.py's key-to-frame series of one surface and phase. The terminal at idle is the key-frame
    target's `terminal.key_to_frame` (scripts/perf-lab/targets.json); every other one is `<surface>.<phase>.key_to_frame`
    (`omnibar.load.key_to_frame`, which stories.d/omnibar.json matches)."""
    if surface == "terminal" and phase == "idle":
        return "terminal.key_to_frame"
    return f"{surface}.{phase}.key_to_frame"


# The stories that claim a key-frame target row (scripts/perf-lab/targets.json), with the session of that row. Only
# they name the target in their results: the typing story measures the same metric but does not claim the row.
KEY_FRAME_STORIES = {"typing-terminal": "light", "typing-stress": "stress"}


def frame_targets(story, session):
    """{metric: target id} of a typing-frame-bench.py run of `story` in `session` (bench_tagged.record_series
    `targets`): `terminal.key_to_frame` names `key-frame.<session>` when the story claims that row, else nothing."""
    if KEY_FRAME_STORIES.get(story) != session:
        return {}
    return {frame_metric("terminal", "idle"): f"key-frame.{session}"}


def unrecorded(**flags):
    """Why a run writes no cmux-perf-result/v1, or None when it writes them. Each flag (its option name with `_` for
    `-`) is an observer that runs during the measured keys and changes what they measure: a profiler that suspends
    the task to sample it (`--sample`, `--trace`) or per-task stack capture (`--task-diagnostics`). Such a run's
    numbers stay in its report, marked perturbed, and never join a lab series."""
    on = [f"--{name.replace('_', '-')}" for name, value in flags.items() if value]
    return f"none: {', '.join(on)} perturbs the numbers" if on else None


def frame_engine(surfaces, engine):
    """The result engine of a typing-frame-bench.py run: the omnibar tab's engine when the run types into the omnibar,
    else none (the other surfaces type into no web page)."""
    return engine if "omnibar" in surfaces else "none"


def churn_metric(phase, real_input):
    """sidebar-churn-typing.py's series of a phase kind (idle or churn). A real HID key and a `debug.key` take
    different paths (the event queue against the control socket's injected-input lane), so they are two series."""
    return f"{phase}.{'hid_key_to_frame' if real_input else 'key_to_frame'}"


def flood_story(flood, stress):
    """bench-typing.py's default story: `bench-typing-flood-<N>`, with `-stress` for the STRESS session."""
    return session_story(f"bench-typing-flood-{flood}", "stress" if stress else "light")
