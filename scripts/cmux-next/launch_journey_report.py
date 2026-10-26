"""The relaunch seam and the result-v1 series of the launch and relaunch journeys (p12-perf-process-064).

Plain data in, plain data out (no app, no socket) except ``relaunch``, so
scripts/cmux-next/tests/test_launch_journey_results.py checks the statistics and the names the lab stories match on
any host. Percentiles come only from scripts/perf-lab/perf_stats.py (linear interpolation, the one definition the lab
judges with), as Chrome's benchmarks hand raw samples to one histogram implementation
(third_party/catapult/tracing/tracing/value/histogram.py).

| Script | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| launch-connect-journey.py | launch-connect | `launch_connect.<launch>.{first_window_frame_committed,usable,connecting_screen}` (ms) | none |
| relaunch-e2e.py | relaunch-e2e | `relaunch_e2e.<mode>.first_answer` (ms), `relaunch_e2e.failed_checks` (count) | none |
| readiness-soak.py | readiness-soak | `readiness_soak.<kind>.{cpu,idle_cpu}` (percent), `.footprint_growth` (bytes), `.fd_growth` and `readiness_soak.events.<kind>`, `readiness_soak.zombies` (count), `readiness_soak.control.{ping,snapshot}` (ms) | chromium (its tabs) |
| downloads-relaunch-live.py | none: a correctness check, it measures nothing | - | - |

Every script launches and relaunches through bench_launch.BenchApp. A relaunch keeps the tag: the same BenchApp starts
the app again on the tag's saved state (``relaunch``), as a person reopens cmux, and its one TagTeardown remembers each
launch's daemon, so the final ``BenchApp.stop`` ends every daemon and terminal the journey started. Chrome's restart
tests do the same: a `PRE_` browser test and its main test are two browser processes on one profile directory
(content/public/test/browser_test_base.h; chrome/browser/sessions/session_restore_browsertest.cc).

Each script writes result-v1 only under an explicit --story whose engine is the run's (bench_story.story_problem) and
only from a run that finished: a launch that did not come up or a stopped run keeps its report and writes no series.
A finished run whose checks failed still records: the series are where the lab sees the regression.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, load_by_path  # noqa: E402
from bench_story import STORIES, STORY_ID  # noqa: E402
from split_pane_bench_report import MIB, Series, kept, record_all, samples  # noqa: E402
from split_pane_bench_report import any_written as any_path_written  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))


def any_written(results):
    """Whether `results` (record_all's {metric: path or `not recorded: why`}, or the text `none: why` of a run that
    recorded nothing) names a written file."""
    return isinstance(results, dict) and any_path_written(results)


class StillRunning(RuntimeError):
    """``relaunch`` was asked to start an app whose earlier process still runs."""


def percentile(values, q, digits=None):
    """perf_stats.pct of the numeric values, rounded to `digits` (None: unrounded); None when there is none."""
    value = perf_stats.pct(samples(values), q)
    return value if value is None or digits is None else round(value, digits)


def story_session_problem(story, session, stories=STORIES):
    """None when `story` (already checked by bench_story.story_problem) declares `session`, else why a run of that
    session must not record under it."""
    if not STORY_ID.fullmatch(story or ""):
        return f"--story {story!r} is not a story id"
    try:
        with open(os.path.join(stories, f"{story}.json")) as handle:
            declared = json.load(handle).get("session")
    except (OSError, ValueError) as error:
        return f"--story {story!r}: {error}"
    if declared != session:
        return f"--story {story!r} has session {declared!r} in stories.d; this run is {session!r}"
    return None


def relaunch(bench, timeout=180, **launch_args):
    """Starts `bench`'s app again on the same tag, after the caller ended it the way its scenario does (a quit
    action, SIGKILL, a crash). The tag's saved state is kept (no fresh state), the daemons the earlier launch left keep
    running and are adopted, and the BenchApp's one TagTeardown remembers this launch's daemon (``remember``), so
    ``bench.stop()`` at the end ends them all. Raises StillRunning when the earlier app still runs: two apps of one
    tag would share its socket. Returns `bench`."""
    if bench.process is not None and bench.process.poll() is None:
        raise StillRunning(f"relaunch: the app of {bench.tag} (pid {bench.process.pid}) still runs; end it first")
    bench.fresh_state = False
    bench.launch(timeout=timeout, **launch_args)
    remember(bench)
    return bench


def remember(bench):
    """Records the launch's daemon in the BenchApp's TagTeardown (a no-op without one): call after each launch."""
    if bench.teardown:
        bench.teardown.remember()


# ---------------------------------------------------------------- launch-connect-journey.py

LAUNCH_CONNECT_SERIES = ("first_window_frame_committed", "usable", "connecting_screen")


def launch_connect_finished(rows, wanted):
    """None when every wanted launch ran and sent its first frame and its workspace content, else why not."""
    ran = {row["launch"]: row for row in rows}
    for name in wanted:
        row = ran.get(name)
        if row is None:
            return f"the {name} launch did not run"
        if row.get("usable_ms") is None or "first_window_frame_committed" not in (row.get("marks") or {}):
            return f"the {name} launch sent no first frame or workspace content mark"
    return None


def launch_connect_series(rows):
    """Per launch: process start to its first window frame and to workspace content, and how long the connecting
    screen showed (only when it showed and left: a screen that never left is a failed check, not a sample)."""
    series = []
    for row in rows:
        values = {"first_window_frame_committed": (row.get("marks") or {}).get("first_window_frame_committed"),
                  "usable": row.get("usable_ms"), "connecting_screen": row.get("connecting_screen_ms")}
        series += [Series(f"launch_connect.{row['launch']}.{name}", "ms", samples([values[name]]))
                   for name in LAUNCH_CONNECT_SERIES]
    return kept(series)


# ---------------------------------------------------------------- relaunch-e2e.py

def relaunch_e2e_series(relaunches, failed_checks):
    """`relaunches` is [(mode, first_answer_ms)] of every relaunch: the ms from the spawn to the app's first answered
    `system.ping` (BenchApp.first_answer_ms), per end mode. `failed_checks` is the run's failed terminal checks, one
    count sample."""
    modes = {}
    for mode, ms in relaunches:
        modes.setdefault(mode, []).append(ms)
    return kept([Series(f"relaunch_e2e.{mode}.first_answer", "ms", samples(values)) for mode, values in modes.items()]
                + [Series("relaunch_e2e.failed_checks", "count", samples([failed_checks]))])


# ---------------------------------------------------------------- readiness-soak.py

SOAK_KINDS = ("app", "daemon", "acpmux")
SOAK_EVENTS = ("crash", "hang", "control-error", "stuck-turn")


def soak_engine(app_config, browsers):
    """The engine of the soak's browser tabs as the run asks for them: none without tabs, WebKit with a sanitizer
    build (Chromium off), else Chromium."""
    if not browsers:
        return "none"
    return "webkit" if app_config else "chromium"


def soak_series(warm, idle, summary, events, zombies, samples_rows):
    """The soak's series. `warm` and `idle` are the sample rows after the warm-up and of the settled quiet phase,
    `summary` the report's per-kind summary (its growth fields), `events` its events, `zombies` the zombie count and
    `samples_rows` every sample row (the control round trips)."""
    series = []
    for kind in SOAK_KINDS:
        row = summary.get(kind) or {}
        series += [
            Series(f"readiness_soak.{kind}.cpu", "percent",
                   samples(s["processes"][kind].get("cpu_percent") for s in warm if kind in s["processes"])),
            Series(f"readiness_soak.{kind}.idle_cpu", "percent",
                   samples(s["processes"][kind].get("cpu_percent") for s in idle if kind in s["processes"])),
            Series(f"readiness_soak.{kind}.footprint_growth", "bytes",
                   [round(v * MIB) for v in samples([row.get("growth_mb")])]),
            Series(f"readiness_soak.{kind}.fd_growth", "count", samples([row.get("fd_growth")])),
        ]
    series += [Series(f"readiness_soak.events.{kind}", "count",
                      [float(sum(1 for e in events if e["kind"] == kind))]) for kind in SOAK_EVENTS]
    series += [Series("readiness_soak.zombies", "count", samples([zombies])),
               Series("readiness_soak.control.ping", "ms", samples(s.get("ping_ms") for s in samples_rows)),
               Series("readiness_soak.control.snapshot", "ms", samples(s.get("snapshot_ms") for s in samples_rows))]
    return kept(series)
