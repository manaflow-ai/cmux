#!/usr/bin/env python3
"""A crash of the app under test during a lease fails every journey of that lease (run.py), no fleet, no app.

    python3 scripts/journeys/test_crash_fails_gate.py

v2.2.4-opt (job 0fd2bb11383cf1d14e6bc4c9) crashed in its slot with SIGSEGV in Chromium's
RenderWidgetHostImpl::OnSnapshotFromSurfaceReceived, relaunched to Home, and the journeys failed only on a frame
check that named no crash; on other runs the relaunch could hide it and a journey pass. A crash report on the mini,
newer than the lease and naming the app under test, now fails each journey of that lease with the report's name,
signal and top frames as evidence (the dogfood gate rule: any crash of the app during the gate fails it).
"""
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import run as R  # noqa: E402

CRASH = {"file": "cmux-2026-10-28-034133.ips", "signal": "SIGSEGV", "exception": "EXC_BAD_ACCESS",
         "frames": ["content::RenderWidgetHostImpl::OnSnapshotFromSurfaceReceived(int, int)",
                    "base::internal::Invoker<...>::RunOnce"]}


class CrashFailsGateTests(unittest.TestCase):
    def test_a_crash_fails_every_journey_of_the_lease_even_a_pass(self):
        results = {"type": {"status": "pass", "reason": ""}, "ctrl-c": {"status": "fail", "reason": "frame"},
                   "clear": {"status": "not run", "reason": "deadline"}}
        got = R.crashed_results(results, [CRASH])
        for journey in ("type", "ctrl-c", "clear"):
            self.assertEqual(got[journey]["status"], "fail", journey)
            self.assertIn("app crashed during the lease", got[journey]["reason"])
            self.assertIn("SIGSEGV", got[journey]["reason"])
            self.assertIn("OnSnapshotFromSurfaceReceived", got[journey]["reason"])
            self.assertEqual(got[journey]["crashes"], [CRASH])
        self.assertIn("frame", got["ctrl-c"]["reason"], "the journey's own reason stays")

    def test_a_deliberate_debug_crash_does_not_fail_the_lease(self):
        """app-life-crash-recovers ends the app with debug.crash.app on purpose (DebugCrashes.crashApp): that report
        is the journey's own step, not a crash of the build."""
        deliberate = {"file": "cmux-2026-10-28-040150.ips", "signal": "SIGSEGV", "exception": "EXC_CRASH",
                      "frames": ["__pthread_kill", "pthread_kill", "raise", "specialized static DebugCrashes.crashApp(_:_:)"]}
        results = {"app-life-crash-recovers": {"status": "pass", "reason": ""}}
        self.assertEqual(R.crashed_results(results, [deliberate]), results)
        got = R.crashed_results(results, [deliberate, CRASH])
        self.assertEqual(got["app-life-crash-recovers"]["status"], "fail")
        self.assertIn("OnSnapshotFromSurfaceReceived", got["app-life-crash-recovers"]["reason"])
        self.assertEqual(got["app-life-crash-recovers"]["crashes"], [CRASH])

    def test_no_crash_changes_nothing(self):
        results = {"type": {"status": "pass", "reason": ""}}
        self.assertEqual(R.crashed_results(results, []), results)

    def test_the_listing_keeps_only_valid_reports(self):
        listing = "\n".join([json.dumps(CRASH), "not json", json.dumps({"file": "x.ips"}), ""])
        self.assertEqual(R.parse_crash_listing(listing), [CRASH, {"file": "x.ips", "signal": "", "exception": "", "frames": []}])

    def test_the_listing_script_matches_only_this_slots_app_on_a_real_report_shape(self):
        """Runs the script's program here on a fake DiagnosticReports folder: the slot's report (coalitionName = its
        bundle id) is listed, another slot's and an older one are not."""
        import os, subprocess, tempfile, time
        with tempfile.TemporaryDirectory() as home:
            reports = Path(home, "Library/Logs/DiagnosticReports")
            reports.mkdir(parents=True)
            def report(name, coalition, age):
                body = {"procPath": "/Users/Shared/*/cmux DEV x.app/Contents/MacOS/cmux", "coalitionName": coalition,
                        "faultingThread": 0, "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"},
                        "threads": [{"frames": [{"symbol": "content::RenderWidgetHostImpl::OnSnapshotFromSurfaceReceived"}]}]}
                path = reports / name
                path.write_text(json.dumps({"app_name": "cmux"}) + "\n" + json.dumps(body))
                os.utime(path, (time.time() - age, time.time() - age))
            report("mine.ips", "com.x.capslot1", 5)
            report("other-slot.ips", "com.x.capslot2", 5)
            report("old.ips", "com.x.capslot1", 3600)
            script = R.crash_listing_script("/Users/Shared/cmux-capture/slots/1/lease-ab/app/cmux DEV x.app",
                                            "com.x.capslot1", time.time() - 60)
            listed = subprocess.run(["sh", "-c", script.replace("/usr/bin/python3", sys.executable)], capture_output=True,
                                    text=True, env={**os.environ, "HOME": home}, check=True).stdout
        crashes = R.parse_crash_listing(listed)
        self.assertEqual([c["file"] for c in crashes], ["mine.ips"])
        self.assertEqual(crashes[0]["signal"], "SIGSEGV")
        self.assertIn("OnSnapshotFromSurfaceReceived", crashes[0]["frames"][0])


if __name__ == "__main__":
    unittest.main()
