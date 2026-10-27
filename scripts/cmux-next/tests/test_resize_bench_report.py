#!/usr/bin/env python3
"""The resize benches' statistics and result-v1 series (resize_bench_report.py, p12-perf-process-059): the perf_stats
percentiles against the private ones they replace, the report keys the benches kept, the names, engines and sessions
the lab stories claim, the failure counts, one run's series through perf_result and perf-lab ingest, and the bench
sources (no private stats, BenchApp launch, p99, the story's debug needs, refusals before any launch).

Runs on any host (Linux included): no app, no daemon, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_resize_bench_report.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = HERE.parent / "perf-lab"
STORIES = PERF_LAB / "stories.d"
sys.path.insert(0, str(HERE))
import resize_bench_report as report  # noqa: E402


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
SHA = "c" * 40
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="f" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)
# bench file -> its stories.
BENCHES = {
    "resize-frames-live.py": (report.WINDOW_STORY,),
    "bench-terminal-resize.py": (report.TERMINAL_STORY, report.TERMINAL_STRESS_STORY),
    "column-resize-live.py": (report.COLUMN_STORY,),
    "devtools-resize-live.py": (report.DEVTOOLS_STORY,),
}


# The private percentiles the benches had before the migration (R8: old and new on one fixed vector).
def old_resize_frames_pct(values, p):  # resize-frames-live.py pct
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))], 2) if ordered else None


def old_terminal_pick(values, q):  # bench-terminal-resize.py split_resize stats' pick
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * (len(ordered) - 1) + 0.5))]


def story(story_id):
    return json.loads((STORIES / f"{story_id}.json").read_text())


def claimed(doc, series):
    """The story metric that full-matches the series' name with its unit, or None."""
    return next((m for m in doc["metrics"] if re.fullmatch(m["name"], series.metric) and m["unit"] == series.unit),
                None)


def raw_frames():
    return {"intervals_ms": VECTOR, "main_ms": [1.0, 2.5, 0.5]}


def window_rounds():
    return [{"before": [80, 80, 1100, 720], "after": [80, 80, 1400, 870], "wall_s": 1.3},
            {"before": [80, 80, 1400, 870], "after": [80, 80, 1100, 720], "wall_s": 1.3}]


def terminal_layouts(session):
    drag = "light" if session == "light" else "stress"
    split = "split-resize" if session == "light" else "split-resize-stress"
    out = [{"layout": drag, "rounds": [
        {"frames": {"missed": 2}, "display": {"total_ms": 14.5}, "unsettled_after": []},
        {"frames": {"missed": 0}, "display": {"total_ms": 9.0}, "unsettled_after": [{"fit": [80, 24]}]}]},
        {"layout": split, "rounds": [
            {"problems": [], "terminals": [{"first_send_ms": 3.0, "final_send_ms": 40.0, "owner_final_ms": 42.0,
                                            "drawn_final_ms": None}]},
            {"problems": ["trace start replied {}"], "terminals": []}]}]
    if session == "light":
        out.insert(0, {"layout": "idle-cursor", "frames": 0, "frames_before": 4, "frames_after": 4})
    return out


def terminal_raw(session):
    drag = "light" if session == "light" else "stress"
    return {drag: [raw_frames(), {"intervals_ms": [8.3, 8.4], "main_ms": [3.0]}]}


def all_series():
    """{story: series} of one run of each bench."""
    steps = [{"pointer_x": 106, "edges_x": [104.5, 700.0]}, {"pointer_x": 112, "edges_x": []}]
    return {
        report.WINDOW_STORY: report.window_resize_series(report.WINDOW_STORY, raw_frames(), VECTOR, window_rounds(), 3),
        report.TERMINAL_STORY: report.terminal_resize_series(report.TERMINAL_STORY, "light", terminal_layouts("light"),
                                                             terminal_raw("light")),
        report.TERMINAL_STRESS_STORY: report.terminal_resize_series(
            report.TERMINAL_STRESS_STORY, "stress", terminal_layouts("stress"), terminal_raw("stress")),
        report.COLUMN_STORY: report.column_resize_series(report.COLUMN_STORY, steps),
        report.DEVTOOLS_STORY: report.devtools_resize_series(report.DEVTOOLS_STORY, "synthesized", [2.0, 30.5],
                                                             ["a drag in the second tab resizes"]),
    }


