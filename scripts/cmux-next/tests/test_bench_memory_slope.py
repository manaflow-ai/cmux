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
import shutil
import subprocess
import sys
import tempfile
import unittest
from fnmatch import fnmatchcase
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
import bench_launch as bl  # noqa: E402
import bench_memory as bm  # noqa: E402

MB = 1048576
BUNDLE = "/tmp/cmux DEV slope.app"
STORIES = ROOT / "scripts" / "perf-lab" / "stories.d"
HOST = {"fingerprint": "0" * 64, "class": "apple-m4-16gb-120hz", "chip": "Apple M4", "macos": "26.0",
        "macos_build": "25A100", "display_hz": 120}
FEATURES = ({"memory.discard.parkedWorkspaces": {"state": "off", "source": "default"}}, "abc", "off")


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
    """The control socket: debug.surfaces' hibernation summary (`hibernation`, a dict, a function of the clock, or
    None for a build without it)."""

    def __init__(self, hibernation=None):
        self.hibernation = hibernation
        self.ran: list[tuple[str, float]] = []
        self.closed: list[str] = []
        self.clock = None

    def call(self, method, params=None, label=None, timeout=120):
        if method == "debug.surfaces" and self.hibernation is not None:
            state = self.hibernation(self.clock.now) if callable(self.hibernation) else self.hibernation
            return {"hibernation": state}
        return {"error": json.dumps({"code": "method_not_found"})}

    def run(self, action, target=None, **args):
        self.ran.append((action, self.clock.now if self.clock else 0.0))
        if action == "closeWorkspace":
            self.closed.append(target)
        return {}


def quiet(call, *args, **kwargs):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return call(*args, **kwargs)


class SlopeMathTests(unittest.TestCase):
    def test_slope_is_the_footprint_difference_per_added_workspace_one_per_sample_pair(self):
        low = [400 * MB, 402 * MB, 401 * MB]
        high = [425 * MB, 427 * MB, 420 * MB]
        self.assertEqual(bm.slope_samples(low, high, 10, 60), [0.5 * MB, 0.5 * MB, 0.38 * MB])

    def test_grace_is_the_timeout_plus_the_planners_pace_at_the_pressure(self):
        # HibernationPlanner.normalPace: 2 pages per pass, a pass every 5 s.
        self.assertEqual(bm.hibernation_grace(1.0, 10), 60 + 5 * 5)
        self.assertEqual(bm.hibernation_grace(1.0, 60), 60 + 30 * 5)
        self.assertEqual(bm.hibernation_grace(0.5, 3), 30 + 2 * 5)
        self.assertEqual(bm.hibernation_grace(None, 60), 0.0)
        # warningPace: 1 page per pass every 15 s, each hidden at least 60 s; criticalPace: 3 every 3 s, 10 s.
        self.assertEqual(bm.hibernation_grace(1.0, 50, "warning"), 60 + 50 * 15)
        self.assertEqual(bm.hibernation_grace(0.5, 50, "warning"), 60 + 50 * 15)
        self.assertEqual(bm.hibernation_grace(1.0, 60, "critical"), 60 + 20 * 3)
        # Under pressure the timeout is 10 minutes at most; an unknown level takes the slowest pace.
        self.assertEqual(bm.hibernation_grace(30.0, 10, "critical"), 600 + 4 * 3)
        self.assertEqual(bm.hibernation_grace(1.0, 10, None), bm.hibernation_grace(1.0, 10, "warning"))

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


def hibernated(count, pressure="normal", neighbors=0):
    return {"mode": 1, "pressure": pressure, "hibernated": [f"tab_{i}" for i in range(count)],
            "awake_neighbors": [f"tab_n{i}" for i in range(neighbors)]}


class PhaseTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.saved = (bm.time, bm.open_workspace_parts)
        bm.time = self.clock
        self.opened_with = []
        self.fail_at = None

        def open_workspace_parts(app, recipe, url, index, chats=None):
            self.opened_with.append((recipe, url))
            return f"ws_{index}", (["chromium"] if index == self.fail_at else [])

        bm.open_workspace_parts = open_workspace_parts

    def tearDown(self):
        bm.time, bm.open_workspace_parts = self.saved

    def run_phase(self, footprints, hibernation=None, samples=3, engine_missing=lambda: None):
        app = FakeApp(hibernation)
        app.clock = self.clock
        taken, opened = [], []

        def take(label, workspaces):
            taken.append((label, workspaces, self.clock.now))
            return total(footprints[label])

        phase = quiet(bm.hidden_slope_phase, app, "terminal+chromium", [10, 60], samples, 10.0,
                      lambda pages, pressure: bm.hibernation_grace(1.0, pages, pressure), 30.0, take,
                      [f"http://site{i}.localhost/" for i in range(60)], opened, engine_missing)
        return app, phase, taken, opened

    def good_footprints(self):
        footprints = {f"slope-10-{i}": (400 + i) * MB for i in (1, 2, 3)}
        footprints.update({f"slope-60-{i}": (425 + i) * MB for i in (1, 2, 3)})
        return footprints

    def test_samples_each_count_after_its_grace_and_stores_every_sample(self):
        app, phase, taken, opened = self.run_phase(self.good_footprints(), hibernated(60))
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
        self.assertNotIn("error", phase)

    def test_awake_neighbors_of_the_shown_workspace_count_as_settled(self):
        _, phase, taken, _ = self.run_phase(self.good_footprints(), hibernated(58, neighbors=2))
        self.assertNotIn("error", phase)
        self.assertEqual(len(taken), 6)

    def test_a_count_it_cannot_reach_records_no_slope(self):
        bm.open_workspace_parts = lambda app, recipe, url, index, chats=None: (
            (None, []) if index >= 3005 else (f"ws_{index}", []))
        app, phase, taken, opened = self.run_phase({})
        self.assertEqual(phase["error"], "opened 5 of 10 workspaces")
        self.assertNotIn("slope_bytes", phase)
        self.assertEqual(taken, [])

    def test_a_page_that_did_not_open_is_a_failed_workspace(self):
        self.fail_at = 3004
        app, phase, taken, opened = self.run_phase({}, hibernated(60))
        self.assertEqual(phase["error"], "workspace 5 (ws_3004): chromium did not open")
        # The workspace is still the run's, so an attached app gets it closed.
        self.assertEqual(opened[-1], "ws_3004")
        self.assertNotIn("slope_bytes", phase)
        self.assertEqual(taken, [])
        self.assertEqual(app.ran, [], "nothing hidden or sampled")

    def test_no_engine_process_for_the_open_pages_records_no_slope(self):
        checks = []

        def missing():
            checks.append(self.clock.now)
            return "no cef-renderer process of the app for its open pages (kinds: app)"

        _, phase, taken, _ = self.run_phase({}, hibernated(60), engine_missing=missing)
        self.assertEqual(phase["error"], "no cef-renderer process of the app for its open pages (kinds: app)")
        self.assertEqual(taken, [])
        self.assertEqual(checks[-1] - checks[0], bm.ENGINE_WAIT_S, "the pages get ENGINE_WAIT_S to start it")

    def test_engine_processes_that_start_late_are_waited_for(self):
        started = {"at": None}

        def missing():
            if started["at"] is None:
                started["at"] = self.clock.now + 4
            return None if self.clock.now >= started["at"] else "not yet"

        _, phase, taken, _ = self.run_phase(self.good_footprints(), hibernated(60), engine_missing=missing)
        self.assertNotIn("error", phase)
        self.assertEqual(len(taken), 6)

    def test_pages_that_never_hibernate_record_no_slope(self):
        app, phase, taken, _ = self.run_phase({}, hibernated(3))
        hidden = app.ran[0][1]
        self.assertEqual(phase["error"], "10 hidden: 3 of 10 hidden pages hibernated (0 awake neighbors) 145 s after "
                                         "they went hidden, at pressure normal")
        self.assertGreaterEqual(self.clock.now - hidden, 85 + 30 + bm.HIBERNATION_POLL_SLACK_S)
        self.assertEqual(taken, [])
        self.assertNotIn("slope_bytes", phase)

    def test_a_build_without_debug_surfaces_cannot_confirm_the_hidden_state(self):
        _, phase, taken, _ = self.run_phase({}, None)
        self.assertIn("unconfirmed", phase["error"])
        self.assertEqual(taken, [])

    def test_warning_pressure_waits_for_the_slower_pace(self):
        # Under warning the planner hibernates one page every 15 s; the 60 count's last page goes 60 + 60 * 15 s
        # after they went hidden, far past the normal-pace grace.
        def state(now):
            if not hasattr(self, "second_hidden"):
                return hibernated(10, "warning")
            return hibernated(60 if now - self.second_hidden >= 60 + 60 * 15 else 20, "warning")

        footprints = self.good_footprints()
        app = FakeApp(state)
        app.clock = self.clock
        real_run = app.run

        def run(action, target=None, **args):
            if action == "workspace.selectFirst" and len(app.ran) == 1:
                self.second_hidden = self.clock.now
            return real_run(action, target, **args)

        app.run = run
        taken = []

        def take(label, workspaces):
            taken.append((label, self.clock.now))
            return total(footprints[label])

        phase = quiet(bm.hidden_slope_phase, app, "terminal+chromium", [10, 60], 3, 10.0,
                      lambda pages, pressure: bm.hibernation_grace(1.0, pages, pressure), 30.0, take,
                      [f"http://site{i}.localhost/" for i in range(60)], [], lambda: None)
        self.assertNotIn("error", phase)
        self.assertGreaterEqual(taken[3][1] - self.second_hidden, 60 + 60 * 15)
        self.assertEqual(phase["counts"]["60"]["hibernation"]["pressure"], "warning")


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
        # The engine check's kinds: an open page of each engine shows as one of these.
        self.assertTrue(set(bm.ENGINE_PAGE_KINDS.values()) <= set(kinds.values()))

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


