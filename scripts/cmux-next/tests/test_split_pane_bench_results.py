#!/usr/bin/env python3
"""The split and pane-scale benches on perf_stats, BenchApp and result-v1 (p12-perf-process-062).

1. split_pane_bench_report: every percentile is perf_stats.pct; each bench's rows become the series its story
   declares (app_split.*, split_latency.*, app_perf.<n>ws.<gesture>.*, pane_scale.<shape>.<n>.*), from successful
   runs only, with raw samples.
2. The series go through a real BenchApp.record and the real perf-lab ingest; every written metric fullmatches its
   story's patterns, with the story's engine and session, and one bench run ingests as one store run.
3. A run that is not a full set writes no result-v1 and fails: a refused split (app-split, split-latency), an
   incomplete pane-scale checkpoint, a run cut short.
4. split-latency-bench against a fake daemon: the rows of a real bench() record under split-latency.
5. --story is refused before any launch for a story of another engine, for an attached app and for --open.
6. The four benches leave the bench-migration queues (MQ1, MQ2, MQ3) and define no private percentile; each story's
   needs are the debug methods its command file calls.

Linux and macOS; no app, no GUI session:

    python3 -m unittest scripts/cmux-next/tests/test_split_pane_bench_results.py
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = ROOT / "scripts/perf-lab"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_launch as bl  # noqa: E402
import split_pane_bench_report as report  # noqa: E402
from test_bench_launch import FEATURES, HOST, record_bundle, result_lines  # noqa: E402
from test_ipc_benches import FakeDaemon, bench_args, split_bench  # noqa: E402

perf_stats = bl.load_by_path("perf_stats", str(PERF_LAB / "perf_stats.py"))
ingest = bl.load_by_path("perf_lab_ingest", str(PERF_LAB / "ingest.py"))
queues = bl.load_by_path("perf_lab_queues", str(PERF_LAB / "queues.py"))
app_split = bl.load_by_path("app_split_bench", str(HERE / "app-split-bench.py"))


def load_pane_scale():
    """bench_pane_scale; off macOS with a stand-in for bench_idle (its samples load libproc), removed again."""
    if sys.platform == "darwin":
        return bl.load_by_path("bench_pane_scale", str(HERE / "bench_pane_scale.py"))
    stub = types.ModuleType("bench_idle")
    stub.classify = stub.usage = stub.wait_for_socket = None
    had = sys.modules.get("bench_idle")
    sys.modules["bench_idle"] = stub
    try:
        return bl.load_by_path("bench_pane_scale", str(HERE / "bench_pane_scale.py"))
    finally:
        if had is None:
            del sys.modules["bench_idle"]
        else:
            sys.modules["bench_idle"] = had


pane_scale = load_pane_scale()
BENCHES = ("app-split-bench.py", "split-latency-bench.py", "app-perf.py", "bench_pane_scale.py")
STORIES = {"app-split-bench.py": "app-split", "split-latency-bench.py": "split-latency", "app-perf.py": "app-perf",
           "bench_pane_scale.py": "pane-scale"}
SHA = "d" * 40
VECTOR = [3.1, 4.7, 5.0, 5.2, 6.8, 7.4, 8.0, 9.9, 12.5, 30.2]


def story_file(story_id):
    return json.loads((PERF_LAB / "stories.d" / f"{story_id}.json").read_text())


class RecordingCase(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="split-pane-bench-")
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def bench(self, tag):
        bench = bl.BenchApp(record_bundle(self.folder, tag, commit=SHA), out=self.out, teardown=False,
                            host=lambda: dict(HOST))
        bench.features = FEATURES  # what launch() read
        return bench

    def by_metric(self):
        return {line["metric"]: line for line in result_lines(self.out)}

    def ingest(self):
        """The out folder through the real perf-lab ingest: {story: (engine, session, {metric: samples})}."""
        db = ingest.store.Store(Path(self.folder) / "lab.sqlite3")
        db.migrate()
        try:
            got = ingest.ingest_paths(db, [self.out], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
            self.assertEqual([r.line() for r in got.rejected], [])
            runs = db._db.execute("SELECT run_uuid, engine, session FROM runs").fetchall()
            return {row["run_uuid"].split("/", 1)[1]: (row["engine"], row["session"], db.run_metrics(row["run_uuid"]))
                    for row in runs}
        finally:
            db.close()

    def assert_story_contract(self, story_id):
        """Every written line is `story_id`'s, fullmatches one of its patterns with that pattern's unit, and carries
        the story's engine and session."""
        story = story_file(story_id)
        lines = result_lines(self.out)
        self.assertTrue(lines)
        for line in lines:
            self.assertEqual(line["story"], story_id)
            units = [m["unit"] for m in story["metrics"] if re.fullmatch(m["name"], line["metric"])]
            self.assertEqual(units, [line["unit"]], f"{story_id} declares {line['metric']} once with its unit")
            self.assertEqual((line["engine"], line["session"]), (story["engine"], story["session"]), line["metric"])
            self.assertEqual(line["better"], "lower")


