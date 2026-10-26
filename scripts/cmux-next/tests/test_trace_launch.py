#!/usr/bin/env python3
"""trace.py's launch-warm and launch-cold scenarios (p08-startup 005).

1. The launch fixture (trace_fixtures.write_launch_fixture: launch.mark signposts, the app's StartupTrace file, a
   daemon startup trace on a clock 2 s off, a Chromium `--trace-startup` file cut inside an event, main-thread
   samples, watchdog records) builds a summary with the milestones, a critical path between them, the top main-thread
   frames before the first frame and every main-thread turn of 4 ms or more; SUMMARY.txt prints them.
2. The startup files merge on one clock (the trace's clock rule): a file on CLOCK_UPTIME_RAW stays put, a file whose
   shared launch marks are off moves by them, a file with no shared mark outside the window is named; each file's
   threads get their own named tracks, never a sampled OS thread's.
3. A cut file (StartupTrace's 64 KiB chunks after a crash, a killed Chromium) gives its whole events; a B with no E
   ends at the file's last time.
4. Existing scenarios are unchanged: a stress or light recording has no launch section, and --scenario still takes
   stress-storm and light-storm (default stress-storm).
5. The record path: the measured launch's window runs inside BenchApp.launch's on_start (no socket call into the
   launching app), the priming launch quits keeping its sessions and the measured one restores them, StartupTrace
   is switched on, the watchdog threshold is 4 ms and no DevTools port is opened; launch-cold stops the bundle and
   refuses the run when `sudo -n purge` needs a password.

Runs on any OS with no app, GUI session or Xcode (the recorders and BenchApp are stand-ins).

    python3 -m unittest scripts/cmux-next/tests/test_trace_launch.py
"""

from __future__ import annotations

import gzip
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


trace = load("cmux_trace", "trace.py")  # not `trace`: the standard library has one
fixtures = load("trace_fixtures", "trace_fixtures.py")
AT = lambda ms: fixtures.LAUNCH_START_US + ms * 1000  # noqa: E731


def read(path):
    with open(path) as f:
        return f.read()


def built(case, scenario="launch-warm"):
    out = tempfile.mkdtemp(prefix="trace-launch-")
    case.addClassCleanup(shutil.rmtree, out, True)
    fixtures.write_launch_fixture(out, scenario=scenario)
    with mock.patch.object(trace, "note", lambda text: None):
        return out, trace.build(out)


