#!/usr/bin/env python3
"""The new-tab and panel benches' result-v1 series (new_tab_bench_report.py, p12-perf-process-051): the names the
lab stories claim, the missed-run counts, the perf_stats percentiles against the private ones they replace, the
report keys the benches kept, and one run's series through perf_result and perf-lab ingest.

Runs on any host (Linux included): no app, no daemon, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_new_tab_bench_report.py
"""

from __future__ import annotations

import argparse
import ast
import importlib.util
import io
import json
import re
import statistics
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
PERF_LAB = HERE.parent / "perf-lab"
STORIES = PERF_LAB / "stories.d"
sys.path.insert(0, str(HERE))
import bench_launch  # noqa: E402
import new_tab_bench_report as report  # noqa: E402


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ingest = load("perf_lab_ingest", PERF_LAB / "ingest.py")
pr = report.perf_result
store = ingest.store

VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]
SHA = "a" * 40
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="f" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)
BUILD = pr.Build(sha=SHA, config="bench", measure_version=2)


# The private percentiles the four benches had before the migration (R8: old and new on one fixed vector).
def old_e2e_p95(values):  # new-tab-e2e.py p95
    values = sorted(values)
    return values[max(0, int(round(0.95 * len(values))) - 1)] if values else 0


def old_nearest_rank(values, q):  # cef-tab-bench.py and open-panel-bench.py pct
    values = sorted(values)
    return round(values[min(len(values) - 1, int(round(q * (len(values) - 1))))], 2)


def old_daemon(values, q):  # new-tab-daemon-bench.py p
    s = sorted(values)
    return s[min(len(s) - 1, int(q * len(s)))]


def story(story_id):
    return json.loads((STORIES / f"{story_id}.json").read_text())


def claimed(doc, series):
    """The story metric that full-matches the series' name with its unit, or None."""
    return next((m for m in doc["metrics"] if re.fullmatch(m["name"], series.metric) and m["unit"] == series.unit),
                None)


def bench_reply(key=1.5, visible=9.0, missed=0, longest=8.4):
    return {"key_ms": key, "visible_ms": visible, "spans": [],
            "frames": {"missed": missed, "max_ms": longest, "refresh_ms": 8.33, "intervals_ms": [8.3, 8.4]}}


def cef_row(case, session="light", visible=12.0, engine="cef"):
    return {"case": case, "session": session, "engine": engine, "key_ms": 2.0, "visible_ms": visible,
            "visible_frame": None if visible is None else 1, "chrome_ms": 14.0, "page_ms": 40.0}


def panel_run(mode, session="light", index=1, first=False, visible=30.0):
    return {"mode": mode, "session": session, "round": index, "first_open": first, "init_ms": 0.4, "begin_ms": 3.0,
            "sync_ms": 3.4, "visible_ms": visible, "frame_max_ms": 16.7}


class PercentileTests(unittest.TestCase):
    def test_fixed_vector_old_private_percentiles_and_the_perf_stats_ones(self):
        self.assertEqual(old_e2e_p95(VECTOR), 20.1)
        self.assertEqual(statistics.median(VECTOR), 6.95)
        self.assertEqual([old_nearest_rank(VECTOR, q) for q in (.5, .95, 1)], [6.0, 20.1, 20.1])
        self.assertEqual([old_daemon(VECTOR, q) for q in (.5, .95)], [7.9, 20.1])
        new = {q: report.pct(VECTOR, q) for q in (.5, .95, .99, 1)}
        self.assertEqual(new, {.5: 6.95, .95: 16.63, .99: 19.41, 1: 20.1})

    def test_pct_is_perf_stats_pct_rounded_and_none_when_empty(self):
        for q in (.5, .95, .99):
            self.assertEqual(report.pct(VECTOR, q), round(report.perf_stats.pct(VECTOR, q), 2))
        self.assertIsNone(report.pct([None, None], .95))
        self.assertEqual(report.pct([None, 4.0], .5), 4.0)


