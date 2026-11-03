#!/usr/bin/env python3
"""The R-DAEMON-STATE S1 typing A/B arms (STATUS 10117): probe_relaunch's `env` reaches the reopen's launch
variables, `new_daemon` stops the old daemon while no app runs (between the quit and the reopen), and daemon_arm
passes only when the daemon's environment matches the arm.

    python3 scripts/journeys/test_ext_load_rds.py
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))  # build_names.py


class FakeApp:
    cli, home, pid = "/fake/cmux", "/fake/home", 100

    def __init__(self, daemon_pid=200):
        self.daemon_state, self.alive_pids, self.calls = {"pid": daemon_pid}, {daemon_pid}, []

    def launch_env(self):
        return {"HOME": self.home, "CMUX_NEXT_CONFIG_FILE": "/fake/config.json"}

    def daemon_socket(self):
        return "/fake/daemon.sock"

    def alive(self, pid):
        return pid in self.alive_pids


class FakeJourney:
    def __init__(self, out, app):
        self.out, self.app, self.seen = out, app, {}

    def step_relaunch(self, step):
        # As driver.py: launch variables read first, the hook between the quit and the reopen.
        self.seen["env"] = self.app.launch_env()
        self.seen["hook"] = step["before_reopen"]() if callable(step.get("before_reopen")) else None
        return {"how": step["how"]}


class RdsArms(unittest.TestCase):
    def setUp(self):
        import driver
        import ext_load
        self.load = ext_load
        ext_load.install(driver)
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def stop_ok(self, app):
        def run(argv, **kw):
            app.calls.append(argv)
            if argv[1:] == ["--socket", "/fake/daemon.sock", "--json", "server", "stop"]:
                app.alive_pids.discard(200)
            return subprocess.CompletedProcess(argv, 0, '{"ok":true}', "")
        return run

    def test_on_arm_env_and_new_daemon(self):
        app = FakeApp()
        j = FakeJourney(self.out, app)
        with mock.patch.object(self.load.subprocess, "run", side_effect=self.stop_ok(app)):
            rec = self.load.step_probe_relaunch(j, {"mark": "probed", "new_daemon": True,
                                                    "env": {"CMUX_NEXT_TUI_RDS_INPUT": "1"}})
        self.assertEqual(j.seen["env"]["CMUX_NEXT_TUI_RDS_INPUT"], "1")
        self.assertIn("CMUX_NEXT_TYPING_PROBE", j.seen["env"])
        self.assertEqual(j.seen["hook"]["old_daemon_pid"], 200)
        self.assertEqual(app.calls, [["/fake/cmux", "--socket", "/fake/daemon.sock", "--json", "server", "stop"]])
        self.assertTrue(rec["new_daemon"])
        self.assertFalse(hasattr(app, "_daemon_sock") and app._daemon_sock)

    def test_off_arm_adds_no_switch_and_no_stop_without_new_daemon(self):
        app = FakeApp()
        j = FakeJourney(self.out, app)
        self.load.step_probe_relaunch(j, {"mark": "probed"})
        self.assertNotIn("CMUX_NEXT_TUI_RDS_INPUT", j.seen["env"])
        self.assertIsNone(j.seen["hook"])

    def test_daemon_that_does_not_stop_is_not_run(self):
        app = FakeApp()
        j = FakeJourney(self.out, app)
        never = lambda argv, **kw: subprocess.CompletedProcess(argv, 1, "", "refused")
        with mock.patch.object(self.load.subprocess, "run", side_effect=never), \
                mock.patch.object(self.load.time, "sleep"), \
                mock.patch.object(self.load.D, "now", side_effect=[0.0, 0.0] + [100.0] * 10):
            with self.assertRaises(self.load.D.NotRun):
                self.load.step_probe_relaunch(j, {"new_daemon": True})

    def arm(self, ps_text, want):
        app = FakeApp()
        j = FakeJourney(self.out, app)
        done = subprocess.CompletedProcess([], 0, ps_text, "")
        # host_now reads CLOCK_UPTIME_RAW, which only macOS has; the arm proof does not depend on it.
        with mock.patch.object(self.load.subprocess, "run", return_value=done), \
                mock.patch.object(self.load, "host_now", return_value=1.0):
            return self.load.step_daemon_arm(j, {"as": "before", "want": want})

    PS_ON = ("  PID   TT  STAT      TIME COMMAND\n  200   ??  Ss   0:01.00 /x/cmux-tui --headless --session s "
             "HOME=/h CMUX_TRACE_FLOWS=/o CMUX_TUI_RDS_INPUT=1 SECRET_TOKEN=abc\n")
    PS_OFF = "  PID   TT  STAT      TIME COMMAND\n  200   ??  Ss   0:01.00 /x/cmux-tui --headless HOME=/h\n"

    def test_arm_proof(self):
        rec = self.arm(self.PS_ON, "on")
        self.assertTrue(rec["on"])
        self.assertEqual(rec["words"], ["CMUX_TUI_RDS_INPUT=1"])
        kept = json.loads((self.out / "daemon-arm-before.json").read_text())
        self.assertNotIn("SECRET_TOKEN", json.dumps(kept))  # only the switch words are kept
        self.assertFalse(self.arm(self.PS_OFF, "off")["on"])
        with self.assertRaises(self.load.D.NotRun):
            self.arm(self.PS_OFF, "on")
        with self.assertRaises(self.load.D.NotRun):
            self.arm(self.PS_ON, "off")


if __name__ == "__main__":
    unittest.main()
