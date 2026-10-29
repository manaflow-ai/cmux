#!/usr/bin/env python3
"""The drag, layout loop, full screen and Chromium resize benches' statistics and result-v1 series
(drag_layout_bench_report.py, p12-perf-process-060): the perf_stats percentiles against the private ones they replace,
the report keys the benches kept, the names the lab stories claim, the story commands through each bench's own parser,
the debug methods each story needs, and one run's series through perf_result and perf-lab ingest.

Runs on any host (Linux included): no app, no daemon, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_drag_layout_bench_report.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import re
import statistics
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = HERE.parent / "perf-lab"
STORIES = PERF_LAB / "stories.d"
sys.path.insert(0, str(HERE))
import drag_layout_bench_report as report  # noqa: E402
from new_tab_bench_report import perf_result as pr  # noqa: E402
from new_tab_bench_report import write_all  # noqa: E402


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ingest = load("perf_lab_ingest", PERF_LAB / "ingest.py")
store = ingest.store

VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]
SHA = "c" * 40
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="e" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)
BENCHES = ("cef-resize-sync-bench.py", "drag-lag-live.py", "layout-loop-stress-live.py", "fullscreen-transition.py")
STORY_SCRIPTS = {"drag-lag": "drag-lag-live.py", "layout-loop-stress": "layout-loop-stress-live.py",
                 "fullscreen-transition": "fullscreen-transition.py", "cef-resize-sync": "cef-resize-sync-bench.py",
                 "cef-resize-sync-stress": "cef-resize-sync-bench.py"}


# The private statistics the benches had before the migration (R8: old and new on one fixed vector).
def old_drag_lag_stats(samples):  # drag-lag-live.py stats()
    ordered = sorted(samples)
    pick = lambda q: ordered[min(len(ordered) - 1, int(q * len(ordered)))]  # noqa: E731
    return {"n": len(samples), "p50_ms": round(statistics.median(samples), 2), "p95_ms": round(pick(0.95), 2),
            "max_ms": round(ordered[-1], 2), "over_16ms": sum(1 for s in samples if s > 16.7)}


def old_fullscreen_med(values):  # fullscreen-transition.py med(): the upper median
    values = sorted(values)
    return values[len(values) // 2]


def story(story_id):
    return json.loads((STORIES / f"{story_id}.json").read_text())


def claimed(doc, series):
    return next((m for m in doc["metrics"] if re.fullmatch(m["name"], series.metric) and m["unit"] == series.unit),
                None)


def drag_inputs(column_ok=True):
    summary = {"tag": "t", "daemon_idle": {"ms": 3.5, "ok": True},
               "column_drag": report.latency_block(VECTOR) if column_ok else {"error": "no column edge"},
               "column_drag_back": report.latency_block(VECTOR), "tab_drag": {"error": "no two-tab strip"},
               "sidebar_drag": {"error": "could not press"},
               "app_errors": {"timed_out": 2, "set_viewport_pane_width_timed_out": 1, "sample": []}}
    moves = {"column_drag": VECTOR, "column_drag_back": VECTOR} if column_ok else {"column_drag_back": VECTOR}
    probes = {"daemon_during_and_3s_after_column_drags": [{"ms": 4.0, "ok": True}, {"ms": 9.0, "ok": False,
                                                                                    "error": "x"}]}
    return summary, moves, probes


def fullscreen_inputs():
    transitions = []
    for trigger in ("action", "zoom"):
        for entering in (True, False):
            for index in range(3):
                transitions.append({"trigger": trigger, "entering": entering, "did_ms": 400.0 + index,
                                    "settle_ms": 520.5, "after_did_ms": None if index == 2 else 120.5,
                                    "layout_total_ms": 8.25, "layout_max_ms": 2.5, "resizes": 3, "layout_passes": 4,
                                    "missed": 0, "hangs": 0})
    rows = [("a", "b", "c", True), ("d", "e", "f", False)]
    return transitions, rows


def cef_runs():
    return [{"layout": layout, "action": action, "round": index, "commit_p95_ms": 3.5, "commit_max_ms": 7.0,
             "frames_p95_ms": 8.4, "frames_p99_ms": 9.1, "missed": 0 if index else None}
            for layout in ("1x2", "4x2") for action in ("split", "close-down") for index in range(3)]


class PercentileTests(unittest.TestCase):
    def test_fixed_vector_old_private_statistics_and_the_perf_stats_ones(self):
        old, new = old_drag_lag_stats(VECTOR), report.latency_block(VECTOR)
        self.assertEqual((old["p50_ms"], old["p95_ms"]), (6.95, 20.1))
        self.assertEqual((new["p50_ms"], new["p95_ms"], new["p99_ms"]), (6.95, 16.63, 19.41))
        self.assertEqual(old_fullscreen_med(VECTOR), 7.9)
        rows = [{"did_ms": v} for v in VECTOR]
        self.assertEqual(report.median_of(rows, "did_ms"), 6.95)

    def test_drag_lag_block_keeps_its_keys_and_adds_p99(self):
        old, new = old_drag_lag_stats(VECTOR), report.latency_block(VECTOR)
        self.assertEqual(set(new) - set(old), {"p99_ms"})
        self.assertEqual((new["n"], new["max_ms"], new["over_16ms"]), (old["n"], old["max_ms"], old["over_16ms"]))
        self.assertEqual(report.latency_block([]), {"n": 0})
        self.assertEqual(report.latency_block([None, True]), {"n": 0})

    def test_median_of_skips_missing_values_and_is_none_when_empty(self):
        self.assertEqual(report.median_of([{"x": 1}, {"x": None}, {}, {"x": 3}], "x"), 2.0)
        self.assertIsNone(report.median_of([{}], "x"))

    def test_fullscreen_summary_line_keeps_its_fields(self):
        line = report.median_line(fullscreen_inputs()[0][:3])
        for field in ("did 401.0", "settle 520.5", "after-did 120.5", "resizes 3", "layout 4x 8.25 ms", "max 2.5",
                      "grids None/None", "missed 0"):
            self.assertIn(field, line)


class SeriesTests(unittest.TestCase):
    def by_metric(self, series):
        return {s.metric: s for s in series}

    def test_drag_lag_series(self):
        got = self.by_metric(report.drag_lag_series(*drag_inputs()))
        self.assertEqual(got["drag_lag.column.move"].samples, VECTOR)
        self.assertEqual([got[f"drag_lag.{d}.failed"].samples for d in ("column", "column_back", "tab", "sidebar")],
                         [[0], [0], [1], [1]])
        self.assertNotIn("drag_lag.tab.move", got)
        self.assertEqual(got["drag_lag.daemon.idle.round_trip"].samples, [3.5])
        self.assertEqual(got["drag_lag.daemon.column.round_trip"].samples, [4.0])
        self.assertEqual(got["drag_lag.daemon.column.failed"].samples, [1])
        self.assertNotIn("drag_lag.daemon.tab.failed", got)  # its drag never ran: no probe
        self.assertEqual(got["drag_lag.app.timed_out"].samples, [2])
        self.assertEqual({(s.engine, s.session, s.story) for s in got.values()}, {("none", "light", "drag-lag")})

    def test_drag_lag_drag_that_did_not_run_fails(self):
        got = self.by_metric(report.drag_lag_series(*drag_inputs(column_ok=False)))
        self.assertEqual(got["drag_lag.column.failed"].samples, [1])
        self.assertNotIn("drag_lag.column.move", got)
        got = self.by_metric(report.drag_lag_series({}, {}, {}))
        self.assertEqual(got["drag_lag.column.failed"].samples, [1], "a run cut short before the drag")

    def test_layout_loop_series(self):
        got = self.by_metric(report.layout_loop_series([{"max_in_one_turn": 3}, {"max_in_one_turn": 17}], ["x"]))
        self.assertEqual(got["layout_loop.max_in_one_turn"].samples, [3, 17])
        self.assertEqual(got["layout_loop.failures"].samples, [1])
        self.assertEqual(set(self.by_metric(report.layout_loop_series([], ["no window"]))), {"layout_loop.failures"})

    def test_fullscreen_series(self):
        got = self.by_metric(report.fullscreen_series(*fullscreen_inputs()))
        self.assertEqual(got["fullscreen.action.enter.did"].samples, [400.0, 401.0, 402.0])
        self.assertEqual(got["fullscreen.zoom.exit.after_did"].samples, [120.5, 120.5])
        self.assertEqual(got["fullscreen.zoom.exit.after_did.missed_runs"].samples, [1])
        self.assertEqual(got["fullscreen.failed_rows"].samples, [1])
        self.assertEqual(got["fullscreen.action.enter.resizes"].unit, "count")

    def test_cef_resize_series_per_mode_session_and_story(self):
        light = self.by_metric(report.cef_resize_series("on0", "light", cef_runs(), valid=True))
        self.assertEqual(light["cef_resize_sync.on0.4x2.close-down.commit_p95"].samples, [3.5, 3.5, 3.5])
        self.assertEqual(light["cef_resize_sync.on0.4x2.close-down.frame_p99"].samples, [9.1, 9.1, 9.1])
        self.assertEqual(light["cef_resize_sync.on0.1x2.split.missed.missed_runs"].samples, [1])
        self.assertEqual(light["cef_resize_sync.on0.failed"].samples, [0])
        self.assertEqual({(s.story, s.session, s.engine) for s in light.values()},
                         {("cef-resize-sync", "light", "chromium")})
        stress = report.cef_resize_series("off", "stress", [], valid=False)
        self.assertEqual([(s.story, s.metric, s.session, s.samples) for s in stress],
                         [("cef-resize-sync-stress", "cef_resize_sync.off.failed", "stress", [1])])
        self.assertEqual(report.cef_resize_series("on", "light", [], valid=True)[-1].samples, [1], "no report")


class StoryTests(unittest.TestCase):
    def check_claimed(self, story_id, series):
        doc = story(story_id)
        mine = [s for s in series if s.story == story_id]
        self.assertTrue(mine, f"no series for {story_id}")
        for s in mine:
            self.assertEqual((s.engine, s.session), (doc["engine"], doc["session"]), s.metric)
            self.assertIsNotNone(claimed(doc, s), f"{story_id} claims no metric {s.metric} ({s.unit})")

    def test_every_series_a_story_runs_is_claimed_by_it(self):
        self.check_claimed("drag-lag", report.drag_lag_series(*drag_inputs()))
        self.check_claimed("layout-loop-stress", report.layout_loop_series([{"max_in_one_turn": 3}], []))
        self.check_claimed("fullscreen-transition", report.fullscreen_series(*fullscreen_inputs()))
        for bench in ("light", "stress"):
            series = report.cef_resize_series("off", bench, cef_runs(), valid=True)
            self.check_claimed(report.cef_resize_story(report.CEF_RESIZE_SESSIONS[bench]), series)

    def test_needs_name_every_debug_method_the_script_calls(self):
        """The lab admits a build only with every method the story's script calls (catalog.py `needs`); BenchApp's
        own calls (debug.windows, debug.quit) are not the script's. cef-resize-sync-bench calls none itself: its
        needs are its sub-benches' files and their debug methods."""
        for story_id, script in STORY_SCRIPTS.items():
            called = set(re.findall(r'rpc\("(debug\.[a-z_]+)"', (HERE / script).read_text()))
            needs = {n.split(":", 1)[1] for n in story(story_id)["needs"] if n.startswith("debug:")}
            self.assertEqual(called - needs, set(), story_id)

    RUNNER = ["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", "/x/out"]  # what the story runner adds

    def parsed(self, story_id):
        command = story(story_id)["command"]
        script = STORY_SCRIPTS[story_id]
        self.assertEqual(command[0], f"scripts/cmux-next/{script}")
        bench = load(f"bench_{script.replace('-', '_')[:-3]}_060", HERE / script)
        return bench.parse(command[1:] + self.RUNNER)

    def test_story_commands_parse_with_their_bench(self):
        drag = self.parsed("drag-lag")
        self.assertEqual((drag.app, drag.out, drag.story, drag.moves), ("/x/cmux DEV t.app", "/x/out", "drag-lag", 120))
        loop = self.parsed("layout-loop-stress")
        self.assertEqual((loop.app, loop.tag, loop.out), ("/x/cmux DEV t.app", "t", "/x/out"))
        full = self.parsed("fullscreen-transition")
        self.assertEqual((full.app, full.out, full.story, full.gate), ("/x/cmux DEV t.app", "/x/out",
                                                                       "fullscreen-transition", False))
        for story_id, bench in (("cef-resize-sync", "light"), ("cef-resize-sync-stress", "stress")):
            cef = self.parsed(story_id)
            self.assertEqual((cef.benches, cef.modes), (bench, "off"))
            self.assertEqual(report.cef_resize_story(report.CEF_RESIZE_SESSIONS[cef.benches]), story_id)

    def test_layout_loop_keeps_its_positional_form(self):
        bench = load("bench_layout_loop_stress_live_060", HERE / "layout-loop-stress-live.py")
        opts = bench.parse(["t", "/x/cmux DEV t.app", "/x/out"])
        self.assertEqual((opts.tag, opts.app, opts.out), ("t", "/x/cmux DEV t.app", "/x/out"))
        for argv in ([], ["t", "/x/a.app"], ["t", "/x/a.app", "/x/out", "--out", "/y"]):
            with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
                bench.parse(argv)

    def test_cef_resize_refuses_an_unknown_bench(self):
        bench = load("bench_cef_resize_sync_bench_060", HERE / "cef-resize-sync-bench.py")
        with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
            bench.parse(["--benches", "heavy"] + self.RUNNER)

    def test_the_catalog_lints_the_new_stories_clean(self):
        catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py").load_catalog()
        self.assertLessEqual(set(STORY_SCRIPTS), {s.id for s in catalog.stories})
        self.assertEqual([p for p in catalog.problems if any(s in p for s in STORY_SCRIPTS)], [])


