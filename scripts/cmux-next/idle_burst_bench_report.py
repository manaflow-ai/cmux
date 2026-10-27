"""The result-v1 series of the idle, fsync and burst benches (p12-perf-process-063).

Plain data in, plain data out (no app, no socket, no daemon), so scripts/cmux-next/tests/test_idle_burst_bench_report.py
checks the names the lab stories match on any host. Percentiles come only from scripts/perf-lab/perf_stats.py; the
series and the writers are new_tab_bench_report.py's (one run per session, BenchApp.record or perf_result).

| Bench | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| idle-budget.py | idle-budget, idle-budget-webkit, idle-budget-stress | `idle_budget.<session>.<kind or sum>.<field>` | the session's |
| browser-idle-cost-live.py | browser-idle-cost | `browser_idle.tabs-<n>.<phase>.<class>.<field>` | chromium |
| burst-bench.py | burst, burst-stress | `burst.<phase>.<scenario>.<metric>` | chromium |
| fsync-bench.py | fsync | `fsync.<mode>.call` | none |

idle-budget's series are its perf cron rows (one value per window), so the lab and the cron read the same numbers.
fsync-bench.py measures this Mac's disk, not an app: its results carry the --app bundle's build (the build the lab
run measures) and this host, and no features (new_tab_bench_report.write_all).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from new_surfaces_report import is_sample  # noqa: E402
from new_tab_bench_report import Series, pct, perf_result, record_all, write_all  # noqa: E402,F401
from sidebar_drag_bench_report import measured_build  # noqa: E402,F401

IDLE_BUDGET_STORY = "idle-budget"
IDLE_BUDGET_WEBKIT_STORY = "idle-budget-webkit"
IDLE_BUDGET_STRESS_STORY = "idle-budget-stress"
BROWSER_IDLE_STORY = "browser-idle-cost"
BURST_STORY = "burst"
BURST_STRESS_STORY = "burst-stress"
FSYNC_STORY = "fsync"

# idle-budget's cron row units (CRON_UNITS, default "/s") -> result-v1 units. gpu_ms_per_s is the GPU ms in each
# second of the window: its unit is ms.
IDLE_UNITS = {"/s": "per_s", "threads": "count", "mW": "mW", "ms/s": "ms", "B/s": "bytes_per_s", "bytes": "bytes",
              "lines": "count"}
# browser-idle-cost-live.py: each process class's report key -> (series part, unit).
BROWSER_IDLE_CLASS_VALUES = (("cpu_percent", "cpu_percent", "percent"), ("wakeups_per_s", "wakeups_per_s", "per_s"),
                             ("footprint_total", "footprint", "bytes"), ("bytes_written", "disk_bytes", "bytes"))
# burst-bench.py: a row's counts (report key, series part); each is a failure when not 0.
BURST_COUNTS = (("lost", "lost"), ("extra", "extra"), ("commit_missed", "commit_missed"))
# fsync-bench.py's modes: (name, fcntl command or None for os.fsync). F_FULLFSYNC is 51 and F_BARRIERFSYNC 85
# (<sys/fcntl.h>); Python's fcntl module names neither on every version.
FSYNC_MODES = (("fsync", None), ("fullfsync", 51), ("barrier", 85))


def latency_block(samples):
    """{n, p50_ms, p95_ms, p99_ms, max_ms} of the samples (perf_stats.pct, 2 decimals); only n without a sample."""
    values = [v for v in samples if is_sample(v)]
    if not values:
        return {"n": 0}
    return {"n": len(values), "p50_ms": pct(values, .5), "p95_ms": pct(values, .95), "p99_ms": pct(values, .99),
            "max_ms": round(max(values), 2)}


def percentiles(values):
    """burst-bench.py's block: {n, p50, p95, p99, max} (perf_stats.pct, 2 decimals), None without a value."""
    values = [v for v in values if is_sample(v)]
    if not values:
        return None
    return {"n": len(values), "p50": pct(values, .5), "p95": pct(values, .95), "p99": pct(values, .99),
            "max": round(max(values), 2)}


# ---------------------------------------------------------------------------------------------------------
# idle-budget.py

def idle_budget_story(session, spec):
    """(story, engine, result-v1 session) of an idle-budget session from its SESSIONS spec, or None for a reference
    session (chrome-static, chrome-power-visible: another browser, no cmux build to record). STRESS sessions are the
    stress story; a session whose browser.defaultEngine is webkit is the WebKit arm; every other one runs Home's
    pages and its tabs in Chromium."""
    if spec.get("chrome"):
        return None
    if spec.get("stress"):
        return IDLE_BUDGET_STRESS_STORY, "chromium", "stress"
    if ((spec.get("config") or {}).get("browser") or {}).get("defaultEngine") == "webkit":
        return IDLE_BUDGET_WEBKIT_STORY, "webkit", "light"
    return IDLE_BUDGET_STORY, "chromium", "light"


def idle_budget_metric(session, row):
    """The result-v1 metric of the cron row `idle_budget.<session>.<kind or sum>.<field>`. Sum selectors join kinds
    with `+` (app+daemon) and unclassified kinds are `other:<executable>`, which result-v1 metric names do not
    allow: each character of that part outside [A-Za-z0-9_-] becomes `_` (app+daemon -> app_daemon). The cron row
    keeps its own name."""
    head = f"idle_budget.{session}."
    part, field = row[len(head):].rsplit(".", 1)
    return f"{head}{re.sub(r'[^A-Za-z0-9_-]', '_', part)}.{field}"


