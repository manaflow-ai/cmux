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

    def test_a_quit_signal_and_the_files_of_another_process_are_no_crash_of_this_run(self):
        self.left({**RUN, "pid": 77}, signal.SIGTERM)
        self.assertIs(self.own(77, ended_in_20_s=True, returncode=-15), False)
        self.left({**RUN, "pid": 900}, signal.SIGSEGV)
        self.assertIs(self.own(77, ended_in_20_s=True, returncode=0), False)
        self.assertIn("run.json is not of this launch's process 77", self.said[1])


if __name__ == "__main__":
    unittest.main()
