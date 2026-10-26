"""The result-v1 series of the new-tab and panel benches (p12-perf-process-051).

Plain data in, plain data out (no app, no socket, no daemon), so scripts/cmux-next/tests/test_new_tab_bench_report.py
checks the names the lab stories match on any host. Percentiles come only from scripts/perf-lab/perf_stats.py.

| Bench | Story (scripts/perf-lab/stories.d) | Series | Engine |
| --- | --- | --- | --- |
| new-tab-e2e.py | new-tab-page | `new_tab_page.<session>.<leg>.<metric>` | webkit (the page is a WKWebView) |
| cef-tab-bench.py | new-browser-tab, new-browser-tab-webkit | `new_browser_tab.<session>.<case>.<metric>` | the engine the runs showed |
| open-panel-bench.py | open-panel | `open_panel.<session>.<mode>.<metric>` | none |
| new-tab-daemon-bench.py | new-tab-daemon | `new_tab_daemon.<shell>.<metric>` | none |

Every per-run series has a `<series>.missed_runs` count next to it (the runs that gave no value), so a failed run
shows in the lab instead of leaving the percentiles of the runs that worked (as new_surfaces_report.py).
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, RecordError, load_by_path  # noqa: E402
from new_surfaces_report import ENGINES, is_sample  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

NEW_TAB_PAGE_STORY = "new-tab-page"
NEW_BROWSER_TAB_STORY = "new-browser-tab"
OPEN_PANEL_STORY = "open-panel"
NEW_TAB_DAEMON_STORY = "new-tab-daemon"

# open-panel-bench.py's per-open times (debug.open_panel_bench), in its report's key order.
OPEN_PANEL_TIMES = ("init_ms", "begin_ms", "sync_ms", "visible_ms", "frame_max_ms")
# cef-tab-bench.py cases that open a WebKit tab; every other case opens a Chromium one.
WEBKIT_CASES = ("webkit_new", "webkit_url")

Series = collections.namedtuple("Series", "story metric unit engine session samples")


def pct(values, q, digits=2):
    """perf_stats.pct rounded to `digits` (the benches print and store 2 decimals); None when no value is a number."""
    value = perf_stats.pct(values, q)
    return None if value is None else round(value, digits)


def per_run(story, metric, unit, engine, session, values):
    """A per-run value's series (its numeric samples, in run order) and its `<metric>.missed_runs` count. No series
    for a value with no sample (result-v1 needs one); the count is still there when any run was made."""
    values = list(values)
    samples = [v for v in values if is_sample(v)]
    out = [Series(story, metric, unit, engine, session, samples)] if samples else []
    if values:
        out.append(Series(story, f"{metric}.missed_runs", "count", engine, session, [len(values) - len(samples)]))
    return out


def new_tab_page_series(leg, replies, session="light", story=NEW_TAB_PAGE_STORY):
    """new-tab-e2e.py `debug.new_tab` replies of one leg: `cmd_t` (bench_open), `cmd_w` (bench_close) or `bang`
    (bench_bang). key_ms (the input's main-thread time), visible (the frame that showed it), dropped (missed display
    frames) and longest_frame per run."""
    name = f"new_tab_page.{session}.{leg}"
    frames = [r.get("frames") or {} for r in replies]
    return (per_run(story, f"{name}.key_ms", "ms", "webkit", session, [r.get("key_ms") for r in replies])
            + per_run(story, f"{name}.visible", "ms", "webkit", session, [r.get("visible_ms") for r in replies])
            + per_run(story, f"{name}.dropped", "count", "webkit", session, [f.get("missed") for f in frames])
            + per_run(story, f"{name}.longest_frame", "ms", "webkit", session, [f.get("max_ms") for f in frames]))


def spare_open_series(opening_ms, session="light", story=NEW_TAB_PAGE_STORY):
    """new-tab-e2e.py's default test: the main-thread ms of each spare adoption (open_and_type)."""
    return per_run(story, f"new_tab_page.{session}.spare_open.ms", "ms", "webkit", session, opening_ms)


