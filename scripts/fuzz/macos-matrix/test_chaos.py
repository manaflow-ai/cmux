#!/usr/bin/env python3
"""Offline checks of chaos.py's verdicts, with a fake guest (no VM, no VNC, no app).

Run: python3 -I scripts/fuzz/macos-matrix/test_chaos.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import chaos  # noqa: E402
import smoke  # noqa: E402


class FakeVNC:
    def __init__(self, *_):
        pass

    def screenshot_png(self) -> bytes:
        return b"png"


class FakeGuest:
    """Answers the guest commands chaos.py sends; `reports` are (mtime, path) of DiagnosticReports."""

    def __init__(self):
        self.app = "/Users/admin/fuzzapp/cmux DEV.app"
        self.socket = "/tmp/cmux-x.sock"
        self.env = ""
        self.binary = ""
        self.reports: list[tuple[int, str]] = []
        self.app_pid: int | None = 4242
        self.pings: list[int | None] = []
        self.commands: list[str] = []

    def sh(self, cmd: str, timeout: float = 30) -> subprocess.CompletedProcess:
        self.commands.append(cmd)
        out = ""
        if "DiagnosticReports" in cmd:
            out = "".join(f"{int(m)} {p}\n" for m, p in self.reports)
        return subprocess.CompletedProcess(cmd, 0, out, "")

    def cmux(self, args, timeout: float = 15) -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess(args, 0, "{}\n", "")

    def _cli(self, args) -> str:
        return "cmux " + " ".join(args)

    def pid(self):
        return self.app_pid

    def ping_ms(self, timeout: float, *_args, **_kw):
        return self.pings.pop(0) if self.pings else 20


class ChaosVerdicts(unittest.TestCase):
    def setUp(self):
        smoke.RFB = FakeVNC
        chaos.REPORT_DEADLINE = 0
        self.out = tempfile.mkdtemp(prefix="chaos-test-")
        self.g = FakeGuest()
        self.c = chaos.Chaos(self.g, "127.0.0.1:5900:pw", self.out)
        self.c.app_pid = 4242
        self.c.quit = lambda: setattr(self.c, "app_pid", None)

    def result(self) -> dict:
        return json.load(open(os.path.join(self.out, "result.json")))

    def test_every_fault_has_a_phase_and_a_method(self):
        for name, (phase, expected) in chaos.FAULTS.items():
            self.assertIn(phase, chaos.PHASES, name)
            self.assertTrue(expected, name)
            self.assertTrue(callable(getattr(chaos.Chaos, "fault_" + name.replace("-", "_"), None)), name)

    def test_ok_fault_needs_the_same_pid_and_answered_pings(self):
        self.c.fault_acpmux = lambda: (True, {"echo": True})
        self.assertEqual(self.c.run_fault("acpmux", "app")["outcome"], "ok")
        self.g.pings = [20, chaos.PING_BOUND_MS, 20]  # one ping ran into its bound: a hang
        self.assertEqual(self.c.run_fault("acpmux", "app")["outcome"], "FAIL")
        self.g.app_pid = 5000  # the app died and something restarted it
        row = self.c.run_fault("acpmux", "app")
        self.assertEqual((row["outcome"], row["app_pid_kept"]), ("FAIL", False))

    def test_skip_and_runner_errors_are_rows(self):
        def cannot():
            raise chaos.Skip("no passwordless sudo in the guest")
        self.c.fault_memory_pressure = cannot
        self.c.fault_daemon = lambda: 1 / 0
        skip = self.c.run_fault("memory-pressure", "app")
        fail = self.c.run_fault("daemon", "app")
        self.assertEqual((skip["outcome"], skip["detail"]), ("skip", "no passwordless sudo in the guest"))
        self.assertEqual(fail["outcome"], "FAIL")
        self.assertIn("ZeroDivisionError", fail["detail"]["error"])

    def test_a_skip_is_no_pass(self):
        self.c.result["faults"] = [{"fault": "acpmux", "outcome": "skip", "ok": False, "crash_reports": []}]
        self.c.finish()
        r = self.result()
        self.assertFalse(r["ok"])
        self.assertEqual((r["skipped"], r["failed_steps"]), (["acpmux"], []))

    def test_crash_reports_go_to_the_fault_whose_window_holds_them(self):
        t = self.c.since + 100
        self.c.result["faults"] = [
            {"fault": "daemon", "outcome": "ok", "ok": True, "window": [t, t + 10], "crash_reports": []},
            {"fault": "acpmux", "outcome": "ok", "ok": True, "window": [t + 20, t + 30], "crash_reports": []},
        ]
        base = "/Users/admin/Library/Logs/DiagnosticReports/"
        self.g.reports = [(t + 25, base + "cmux DEV-2026-10-26-1.ips"),  # late report: the second fault's
                          (t + 22, base + "cmux DEV-2026-10-26-2.hang")]  # a hang report is no crash
        self.c.finish()
        r = self.result()
        daemon, acpmux = r["faults"]
        self.assertEqual((daemon["outcome"], acpmux["outcome"]), ("ok", "FAIL"))
        self.assertEqual(acpmux["crash_reports"], ["cmux DEV-2026-10-26-1.ips"])
        self.assertEqual((r["crashes"], r["failed_steps"], r["ok"]), (1, ["acpmux"], False))

    def test_a_crash_before_any_fault_fails_the_run(self):
        t = self.c.since + 100
        self.c.result["faults"] = [{"fault": "daemon", "outcome": "ok", "ok": True, "window": [t, t + 10],
                                    "crash_reports": []}]
        self.g.reports = [(t - 50, "/Library/Logs/DiagnosticReports/cmux DEV-tour.ips")]
        self.c.finish()
        r = self.result()
        self.assertEqual(r["crashes_outside_faults"], ["cmux DEV-tour.ips"])
        self.assertFalse(r["ok"])

    def test_all_ok_is_a_pass(self):
        t = self.c.since + 100
        self.c.result["faults"] = [{"fault": f, "outcome": "ok", "ok": True, "window": [t, t + 1], "crash_reports": []}
                                   for f in chaos.FAULTS]
        self.c.finish()
        self.assertTrue(self.result()["ok"])

    def test_owned_processes(self):
        self.c.bundle_id = "com.cmuxterm.app.debug.tag"
        self.assertTrue(self.c.owned(self.g.app + "/Contents/MacOS/cmux-tui --headless"))
        self.assertTrue(self.c.owned("cmux-tui-host __holder --owner com.cmuxterm.app.debug.tag:tag@12"))
        self.assertFalse(self.c.owned("cmux-tui-host __holder --owner com.cmuxterm.app:-@12"))

    def test_network_off_turns_pf_on_in_the_foreground(self):
        """Only the off-timer may run in the background: the token must reach the host."""
        self.c.tabs["cef"] = "tab1"
        self.g.sh = lambda cmd, timeout=30: self.capture(cmd)
        self.captured: list[str] = []
        with self.assertRaises(chaos.Skip):  # the fake prints no token
            self.c.fault_network_off()
        on = next(c for c in self.captured if "pfctl -E" in c)
        foreground, _, background = on.partition("( sleep")
        self.assertIn("pfctl -E", foreground)
        self.assertNotIn("&", foreground.replace("2>&1", ""))
        self.assertIn(f"{chaos.NETWORK_OFF_SECONDS};", background)

    def capture(self, cmd):
        self.captured.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, "", "")


if __name__ == "__main__":
    unittest.main()