class PercentileTests(unittest.TestCase):
    def test_fixed_vector_old_private_percentiles_and_the_perf_stats_ones(self):
        # resize-frames-live.py: p50 6.0 -> 6.95, p95 20.1 -> 16.63, p99 20.1 -> 19.41.
        self.assertEqual([old_resize_frames_pct(VECTOR, q) for q in (0.5, 0.95, 0.99)], [6.0, 20.1, 20.1])
        # bench-terminal-resize.py split-resize: p50 7.9 -> 6.95, p95 20.1 -> 16.63; p99 new.
        self.assertEqual([old_terminal_pick(VECTOR, q) for q in (0.5, 0.95)], [7.9, 20.1])
        self.assertEqual([report.pct(VECTOR, q) for q in (0.5, 0.95, 0.99)], [6.95, 16.63, 19.41])

    def test_pct_is_perf_stats_pct_and_none_when_empty(self):
        self.assertEqual(report.pct(VECTOR, 0.95, digits=6), round(report.perf_stats.pct(VECTOR, 0.95), 6))
        self.assertIsNone(report.pct([], 0.5))
        self.assertIsNone(report.pct([None, True], 0.5))

    def test_event_rpc_block_keeps_its_keys(self):
        self.assertEqual(report.event_rpc_block(VECTOR), {"p50": 6.95, "p95": 16.63, "p99": 19.41, "max": 20.1})
        self.assertEqual(report.event_rpc_block([]), {"p50": None, "p95": None, "p99": None, "max": None})

    def test_split_resize_block_keeps_its_keys_and_adds_p99(self):
        self.assertEqual(report.spread(VECTOR + [None]), {"n": 10, "p50": 6.95, "p95": 16.63, "p99": 19.41, "max": 20.1})
        self.assertIsNone(report.spread([None]))

    def test_raw_frames_leave_the_report_summary(self):
        reply = {"frames": 3, "p95_ms": 9.0, "missed": 1, "intervals_ms": [8.0, 9.0, 25.0], "main_ms": [1.0, 2.0, 3.0],
                 "view_layouts_per_frame": [0, 1, 0], "frame_sets_per_frame": [1, 1, 1], "frame_sets": 3}
        summary, raw = report.split_raw_frames(reply)
        self.assertEqual(summary, {"frames": 3, "p95_ms": 9.0, "missed": 1, "frame_sets": 3})
        self.assertEqual(raw, {"intervals_ms": [8.0, 9.0, 25.0], "main_ms": [1.0, 2.0, 3.0]})
        self.assertEqual(report.split_raw_frames({"error": "closed"}), ({"error": "closed"},
                                                                       {"intervals_ms": [], "main_ms": []}))
        self.assertEqual(report.split_raw_frames(None), ({}, {"intervals_ms": [], "main_ms": []}))