class LaunchSummary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.out, cls.summary = built(cls)
        cls.launch = cls.summary["launch"]
        with gzip.open(os.path.join(cls.out, "trace.json.gz"), "rt") as f:
            cls.events = json.load(f)["traceEvents"]

    def test_milestones_in_order(self):
        names = [m["name"] for m in self.launch["milestones"]]
        self.assertEqual(names[0], "process_start")
        self.assertEqual(self.launch["process_start_from"], "startup trace")
        self.assertLess(names.index("main_start"), names.index("first_window_frame_committed"))
        self.assertEqual(self.launch["first_frame_ms"], 240.0)
        self.assertEqual(self.launch["startup_complete_ms"], 900.0)

    def test_critical_path(self):
        steps = {(s["from"], s["to"]): s for s in self.launch["critical_path"]}
        dfl = steps[("did_finish_launching_start", "did_finish_launching_end")]
        self.assertEqual(dfl["ms"], 130.0)
        self.assertEqual(dfl["main_cpu_ms"], 2.0)  # two 1 ms samples of SessionStore.restore()
        self.assertEqual(dfl["frames"][0]["frame"], "AppDelegate.applicationDidFinishLaunching")
        self.assertEqual(dfl["tasks"][0], {"task": "SessionRestore", "ms": 115.0})  # B/E made a slice
        # daemon.* marks are not on the main thread's path.
        self.assertNotIn("daemon.socket_bound", {s["from"] for s in self.launch["critical_path"]})
        self.assertEqual([s for s in self.launch["critical_path"] if s.get("longest")][0]["to"], "startup_complete")
        # Steps chain: each starts where the one before ended.
        path = self.launch["critical_path"]
        self.assertTrue(all(a["to"] == b["from"] for a, b in zip(path, path[1:])))

    def test_top_frames_before_first_frame(self):
        frames = {row["frame"]: row for row in self.launch["top_main_frames"]}
        self.assertEqual(self.launch["top_main_frames_until"], "first_window_frame_committed")
        self.assertEqual(frames["SessionStore.restore()"]["self_ms"], 2.0)
        self.assertEqual(frames["AppDelegate.applicationDidFinishLaunching"]["ms"], 3.0)
        self.assertNotIn("LateWork.run()", frames)  # sampled after the first frame
        self.assertNotIn("main", frames)  # generic frames are left out
        self.assertLessEqual(len(frames), trace.LAUNCH_TOP_FRAMES)

    def test_turns_over_4_ms(self):
        turns = self.launch["turns"]
        self.assertEqual([(t["at_ms"], t["ms"], t["source"]) for t in turns],
                         [(100.0, 12.0, "startup trace"), (200.0, 6.0, "watchdog")])  # the 2 ms turn is left out
        self.assertEqual(turns[0]["step"], "did_finish_launching_start -> did_finish_launching_end")
        self.assertEqual(turns[1]["frames"], ["CmuxNextApp WindowBuilder.build() + 10"])

    def test_summary_text(self):
        text = read(os.path.join(self.out, "SUMMARY.txt"))
        self.assertIn("Launch (warm): first frame 240.0 ms", text)
        self.assertIn("Critical path", text)
        self.assertIn("* first_window_frame_committed -> startup_complete: 660.0 ms", text)
        self.assertIn("Top 10 main-thread frames before first_window_frame_committed", text)
        self.assertIn("Main-thread turns of 4 ms or more (2):", text)
        self.assertIn("startup-cef.json: chromium, 2 events, TRUNCATED", text)

    def test_files_on_one_clock(self):
        files = self.summary["sources"]["startup_files"]
        self.assertEqual(files["startup-app.json"]["offset_us"], 0.0)
        self.assertIsNone(files["startup-app.json"]["warning"])
        self.assertEqual(files["startup-daemon.json"]["offset_us"], fixtures.DAEMON_SKEW_US)
        self.assertIn("off the signposts", files["startup-daemon.json"]["warning"])
        bound = next(e for e in self.events if e.get("name") == "socket_bound")
        self.assertEqual(bound["ts"], AT(120))  # moved onto the app's daemon.socket_bound
        self.assertTrue(files["startup-cef.json"]["truncated"])

    def test_own_named_tracks(self):
        restore = next(e for e in self.events if e.get("name") == "SessionRestore")
        self.assertEqual(restore["pid"], fixtures.LAUNCH_PID)
        self.assertNotEqual(restore["tid"], fixtures.LAUNCH_MAIN_TID)  # never on the sampled main thread's track
        self.assertLess(restore["tid"], 1 << 31)
        names = {(e["pid"], e.get("tid")): e["args"]["name"] for e in self.events
                 if e.get("ph") == "M" and e.get("name") == "thread_name"}
        self.assertEqual(names[(restore["pid"], restore["tid"])], "startup app: main")
        self.assertEqual(names[(fixtures.CEF_PID, 5)], "startup chromium: CrBrowserMain")
        processes = {e["pid"]: e["args"]["name"] for e in self.events if e.get("name") == "process_name"}
        self.assertTrue(processes[fixtures.DAEMON_PID].startswith("daemon:"), processes)

    def test_cold_label(self):
        _, summary = built(type(self), "launch-cold")
        self.assertEqual(summary["launch"]["temperature"], "cold")


class StartupFiles(unittest.TestCase):
    def write(self, text):
        handle, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(handle, "w") as f:
            f.write(text)
        self.addCleanup(os.unlink, path)
        return path

    def test_whole_and_bare_array(self):
        events, cut = trace.read_trace_file(self.write('{"traceEvents":[{"ph":"i","ts":1}]}'))
        self.assertEqual((len(events), cut), (1, False))
        events, cut = trace.read_trace_file(self.write('[{"ph":"i","ts":1},{"ph":"i","ts":2}]'))
        self.assertEqual((len(events), cut), (2, False))

    def test_cut_after_a_chunk_and_inside_an_event(self):
        whole = '{"traceEvents":[\n{"ph":"B","pid":1,"tid":1,"name":"a","ts":10},\n{"ph":"i","pid":1,"tid":1,"ts":50},\n'
        events, cut = trace.read_trace_file(self.write(whole))  # no closing bracket: a chunk boundary
        self.assertEqual((len(events), cut), (2, True))
        events, cut = trace.read_trace_file(self.write(whole + '{"ph":"E","pid":1,"ti'))
        self.assertEqual((len(events), cut), (2, True))
        slices = trace.complete_slices(events)
        begun = next(e for e in slices if e.get("name") == "a")
        self.assertEqual((begun["ph"], begun["dur"], begun["args"]["unfinished"]), ("X", 40.0, True))
        self.assertEqual(trace.read_trace_file(self.write("garbage")), ([], True))
        self.assertEqual(trace.read_trace_file("/nonexistent/startup.json"), ([], False))

    def test_clock_rule(self):
        same = [{"ph": "i", "name": "main_start", "ts": 1000.0 + 300}]
        self.assertEqual(trace.startup_clock(same, {"main_start": 1000.0}, (0, 2000))[0], 0.0)  # within 1 ms
        far = [{"ph": "i", "name": "main_start", "ts": 1000.0 - 5e6}]
        offset, _, warning = trace.startup_clock(far, {"main_start": 1000.0}, (0, 2000))
        self.assertEqual(offset, 5e6)
        self.assertIsNotNone(warning)
        alone = [{"ph": "X", "name": "x", "ts": 99e9, "dur": 1}]
        offset, how, warning = trace.startup_clock(alone, {}, (0, 2e6))
        self.assertEqual(offset, 0.0)
        self.assertIn("assumed", how)
        self.assertIn("not CLOCK_UPTIME_RAW", warning)
        prefixed = [{"ph": "i", "name": "socket_bound", "ts": 10.0}]
        self.assertEqual(trace.startup_clock(prefixed, {"daemon.socket_bound": 10.0 + 4e6}, (0, 1), "daemon.")[0], 4e6)


