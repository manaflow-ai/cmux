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
    def __init__(self, out, app, pane=None, host_pid=None):
        self.out, self.app, self.seen = out, app, {}
        self.pane, self.term, self.host_pid = pane, "term_x" if pane else None, host_pid

    def view_of_pane(self, pane_id):
        return {"pane": pane_id, "host_pid": self.host_pid} if pane_id == self.pane else None

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

    BUNDLE = "/lease/app/cmux DEV x.app"

    def fake_ps(self, env=None, exe=None, ppid=None):
        """subprocess.run for `ps`, answered by its arguments: -wwE (ENV: pid -> command and environment text),
        -o comm= (EXE: pid -> executable path) and -o ppid= (PPID: pid -> parent pid)."""
        env, exe, ppid = env or {}, exe or {}, ppid or {}

        def run(argv, **kw):
            pid = int(argv[-1])
            if argv[:2] == ["ps", "-wwE"]:
                out = "  PID   TT  STAT      TIME COMMAND\n" + (f"  {pid}   ??  Ss   0:01.00 {env[pid]}\n" if pid in env else "")
            elif argv[:3] == ["ps", "-o", "comm="]:
                out = exe.get(pid, "") + "\n"
            elif argv[:3] == ["ps", "-o", "ppid="]:
                out = f"{ppid[pid]}\n" if pid in ppid else ""
            else:
                raise AssertionError(f"unexpected command {argv}")
            return subprocess.CompletedProcess(argv, 0, out, "")
        return run

    def arm(self, daemon_env, want, j=None, **ps):
        j = j or FakeJourney(self.out, FakeApp())
        env = {**ps.pop("env", {}), 200: daemon_env}
        exe = {**ps.pop("exe", {}), 200: f"{self.BUNDLE}/Contents/Resources/bin/cmux"}
        # host_now reads CLOCK_UPTIME_RAW, which only macOS has; the arm proof does not depend on it.
        with mock.patch.object(self.load.subprocess, "run", side_effect=self.fake_ps(env, exe, ps.pop("ppid", {}))), \
                mock.patch.object(self.load, "host_now", return_value=1.0):
            return self.load.step_daemon_arm(j, {"as": "before", "want": want})

    PS_ON = ("/x/cmux DEV x.app/Contents/Resources/bin/cmux --headless --session s HOME=/h CMUX_TRACE_FLOWS=/o "
             "CMUX_TUI_RDS_INPUT=1 SECRET_TOKEN=abc")
    PS_OFF = "/x/cmux DEV x.app/Contents/Resources/bin/cmux --headless HOME=/h"

    def test_arm_proof(self):
        rec = self.arm(self.PS_ON, "on")
        self.assertTrue(rec["on"])
        self.assertEqual(rec["words"], ["CMUX_TUI_RDS_INPUT=1"])
        self.assertEqual(rec["exe"], f"{self.BUNDLE}/Contents/Resources/bin/cmux")  # the whole path, spaces too
        kept = json.loads((self.out / "daemon-arm-before.json").read_text())
        self.assertNotIn("SECRET_TOKEN", json.dumps(kept))  # only the switch words are kept
        self.assertFalse(self.arm(self.PS_OFF, "off")["on"])
        with self.assertRaises(self.load.D.NotRun):
            self.arm(self.PS_OFF, "on")
        with self.assertRaises(self.load.D.NotRun):
            self.arm(self.PS_ON, "off")

    def test_arm_proof_names_the_typing_host_and_its_flow_trace(self):
        j = FakeJourney(self.out, FakeApp(), pane="pane_t", host_pid=300)
        rec = self.arm(self.PS_ON, "on", j=j, env={300: "/x/host CMUX_TRACE_FLOWS=/o/flows TOKEN=abc"})
        self.assertEqual(rec["host"]["pid"], 300)
        self.assertEqual(rec["host"]["found_by"], "pane view host_pid")
        self.assertTrue(rec["host"]["trace_flows"])
        self.assertEqual(rec["host"]["words"], ["CMUX_TRACE_FLOWS=/o/flows"])
        self.assertNotIn("TOKEN", (self.out / "daemon-arm-before.json").read_text())

    def test_adopted_host_without_a_view_pid_is_the_echo_programs_bundle_ancestor(self):
        # The adopted set-up terminal: its host came from the old daemon (no CMUX_TRACE_FLOWS). The pane view names
        # no host, so the echo program's parents are walked: echo.py 400 <- login 350 <- host 300 (in the bundle).
        app = FakeApp()
        app.bundle = self.BUNDLE
        j = FakeJourney(self.out, app, pane="pane_t", host_pid=None)
        j.echo_log = self.out / "echo.jsonl"
        j.echo_log.write_text('{"t": 1.0, "ready": true, "pid": 400}\n')
        rec = self.arm(self.PS_ON, "on", j=j, env={300: "/x/host HOME=/h"}, ppid={400: 350, 350: 300},
                       exe={350: "/usr/bin/login", 300: f"{self.BUNDLE}/Contents/Resources/bin/cmux"})
        self.assertEqual(rec["host"]["pid"], 300)
        self.assertEqual(rec["host"]["found_by"], "echo program's ancestor in the app bundle")
        self.assertFalse(rec["host"]["trace_flows"])
        self.assertEqual(rec["host"]["words"], [])

    def test_no_host_found_is_recorded_not_raised(self):
        j = FakeJourney(self.out, FakeApp(), pane="pane_t", host_pid=None)
        rec = self.arm(self.PS_ON, "on", j=j)
        self.assertIsNone(rec["host"]["pid"])

    def test_server_stats_sends_the_raw_line_and_keeps_the_reply(self):
        app = FakeApp()
        j = FakeJourney(self.out, app)
        sent = []
        reply = {"id": 1, "ok": True, "result": {"locks": {"registry": {}, "state": {"by_hold_p99": []}}}}

        def ask(path, message, timeout=5.0):
            sent.append((path, message))
            return reply
        with mock.patch.object(self.load.D, "unix_request", side_effect=ask), \
                mock.patch.object(self.load, "host_now", return_value=2.0):
            rec = self.load.step_server_stats(j, {"as": "after", "include": ["locks"]})
        self.assertEqual(sent, [("/fake/daemon.sock", {"id": 1, "cmd": "server-stats", "include": ["locks"]})])
        kept = json.loads((self.out / "server-stats-after.json").read_text())
        self.assertEqual(kept["reply"], reply)
        self.assertEqual(kept["daemon_pid"], 200)
        self.assertEqual(rec["locks"], ["registry", "state"])

    def test_server_stats_without_an_answer_is_kept_as_missing(self):
        j = FakeJourney(self.out, FakeApp())
        with mock.patch.object(self.load.D, "unix_request", return_value={}), \
                mock.patch.object(self.load, "host_now", return_value=2.0):
            rec = self.load.step_server_stats(j, {"as": "before"})
        self.assertFalse(rec["answered"])
        self.assertIn("missing", json.loads((self.out / "server-stats-before.json").read_text())["reply"])