class SeriesTests(unittest.TestCase):
    def metrics(self, series):
        return {s.metric: s.samples for s in series}

    def test_window_series_and_its_failure_count(self):
        got = self.metrics(all_series()[report.WINDOW_STORY])
        self.assertEqual(got["window_resize.frame_interval"], VECTOR)
        self.assertEqual(got["window_resize.missed"], [3])
        self.assertEqual(got["window_resize.not_resized"], [0])
        stuck = [{"before": [0, 0, 1100, 720], "after": [0, 0, 1100, 720]}, {"before": None, "after": None}]
        self.assertEqual(self.metrics(report.window_resize_series("s", {}, [], stuck, None))["window_resize.not_resized"],
                         [2])
        nothing = self.metrics(report.window_resize_series("s", {}, [], [], None))
        self.assertEqual(nothing, {"window_resize.not_resized": [1]})  # no round ran: a failure, never a gap

    def test_terminal_series_pool_rounds_and_count_failures(self):
        got = self.metrics(all_series()[report.TERMINAL_STORY])
        self.assertEqual(got["terminal_resize.light.frame_interval"], VECTOR + [8.3, 8.4])
        self.assertEqual(got["terminal_resize.light.main_busy"], [1.0, 2.5, 0.5, 3.0])
        self.assertEqual(got["terminal_resize.light.display_main"], [14.5, 9.0])
        self.assertEqual(got["terminal_resize.light.missed"], [2, 0])
        self.assertEqual(got["terminal_resize.light.unsettled"], [0, 1])
        self.assertEqual(got["terminal_resize.light.failed"], [0])
        self.assertEqual(got["terminal_resize.idle_cursor.frames"], [0])
        self.assertEqual(got["terminal_split_resize.light.key_to_final_grid_sent"], [40.0])
        self.assertNotIn("terminal_split_resize.light.key_to_first_frame_at_final_grid", got)  # no sample
        self.assertEqual(got["terminal_split_resize.light.problems"], [1])
        broken = [{"layout": "light", "error": "no vertical divider"}, {"layout": "idle-cursor", "error": "no counter"},
                  {"layout": "split-resize", "rounds": []}]
        got = self.metrics(report.terminal_resize_series("s", "light", broken, {}))
        self.assertEqual(got, {"terminal_resize.light.failed": [1], "terminal_resize.idle_cursor.failed": [1],
                               "terminal_split_resize.light.problems": [1]})

    def test_terminal_series_keep_only_the_runs_session(self):
        mixed = terminal_layouts("light") + terminal_layouts("stress")
        light = report.terminal_resize_series("s", "light", mixed, {**terminal_raw("light"), **terminal_raw("stress")})
        self.assertTrue(light)
        self.assertFalse([s for s in light if "stress" in s.metric or s.session != "light"])

    def test_terminal_session_is_one_session(self):
        self.assertEqual(report.terminal_session(["idle-cursor", "light", "split-resize"]), "light")
        self.assertEqual(report.terminal_session(["stress", "split-resize-stress"]), "stress")
        with self.assertRaisesRegex(ValueError, "sessions light and stress"):
            report.terminal_session(["light", "stress"])  # the default --layouts: no --story run
        with self.assertRaisesRegex(ValueError, "unknown layout zoom"):
            report.terminal_session(["zoom"])
        with self.assertRaises(ValueError):
            report.terminal_session([])

    def test_column_edge_lag_and_failed_steps(self):
        got = self.metrics(all_series()[report.COLUMN_STORY])
        self.assertEqual(got, {"column_resize.edge_lag": [1.5], "column_resize.failed_steps": [1]})
        self.assertEqual(self.metrics(report.column_resize_series("s", [], no_divider=True)),
                         {"column_resize.failed_steps": [1]})

    def test_devtools_drag_error_and_failed_checks(self):
        got = self.metrics(all_series()[report.DEVTOOLS_STORY])
        self.assertEqual(got, {"devtools_resize.synthesized.drag_error": [2.0, 30.5],
                               "devtools_resize.synthesized.failed_checks": [1]})