class ShaEnv(unittest.TestCase):
    def setUp(self):
        self.saved_sha = os.environ.get("CMUX_CI_SHA")
        os.environ["CMUX_CI_SHA"] = "a" * 40

    def tearDown(self):
        if self.saved_sha is None:
            os.environ.pop("CMUX_CI_SHA")
        else:
            os.environ["CMUX_CI_SHA"] = self.saved_sha


class RecordTests(ShaEnv):
    def bench(self, folder):
        bench = bl.BenchApp(stamped_bundle(folder), out=os.path.join(folder, "out"), teardown=False,
                            host=lambda: HOST)
        bench.features = FEATURES
        return bench

    def test_slope_and_each_counts_footprint_are_valid_result_v1_with_every_sample(self):
        phase = {"slope_bytes": [0.5 * MB, 0.48 * MB, 0.52 * MB],
                 "counts": {"10": {"footprint_bytes": [400 * MB, 401 * MB, 399 * MB]},
                            "60": {"footprint_bytes": [425 * MB, 425 * MB, 425 * MB]}}}
        with tempfile.TemporaryDirectory() as folder:
            for engine in ("chromium", "webkit"):
                written = bm.record_slope(self.bench(folder), bm.SLOPE_STORIES[engine], engine, phase, [10, 60])
                self.assertFalse([o for o in written.values() if o.startswith("not recorded")], written)
                self.assertIsNone(bm.slope_failure({**phase, "results": written}))
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

    def test_a_phase_without_a_slope_writes_nothing_not_even_the_count_it_reached(self):
        phase = {"error": "60 hidden: 3 of 60 hidden pages hibernated",
                 "counts": {"10": {"footprint_bytes": [400 * MB, 401 * MB, 399 * MB]}}}
        with tempfile.TemporaryDirectory() as folder:
            written = bm.record_slope(self.bench(folder), "memory-hidden", "chromium", phase, [10, 60])
            why = "not recorded: 60 hidden: 3 of 60 hidden pages hibernated"
            self.assertEqual(written, {"memory.hidden_slope": why, "memory.hidden_footprint.10": why,
                                       "memory.hidden_footprint.60": why})
            self.assertFalse(os.path.exists(os.path.join(folder, "out")) and os.listdir(os.path.join(folder, "out")))

    def test_a_metric_it_could_not_record_fails_the_run(self):
        self.assertEqual(bm.slope_failure({"slope_bytes": [1.0], "results": {"memory.hidden_slope": "/x",
                                                                             "memory.hidden_footprint.10": "not recorded: no features"}}),
                         "memory.hidden_footprint.10: not recorded: no features")
        self.assertEqual(bm.slope_failure({"error": "opened 5 of 10 workspaces"}), "opened 5 of 10 workspaces")
        self.assertEqual(bm.slope_failure(None), "the phase did not run")


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
        self.assertEqual((counts, args.slope_samples, args.engine, args.session), ([10, 60], 3, "chromium", "light"))
        self.assertEqual(self.parse("--hidden-slope", "--slope-counts", "60,10")[1], [10, 60])
        self.assertEqual(self.parse("--workspaces", "1,10")[1], [])

    def test_combinations_a_run_cannot_honor_are_refused(self):
        for argv in (("--hidden-slope", "--slope-counts", "10"), ("--hidden-slope", "--slope-counts", "10,10"),
                     ("--hidden-slope", "--slope-counts", "0,60"), ("--hidden-slope", "--tabs", "1,10"),
                     ("--hidden-slope", "--slope-samples", "0"), ("--hidden-slope", "--slope-counts", "a,b"),
                     ("--hibernate-after", "1", "--socket", "/tmp/s", "--app-pid", "1"),
                     ("--hibernate-after", "0"), ("--grace", "10"), ("--hidden-slope", "--tag", "other"),
                     ("--hidden-slope", "--session", "stress")):
            with self.subTest(argv=argv):
                self.assertEqual(self.refused(*argv), 2)

    def test_the_runners_tag_must_name_the_bundle(self):
        self.assertEqual(self.parse("--hidden-slope", "--tag", "slope")[0].tag, "slope")
        self.assertEqual(self.parse("--hidden-slope", "--tag", "Slope")[0].tag, "Slope")

    def test_attach_mode_stays(self):
        args, _ = self.parse("--hidden-slope", "--socket", "/tmp/s", "--app-pid", "42", "--grace", "120")
        self.assertEqual((args.socket, args.app_pid, args.grace), ("/tmp/s", 42, 120.0))

    def test_out_is_the_report_file_unless_a_slope_run_gets_a_results_folder(self):
        self.assertEqual(bm.out_paths(None, True), (None, None))
        self.assertEqual(bm.out_paths("/tmp/memory.json", True), ("/tmp/memory.json", None))
        with tempfile.TemporaryDirectory() as folder:
            report = os.path.join(folder, "report")
            self.assertEqual(bm.out_paths(report, False), (report, None))
            self.assertFalse(os.path.exists(report), "the report file of any other mode is no folder")
            out = os.path.join(folder, "results")
            self.assertEqual(bm.out_paths(out, True), (os.path.join(out, "bench-memory.json"), out))
            self.assertTrue(os.path.isdir(out))


