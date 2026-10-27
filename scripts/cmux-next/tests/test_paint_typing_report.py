#!/usr/bin/env python3
"""The typing e2e, Cmd-N paint and zoom close checks on perf_stats, BenchApp and result-v1 (p12-perf-process-065).

1. paint_typing_report: zoom-close-check's frame gaps are perf_stats percentiles (p99 added); the old upper median on
   the commit's fixed vector against the new one.
2. Each check's rows become the series its story declares, with raw samples; they go through a real BenchApp.record
   and the real perf-lab ingest, every metric fullmatching its story's pattern with the story's engine and session.
3. cmd-n-paint-e2e.py parses the story command with the runner's flags, refuses --story without --app or for a story
   of another engine; the two module-level checks refuse a wrong --story before any launch.
4. The four files leave the bench-migration queues (MQ1, MQ2, MQ3), launch only through BenchApp, and each story's
   needs name every debug method its command file calls.

Linux and macOS; no app, no GUI session:

    python3 -m unittest scripts/cmux-next/tests/test_paint_typing_report.py
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
from contextlib import redirect_stderr
from io import StringIO
from itertools import accumulate
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = ROOT / "scripts/perf-lab"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_launch as bl  # noqa: E402
import paint_typing_report as report  # noqa: E402
from test_bench_launch import FEATURES, HOST, record_bundle, result_lines  # noqa: E402

perf_stats = bl.load_by_path("perf_stats", str(PERF_LAB / "perf_stats.py"))
ingest = bl.load_by_path("perf_lab_ingest", str(PERF_LAB / "ingest.py"))
queues = bl.load_by_path("perf_lab_queues", str(PERF_LAB / "queues.py"))
cmd_n = bl.load_by_path("cmd_n_paint_e2e", str(HERE / "cmd-n-paint-e2e.py"))

FILES = ("home-typing-still.py", "new-workspace-real-typing-e2e.py", "cmd-n-paint-e2e.py", "zoom-close-check.py")
STORY_SCRIPTS = {"cmd-n-paint": "cmd-n-paint-e2e.py", "new-workspace-typing": "new-workspace-real-typing-e2e.py",
                 "home-typing-still": "home-typing-still.py"}
# Modules a story's script drives the app through (their rpc calls are the script's too).
HELPERS = {"home-typing-still": ("home_classic.py",)}
SHA = "e" * 40
VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]
RUNNER = ["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", "/x/out"]  # what the story runner adds


def story_file(story_id):
    return json.loads((PERF_LAB / "stories.d" / f"{story_id}.json").read_text())


def openings():
    return [{"key": "n", "split": 1, "cold": True, "bad": 0, "spare": False},
            {"key": "n", "split": 1, "cold": False, "bad": 2, "spare": True},
            {"key": "t", "split": 1, "cold": False, "bad": 0, "spare": False},
            {"key": "n", "split": 3, "cold": False, "bad": 1, "spare": True}]


def typing_rows():
    return [{"run": "cold-cmdn-1", "field": "lo world 123", "pass": False},
            {"run": "cold-cmdn-2", "field": "hello world 123", "pass": True},
            {"run": "warm-cmdt-1", "field": None, "pass": False},
            {"run": "warm-split-1", "pass": False, "error": "setup failed"},
            {"run": "warm-newwin-1", "field": "hello world 123", "pass": True}]


def pace_steps():
    return [{"ms": 1.25, "deferred": 0, "passes": 3, "rows": []}, {"ms": 0.75, "deferred": 1, "passes": 4, "rows": []}]


class StatisticsTests(unittest.TestCase):
    def test_frame_gaps_are_perf_stats_with_p99(self):
        times = [0.0] + list(accumulate(VECTOR))
        gaps = report.frame_gaps(times)
        self.assertEqual(set(gaps), {"samples", "p50", "p95", "p99", "max", "over_12_5", "over_25"})
        self.assertEqual(gaps["samples"], len(times))
        for key, q in (("p50", 0.5), ("p95", 0.95), ("p99", 0.99)):
            self.assertAlmostEqual(gaps[key], round(perf_stats.pct(VECTOR, q), 2), places=6)
        self.assertEqual((gaps["max"], gaps["over_12_5"], gaps["over_25"]), (20.1, 1, 0))
        self.assertIsNone(report.frame_gaps([5.0]))

    def test_the_fixed_vector_of_the_commit(self):
        # Old zoom-close-check: sorted gaps[len // 2] (the upper median), no p95 or p99. New: perf_stats.pct.
        old_p50 = sorted(VECTOR)[len(VECTOR) // 2]
        self.assertEqual(old_p50, 7.9)
        gaps = report.frame_gaps([0.0] + list(accumulate(VECTOR)))
        self.assertEqual((gaps["p50"], gaps["p95"], gaps["p99"]), (6.95, 16.63, 19.41))

    def test_bad_frames_keeps_the_cold_rule(self):
        frames = [{"blank": False, "intermediate": 1}, {"blank": True, "intermediate": 0},
                  {"blank": False, "intermediate": 0, "content_intermediate": 1}, {"blank": False, "intermediate": 0}]
        self.assertEqual(len(report.bad_frames(frames, cold=False)), 3)
        self.assertEqual(report.bad_frames(frames, cold=True), [frames[1]])

    def test_lost_keys(self):
        self.assertEqual(report.lost_keys("hello world 123", "lo world 123"), 3)
        self.assertEqual(report.lost_keys("hello world 123", "hello world 123"), 0)
        self.assertEqual(report.lost_keys("hello", None), 5)
        self.assertEqual(report.lost_keys("hello", ""), 5)


class SeriesTests(unittest.TestCase):
    def test_cmd_n_paint_series(self):
        got = {s.metric: (s.unit, s.samples) for s in report.cmd_n_paint_series(openings())}
        self.assertEqual(got, {
            "cmd_n_paint.cold.cmd_n.bad_frames": ("count", [0.0]),
            "cmd_n_paint.cmd_n.bad_frames": ("count", [2.0]),
            "cmd_n_paint.cmd_n.not_adopted": ("count", [0.0]),
            "cmd_n_paint.cmd_t.bad_frames": ("count", [0.0]),
            "cmd_n_paint.cmd_t.not_adopted": ("count", [1.0]),
            "cmd_n_paint.split3.cmd_n.bad_frames": ("count", [1.0]),
            "cmd_n_paint.split3.cmd_n.not_adopted": ("count", [0.0])})

    def test_typing_series(self):
        got = {s.metric: s.samples for s in report.typing_series(typing_rows(), "hello world 123")}
        self.assertEqual(got, {
            "new_workspace_typing.cold_cmdn.lost_keys": [3.0, 0.0],
            "new_workspace_typing.cold_cmdn.failed_runs": [1.0],
            "new_workspace_typing.warm_cmdt.lost_keys": [15.0],
            "new_workspace_typing.warm_cmdt.failed_runs": [1.0],
            "new_workspace_typing.warm_split.failed_runs": [1.0],
            "new_workspace_typing.warm_newwin.lost_keys": [0.0],
            "new_workspace_typing.warm_newwin.failed_runs": [0.0]})

    def test_keys_that_reach_no_new_page_are_all_lost(self):
        text = "hello world 123"
        rows = [  # the focused tab did not change: the old page (the last run's) holds the text, the new one none
                {"run": "warm-cmdn-1", "field": text + text, "pass": False, "tab_before": "t1", "tab_after": "t1"},
                {"run": "warm-cmdn-2", "field": text, "pass": False, "tab_before": "t1", "tab_after": None},
                {"run": "warm-cmdn-3", "field": text, "pass": True, "tab_before": "t1", "tab_after": "t2"},
                # Cmd-D focused a new tab but made no pane: the keys reached no new pane's page
                {"run": "warm-split-1", "field": text, "pass": False, "tab_before": "t2", "tab_after": "t3",
                 "new_pane": True, "panes": [1, 1]},
                {"run": "warm-split-2", "field": text, "pass": True, "tab_before": "t3", "tab_after": "t4",
                 "new_pane": True, "panes": [1, 2]}]
        got = {s.metric: s.samples for s in report.typing_series(rows, text)}
        self.assertEqual(got["new_workspace_typing.warm_cmdn.lost_keys"], [15.0, 15.0, 0.0])
        self.assertEqual(got["new_workspace_typing.warm_split.lost_keys"], [15.0, 0.0])

    def test_home_typing_series(self):
        got = {s.metric: (s.unit, s.samples) for s in report.home_typing_series(pace_steps(), ["x"])}
        self.assertEqual(got, {"home_typing_still.resize_pace.width_pass": ("ms", [1.25, 0.75]),
                               "home_typing_still.resize_pace.deferred": ("count", [1.0]),
                               "home_typing_still.failed_checks": ("count", [1.0])})
        self.assertEqual([s.metric for s in report.home_typing_series([], [])], ["home_typing_still.failed_checks"])


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="paint-typing-")
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def record(self, story_id, series):
        bench = bl.BenchApp(record_bundle(self.folder, story_id.replace("-", ""), commit=SHA), out=self.out,
                            teardown=False, host=lambda: dict(HOST))
        bench.features = FEATURES  # what launch() read
        written = report.record_all(bench, story_id, report.ENGINES[story_id], series)
        self.assertTrue(report.any_written(written), written)

    def assert_story_contract(self, story_id):
        story = story_file(story_id)
        lines = [line for line in result_lines(self.out) if line["story"] == story_id]
        self.assertTrue(lines)
        for line in lines:
            units = [m["unit"] for m in story["metrics"] if re.fullmatch(m["name"], line["metric"])]
            self.assertEqual(units, [line["unit"]], f"{story_id} declares {line['metric']} once with its unit")
            self.assertEqual((line["engine"], line["session"]), (story["engine"], story["session"]), line["metric"])
            self.assertEqual(line["better"], "lower")

    def test_each_story_round_trips_through_record_and_ingest(self):
        self.record("cmd-n-paint", report.cmd_n_paint_series(openings()))
        self.record("new-workspace-typing", report.typing_series(typing_rows(), "hello world 123"))
        self.record("home-typing-still", report.home_typing_series(pace_steps(), []))
        for story_id in STORY_SCRIPTS:
            self.assert_story_contract(story_id)
        db = ingest.store.Store(Path(self.folder) / "lab.sqlite3")
        db.migrate()
        try:
            got = ingest.ingest_paths(db, [self.out], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
            self.assertEqual([r.line() for r in got.rejected], [])
        finally:
            db.close()


class CommandTests(unittest.TestCase):
    def test_cmd_n_paint_parses_its_story_command(self):
        opts = cmd_n.parse(story_file("cmd-n-paint")["command"][1:] + RUNNER)
        self.assertEqual((opts.app, opts.out, opts.story, opts.runs, opts.keys), ("/x/cmux DEV t.app", "/x/out",
                                                                                  "cmd-n-paint", 3, "n,t"))

    def test_cmd_n_paint_refusals(self):
        for argv in (["--socket", "/x/s", "--story", "cmd-n-paint"], ["--app", "/x/a.app", "--story", "typing"],
                     ["--socket", "/x/s", "--app", "/x/a.app"], []):
            with self.assertRaises(SystemExit), redirect_stderr(StringIO()):
                cmd_n.parse(argv)
        self.assertEqual(cmd_n.parse(["--socket", "/x/s"]).socket, "/x/s")

    def test_module_level_checks_refuse_a_story_of_another_engine_before_launch(self):
        for name, wrong in (("home-typing-still.py", "typing"), ("new-workspace-real-typing-e2e.py", "home-perf")):
            done = subprocess.run([sys.executable, "-I", str(HERE / name), "--app", "/x/nothing.app", "--story", wrong,
                                   "--out", os.path.join(tempfile.gettempdir(), "paint-typing-refusal")],
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 2, f"{name}: {done.stderr[-400:]}")
            self.assertIn("engine", done.stderr, name)

    def test_every_check_takes_app_tag_and_out_under_python_isolated(self):
        for name in STORY_SCRIPTS.values():
            done = subprocess.run([sys.executable, "-I", str(HERE / name), "--help"], capture_output=True, text=True,
                                  timeout=60)
            self.assertEqual(done.returncode, 0, f"{name}: {done.stderr[-400:]}")
            for flag in ("--app", "--tag", "--out", "--story"):
                self.assertIn(flag, done.stdout, f"{name} {flag}")


class SourceTests(unittest.TestCase):
    def test_the_four_files_leave_the_bench_migration_queues(self):
        keys = {f"scripts/cmux-next/{name}" for name in FILES} | {"scripts/cmux-next/paint_typing_report.py"}
        for name, run in (("MQ1", queues.private_stats), ("MQ2", queues.self_launch), ("MQ3", queues.p95_without_p99)):
            self.assertEqual([i.key for i in run(str(ROOT)) if i.key in keys], [], name)

    def test_no_check_launches_on_its_own(self):
        for name in FILES:
            source = (HERE / name).read_text()
            self.assertNotIn("Popen(", source, name)
            self.assertNotIn("launch-tagged-automation", source, name)
            self.assertNotIn("Contents/MacOS", source, name)

    def test_needs_name_every_debug_method_the_script_calls(self):
        """The lab admits a build only with every method the story's script calls (catalog.py `needs`); BenchApp's
        own calls (debug.windows, debug.quit) are not the script's."""
        for story_id, script in STORY_SCRIPTS.items():
            text = "".join((HERE / f).read_text() for f in (script, *HELPERS.get(story_id, ())))
            called = set(re.findall(r'rpc\("(debug\.[a-z_.]+)"', text))
            called |= {"debug.home.api"} if "def api(" in text else set()
            needs = {n.split(":", 1)[1] for n in story_file(story_id)["needs"] if n.startswith("debug:")}
            self.assertEqual(called - needs, set(), story_id)

    def test_the_catalog_lints_the_new_stories_clean(self):
        catalog = bl.load_by_path("perf_lab_catalog", str(PERF_LAB / "catalog.py")).load_catalog()
        self.assertLessEqual(set(STORY_SCRIPTS), {s.id for s in catalog.stories})
        self.assertEqual([p for p in catalog.problems if any(s in p for s in STORY_SCRIPTS)], [])