class StoryTests(unittest.TestCase):
    def test_every_series_is_claimed_by_its_story_with_its_engine_and_session(self):
        for story_id, series in all_series().items():
            doc = story(story_id)
            self.assertTrue(series, story_id)
            for s in series:
                self.assertEqual(s.story, story_id)
                self.assertEqual((s.engine, s.session), (doc["engine"], doc["session"]), f"{story_id} {s.metric}")
                self.assertIsNotNone(claimed(doc, s), f"{story_id} claims no metric {s.metric} ({s.unit})")

    def test_story_commands_name_their_bench_and_their_story(self):
        for bench, story_ids in BENCHES.items():
            for story_id in story_ids:
                command = story(story_id)["command"]
                self.assertEqual(command[0], f"scripts/cmux-next/{bench}")
                self.assertEqual(command[command.index("--story") + 1], story_id)
        for story_id in (report.TERMINAL_STORY, report.TERMINAL_STRESS_STORY):
            command = story(story_id)["command"]
            layouts = command[command.index("--layouts") + 1].split(",")
            self.assertEqual(report.terminal_session(layouts), story(story_id)["session"])

    def test_story_problem_checks_engine_and_session(self):
        self.assertIsNone(report.story_problem(report.TERMINAL_STORY, "none", "light"))
        self.assertIn("session 'light'", report.story_problem(report.TERMINAL_STORY, "none", "stress"))
        self.assertIn("engine 'webkit'", report.story_problem(report.WINDOW_STORY, "chromium", "light"))
        self.assertIn("not in scripts/perf-lab/stories.d", report.story_problem("no-such-story", "none", "light"))

    def test_the_catalog_lints_the_new_stories_clean(self):
        catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py").load_catalog()
        new = {story_id for ids in BENCHES.values() for story_id in ids}
        self.assertLessEqual(new, {s.id for s in catalog.stories})
        self.assertEqual([p for p in catalog.problems if any(story_id in p for story_id in new)], [])

    def test_story_needs_cover_every_debug_method_the_bench_calls(self):
        stress_session = (HERE / "perf-stress-session.py").read_text()
        for bench, story_ids in BENCHES.items():
            source = (HERE / bench).read_text()
            for story_id in story_ids:
                called = set(re.findall(r'rpc\("(debug\.[a-z_.]+)"', source))
                if story(story_id)["session"] == "stress":
                    called |= set(re.findall(r'"(debug\.[a-z_.]+)"', stress_session))
                needs = {n.removeprefix("debug:") for n in story(story_id)["needs"]}
                self.assertLessEqual(called - {"debug.windows", "debug.quit"}, needs, f"{story_id}: {bench}")


class AppLookupTests(unittest.TestCase):
    def test_tagged_app_prefers_app_then_the_newest_build_of_the_tag(self):
        self.assertEqual(report.tagged_app("/x/cmux DEV t.app/", "t"), "/x/cmux DEV t.app")
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(report.tagged_app(None, "t", derived_data=tmp))
            self.assertIsNone(report.tagged_app(None, None, derived_data=tmp))
            old = Path(tmp, "cmux-t", "Build", "Products", "Debug", "cmux DEV t.app")
            new = Path(tmp, "cmux-u", "Build", "Products", "Release", "cmux DEV t.app")
            other = Path(tmp, "cmux-v", "Build", "Products", "Debug", "cmux DEV t2.app")
            for index, path in enumerate((old, new, other)):
                path.mkdir(parents=True)
                os.utime(path, (time.time() + index, time.time() + index))
            self.assertEqual(report.tagged_app(None, "t", derived_data=tmp), str(new))


