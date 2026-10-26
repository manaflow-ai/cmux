#!/usr/bin/env python3
"""bench_memory.py --hidden-slope (p12-perf-process-035): the footprint of the app and every process it owns at two
counts of hidden terminal+<engine> workspaces after the hibernation grace, the slope between them, and its
cmux-perf-result/v1 files (memory.hidden_slope against target row memory-slope.<engine>, every sample stored). Runs on
any OS: the app socket, the process table and proc_pid_rusage are fakes; record() goes through the real BenchApp and
perf_result. Local only: python3 -I scripts/cmux-next/tests/test_bench_memory_slope.py"""

from __future__ import annotations

import contextlib
import io
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
import bench_launch as bl  # noqa: E402
import bench_memory as bm  # noqa: E402

MB = 1048576
BUNDLE = "/tmp/cmux DEV slope.app"
STORIES = ROOT / "scripts" / "perf-lab" / "stories.d"


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def time(self):
        return 1_700_000_000 + self.now


class FakeApp:
    """The control socket: debug.surfaces' hibernation summary (`hibernation`, None for a build without it)."""

    def __init__(self, hibernation=None):
        self.hibernation = hibernation
        self.ran: list[tuple[str, float]] = []
        self.clock = None

    def call(self, method, params=None, label=None, timeout=120):
        if method == "debug.surfaces" and self.hibernation is not None:
            return {"hibernation": self.hibernation}
        return {"error": json.dumps({"code": "method_not_found"})}

    def run(self, action, target=None, **args):
        self.ran.append((action, self.clock.now if self.clock else 0.0))
        return {}


def quiet(call, *args, **kwargs):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return call(*args, **kwargs)


class SlopeMathTests(unittest.TestCase):
    def test_slope_is_the_footprint_difference_per_added_workspace_one_per_sample_pair(self):
        low = [400 * MB, 402 * MB, 401 * MB]
        high = [425 * MB, 427 * MB, 420 * MB]
        self.assertEqual(bm.slope_samples(low, high, 10, 60), [0.5 * MB, 0.5 * MB, 0.38 * MB])

    def test_grace_is_the_timeout_plus_the_planners_normal_pace(self):
        # HibernationPlanner.normalPace: 2 pages per pass, a pass every 5 s.
        self.assertEqual(bm.hibernation_grace(1.0, 10), 60 + 5 * 5)
        self.assertEqual(bm.hibernation_grace(1.0, 60), 60 + 30 * 5)
        self.assertEqual(bm.hibernation_grace(0.5, 3), 30 + 2 * 5)
        self.assertEqual(bm.hibernation_grace(None, 60), 0.0)

    def test_hibernation_minutes_read_the_setting_as_debug_surfaces_reports_it(self):
        self.assertEqual(bm.hibernation_minutes(1), 1.0)
        self.assertEqual(bm.hibernation_minutes(0.5), 0.5)
        self.assertEqual(bm.hibernation_minutes("moderate"), 30.0)
        self.assertEqual(bm.hibernation_minutes("aggressive"), 10.0)
        self.assertIsNone(bm.hibernation_minutes("off"))
        self.assertIsNone(bm.hibernation_minutes(True))

    def test_the_app_report_wins_then_the_configured_minutes_then_the_default(self):
        self.assertEqual(bm.slope_hibernation_minutes({"mode": "aggressive"}, 1.0), 10.0)
        self.assertIsNone(bm.slope_hibernation_minutes({"mode": "off"}, 1.0))
        self.assertEqual(bm.slope_hibernation_minutes({}, 1.0), 1.0)
        self.assertEqual(bm.slope_hibernation_minutes({}, None), 30.0)


def total(footprint):
    """A bench_memory.sample-shaped result with one app process of `footprint` bytes."""
    return {"total_footprint_bytes": footprint, "kinds": {"app": {"footprint_mb": footprint / MB}}}


class PhaseTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.saved = (bm.time, bm.open_workspace)
        bm.time = self.clock
        self.opened_with = []

        def open_workspace(app, recipe, url, index, chats=None):
            self.opened_with.append((recipe, url))
            return f"ws_{index}"

        bm.open_workspace = open_workspace

    def tearDown(self):
        bm.time, bm.open_workspace = self.saved

    def run_phase(self, footprints, hibernation=None, samples=3):
        app = FakeApp(hibernation)
        app.clock = self.clock
        taken, opened = [], []

        def take(label, workspaces):
            taken.append((label, workspaces, self.clock.now))
            return total(footprints[label])

        phase = quiet(bm.hidden_slope_phase, app, "terminal+chromium", [10, 60], samples, 10.0,
                      lambda pages: bm.hibernation_grace(1.0, pages), 30.0, take,
                      [f"http://site{i}.localhost/" for i in range(60)], opened)
        return app, phase, taken, opened

    def test_samples_each_count_after_its_grace_and_stores_every_sample(self):
        footprints = {f"slope-10-{i}": (400 + i) * MB for i in (1, 2, 3)}
        footprints.update({f"slope-60-{i}": (425 + i) * MB for i in (1, 2, 3)})
        app, phase, taken, opened = self.run_phase(footprints, {"mode": 1, "hibernated": ["a"] * 60})
        self.assertEqual(len(opened), 60)
        self.assertEqual(len({url for _, url in self.opened_with}), 60, "each workspace its own site")
        self.assertTrue(all(recipe == "terminal+chromium" for recipe, _ in self.opened_with))
        # All hidden: the launch workspace shown again before each count's grace starts.
        self.assertEqual([action for action, _ in app.ran], ["workspace.selectFirst"] * 2)
        first_hidden = app.ran[0][1]
        self.assertEqual([t for _, _, t in taken[:3]],
                         [first_hidden + 85 + 30, first_hidden + 125, first_hidden + 135])
        second_hidden = app.ran[1][1]
        self.assertEqual(taken[3][2], second_hidden + 210 + 30)
        self.assertEqual([(label, ws) for label, ws, _ in taken],
                         [("slope-10-1", 11), ("slope-10-2", 11), ("slope-10-3", 11),
                          ("slope-60-1", 61), ("slope-60-2", 61), ("slope-60-3", 61)])
        self.assertEqual(phase["counts"]["10"]["footprint_bytes"], [401 * MB, 402 * MB, 403 * MB])
        self.assertEqual(phase["counts"]["60"]["footprint_bytes"], [426 * MB, 427 * MB, 428 * MB])
        self.assertEqual(phase["slope_bytes"], [0.5 * MB] * 3)
        self.assertEqual(phase["slope_summary"]["p50"], 0.5 * MB)
        self.assertEqual(phase["counts"]["60"]["hibernation"]["hibernated"], 60)

    def test_a_count_it_cannot_reach_records_no_slope(self):
        bm.open_workspace = lambda app, recipe, url, index, chats=None: None if index >= 3005 else f"ws_{index}"
        app, phase, taken, opened = self.run_phase({})
        self.assertEqual(phase["error"], "opened 5 of 10 workspaces")
        self.assertNotIn("slope_bytes", phase)
        self.assertEqual(taken, [])