def case_engine(case, rows):
    """The result-v1 engine of a cef-tab-bench case: the engine most of its runs showed, else the case's own."""
    engines = collections.Counter(ENGINES[r["engine"]] for r in rows if r.get("engine") in ENGINES)
    if engines:
        return engines.most_common(1)[0][0]
    return "webkit" if case in WEBKIT_CASES else "chromium"


def new_browser_tab_series(rows, cases, story=NEW_BROWSER_TAB_STORY):
    """cef-tab-bench.py rows -> series per session and case. All results of one story share an engine (perf-lab
    ingest), so the WebKit cases are their own story, `<story>-webkit`."""
    out = []
    for session in sorted({r.get("session") for r in rows if r.get("session")}):
        for case in cases:
            sel = [r for r in rows if r.get("session") == session and r.get("case") == case]
            if not sel:
                continue
            engine = case_engine(case, sel)
            case_story = story if engine == "chromium" else f"{story}-{engine}"
            for metric, unit, field in (("visible", "ms", "visible_ms"), ("visible_frame", "count", "visible_frame"),
                                        ("chrome", "ms", "chrome_ms"), ("page", "ms", "page_ms"),
                                        ("key_ms", "ms", "key_ms")):
                out += per_run(case_story, f"new_browser_tab.{session}.{case}.{metric}", unit, engine, session,
                               [r.get(field) for r in sel])
    return out


def open_panel_series(runs, story=OPEN_PANEL_STORY):
    """open-panel-bench.py runs -> series per session and mode, the session's first open left out (as its
    percentiles: it may overlap launch or STRESS build work)."""
    out = []
    groups = {}
    for run in runs:
        if not run.get("first_open"):
            groups.setdefault((run.get("session"), run.get("mode")), []).append(run)
    for (session, mode), sel in groups.items():
        for key in OPEN_PANEL_TIMES:
            out += per_run(story, f"open_panel.{session}.{mode}.{key[:-len('_ms')]}", "ms", "none", session,
                           [r.get(key) for r in sel])
    return out


def new_tab_daemon_series(reply_ms, adopted, shell, session="light", story=NEW_TAB_DAEMON_STORY):
    """new-tab-daemon-bench.py: each new-tab reply's ms (None for a run that got no reply), and how many answered
    tabs did not adopt the spare host."""
    out = per_run(story, f"new_tab_daemon.{shell}.reply", "ms", "none", session, reply_ms)
    answered = sum(1 for v in reply_ms if is_sample(v))
    if answered:
        out.append(Series(story, f"new_tab_daemon.{shell}.not_adopted", "count", "none", session,
                          [answered - adopted]))
    return out


def record_all(launcher, series):
    """Writes each series as one cmux-perf-result/v1 file through ``BenchApp.record``; returns {`story/metric`: path,
    or `not recorded: <reason>`}. A series the bench cannot describe truthfully (no build sha, no features snapshot)
    is not written, and its reason is printed."""
    written = {}
    for entry in series:
        launcher.perf_session = entry.session
        key = f"{entry.story}/{entry.metric}"
        try:
            written[key] = str(launcher.record(entry.story, entry.metric, entry.unit, entry.samples, better="lower",
                                               engine=entry.engine))
        except (RecordError, perf_result.ResultError) as error:
            written[key] = f"not recorded: {error}"
            print(f"result-v1 {key}: {written[key]}", flush=True)
    return written


def write_all(out, series, build, host, run=None, root=None):
    """For a bench with no app (new-tab-daemon-bench.py): every series into one result-v1 file in `out` through
    perf_result (validated first; nothing is written when one is invalid). No features: no app ran."""
    run = run or perf_result.Run.start()
    results = [perf_result.Result(story=s.story, metric=s.metric, unit=s.unit, better="lower", samples=list(s.samples),
                                  build=build, host=host, engine=s.engine, session=s.session, run=run)
               for s in series]
    return perf_result.write_ndjson(out, results, repo_root=root)