class StatisticsTests(unittest.TestCase):
    def test_percentiles_are_perf_stats(self):
        for q in (0.5, 0.95, 0.99):
            self.assertEqual(report.percentile(VECTOR, q), perf_stats.pct(VECTOR, q))
        self.assertEqual(report.percentile(VECTOR, 0.95, digits=2), round(perf_stats.pct(VECTOR, 0.95), 2))
        self.assertIsNone(report.percentile([None, "x", True], 0.5))
        self.assertEqual(pane_scale.pct(VECTOR, 0.99), round(perf_stats.pct(VECTOR, 0.99), 2))
        self.assertIsNone(pane_scale.pct([], 0.5))

    def test_the_fixed_vector_of_the_commit(self):
        # Old: app-perf and bench_pane_scale s[round((n-1)q)]; app-split s[n//2] and s[min(n-1, int(0.95n))];
        # split-latency nearest rank s[ceil(qn)-1]. New: perf_stats.pct (linear interpolation).
        self.assertEqual([round(perf_stats.pct(VECTOR, q), 3) for q in (0.5, 0.95, 0.99)], [7.1, 22.235, 28.607])

    def test_split_latency_summary_keeps_its_keys(self):
        daemon = FakeDaemon(["terminal-placement-env-v1"])
        self.addCleanup(daemon.close)
        args = bench_args()
        rows, _ = split_bench.bench(daemon.path, args, log=lambda _: None, app_absent="no app")
        stats = split_bench.summarize(rows, "t", log=lambda _: None)
        self.assertEqual(set(stats["split_reply"]), {"n", "p50", "p95", "p99", "max"})
        values = [r["split_reply"] for r in rows]
        self.assertEqual(stats["split_reply"]["p50"], round(perf_stats.pct(values, 0.5), 3))


def split_row(run, ok=True, wait=10.0, shown=12.0):
    return {"label": "t", "run": run, "wall0": 0.0, "ok": ok, "error": None if ok else "refused",
            "action_run_wait_ms": wait, "snapshot_has_pane_ms": shown, "reply_listed_created": True}


