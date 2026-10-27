#!/usr/bin/env python3
"""The motion benches' medians and result-v1 series (motion_bench_report.py, p12-perf-process-061).

1. median is perf_stats.pct at 0.5 and equals the private `values[len // 2]` it replaces on an odd count; the
   fixed vectors of the commit message hold.
2. pane-perf-terminal.py, pane-zoom-terminal.py, split-spring-terminal.py and anim-perf-terminal.py define no private
   statistic and launch only through BenchApp.
3. Each bench's series fullmatch its story's patterns with the story's engine and session; a refused gesture, an
   inactive window's layout and the other session's layouts add nothing; an undeclared metric is not written.
4. The pane and anim series carry the perf cron's row names (perf-budgets.py rows_panes and rows_anim).
5. A real BenchApp.record writes them and the real perf-lab ingest stores the run.
6. The benches refuse a story of another engine or session, and --story with --reduce-motion, before any launch.

Linux and macOS; no app, no GUI session.

    python3 -m unittest scripts/cmux-next/tests/test_motion_bench_report.py
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = ROOT / "scripts/perf-lab"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_launch as bl  # noqa: E402
import motion_bench_report as report  # noqa: E402
from test_bench_launch import FEATURES, HOST, record_bundle, result_lines  # noqa: E402

budgets = bl.load_by_path("perf_budgets", str(HERE / "perf-budgets.py"))
ingest = bl.load_by_path("perf_lab_ingest", str(PERF_LAB / "ingest.py"))
BENCHES = ("pane-perf-terminal.py", "pane-zoom-terminal.py", "split-spring-terminal.py", "anim-perf-terminal.py")
SHA = "d" * 40


def story(story_id, engine="none"):
    return report.Story.load(story_id, engine)


def pane_run(layout, action, intervals, missed, posts=None, error=None):
    return {"layout": layout, "action": action, "frame_intervals_ms": list(intervals), "missed": missed,
            "posts_per_frame": posts, "error": error}


class MedianTests(unittest.TestCase):
    def old_med(self, values):
        values = sorted(v for v in values if v is not None)
        return values[len(values) // 2] if values else None

    def test_an_odd_count_keeps_the_old_median(self):
        for vector in ([8.4, 9.1, 12.6], [3, 1, 2], [16.7, 8.3, 8.4, 33.3, 8.3]):
            self.assertEqual(report.median(vector), self.old_med(vector), vector)

    def test_the_fixed_vectors_of_the_commit(self):
        # Two rounds (perf-budgets runs panes and anim with --rounds 2): the old pick was the upper value.
        self.assertEqual(self.old_med([8.4, 12.6]), 12.6)
        self.assertAlmostEqual(report.median([8.4, 12.6]), 10.5)
        self.assertEqual(self.old_med([0, 1]), 1)
        self.assertEqual(report.median([0, 1]), 0.5)
        self.assertEqual(self.old_med([8.33, 8.34, 9.0, 16.7]), 9.0)
        self.assertAlmostEqual(report.median([8.33, 8.34, 9.0, 16.7]), 8.67)

    def test_counts_stay_ints_and_gaps_are_skipped(self):
        self.assertIs(type(report.median([0, 2, 1])), int)
        self.assertEqual(report.median([None, 4, None]), 4)
        self.assertIsNone(report.median([None, None]))
        self.assertIsNone(report.median([]))
        self.assertEqual(report.median([True, 3]), 3)  # a bool is not a sample

    def test_frame_intervals_read_the_raw_reply(self):
        self.assertEqual(report.frame_intervals({"intervals_ms": [8.33, 8.34, "x", None]}), [8.33, 8.34])
        self.assertEqual(report.frame_intervals({"p95_ms": 8.3}), [])
        self.assertEqual(report.frame_intervals({"error": "no socket"}), [])


class SourceTests(unittest.TestCase):
    def test_no_private_statistic_and_no_own_launch(self):
        for name in BENCHES:
            text = (HERE / name).read_text()
            self.assertNotRegex(text, r"def (med|median|pct|percentile|stats)\(", name)
            self.assertNotIn("len(values) // 2", text, name)
            self.assertNotIn("Contents/MacOS", text, name)
            self.assertNotIn("launch_app", text, name)
            self.assertIn("BenchApp", text, name)
            # The bench env reaches the app (its own cmux.json and Ghostty file) and BenchApp.stop tears the tag down.
            self.assertNotIn("teardown=False", text, name)
            self.assertNotRegex(text, r"CMUX_NEXT_(CONFIG_FILE|GHOSTTY_CONFIG)", name)
            self.assertNotIn('"server", "stop"', text, name)
            self.assertIn("motion_bench_report", text, name)
            self.assertIn("p99", text, name)


class SeriesCase(unittest.TestCase):
    def assert_story_contract(self, series, story_id):
        doc = json.loads((PERF_LAB / "stories.d" / f"{story_id}.json").read_text())
        self.assertTrue(series)
        for entry in series:
            self.assertEqual(entry.story, story_id)
            self.assertTrue(any(re.fullmatch(m["name"], entry.metric) for m in doc["metrics"]), entry.metric)
            unit = next(m["unit"] for m in doc["metrics"] if re.fullmatch(m["name"], entry.metric))
            self.assertEqual((entry.unit, entry.engine, entry.session), (unit, doc["engine"], doc["session"]),
                             entry.metric)


class PaneSeriesTests(SeriesCase):
    def runs(self):
        return [pane_run("stress", "split", [8.3, 8.4, 16.7], 1), pane_run("stress", "split", [8.3, 8.3], 0),
                pane_run("stress", "close", [8.3], 0, error="no pane to close"),
                pane_run("stress-inactive", "zoom", [8.3], 0), pane_run("4x2", "split", [8.3], 0, posts=1.5)]

    def test_stress_story_takes_its_session_and_declared_metrics_only(self):
        series, skipped = report.pane_series(self.runs(), story("pane-stress"))
        by_name = {s.metric: s.samples for s in series}
        self.assertEqual(by_name, {"panes.split.stress.frame": [8.3, 8.4, 16.7, 8.3, 8.3],
                                   "panes.split.stress.missed": [1, 0]})
        self.assert_story_contract(series, "pane-stress")
        self.assertEqual(skipped["panes.zoom.stress-inactive"], "the window was not key")
        self.assertIn("1 refused", skipped["panes.close.stress.frame"])

    def test_chromium_story_records_the_light_grid_with_its_posts(self):
        series, _ = report.pane_series(self.runs(), story("pane-chromium", "chromium"))
        self.assertEqual({s.metric: s.samples for s in series},
                         {"panes.split.4x2.frame": [8.3], "panes.split.4x2.missed": [0],
                          "panes.split.4x2.posts_per_frame": [1.5]})
        self.assert_story_contract(series, "pane-chromium")

    def test_series_names_are_the_cron_rows(self):
        runs = self.runs()
        summary = [{"layout": r["layout"], "action": r["action"], "frames_p50_ms": 1.0, "frames_p95_ms": 2.0, "missed": 0}
                   for r in runs if not r["error"] and not r["layout"].endswith("-inactive")]
        cron_rows = set(budgets.rows_panes({"summary": summary}))
        cron_rows |= {f"panes.{s['action']}.{s['layout']}.missed" for s in summary}  # perf-cron rows_of_part
        for story_id, engine in (("pane-stress", "none"), ("pane-chromium", "chromium")):
            for entry in report.pane_series(runs, story(story_id, engine))[0]:
                if entry.metric.endswith((".frame", ".missed")):
                    self.assertIn(entry.metric, cron_rows)


class ZoomSplitAnimSeriesTests(SeriesCase):
    def test_zoom_series(self):
        runs = [{"layout": "2x2", "direction": "zoom", "frame_intervals_ms": [8.3, 9.0], "missed": 0, "resizes_sent": 1,
                 "reply_error": None},
                {"layout": "2x2", "direction": "unzoom", "frame_intervals_ms": [8.3], "missed": 2, "resizes_sent": 1,
                 "reply_error": "refused"},
                {"layout": "2x2", "direction": "unzoom", "frame_intervals_ms": [8.4], "missed": 1, "resizes_sent": 1,
                 "reply_error": None}]
        series, skipped = report.zoom_series(runs, story("pane-zoom"))
        self.assertEqual({s.metric: s.samples for s in series},
                         {"panes.zoom.2x2.frame": [8.3, 9.0], "panes.zoom.2x2.missed": [0],
                          "panes.zoom.2x2.resizes_sent": [1], "panes.unzoom.2x2.frame": [8.4],
                          "panes.unzoom.2x2.missed": [1], "panes.unzoom.2x2.resizes_sent": [1]})
        self.assertEqual(skipped, {})
        self.assert_story_contract(series, "pane-zoom")

    def test_split_series_leaves_out_a_burst_with_a_refused_press(self):
        runs = [{"direction": "right", "frame_intervals_ms": [8.3, 8.3], "missed": 0, "resizes_sent": 6, "errors": []},
                {"direction": "right", "frame_intervals_ms": [50.0], "missed": 5, "resizes_sent": 2,
                 "errors": ["not enough room"]},
                {"direction": "down", "frame_intervals_ms": [], "missed": None, "resizes_sent": None, "errors": []}]
        series, skipped = report.split_series(runs, story("split-spring"))
        self.assertEqual({s.metric: s.samples for s in series},
                         {"split_spring.right.frame": [8.3, 8.3], "split_spring.right.missed": [0],
                          "split_spring.right.resizes_sent": [6]})
        self.assertEqual(set(skipped), {"split_spring.down.frame", "split_spring.down.missed",
                                        "split_spring.down.resizes_sent"})
        self.assert_story_contract(series, "split-spring")

    def test_anim_series_are_the_cron_rows(self):
        runs = [{"anim": "tab-new", "error": None, "frame_intervals_ms": [8.3, 8.4], "dropped": 0, "over_8_33": 1,
                 "main_ms_max": 4.2, "p50_ms": 8.3, "p95_ms": 8.4},
                {"anim": "tab-new", "error": None, "frame_intervals_ms": [8.3], "dropped": 1, "over_8_33": 0,
                 "main_ms_max": 9.0, "p50_ms": 8.3, "p95_ms": 8.3},
                {"anim": "chat-open", "error": "no seeded chats", "frame_intervals_ms": [8.3], "dropped": 0,
                 "over_8_33": 0, "main_ms_max": 1.0}]
        series, skipped = report.anim_series(runs, story("anim-perf"))
        self.assertEqual({s.metric: s.samples for s in series},
                         {"anim.tab-new.frame": [8.3, 8.4, 8.3], "anim.tab-new.dropped": [0, 1],
                          "anim.tab-new.over_8_33": [1, 0], "anim.tab-new.main_ms_max": [4.2, 9.0]})
        self.assertIn("1 refused", skipped["anim.chat-open.frame"])
        self.assert_story_contract(series, "anim-perf")
        summary = [{"anim": "tab-new", "p50_ms": 8.3, "p95_ms": 8.4, "dropped": 0, "over_8_33": 1, "main_ms_max": 9.0}]
        cron_rows = set(budgets.rows_anim({"summary": summary}))
        for entry in series:
            self.assertIn(entry.metric, cron_rows)


class StoryTests(unittest.TestCase):
    def test_a_story_of_another_engine_or_session_is_refused(self):
        with self.assertRaisesRegex(report.StoryError, "engine 'chromium'"):
            story("pane-chromium", "none")
        with self.assertRaisesRegex(report.StoryError, "not in scripts/perf-lab/stories.d"):
            story("no-such-story")
        with self.assertRaisesRegex(report.StoryError, "session 'stress'"):
            story("pane-stress").check_sessions({"light"})
        story("pane-stress").check_sessions({"stress", "light"})


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="motion-bench-")
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_a_run_writes_and_ingests(self):
        bench = bl.BenchApp(record_bundle(self.folder, "motion061", commit=SHA), out=self.out, teardown=False,
                            host=lambda: dict(HOST))
        bench.features = FEATURES  # what launch() read
        runs = [pane_run("stress", "split", [8.3, 8.4], 0), pane_run("stress", "zoom", [8.3, 25.0], 1)]
        series, skipped = report.pane_series(runs, story("pane-stress"))
        written = report.record(bench, series, skipped)
        self.assertEqual(report.written_count(written), 4)
        lines = result_lines(self.out)
        self.assertEqual({line["metric"]: line["samples"] for line in lines},
                         {"panes.split.stress.frame": [8.3, 8.4], "panes.split.stress.missed": [0],
                          "panes.zoom.stress.frame": [8.3, 25.0], "panes.zoom.stress.missed": [1]})
        self.assertEqual({(line["story"], line["engine"], line["session"]) for line in lines},
                         {("pane-stress", "none", "stress")})
        db = ingest.store.Store(Path(self.folder) / "lab.sqlite3")
        db.migrate()
        try:
            stored = ingest.ingest_paths(db, [self.out],
                                         commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
            self.assertEqual([r.line() for r in stored.rejected], [])
            self.assertEqual(stored.added_results, 4)
        finally:
            db.close()

    def test_nothing_to_write_reports_why(self):
        bench = bl.BenchApp(record_bundle(self.folder, "motion061b", commit=SHA), out=self.out, teardown=False,
                            host=lambda: dict(HOST))
        bench.features = FEATURES
        written = report.record(bench, [], {"panes.zoom.stress-inactive": "the window was not key"})
        self.assertEqual(report.written_count(written), 0)
        self.assertEqual(written, {"panes.zoom.stress-inactive": "not recorded: the window was not key"})


class CommandLineTests(unittest.TestCase):
    """The benches refuse a wrong --story at parse time, before any launch (exit 2, argparse)."""

    def run_bench(self, name, *args):
        return subprocess.run([sys.executable, "-I", str(HERE / name), "--tag", "t061", "--app", "/nonexistent.app",
                               "--out", tempfile.mkdtemp(prefix="motion-cli-"), *args],
                              capture_output=True, text=True, timeout=60)

    def test_refusals(self):
        cases = [("pane-perf-terminal.py", ("--story", "pane-chromium", "--layouts", "4x2"), "engine 'chromium'"),
                 ("pane-perf-terminal.py", ("--story", "pane-stress", "--layouts", "4x2"), "session 'stress'"),
                 ("pane-perf-terminal.py", ("--story", "pane-stress", "--layouts", "stress",
                                            "--stress-selected", "chromium"), "engine 'none'"),
                 ("pane-zoom-terminal.py", ("--story", "pane-stress"), "session 'stress'"),
                 ("anim-perf-terminal.py", ("--story", "anim-perf", "--reduce-motion"), "--reduce-motion"),
                 ("anim-perf-terminal.py", ("--story", "pane-chromium"), "engine 'chromium'")]
        for name, args, message in cases:
            done = self.run_bench(name, *args)
            self.assertEqual(done.returncode, 2, (name, args, done.stdout[-400:], done.stderr[-400:]))
            self.assertIn(message, done.stderr, (name, args))


if __name__ == "__main__":
    unittest.main()