class StubBench(bl.BenchApp):
    """BenchApp with the launch and stop of a fake app; record() and environment() are the real ones."""

    made: list = []

    def __init__(self, app, **kwargs):
        self.kwargs = dict(kwargs)
        kwargs["teardown"] = False
        super().__init__(app, host=lambda: HOST, **kwargs)
        self.events: list = []
        StubBench.made.append(self)

    def launch(self, *args, **kwargs):
        self.events.append(("launch", None if bm._foreign_webkit is None else set(bm._foreign_webkit)))
        self.socket, self.process, self.features = "/tmp/fake-slope.sock", SimpleNamespace(pid=4242), FEATURES

    def stop(self, *args, **kwargs):
        self.events.append(("stop",))

    def read_features(self):
        return FEATURES


class StubChats:
    def __init__(self, app, bundle, script):
        self.script = script


class MainTests(ShaEnv):
    """main() end to end on a fake app: the launch config and env, the WebKit snapshot before the launch, the teardown
    of a launched and an attached app, and the result-v1 files under --out DIR."""

    def setUp(self):
        super().setUp()
        self.folder = tempfile.mkdtemp(prefix="bench-memory-slope-test-")
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.bundle = stamped_bundle(self.folder)
        self.out = os.path.join(self.folder, "out")
        self.clock = FakeClock()
        self.opened: list[str] = []
        self.failing_index = None
        self.hibernates = True
        self.app = FakeApp(self.state)
        self.app.clock = self.clock
        StubBench.made = []

        def open_workspace_parts(app, recipe, url, index, chats=None):
            self.opened.append(f"ws_{index}")
            return f"ws_{index}", (["chromium"] if index == self.failing_index else [])

        def sample(app_pid, bundle, label, workspaces, measure=0):
            footprint = 400 * MB + workspaces * MB // 2
            return {"label": label, "workspaces": workspaces, "processes": [], "total_rss_mb": 0.0,
                    "total_footprint_mb": footprint / MB, "total_footprint_bytes": footprint,
                    "kinds": {"app": {"count": 1, "rss_mb": 0.0, "footprint_mb": footprint / MB,
                                      "footprint_bytes": footprint}}}

        saved_foreign = bm._foreign_webkit
        patches = [mock.patch.object(bm, "time", self.clock), mock.patch.object(bm, "BenchApp", StubBench),
                   mock.patch.object(bm, "App", lambda bundle, path: self.app),
                   mock.patch.object(bm, "FakeChats", StubChats),
                   mock.patch.object(bm, "open_workspace_parts", open_workspace_parts),
                   mock.patch.object(bm, "sample", sample),
                   mock.patch.object(bm, "owned", lambda app_pid, bundle: {9: ("cef-renderer", "renderer")}),
                   mock.patch.object(bm, "webkit_pids", lambda: {7, 8}),
                   mock.patch.object(bm, "thread_times", lambda pid: {}),
                   mock.patch.object(bm, "tab_urls", lambda spec, count: [f"http://site{i}.localhost/" for i in range(count)]),
                   mock.patch.object(bm.signal, "signal"), mock.patch.object(bm.sys, "platform", "darwin")]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.addCleanup(setattr, bm, "_foreign_webkit", saved_foreign)

    def state(self, now):
        return {"mode": 1, "pressure": "normal", "hibernated": list(self.opened) if self.hibernates else []}

    def main(self, *argv):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return bm.main(["--app", self.bundle, *argv])

    def results(self):
        return {r.metric: r for r in bm.perf_result.read_dir(self.out)} if os.path.isdir(self.out) else {}

    def report(self):
        with open(os.path.join(self.out, "bench-memory.json")) as handle:
            return json.load(handle)

    def test_a_launched_slope_run_configures_hibernation_snapshots_webkit_and_ends_the_app(self):
        self.main("--hidden-slope", "--tag", "slope", "--session", "light", "--fake-agent", "/x/fake_agent.py",
                  "--out", self.out)
        bench, = StubBench.made
        self.assertEqual(bench.kwargs["out"], self.out)
        self.assertEqual(bench.kwargs["perf_session"], "light")
        self.assertEqual(bench.kwargs["config"]["browser"]["hibernation"], bm.SLOPE_HIBERNATE_AFTER_MINUTES)
        self.assertEqual(bench.kwargs["config"]["updates"],
                         {"checkAutomatically": False, "downloadAutomatically": False})
        env = bench.environment()
        self.assertNotIn("CMUX_NEXT_AGENT_PANE_MOCK", env)
        self.assertNotIn("ACPMUX_AGENT_LAUNCH", env)
        with open(env["CMUX_NEXT_CONFIG_FILE"]) as handle:
            self.assertEqual(json.load(handle)["browser"]["hibernation"], 1.0)
        # The WebKit processes that ran before the launch are taken before it, and the launched app ends whole.
        self.assertEqual(bench.events, [("launch", {7, 8}), ("stop",)])
        self.assertEqual(self.app.closed, [])
        results = self.results()
        self.assertEqual(set(results), {"memory.hidden_slope", "memory.hidden_footprint.10",
                                        "memory.hidden_footprint.60"})
        self.assertEqual(results["memory.hidden_slope"].samples, [0.5 * MB] * 3)
        self.assertEqual(results["memory.hidden_slope"].target_ref.target, "memory-slope.chromium")
        self.assertEqual(results["memory.hidden_slope"].session, "light")
        self.assertNotIn("error", self.report()["hidden_slope"])

    def test_without_the_fake_agent_the_bench_env_keeps_its_agent_mock(self):
        self.main("--hidden-slope", "--out", self.out)
        bench, = StubBench.made
        self.assertNotIn("CMUX_NEXT_AGENT_PANE_MOCK", bench.kwargs["env"])

    def test_an_attached_slope_run_records_and_closes_only_its_own_workspaces(self):
        self.main("--hidden-slope", "--socket", "/tmp/s.sock", "--app-pid", "42", "--grace", "90", "--out", self.out)
        bench, = StubBench.made
        self.assertEqual((bench.kwargs["teardown"], bench.socket), (False, "/tmp/s.sock"))
        self.assertEqual(bench.events, [], "an attached app is neither launched nor stopped")
        self.assertIsNone(bm._foreign_webkit)
        self.assertEqual(self.app.closed, self.opened)
        self.assertEqual(len(self.opened), 60)
        self.assertEqual(set(self.results()), {"memory.hidden_slope", "memory.hidden_footprint.10",
                                               "memory.hidden_footprint.60"})

    def test_an_attached_run_without_the_slope_builds_no_bench_and_keeps_out_as_the_report_file(self):
        report = os.path.join(self.folder, "report")
        self.main("--socket", "/tmp/s.sock", "--app-pid", "42", "--workspaces", "1", "--out", report)
        self.assertEqual(StubBench.made, [])
        self.assertTrue(os.path.isfile(report))

    def test_a_page_that_did_not_open_exits_non_zero_and_records_nothing(self):
        self.failing_index = 3004
        with self.assertRaises(SystemExit) as raised:
            self.main("--hidden-slope", "--out", self.out)
        self.assertIn("chromium did not open", str(raised.exception.code))
        self.assertEqual(self.results(), {})
        self.assertIn("did not open", self.report()["hidden_slope"]["error"])
        self.assertEqual(StubBench.made[0].events[-1], ("stop",))

    def test_pages_that_never_hibernate_exit_non_zero_and_record_nothing(self):
        self.hibernates = False
        with self.assertRaises(SystemExit) as raised:
            self.main("--hidden-slope", "--out", self.out)
        self.assertIn("0 of 10 hidden pages hibernated", str(raised.exception.code))
        self.assertEqual(self.results(), {})