class SeriesTests(unittest.TestCase):
    def test_new_tab_page_legs_and_missed_runs(self):
        replies = [bench_reply(), bench_reply(visible=None), bench_reply(missed=2, longest=25.0)]
        series = {s.metric: s for s in report.new_tab_page_series("cmd_t", replies)}
        self.assertEqual(series["new_tab_page.light.cmd_t.visible"].samples, [9.0, 9.0])
        self.assertEqual(series["new_tab_page.light.cmd_t.visible.missed_runs"].samples, [1])
        self.assertEqual(series["new_tab_page.light.cmd_t.dropped"].samples, [0, 0, 2])
        self.assertEqual(series["new_tab_page.light.cmd_t.longest_frame"].samples, [8.4, 8.4, 25.0])
        self.assertEqual({s.engine for s in series.values()}, {"webkit"})

    def test_a_value_no_run_gave_writes_only_its_missed_count(self):
        series = report.per_run("s", "m", "ms", "none", "light", [None, None])
        self.assertEqual([(s.metric, s.samples) for s in series], [("m.missed_runs", [2])])
        self.assertEqual(report.per_run("s", "m", "ms", "none", "light", []), [])

    def test_cef_tab_cases_split_by_engine_into_two_stories(self):
        rows = [cef_row("cold_pane"), cef_row("cold_pane", visible=None), cef_row("webkit_new", engine="webkit"),
                cef_row("webkit_url", engine=None)]
        series = report.new_browser_tab_series(rows, ["cold_pane", "webkit_new", "webkit_url"])
        by_name = {s.metric: s for s in series}
        self.assertEqual(by_name["new_browser_tab.light.cold_pane.visible"].story, "new-browser-tab")
        self.assertEqual(by_name["new_browser_tab.light.cold_pane.visible"].engine, "chromium")
        self.assertEqual(by_name["new_browser_tab.light.cold_pane.visible.missed_runs"].samples, [1])
        self.assertEqual(by_name["new_browser_tab.light.webkit_new.visible"].story, "new-browser-tab-webkit")
        # A run that reported no engine still lands in its case's engine, never in the Chromium story.
        self.assertEqual(by_name["new_browser_tab.light.webkit_url.page"].engine, "webkit")

    def test_a_chromium_case_that_fell_back_to_webkit_stays_in_its_story_as_missed_runs(self):
        rows = [cef_row("cold_pane", visible=5.0), cef_row("cold_pane", visible=90.0, engine="webkit"),
                cef_row("cold_pane", visible=91.0, engine="webkit"), cef_row("webkit_new", visible=7.0, engine="cef")]
        series = report.new_browser_tab_series(rows, ["cold_pane", "webkit_new"])
        by_name = {s.metric: s for s in series}
        visible = by_name["new_browser_tab.light.cold_pane.visible"]
        self.assertEqual((visible.story, visible.engine, visible.samples), ("new-browser-tab", "chromium", [5.0]))
        self.assertEqual(by_name["new_browser_tab.light.cold_pane.visible.missed_runs"].samples, [2])
        self.assertEqual({s.story for s in series if ".cold_pane." in s.metric}, {"new-browser-tab"})
        # The WebKit case that opened Chromium writes no sample, only its missed count, in the WebKit story.
        self.assertNotIn("new_browser_tab.light.webkit_new.visible", by_name)
        missed = by_name["new_browser_tab.light.webkit_new.visible.missed_runs"]
        self.assertEqual((missed.story, missed.engine, missed.samples), ("new-browser-tab-webkit", "webkit", [1]))
        self.check_claims(series)

    def check_claims(self, series):
        for s in series:
            self.assertIsNotNone(claimed(story(s.story), s), f"{s.story} claims no metric {s.metric} ({s.unit})")

    def test_open_panel_leaves_the_first_open_out(self):
        runs = [panel_run("made", first=True, visible=900.0), panel_run("made"), panel_run("fresh", visible=None)]
        series = {s.metric: s for s in report.open_panel_series(runs)}
        self.assertEqual(series["open_panel.light.made.visible"].samples, [30.0])
        self.assertEqual(series["open_panel.light.fresh.visible.missed_runs"].samples, [1])
        self.assertNotIn("open_panel.light.fresh.visible", series)
        self.assertIn("open_panel.light.made.frame_max", series)

    def test_daemon_counts_tabs_that_missed_the_spare_among_answered_ones(self):
        series = {s.metric: s for s in report.new_tab_daemon_series([5.0, 7.0, None], 1, "login")}
        self.assertEqual(series["new_tab_daemon.login.reply"].samples, [5.0, 7.0])
        self.assertEqual(series["new_tab_daemon.login.reply.missed_runs"].samples, [1])
        self.assertEqual(series["new_tab_daemon.login.not_adopted"].samples, [1])