class RecordTests(unittest.TestCase):
    class Bench:
        perf_session = "light"
        run = None

        def __init__(self, refuse=()):
            self.refuse, self.calls = refuse, []

        def record(self, story_id, metric, unit, samples, better, engine, target_ref=None):
            self.calls.append((story_id, metric, self.perf_session, engine, better))
            if metric in self.refuse:
                raise report.perf_result.ResultError("no build sha")
            return f"/out/{metric}.ndjson"

    def test_record_writes_each_series_under_its_engine_and_session(self):
        bench = self.Bench()
        with redirect_stdout(io.StringIO()) as printed:
            problems = report.record(bench, all_series()[report.TERMINAL_STRESS_STORY])
        self.assertEqual(problems, [])
        self.assertEqual({c[2:] for c in bench.calls}, {("stress", "none", "lower")})
        self.assertIn("result-v1 terminal-resize-stress/terminal_resize.stress.frame_interval: /out/", printed.getvalue())

    def test_a_series_not_recorded_or_no_series_is_a_problem(self):
        bench = self.Bench(refuse={"column_resize.edge_lag"})
        with redirect_stdout(io.StringIO()):
            problems = report.record(bench, all_series()[report.COLUMN_STORY])
        self.assertEqual(len(problems), 1)
        self.assertIn("column_resize.edge_lag: not recorded: no build sha", problems[0])
        self.assertEqual(report.record(self.Bench(), []), ["no series to record"])

    def test_series_round_trip_through_perf_result_and_ingest(self):
        run = pr.Run(id="run059", started_at="2026-10-26T12:00:00.000000Z")
        build = pr.Build(sha=SHA, config="bench", measure_version=2)
        with tempfile.TemporaryDirectory() as tmp:
            db = store.Store(Path(tmp) / "lab.sqlite3")
            db.migrate()
            try:
                for index, (story_id, series) in enumerate(all_series().items()):
                    results = [pr.Result(story=s.story, metric=s.metric, unit=s.unit, better="lower",
                                         samples=s.samples, build=build, host=HOST, engine=s.engine,
                                         session=s.session, run=run) for s in series]
                    out = Path(tmp) / f"results-{index}"
                    pr.write_ndjson(out, results, repo_root=ROOT)
                    self.assertEqual(sorted(r.metric for r in pr.read_dir(out)), sorted(s.metric for s in series))
                    got = ingest.ingest_paths(db, [out],
                                              commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
                    self.assertEqual(got.rejected, [], story_id)
                    self.assertLessEqual({s.metric for s in series}, set(db.run_metrics(f"run059/{story_id}")))
            finally:
                db.close()


class BenchSourceTests(unittest.TestCase):
    """The four benches keep no private percentile, launch only through BenchApp and name p99 (MQ1, MQ2, MQ3)."""

    def test_no_private_stats_no_self_launch_and_p99(self):
        queues = load("perf_lab_queues", PERF_LAB / "queues.py")
        keys = {f"scripts/cmux-next/{name}" for name in BENCHES} | {"scripts/cmux-next/resize_bench_report.py"}
        for name, run in (("MQ1", queues.private_stats), ("MQ2", queues.self_launch), ("MQ3", queues.p95_without_p99),
                          ("MQ-B", queues.bench_migration)):
            self.assertEqual([i.key for i in run(str(ROOT)) if i.key in keys], [], name)

    def test_benches_launch_through_bench_app_and_never_spawn_the_binary(self):
        for name in BENCHES:
            source = (HERE / name).read_text()
            self.assertIn("BenchApp(", source, name)
            self.assertIn("bench.stop()", source, name)
            for banned in ("Contents/MacOS", "subprocess.Popen([BINARY", "TagTeardown(", "socket.socket("):
                self.assertNotIn(banned, source, f"{name}: {banned}")
            self.assertNotRegex(source, r"\bimport statistics\b|\bstatistics\.[a-z]", name)

    def test_result_v1_is_written_after_the_stop_and_only_with_a_story(self):
        for name in BENCHES:
            source = (HERE / name).read_text()
            body = source[source.index("def main(argv=None):"):]
            self.assertLess(body.index("bench.stop()"), body.index("results.record("), name)
            self.assertIn("opts.story", body[:body.index("results.record(") + 200], name)

    def test_every_bench_takes_app_tag_out_and_story_under_python_isolated(self):
        """The lab runner (task 008) passes --app, --tag and --out to a story command."""
        for name in BENCHES:
            done = subprocess.run([sys.executable, "-I", str(HERE / name), "--help"], capture_output=True, text=True,
                                  timeout=60)
            self.assertEqual(done.returncode, 0, f"{name}: {done.stderr[-400:]}")
            for flag in ("--app", "--tag", "--out", "--story"):
                self.assertIn(flag, done.stdout, f"{name} {flag}")

    def test_a_story_of_another_engine_or_session_is_refused_before_any_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp, "cmux DEV t.app")
            app.mkdir()
            cases = (("resize-frames-live.py", ["--story", report.DEVTOOLS_STORY], "engine 'chromium'"),
                     ("column-resize-live.py", ["--story", report.TERMINAL_STORY], "engine 'none'"),
                     ("devtools-resize-live.py", ["--background", "--story", report.WINDOW_STORY], "engine 'webkit'"),
                     ("bench-terminal-resize.py", ["--story", report.TERMINAL_STORY],
                      "sessions light and stress"),
                     ("bench-terminal-resize.py", ["--layouts", "stress", "--story", report.TERMINAL_STORY],
                      "session 'light'"))
            for name, args, why in cases:
                done = subprocess.run([sys.executable, "-I", str(HERE / name), "--app", str(app), "--out", tmp, *args],
                                      capture_output=True, text=True, timeout=60)
                self.assertEqual(done.returncode, 2, f"{name} {args}: {done.stdout[-300:]} {done.stderr[-300:]}")
                self.assertIn(why, done.stderr, name)
                self.assertNotIn("bench-launch:", done.stdout + done.stderr, name)

    def test_devtools_story_needs_the_background_drag_and_is_refused_before_any_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp, "cmux DEV t.app")
            app.mkdir()
            done = subprocess.run([sys.executable, "-I", str(HERE / "devtools-resize-live.py"), "--app", str(app),
                                   "--out", tmp, "--story", report.DEVTOOLS_STORY], capture_output=True, text=True,
                                  timeout=60)
            self.assertEqual(done.returncode, 2, done.stdout[-300:] + done.stderr[-300:])
            self.assertIn("measures the --background drag", done.stderr)
            self.assertNotIn("bench-launch:", done.stdout + done.stderr)

    def test_the_report_module_imports_under_python_isolated(self):
        code = ("import runpy, sys; m = runpy.run_path(sys.argv[1]); "
                "print(m['pct']([1.0, 2.0, 3.0], 0.5), m['record_all'].__name__)")
        done = subprocess.run([sys.executable, "-I", "-c", code, str(HERE / "resize_bench_report.py")],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr[-600:])
        self.assertEqual(done.stdout.split(), ["2.0", "record_all"])