def idle_budget_series(session, spec, rows, failed=False):
    """idle-budget.py: one session's cron rows (cron_rows of its entry: `idle_budget.<session>.<kind or sum>.<field>`,
    one value per window) as series of the session's story, and `idle_budget.<session>.failed` (1 when the session
    did not measure; its rows are then empty). [] for a reference session."""
    placed = idle_budget_story(session, spec)
    if placed is None:
        return []
    story, engine, perf_session = placed
    out = [Series(story, idle_budget_metric(session, name), IDLE_UNITS.get(row.get("unit"), "per_s"), engine,
                  perf_session, [row["p50"]])
           for name, row in sorted(rows.items()) if is_sample(row.get("p50")) and not failed]
    out.append(Series(story, f"idle_budget.{session}.failed", "count", engine, perf_session, [1 if failed else 0]))
    return out


# ---------------------------------------------------------------------------------------------------------
# browser-idle-cost-live.py

def browser_idle_series(results, failures=(), story=BROWSER_IDLE_STORY):
    """browser-idle-cost-live.py's report -> series: per phase and process class its idle CPU %, wakeups/s, footprint
    and disk bytes written in the window; per phase the CPU % of all classes and cef.log's growth (bytes/s); the page
    console lines found in cef.log; the run's failures (each a FAIL line)."""
    name = f"browser_idle.tabs-{results.get('tabs')}"
    out = []
    for phase in results.get("phases") or []:
        prefix = f"{name}.{phase['phase']}"
        for kind, values in sorted((phase.get("classes") or {}).items()):
            for key, part, unit in BROWSER_IDLE_CLASS_VALUES:
                if is_sample(values.get(key)):
                    out.append(Series(story, f"{prefix}.{kind}.{part}", unit, "chromium", "light", [values[key]]))
        if is_sample(phase.get("total_cpu_percent")):
            out.append(Series(story, f"{prefix}.total_cpu_percent", "percent", "chromium", "light",
                              [phase["total_cpu_percent"]]))
        if is_sample(phase.get("cef_log_bytes_per_min")):
            out.append(Series(story, f"{prefix}.cef_log_bytes_per_s", "bytes_per_s", "chromium", "light",
                              [round(phase["cef_log_bytes_per_min"] / 60, 2)]))
    if is_sample(results.get("console_marker_lines_on_disk")):
        out.append(Series(story, f"{name}.console_marker_lines", "count", "chromium", "light",
                          [results["console_marker_lines_on_disk"]]))
    out.append(Series(story, f"{name}.failures", "count", "chromium", "light", [len(failures)]))
    return out


# ---------------------------------------------------------------------------------------------------------
# burst-bench.py

def burst_story(phase):
    return BURST_STRESS_STORY if phase == "stress" else BURST_STORY


def burst_series(phase, rows):
    """burst-bench.py: one phase's rows -> series. A row that does not measure what it names (invalid, or a scenario
    that raised errors) gives only `burst.<phase>.<scenario>.invalid` = 1; a valid one gives invalid = 0, each press's
    input -> next commit (ms, presses that changed the layout), its lost, extra and missed-commit counts and the
    missed vsyncs of debug.frames over the burst. Every row of the bench drives Chromium (its Chromium rows are
    invalid without it), so the stories are chromium."""
    story = burst_story(phase)
    out = []
    for row in rows:
        name = f"burst.{phase}.{row.get('scenario')}"
        if row.get("invalid") or row.get("errors"):
            out.append(Series(story, f"{name}.invalid", "count", "chromium", phase, [1]))
            continue
        out.append(Series(story, f"{name}.invalid", "count", "chromium", phase, [0]))
        samples = [v for v in row.get("input_to_next_commit_samples_ms") or [] if is_sample(v)]
        if samples:
            out.append(Series(story, f"{name}.input_to_next_commit", "ms", "chromium", phase, samples))
        for key, part in BURST_COUNTS:
            if is_sample(row.get(key)):
                out.append(Series(story, f"{name}.{part}", "count", "chromium", phase, [row[key]]))
        missed = (row.get("frames") or {}).get("missed")
        if is_sample(missed):
            out.append(Series(story, f"{name}.frames_missed", "count", "chromium", phase, [missed]))
    return out


# ---------------------------------------------------------------------------------------------------------
# fsync-bench.py

def fsync_series(times, session="light", story=FSYNC_STORY):
    """fsync-bench.py: {mode: [ms of each call]} -> `fsync.<mode>.call` (ms, every call)."""
    return [Series(story, f"fsync.{mode}.call", "ms", "none", session, [v for v in values if is_sample(v)])
            for mode, values in times.items() if any(is_sample(v) for v in values)]


def fsync_line(mode, samples):
    """fsync-bench.py's line of one mode: p50, p95 and p99 (perf_stats.pct) in ms, and n."""
    block = latency_block(samples)
    return f"{mode} p50 {block['p50_ms']:.2f} p95 {block['p95_ms']:.2f} p99 {block['p99_ms']:.2f} ms n={block['n']}"