class AppSplitTests(RecordingCase):
    def test_a_full_run_records_both_series(self):
        rows = [split_row(0, wait=10.0, shown=12.5), split_row(1, wait=11.0, shown=13.0)]
        with contextlib.redirect_stdout(io.StringIO()):
            code = app_split.record(self.bench("split"), "app-split", rows)
        self.assertEqual(code, 0)
        lines = self.by_metric()
        self.assertEqual(lines["app_split.action_run_wait"]["samples"], [10.0, 11.0])
        self.assertEqual(lines["app_split.snapshot_has_pane"]["samples"], [12.5, 13.0])
        self.assert_story_contract("app-split")
        runs = self.ingest()
        self.assertEqual(sorted(runs), ["app-split"])
        self.assertEqual(runs["app-split"][:2], ("none", "light"))

    def test_a_refused_or_unseen_split_writes_nothing_and_fails(self):
        for rows in ([split_row(0), split_row(1, ok=False)], [split_row(0, shown=None)], []):
            with self.subTest(rows=len(rows)), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(app_split.record(self.bench(f"s{len(rows)}"), "app-split", rows), 1)
                self.assertIn("RESULT-V1 none", out.getvalue())
        self.assertFalse(os.path.isdir(self.out) and list(Path(self.out).glob("*.ndjson")))

    def test_no_story_no_result(self):
        self.assertEqual(app_split.record(None, None, [split_row(0)]), 0)

    def test_story_needs_a_launched_app_of_its_engine(self):
        for argv in (["--control-socket", "s", "--pid", "1", "--workspace", "w", "--story", "app-split"],
                     ["--app", "a.app", "--story", "typing"],  # a chromium story
                     ["--app", "a.app", "--story", "no-such-story"],
                     ["--control-socket", "s"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    app_split.parse_args(argv)
                self.assertEqual(raised.exception.code, 2)
        self.assertEqual(app_split.parse_args(["--app", "a.app", "--story", "app-split"]).story, "app-split")

    def test_main_launches_records_and_stops_through_the_bench_app(self):
        made = []

        class Launched:
            def __init__(self, case, path, out, session):
                self.inner = case.bench("launched")
                self.socket, self.process = "sock", types.SimpleNamespace(pid=7)
                self.calls = []
                made.append(self)

            def launch(self):
                self.calls.append("launch")

            def stop(self):
                self.calls.append("stop")

            def record(self, *args, **kwargs):
                return self.inner.record(*args, **kwargs)

        original = app_split.shown_workspace, app_split.measure
        app_split.shown_workspace = lambda sock: "ws1"
        app_split.measure = lambda sock, pid, ws, runs, label: ([split_row(i) for i in range(runs)], {})
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                code = app_split.main(["--app", "a.app", "--story", "app-split", "--runs", "3", "--out", self.out],
                                      bench_app=lambda path, out, session: Launched(self, path, out, session))
        finally:
            app_split.shown_workspace, app_split.measure = original
        self.assertEqual(code, 0)
        self.assertEqual(made[0].calls, ["launch", "stop"])
        self.assertEqual(len(self.by_metric()["app_split.action_run_wait"]["samples"]), 3)


class SplitLatencyTests(RecordingCase):
    def rows(self, capabilities, runs=3):
        daemon = FakeDaemon(capabilities)
        self.addCleanup(daemon.close)
        args = bench_args(runs=runs)
        return split_bench.bench(daemon.path, args, log=lambda _: None, app_absent="--socket: no app is attached")

    def test_a_real_run_records_every_step_and_view_count(self):
        rows, info = self.rows([split_bench.STREAMS_CAPABILITY])
        out_report = {}
        code = split_bench.record(self.bench("lat"), "split-latency", rows, info, 3, True, out_report,
                                  log=lambda _: None)
        self.assertEqual(code, 0, out_report)
        lines = self.by_metric()
        self.assertEqual(len(lines["split_latency.split_reply"]["samples"]), 3)
        self.assertEqual(lines["split_latency.bench_view_connections"]["samples"], [0, 0, 0])
        self.assertEqual(lines["split_latency.bench_view_connections"]["unit"], "count")
        self.assertNotIn("split_latency.app_view_connections", lines, "no app: no app view series")
        self.assert_story_contract("split-latency")
        self.assertEqual(sorted(self.ingest()), ["split-latency"])

    def test_without_streams_only_the_steps_record(self):
        rows, info = self.rows(["terminal-placement-env-v1"])
        out_report = {}
        self.assertEqual(split_bench.record(self.bench("lat2"), "split-latency", rows, info, 3, False, out_report,
                                            log=lambda _: None), 0)
        self.assertFalse([m for m in self.by_metric() if "view" in m])

    def test_a_refused_split_or_attach_or_a_short_run_writes_nothing(self):
        rows, info = self.rows([split_bench.STREAMS_CAPABILITY])
        cases = (({"failures": ["run 2: split refused: busy"]}, rows),
                 ({"failures": ["run 0: attach refused: gone"]}, rows),
                 ({"failures": []}, rows[:2]))
        for index, (failed_info, kept_rows) in enumerate(cases):
            with self.subTest(info=failed_info, rows=len(kept_rows)):
                out_report = {}
                self.assertEqual(split_bench.record(self.bench(f"bad{index}"), "split-latency", kept_rows, failed_info, 3,
                                                    True, out_report, log=lambda _: None), 1)
                self.assertTrue(out_report["recorded"].startswith("none: "))
        self.assertFalse(os.path.isdir(self.out) and list(Path(self.out).glob("*.ndjson")))

    def test_bench_lists_a_refused_split(self):
        daemon = FakeDaemon([])
        self.addCleanup(daemon.close)
        original = daemon.handle

        def refuse_split(conn, number, m):
            if m.get("cmd") == "split":
                return daemon.write(conn, {"id": m.get("id"), "error": {"code": "busy"}})
            return original(conn, number, m)

        daemon.handle = refuse_split
        rows, info = split_bench.bench(daemon.path, bench_args(), log=lambda _: None, app_absent="no app")
        self.assertEqual(rows, [])
        self.assertEqual(len(info["failures"]), 1)

    def test_story_needs_a_local_launch_of_its_engine(self):
        for argv in (["--socket", "s", "--story", "split-latency"],
                     ["--tag", "t", "--machine", "ssh", "--ssh-host", "h", "--story", "split-latency"],
                     ["--tag", "t", "--story", "typing"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    split_bench.parse_args(argv)
        args = split_bench.parse_args(["--tag", "t", "--out", "/x", "--jsonl", "/y.jsonl", "--story", "split-latency"])
        self.assertEqual((args.artifacts, args.jsonl, args.session), ("/x", "/y.jsonl", "light"))
        self.assertEqual(split_bench.parse_args(["--tag", "t", "--artifacts", "/z"]).artifacts, "/z")


def perf_run(count, scenario, ok=True, intervals=(8.3, 8.4), busy=(2.0, 3.0), drop=0, commit=None):
    return {"workspaces": count, "scenario": scenario, "round": 0, "ok": ok, "intervals_ms": list(intervals),
            "main_ms": list(busy), "drop120": drop, "app_commit_ms": commit}


class AppPerfTests(RecordingCase):
    def test_ok_gestures_pool_their_frames(self):
        runs = [perf_run(10, "split-right", intervals=[8.3, 8.4], drop=0),
                perf_run(10, "split-right", intervals=[16.7], drop=1),
                perf_run(10, "split-right", ok=False, intervals=[99.0], drop=9),
                perf_run(50, "switch", commit=4.5), perf_run(50, "switch", commit=5.5),
                perf_run(50, "sidebar-show", intervals=[])]
        series = {s.metric: s for s in report.app_perf_series(runs)}
        self.assertEqual(series["app_perf.10ws.split-right.frame_interval"].samples, [8.3, 8.4, 16.7])
        self.assertEqual(series["app_perf.10ws.split-right.drop120"].samples, [0.0, 1.0])
        self.assertNotIn("app_perf.10ws.split-right.commit", series, "split has no app commit timer")
        self.assertEqual(series["app_perf.50ws.switch.commit"].samples, [4.5, 5.5])
        self.assertNotIn("app_perf.50ws.sidebar-show.frame_interval", series)
        written = report.record_all(self.bench("perf"), "app-perf", "none", list(series.values()), log=lambda _: None)
        self.assertTrue(report.any_written(written))
        self.assert_story_contract("app-perf")
        self.assertEqual(sorted(self.ingest()), ["app-perf"])

    def test_story_is_refused_with_open_or_another_engine_before_launch(self):
        for extra, message in ((["--story", "app-perf", "--open"], "--open"), (["--story", "typing"], "engine")):
            with self.subTest(extra=extra):
                done = subprocess.run([sys.executable, "-I", str(HERE / "app-perf.py"), "--tag", "t", "--app",
                                       "/nonexistent/cmux DEV t.app", *extra], capture_output=True, text=True, timeout=60)
                self.assertEqual(done.returncode, 2, done.stderr)
                self.assertIn(message, done.stderr)


def checkpoint(target, panes=None, refused=(), skipped=False):
    if skipped:
        return {"target": target, "skipped": "PTY guard"}
    return {"target": target, "panes": target if panes is None else panes,
            "build": {"refused": list(refused)},
            "idle": {"processes": {"app": {"cpu_percent": 0.4, "wakeups_per_s": 2.5, "footprint_mb": 300.0},
                                   "daemon": {"cpu_percent": 9.0}}}}


RAW = {"create_rtt": [10.0, 12.0], "create_visible": [20.0, None, 22.0],
       "phases": {"focus": {"op": [1.0, 2.0], "frame_interval": [8.3, 8.4]},
                  "churn": {"op": [30.0], "frame_interval": []},
                  "status": {"op": [], "frame_interval": [8.3]}}}


class PaneScaleTests(RecordingCase):
    def test_a_complete_checkpoint_records_raw_samples(self):
        series = {s.metric: s for s in report.pane_scale_series("grid", checkpoint(16), RAW)}
        self.assertEqual(series["pane_scale.grid.16.create.visible"].samples, [20.0, 22.0])
        self.assertEqual(series["pane_scale.grid.16.focus.op"].samples, [1.0, 2.0])
        self.assertNotIn("pane_scale.grid.16.churn.frame_interval", series)
        self.assertNotIn("pane_scale.grid.16.status.op", series)
        self.assertEqual(series["pane_scale.grid.16.app_footprint"].samples, [300 * 1048576])
        self.assertEqual(series["pane_scale.grid.16.idle.app_cpu"].unit, "percent")

    def test_only_complete_checkpoints_record(self):
        checkpoints = [checkpoint(16), checkpoint(64, panes=60), checkpoint(256, refused=[{"error": "x"}]),
                       checkpoint(1024, skipped=True)]
        raw = {16: RAW, 64: RAW, 256: RAW}
        written = pane_scale.record(self.bench("scale"), "pane-scale", "grid", checkpoints, raw, log=lambda _: None)
        self.assertTrue(report.any_written(written))
        self.assertEqual({m.split(".")[2] for m in self.by_metric()}, {"16"})
        self.assertFalse(any(report.pane_scale_complete(c) for c in checkpoints[1:]))
        self.assert_story_contract("pane-scale")
        self.assertIn("pane_scale.grid.16.status.frame_interval", self.by_metric())
        self.assertEqual(sorted(self.ingest()), ["pane-scale"])

    def test_the_mixed_shape_is_a_chromium_run(self):
        self.assertEqual(report.pane_scale_engine("mixed"), "chromium")
        self.assertEqual(report.pane_scale_engine("nested"), "none")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            pane_scale.main(["--tag", "t", "--shape", "mixed", "--story", "pane-scale"])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            pane_scale.main(["--tag", "t", "--story", "pane-scale", "--sample-seconds", "5"])


class QueueAndStoryTests(unittest.TestCase):
    def test_the_benches_leave_the_bench_migration_queues(self):
        names = {f"scripts/cmux-next/{name}" for name in BENCHES + ("split_pane_bench_report.py",)}
        for query in (queues.private_stats, queues.self_launch, queues.p95_without_p99):
            self.assertEqual(sorted(names & {item.key for item in query(str(ROOT))}), [], query.__name__)

    def test_no_bench_sorts_its_own_percentile(self):
        for name in BENCHES:
            text = (HERE / name).read_text()
            self.assertNotRegex(text, r"len\(\w+\) // 2\]|int\(0\.95 \* len|int\(round\(\(len", name)

    def test_each_story_needs_the_debug_methods_its_bench_calls(self):
        # debug.windows is BenchApp's launch readiness probe, which every launch has.
        for name, story_id in STORIES.items():
            with self.subTest(story=story_id):
                called = set(re.findall(r'"(debug\.[a-z_.]*[a-z_])"', (HERE / name).read_text())) - {"debug.windows"}
                needs = {n.split(":", 1)[1] for n in story_file(story_id)["needs"] if n.startswith("debug:")}
                self.assertEqual(needs, called)

    def test_each_story_runs_its_bench(self):
        for name, story_id in STORIES.items():
            story = story_file(story_id)
            self.assertEqual(story["command"][0], f"scripts/cmux-next/{name}")
            self.assertEqual(story["command"][story["command"].index("--story") + 1], story_id)


if __name__ == "__main__":
    unittest.main()