class SampleTests(unittest.TestCase):
    """The total is phys_footprint of the app, its bundle processes, the terminal hosts and holders its daemons
    started (they run from a copy outside the bundle) and its WebKit processes; never RSS."""

    def setUp(self):
        self.saved = (bm.process_table, bm.usage, bm._responsible, bm._foreign_webkit)

    def tearDown(self):
        bm.process_table, bm.usage, bm._responsible, bm._foreign_webkit = self.saved
        bm._run_pids.clear()

    def test_footprint_of_every_owned_process_and_not_rss(self):
        host_copy = "/Users/b/Library/Application Support/cmux-tui/host-exe/ab12"
        rows = [
            (100, 1, f"{BUNDLE}/Contents/MacOS/cmux DEV"),
            (101, 1, f"{BUNDLE}/Contents/Resources/bin/cmux-tui --session main server run"),
            (102, 100, f"{BUNDLE}/Contents/Frameworks/cmux DEV Helper (Renderer).app/Contents/MacOS/x --type=renderer"),
            (103, 1, f"{host_copy}/cmux-tui-host __terminal-host --bootstrap-stdio --owner com.x:slope@101"),
            # The standalone holder runs with argv0 `cmux-holder` (holder_runtime/service.rs launch).
            (104, 1, "cmux-holder --socket /tmp/cmux-hd-501/1.sock --owner com.x:slope@101"),
            (105, 1, f"{host_copy}/cmux-tui-host __holder --socket /tmp/cmux-hd-501/2.sock --owner com.x:slope@101"),
            (106, 1, f"{host_copy}/cmux-tui-host __terminal-host --owner com.x:other@999"),
            (107, 1, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/x"),
            (108, 1, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/x"),
            (109, 1, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.Networking.xpc/x"),
        ]
        bm.process_table = lambda: rows
        # The app is a child of the bench: macOS holds the bench's launcher (pid 50) responsible for it and for the
        # WebKit processes it starts. 108 ran before the launch; 109 belongs to another app.
        responsible = {100: 50, 107: 50, 108: 50, 109: 77}
        bm._responsible = lambda pid: responsible.get(pid, pid)
        bm._foreign_webkit = {108}
        bm.usage = lambda pid: (pid * 1000 * MB, pid * MB, pid * MB, 0, 0)
        result = bm.sample(100, BUNDLE, "x", 1)
        kinds = {row["pid"]: row["kind"] for row in result["processes"]}
        self.assertEqual(kinds, {100: "app", 101: "tui-daemon", 102: "cef-renderer", 103: "terminal-host",
                                 104: "terminal-holder", 105: "terminal-holder", 107: "webkit-webcontent"})
        self.assertEqual(result["total_footprint_bytes"], sum(pid * MB for pid in kinds))

    def test_an_app_responsible_for_its_webkit_processes_needs_no_launch_record(self):
        rows = [(100, 1, f"{BUNDLE}/Contents/MacOS/cmux DEV"),
                (107, 1, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/x"),
                (108, 1, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/x")]
        bm.process_table = lambda: rows
        bm._responsible = lambda pid: {107: 100, 108: 1}.get(pid, pid)
        bm._foreign_webkit = None
        self.assertEqual(set(bm.owned(100, BUNDLE)), {100, 107})


def stamped_bundle(folder):
    """A `cmux DEV slope.app` as `reload.sh --config bench` stages it (BenchApp.record reads its config)."""
    app = os.path.join(folder, "cmux DEV slope.app")
    if os.path.isdir(app):
        return app
    os.makedirs(os.path.join(app, "Contents/MacOS"))
    with open(os.path.join(app, "Contents/Info.plist"), "wb") as out:
        plistlib.dump({"CFBundleExecutable": "cmux DEV", "CMUXBuildConfiguration": "bench"}, out)
    with open(os.path.join(app, "Contents/MacOS/cmux DEV"), "wb") as out:
        out.write(b"\xcf\xfa\xed\xfe" + b"\0" * 256 + bl.BENCH_HOOKS_MARKER + b"\0" * 16)
    return app


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.saved_sha = os.environ.get("CMUX_CI_SHA")
        os.environ["CMUX_CI_SHA"] = "a" * 40

    def tearDown(self):
        if self.saved_sha is None:
            os.environ.pop("CMUX_CI_SHA")
        else:
            os.environ["CMUX_CI_SHA"] = self.saved_sha

    def bench(self, folder):
        host = {"fingerprint": "0" * 64, "class": "apple-m4-16gb-120hz", "chip": "Apple M4", "macos": "26.0",
                "macos_build": "25A100", "display_hz": 120}
        bench = bl.BenchApp(stamped_bundle(folder), out=os.path.join(folder, "out"), teardown=False,
                            host=lambda: host)
        bench.features = ({"memory.discard.parkedWorkspaces": {"state": "off", "source": "default"}}, "abc", "off")
        return bench

    def test_slope_and_each_counts_footprint_are_valid_result_v1_with_every_sample(self):
        phase = {"slope_bytes": [0.5 * MB, 0.48 * MB, 0.52 * MB],
                 "counts": {"10": {"footprint_bytes": [400 * MB, 401 * MB, 399 * MB]},
                            "60": {"footprint_bytes": [425 * MB, 425 * MB, 425 * MB]}}}
        with tempfile.TemporaryDirectory() as folder:
            for engine in ("chromium", "webkit"):
                written = bm.record_slope(self.bench(folder), bm.SLOPE_STORIES[engine], engine, phase)
                self.assertFalse([o for o in written.values() if o.startswith("not recorded")], written)
            results = bm.perf_result.read_dir(os.path.join(folder, "out"))
        by = {(r.engine, r.metric): r for r in results}
        self.assertEqual(len(by), 6)
        for engine, story in (("chromium", "memory-hidden"), ("webkit", "memory-hidden-webkit")):
            slope = by[(engine, "memory.hidden_slope")]
            self.assertEqual((slope.story, slope.unit, slope.better, slope.target_ref.target, slope.build.config),
                             (story, "bytes", "lower", f"memory-slope.{engine}", "bench"))
            self.assertEqual(slope.samples, phase["slope_bytes"])
            self.assertEqual(by[(engine, "memory.hidden_footprint.10")].samples, [400 * MB, 401 * MB, 399 * MB])
            self.assertIsNone(by[(engine, "memory.hidden_footprint.60")].target_ref)

    def test_a_phase_without_samples_writes_nothing_and_says_why(self):
        with tempfile.TemporaryDirectory() as folder:
            written = bm.record_slope(self.bench(folder), "memory-hidden", "chromium",
                                      {"error": "opened 5 of 10 workspaces", "counts": {}})
            self.assertEqual(written, {"memory.hidden_slope": "not recorded: opened 5 of 10 workspaces"})
            self.assertFalse(os.path.exists(os.path.join(folder, "out")) and os.listdir(os.path.join(folder, "out")))


class CommandLineTests(unittest.TestCase):
    BASE = ["--app", BUNDLE]

    def parse(self, *argv):
        return bm.parse_args(list(argv) + self.BASE)

    def refused(self, *argv):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            self.parse(*argv)
        return raised.exception.code

    def test_defaults_are_the_spec_counts_and_samples(self):
        args, counts = self.parse("--hidden-slope")
        self.assertEqual((counts, args.slope_samples, args.engine), ([10, 60], 3, "chromium"))
        self.assertEqual(self.parse("--hidden-slope", "--slope-counts", "60,10")[1], [10, 60])
        self.assertEqual(self.parse("--workspaces", "1,10")[1], [])

    def test_combinations_a_run_cannot_honor_are_refused(self):
        for argv in (("--hidden-slope", "--slope-counts", "10"), ("--hidden-slope", "--slope-counts", "10,10"),
                     ("--hidden-slope", "--slope-counts", "0,60"), ("--hidden-slope", "--tabs", "1,10"),
                     ("--hidden-slope", "--slope-samples", "0"), ("--hidden-slope", "--slope-counts", "a,b"),
                     ("--hibernate-after", "1", "--socket", "/tmp/s", "--app-pid", "1"),
                     ("--hibernate-after", "0"), ("--grace", "10")):
            with self.subTest(argv=argv):
                self.assertEqual(self.refused(*argv), 2)

    def test_attach_mode_stays(self):
        args, _ = self.parse("--hidden-slope", "--socket", "/tmp/s", "--app-pid", "42", "--grace", "120")
        self.assertEqual((args.socket, args.app_pid, args.grace), ("/tmp/s", 42, 120.0))

    def test_out_is_a_results_folder_or_the_older_report_file(self):
        self.assertEqual(bm.out_paths(None), (None, None))
        self.assertEqual(bm.out_paths("/tmp/memory.json"), ("/tmp/memory.json", None))
        with tempfile.TemporaryDirectory() as folder:
            out = os.path.join(folder, "results")
            self.assertEqual(bm.out_paths(out), (os.path.join(out, "bench-memory.json"), out))
            self.assertTrue(os.path.isdir(out))


class StoryTests(unittest.TestCase):
    """Each engine's story runs this bench, and its metrics are the ones record_slope writes."""

    def test_both_engine_stories_run_the_slope_and_list_its_metrics(self):
        for engine, story_id in bm.SLOPE_STORIES.items():
            with self.subTest(engine=engine):
                story = json.loads((STORIES / f"{story_id}.json").read_text())
                self.assertEqual((story["id"], story["engine"]), (story_id, engine))
                self.assertEqual(story["command"][0], "scripts/cmux-next/bench_memory.py")
                args, counts = bm.parse_args(story["command"][1:] + ["--app", BUNDLE, "--out", "/tmp/out"])
                self.assertTrue(args.hidden_slope)
                self.assertEqual((args.engine, counts, args.slope_samples, args.story), (engine, [10, 60], 3, None))
                written = [bm.SLOPE_METRIC] + [f"memory.hidden_footprint.{count}" for count in counts]
                patterns = [metric["name"] for metric in story["metrics"]]
                for metric in written:
                    self.assertTrue(any(re.fullmatch(p, metric) for p in patterns), metric)
                for pattern in patterns:
                    self.assertTrue(any(re.fullmatch(pattern, metric) for metric in written), pattern)
                slope = next(m for m in story["metrics"] if m["name"] == "memory\\.hidden_slope")
                self.assertEqual(slope["target_ref"], {"target": f"memory-slope.{engine}"})


class MigrationTests(unittest.TestCase):
    def test_bench_memory_is_not_in_mq2(self):
        # p12-perf-process.md MQ2: a bench that names neither bench_launch nor BenchApp launches its own app.
        text = (HERE.parent / "bench_memory.py").read_text()
        self.assertRegex(text, r"bench_launch|BenchApp")
        self.assertIn("from bench_launch import", text)

    def test_percentiles_come_from_perf_stats(self):
        text = (HERE.parent / "bench_memory.py").read_text()
        self.assertNotRegex(text, r"def (pct|percentile|percentiles|p95|p99|quantile|median|_median|stats)\(")
        self.assertIn("perf_stats.summary(", text)

    def test_help_runs_under_isolated_python(self):
        done = subprocess.run([sys.executable, "-I", str(HERE.parent / "bench_memory.py"), "--help"],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("--hidden-slope", done.stdout)


if __name__ == "__main__":
    unittest.main()