class StoryTests(unittest.TestCase):
    """Each engine's story runs this bench with the lab runner's argv, its metrics are the ones record_slope writes,
    and a target miss or regression routes to the memory owner."""

    RUNNER = ["--app", BUNDLE, "--tag", "slope", "--out", "/tmp/out", "--session", "light"]

    def test_both_engine_stories_run_the_slope_and_list_its_metrics(self):
        for engine, story_id in bm.SLOPE_STORIES.items():
            with self.subTest(engine=engine):
                story = json.loads((STORIES / f"{story_id}.json").read_text())
                self.assertEqual((story["id"], story["engine"]), (story_id, engine))
                self.assertEqual(story["command"][0], "scripts/cmux-next/bench_memory.py")
                args, counts = bm.parse_args(story["command"][1:] + self.RUNNER)
                self.assertTrue(args.hidden_slope)
                self.assertEqual((args.engine, counts, args.slope_samples, args.story, args.session),
                                 (engine, [10, 60], 3, None, story["session"]))
                written = [bm.SLOPE_METRIC] + [f"memory.hidden_footprint.{count}" for count in counts]
                patterns = [metric["name"] for metric in story["metrics"]]
                for metric in written:
                    self.assertTrue(any(re.fullmatch(p, metric) for p in patterns), metric)
                for pattern in patterns:
                    self.assertTrue(any(re.fullmatch(pattern, metric) for metric in written), pattern)
                slope = next(m for m in story["metrics"] if m["name"] == "memory\\.hidden_slope")
                self.assertEqual(slope["target_ref"], {"target": f"memory-slope.{engine}"})

    def test_the_memory_target_subscription_matches_both_stories(self):
        document = json.loads((ROOT / "scripts" / "perf-lab" / "subscriptions.json").read_text())
        entries = [entry for entry in document["subscriptions"] if entry["kind"] == "target"
                   and "memory-slope" in entry.get("targets", [])]
        self.assertEqual(len(entries), 1)
        match = entries[0]["match"]
        for story_id in bm.SLOPE_STORIES.values():
            self.assertTrue(fnmatchcase(story_id, match["story"]), story_id)
        self.assertTrue(fnmatchcase(bm.SLOPE_METRIC, match["metric"]))


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