class Journeys(unittest.TestCase):
    """typing/gen_load.py: the adopted variant types into the set-up terminal; the new-tab one into a new tab."""

    def test_adopted_and_new_tab_targets(self):
        sys.path.insert(0, str(HERE / "typing"))
        import gen_load
        new_tab, adopted = gen_load.rds_journey("on"), gen_load.rds_journey("on", target="adopted")
        self.assertEqual(adopted["id"], "typing-load-l6-rds-adopted-on")
        self.assertEqual(new_tab["id"], "typing-load-l6-rds-on")
        lines = lambda spec: [s["line"] for s in spec["steps"] if s["do"] == "smoke_adopt_line"]
        self.assertEqual(lines(adopted), ["typing-${nonce}", "typing-${nonce}"])
        self.assertEqual(lines(new_tab), ["typing-${nonce}", "typing-${nonce}", "rds-${nonce}"])
        for spec in (new_tab, adopted):
            steps = [(s["do"], s.get("as")) for s in spec["steps"]]
            relaunch = next(s for s in spec["steps"] if s["do"] == "probe_relaunch")
            self.assertEqual(relaunch["env"], {"CMUX_NEXT_TUI_RDS_INPUT": "1"})
            self.assertTrue(relaunch["new_daemon"])
            for want in (("daemon_arm", "before"), ("daemon_arm", "after"), ("server_stats", "before"),
                         ("server_stats", "after")):
                self.assertIn(want, steps)
            # the typed terminal is adopted before echo.py starts in it
            self.assertLess(max(i for i, s in enumerate(spec["steps"]) if s["do"] == "smoke_adopt_line"),
                            next(i for i, s in enumerate(spec["steps"]) if s["do"] == "echo_start"))


class ResultFetch(unittest.TestCase):
    """run.py take_results: a flow file has its own cap, and a dropped member is logged with its size."""

    def setUp(self):
        sys.argv = ["run.py"]
        import run
        self.run = run
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def tar(self, members):
        import io
        import tarfile
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for name, data in members:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        return buf.getvalue()

    def test_flow_file_over_the_result_cap_is_kept_and_drops_are_logged(self):
        j = "typing-load-l6-rds-on"
        big = b"x" * 2048
        files = self.tar([(f"{j}/flows/flows-22491.jsonl", big), (f"{j}/server-stats-after.json", b"{}"),
                          (f"{j}/probe.csv", big), (f"{j}/flows/other.bin", b"y")])
        logged = []
        with mock.patch.object(self.run, "RESULT_MAX_BYTES", 1024), \
                mock.patch.object(self.run, "log", side_effect=logged.append):
            self.run.take_results(files, self.out, {j})
        kept = sorted(str(p.relative_to(self.out)) for p in self.out.rglob("*") if p.is_file())
        self.assertEqual(kept, [f"{j}/flows/flows-22491.jsonl", f"{j}/server-stats-after.json"])
        self.assertEqual((self.out / j / "flows" / "flows-22491.jsonl").read_bytes(), big)
        self.assertTrue(any("probe.csv" in line and "2048 bytes" in line for line in logged), logged)
        self.assertTrue(any("other.bin" in line for line in logged), logged)


if __name__ == "__main__":
    unittest.main()
