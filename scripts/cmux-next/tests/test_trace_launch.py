#!/usr/bin/env python3
"""trace.py's launch-warm and launch-cold scenarios (p08-startup 005).

1. The launch fixture (trace_fixtures.write_launch_fixture: launch.mark signposts, the app's StartupTrace file, a
   daemon startup trace on a clock 2 s off, a Chromium `--trace-startup` file cut inside an event, main-thread
   samples, watchdog records) builds a summary with the milestones, a critical path between them, the top main-thread
   frames before the first frame and every main-thread turn of 4 ms or more; SUMMARY.txt prints them. A step's tasks
   are the app's main-thread top-level slices only: never a lane job's background thread, a nested child or a
   Chromium file's thread of the same process. Watchdog records the drain lost are counted and warned about.
2. The startup files merge on one clock (the trace's clock rule), against the time each launch mark names (process
   start + its ms), not the signpost's emission: a file on CLOCK_UPTIME_RAW stays put even when its `daemon.*` marks
   were emitted late (the identify reply hands them over), a file whose shared launch marks are off moves by them, a
   file with no shared mark outside the window is named; each file's threads get their own named tracks, never a
   sampled OS thread's.
3. A cut file (StartupTrace's 64 KiB chunks after a crash, a killed Chromium) gives its whole events; a B with no E
   ends at the file's last time.
3b. The three startup tracks (p08-startup 099): a cold launch with a Chromium start has the app's file, the daemon's
   track from the app's `daemon.*` start marks (identify's startup_marks, p08-startup 093; the daemon writes no file)
   and Chromium's file; the summary names them and warns about one the launch should have: the app's always, the
   daemon's when the launch spawned it (`daemon.spawned`), Chromium's when it started (`cef.initialize_started`).
4. Existing scenarios are unchanged: a stress or light recording has no launch section, and --scenario still takes
   stress-storm and light-storm (default stress-storm).
5. The record path: the measured launch's window runs inside BenchApp.launch's on_start (no socket call into the
   launching app), the priming launch quits keeping its sessions and the measured one restores them, StartupTrace
   is switched on, the watchdog threshold is 4 ms and no DevTools port is opened; only the launched pid's
   `launch.mark` ends the window; the stop dumps the StartupTrace file (`debug.startup_trace`) before the app quits;
   launch-cold stops the bundle and refuses the run when `sudo -n purge` needs a password.

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


def built(case, scenario="launch-warm", **fixture):
    out = tempfile.mkdtemp(prefix="trace-launch-")
    case.addClassCleanup(shutil.rmtree, out, True)
    fixtures.write_launch_fixture(out, scenario=scenario, **fixture)
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
        # B/E made a slice; its nested child and the lane job's background thread are not main-thread steps' work.
        self.assertEqual(dfl["tasks"], [{"task": "SessionRestore", "ms": 115.0}])
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
        self.assertIn("Main-thread turns of 4 ms or more (2; watchdog records dropped 0):", text)
        self.assertNotIn("WARNING: the watchdog ring dropped", text)
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

    def test_late_daemon_marks_on_the_right_clock(self):
        # The daemon's file is on CLOCK_UPTIME_RAW; its `daemon.*` signposts came DAEMON_MARK_DELAY_MS late.
        _, summary = built(type(self), daemon_skew_us=0.0)
        daemon = summary["sources"]["startup_files"]["startup-daemon.json"]
        self.assertEqual(daemon["offset_us"], 0.0)
        self.assertIsNone(daemon["warning"])

    def test_dropped_watchdog_records_warn(self):
        out, summary = built(type(self), hangs_dropped=3)
        self.assertEqual(summary["launch"]["hangs_dropped"], 3)
        text = read(os.path.join(out, "SUMMARY.txt"))
        self.assertIn("watchdog records dropped 3", text)
        self.assertIn("WARNING: the watchdog ring dropped its 3 oldest record(s)", text)

    def test_chromium_threads_of_the_app_process_are_not_main_work(self):
        # CEF's browser process is the app: its `--trace-startup` file has CrBrowserMain and IO threads in the app pid.
        out = tempfile.mkdtemp(prefix="trace-launch-")
        self.addCleanup(shutil.rmtree, out, True)
        fixtures.write_launch_fixture(out)
        with open(os.path.join(out, "startup", "startup-cef-browser.json"), "w") as f:
            json.dump({"traceEvents": [
                {"ph": "M", "pid": fixtures.LAUNCH_PID, "tid": 31, "name": "thread_name",
                 "args": {"name": "Chrome_IOThread"}},
                {"ph": "X", "pid": fixtures.LAUNCH_PID, "tid": 31, "name": "ChromeIO.task", "ts": AT(51), "dur": 125_000.0},
                {"ph": "X", "pid": fixtures.LAUNCH_PID, "tid": fixtures.LAUNCH_MAIN_TID, "name": "CrBrowser.task",
                 "ts": AT(51), "dur": 126_000.0}]}, f)
        with mock.patch.object(trace, "note", lambda text: None):
            launch = trace.build(out)["launch"]
        tasks = {t["task"] for step in launch["critical_path"] for t in step["tasks"]}
        self.assertEqual(tasks, {"SessionRestore"})


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

    def test_mark_times_name_the_mark_not_the_emission(self):
        marks = {"main_start": {"ms": 30.0, "at_us": 10_030_000.0},
                 "daemon.socket_bound": {"ms": 120.0, "at_us": 10_200_000.0}}  # handed over 80 ms late
        self.assertEqual(trace.launch_process_start(marks), 10_000_000.0)
        self.assertEqual(trace.launch_mark_times(marks)["daemon.socket_bound"], 10_120_000.0)
        self.assertEqual(trace.launch_mark_times({}), {})

    def test_top_level_slices(self):
        parent = {"ph": "X", "pid": 1, "tid": 1, "name": "p", "ts": 0.0, "dur": 100.0}
        child = {"ph": "X", "pid": 1, "tid": 1, "name": "c", "ts": 10.0, "dur": 20.0}
        other = {"ph": "X", "pid": 1, "tid": 2, "name": "o", "ts": 10.0, "dur": 20.0}
        after = {"ph": "X", "pid": 1, "tid": 1, "name": "a", "ts": 100.0, "dur": 5.0}
        self.assertEqual([e["name"] for e in trace.top_level([child, after, parent, other])], ["p", "o", "a"])

    def test_main_tracks(self):
        named = [{"ph": "M", "pid": 1, "tid": 3, "name": "thread_name", "args": {"name": "Main Thread"}},
                 {"ph": "X", "pid": 1, "tid": 4, "name": "job", "ts": 1.0, "dur": 1.0}]
        self.assertEqual(trace.startup_main_tracks(named), {(1, 3)})
        turned = [{"ph": "X", "pid": 1, "tid": 5, "cat": "main_turn", "name": "main.turn", "ts": 1.0, "dur": 9.0}]
        self.assertEqual(trace.startup_main_tracks(turned), {(1, 5)})
        marked = [{"ph": "i", "pid": 1, "tid": 6, "name": "mark", "ts": 1.0, "args": {"mark": "main_start"}}]
        self.assertEqual(trace.startup_main_tracks(marked), {(1, 6)})

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


    def test_startup_tracks_name_the_missing_ones(self):
        files = {"startup-app.json": {"source": "app", "events": 9}, "startup-cef.json": {"source": "chromium", "events": 0}}
        quiet = trace.startup_tracks(files, {})  # a warm launch (no spawn) that never started Chromium
        self.assertEqual(quiet, {"present": ["app"], "missing": []})
        both = trace.startup_tracks(files, {"daemon.spawned": {}, "cef.initialize_started": {}})
        self.assertEqual([(gap["source"], gap["mark"]) for gap in both["missing"]],
                         [("daemon", "daemon.spawned"), ("chromium", "cef.initialize_started")])
        reported = trace.startup_tracks(files, {"daemon.spawned": {}, "daemon.main_start": {}})  # the daemon's start
        self.assertEqual((reported["present"], reported["missing"]), (["app", "daemon"], []))
        none = trace.startup_tracks({}, {})
        self.assertEqual((none["present"], [gap["source"] for gap in none["missing"]]), ([], ["app"]))
        text = "\n".join(trace.launch_text({"startup_tracks": both}, {}))
        self.assertIn("startup tracks: app", text)
        self.assertIn("WARNING: no chromium startup trace although the launch marked cef.initialize_started", text)


class StartupTracks(unittest.TestCase):
    """A cold launch that spawned the daemon and started Chromium: no daemon startup file, the daemon's start only in
    the app's launch marks."""

    @classmethod
    def setUpClass(cls):
        cls.out, cls.summary = built(cls, "launch-cold", cold_marks=True)
        with gzip.open(os.path.join(cls.out, "trace.json.gz"), "rt") as f:
            cls.events = json.load(f)["traceEvents"]

    def test_three_startup_tracks(self):
        self.assertNotIn("startup-daemon.json", self.summary["sources"]["startup_files"])
        tracks = self.summary["launch"]["startup_tracks"]
        self.assertEqual(tracks, {"present": ["app", "daemon", "chromium"], "missing": []})
        text = read(os.path.join(self.out, "SUMMARY.txt"))
        self.assertIn("startup tracks: app, daemon, chromium", text)
        self.assertNotIn("no daemon startup trace", text)

    def test_daemon_track_from_its_start_marks(self):
        daemon = [e for e in self.events if e.get("cat") == "startup.daemon"]
        self.assertEqual({e["pid"] for e in daemon}, {fixtures.DAEMON_PID})
        self.assertEqual(len({e["tid"] for e in daemon}), 1)
        start = next(e for e in daemon if e["ph"] == "i")
        # At the daemon's times, not the emission DAEMON_MARK_DELAY_MS later.
        self.assertEqual((start["name"], start["ts"]), ("daemon.main_start", AT(64)))
        steps = [(e["name"], e["ts"], e["dur"]) for e in daemon if e["ph"] == "X"]
        self.assertEqual(steps, [("config_loaded", AT(64), 6000.0), ("socket_bound", AT(70), 50000.0),
                                 ("mux_restored", AT(120), 2000.0), ("lifecycle_ready", AT(122), 3000.0),
                                 ("first_identify_served", AT(125), 5000.0)])
        names = {(e["pid"], e.get("tid")): e["args"]["name"] for e in self.events
                 if e.get("ph") == "M" and e.get("name") == "thread_name"}
        self.assertEqual(names[(fixtures.DAEMON_PID, daemon[0]["tid"])], "startup daemon")
        processes = {e["pid"]: e["args"]["name"] for e in self.events if e.get("name") == "process_name"}
        self.assertTrue(processes[fixtures.DAEMON_PID].startswith("daemon:"), processes)

    def test_an_older_daemon_names_the_missing_track(self):
        marks = {"daemon.spawned": {"ms": 62.0, "at_us": AT(62)}}  # spawned, but no startup_marks in identify
        tracks = trace.startup_tracks({"startup-app.json": {"source": "app", "events": 9}}, marks)
        self.assertEqual(tracks["present"], ["app"])
        self.assertEqual([(gap["source"], gap["mark"]) for gap in tracks["missing"]], [("daemon", "daemon.spawned")])
        self.assertIn("startup_marks", tracks["missing"][0]["why"])


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
        self.calls.append(("app-stop", None))
        if self.process:
            self.process.end()


