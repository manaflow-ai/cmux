#!/usr/bin/env python3
"""The dogfood smoke gate's verdict rules, with a stand-in for run.py: no fleet, no app.

    python3 scripts/journeys/test_smoke_gate.py

PASS (and the .pass file) only when every round passes; FAIL when one round failed; NOT JUDGED when no round
failed but one did not run, a known gap included, or the hog log shows no memory pressure; TRIAL PASS (no .pass)
below 10 rounds or +15 GB; never a .pass file from a gate with uncommitted changes, from results of another build
or from a used --out folder. The type-at-once check (smoke_new_terminals) fails keys that reached an old
terminal, a missing tab or the wrong pane. Also: the journey and its step group load (`run.py --check`).
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "smoke-gate.py"

FAKE = r'''
import json, os, sys
args = sys.argv[1:]
out = args[args.index("--out") + 1]
os.makedirs(os.path.join(out, "smoke-dogfood"), exist_ok=True)
n = int(os.path.basename(out).split("-")[1])
plan = json.loads(os.environ["SMOKE_PLAN"])
status = plan[n - 1]
row = {"id": "smoke-dogfood", "status": status, "reason": "", "host": "cmux99",
       "build_job": os.environ.get("SMOKE_BUILD", "job123")}
if status == "silent":  # run.py stopped before it wrote results
    sys.exit(3)
if os.environ.get("SMOKE_HOG", "edge") != "none":
    level = 15 if os.environ.get("SMOKE_HOG", "edge") == "edge" else 60
    with open(os.path.join(out, "hog-slot-cmux99-abc.jsonl"), "w") as f:
        for t in range(40):
            f.write(json.dumps({"t": t, "held_mb": 9000, "swap_used_mb": 1000 + t * 10, "level": level}) + "\n")
if status == "gap":
    row["status"], row["reason"] = "not run", "known gap: the capture slot could not make the window key"
if status == "fail":
    json.dump({"steps": [{"do": "smoke_type_now", "ok": False, "error": "keys lost"}]},
              open(os.path.join(out, "smoke-dogfood", "result.json"), "w"))
if status == "pass" and "--journey-option" not in args:
    late = os.environ.get("SMOKE_LATE") == "yes"
    typed = [] if os.environ.get("SMOKE_LATE") == "none" else [{"index": 7, "do": "smoke_type_now", "ok": True,
                                                                 "result": {"at_once": not late}}]
    json.dump({"steps": typed},
              open(os.path.join(out, "smoke-dogfood", "result.json"), "w"))
if "--journey-option" in args:
    open(os.path.join(out, "options.txt"), "w").write(args[args.index("--journey-option") + 1])
    json.dump({"steps": [{"index": 5, "do": "expect", "title": "Cmd-D twice fast", "ok": status == "pass",
                          "error": "" if status == "pass" else "no new pane"}]},
              open(os.path.join(out, "smoke-dogfood", "result.json"), "w"))
open(os.path.join(out, "results.jsonl"), "w").write(json.dumps(row) + "\n")
print("leased slot-cmux99-abc")
if os.environ.get("SMOKE_EXCLUSIVE", "yes") == "yes":
    open(os.path.join(out, "acquire.log"), "w").write(
        "capture-host: cmux99 is exclusive until 2026-10-31T03:00:00Z: the fleet controller places no step on its workers (cmux99-perf)\n")
open(os.path.join(out, "argv.json"), "w").write(json.dumps(args))
open(os.path.join(out, "env.json"), "w").write(json.dumps({k: os.environ.get(k) for k in
    ("CAPTURE_HOST_POOL", "CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS", "CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS")}))
'''


def gate(plan, tmp, extra=(), env_extra=None, rounds=None):
    runner = os.path.join(tmp, "fake_run.py")
    with open(runner, "w") as f:
        f.write(FAKE)
    env = {k: v for k, v in os.environ.items() if not k.startswith("CAPTURE_HOST_")}
    env.update({"SMOKE_PLAN": json.dumps(plan), "SMOKE_GATE_CMUX_CI": "/bin/false", **(env_extra or {})})
    done = subprocess.run([sys.executable, str(GATE), "--build", "job123", "--rounds", str(rounds or len(plan)), "--runner", runner,
                           "--out", os.path.join(tmp, "out"), "--handoff", os.path.join(tmp, "handoff"), *extra],
                          capture_output=True, text=True, env=env, timeout=120)
    with open(os.path.join(tmp, "out", "summary.json")) as f:
        return done.returncode, json.load(f)


class Verdicts(unittest.TestCase):
    def test_pass_needs_every_round_and_a_committed_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp)
            self.assertEqual(summary["verdict"], "PASS")
            self.assertTrue(summary["rounds_detail"][0]["pressure"]["ok"])
            with open(os.path.join(tmp, "out", "round-01", "env.json")) as f:
                env = json.load(f)
            # The perf minis' owner pool (the controller refuses an exclusive lease there without it) and the
            # fleet rules' acquire and drain bounds.
            self.assertEqual(env, {"CAPTURE_HOST_POOL": "perf-lead", "CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS": "600",
                                   "CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS": "900"})
            self.assertEqual(summary["rounds_detail"][0]["leases"], ["slot-cmux99-abc"])  # from "leased <lease>"
            written = os.path.exists(os.path.join(tmp, "handoff", "job123.pass"))
            # The gate's own folder may have uncommitted edits while it is developed: then no .pass file.
            self.assertEqual(written, not summary["gate_dirty"])
            self.assertEqual(code, 75 if summary["gate_dirty"] else 0)

    def test_one_failed_round_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass", "fail", "pass"], tmp)
            self.assertEqual((code, summary["verdict"], summary["failed"]), (1, "FAIL", 1))
            self.assertEqual(summary["rounds_detail"][1]["failing_step"]["do"], "smoke_type_now")
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))

    def test_a_known_gap_is_never_a_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass", "gap"], tmp)
            self.assertEqual((code, summary["verdict"]), (75, "NOT JUDGED"))
            self.assertEqual(summary["known_gap_rounds"], [2])
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))
            with open(os.path.join(tmp, "out", "summary.txt")) as f:
                self.assertIn("KNOWN GAP in rounds [2]", f.read())


    def test_a_pass_without_an_exclusive_lease_does_not_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp, env_extra={"SMOKE_EXCLUSIVE": "no"})
            self.assertEqual((code, summary["verdict"], summary["passed"]), (75, "NOT JUDGED", 0))
            self.assertIn("exclusive", summary["rounds_detail"][0]["reason"])

    def test_the_caller_can_name_another_owner_pool(self):
        with tempfile.TemporaryDirectory() as tmp:
            gate(["pass"], tmp, env_extra={"CAPTURE_HOST_POOL": "other-pool"})
            with open(os.path.join(tmp, "out", "round-01", "env.json")) as f:
                self.assertEqual(json.load(f)["CAPTURE_HOST_POOL"], "other-pool")

    def test_diagnostic_rounds_report_each_check_and_never_write_the_pass_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 9 + ["fail"], tmp, ("--diagnostic",))
            self.assertEqual((code, summary["verdict"], summary["gate_run"]), (1, "DIAGNOSTIC (NOT JUDGED)", False))
            self.assertEqual(summary["expects"]["Cmd-D twice fast"], {"reached": 10, "passed": 9, "failed": 1,
                                                                      "errors": ["round 10: no new pane"]})
            with open(os.path.join(tmp, "out", "round-01", "options.txt")) as f:
                self.assertEqual(f.read(), "smoke_mode=diagnostic")
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp, ("--diagnostic",))
            self.assertEqual((code, summary["verdict"]), (75, "DIAGNOSTIC (NOT JUDGED)"))
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))

    def test_a_strict_pass_whose_lines_were_not_typed_at_once_does_not_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp, env_extra={"SMOKE_LATE": "yes"})
            self.assertEqual((code, summary["verdict"], summary["passed"]), (75, "NOT JUDGED", 0))
            self.assertIn("not typed at once", summary["rounds_detail"][0]["reason"])
        with tempfile.TemporaryDirectory() as tmp:  # a pass with no typing step at all does not count either
            code, summary = gate(["pass"] * 10, tmp, env_extra={"SMOKE_LATE": "none"})
            self.assertEqual((code, summary["verdict"], summary["passed"]), (75, "NOT JUDGED", 0))
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))

    def test_whole_host_leases_that_mini_alone_and_asks_run_py_for_an_active_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            gate(["pass"], tmp, ("--whole-host", "cmux17"))
            with open(os.path.join(tmp, "out", "round-01", "argv.json")) as f:
                args = json.load(f)
            self.assertIn("--whole-host", args)
            self.assertEqual(args[args.index("--hosts") + 1], "cmux17")
            self.assertIn("--exclusive", args)
        with tempfile.TemporaryDirectory() as tmp:
            done = subprocess.run([sys.executable, str(GATE), "--build", "job123", "--whole-host", "cmux99",
                                   "--out", os.path.join(tmp, "out")], capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 2)

    def test_a_trial_never_writes_the_pass_file(self):
        for plan, extra in ((["pass"] * 3, ()), (["pass"] * 10, ("--swap-gb", "4"))):
            with tempfile.TemporaryDirectory() as tmp:
                code, summary = gate(plan, tmp, extra)
                self.assertEqual((code, summary["verdict"], summary["gate_run"]), (75, "TRIAL PASS", False))
                self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))

    def test_a_pass_without_memory_pressure_does_not_count(self):
        for hog in ("none", "idle"):
            with tempfile.TemporaryDirectory() as tmp:
                code, summary = gate(["pass"] * 10, tmp, env_extra={"SMOKE_HOG": hog})
                self.assertEqual((code, summary["verdict"], summary["passed"]), (75, "NOT JUDGED", 0))
                self.assertIn("no memory pressure", summary["rounds_detail"][0]["reason"])

    def test_results_of_another_build_or_a_silent_run_do_not_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp, env_extra={"SMOKE_BUILD": "otherjob"})
            self.assertEqual((code, summary["verdict"]), (75, "NOT JUDGED"))
            self.assertIn("not job123", summary["rounds_detail"][0]["reason"])
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["silent"] * 10, tmp)
            self.assertEqual((code, summary["verdict"]), (75, "NOT JUDGED"))
            self.assertIn("run.py exited 3", summary["rounds_detail"][0]["reason"])

    def test_an_used_out_folder_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = os.path.join(tmp, "out", "round-01")
            os.makedirs(old)
            with open(os.path.join(old, "results.jsonl"), "w") as f:
                f.write(json.dumps({"id": "smoke-dogfood", "status": "pass", "build_job": "job123"}) + "\n")
            runner = os.path.join(tmp, "fake_run.py")
            with open(runner, "w") as f:
                f.write(FAKE)
            done = subprocess.run([sys.executable, str(GATE), "--build", "job123", "--runner", runner,
                                   "--out", os.path.join(tmp, "out"), "--handoff", os.path.join(tmp, "handoff")],
                                  capture_output=True, text=True, timeout=60, env={**os.environ, "SMOKE_GATE_CMUX_CI": "/bin/false"})
            self.assertEqual(done.returncode, 2)
            self.assertIn("not empty", done.stderr)


class Hosts(unittest.TestCase):
    def test_idle_minis_are_offered_first_and_a_failed_read_keeps_the_list(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("smoke_gate", GATE)
        gate_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate_module)
        with tempfile.TemporaryDirectory() as tmp:
            fake = os.path.join(tmp, "cmux-ci")
            with open(fake, "w") as f:
                f.write("#!/bin/sh\necho '{\"cmux17\": {\"idle\": false}, \"cmux18\": {\"idle\": true}, \"cmux19\": {\"idle\": true}}'\n")
            os.chmod(fake, 0o755)
            old = os.environ.get("SMOKE_GATE_CMUX_CI")
            try:
                os.environ["SMOKE_GATE_CMUX_CI"] = fake
                self.assertEqual(gate_module.idle_first("cmux17 cmux18 cmux19"), "cmux18 cmux19")
                os.environ["SMOKE_GATE_CMUX_CI"] = "/bin/false"
                self.assertEqual(gate_module.idle_first("cmux17 cmux18"), "cmux17 cmux18")
            finally:
                if old is None:
                    os.environ.pop("SMOKE_GATE_CMUX_CI", None)
                else:
                    os.environ["SMOKE_GATE_CMUX_CI"] = old


class Acquire(unittest.TestCase):
    def test_a_timed_out_exclusive_acquire_gets_term_so_its_trap_unreserves(self):
        sys.path.insert(0, str(HERE))
        import run as run_module
        with tempfile.TemporaryDirectory() as tmp:
            fake, mark = os.path.join(tmp, "capture-host"), os.path.join(tmp, "unreserved")
            with open(fake, "w") as f:
                f.write(f"#!/bin/bash\ntrap 'echo yes > {mark}; kill $child; exit 143' TERM\nsleep 30 & child=$!\nwait $child\n")
            os.chmod(fake, 0o755)
            saved = {k: os.environ.get(k) for k in ("CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS", "CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS")}
            slack = run_module.ACQUIRE_SLACK_SECONDS
            try:
                os.environ["CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS"] = "1"
                os.environ["CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS"] = "0"
                run_module.ACQUIRE_SLACK_SECONDS = 1
                with self.assertRaises(RuntimeError) as caught:
                    run_module.acquire_lease(fake, True)
                self.assertIn("no lease within 2s", str(caught.exception))
                self.assertTrue(os.path.exists(mark), "the acquire got KILL, not TERM: its reservation would stay")
            finally:
                run_module.ACQUIRE_SLACK_SECONDS = slack
                for k, v in saved.items():
                    os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)


class Launch(unittest.TestCase):
    def test_the_launch_names_the_build_commit_and_the_unpack_writes_it_beside_the_bundle(self):
        # capture-host (hq main 2026-10-30) refuses `launch` without --commit SHA checked against the bundle.
        src = (HERE / "run.py").read_text()
        self.assertIn('[ch, "launch", "--commit", commit, *(["--activate"] if whole_host else []), lease, app', src)
        self.assertIn("capture-commit", src)


class WholeHost(unittest.TestCase):
    def test_run_py_and_the_driver_carry_activate(self):
        src = (HERE / "run.py").read_text()
        self.assertIn('*([] if whole_host else ["--slot"])', src)
        self.assertIn('*(["--activate"] if whole_host else [])', src)
        self.assertIn('(" --activate" if whole_host else "")', src)
        drv = (HERE / "driver.py").read_text()
        self.assertIn('*([] if ACTIVATE else ["-g"])', drv)


class NewTerminals(unittest.TestCase):
    """cond_smoke_new_terminals on a fake app: the lines must be one each on new terminals, placed as asked."""

    def setUp(self):
        sys.path.insert(0, str(HERE))
        import ext_smoke

        class StepError(Exception):
            pass

        class NotRun(Exception):
            pass

        ext_smoke.install(type("D", (), {"StepError": StepError, "NotRun": NotRun, "now": staticmethod(lambda: 0.0)}))
        self.NotRun, self.StepError = NotRun, StepError
        self.ext = ext_smoke

    def journey(self, layout, screens, focused):
        """layout: [(workspace, pane, tab, terminal, selected)]; screens: {terminal: text}."""
        class App:
            def panes(self_):
                return [{"pane": p, "focused": p == focused} for p in sorted({row[1] for row in layout})]

            def screen(self_, term):
                return {"text": screens.get(term, "")}

        class J:
            app = App()
            vars = {}
            spec = {}
            key_window = None

            def sub(self_, x):
                return x

            def topology(self_):
                return {"layout": layout, "workspaces": [{"id": w} for w in sorted({row[0] for row in layout})]}

            @staticmethod
            def places(topo):
                records = {w["id"]: w for w in topo.get("workspaces", [])}
                for row in topo["layout"]:
                    ws, pane, tab, term, selected = row[:5]
                    key = row[5] if len(row) > 5 else term
                    yield (records.get(ws, {"id": ws}), {"id": pane, "selected_tab": tab if selected else None},
                           {"id": tab, "terminal_key": key}, term)

            def topology_workspaces(self_):
                return sorted({row[0] for row in layout})
        return J()

    def check(self, before, after, screens, focused, lines, placement, focused_line=None):
        j = self.journey(before, {}, focused)
        self.ext.step_smoke_snapshot(j, {"name": "s"})
        j2 = self.journey(after, screens, focused)
        j2.smoke_snapshots = j.smoke_snapshots
        return self.ext.cond_smoke_new_terminals(j2, {"since": "s", "lines": lines, "focused": focused_line,
                                                      "placement": placement}, {})

    def test_tabs_in_the_focused_pane(self):
        before = [("w", "p1", "a", "T0", True)]
        after = before[:1] + [("w", "p1", "b", "T1", False), ("w", "p1", "c", "T2", True)]
        ok, detail = self.check(before, after, {"T1": "t1", "T2": "t2"}, "p1", ["t1", "t2"], "focused_pane", "t2")
        self.assertTrue(ok, detail)
        # The second Ctrl-` made no tab: t2 went into tab 1.
        lost = before[:1] + [("w", "p1", "b", "T1", True)]
        ok, detail = self.check(before, lost, {"T1": "t1\nt2"}, "p1", ["t1", "t2"], "focused_pane", "t2")
        self.assertFalse(ok)
        self.assertTrue(any("new terminals" in p for p in detail["problems"]), detail)

    def test_keys_that_reach_the_old_terminal_fail(self):
        before = [("w", "p1", "a", "T0", True)]
        after = before + [("w", "p2", "b", "T1", True), ("w", "p3", "c", "T2", True)]
        ok, detail = self.check(before, after, {"T0": "d1", "T2": "d2"}, "p3", ["d1", "d2"], "new_panes", "d2")
        self.assertFalse(ok)
        self.assertTrue(any("old terminal T0" in p for p in detail["problems"]), detail)
        ok, detail = self.check(before, after, {"T1": "d1", "T2": "d2"}, "p3", ["d1", "d2"], "new_panes", "d2")
        self.assertTrue(ok, detail)

    def test_a_stand_in_terminal_whose_public_id_changes_is_not_new(self):
        # The snapshot saw the stand-in (public id = its key K0); the daemon's tab then gave it the id T0.
        before = [("w", "p1", "a", "K0", True, "K0")]
        after = [("w", "p1", "a", "T0", False, "K0"), ("w", "p1", "b", "T1", False, "K1"), ("w", "p1", "c", "T2", True, "K2")]
        ok, detail = self.check(before, after, {"T1": "t1", "T2": "t2"}, "p1", ["t1", "t2"], "focused_pane", "t2")
        self.assertTrue(ok, detail)
        ok, detail = self.check(before, after, {"T0": "t1", "T2": "t2"}, "p1", ["t1", "t2"], "focused_pane", "t2")
        self.assertFalse(ok)
        self.assertTrue(any("old terminal K0" in p for p in detail["problems"]), detail)

    def test_the_restore_compares_ids_taken_once_confirmed(self):
        ext = self.ext
        layout = [("w0", "p0", "a", "T0", True), ("ws_1", "p1", "b", "T1", True)]
        j = self.journey(layout, {}, "p1")
        j.topology = lambda: {"layout": layout, "workspaces": [{"id": "w0"}, {"id": "ws_1"}]}
        j.smoke_baseline = {"w0"}
        ext.step_smoke_snapshot(j, {"name": "confirmed"})
        ok, detail = ext.cond_smoke_workspaces(j, {"new": 1, "same_as": "confirmed"}, {})
        self.assertTrue(ok, detail)
        j.topology = lambda: {"layout": layout, "workspaces": [{"id": "w0"}, {"id": "ws_2"}]}
        ok, detail = ext.cond_smoke_workspaces(j, {"new": 1, "same_as": "confirmed"}, {})
        self.assertFalse(ok, detail)

    def test_typing_after_the_window_lost_key_is_a_known_gap(self):
        j = self.journey([("w", "p1", "a", "T0", True)], {}, "p1")
        j.smoke_key_ok, typed = True, []
        j.app.rpc = lambda method, params=None: {"windows": [{"id": 1, "kind": "main", "key": False}]}
        j.key = lambda *a: typed.append(a)
        with self.assertRaises(self.NotRun) as caught:
            self.ext.step_smoke_type_now(j, {"text": "echo x"})
        self.assertIn("known gap", str(caught.exception))
        self.assertEqual(typed, [])
        j.app.rpc = lambda method, params=None: {"windows": [{"id": 1, "kind": "main", "key": False},
                                                             {"id": 2, "kind": "ChromiumChild", "key": True}]}
        with self.assertRaises(self.StepError) as caught:
            self.ext.step_smoke_type_now(j, {"text": "echo x"})
        self.assertIn("not a main window", str(caught.exception))
        self.assertEqual(typed, [])

    def test_diagnostic_mode_types_after_the_hold_when_no_window_is_key(self):
        j = self.journey([("w", "p1", "a", "T0", True)], {}, "p1")
        j.spec = {"options": {"smoke_mode": "diagnostic"}}
        j.smoke_key_ok, typed, waited = False, [], []
        j.app.rpc = lambda method, params=None: {"windows": [{"id": 1, "kind": "main", "key": False}]}
        j.key = lambda *a: typed.append(a)
        j.outwait_creation_hold = lambda since: waited.append(since) or 2.5
        j.last_key_at = 7.0
        result = self.ext.step_smoke_type_now(j, {"text": "ab"})
        self.assertEqual((result["at_once"], result["waited_hold_s"], waited, len(typed)), (False, 2.5, [7.0], 3))
        ok, detail = self.ext.cond_smoke_key_window(j, {}, {})
        self.assertTrue(ok, detail)
        # Another app window key is still a fail in diagnostic mode.
        j.app.rpc = lambda method, params=None: {"windows": [{"id": 1, "kind": "main", "key": False},
                                                             {"id": 2, "kind": "ChromiumChild", "key": True}]}
        with self.assertRaises(self.StepError):
            self.ext.step_smoke_type_now(j, {"text": "ab"})
        ok, detail = self.ext.cond_smoke_key_window(j, {}, {})
        self.assertFalse(ok, detail)

    def test_strict_mode_on_a_slot_with_no_key_window_is_a_known_gap(self):
        j = self.journey([("w", "p1", "a", "T0", True)], {}, "p1")
        j.smoke_key_ok, j.smoke_key_reply, typed = False, {"key": None}, []
        j.app.rpc = lambda method, params=None: {"windows": [{"id": 1, "kind": "main", "key": False}]}
        j.key = lambda *a: typed.append(a)
        with self.assertRaises(self.NotRun) as caught:
            self.ext.step_smoke_type_now(j, {"text": "echo x"})
        self.assertIn("debug.window.focus said", str(caught.exception))
        self.assertEqual(typed, [])
        # No main window at all: a fail in either mode (nothing to type in).
        j.spec = {"options": {"smoke_mode": "diagnostic"}}
        j.app.rpc = lambda method, params=None: {"windows": []}
        with self.assertRaises(self.StepError):
            self.ext.step_smoke_type_now(j, {"text": "echo x"})
        ok, _detail = self.ext.cond_smoke_key_window(j, {}, {})
        self.assertFalse(ok)

    def test_the_pane_count_is_read_from_the_workspace_that_shows_the_line(self):
        layout = [("w0", "p0", "a", "T0", True), ("w1", "p1", "b", "T1", True), ("w1", "p2", "c", "T2", True),
                  ("w1", "p3", "d", "T3", True)]
        j = self.journey(layout, {"T3": "d2"}, "p3")
        j.topology = lambda: {"layout": layout, "workspaces": [
            {"id": "w0", "screens": [{"panes": [{"id": "p0"}]}]},
            {"id": "w1", "screens": [{"panes": [{"id": "p1"}, {"id": "p2"}, {"id": "p3"}]}]}]}
        self.assertTrue(self.ext.cond_smoke_panes(j, {"line": "d2", "count": 3}, {})[0])
        self.assertFalse(self.ext.cond_smoke_panes(j, {"line": "d2", "count": 2}, {})[0])
        self.assertFalse(self.ext.cond_smoke_panes(j, {"line": "zz", "count": 3}, {})[0])

    def test_smoke_ready_waits_for_a_window_and_a_loaded_topology(self):
        j = self.journey([], {}, None)
        replies = iter([({"windows": []}, {"topology": {"loaded": False}}),
                        ({"windows": [{"id": "w"}]}, {"topology": {"loaded": True, "daemon_state": "connected"}})])
        state = {}

        def rpc(method, params=None):
            if method == "debug.windows":
                state["now"] = next(replies)
                return state["now"][0]
            return state["now"][1]
        j.app.rpc = rpc
        sleep = self.ext.time.sleep
        self.ext.time.sleep = lambda s: None  # the time module itself: put back below
        try:
            result = self.ext.step_smoke_ready(j, {"timeout": 5})
            self.assertEqual((result["windows"], result["loaded"]), (1, True))
            j.app.rpc = lambda method, params=None: {"windows": []} if method == "debug.windows" else {}
            clock = iter(range(100))
            self.ext.D.now = staticmethod(lambda: float(next(clock)))
            with self.assertRaises(self.StepError):
                self.ext.step_smoke_ready(j, {"timeout": 5})
        finally:
            self.ext.time.sleep = sleep

    def test_each_workspace_line_in_its_own_new_workspace(self):
        before = [("w0", "p0", "a", "T0", True)]
        after = before + [("w1", "p1", "b", "T1", True), ("w1", "p1", "c", "T2", False)]
        ok, detail = self.check(before, after, {"T1": "w1", "T2": "w2"}, "p1", ["w1", "w2"], "new_workspaces", "w1")
        self.assertFalse(ok)
        self.assertTrue(any("own new workspace" in p for p in detail["problems"]), detail)


class Resize(unittest.TestCase):
    """R3a (grid == fit(bounds) == PTY == daemon, long line wraps at the new width) and R3b (old columns keep
    exactly their width): a fake mismatch must fail, with every size in the result."""

    def setUp(self):
        sys.path.insert(0, str(HERE))
        import ext_smoke

        class StepError(Exception):
            pass

        ext_smoke.install(type("D", (), {"StepError": StepError, "NotRun": Exception, "now": staticmethod(lambda: 0.0)}))
        self.ext, self.StepError = ext_smoke, StepError

    def journey(self, grid="80x24", fit="80x24", drawn="80x24", daemon=(80, 24), topo=(80, 24), pty=(80, 24),
                frame=(80 * 8 + 8, 24 * 16 + 8), long_rows=None, columns=None):
        """columns: [(column index, pane id, frame_x, frame_width)] of workspace W besides pane P1 (column 0)."""
        screen_text = "$ echo r3-1 $(stty size)\nr3-1 %d %d\n" % (pty[1], pty[0]) if pty else ""
        if long_rows:
            screen_text += "\n".join(long_rows) + "\n"
        panes = [{"pane": "P1", "workspace": "W", "content_size": "%dx%d" % frame, "focused": True,
                  "surface": {"grid": grid, "fit_grid": fit, "drawn_grid": drawn},
                  "grid": {"cell_width": 8, "cell_height": 16, "frame_x": 0, "frame_y": 0, "origin_x": 4, "origin_y": 4,
                           "frame_width": frame[0], "frame_height": frame[1]}}]
        topo_panes = [{"id": "P1", "column": 0}]
        for column, key, x0, width in (columns or []):
            panes.append({"pane": key, "workspace": "W", "content_size": "%dx400" % int(width),
                          "grid": {"frame_x": x0, "frame_width": width}})
            topo_panes.append({"id": key, "column": column})

        class App:
            def panes(self_):
                return panes

            def screen(self_, term):
                return {"text": screen_text, "cols": daemon[0], "rows": daemon[1]}

        class J:
            app = App()
            vars = {}
            pane = "P1"
            smoke_named = {"right": {"pane": "P1", "term": "T1"}}
            ext_remembered = {"right0": {"grid": (70, 24)}, "right1": {"grid": (90, 24)}}
            smoke_long = {"LL": 95}

            def sub(self_, x):
                return x

            def topology(self_):
                return {"workspaces": [{"id": "W", "screens": [{"panes": topo_panes}]}]}

            @staticmethod
            def places(_topology):
                yield {"id": "W"}, {"id": "P1"}, {"id": "t", "columns": topo[0], "rows": topo[1]}, "T1"
        return J()

    def r3(self, j, **want):
        return self.ext.cond_smoke_r3(j, dict({"pane": "right", "pty_tag": "r3-1"}, **want), {})

    def test_r3_holds_when_every_size_agrees(self):
        ok, detail = self.r3(self.journey())
        self.assertTrue(ok, detail)
        self.assertEqual(detail["sizes"]["pty"], (80, 24))

    def test_r3_fails_on_each_mismatch_and_reports_every_size(self):
        for kwargs, word in ((dict(fit="79x24"), "fit_grid"), (dict(drawn="70x24"), "drawn_grid"),
                             (dict(daemon=(70, 24)), "daemon"), (dict(topo=(70, 24)), "topology"),
                             (dict(pty=(70, 24)), "pty"), (dict(frame=(70 * 8 + 8, 24 * 16 + 8)), "fit(bounds)"),
                             (dict(frame=(81 * 8 + 8, 24 * 16 + 8)), "fit(bounds)"), (dict(pty=None), "pty")):
            ok, detail = self.r3(self.journey(**kwargs))
            self.assertFalse(ok, (kwargs, detail))
            self.assertTrue(any(word in p for p in detail["problems"]), (kwargs, detail["problems"]))
            self.assertEqual(set(detail["sizes"]), {"grid", "fit_grid", "drawn_grid", "fit_bounds", "pty", "daemon", "topology"})

    def test_a_terminal_that_did_not_resize_fails_the_window_check(self):
        # After the window drag the pane must be narrower than right1 (90 cols): 80 passes; a pane that stayed at
        # 90 (the window resized, the terminal did not) fails, although its seven sizes agree.
        ok, detail = self.r3(self.journey(), vs="right1", cols="narrower")
        self.assertTrue(ok, detail)
        same = self.journey(grid="90x24", fit="90x24", drawn="90x24", daemon=(90, 24), topo=(90, 24), pty=(90, 24),
                            frame=(90 * 8 + 8, 24 * 16 + 8))
        ok, detail = self.r3(same, vs="right1", cols="narrower")
        self.assertFalse(ok)
        self.assertTrue(any("not narrower" in p for p in detail["problems"]), detail["problems"])
        self.assertIn("smoke_r3", self.ext.NEGATIVE)

    def test_the_long_line_must_wrap_at_the_new_width(self):
        good = ["LL" + "x" * 78, "x" * 15]
        ok, detail = self.r3(self.journey(long_rows=good), long_tag="LL", vs="right0", cols="wider")
        self.assertTrue(ok, detail)
        old = ["LL" + "x" * 68, "x" * 25]  # wrapped at the old width (70)
        ok, detail = self.r3(self.journey(long_rows=old), long_tag="LL")
        self.assertFalse(ok)
        self.assertTrue(any("wraps at 70" in p for p in detail["problems"]), detail["problems"])
        ok, detail = self.r3(self.journey(long_rows=None), long_tag="LL")
        self.assertFalse(ok)

    def test_the_long_line_waits_for_the_prompt_and_exceeds_the_current_width(self):
        j = self.journey()
        screens = iter(["$ echo r3-1 $(stty size)\n", "$ echo r3-1 $(stty size)\nr3-1 24 80\n$ \n"])
        state = {"text": next(screens)}

        def screen(term):
            state["text"] = next(screens, state["text"])
            return {"text": state["text"], "cols": 80, "rows": 24}
        j.app.screen = screen
        j.need_term = lambda: "T1"
        typed = []
        j.key = lambda *a: typed.append(a)
        j.key_window = None
        j.ext_remembered = {}
        sleep = self.ext.time.sleep
        self.ext.time.sleep = lambda s: None
        try:
            result = self.ext.step_smoke_long_line(j, {"tag": "LL"})
            self.assertEqual(result["length"], 95)  # the current pane's 80 columns + 15
            self.assertGreater(len(typed), 0)
            j.pane = "P9"  # the focused pane is not the current one: the keys would go elsewhere
            with self.assertRaises(self.StepError):
                self.ext.step_smoke_long_line(j, {"tag": "LL2"})
        finally:
            self.ext.time.sleep = sleep

    def test_r3b_any_old_column_width_change_fails_with_old_and_new(self):
        base = [(1, "P2", 650.0, 300.0)]
        j = self.journey(columns=base)
        self.ext.step_smoke_widths(j, {"name": "c0"})
        # A new column after column 0 shifts P2 to index 2; it is matched by its pane, not its index.
        same = self.journey(columns=[(1, "P3", 650.0, 300.0), (2, "P2", 951.0, 300.0)])
        same.smoke_width_snaps = j.smoke_width_snaps
        ok, detail = self.ext.cond_smoke_same_widths(same, {"since": "c0", "new": 1}, {})
        self.assertTrue(ok, detail)
        moved = self.journey(columns=[(1, "P3", 650.0, 300.0), (2, "P2", 951.0, 299.5)])
        moved.smoke_width_snaps = j.smoke_width_snaps
        ok, detail = self.ext.cond_smoke_same_widths(moved, {"since": "c0", "new": 1}, {})
        self.assertFalse(ok)
        self.assertEqual({k: (v["old"], v["new"]) for k, v in detail["changed"].items()}, {"1": (300.0, 299.5)})
        # A split inside a column is no new column: "1 new" fails.
        split = self.journey(columns=[(1, "P2", 650.0, 300.0), (1, "P4", 650.0, 300.0)])
        split.smoke_width_snaps = j.smoke_width_snaps
        ok, detail = self.ext.cond_smoke_same_widths(split, {"since": "c0", "new": 1}, {})
        self.assertFalse(ok)
        self.assertTrue(any("new columns" in p for p in detail["problems"]), detail["problems"])
        self.assertIn("smoke_same_widths", self.ext.NEGATIVE)

class Loads(unittest.TestCase):
    def test_the_smoke_journey_and_its_steps_load(self):
        done = subprocess.run([sys.executable, str(HERE / "run.py"), "--check"], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        listed = subprocess.run([sys.executable, str(HERE / "run.py"), "--list"], capture_output=True, text=True, timeout=120)
        self.assertIn("smoke-dogfood", listed.stdout)


if __name__ == "__main__":
    unittest.main()
