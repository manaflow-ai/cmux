#!/usr/bin/env python3
"""The R-DAEMON-STATE S1 typing A/B arms (STATUS 10117): probe_relaunch's `env` reaches the reopen's launch
variables, `new_daemon` stops the old daemon while no app runs (between the quit and the reopen), and daemon_arm
passes only when the daemon's environment matches the arm.

    python3 scripts/journeys/test_ext_load_rds.py
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
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

    PS_ZERO = "/x/cmux DEV x.app/Contents/Resources/bin/cmux --headless HOME=/h CMUX_TUI_RDS_INPUT=0"

    def arm_value(self, daemon_env, want, value):
        j = FakeJourney(self.out, FakeApp())
        exe = {200: f"{self.BUNDLE}/Contents/Resources/bin/cmux"}
        with mock.patch.object(self.load.subprocess, "run", side_effect=self.fake_ps({200: daemon_env}, exe)), \
                mock.patch.object(self.load, "host_now", return_value=1.0):
            return self.load.step_daemon_arm(j, {"as": "before", "want": want, "value": value})

    def test_off_arm_that_sets_zero_needs_the_zero_word(self):
        # After S1.7 an unset switch is ON: an OFF arm proves off only by CMUX_TUI_RDS_INPUT=0 in the daemon.
        rec = self.arm_value(self.PS_ZERO, "off", "0")
        self.assertEqual((rec["on"], rec["words"], rec["value"]), (False, ["CMUX_TUI_RDS_INPUT=0"], "0"))
        with self.assertRaises(self.load.D.NotRun):
            self.arm_value(self.PS_OFF, "off", "0")    # unset: ON on an S1.7 build, so not proven off
        with self.assertRaises(self.load.D.NotRun):
            self.arm_value(self.PS_ON, "off", "0")
        self.assertTrue(self.arm_value(self.PS_ON, "on", "1")["on"])
        with self.assertRaises(self.load.D.NotRun):
            self.arm_value(self.PS_ZERO, "on", "1")

    def arm_unset(self, daemon_env):
        j = FakeJourney(self.out, FakeApp())
        exe = {200: f"{self.BUNDLE}/Contents/Resources/bin/cmux"}
        step = {"as": "before", "want": "unset", "names": ["CMUX_TUI_RDS_INPUT", "CMUX_NEXT_TUI_RDS_INPUT"]}
        with mock.patch.object(self.load.subprocess, "run", side_effect=self.fake_ps({200: daemon_env}, exe)), \
                mock.patch.object(self.load, "host_now", return_value=1.0):
            return self.load.step_daemon_arm(j, step)

    def test_unset_arm_needs_neither_variable(self):
        rec = self.arm_unset(self.PS_OFF)
        self.assertEqual((rec["words"], rec["on"]), ([], False))
        for env in (self.PS_ON, self.PS_ZERO, self.PS_OFF + " CMUX_NEXT_TUI_RDS_INPUT=1",
                    self.PS_OFF + " CMUX_NEXT_TUI_RDS_INPUT=0"):
            with self.assertRaises(self.load.D.NotRun, msg=env):
                self.arm_unset(env)

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


class EchoStop(unittest.TestCase):
    """ext_load echo_stop: ends the journey's own echo.py (SIGTERM) and waits for its end record; any other pid is
    refused and left alone."""

    def setUp(self):
        import driver
        import ext_load
        self.load = ext_load
        ext_load.install(driver)
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.log = self.out / "echo.jsonl"
        self.j = FakeJourney(self.out, FakeApp())
        self.j.echo_log = self.log
        self.children = []

    def tearDown(self):
        for pid in self.children:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
        self.tmp.cleanup()

    def start_echo(self):
        import pty
        sys.path.insert(0, str(HERE / "typing"))
        import test_echo
        pid, fd = pty.fork()
        if pid == 0:
            os.execv(sys.executable, [sys.executable, "-I", "-c", test_echo.WRAP, str(test_echo.ECHO), str(self.log)])
        self.children.append(pid)
        self.addCleanup(os.close, fd)
        end = time.monotonic() + 10
        while time.monotonic() < end and not (self.log.exists() and '"ready"' in self.log.read_text()):
            time.sleep(0.02)
        os.write(fd, b"ab")
        time.sleep(0.2)
        return pid

    def test_ends_the_journeys_echo_and_waits_for_its_records(self):
        pid = self.start_echo()
        rec = self.load.step_echo_stop(self.j, {"timeout": 10})
        self.assertEqual((rec["pid"], rec["why"]), (pid, f"signal {int(signal.SIGTERM)}"))
        reads = [json.loads(l) for l in self.log.read_text().splitlines() if '"bytes"' in l]
        self.assertEqual(b"".join(bytes.fromhex(r["bytes"]) for r in reads), b"ab")
        self.assertEqual(self.load.step_echo_stop(self.j, {}), {"already_ended": True})  # again in finally

    def test_another_process_is_refused_and_left_running(self):
        other = subprocess.Popen(["sleep", "30"])
        self.children.append(other.pid)
        self.log.write_text(json.dumps({"t": 1.0, "ready": True, "pid": other.pid}) + "\n")
        with self.assertRaises(self.load.D.NotRun):
            self.load.step_echo_stop(self.j, {"timeout": 1})
        self.assertIsNone(other.poll())

    def test_no_echo_program_is_nothing_to_do(self):
        j = FakeJourney(self.out, FakeApp())
        self.assertEqual(self.load.step_echo_stop(j, {}), {"skipped": "no echo program started"})


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
            self.assertEqual({(s["as"], s["want"], s["value"]) for s in spec["steps"] if s["do"] == "daemon_arm"},
                             {("before", "on", "1"), ("after", "on", "1")})
            self.assertTrue(relaunch["new_daemon"])
            for want in (("daemon_arm", "before"), ("daemon_arm", "after"), ("server_stats", "before"),
                         ("server_stats", "after")):
                self.assertIn(want, steps)
            # the L1 storm runs 12 workers at the same 120 calls/s
            load = next(s for s in spec["steps"] if s["do"] == "load_start")
            self.assertEqual(load["args"], ["--rate", "120", "--devtools", "--workers", "12"])
            # echo.py writes its records when it ends: the journey ends it after its last check and in finally
            self.assertEqual(spec["steps"][-1], {"do": "echo_stop"})
            self.assertEqual(spec["finally"][0], {"do": "echo_stop"})
            # the typed terminal is adopted before echo.py starts in it
            self.assertLess(max(i for i, s in enumerate(spec["steps"]) if s["do"] == "smoke_adopt_line"),
                            next(i for i, s in enumerate(spec["steps"]) if s["do"] == "echo_start"))


class UnsetJourney(unittest.TestCase):
    """typing-load-l6-unset is typing-load-l6 (the gated journey) plus two read-only daemon_arm steps."""

    def test_gated_journey_plus_two_proofs(self):
        sys.path.insert(0, str(HERE / "typing"))
        import gen_load
        unset, gated = gen_load.unset_journey(), gen_load.journey("L6", True)
        self.assertEqual(unset["id"], "typing-load-l6-unset")
        self.assertEqual([s for s in unset["steps"] if s["do"] != "daemon_arm"], gated["steps"])
        self.assertEqual(unset["finally"], gated["finally"])
        proofs = [s for s in unset["steps"] if s["do"] == "daemon_arm"]
        self.assertEqual([(p["as"], p["want"]) for p in proofs], [("before", "unset"), ("after", "unset")])
        self.assertTrue(all(p["names"] == ["CMUX_TUI_RDS_INPUT", "CMUX_NEXT_TUI_RDS_INPUT"] for p in proofs))
        relaunch = next(s for s in unset["steps"] if s["do"] == "probe_relaunch")
        self.assertNotIn("env", relaunch)
        self.assertNotIn("new_daemon", relaunch)


class OffArm(unittest.TestCase):
    """The OFF journey sets the switch to 0 and proves CMUX_TUI_RDS_INPUT=0 (an unset switch is ON after S1.7)."""

    def test_off_journey_sets_zero_and_proves_it(self):
        sys.path.insert(0, str(HERE / "typing"))
        import gen_load
        spec = gen_load.rds_journey("off")
        relaunch = next(s for s in spec["steps"] if s["do"] == "probe_relaunch")
        self.assertEqual(relaunch["env"], {"CMUX_NEXT_TUI_RDS_INPUT": "0"})
        self.assertEqual({(s["as"], s["want"], s["value"]) for s in spec["steps"] if s["do"] == "daemon_arm"},
                         {("before", "off", "0"), ("after", "off", "0")})


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

    def arm_file(self, j, side, daemon, host):
        (self.out / j).mkdir(parents=True, exist_ok=True)
        (self.out / j / f"daemon-arm-{side}.json").write_text(json.dumps({"pid": daemon, "host": {"pid": host}}))

    def fetch(self, left_s=400.0, fail_flows=False):
        """fetch_in_lease with `remote` faked; the scripts it ran are returned. LEFT_S: lease seconds left."""
        calls = []

        def remote(host, script, **kw):
            calls.append((script, kw.get("timeout")))
            if "/flows/" in script:
                if fail_flows:
                    raise subprocess.TimeoutExpired(script, kw.get("timeout") or 0)
                return subprocess.CompletedProcess(script, 0, self.tar([("j/flows/flows-100.jsonl", b"{}"),
                                                                         ("j/flows/flows-200.jsonl", b"{}")]), b"")
            return subprocess.CompletedProcess(script, 0, b"", b"")
        left = lambda cap: max(10.0, min(cap, left_s))
        with mock.patch.object(self.run, "remote", side_effect=remote), mock.patch.object(self.run, "log"):
            self.run.fetch_in_lease("cmux21", "/lease/journeys", self.out, {"j"}, left)
        return calls

    def test_fetches_only_the_named_flow_files_in_the_lease(self):
        self.arm_file("j", "before", 100, 200)
        self.arm_file("j", "after", 100, 200)
        calls = self.fetch()
        self.assertEqual(len(calls), 1)               # the flow files only: the movies are parked, not fetched here
        flows = calls[0][0]
        for name in ("j/flows/flows-100.jsonl", "j/flows/*-100.recording.cmxtrace", "j/flows/flows-200.jsonl"):
            self.assertIn(name, flows)
        self.assertNotIn("*/flows", flows)            # never every process's file
        self.assertNotIn("video", flows)
        self.assertTrue((self.out / "j" / "flows" / "flows-100.jsonl").is_file())
        self.assertFalse((self.out / "kept-on-mini.json").exists())

    def test_no_daemon_arm_record_fetches_nothing(self):
        self.assertEqual(self.fetch(), [])

    def test_too_little_lease_left_or_a_failed_flow_fetch_is_named(self):
        self.arm_file("j", "before", 100, 200)
        self.assertEqual(self.fetch(left_s=20.0), [])
        self.assertEqual(json.loads((self.out / "kept-on-mini.json").read_text())["not_fetched"], ["flows"])
        (self.out / "kept-on-mini.json").unlink()
        self.fetch(fail_flows=True)
        self.assertEqual(json.loads((self.out / "kept-on-mini.json").read_text())["not_fetched"], ["flows"])

    def park(self, reply):
        calls = []

        def remote(host, script, **kw):
            calls.append(script)
            return subprocess.CompletedProcess(script, 0, reply.encode(), b"")
        with mock.patch.object(self.run, "remote", side_effect=remote), mock.patch.object(self.run, "log"):
            self.run.park_movies("cmux21", "/lease/journeys", self.out, "20261104T120000Z-ab12cd34", lambda cap: cap)
        return calls

    def test_park_moves_the_movies_out_of_the_lease_root_and_names_them(self):
        calls = self.park("PARKED j/video\nPATH /Users/cmux/.cache/cmux-journeys/fetch/20261104T120000Z-ab12cd34\n")
        self.assertEqual(len(calls), 1)
        self.assertIn("mv \"$d\" \"$p/$d\"", calls[0])
        self.assertIn("-mmin +360", calls[0])          # old parked folders are removed first
        self.assertIn("p=$HOME/.cache/cmux-journeys/fetch/20261104T120000Z-ab12cd34", calls[0])
        parked = json.loads((self.out / "parked.json").read_text())
        self.assertEqual((parked["host"], parked["path"], parked["items"]),
                         ("cmux21", "/Users/cmux/.cache/cmux-journeys/fetch/20261104T120000Z-ab12cd34", ["j/video"]))

    def test_nothing_parked_writes_no_parked_json(self):
        self.park("")
        self.assertFalse((self.out / "parked.json").exists())
        calls = []
        with mock.patch.object(self.run, "remote", side_effect=lambda *a, **k: calls.append(a)), \
                mock.patch.object(self.run, "log"):
            self.run.park_movies("cmux21", "/w", self.out, "bad id; rm -rf /", lambda cap: cap)
        self.assertEqual(calls, [])                    # a run id that is not plain is never put in a command

    def test_the_hog_stops_before_the_lease_fetch(self):
        src = (HERE / "run.py").read_text()
        body = src[src.index("        if hog_started:\n            hog_log = remote("):src.index("    except (RuntimeError, subprocess.TimeoutExpired, KeyError")]
        self.assertLess(body.index("stop_hog(host, work)"), body.index("fetch_in_lease("))
        self.assertLess(body.index("fetch_in_lease("), body.index("park_movies("))

    def test_no_fetch_after_the_release(self):
        # run_lease has no code path that runs a remote command after `capture-host release` (R-HARNESS rule).
        src = (HERE / "run.py").read_text()
        body = src[src.index("        released = subprocess.run([ch, \"release\", lease]"):src.index("def named_flow_files")]
        after = body[:body.index("    return stamp_harness(")]
        self.assertNotIn("remote(", after)
        self.assertNotIn("fetch_", after)


if __name__ == "__main__":
    unittest.main()