class FakeStream:
    def __init__(self):
        self.marks, self.pid = {}, None

    def watch_mark(self, name):
        return self.marks.setdefault(name, threading.Event())

    def watch_pid(self, pid):
        self.pid = pid

    def stop(self):
        pass

    kill = stop


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
        app = types.SimpleNamespace(bench=self.bench, rpc=self.bench.rpc, probe=os.path.join(self.out, "typing.csv"),
                                    startup_dir=os.path.join(self.out, "startup"),
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
        self.assertEqual(self.stream.pid, 1002)  # the window's marks are the measured launch's own

    def test_stop_dumps_the_startup_trace_before_the_app_quits(self):
        rec, app = self.recording("launch-warm")
        with mock.patch.object(trace, "TraceApp", lambda *args: app), \
                mock.patch.object(trace, "ps_snapshot", lambda bundle: []):
            rec.launch_window()
            rec.stop()
            rec.stop_app()
        methods = [method for method, _ in self.bench.calls]
        self.assertIn("debug.startup_trace", methods)
        self.assertLess(methods.index("debug.startup_trace"), methods.index("app-stop"))
        self.assertLess(methods.index("debug.startup_trace"), methods.index("debug.hangs"))
        self.assertEqual(rec.meta["errors"], [])
        self.assertTrue(rec.hangs.from_start)

    def test_single_drain_counts_records_lost_before_the_first(self):
        replies = iter([{"records": [{"sequence": 6}, {"sequence": 7}]}, {"records": [{"sequence": 9}]}])
        drain = trace.HangDrain(lambda *args, **kwargs: next(replies), os.path.join(self.out, "h.json"), from_start=True)
        drain.drain()
        self.assertEqual(drain.gaps, 5)  # sequences 1 to 5 left the ring before the drain
        drain.drain()
        self.assertEqual(drain.gaps, 6)
        periodic = trace.HangDrain(lambda *args, **kwargs: {"records": [{"sequence": 6}]}, os.path.join(self.out, "p.json"))
        periodic.drain()
        self.assertEqual(periodic.gaps, 0)  # a storm's drain starts mid-run: what came before is not its window's

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
        opts = types.SimpleNamespace(scenario="launch-warm", hang_ms=8, no_cef=False, cdp_port=0, release=False)
        launch = trace.TraceApp(app_dir, self.out, opts)
        self.assertIsNone(launch.cdp_port)
        self.assertEqual(launch.bench.extra_env["CMUX_NEXT_HANG_THRESHOLD_MS"], "4")
        env = launch.startup_env(7)
        self.assertEqual(env["CMUX_TRACE_STARTUP"], "7")
        self.assertEqual(env["CMUX_TRACE_STARTUP_FILE"], os.path.join(self.out, "startup", "startup-app.json"))
        storm = trace.TraceApp(app_dir, self.out, types.SimpleNamespace(scenario="light-storm", hang_ms=8, no_cef=False,
                                                                        cdp_port=4321, release=False))
        self.assertEqual(storm.cdp_port, 4321)  # unchanged for the storms
        self.assertEqual(storm.bench.extra_env["CMUX_NEXT_HANG_THRESHOLD_MS"], "8")

    def test_signpost_stream_sees_the_mark(self):
        stream = trace.SignpostStream(os.path.join(self.out, "s.ndjson"))
        complete = stream.watch_mark("startup_complete")
        stream._saw(json.dumps({"signpostName": "launch.mark", "processID": 7, "eventMessage": "first_idle ms=12.0"}))
        stream.watch_pid(7)
        self.assertFalse(complete.is_set())
        stream._saw(json.dumps({"signpostName": "launch.mark", "processID": 7, "eventMessage": "startup_complete ms=900.0"}))
        self.assertTrue(complete.is_set())

    def test_another_apps_mark_does_not_end_the_window(self):
        stream = trace.SignpostStream(os.path.join(self.out, "s.ndjson"))
        complete = stream.watch_mark("startup_complete")
        other = json.dumps({"signpostName": "launch.mark", "processID": 99, "eventMessage": "startup_complete ms=5.0"})
        stream._saw(other)  # before the spawn: the pid is not known yet
        stream.watch_pid(7)
        stream._saw(other)
        self.assertFalse(complete.is_set())

    def test_this_apps_mark_before_watch_pid_counts(self):
        stream = trace.SignpostStream(os.path.join(self.out, "s.ndjson"))
        complete = stream.watch_mark("startup_complete")
        stream._saw(json.dumps({"signpostName": "launch.mark", "processID": 7, "eventMessage": "startup_complete ms=5.0"}))
        self.assertFalse(complete.is_set())
        stream.watch_pid(7)
        self.assertTrue(complete.is_set())


if __name__ == "__main__":
    unittest.main()