class DevtoolsLaunchTests(unittest.TestCase):
    """devtools-resize-live.py's real-mouse launch may activate and stays isolated (LaunchIsolation)."""

    def test_real_mode_may_activate_and_is_an_isolated_launch(self):
        devtools = load("devtools_resize_live", HERE / "devtools-resize-live.py")
        launch = load("bench_launch", HERE / "bench_launch.py")
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp, "cmux DEV t.app")
            app.mkdir()
            for background, no_activate, isolated in ((False, None, "1"), (True, "1", None)):
                env = launch.BenchApp(str(app), out=tmp, env=devtools.launch_env(background), window=devtools.WINDOW,
                                      screen="last", teardown=False).environment()
                self.assertEqual(env.get("CMUX_NEXT_NO_ACTIVATE"), no_activate, background)
                self.assertEqual(env.get(launch.ISOLATED_LAUNCH_KEY), isolated, background)
                self.assertEqual(env.get("CMUX_NEXT_TEST_WINDOW_FRAME"), "40,40,1200,800", background)


class TerminalStressStoryTests(unittest.TestCase):
    """terminal-resize-stress runs its STRESS layouts in one launch: the session is built once and shared."""

    def test_the_story_layouts_build_stress_once_in_one_app(self):
        bench = load("bench_terminal_resize", HERE / "bench-terminal-resize.py")
        command = story(report.TERMINAL_STRESS_STORY)["command"]
        layouts = command[command.index("--layouts") + 1].split(",")
        builds = []

        class StressShapeError(Exception):
            pass

        class FakeStress:
            """perf-stress-session.Stress's workspace check on an app whose workspaces persist between builds."""
            workspaces = 1

            def __init__(self, rpc):
                pass

            def build(self):
                if FakeStress.workspaces > 59:
                    raise StressShapeError(f"the app already has {FakeStress.workspaces} workspaces")
                FakeStress.workspaces = 60
                builds.append(1)
                return {"workspaces": 60, "busy_terminals": 10}

        class Clock:
            monotonic = staticmethod(time.monotonic)

            @staticmethod
            def sleep(_seconds):
                pass

        saved = {k: getattr(bench, k) for k in ("load_stress", "measure", "write", "final_grid_round", "time", "opts")}
        try:
            bench.STRESS.clear()
            bench.load_stress = lambda: type("Module", (), {"Stress": FakeStress})
            bench.measure = lambda name: {"layout": name}
            bench.write = lambda text: None
            bench.final_grid_round = lambda action: {"action": action, "terminals": []}
            bench.time = Clock
            bench.opts = type("Opts", (), {"rounds": 1})
            results = [bench.LAYOUTS[name]() for name in layouts]
        finally:
            for key, value in saved.items():
                setattr(bench, key, value)
            bench.STRESS.clear()
        self.assertEqual(len(builds), 1)
        self.assertEqual([r["layout"] for r in results], layouts)
        self.assertEqual([r["session"]["workspaces"] for r in results], [60, 60])


if __name__ == "__main__":
    unittest.main()