class StoryTests(unittest.TestCase):
    def check_claimed(self, story_id, series):
        doc = story(story_id)
        mine = [s for s in series if s.story == story_id]
        self.assertTrue(mine, f"no series for {story_id}")
        for s in mine:
            self.assertEqual((s.engine, s.session), (doc["engine"], doc["session"]), s.metric)
            self.assertIsNotNone(claimed(doc, s), f"{story_id} claims no metric {s.metric} ({s.unit})")

    def test_every_series_a_story_runs_is_claimed_by_it(self):
        self.check_claimed("new-tab-page", report.new_tab_page_series("cmd_t", [bench_reply(), bench_reply(visible=None)]))
        cases = ["cold_pane", "warm_pane", "second_pane", "third_pane", "url_warm", "url_cold", "webkit_new", "webkit_url"]
        rows = [cef_row(c, engine="webkit" if c.startswith("webkit") else "cef") for c in cases]
        rows.append(cef_row("cold_pane", visible=None))
        series = report.new_browser_tab_series(rows, cases)
        self.check_claimed("new-browser-tab", series)
        self.check_claimed("new-browser-tab-webkit", series)
        runs = [panel_run(m, index=i, visible=None if i == 2 else 30.0) for m in ("made", "fresh", "window") for i in (1, 2)]
        self.check_claimed("open-panel", report.open_panel_series(runs))
        self.check_claimed("new-tab-daemon", report.new_tab_daemon_series([5.0, None], 0, "login"))

    RUNNER = ["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", "/x/out"]  # what the story runner adds

    def parsed(self, story_id, script):
        """The story's command, plus the runner's flags, through its bench's own parser."""
        command = story(story_id)["command"]
        self.assertEqual(command[0], f"scripts/cmux-next/{script}")
        bench = load(f"bench_{script.replace('-', '_')[:-3]}_051", HERE / script)
        return bench.parse(command[1:] + self.RUNNER)

    def test_story_commands_parse_with_their_bench_and_say_what_the_story_does(self):
        page = self.parsed("new-tab-page", "new-tab-e2e.py")
        self.assertEqual((page.bench_open, page.runs, page.app, page.out), (True, 20, "/x/cmux DEV t.app", "/x/out"))
        for story_id in ("new-browser-tab", "new-browser-tab-webkit"):
            tab = self.parsed(story_id, "cef-tab-bench.py")
            cases = tab.cases.split(",")
            self.assertEqual((tab.sessions, tab.rounds, tab.tag), ("light", 6, "t"))
            self.assertEqual({report.case_engine(c) for c in cases}, {story(story_id)["engine"]}, story_id)
        panel = self.parsed("open-panel", "open-panel-bench.py")
        self.assertEqual((panel.sessions, panel.rounds, panel.modes), ("light", 5, "made,fresh,window"))
        daemon = self.parsed("new-tab-daemon", "new-tab-daemon-bench.py")
        self.assertEqual((daemon.runs, daemon.shell, daemon.out), (20, "login", "/x/out"))
        self.assertEqual(daemon.binary, "/x/cmux DEV t.app/Contents/Resources/bin/cmux", "--app names the daemon")

    def test_daemon_bench_takes_the_old_positionals_and_refuses_out_without_app(self):
        bench = load("bench_new_tab_daemon_bench_051", HERE / "new-tab-daemon-bench.py")
        old = bench.parse(["/bin/cmux", "7", "sh"])
        self.assertEqual((old.binary, old.runs, old.shell, old.out), ("/bin/cmux", 7, "sh", None))
        flags = bench.parse(["/bin/cmux", "7", "sh", "--runs", "3", "--shell", "login"])
        self.assertEqual((flags.runs, flags.shell), (3, "login"), "the flags win over the positionals")
        for argv in ([], ["/bin/cmux", "--out", "/x/out"]):
            with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
                bench.parse(argv)

    def test_the_catalog_lints_the_new_stories_clean(self):
        catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py").load_catalog()
        ids = {s.id for s in catalog.stories}
        self.assertLessEqual({"new-tab-page", "new-browser-tab", "new-browser-tab-webkit", "open-panel",
                              "new-tab-daemon"}, ids)
        self.assertEqual([p for p in catalog.problems if "new-" in p or "open-panel" in p], [])