def bench_sparse_paths():
    """The sparse-checkout list of cmux-next-frame-pacing.yml's "Checkout the bench" step."""
    lines = (ROOT / ".github/workflows/cmux-next-frame-pacing.yml").read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "- name: Checkout the bench")
    block = next(i for i in range(start, len(lines)) if lines[i].strip() == "sparse-checkout: |")
    indent = len(lines[block]) - len(lines[block].lstrip())
    paths = []
    for line in lines[block + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        paths.append(line.strip())
    return [p for p in paths if p]


class WorkflowTests(unittest.TestCase):
    def test_the_frame_pacing_checkout_holds_every_module_its_guards_import(self):
        """The frame-pacing GUI lane runs cmd-n-paint-e2e.py and instant-new-surfaces-bench.py from its sparse
        checkout: under `python3 -I` from a copy of only those paths, both start (their whole import closure, the
        perf-lab modules loaded by path included, is in it)."""
        paths = bench_sparse_paths()
        with tempfile.TemporaryDirectory(prefix="frame-pacing-sparse-") as scratch:
            for path in paths:
                source, target = ROOT / path, Path(scratch) / path
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__"))
                else:
                    shutil.copy2(source, target)
            for name in ("cmd-n-paint-e2e.py", "instant-new-surfaces-bench.py"):
                done = subprocess.run([sys.executable, "-I", "-B", str(Path(scratch) / "scripts/cmux-next" / name),
                                       "--help"], capture_output=True, text=True, timeout=60)
                self.assertEqual(done.returncode, 0, f"{name}: {done.stderr[-400:]}")


if __name__ == "__main__":
    unittest.main()