class ExistingScenarios(unittest.TestCase):
    def test_storm_summary_has_no_launch_section(self):
        with tempfile.TemporaryDirectory() as out, mock.patch.object(trace, "note", lambda text: None):
            summary = trace.build_fixture(out)
            self.assertNotIn("launch", summary)
            self.assertEqual(summary["sources"]["startup_files"], {})
            self.assertNotIn("Critical path", read(os.path.join(out, "SUMMARY.txt")))

    def test_scenario_choices(self):
        done = subprocess.run([sys.executable, os.path.join(SCRIPTS, "trace.py"), "record", "--help"],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        for name in ("stress-storm", "light-storm", "launch-warm", "launch-cold"):
            self.assertIn(name, done.stdout)


class FakeProcess:
    """A launched app: `wait` blocks until `end`."""

    def __init__(self, pid):
        self.pid, self.ended, self.code = pid, threading.Event(), None

    def wait(self, timeout=None):
        if not self.ended.wait(timeout):
            raise subprocess.TimeoutExpired("app", timeout)
        return self.code

    def poll(self):
        return self.code

    def end(self):
        self.code = 0
        self.ended.set()

    terminate = kill = end


class FakeBench:
    def __init__(self, test):
        self.test, self.launches, self.calls = test, [], []
        self.fresh_state, self.extra_env, self.process = True, {}, None
        self.tag, self.ready_seconds, self.launched_env = "fixture", 1.0, None

    def launch(self, on_start=None):
        self.launches.append({"fresh_state": self.fresh_state, "env": dict(self.extra_env),
                              "rpc_calls_before": len(self.calls)})
        self.process = FakeProcess(1000 + len(self.launches))
        self.launched_env = dict(self.extra_env)
        if on_start:
            self.test.stream.marks["startup_complete"].set()  # the reader saw the mark
            on_start(self.process)
            self.launches[-1]["rpc_calls_in_window"] = len(self.calls) - self.launches[-1]["rpc_calls_before"]

    def rpc(self, method, params=None, timeout=60):
        self.calls.append((method, params))
        if method == "debug.quit":
            self.process.end()
        return {}

    def stop(self):
        if self.process:
            self.process.end()


class FakeStream:
    def __init__(self):
        self.marks = {}

    def watch_mark(self, name):
        return self.marks.setdefault(name, threading.Event())


class RecordPath(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="trace-launch-record-")
        self.addCleanup(shutil.rmtree, self.out, True)
        self.stream = FakeStream()
        self.bench = FakeBench(self)
        clock = iter(range(1, 10_000))
        patches = [mock.patch.object(trace, "uptime_us", lambda: float(next(clock) * 1000)),
                   mock.patch.object(trace, "note", lambda text: None),
                   mock.patch.object(trace, "LAUNCH_SETTLE_S", 0.01)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def recording(self, scenario):
        opts = trace.fake_opts(scenario=scenario, app="/x/cmux DEV fixture.app", seconds=5, hang_ms=8, no_cef=False,
                               cdp_port=0)
        meta = {"host": "test", "scenario": scenario, "sources": {}, "warnings": []}
        # The xctrace recorder (its start is the stand-in below): a sample recorder would start /usr/bin/sample.
        rec = trace.Recording(opts, self.out, meta, trace.Stages(meta, log=lambda text: None), "/x/cmux DEV fixture.app",
                              "xctrace")
        app = types.SimpleNamespace(bench=self.bench, rpc=self.bench.rpc,
                                    startup_env=lambda seconds: {"CMUX_TRACE_STARTUP": f"{seconds:g}"})

        def start_recorders():
            rec.signposts = self.stream

        rec.start_recorders = start_recorders
        rec.install_signals = lambda: None
        return rec, app

    def test_warm_launch(self):
        rec, app = self.recording("launch-warm")
        with mock.patch.object(trace, "TraceApp", lambda *args: app):
            rec.launch_window()
        prime, measured = self.bench.launches
        self.assertTrue(prime["fresh_state"])  # a fresh session to save
        self.assertNotIn("CMUX_TRACE_STARTUP", prime["env"])
        self.assertFalse(measured["fresh_state"])  # the measured launch restores it
        self.assertEqual(measured["env"]["CMUX_TRACE_STARTUP"], "5.01")
        self.assertEqual(measured["rpc_calls_in_window"], 0)  # nothing reached the launching app's socket
        self.assertIn(("debug.quit", {"fixture_quit": "keep"}), self.bench.calls)
        meta = rec.meta
        self.assertTrue(meta["launch"]["startup_complete"])
        self.assertEqual(meta["app_pid"], 1002)
        self.assertLess(meta["window_start_us"], meta["launch"]["spawned_us"])
        self.assertLess(meta["launch"]["spawned_us"], meta["window_end_us"])
        self.assertEqual(meta["scenario_label"], "launch-warm-key-unknown")
        self.assertEqual(meta["errors"], [])

    def test_cold_refuses_without_purge(self):
        rec, app = self.recording("launch-cold")
        stopped = []
        teardown = types.SimpleNamespace(TagTeardown=lambda bundle: types.SimpleNamespace(processes=lambda: [(4242, "d")]))
        refused = subprocess.CompletedProcess(["sudo"], 1, "", "sudo: a password is required")
        with mock.patch.object(trace, "TraceApp", lambda *args: app), \
                mock.patch.dict(sys.modules, {"tag_teardown": teardown}), \
                mock.patch.object(trace.os, "kill", lambda pid, sig: stopped.append((pid, sig))), \
                mock.patch.object(trace, "wait_exits", lambda pids, timeout: set()), \
                mock.patch.object(trace.subprocess, "run", return_value=refused) as run:
            with self.assertRaises(trace.LaunchError) as raised:
                rec.launch_window()
        self.assertEqual(raised.exception.reason, "purge-refused")
        self.assertEqual(run.call_args.args[0], ["sudo", "-n", "purge"])
        self.assertEqual(stopped, [(4242, trace.signal.SIGTERM)])
        self.assertEqual(len(self.bench.launches), 1)  # never a measured launch with a warm cache
        self.assertEqual(rec.meta["errors"][0]["stage"], "cold-prep")

    def test_trace_app_launch_environment(self):
        app_dir = os.path.join(self.out, "cmux DEV fixture.app")
        os.makedirs(app_dir)
        opts = types.SimpleNamespace(scenario="launch-warm", hang_ms=8, no_cef=False, cdp_port=0)
        launch = trace.TraceApp(app_dir, self.out, opts)
        self.assertIsNone(launch.cdp_port)
        self.assertEqual(launch.bench.extra_env["CMUX_NEXT_HANG_THRESHOLD_MS"], "4")
        env = launch.startup_env(7)
        self.assertEqual(env["CMUX_TRACE_STARTUP"], "7")
        self.assertEqual(env["CMUX_TRACE_STARTUP_FILE"], os.path.join(self.out, "startup", "startup-app.json"))
        storm = trace.TraceApp(app_dir, self.out, types.SimpleNamespace(scenario="light-storm", hang_ms=8, no_cef=False,
                                                                        cdp_port=4321))
        self.assertEqual(storm.cdp_port, 4321)  # unchanged for the storms
        self.assertEqual(storm.bench.extra_env["CMUX_NEXT_HANG_THRESHOLD_MS"], "8")

    def test_signpost_stream_sees_the_mark(self):
        stream = trace.SignpostStream(os.path.join(self.out, "s.ndjson"))
        complete = stream.watch_mark("startup_complete")
        stream._saw(json.dumps({"signpostName": "launch.mark", "eventMessage": "first_idle ms=12.0"}))
        self.assertFalse(complete.is_set())
        stream._saw(json.dumps({"signpostName": "launch.mark", "eventMessage": "startup_complete ms=900.0"}))
        self.assertTrue(complete.is_set())


if __name__ == "__main__":
    unittest.main()
