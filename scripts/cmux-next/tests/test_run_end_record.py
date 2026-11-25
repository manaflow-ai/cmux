#!/usr/bin/env python3
"""run_end_record.py: what the app's last run left, printed whole before a driver's launch, and the driver's own end.

No app and no Mac: the app's files are written here as AppRunMarker.swift writes them (a `run.json`, a
`run.signal` with a signal's number or empty, a `run.exception`), in a home that is this test's folder. So this
proves the reading, the prints, their order and the verdicts, not that an app on a Mac writes such files.

    python3 -I scripts/cmux-next/tests/test_run_end_record.py
"""
import json
import os
import plistlib
import signal
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True  # the imports leave no cache folder in the checkout
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
try:
    import run_end_record  # noqa: E402
except ImportError:
    run_end_record = None  # each test then fails by its own first line

BUNDLE = "com.example.app.debug.demo tag"
RUN = {"pid": 4242, "launched": 1763500000.5, "recovery": False, "survived": True, "version": "0.1 7", "commit": "abc1234",
       "context": {"workspaces": 3, "note": "x" * 600}}
NOW = 1795000000.0  # the time of each read of the system's reports here; a report's age counts back from it


class RunEndTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(run_end_record, "scripts/cmux-next/run_end_record.py is not there: the driver prints no end record")
        self.home = os.path.realpath(tempfile.mkdtemp(prefix="run-end-record-test-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.home, ignore_errors=True))
        self.app = os.path.join(self.home, "builds", "cmux DEV demo-tag.app")
        os.makedirs(os.path.join(self.app, "Contents"))
        with open(os.path.join(self.app, "Contents", "Info.plist"), "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": BUNDLE}, handle)
        self.folder = os.path.join(self.home, "Library/Application Support/cmux-next/com.example.app.debug.demo_tag")
        self.logs = os.path.join(self.home, "Library/Logs/cmux-next")
        self.said = []
        self.end = run_end_record.RunEnd(self.app, home=self.home, out=self.said.append)
        # The system's report folders are the machine's own: no test reads them.
        patch = mock.patch.object(run_end_record.bench_launch, "crash_report_candidates", lambda since, name="cmux DEV": [])
        patch.start()
        self.addCleanup(patch.stop)

    def left(self, run=None, number=None, exception=None, **more):
        """The files that a run left: `run.json`, `run.signal` (empty with no number), and the others by name."""
        os.makedirs(self.folder, exist_ok=True)
        texts = {"run.json": None if run is None else json.dumps(run), "run.signal": "" if number is None else f"{number}\n",
                 "run.exception": exception, **more}
        for name, text in texts.items():
            if text is not None:
                Path(self.folder, name).write_text(text)

    def lines(self, start):
        return [line for line in self.said if line.startswith(start)]

    def test_the_folder_is_the_apps_own_for_the_bundles_id(self):
        self.assertEqual(run_end_record.safe("a b/c.d-e_f1"), "a_b_c.d-e_f1")
        self.assertEqual((self.end.bundle, self.end.folder), (BUNDLE, self.folder))

    def test_the_last_record_is_in_the_log_whole_before_a_file_moves(self):
        self.left(RUN, signal.SIGSEGV, **{"crash-forwarder.json": "{}"})
        os.makedirs(self.logs)
        report = json.dumps({"kind": "app", "signal": 11, "ips": "/x/cmux DEV demo-tag-2026.ips", "long": "y" * 900})
        Path(self.logs, "com.example.app.debug.demo_tag-app-20261118-101010-123.json").write_text(report)
        Path(self.logs, "com.example.app.debug.other-app-20261118-101010-124.json").write_text("another bundle's")
        self.end.last()
        self.assertEqual(sorted(os.listdir(self.folder)), ["crash-forwarder.json", "run.json", "run.signal"])  # nothing changed
        self.assertTrue(all(line.startswith("LAST-END-RECORD ") for line in self.said), self.said)
        self.assertIn(f"LAST-END-RECORD run.json: {json.dumps(RUN)}", self.said)  # whole: no cut of its 600 character note
        self.assertIn("LAST-END-RECORD run.signal: 11", self.said)
        self.assertIn("LAST-END-RECORD verdict: CRASHED: signal 11 (SIGSEGV)", self.said)
        self.assertIn(f"LAST-END-RECORD com.example.app.debug.demo_tag-app-20261118-101010-123.json: {report}", self.said)
        self.assertFalse([line for line in self.said if "another bundle's" in line])
        printed = len(self.said)
        self.assertEqual(self.end.set_aside(), ["run.json", "run.signal"])
        # Only the app's 3 files move: the crash forwarder's own file stays in the folder.
        self.assertEqual((os.listdir(self.folder), sorted(os.listdir(self.folder + ".bench-prev"))), (["crash-forwarder.json"], ["run.json", "run.signal"]))
        self.assertEqual(self.said[printed:], [f"LAST-END-RECORD moved aside into {self.folder}.bench-prev: run.json, run.signal"])

    def test_a_bundle_with_no_record_says_so_and_moves_nothing(self):
        self.end.last()
        self.assertIn(f"LAST-END-RECORD bundle {BUNDLE}; folder {self.folder}; files: none", self.said)
        self.assertEqual(len(self.lines("LAST-END-RECORD verdict: no record: ")), 1)
        self.assertEqual((self.end.set_aside(), os.path.exists(self.folder + ".bench-prev")), ([], False))
        self.assertEqual(self.said[-1], f"LAST-END-RECORD moved aside into {self.folder}.bench-prev: nothing")

    def test_files_that_an_earlier_run_moved_aside_are_replaced(self):
        self.left(RUN, signal.SIGSEGV)
        self.end.set_aside()
        self.left({**RUN, "pid": 5000})
        self.assertEqual(self.end.set_aside(), ["run.json", "run.signal"])
        self.assertEqual(json.loads(Path(self.folder + ".bench-prev", "run.json").read_text())["pid"], 5000)

    def test_the_verdict_is_the_apps_own_rule(self):
        verdict = run_end_record.RunEnd.verdict
        self.assertEqual(verdict({"run.json": json.dumps(RUN), "run.signal": "15\n"}), "ended as asked: signal 15 (SIGTERM), a quit signal")
        self.assertEqual(verdict({"run.json": json.dumps(RUN), "run.signal": "6\n"}), "CRASHED: signal 6 (SIGABRT)")
        self.assertEqual(verdict({"run.json": json.dumps(RUN), "run.signal": "", "run.exception": "NSRangeException"}), "CRASHED: an uncaught exception")
        self.assertIn("did not come to its end", verdict({"run.json": json.dumps({**RUN, "quitting": True}), "run.signal": ""}))
        self.assertIn("no signal handler", verdict({"run.json": json.dumps(RUN), "run.signal": ""}))
        self.assertIn("not known", verdict({"run.signal": ""}))

    def test_a_launch_is_a_clean_one_only_when_its_own_run_json_says_no_restart(self):
        self.left({**RUN, "pid": 77})
        self.assertIsNone(self.end.launch_fault(77))
        self.assertEqual(self.said[-1], "OWN-END-RECORD at the launch: run.json is of this launch (the process 77) and says no restart")
        self.assertEqual(self.end.launch_fault(78), "launch: run.json is of the process 77, and this launch is the process 78")
        self.left({**RUN, "pid": 77, "recovery": True})
        fault = self.end.launch_fault(77)
        self.assertTrue(fault.startswith("launch: run.json says `recovery` true: the launch follows a crash or a quick kill"), fault)
        self.assertEqual(self.said[-1], f"OWN-END-RECORD at the launch: {fault}")
        os.remove(os.path.join(self.folder, "run.json"))
        self.assertTrue(self.end.launch_fault(77).startswith("launch: no run.json of this launch in "))

    def own(self, pid, **quit_fact):
        self.said.clear()
        self.end.ended = None
        return self.end.own(pid, quit_fact)

    def test_a_quit_that_came_to_its_end_is_no_crash(self):
        self.assertIs(self.own(77, ended_in_20_s=True, returncode=0), False)
        self.assertEqual(self.said, ['OWN-END-RECORD the driver\'s quit: {"ended_in_20_s": true, "returncode": 0}',
                                     "OWN-END-RECORD files after the quit: none (a quit that came to its end removes them)",
                                     "OWN-END-RECORD verdict: no crash of this run (no record of it is left)"])

    def test_a_fatal_signal_of_the_drivers_own_launch_is_a_crash(self):
        self.left({**RUN, "pid": 77}, signal.SIGSEGV)
        self.assertIs(self.own(77, ended_in_20_s=True, returncode=-11), True)
        self.assertIn("OWN-END-RECORD run.signal: 11", self.said)
        self.assertEqual(self.said[-1], "OWN-END-RECORD verdict: THIS RUN CRASHED: signal 11 (SIGSEGV) in run.signal")
        # A second call (the exit's) prints nothing more and gives the same answer.
        printed = len(self.said)
        self.assertEqual((self.end.own(77, {}), len(self.said)), (True, printed))

    def test_an_exception_or_a_process_that_a_fatal_signal_ended_is_a_crash(self):
        self.left({**RUN, "pid": 77, "quitting": True}, exception="NSInternalInconsistencyException in the quit")
        self.assertIs(self.own(77, ended_in_20_s=True, returncode=0), True)
        self.assertEqual(self.said[-1], "OWN-END-RECORD verdict: THIS RUN CRASHED: an uncaught exception in run.exception")
        __import__("shutil").rmtree(self.folder)
        self.assertIs(self.own(77, ended_in_20_s=True, returncode=-6), True)
        self.assertEqual(self.said[-1], "OWN-END-RECORD verdict: THIS RUN CRASHED: the process ended by signal 6 (SIGABRT)")

    def test_a_quit_that_the_driver_ended_with_kill_is_printed_and_is_no_crash(self):
        self.left({**RUN, "pid": 77, "quitting": True})
        self.assertIs(self.own(77, ended_in_20_s=False, killed_by_the_driver=True, returncode=-9), False)
        self.assertIn('"killed_by_the_driver": true', self.said[0])
        self.assertIn("OWN-END-RECORD verdict: no crash of this run (a quit that was asked for began and did not come to its end", self.said[-1])

    def system_report(self, name, age=100.0, bundle=BUNDLE, folder="", frames=20, path=None):
        """A report of the system's writer in the account's report folder, in its form of a header line and a body:
        the crashed thread is the second of two, with `frames` frames. Each text of it is made up here."""
        reports = os.path.join(self.home, "Library/Logs/DiagnosticReports", folder)
        os.makedirs(reports, exist_ok=True)
        head = {"app_name": "demo", "app_version": "0.1", "build_version": "7", "bundleID": bundle, "name": "demo", "bug_type": "309"}
        stack = [{"imageIndex": 0, "imageOffset": 4096 + n, "symbol": f"step_{n}", "symbolLocation": n} for n in range(frames)]
        stack[3:4] = [{"imageIndex": 0, "imageOffset": 4099}] if frames > 3 else []  # a frame with no symbol
        body = {"procName": "demo", "procPath": path or os.path.join(self.app, "Contents/MacOS/demo"),
                "exception": {"type": "EXC_BREAKPOINT", "signal": "SIGTRAP"}, "termination": {"indicator": "Trace/BPT trap: 5"},
                "faultingThread": 1,
                "threads": [{"id": 10, "frames": [{"imageIndex": 1, "imageOffset": 64, "symbol": "idle_wait", "symbolLocation": 8}]},
                            {"id": 11, "queue": "com.example.main-thread", "triggered": True, "frames": stack}],
                "usedImages": [{"name": "demo", "uuid": "0000-1111"}, {"name": "libfake.dylib", "uuid": "2222-3333"}]}
        file = Path(reports, name)
        file.write_text(json.dumps(head) + "\n" + json.dumps(body, indent=1))
        os.utime(file, (NOW - age, NOW - age))
        return file

    def test_a_system_report_is_the_bundles_by_its_own_bundle_id_whatever_its_files_name(self):
        # The system names a report after the process, and a build's process does not have the app folder's name.
        self.system_report("demo-2026-11-18-060634.ips", age=300.0)
        self.system_report("demo-2026-11-17-010101.ips", age=5000.0, folder="Retired")
        self.system_report("demo-2026-11-18-070000.ips", bundle="com.example.app.debug.other")
        self.system_report("demo-2026-11-01-010101.ips", age=15 * 86400.0)
        self.end.last(now=NOW)
        found = self.lines("LAST-END-RECORD the system's reports of this bundle from the last 14 days: ")
        self.assertEqual(len(found), 1, self.said)
        self.assertTrue(found[0].startswith("LAST-END-RECORD the system's reports of this bundle from the last 14 days: 2; the newest: "
                                            "demo-2026-11-17-010101.ips, demo-2026-11-18-060634.ips"), found)
        self.assertIn("a report is the bundle's by its own bundle id", found[0])
        self.assertFalse([line for line in self.said if "demo-2026-11-18-070000.ips" in line or "demo-2026-11-01-010101.ips" in line])

    def test_a_report_with_no_bundle_id_is_the_bundles_by_its_path_or_by_its_files_name(self):
        by_path = self.system_report("demo-2026-11-18-060634.ips", bundle=None)
        self.system_report("demo-2026-11-18-060700.ips", bundle=None, path="/another/place/demo.app/Contents/MacOS/demo")
        Path(by_path.parent, "cmux DEV demo-tag-2026-11-18-060800.ips").write_text("not a report that can be read")
        os.utime(Path(by_path.parent, "cmux DEV demo-tag-2026-11-18-060800.ips"), (NOW - 50, NOW - 50))
        self.end.last(now=NOW)
        found = self.lines("LAST-END-RECORD the system's reports of this bundle from the last 14 days: ")
        self.assertTrue(found and found[0].startswith("LAST-END-RECORD the system's reports of this bundle from the last 14 days: 2; the newest: "
                                                      "demo-2026-11-18-060634.ips, cmux DEV demo-tag-2026-11-18-060800.ips"), self.said)

    def test_no_report_folder_is_said_and_is_no_stop(self):
        self.end.last(now=NOW)
        found = self.lines("LAST-END-RECORD the system's reports of this bundle from the last 14 days: 0")
        self.assertEqual(len(found), 1, self.said)
        self.assertIn("not there or not read: ", found[0])

    def test_the_crashed_threads_first_12_frames_are_in_the_log(self):
        self.system_report("demo-2026-11-18-060634.ips")
        self.end.last(now=NOW)
        name = "LAST-END-RECORD demo-2026-11-18-060634.ips"
        self.assertIn(f"{name} crashed thread 1 (queue com.example.main-thread): 20 frames, the first 12", self.said)
        frames = self.lines(f"{name} frame ")
        self.assertEqual(len(frames), 12, self.said)
        self.assertEqual(frames[:5], [f"{name} frame 0: demo step_0 + 0", f"{name} frame 1: demo step_1 + 1", f"{name} frame 2: demo step_2 + 2",
                                      f"{name} frame 3: demo 0x1003 (no symbol)", f"{name} frame 4: demo step_4 + 4"])
        self.assertFalse([line for line in self.said if "idle_wait" in line])  # the other thread's frame

    def test_the_build_of_a_report_is_in_the_log_and_its_commit_only_when_the_report_has_one(self):
        self.system_report("demo-2026-11-18-060634.ips")
        os.makedirs(self.logs)
        Path(self.logs, "com.example.app.debug.demo_tag-app-20261118-101010-123.json").write_text(json.dumps({"kind": "app", "signal": 5, "version": "0.1 7"}))
        Path(self.logs, "com.example.app.debug.demo_tag-app-20261118-101010-124.json").write_text(
            json.dumps({"kind": "app", "signal": 5, "version": "0.1 8", "commit": "abc1234"}))
        self.left(RUN, signal.SIGTRAP)
        self.end.last(now=NOW)
        self.assertIn("LAST-END-RECORD run.json build: version 0.1 7; commit abc1234", self.said)
        # A record with no commit says so, and the tool gives none.
        self.said.clear()
        self.left({key: value for key, value in RUN.items() if key != "commit"}, signal.SIGTRAP)
        self.end.last(now=NOW)
        self.assertIn("LAST-END-RECORD run.json build: version 0.1 7; commit: not in the record", self.said)
        self.assertIn("LAST-END-RECORD com.example.app.debug.demo_tag-app-20261118-101010-123.json build: version 0.1 7; commit: not in the report", self.said)
        self.assertIn("LAST-END-RECORD com.example.app.debug.demo_tag-app-20261118-101010-124.json build: version 0.1 8; commit abc1234", self.said)
        self.assertIn("LAST-END-RECORD demo-2026-11-18-060634.ips build: version 0.1 (7); the process demo; image uuid 0000-1111; "
                      "commit: not in the report", self.said)

    def test_a_text_report_gives_the_first_12_lines_of_its_crashed_thread(self):
        reports = os.path.join(self.home, "Library/Logs/DiagnosticReports")
        os.makedirs(reports)
        text = (f"Process:               demo [1]\nIdentifier:            {BUNDLE}\nVersion:               0.1 (7)\n\n"
                "Thread 0:\n0   libfake.dylib  0x01 idle_wait + 8\n\nThread 1 Crashed:: Dispatch queue: com.example.main-thread\n"
                + "".join(f"{n}   demo  0x{4096 + n:x} step_{n} + {n}\n" for n in range(15)) + "\nThread 2:\n0   libfake.dylib  0x02 other_wait + 4\n")
        Path(reports, "demo_2026-11-18-060634_host.crash").write_text(text)
        os.utime(Path(reports, "demo_2026-11-18-060634_host.crash"), (NOW - 100, NOW - 100))
        self.end.last(now=NOW)
        name = "LAST-END-RECORD demo_2026-11-18-060634_host.crash"
        self.assertIn(f"{name} crashed thread: Thread 1 Crashed:: Dispatch queue: com.example.main-thread; 15 frames, the first 12", self.said)
        frames = self.lines(f"{name} frame ")
        self.assertEqual((len(frames), frames[0], frames[-1]), (12, f"{name} frame 0   demo  0x1000 step_0 + 0", f"{name} frame 11   demo  0x100b step_11 + 11"))
        self.assertFalse([line for line in frames if "wait" in line])  # no line of another thread

    def test_a_quit_signal_and_the_files_of_another_process_are_no_crash_of_this_run(self):
        self.left({**RUN, "pid": 77}, signal.SIGTERM)
        self.assertIs(self.own(77, ended_in_20_s=True, returncode=-15), False)
        self.left({**RUN, "pid": 900}, signal.SIGSEGV)
        self.assertIs(self.own(77, ended_in_20_s=True, returncode=0), False)
        self.assertIn("run.json is not of this launch's process 77", self.said[1])


if __name__ == "__main__":
    unittest.main()