class RecordTests(unittest.TestCase):
    def test_cef_resize_sessions_round_trip_through_perf_result_and_ingest(self):
        """write_all (the bench with no app of its own): one file, each session its own run and story."""
        series = (report.cef_resize_series("on", "light", cef_runs(), valid=True)
                  + report.cef_resize_series("on", "stress", cef_runs(), valid=True))
        build = pr.Build(sha=SHA, config="bench", measure_version=2)
        run = pr.Run(id="run060", started_at="2026-10-26T12:00:00.000000Z")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            write_all(out, series, build, HOST, run=run, root=ROOT)
            back = pr.read_dir(out)
            self.assertEqual(sorted(r.metric for r in back), sorted(s.metric for s in series))
            db = store.Store(Path(tmp) / "lab.sqlite3")
            db.migrate()
            try:
                got = ingest.ingest_paths(db, [out], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
                self.assertEqual(got.rejected, [])
                self.assertIn("cef_resize_sync.on.1x2.split.commit_p95", db.run_metrics("run060/cef-resize-sync"))
                self.assertIn("cef_resize_sync.on.failed", db.run_metrics("run060.stress/cef-resize-sync-stress"))
            finally:
                db.close()


class LaunchTests(unittest.TestCase):
    """The full screen bench may activate and stays isolated; its cleanup always stops the app it started, also after
    a launch that raised; the layout stress passes LAYOUT_STRESS_APP_ARGS as launch arguments, never as defaults."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="drag-layout-launch-")
        self.app = Path(self.folder) / "cmux DEV fs-launch.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.fullscreen = load("fullscreen_transition", HERE / "fullscreen-transition.py")

    def tearDown(self):
        self.fullscreen.LAUNCHER = self.fullscreen.SOCKET = None

    def test_fullscreen_launch_may_activate_and_stays_isolated(self):
        bench = self.fullscreen.bench_app(str(self.app), self.folder)
        env = bench.environment()
        self.assertNotIn("CMUX_NEXT_NO_ACTIVATE", env)
        self.assertEqual(env.get("CMUX_NEXT_ISOLATED_LAUNCH"), "1")
        self.assertEqual(env.get("CMUX_NEXT_TEST_WINDOW_FRAME"), "80,80,1400,900")

    def fake_launcher(self, alive=True):
        stops = []

        class Process:
            def poll(self):
                return None if alive else 0

        class Launcher:
            process = Process()
            socket = str(Path(self.folder) / "nothing-listens.sock")

            def stop(self):
                stops.append(True)

        return Launcher(), stops

    def test_cleanup_after_a_launch_that_raised_stops_the_running_app(self):
        """launch() raised with the app alive and before measure() set SOCKET: cleanup reads the launcher's socket."""
        self.fullscreen.LAUNCHER, stops = self.fake_launcher()
        self.fullscreen.SOCKET = None
        self.fullscreen.cleanup()
        self.assertEqual(stops, [True])
        self.assertEqual(self.fullscreen.SOCKET, self.fullscreen.LAUNCHER.socket)

    def test_cleanup_stops_the_app_when_leaving_full_screen_fails(self):
        self.fullscreen.LAUNCHER, stops = self.fake_launcher()
        original = self.fullscreen.is_full
        self.fullscreen.is_full = lambda: (_ for _ in ()).throw(RuntimeError("no answer"))
        try:
            with self.assertRaises(RuntimeError):
                self.fullscreen.cleanup()
        finally:
            self.fullscreen.is_full = original
        self.assertEqual(stops, [True])

    def test_layout_stress_app_args_are_launch_arguments(self):
        stress = load("layout_loop_stress_live", HERE / "layout-loop-stress-live.py")
        words = ["-AppleShowScrollBars", "Always"]
        self.assertEqual(stress.app_args(words), words)
        self.assertEqual(stress.app_args([]), [])
        for bad in (["-AppleShowScrollBars"], ["AppleShowScrollBars", "Always"]):
            with self.assertRaises(SystemExit):
                stress.app_args(bad)
        source = (HERE / "layout-loop-stress-live.py").read_text()
        self.assertIn("args=app_args(", source)
        self.assertNotIn("defaults", source)


class BenchSourceTests(unittest.TestCase):
    """The four benches keep no private statistic, launch only through BenchApp and name p99 (MQ1, MQ2, MQ3)."""

    def test_no_private_stats_no_self_launch_and_p99(self):
        queues = load("perf_lab_queues", PERF_LAB / "queues.py")
        keys = {f"scripts/cmux-next/{name}" for name in BENCHES}
        for name, run in (("MQ1", queues.private_stats), ("MQ2", queues.self_launch), ("MQ3", queues.p95_without_p99)):
            self.assertEqual([i.key for i in run(str(ROOT)) if i.key in keys], [], name)

    def test_no_bench_uses_statistics_popen_or_open(self):
        for name in BENCHES:
            source = (HERE / name).read_text()
            self.assertNotIn("statistics.", source, name)
            self.assertNotIn("Popen(", source, name)
            self.assertNotIn('["open", "-n"', source, name)
            self.assertNotIn("Contents/MacOS", source, name)

    def test_every_bench_takes_app_tag_and_out_under_python_isolated(self):
        """The lab runner (task 008) passes --app, --tag and --out to a story command."""
        for name in BENCHES:
            done = subprocess.run([sys.executable, "-I", str(HERE / name), "--help"], capture_output=True, text=True,
                                  timeout=60)
            self.assertEqual(done.returncode, 0, f"{name}: {done.stderr[-400:]}")
            for flag in ("--app", "--tag", "--out"):
                self.assertIn(flag, done.stdout, f"{name} {flag}")


if __name__ == "__main__":
    unittest.main()