class RecordTests(unittest.TestCase):
    def test_write_all_round_trips_and_ingests(self):
        series = report.new_tab_daemon_series([5.0, 7.5, 6.1], 2, "login")
        run = pr.Run(id="run1", started_at="2026-10-26T12:00:00.000000Z")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            report.write_all(out, series, BUILD, HOST, run=run, root=HERE.parent.parent)
            back = pr.read_dir(out)
            self.assertEqual(sorted(r.metric for r in back), sorted(s.metric for s in series))
            self.assertEqual(next(r for r in back if r.metric.endswith(".reply")).samples, [5.0, 7.5, 6.1])
            db = store.Store(Path(tmp) / "lab.sqlite3")
            db.migrate()
            try:
                got = ingest.ingest_paths(db, [out], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
                self.assertEqual(got.rejected, [])
                self.assertIn("new_tab_daemon.login.not_adopted", db.run_metrics("run1/new-tab-daemon"))
            finally:
                db.close()

    def ingest(self, tmp, folder):
        db = store.Store(Path(tmp) / "lab.sqlite3")
        db.migrate()
        self.addCleanup(db.close)
        got = ingest.ingest_paths(db, [folder], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
        return db, got

    def bench_app(self, tmp, out):
        """A real BenchApp (its record, its run handling) with the launch's snapshot, build and host filled in."""
        bundle = Path(tmp) / "cmux DEV nt051.app"
        bundle.mkdir()
        app = bench_launch.BenchApp(str(bundle), out=str(out), teardown=False)
        app.features, app._build, app._host = ({}, None, None), BUILD, HOST
        return app

    def two_session_series(self):
        panels = [panel_run("made", session=s, index=i) for s in ("light", "stress") for i in (1, 2)]
        cases = ["cold_pane", "webkit_new"]
        rows = [cef_row(c, session=s, engine="webkit" if c.startswith("webkit") else "cef")
                for s in ("light", "stress") for c in cases]
        return report.open_panel_series(panels) + report.new_browser_tab_series(rows, cases)

    def test_record_all_writes_each_session_as_its_own_run_and_ingest_stores_every_group(self):
        series = self.two_session_series()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            app = self.bench_app(tmp, out)
            written = report.record_all(app, series)
            self.assertFalse([v for v in written.values() if v.startswith("not recorded")])
            back = pr.read_dir(out)
            runs = {r.session: r.run.id for r in back}
            self.assertEqual(len(set(runs.values())), 2, runs)
            self.assertEqual(len({(r.session, r.run.id) for r in back}), 2, "one run per session")
            db, got = self.ingest(tmp, out)
            self.assertEqual(got.rejected, [])
            for session, run_id in runs.items():
                for story_id in ("open-panel", "new-browser-tab", "new-browser-tab-webkit"):
                    metrics = db.run_metrics(f"{run_id}/{story_id}")
                    self.assertTrue(metrics, f"{session} {story_id} not stored")
                    self.assertTrue(all(f".{session}." in name for name in metrics), metrics)
            # A second call of the same bench keeps each session on its run (new-tab-e2e records twice).
            report.record_all(app, report.open_panel_series([panel_run("fresh", session="stress")]))
            self.assertEqual({r.run.id for r in pr.read_dir(out) if r.session == "stress"}, {runs["stress"]})
            self.assertEqual((app.perf_session, app.run.id), ("light", runs["light"]))

    def test_write_all_writes_each_session_as_its_own_run(self):
        series = (report.new_tab_daemon_series([5.0], 1, "login", session="light")
                  + report.new_tab_daemon_series([6.0], 1, "login", session="stress"))
        run = pr.Run(id="run2", started_at="2026-10-26T12:00:00.000000Z")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            report.write_all(out, series, BUILD, HOST, run=run, root=HERE.parent.parent)
            self.assertEqual({(r.session, r.run.id) for r in pr.read_dir(out)}, {("light", "run2"),
                                                                                 ("stress", "run2.stress")})
            db, got = self.ingest(tmp, out)
            self.assertEqual(got.rejected, [])
            self.assertTrue(db.run_metrics("run2.stress/new-tab-daemon"))

    def test_record_all_sets_each_series_session_and_reports_a_refused_one(self):
        class Launcher:
            perf_session = "light"
            run = None
            calls = []

            def record(self, story_id, metric, unit, samples, better, engine, target_ref=None):
                self.calls.append((story_id, metric, self.perf_session, engine))
                if metric.endswith("missed_runs"):
                    raise report.RecordError("no features snapshot")
                return f"/out/{metric}.ndjson"

        launcher = Launcher()
        runs = [panel_run("made", session="stress"), panel_run("made", session="stress", visible=None)]
        with redirect_stdout(io.StringIO()) as printed:
            written = report.record_all(launcher, report.open_panel_series(runs))
        self.assertEqual({c[2] for c in launcher.calls}, {"stress"})
        self.assertEqual(written["open-panel/open_panel.stress.made.visible"], "/out/open_panel.stress.made.visible.ndjson")
        self.assertTrue(written["open-panel/open_panel.stress.made.visible.missed_runs"].startswith("not recorded"))
        self.assertIn("not recorded: no features snapshot", printed.getvalue())


class BenchSourceTests(unittest.TestCase):
    """The four benches keep no private percentile, launch through BenchApp (all but the daemon bench, which starts a
    headless daemon, not the app) and print p99 (MQ1, MQ2, MQ3)."""

    BENCHES = ("new-tab-e2e.py", "cef-tab-bench.py", "open-panel-bench.py", "new-tab-daemon-bench.py")

    def test_no_private_stats_no_self_launch_and_p99(self):
        queues = load("perf_lab_queues", PERF_LAB / "queues.py")
        root = str(HERE.parent.parent)
        keys = {f"scripts/cmux-next/{name}" for name in self.BENCHES}
        for name, run in (("MQ1", queues.private_stats), ("MQ2", queues.self_launch), ("MQ3", queues.p95_without_p99)):
            self.assertEqual([i.key for i in run(root) if i.key in keys], [], name)

    def test_cef_tab_summary_keeps_every_old_key(self):
        source = (HERE / "cef-tab-bench.py").read_text()
        keys = {node.value for node in ast.walk(ast.parse(source)) if isinstance(node, ast.Constant)
                and isinstance(node.value, str)}
        old = {"n", "missed", "engines", "key_p50", "key_max", "visible_p50", "visible_p95", "visible_max",
               "visible_frame_p95", "chrome_p50", "chrome_p95", "page_p50", "page_p95", "create_window_ms_p95",
               "tab_add_ms_p95", "main_spans_ms_p95", "refresh_ms"}
        self.assertLessEqual(old, keys)

    def test_open_panel_summary_keeps_p50_p95_max_and_adds_p99(self):
        bench = load("open_panel_bench_051", HERE / "open-panel-bench.py")
        row = bench.summary([{"sync_ms": v} for v in VECTOR], "sync_ms")
        self.assertEqual(row, {"p50": 6.95, "p95": 16.63, "p99": 19.41, "max": 20.1})
        opts = argparse.Namespace(modes="made", rounds=3)
        report_doc = {"runs": [], "summary": []}

        class App:
            def rpc(self, method, params=None, timeout=60):
                return {"mode": "made", "init_ms": 1.0, "begin_ms": 1.0, "sync_ms": 2.0, "visible_ms": 9.0,
                        "frames": {"max_ms": 8.4, "missed": 0, "refresh_ms": 8.33}}

        with redirect_stdout(io.StringIO()):
            bench.measure(App(), "light", report_doc, opts)
        self.assertEqual(report_doc["summary"][0]["visible_ms"], {"p50": 9.0, "p95": 9.0, "p99": 9.0, "max": 9.0})


if __name__ == "__main__":
    unittest.main()
