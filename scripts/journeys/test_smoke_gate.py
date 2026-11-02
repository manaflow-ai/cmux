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
import time
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
R3 = [st["title"] for st in json.load(open(os.environ["SMOKE_JOURNEY"]))["steps"]
      if st.get("do") == "expect" and str(st.get("title", "")).startswith("R3")]
args = sys.argv[1:]
out = args[args.index("--out") + 1]
os.makedirs(os.path.join(out, "smoke-dogfood"), exist_ok=True)
n = int(os.path.basename(out).split("-")[1])
plan = json.loads(os.environ["SMOKE_PLAN"])
status = plan[n - 1] if n <= len(plan) else plan[-1]
idle = status == "pass-idle"  # a pass whose hog log shows no pressure (this attempt only)
status = "pass" if idle else status
row = {"id": "smoke-dogfood", "status": status, "reason": "", "host": "cmux99",
       "build_job": os.environ.get("SMOKE_BUILD", "job123")}
if status == "silent":  # run.py stopped before it wrote results
    sys.exit(3)
if os.environ.get("SMOKE_HOG", "edge") != "none":
    level = 15 if os.environ.get("SMOKE_HOG", "edge") == "edge" and not idle else 60
    with open(os.path.join(out, "hog-slot-cmux99-abc.jsonl"), "w") as f:
        for t in range(40):
            f.write(json.dumps({"t": t, "held_mb": 9000, "swap_used_mb": 1000 + t * 10, "level": level}) + "\n")
if status == "gap":
    row["status"], row["reason"] = "not run", "known gap: the capture slot could not make the window key"
if status == "fail":
    json.dump({"steps": [{"do": "smoke_type_now", "ok": False, "error": "keys lost"}]},
              open(os.path.join(out, "smoke-dogfood", "result.json"), "w"))
opts = [args[i + 1] for i, a in enumerate(args) if a == "--journey-option"]
real = "key_path=real" in opts and os.environ.get("SMOKE_REAL_PATH", "real_hid") != "none"
if status == "pass" and not [o for o in opts if o != "key_path=real"]:
    late = os.environ.get("SMOKE_LATE") == "yes"
    path = os.environ.get("SMOKE_REAL_PATH", "real_hid") if "key_path=real" in opts else "debug.key"
    typed = [] if os.environ.get("SMOKE_LATE") == "none" else [{"index": 7, "do": "smoke_type_now", "ok": True,
                                                                 "result": {"at_once": not late}, "key_path": path}]
    r3 = os.environ.get("SMOKE_R3", "all")  # all | none | r3b-failed | one-r3b | renamed | duplicated
    checks = [(title, not (r3 == "r3b-failed" and title.startswith("R3b: Cmd-D"))) for title in R3]
    if r3 == "none":
        checks = []
    if r3 == "one-r3b":
        checks = [c for c in checks if not c[0].startswith("R3b: New Column's key (the build's binding) adds")]
    if r3 == "renamed":
        checks = [("R3b: Split Down, renamed", True) if c[0].startswith("R3b: Cmd-Shift-D") else c for c in checks]
    if r3 == "duplicated":
        twice = next(c for c in checks if c[0].startswith("R3b: New Column adds"))
        checks = [twice if c[0].startswith("R3b: Cmd-Shift-D") else c for c in checks]
    typed += [{"do": "expect", "title": title, "ok": ok} for title, ok in checks]
    evidence = ([{"kind": "app", "check": "smoke_key_window", "pass": True,
                  "detail": {"not_checked": "known gap: another app has the key window on this host (UNC)"}}]
                if os.environ.get("SMOKE_KEY_GAP") == "yes" else [])
    json.dump({"steps": typed, "evidence": evidence},
              open(os.path.join(out, "smoke-dogfood", "result.json"), "w"))
if [o for o in opts if o != "key_path=real"]:
    open(os.path.join(out, "options.txt"), "w").write([o for o in opts if o != "key_path=real"][0])
    json.dump({"steps": [{"index": 5, "do": "expect", "title": "Cmd-D twice fast", "ok": status == "pass",
                          "error": "" if status == "pass" else "no new pane"}]
                        + ([{"do": "expect", "title": t, "ok": True} for t in R3] if status == "pass" else [])},
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
    if not os.path.exists(os.path.join(tmp, "open-p0.txt")):
        open(os.path.join(tmp, "open-p0.txt"), "w").write("# no open P0 journeys\n")
    env.update({"SMOKE_GATE_OPEN_P0": os.path.join(tmp, "open-p0.txt"), "JOURNEYS_P0_LEDGER": os.path.join(tmp, "ledger")})
    env.update({"SMOKE_PLAN": json.dumps(plan), "SMOKE_GATE_CMUX_CI": "/bin/false",
                "SMOKE_JOURNEY": str(HERE / "journeys" / "dogfood" / "smoke-dogfood.json"), **(env_extra or {})})
    done = subprocess.run([sys.executable, str(GATE), "--build", "job123", "--rounds", str(rounds or len(plan)), "--runner", runner,
                           "--out", os.path.join(tmp, "out"), "--handoff", os.path.join(tmp, "handoff"), *extra],
                          capture_output=True, text=True, env=env, timeout=120)
    with open(os.path.join(tmp, "out", "summary.json")) as f:
        return done.returncode, json.load(f)


class Verdicts(unittest.TestCase):
    def test_pass_needs_every_round_and_a_committed_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp, extra=("--hosts", "cmux99", "--whole-host", "cmux99"))
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
                                                                      "not_judged": 0, "errors": ["round 10: no new pane"]})
            with open(os.path.join(tmp, "out", "round-01", "options.txt")) as f:
                self.assertEqual(f.read(), "smoke_mode=diagnostic")
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp, ("--diagnostic",))
            self.assertEqual((code, summary["verdict"]), (75, "DIAGNOSTIC (NOT JUDGED)"))
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))

    def test_the_gate_requires_exactly_the_journeys_resize_checks(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("smoke_gate_titles", GATE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with open(HERE / "journeys" / "dogfood" / "smoke-dogfood.json") as f:
            journey = json.load(f)
        titles = [st["title"] for st in journey["steps"] if st.get("do") == "expect" and st["title"].startswith("R3")]
        self.assertEqual(titles, list(module.REQUIRED_CHECKS))
        self.assertEqual(len(titles), len(set(titles)))

    def test_every_pane_count_in_the_journey_matches_the_panes_its_steps_make(self):
        """B1 of 7e7243708c4: a column step moved the count; sum the panes each step makes in the measured workspace."""
        with open(HERE / "journeys" / "dogfood" / "smoke-dogfood.json") as f:
            steps = json.load(f)["steps"]
        start = next(i for i, st in enumerate(steps) if st.get("do") == "smoke_snapshot" and st.get("name") == "before_splits")
        panes, checked = 1, 0  # ws3: one pane (its New Tab page and its Ctrl-` terminal are tabs of it)
        for st in steps[start:]:
            mods = st.get("modifiers") or []
            is_key = st.get("do") in ("key", "smoke_key")
            if is_key and st.get("key") == "n" and mods == ["cmd"]:
                break  # a new workspace: the counts below are another workspace's
            if (is_key and st.get("key") == "d") or (st.get("do") == "action" and st.get("action") == "newColumn"):
                panes += 1
            for cond in st.get("all", []):
                if "smoke_panes" in cond:
                    self.assertEqual(cond["smoke_panes"]["count"], panes, st.get("title"))
                    checked += 1
        self.assertEqual(checked, 2)

    def test_a_round_that_did_not_reach_or_pass_every_resize_check_is_no_pass(self):
        for r3, want in (("none", "R3a split resize: the right pane is wider"),
                         ("r3b-failed", "R3b: Cmd-D (Split Right) splits the pane inside its own column and every...: failed"),
                         ("one-r3b", "R3b: New Column's key (the build's binding) adds a column"),
                         ("renamed", "R3b: Cmd-Shift-D (Split Down) adds no column"),
                         ("duplicated", "recorded 2 times")):
            with tempfile.TemporaryDirectory() as tmp:
                code, summary = gate(["pass"] * 10, tmp, env_extra={"SMOKE_R3": r3})
                self.assertEqual((code, summary["verdict"], summary["passed"]), (1, "FAIL", 0), r3)
                self.assertIn(want, summary["rounds_detail"][0]["reason"], r3)
                self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))

    def test_a_passed_round_with_a_key_gap_is_not_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp, env_extra={"SMOKE_KEY_GAP": "yes"})
            self.assertEqual((code, summary["verdict"], summary["passed"]), (75, "NOT JUDGED", 0))
            self.assertIn("known gap: another app", summary["rounds_detail"][0]["reason"])

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
                # Each slot's no-pressure round is run again, at most --rounds times in all; then the rest stay not run.
                self.assertEqual((len(summary["rounds_detail"]), len(summary["replaced_rounds"]), summary["not_run"]), (20, 10, 10))

    def test_a_round_without_pressure_is_run_again_in_its_slot(self):
        plan = ["pass-idle", "pass", "pass", "pass", "pass", "pass-idle", "pass", "pass", "pass", "pass", "pass", "pass"]
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(plan, tmp, extra=("--hosts", "cmux99", "--whole-host", "cmux99"), rounds=10)
            self.assertEqual((summary["verdict"], summary["passed"], summary["not_run"]), ("PASS", 10, 0))
            self.assertEqual(summary["replaced_rounds"], [1, 6])
            detail = summary["rounds_detail"]
            self.assertEqual([r["slot"] for r in detail], [1, 1, 2, 3, 4, 5, 5, 6, 7, 8, 9, 10])
            # Slot 1 is a real-key slot: its replacement is typed with real keys too. Slot 5 (attempts 6 and 7) is
            # not, and slot 6 (attempt 8) still is: a replacement does not shift the real-key slots.
            self.assertEqual([r["key_path"] for r in detail[:2]], ["real_hid", "real_hid"])
            self.assertEqual([r["key_path"] for r in detail[5:8]], ["debug.key", "debug.key", "real_hid"])
            self.assertIn("run again for slot 1", detail[0]["reason"])
            self.assertIn("rounds [1, 6] showed no memory pressure and were run again", open(os.path.join(tmp, "out", "summary.txt")).read())

    def test_a_failed_round_is_never_run_again(self):
        plan = ["pass-idle", "fail"] + ["pass"] * 10
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(plan, tmp, rounds=10)
            self.assertEqual((summary["verdict"], summary["failed"], summary["replaced_rounds"]), ("FAIL", 1, [1]))
            self.assertEqual(len(summary["rounds_detail"]), 11)

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
                                  capture_output=True, text=True, timeout=60,
                                  env={**os.environ, "SMOKE_GATE_CMUX_CI": "/bin/false",
                                       "SMOKE_JOURNEY": str(HERE / "journeys" / "dogfood" / "smoke-dogfood.json")})
            self.assertEqual(done.returncode, 2)
            self.assertIn("not empty", done.stderr)


class RealKeys(unittest.TestCase):
    """cmux-ad 13:10Z: each gate run types at least 2 of its 10 rounds with real HID keys, and they must pass."""

    WH = ("--hosts", "cmux99", "--whole-host", "cmux99")

    def test_two_rounds_type_real_keys_and_each_round_says_its_key_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp, extra=self.WH)
            self.assertEqual(summary["real_key_rounds"], [1, 6])
            for n in range(1, 11):
                argv = json.load(open(os.path.join(tmp, "out", f"round-{n:02d}", "argv.json")))
                self.assertEqual("key_path=real" in argv, n in (1, 6), n)
            self.assertEqual([r["key_path"] for r in summary["rounds_detail"]][:2], ["real_hid", "debug.key"])
            self.assertEqual(summary["real_key_passed"], 2)
            self.assertEqual(summary["verdict"], "PASS")

    def test_a_real_key_round_whose_keys_took_debug_key_is_no_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp, extra=self.WH, env_extra={"SMOKE_REAL_PATH": "debug.key"})
            self.assertEqual(summary["rounds_detail"][0]["status"], "not run")
            self.assertIn("real HID", summary["rounds_detail"][0]["reason"])
            self.assertEqual(summary["verdict"], "NOT JUDGED")
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))

    def test_without_a_whole_host_there_are_no_real_key_rounds_and_no_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 10, tmp)
            self.assertEqual(summary["real_key_rounds"], [])
            self.assertEqual(summary["verdict"], "TRIAL PASS")
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))

    def test_the_real_key_rounds_spread_over_the_run(self):
        mod = load_gate()
        self.assertEqual(mod.real_key_rounds(10, 2), [1, 6])
        self.assertEqual(mod.real_key_rounds(10, 3), [1, 4, 7])
        self.assertEqual(mod.real_key_rounds(1, 2), [1])
        self.assertEqual(mod.real_key_rounds(10, 0), [])


class RealKeySteps(unittest.TestCase):
    """smoke_key / smoke_type / smoke_type_now on the real HID path (CuaDriver), with the path in the result."""

    def setUp(self):
        sys.path.insert(0, str(HERE))
        import ext_smoke
        import ext_realkey

        class StepError(Exception):
            pass

        class NotRun(Exception):
            pass
        D = type("D", (), {"StepError": StepError, "NotRun": NotRun, "now": staticmethod(time.monotonic)})
        ext_smoke.install(D)
        ext_realkey.install(D)
        self.ext, self.rk, self.NotRun = ext_smoke, ext_realkey, NotRun
        self.sent = []
        sent = self.sent

        class Session:
            proc = type("P", (), {"poll": staticmethod(lambda: None)})()

            def call(self_, tool, args):
                if tool == "list_windows":
                    return False, {"windows": [{"pid": 7, "window_id": 3, "layer": 0, "bounds": {"width": 100, "height": 50}},
                                               {"pid": 7, "window_id": 9, "layer": 0, "bounds": {"width": 900, "height": 700}},
                                               {"pid": 8, "window_id": 4, "layer": 0, "bounds": {"width": 2000, "height": 2000}}]}, {}
                sent.append((tool, args))
                return False, {"effect": "unverifiable"}, {}

        self.session = Session()
        if not hasattr(ext_realkey, "_original_front_pid"):
            ext_realkey._original_front_pid = ext_realkey.front_pid
        self.real_front_pid = ext_realkey._original_front_pid

    def tearDown(self):
        self.rk.front_pid = self.rk._original_front_pid

    def journey(self, mode):
        j = type("J", (), {})()
        j.key_window = "W1"
        j.spec = {"options": {"key_path": "real"} if mode == "real" else {}}
        j.app = type("A", (), {"pid": 7})()
        j.marks, j.vars, j.cua_session = {}, {}, self.session
        j.sub = lambda x: x
        j.before_keys = lambda: None
        self.rk.front_pid = lambda: 7  # restored in tearDown
        j.step_key = lambda step: {"key": step["key"], "reply": {"handled_by": "app"}}
        j.step_type = lambda step: {"typed": step["text"]}
        return j

    def test_a_key_is_a_desktop_hid_key_event_to_the_frontmost_app(self):
        done = self.ext.step_smoke_key(self.journey("real"), {"key": "`", "modifiers": ["control"], "mark": "m"})
        self.assertEqual(done["key_path"], "real_hid")
        self.assertEqual(self.sent, [("hotkey", {"scope": "desktop", "keys": ["ctrl", "`"]})])

    def test_no_real_key_while_another_app_is_in_front(self):
        j = self.journey("real")
        self.rk.front_pid = lambda: 406  # a Terminal window or a host prompt in front
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_key(j, {"key": "d", "modifiers": ["cmd"]})
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_type(j, {"text": "x"})
        self.assertEqual(self.sent, [])
        fronts = iter([7, 406, 406])  # in front at the check, then a prompt takes the front during the key
        self.rk.front_pid = lambda: next(fronts)
        with self.assertRaises(self.NotRun) as no:
            self.ext.step_smoke_key(j, {"key": "d", "modifiers": ["cmd"]})
        self.assertIn("lost the front", str(no.exception))

    def test_typing_uses_shift_for_shifted_characters_and_return(self):
        self.ext.step_smoke_type(self.journey("real"), {"text": "a$(B", "enter": True})
        self.assertEqual([(t, a.get("key") or a.get("keys")) for t, a in self.sent],
                         [("press_key", "a"), ("hotkey", ["shift", "4"]), ("hotkey", ["shift", "9"]),
                          ("hotkey", ["shift", "b"]), ("press_key", "return")])

    def test_front_pid_reads_lsappinfos_one_line_answer(self):
        real_run = self.rk.subprocess.run
        answers = iter(["ASN:0x0-0x9009:\n", "    pid = 397 !cgsConnection !signalled type=[ NULL ]  Arch=!!none \n"])
        self.rk.subprocess.run = lambda *a, **k: type("R", (), {"stdout": next(answers)})()
        try:
            self.assertEqual(self.real_front_pid(), 397)
        finally:
            self.rk.subprocess.run = real_run

    def bindings(self, rows, resolves):
        def rpc(method, params=None):
            if method == "keybinding.list":
                return {"bindings": rows}
            return resolves.get(params["keys"], {"outcome": "none"})
        return rpc

    def test_a_command_key_is_the_one_the_build_resolves_to_that_command(self):
        j = self.journey("real")
        j.key_window = "W1"
        rows = [{"command": "newColumn", "key": "cmd+ctrl+d", "when": None, "source": "default", "removed": True},
                {"command": "newColumn", "key": "cmd+opt+n", "when": None, "source": "default"},
                {"command": "newColumn", "key": "cmd+opt+m", "when": None, "source": "default"}]
        resolves = {"cmd+opt+n": {"outcome": "run", "winner": {"command": "newTab", "source": "user"}},
                    "cmd+opt+m": {"outcome": "run", "winner": {"command": "newColumn", "source": "default"}}}
        j.app.rpc = self.bindings(rows, resolves)
        done = self.ext.step_smoke_key(j, {"command": "newColumn", "key": "d", "modifiers": ["control", "cmd"]})
        self.assertEqual(self.sent, [("hotkey", {"scope": "desktop", "keys": ["cmd", "option", "m"]})])
        self.assertEqual(done["key_source"]["binding"], "cmd+opt+m")  # the removed row and the shadowed key skipped

    def test_a_host_binding_or_no_runnable_key_is_not_run(self):
        j = self.journey("real")
        rows = [{"command": "newColumn", "key": "cmd+opt+n", "when": None, "source": "user"}]
        j.app.rpc = self.bindings(rows, {"cmd+opt+n": {"outcome": "run", "winner": {"command": "newColumn", "source": "user"}}})
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_key(j, {"command": "newColumn", "key": "d", "modifiers": ["control", "cmd"]})
        j.app.rpc = self.bindings(rows, {})
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_key(j, {"command": "newColumn", "key": "d", "modifiers": ["control", "cmd"]})

        def busy(method, params=None):
            raise self.ext.D.StepError("keybinding.list: timeout")
        j.app.rpc = busy  # not method_not_found: never fall back to Look Up's key
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_key(j, {"command": "newColumn", "key": "d", "modifiers": ["control", "cmd"]})
        self.assertEqual(self.sent, [])

    def test_a_build_without_keybinding_list_keeps_the_journeys_key(self):
        j = self.journey("real")

        def rpc(method, params=None):
            raise self.ext.D.StepError("keybinding.list: method_not_found")
        j.app.rpc = rpc
        done = self.ext.step_smoke_key(j, {"command": "newColumn", "key": "d", "modifiers": ["control", "cmd"]})
        self.assertEqual(self.sent, [("hotkey", {"scope": "desktop", "keys": ["ctrl", "cmd", "d"]})])
        self.assertTrue(done["key_source"]["source"].startswith("journey"))

    def test_real_click_is_a_foreground_modified_click_at_the_panes_center_with_host_times(self):
        j = self.journey("real")
        layers = {"windows": [{"frame": [100, 50, 940, 720], "screen_frame": [0, 0, 1920, 1080],
                               "screen_visible_frame": [0, 0, 1920, 1055]}]}
        journal = {"entries": [{"seq": 5, "kind": {"key": {}}}]}

        def rpc(method, params=None):
            if method == "debug.layers":
                return layers
            if method == "debug.journal":
                return journal
            return {"windows": [{"panes": [
            {"pane": "P1", "focused": False, "grid": {"frame_x": 0, "frame_y": 0, "frame_width": 100, "frame_height": 100}},
            {"pane": "P2", "focused": True, "grid": {"frame_x": 200, "frame_y": 40, "frame_width": 300, "frame_height": 200}}]}]}
        j.app.rpc = rpc
        calls = []
        orig = self.session.call

        def call(tool, args):
            calls.append((tool, args))
            if tool == "get_screen_size":
                return False, {"scale_factor": 2.0}, {}
            if tool == "click":  # the app journals the mouse-down it got
                journal["entries"].append({"seq": 6, "kind": {"mouse": {"_0": {
                    "phase": "down", "button": 0, "x": landed[0], "y": landed[1], "clickCount": 1, "modifiers": landed[2]}}}})
            return orig(tool, args)
        landed = [350.5, 139.0, 1]
        self.session.call = call
        done = self.rk.step_real_click(j, {"pane": "focused", "modifiers": ["cmd"], "mark": "click"})
        clicks = [a for t, a in calls if t == "click"]
        # window top = 1080 - (50 + 720) = 310; screen point (100 + 350, 310 + 140) points, 2x pixels
        self.assertEqual(clicks, [{"scope": "desktop", "x": 900, "y": 900, "modifier": ["cmd"]}])
        self.assertEqual((done["pane"], done["point"]), ("P2", [350.0, 140.0]))
        self.assertLessEqual(done["clicked_at"], done["returned_at"])
        self.assertIn("click", j.marks)
        self.assertEqual(done["journal_mouse_down"]["modifiers"], ["cmd"])
        # A window on another display (debug.layers names no primary screen): not run before any click.
        layers["windows"][0]["screen_frame"] = [1920, 0, 1920, 1080]
        clicks_before = len([c for c in calls if c[0] == "click"])
        with self.assertRaises(self.NotRun):
            self.rk.step_real_click(j, {"pane": "focused", "modifiers": ["cmd"]})
        self.assertEqual(len([c for c in calls if c[0] == "click"]), clicks_before)
        layers["windows"][0]["screen_frame"] = [0, 0, 1920, 1080]
        # The click reached cmux without Cmd, or somewhere else: not run (CuaDriver modifiers or coordinates).
        for bad in ([350.5, 139.0, 0], [700.0, 280.0, 1]):
            landed[:] = bad
            journal["entries"][:] = [{"seq": 5, "kind": {"key": {}}}]
            with self.assertRaises(self.NotRun):
                self.rk.step_real_click(j, {"pane": "focused", "modifiers": ["cmd"]})

    def test_the_debug_key_mode_says_so(self):
        self.assertEqual(self.ext.step_smoke_key(self.journey("debug"), {"key": "n", "modifiers": ["cmd"]})["key_path"], "debug.key")
        self.assertEqual(self.ext.step_smoke_type(self.journey("debug"), {"text": "x"})["key_path"], "debug.key")
        self.assertEqual(self.sent, [])

    def test_a_refused_key_is_not_run_never_a_red(self):
        self.session.call = lambda tool, args: (True, {}, {"isError": True}) if tool != "list_windows" else \
            (False, {"windows": [{"pid": 7, "window_id": 9, "layer": 0, "bounds": {"width": 9, "height": 9}}]}, {})
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_key(self.journey("real"), {"key": "d", "modifiers": ["cmd"]})


class OmnibarDrawn(unittest.TestCase):
    """The typed address must be DRAWN in the address bar (coordinator 14:0xZ), read from the bar's own frame."""

    def setUp(self):
        sys.path.insert(0, str(HERE))
        import ext_smoke
        import ext_window

        class StepError(Exception):
            pass

        class NotRun(Exception):
            pass
        D = type("D", (), {"StepError": StepError, "NotRun": NotRun, "now": staticmethod(time.monotonic),
                           "ocr_contains": staticmethod(lambda lines, t: any(t in l for l in lines))})
        ext_smoke.install(D)
        ext_window.install(D)
        self.ext, self.win = ext_smoke, ext_window
        self.saved = (ext_window.windows, ext_window.png_size, ext_window.crop_read)
        self.crops = []

    def tearDown(self):
        self.win.windows, self.win.png_size, self.win.crop_read = self.saved

    def check(self, lines, rect=[600, 398, 100, 22]):
        crops = self.crops
        self.win.windows = lambda j: {"W": {"frame": [500, 100, 940, 720], "screen": [0, 0, 1920, 1080]}}
        self.win.png_size = lambda path: (1880, 1440)  # a 2x snapshot of the 940x720 window
        self.win.crop_read = lambda j, image, box, up: crops.append(box) or lines
        j = type("J", (), {})()
        j.key_window, j.checks, j.out = "W", 0, Path("/tmp")
        reply = {"field_frame": rect, "editor": {"text_kit": "2"}} if rect else {"field_frame": None, "editor": {}}
        j.app = type("A", (), {"rpc": staticmethod(lambda m, p=None: reply),
                               "snapshot": staticmethod(lambda path: Path(path))})()
        return self.ext.cond_smoke_omnibar_drawn(j, {"host": "example.com", "min_suffix": 6}, {})

    def test_the_bars_tail_counts_and_the_crop_is_the_bars_frame(self):
        ok, detail = self.check(["‹ample.com"])
        self.assertTrue(ok)
        self.assertEqual(detail["matched"], "ample.com")
        # field top from the window's top = 720 - (398 + 22) = 300; at (600, 300) points, 2x, 3 points of padding
        self.assertEqual(self.crops[0], [1194, 594, 212, 56])

    def test_less_than_six_characters_or_another_text_is_not_drawn(self):
        self.assertFalse(self.check([".com"])[0])
        self.assertFalse(self.check(["Import cookies from Safari"])[0])
        self.assertTrue(self.check(["example.com"])[0])

    def test_no_field_frame_fails(self):
        ok, detail = self.check(["example.com"], rect=None)
        self.assertFalse(ok)
        self.assertIn("no field frame", detail["error"])


class FailingStep(unittest.TestCase):
    def test_a_failed_finally_step_is_never_the_rounds_failing_step(self):
        mod = load_gate()
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / mod.JOURNEY
            d.mkdir()
            steps = [{"do": "expect", "ok": True}, {"do": "rpc", "ok": False, "error": "x", "finally": True}]
            (d / "result.json").write_text(json.dumps({"steps": steps}))
            self.assertIsNone(mod.failing_step(Path(tmp)))
            steps.insert(1, {"do": "expect", "ok": False, "error": "real", "title": "t"})
            (d / "result.json").write_text(json.dumps({"steps": steps}))
            self.assertEqual(mod.failing_step(Path(tmp))["error"], "real")


class OpenP0(unittest.TestCase):
    """A .pass needs every open P0 journey passed, and never failed, on the exact build (cmux-ad 12:35Z)."""

    def test_an_open_p0_without_a_pass_on_the_build_blocks_the_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            open(os.path.join(tmp, "open-p0.txt"), "w").write(
                "# comment\nr3-new-tab-panel kit@1 owner STATUS-1017\nj-a|j-b kit@2 owner STATUS-1\n")
            code, summary = gate(["pass"] * 10, tmp, extra=("--hosts", "cmux99", "--whole-host", "cmux99"))
            self.assertEqual(summary["verdict"], "PASS")
            self.assertEqual(code, 75)
            self.assertFalse(os.path.exists(os.path.join(tmp, "handoff", "job123.pass")))
            if not summary["gate_dirty"]:  # the open-P0 check runs after the committed-gate check
                text = open(os.path.join(tmp, "out", "open-p0.txt")).read()
                self.assertIn("r3-new-tab-panel", text)
                self.assertIn("has not passed on job123", text)

    def test_the_ledger_decides_pass_fail_and_other_builds(self):
        mod = load_gate()
        with tempfile.TemporaryDirectory() as tmp:
            mod.OPEN_P0, mod.P0_LEDGER = Path(tmp) / "list.txt", Path(tmp) / "ledger"
            mod.OPEN_P0.write_text("r3-new-tab-panel k o S1\nj-a|j-b k o S2\n")
            mod.P0_LEDGER.mkdir()
            ok = {"kit_dirty": False, "options": {}}
            rows = [{"id": "r3-new-tab-panel", "status": "pass", "build_job": "J", **ok},
                    {"id": "j-b", "status": "pass", "build_job": "J", "kit_dirty": True, "options": {}},
                    {"id": "j-a", "status": "pass", "build_job": "J", "kit_dirty": False,
                     "options": {"smoke_mode": "diagnostic"}},
                    {"id": "r3-new-tab-panel", "status": "pass", "build_job": "OTHER"}]
            (mod.P0_LEDGER / "J.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n")
            mod.P0_WAIVERS = Path(tmp) / "waivers.txt"
            # j-a|j-b: a dirty-kit pass and a diagnostic pass do not count
            self.assertEqual([b[0].split()[0] for b in mod.open_p0_blockers("J")], ["j-a|j-b"])
            with open(mod.P0_LEDGER / "J.jsonl", "a") as f:
                f.write(json.dumps({"id": "j-b", "status": "pass", "build_job": "J", **ok}) + "\n")
            self.assertEqual(mod.open_p0_blockers("J"), [])
            with open(mod.P0_LEDGER / "J.jsonl", "a") as f:
                f.write(json.dumps({"id": "r3-new-tab-panel", "status": "fail", "build_job": "J", "out": "/x"}) + "\n")
            blockers = mod.open_p0_blockers("J")
            self.assertEqual(len(blockers), 1)
            self.assertIn("FAILED on J", blockers[0][1])
            mod.P0_WAIVERS.write_text("/x the kit's text reader misread the line (STATUS 1412)\n")
            waived = []
            self.assertEqual(mod.open_p0_blockers("J", waived), [])
            self.assertEqual(waived[0]["out"], "/x")
            mod.P0_WAIVERS.write_text("")
            self.assertEqual(len(mod.open_p0_blockers("NONE")), 2)  # no results on that build: both block
            mod.OPEN_P0 = Path(tmp) / "missing.txt"
            self.assertIn("cannot be read", mod.open_p0_blockers("J")[0][1])

    def test_run_py_appends_each_result_to_the_ledger(self):
        sys.path.insert(0, str(HERE))
        import importlib
        run = importlib.import_module("run")
        with tempfile.TemporaryDirectory() as tmp:
            old, run.P0_LEDGER = run.P0_LEDGER, Path(tmp) / "ledger"
            try:
                run.record_p0_results([{"id": "x", "status": "pass", "build_job": "J", "reason": ""},
                                       {"id": "y", "status": "fail", "build_job": None}], Path(tmp) / "out")
            finally:
                ledger, run.P0_LEDGER = run.P0_LEDGER, old
            rows = [json.loads(l) for l in (ledger / "J.jsonl").read_text().splitlines()]
            self.assertEqual([(r["id"], r["status"], r["build_job"]) for r in rows], [("x", "pass", "J")])
            self.assertIn("kit_dirty", rows[0])
            in_git = subprocess.run(["git", "-C", str(HERE), "rev-parse", "HEAD"], capture_output=True).returncode == 0
            if in_git:
                self.assertTrue(rows[0]["kit"])
            else:
                self.assertTrue(rows[0]["kit_dirty"])  # no git: never counted as a clean kit


class GoSpec(unittest.TestCase):
    """--go-spec: one scheduler GO per round, all rounds one gate run (the tip watcher, lead STATUS 1354)."""

    @staticmethod
    def stamp(t):
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))

    def test_a_round_runs_on_the_gos_mini_inside_its_window_and_ends_the_go(self):
        with tempfile.TemporaryDirectory() as tmp:
            rounds_dir = os.path.join(tmp, "rounds")
            os.makedirs(rounds_dir)
            now = time.time()
            with open(os.path.join(rounds_dir, "spec-x.go"), "w") as f:
                json.dump({"spec": "spec-x", "host": "cmux99", "go": self.stamp(now - 5), "until": self.stamp(now + 300)}, f)
            ci = os.path.join(tmp, "fake-ci")
            with open(ci, "w") as f:
                f.write("#!/bin/sh\necho '{\"state\": \"done\"}'\n")
            os.chmod(ci, 0o755)
            code, summary = gate([{"status": "pass"}], tmp, extra=("--go-spec", "spec-x", "--hosts", "cmux98 cmux99"),
                                 env_extra={"SMOKE_GATE_SCHED_ROUNDS": rounds_dir, "SMOKE_GATE_CMUX_CI": ci})
            argv = json.load(open(os.path.join(tmp, "out", "round-01", "argv.json")))
            self.assertEqual(argv[argv.index("--hosts") + 1], "cmux99")
            env = json.load(open(os.path.join(tmp, "out", "round-01", "env.json")))
            bound = int(env["CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS"]) + int(env["CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS"])
            self.assertLessEqual(bound, 300 - 20)  # the lease starts before the GO's until
            done = json.load(open(os.path.join(rounds_dir, "spec-x.done")))
            self.assertNotIn("status", done)  # a round that took its lease uses up one of the spec's rounds
            self.assertEqual(summary["rounds_detail"][0]["go"]["host"], "cmux99")

    def test_a_short_or_foreign_go_is_given_back_and_a_used_go_is_never_reused(self):
        gate_mod = load_gate()
        with tempfile.TemporaryDirectory() as tmp:
            gate_mod.SCHED_ROUNDS = Path(tmp)
            now = time.time()
            go_file = os.path.join(tmp, "s.go")
            json.dump({"host": "cmux99", "go": self.stamp(now - 5), "until": self.stamp(now + 30)}, open(go_file, "w"))
            go, why = gate_mod.await_go("s", ["cmux99"], set(), now + 0.5, poll=0.1)
            self.assertIsNone(go)  # 30 s left < 60 s: given back, and not counted as a round taken
            self.assertEqual(json.load(open(os.path.join(tmp, "s.done")))["status"], "not run")
            self.assertEqual(gate_mod._utc("2026-10-31T11:00:00Z"), 1793444400)  # UTC whatever the local zone
            os.remove(os.path.join(tmp, "s.done"))
            json.dump({"host": "cmux42", "go": self.stamp(now - 3), "until": self.stamp(now + 400)}, open(go_file, "w"))
            go, _ = gate_mod.await_go("s", ["cmux99"], set(), now + 0.5, poll=0.1)
            self.assertIsNone(go)  # not one of --hosts
            json.dump({"host": "cmux99", "go": self.stamp(now - 1), "until": self.stamp(now + 400)}, open(go_file, "w"))
            used = set()
            go, _ = gate_mod.await_go("s", ["cmux99"], used, now + 0.5, poll=0.1)
            self.assertEqual(go["host"], "cmux99")
            used.add(go["go"])
            again, _ = gate_mod.await_go("s", ["cmux99"], used, time.time() + 0.3, poll=0.1)
            self.assertIsNone(again)  # the same GO twice is never two rounds
            if os.path.exists(os.path.join(tmp, "s.done")):
                os.remove(os.path.join(tmp, "s.done"))
            older = dict(go, go=go["go"] - 100)
            self.assertFalse(gate_mod.go_done("s", older, "x"))  # a .done for an older GO never ends the open one
            self.assertFalse(os.path.exists(os.path.join(tmp, "s.done")))


def load_gate():
    import importlib.util
    spec = importlib.util.spec_from_file_location("smoke_gate_mod", str(GATE))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


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

    def test_a_page_step_passes_when_the_chromium_page_child_of_a_main_window_holds_the_keys(self):
        # cmux21 tip smoke 18:22Z-21:25Z (builds 2ee98d9c, a6f13ca1, aae61943): after Cmd-T in a browser tab the
        # New Tab page's CefNSWindow, a child of the cmux window, was key, as the app is built to do
        # (ChromiumPageWindowMain). The check counted only a key main window and failed every debug.key round.
        j = self.journey([("w", "p1", "a", "T0", True)], {}, "p1")
        j.smoke_key_ok = True
        page = [{"id": 1, "kind": "main", "key": False, "parent": None},
                {"id": 2, "kind": "CefNSWindow", "class": "CefNSWindow", "key": True, "visible": True, "parent": 1}]
        j.app.rpc = lambda method, params=None: {"windows": page}
        ok, detail = self.ext.cond_smoke_key_window(j, {"page": True}, {})
        self.assertTrue(ok, detail)
        self.assertEqual(detail.get("holder"), {"page": 2, "of_main": 1})
        # Without "page" the step still wants the main window itself key (a terminal step: keys to a page are wrong).
        self.assertFalse(self.ext.cond_smoke_key_window(j, {}, {})[0])
        # A page window that is the child of no main window of the app, or a key panel, never passes.
        for other in ({"id": 2, "kind": "CefNSWindow", "key": True, "visible": True, "parent": 9},
                      {"id": 2, "kind": "panel", "key": True, "visible": True, "parent": 1},
                      {"id": 2, "kind": "CefNSWindow", "key": True, "visible": False, "parent": 1}):
            j.app.rpc = lambda method, params=None, o=other: {"windows": [page[0], o]}
            self.assertFalse(self.ext.cond_smoke_key_window(j, {"page": True}, {})[0], other)
        # Typing at once into a terminal still refuses a key page window.
        j.app.rpc = lambda method, params=None: {"windows": page}
        j.key = lambda *a: None
        with self.assertRaises(self.StepError):
            self.ext.step_smoke_type_now(j, {"text": "x"})

    def test_the_cmd_t_step_lets_the_new_tab_page_hold_the_keys(self):
        spec = json.loads((Path(__file__).resolve().parent / "journeys" / "dogfood" / "smoke-dogfood.json").read_text())
        cmdt = [s for s in spec["steps"] if s.get("since") == "cmdt" and s.get("do") == "expect"]
        self.assertEqual(len(cmdt), 1)
        self.assertIn({"smoke_key_window": {"page": True}}, cmdt[0]["all"])
        # Every other key-window check still wants a main window key.
        others = [c for s in spec["steps"] if s is not cmdt[0] for c in s.get("all", []) if "smoke_key_window" in c]
        self.assertTrue(others)
        self.assertTrue(all(c == {"smoke_key_window": {}} for c in others), others)

    def test_a_key_window_lost_to_a_prompt_that_was_already_there_is_not_judged_not_a_fail(self):
        j = self.journey([("w", "p1", "a", "T0", True)], {}, "p1")
        j.smoke_key_ok = True  # the window was key, then the console's system prompt took the keys back
        j.app.rpc = lambda method, params=None: {"windows": [{"id": 1, "kind": "main", "key": False}]}
        j.app.identity = {"bundle_id": "com.cmuxterm.app.debug.x"}
        front = self.ext._front_app
        prompt = ("UserNotificationCenter", "com.apple.UserNotificationCenter")
        try:
            self.ext._front_app = lambda: prompt
            j.smoke_front_before = prompt  # the prompt was front before smoke_make_key
            ok, detail = self.ext.cond_smoke_key_window(j, {}, {})
            self.assertTrue(ok)  # holds for this step, so the step's other checks are still judged
            self.assertIn("UserNotificationCenter", detail["not_checked"])
            self.assertEqual(len(j.smoke_key_gaps), 1)
            # The same prompt appeared only during the journey (the app may have raised it): a fail.
            j.smoke_front_before = (None, None)
            self.assertFalse(self.ext.cond_smoke_key_window(j, {}, {})[0])
            # The app's own helper is front: the app's fault, a fail.
            self.ext._front_app = lambda: ("cmux helper", "com.cmuxterm.app.debug.x.helper")
            j.smoke_front_before = ("cmux helper", "com.cmuxterm.app.debug.x.helper")
            self.assertFalse(self.ext.cond_smoke_key_window(j, {}, {})[0])
            # The front app cannot be read: a fail.
            self.ext._front_app = lambda: (None, None)
            self.assertFalse(self.ext.cond_smoke_key_window(j, {}, {})[0])
        finally:
            self.ext._front_app = front

    def test_diagnostic_mode_on_a_slot_where_the_key_was_lost_is_not_checked(self):
        j = self.journey([("w", "p1", "a", "T0", True)], {}, "p1")
        j.spec = {"options": {"smoke_mode": "diagnostic"}}
        j.smoke_key_ok = True  # smoke_make_key got the key for a moment (cmux21, 2026-10-31 10:3xZ)
        j.app.rpc = lambda method, params=None: {"windows": [{"id": 1, "kind": "main", "key": False}]}
        ok, detail = self.ext.cond_smoke_key_window(j, {}, {})
        self.assertTrue(ok, detail)
        self.assertTrue(detail["was_key_at_make_key"])
        j.app.rpc = lambda method, params=None: {"windows": [{"id": 1, "kind": "main", "key": False},
                                                             {"id": 2, "kind": "panel", "key": True}]}
        self.assertFalse(self.ext.cond_smoke_key_window(j, {}, {})[0])

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

    def test_split_lines_must_be_in_the_panes_made_for_them_in_order(self):
        before = [("w", "pA", "a", "T0", True)]
        after = before + [("w", "pB", "b", "T1", False), ("w", "pC", "c", "T2", True)]
        def run(screens, xs, focused="pC"):
            j = self.journey(after, screens, focused)
            j.app.panes = lambda: [{"pane": p, "focused": p == focused, "grid": {"frame_x": x}} for p, x in xs.items()]
            snap = self.journey(before, {}, "pA")
            self.ext.step_smoke_snapshot(snap, {"name": "s"})
            j.smoke_snapshots = snap.smoke_snapshots
            return self.ext.cond_smoke_new_terminals(j, {"since": "s", "lines": ["d1", "d2"], "focused": "d2",
                                                         "placement": "new_panes", "order": "left_to_right"}, {})
        xs = {"pA": 0.0, "pB": 450.0, "pC": 671.0}
        ok, detail = run({"T1": "d1", "T2": "d2"}, xs)
        self.assertTrue(ok, detail)
        # Swapped: d1 in the right pane, d2 in the left one (focus on d2's pane): fails on the order.
        ok, detail = run({"T1": "d2", "T2": "d1"}, xs, focused="pB")
        self.assertFalse(ok)
        self.assertTrue(any("left to right" in p for p in detail["problems"]), detail["problems"])
        # TIP RED 1193: both lines in the first new pane (pB), focus kept on pB: fails.
        ok, detail = run({"T1": "d1\nd2"}, xs, focused="pB")
        self.assertFalse(ok)

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

        class NotRun(Exception):
            pass

        ext_smoke.install(type("D", (), {"StepError": StepError, "NotRun": NotRun, "now": staticmethod(lambda: 0.0)}))
        self.ext, self.StepError, self.NotRun = ext_smoke, StepError, NotRun

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
        topo_panes = [{"id": "P1", "column": 0, "selected_tab": "tab-P1", "tabs": [{"id": "tab-P1", "terminal": "T-P1"}]}]
        for column, key, x0, width in (columns or []):
            panes.append({"pane": key, "workspace": "W", "content_size": "%dx400" % int(width),
                          "grid": {"frame_x": x0, "frame_width": width}})
            topo_panes.append({"id": key, "column": column, "selected_tab": "tab-" + key,
                               "tabs": [{"id": "tab-" + key, "terminal": "T-" + key}]})

        shell = {"pid": os.getpid()}

        class App:
            def panes(self_):
                return panes

            def screen(self_, term):
                return {"text": screen_text, "cols": daemon[0], "rows": daemon[1]}

            def cmux(self_, *args):
                if args[:1] == ("screen",):
                    cols = [{"width": w, "root": {"kind": "leaf", "pane_id": k, "tab_ids": ["t"]}}
                            for k, w in shell.get("daemon_cols", [])]
                    return {"root": {"kind": "viewport", "columns": cols}} if cols else {}
                return {"pid": shell["pid"]}

        class J:
            app = App()
            vars = {}
            pane = "P1"
            shell_state = shell
            smoke_named = {"right": {"pane": "P1", "term": "T1"}}
            ext_remembered = {"right0": {"grid": (70, 24)}, "right1": {"grid": (90, 24)}}
            smoke_long = {"LL": 95}

            def sub(self_, x):
                return x

            def topology(self_):
                return {"workspaces": [{"id": "W", "screens": [{"id": "S", "panes": topo_panes}]}]}

            @staticmethod
            def places(topology):
                yield {"id": "W"}, {"id": "P1"}, {"id": "t", "columns": topo[0], "rows": topo[1]}, "T1"
                for pane in (topology or {}).get("workspaces", [{}])[0].get("screens", [{}])[0].get("panes", [])[1:]:
                    yield {"id": "W"}, pane, pane["tabs"][0], pane["tabs"][0]["terminal"]
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

    def test_r3_reads_the_screen_again_once_after_a_failed_read(self):
        j = self.journey()
        calls = {"n": 0}
        real = j.app.screen

        def flaky(term):
            calls["n"] += 1
            if calls["n"] == 1:
                raise self.StepError("slow reply")
            return real(term)
        j.app.screen = flaky
        sleep = self.ext.time.sleep
        self.ext.time.sleep = lambda s: None
        try:
            ok, detail = self.r3(j)
        finally:
            self.ext.time.sleep = sleep
        self.assertTrue(ok, detail)
        self.assertEqual(calls["n"], 2)

    def test_uneven_padding_is_not_a_misfit_but_a_spare_column_is(self):
        # 80 columns of 8 points, left padding 4, right padding 9 (an uneven split of the leftover): fits.
        ok, detail = self.r3(self.journey(frame=(4 + 80 * 8 + 9, 24 * 16 + 8)))
        self.assertTrue(ok, detail)
        # Right padding 4 + 8: a whole column is left unused: misfit.
        ok, detail = self.r3(self.journey(frame=(4 + 80 * 8 + 12, 24 * 16 + 8)))
        self.assertFalse(ok, detail)
        self.assertTrue(any("fit(bounds)" in p for p in detail["problems"]), detail["problems"])

    def test_r3b_a_column_with_no_frame_is_not_judged(self):
        j = self.journey(columns=[(1, "P2", 650.0, 300.0)])
        self.ext.step_smoke_widths(j, {"name": "c0"})
        later = self.journey(columns=[(1, "P2", 650.0, 300.0), (2, "P3", 951.0, 300.0)])
        later.smoke_width_snaps = j.smoke_width_snaps
        del later.app.panes()[1]["grid"]  # old P2 has no frame now (off screen, closed under memory pressure)
        clock = {"t": 0.0}
        self.ext.D.now = staticmethod(lambda: clock["t"])
        # Not judged yet while frames may still come: this poll does not hold.
        ok, detail = self.ext.cond_smoke_same_widths(later, {"since": "c0", "new": 1}, {})
        self.assertFalse(ok)
        self.assertTrue(detail["waiting_for_frames"])
        # Past UNKNOWN_SECONDS, with P2's terminal alive (daemon pane, screen, shell process): the view is only
        # hidden: not judged (the round is "not run"), never a fail or a pass.
        clock["t"] = self.ext.UNKNOWN_SECONDS + 0.1
        with self.assertRaises(self.NotRun) as caught:
            self.ext.cond_smoke_same_widths(later, {"since": "c0", "new": 1}, {})
        self.assertIn("P2", str(caught.exception))
        # P2's terminal process is gone (killed under memory pressure): a FAIL, never "not judged".
        later.shell_state["pid"] = 999999
        later.smoke_unknown_since = {"c0": 0.0}
        with self.assertRaises(self.StepError) as caught:
            self.ext.cond_smoke_same_widths(later, {"since": "c0", "new": 1}, {})
        self.assertIn("TERMINAL GONE", str(caught.exception))
        self.assertIn("999999", str(caught.exception))
        bare = self.journey(columns=[(1, "P2", 650.0, 300.0)])
        del bare.app.panes()[1]["grid"]
        bare.shell_state["pid"] = 999999  # a frameless pane whose shell is dead: the snapshot step fails at once
        with self.assertRaises(self.StepError):
            self.ext.step_smoke_widths(bare, {"name": "c1", "frame_wait": 0.3})

    def test_a_hidden_column_is_judged_by_the_daemons_column_width(self):
        j = self.journey(columns=[(1, "P2", 650.0, 300.0)])
        j.shell_state["daemon_cols"] = [("P1", 0.5), ("P2", 0.5)]
        self.ext.step_smoke_widths(j, {"name": "c0"})
        later = self.journey(columns=[(1, "P2", 650.0, 300.0), (2, "P3", 951.0, 300.0)])
        later.smoke_width_snaps = j.smoke_width_snaps
        del later.app.panes()[1]["grid"]  # P2's view is hidden; its terminal lives
        # The daemon keeps P2's column at 0.5: holds, judged from the daemon.
        later.shell_state["daemon_cols"] = [("P1", 0.5), ("P2", 0.5), ("P3", 0.5)]
        ok, detail = self.ext.cond_smoke_same_widths(later, {"since": "c0", "new": 1}, {})
        self.assertTrue(ok, detail)
        self.assertEqual(detail["daemon_resolved"]["1"]["source"], "daemon")
        # The daemon shrank P2's column to 0.25: fails, with both shares.
        later.shell_state["daemon_cols"] = [("P1", 0.5), ("P2", 0.25), ("P3", 0.5)]
        ok, detail = self.ext.cond_smoke_same_widths(later, {"since": "c0", "new": 1}, {})
        self.assertFalse(ok)
        self.assertEqual((detail["changed"]["1"]["old"], detail["changed"]["1"]["new"]), (0.5, 0.25))

    def test_a_new_pane_without_its_frame_yet_does_not_hide_the_old_column(self):
        # Split Down adds P6 to column 1; P6 has no frame yet at this poll. Column 1's width is read from P2 alone.
        j = self.journey(columns=[(1, "P2", 650.0, 300.0)])
        self.ext.step_smoke_widths(j, {"name": "c0"})
        down = self.journey(columns=[(1, "P2", 650.0, 300.0), (1, "P6", 650.0, 300.0)])
        down.smoke_width_snaps = j.smoke_width_snaps
        del down.app.panes()[2]["grid"]
        ok, detail = self.ext.cond_smoke_same_widths(down, {"since": "c0", "new": 0}, {})
        self.assertTrue(ok, detail)

    def test_a_column_that_grew_to_hold_a_new_pane_beside_its_old_ones_fails(self):
        j = self.journey(columns=[(1, "P2", 650.0, 300.0)])
        self.ext.step_smoke_widths(j, {"name": "c0"})
        # P6 joins column 1 to the right of P2: P2 keeps 300 points, but the column is now 600 wide.
        grew = self.journey(columns=[(1, "P2", 650.0, 300.0), (1, "P6", 951.0, 300.0)])
        grew.smoke_width_snaps = j.smoke_width_snaps
        ok, detail = self.ext.cond_smoke_same_widths(grew, {"since": "c0", "new": 0}, {})
        self.assertFalse(ok)
        self.assertEqual(detail["changed"]["1"]["all_panes_span"], 601.0)
        # The new columns' widths are in the evidence.
        added = self.journey(columns=[(1, "P2", 650.0, 300.0), (2, "P7", 951.0, 250.0)])
        added.smoke_width_snaps = j.smoke_width_snaps
        ok, detail = self.ext.cond_smoke_same_widths(added, {"since": "c0", "new": 1}, {})
        self.assertTrue(ok, detail)
        self.assertEqual(detail["new_widths"]["2"], 250.0)

    def test_a_real_failure_is_judged_even_when_a_width_is_unknown(self):
        # Column 0's pane has no frame, and Cmd-D opened a column instead of splitting: a FAIL, not "not judged".
        j = self.journey(columns=[(1, "P2", 650.0, 300.0)])
        j.app.panes()[1]["focused"], j.app.panes()[0]["focused"] = True, False
        self.ext.step_smoke_widths(j, {"name": "c0"})
        opened = self.journey(columns=[(1, "P2", 650.0, 300.0), (2, "P5", 951.0, 300.0)])
        opened.smoke_width_snaps = j.smoke_width_snaps
        del opened.app.panes()[0]["grid"]
        ok, detail = self.ext.cond_smoke_same_widths(opened, {"since": "c0", "new": 0, "split_in_place": True}, {})
        self.assertFalse(ok)
        self.assertTrue(any("new columns" in p for p in detail["problems"]), detail["problems"])

    def test_a_snapshot_with_a_hidden_live_pane_is_kept_and_judged_by_the_daemon(self):
        bare = self.journey(columns=[(1, "P2", 650.0, 300.0)])
        bare.shell_state["daemon_cols"] = [("P1", 0.5), ("P2", 0.5)]
        del bare.app.panes()[1]["grid"]  # P2's view hidden, its terminal alive
        result = self.ext.step_smoke_widths(bare, {"name": "c1", "frame_wait": 0.3})
        self.assertIsNone(result["widths"]["1"])
        self.assertIn("P2", result["hidden_alive"])
        later = self.journey(columns=[(1, "P2", 650.0, 300.0), (2, "P3", 951.0, 300.0)])
        later.smoke_width_snaps = bare.smoke_width_snaps
        del later.app.panes()[1]["grid"]
        later.shell_state["daemon_cols"] = [("P1", 0.5), ("P2", 0.5), ("P3", 0.5)]
        ok, detail = self.ext.cond_smoke_same_widths(later, {"since": "c1", "new": 1}, {})
        self.assertTrue(ok, detail)
        later.shell_state["daemon_cols"] = [("P1", 0.5), ("P2", 0.3), ("P3", 0.5)]
        self.assertFalse(self.ext.cond_smoke_same_widths(later, {"since": "c1", "new": 1}, {})[0])

    def test_cmd_d_splits_in_place_and_no_other_column_changes(self):
        base = [(1, "P2", 650.0, 300.0)]
        j = self.journey(columns=base)
        j.app.panes()[1]["focused"], j.app.panes()[0]["focused"] = True, False  # P2 (column 1) is focused
        self.ext.step_smoke_widths(j, {"name": "c0"})
        self.assertEqual(j.smoke_width_snaps["c0"]["focused"], "P2")
        # P2 splits inside column 1 (P2 and P5 share it); column 0 keeps its width: holds.
        good = self.journey(columns=[(1, "P2", 650.0, 150.0), (1, "P5", 800.0, 150.0)])
        good.smoke_width_snaps = j.smoke_width_snaps
        ok, detail = self.ext.cond_smoke_same_widths(good, {"since": "c0", "new": 0, "split_in_place": True}, {})
        self.assertTrue(ok, detail)
        # Cmd-D opened a column instead: fails ("1 new columns, not 0").
        column = self.journey(columns=[(1, "P2", 650.0, 300.0), (2, "P5", 951.0, 300.0)])
        column.smoke_width_snaps = j.smoke_width_snaps
        ok, detail = self.ext.cond_smoke_same_widths(column, {"since": "c0", "new": 0, "split_in_place": True}, {})
        self.assertFalse(ok)
        # Another column changed width: fails, with old and new.
        other = self.journey(columns=[(1, "P2", 650.0, 150.0), (1, "P5", 800.0, 150.0)],
                             frame=(80 * 8 + 8 - 40, 24 * 16 + 8))
        other.smoke_width_snaps = j.smoke_width_snaps
        ok, detail = self.ext.cond_smoke_same_widths(other, {"since": "c0", "new": 0, "split_in_place": True}, {})
        self.assertFalse(ok)
        self.assertIn("0", detail["changed"])

    def test_split_down_adds_no_column_and_keeps_every_width(self):
        j = self.journey(columns=[(1, "P2", 650.0, 300.0)])
        self.ext.step_smoke_widths(j, {"name": "c0"})
        down = self.journey(columns=[(1, "P2", 650.0, 300.0), (1, "P6", 650.0, 300.0)])
        down.smoke_width_snaps = j.smoke_width_snaps
        ok, detail = self.ext.cond_smoke_same_widths(down, {"since": "c0", "new": 0}, {})
        self.assertTrue(ok, detail)
        opened = self.journey(columns=[(1, "P2", 650.0, 300.0), (2, "P6", 951.0, 300.0)])
        opened.smoke_width_snaps = j.smoke_width_snaps
        self.assertFalse(self.ext.cond_smoke_same_widths(opened, {"since": "c0", "new": 0}, {})[0])

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


class SettleThroughTheDriver(unittest.TestCase):
    """smoke_same_widths through the real driver.Journey.step_expect (its polls and its settle): an old pane that
    loses its frame after the check held is not judged (not run), never a FAIL; a frame never lost passes."""

    def run_step(self, lose_after, shell_pid=None, back_after=None):
        sys.path.insert(0, str(HERE))
        sys.path.insert(0, str(HERE.parent / "cmux-next"))  # driver.py imports build_names from there
        import driver
        import ext_smoke
        ext_smoke.install(driver)
        t0 = driver.now()
        topo = {"workspaces": [{"id": "W", "screens": [{"panes": [
            {"id": k, "column": c, "selected_tab": "tab-" + k, "tabs": [{"id": "tab-" + k, "terminal": "T-" + k}]}
            for k, c in (("P1", 0), ("P2", 1), ("P3", 2))]}]}]}

        class App:
            snapshot_window = None

            def rpc(self_, method, params=None):
                return {"topology": topo} if method == "snapshot.get" else {}

            def screen(self_, term):
                return {"text": "$", "cols": 80, "rows": 24}

            def cmux(self_, *args):
                if args[:2] == ("terminal", "list"):
                    return {"terminals": [{"terminal_id": "T-" + k, "lifecycle": "running", "exit": None}
                                          for k in ("P1", "P2", "P3")]}
                return {"pid": shell_pid or os.getpid()}

            def panes(self_):
                elapsed = driver.now() - t0
                lost = lose_after is not None and elapsed >= lose_after and not (back_after and elapsed >= back_after)
                rows = [{"pane": "P1", "workspace": "W", "grid": {"frame_x": 0.0, "frame_width": 300.0}},
                        {"pane": "P2", "workspace": "W", "grid": {"frame_x": 301.0, "frame_width": 300.0}},
                        {"pane": "P3", "workspace": "W", "grid": {"frame_x": 602.0, "frame_width": 300.0}}]
                if lost:
                    del rows[0]["grid"]
                return rows

        with tempfile.TemporaryDirectory() as tmp:
            j = driver.Journey({"id": "settle-test", "steps": []}, App(), tmp, driver.now() + 60, 1.0)
            j.smoke_width_snaps = {"c0": {"workspace": "W", "widths": {"0": 300.0, "1": 300.0},
                                          "columns": {"0": ["P1"], "1": ["P2"]}, "focused": "P2"}}
            j.marks["m"] = driver.now()
            return j.step_expect({"title": "R3b settle", "since": "m", "timeout": 4, "settle": 1.5,
                                  "all": [{"smoke_same_widths": {"since": "c0", "new": 1}}]}), driver

    def test_a_gone_terminal_ends_the_step_through_the_driver_even_if_the_frame_comes_back(self):
        sys.path.insert(0, str(HERE))
        sys.path.insert(0, str(HERE.parent / "cmux-next"))
        import driver
        # P1's frame is lost at once and its shell pid is dead; the frame comes back after 0.6 s (before the 4 s timeout).
        with self.assertRaises(driver.TerminalGone) as caught:
            self.run_step(0.0, shell_pid=999999, back_after=0.6)
        self.assertIn("TERMINAL GONE", str(caught.exception))
        self.assertIn("999999", str(caught.exception))

    def test_a_key_gap_never_hides_a_failing_check_in_the_same_step(self):
        sys.path.insert(0, str(HERE))
        sys.path.insert(0, str(HERE.parent / "cmux-next"))
        import driver
        import ext_smoke
        ext_smoke.install(driver)

        class App:
            snapshot_window = None
            identity = {"bundle_id": "com.cmuxterm.app.debug.x"}

            def rpc(self_, method, params=None):
                if method == "debug.window_list":
                    return {"windows": [{"id": 1, "kind": "main", "key": False}]}
                return {}

            def panes(self_):
                return []

        prompt = ("UserNotificationCenter", "com.apple.UserNotificationCenter")
        front = ext_smoke._front_app
        ext_smoke._front_app = lambda: prompt
        try:
            with tempfile.TemporaryDirectory() as tmp:
                j = driver.Journey({"id": "gap-test", "steps": []}, App(), tmp, driver.now() + 60, 1.0)
                j.smoke_key_ok, j.smoke_front_before = True, prompt
                j.marks["m"] = driver.now()
                # The key gap plus a check that fails (no such workspaces): the step FAILS, the gap does not hide it.
                j.smoke_baseline = set()
                j.topology = lambda: {"workspaces": []}
                with self.assertRaises(driver.StepError) as caught:
                    j.step_expect({"title": "gap", "since": "m", "timeout": 1,
                                   "all": [{"smoke_key_window": {}}, {"smoke_workspaces": {"new": 3}}]})
                self.assertIn("smoke_workspaces", str(caught.exception))
                # The key gap alone: the step passes and the gap is recorded for smoke-gate.py.
                j.step_expect({"title": "gap2", "since": "m", "timeout": 1, "all": [{"smoke_key_window": {}}]})
                self.assertTrue(any(e["detail"].get("not_checked") for e in j.evidence if isinstance(e.get("detail"), dict)))
        finally:
            ext_smoke._front_app = front

    def test_a_not_judged_check_does_not_end_the_journey(self):
        sys.path.insert(0, str(HERE))
        sys.path.insert(0, str(HERE.parent / "cmux-next"))
        import driver

        class App:
            snapshot_window = None
            bundle = "/stand-in/cmux DEV t.app"

            def rpc(self_, method, params=None):
                return {}

            def snapshot(self_, path):
                raise driver.StepError("no frames here")

            def daemon_facts(self_):  # the daemons are the build under test (test_daemon_skew covers skew)
                own = self_.bundle + "/Contents/Resources/bin/cmux"
                return {"expected_build": "abc", "cmux_tui": {"pid": 1, "exe": own, "build_id": "abc"}, "acpmux": None}

        calls = []
        driver.Journey.step_t_mark = lambda self, step: calls.append(step["n"]) or {}
        orig = dict(driver.EXT_CONDITIONS)
        driver.EXT_CONDITIONS["t_unjudged"] = lambda j, want, cache: (_ for _ in ()).throw(driver.NotRun("hidden view"))
        driver.EXT_CONDITIONS["t_fails"] = lambda j, want, cache: (False, {})
        driver.KIND.setdefault("t_unjudged", "app")
        driver.KIND.setdefault("t_fails", "app")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                steps = [{"do": "expect", "title": "R3b x", "timeout": 0.2, "all": [{"t_unjudged": {}}]},
                         {"do": "t_mark", "n": 2}]
                spec = {"id": "nj", "continue_not_judged": True, "steps": steps}
                result = driver.Journey(spec, App(), tmp, driver.now() + 30, 1.0).run()
                self.assertEqual(result["status"], "not run")
                self.assertEqual(calls, [2])  # the step after the not-judged check ran
                self.assertIs(result["steps"][0]["ok"], None)
                # A later failure still fails the journey.
                steps.append({"do": "expect", "title": "later", "timeout": 0.2, "all": [{"t_fails": {}}]})
                result = driver.Journey(dict(spec, id="nj2"), App(), tmp, driver.now() + 30, 1.0).run()
                self.assertEqual(result["status"], "fail")
                # A later NotRun from a non-expect step keeps the earlier not-judged list in the reason (S3).
                driver.Journey.step_t_stop = lambda self, step: (_ for _ in ()).throw(driver.NotRun("stopped"))
                result = driver.Journey(dict(spec, id="nj4", steps=steps[:1] + [{"do": "t_stop"}]), App(), tmp,
                                        driver.now() + 30, 1.0).run()
                self.assertEqual(result["status"], "not run")
                self.assertIn("hidden view", result["reason"])
                del driver.Journey.step_t_stop
                # Without the option, a not-judged check ends the journey.
                calls.clear()
                result = driver.Journey({"id": "nj3", "steps": steps[:2]}, App(), tmp, driver.now() + 30, 1.0).run()
                self.assertEqual((result["status"], calls), ("not run", []))
        finally:
            driver.EXT_CONDITIONS.clear()
            driver.EXT_CONDITIONS.update(orig)
            del driver.Journey.step_t_mark

    def test_the_post_relaunch_daemon_sample_waits_for_the_step_after_the_relaunch(self):
        """Review at 1548fb29ce5: the expect after a relaunch measures from its mark; the sample must not run inside."""
        sys.path.insert(0, str(HERE))
        sys.path.insert(0, str(HERE.parent / "cmux-next"))
        import driver
        order = []

        class App:
            snapshot_window = None
            bundle = "/stand-in/cmux DEV t.app"

            def rpc(self_, method, params=None):
                return {}

            def daemon_facts(self_):
                order.append("sample")
                own = self_.bundle + "/Contents/Resources/bin/cmux"
                return {"expected_build": "abc", "cmux_tui": {"pid": 1, "exe": own, "build_id": "abc"}, "acpmux": None}
        driver.Journey.step_t_step = lambda self, step: order.append(step["n"]) or {}
        real_relaunch = driver.Journey.step_relaunch
        driver.Journey.step_relaunch = lambda self, step: order.append("relaunch") or {}
        try:
            with tempfile.TemporaryDirectory() as tmp:
                steps = [{"do": "t_step", "n": 1}, {"do": "relaunch"}, {"do": "t_step", "n": 3}, {"do": "t_step", "n": 4}]
                driver.Journey({"id": "rs", "steps": steps}, App(), tmp, driver.now() + 30, 1.0).run()
        finally:
            del driver.Journey.step_t_step
            driver.Journey.step_relaunch = real_relaunch
        self.assertEqual(order, [1, "sample", "relaunch", 3, "sample", 4, "sample"])
        # A relaunch whose mark a later step measures from: the sample waits for that step (review S1 at f8de46b2f79).
        order.clear()
        driver.Journey.step_t_step = lambda self, step: order.append(step["n"]) or {}
        driver.Journey.step_relaunch = lambda self, step: order.append("relaunch") or {}
        try:
            with tempfile.TemporaryDirectory() as tmp:
                steps = [{"do": "t_step", "n": 1}, {"do": "relaunch", "mark": "reopened"}, {"do": "t_step", "n": 3},
                         {"do": "t_step", "n": 4, "since": "reopened"}, {"do": "t_step", "n": 5}]
                driver.Journey({"id": "rs2", "steps": steps}, App(), tmp, driver.now() + 30, 1.0).run()
        finally:
            del driver.Journey.step_t_step
            driver.Journey.step_relaunch = real_relaunch
        self.assertEqual(order, [1, "sample", "relaunch", 3, 4, "sample", 5, "sample"])

    def test_app_log_records_only_and_never_fails_a_round(self):
        sys.path.insert(0, str(HERE))
        import ext_realkey
        j = type("J", (), {"app": type("A", (), {"pid": 7})()})()
        real = ext_realkey.subprocess.run

        def slow(*a, **k):
            raise ext_realkey.subprocess.TimeoutExpired("log", 60)
        ext_realkey.subprocess.run = slow
        try:
            done = ext_realkey.step_app_log(j, {"seconds": 30, "grep": "newTab"})
        finally:
            ext_realkey.subprocess.run = real
        self.assertEqual(done["count"], 0)
        self.assertIn("error", done)

    def test_the_page_check_accepts_any_language_of_example_com(self):
        sys.path.insert(0, str(HERE))
        import ext_smoke
        D = type("D", (), {"ocr_contains": staticmethod(lambda lines, t: any(t in l for l in lines))})
        ext_smoke.install(D)
        j = type("J", (), {})()
        j.checks, j.out = 0, Path("/tmp")
        j.sub = lambda x: x
        j.app = type("A", (), {"snapshot": staticmethod(lambda p: Path(p)),
                               "read_text": staticmethod(lambda image: ["Este dominio está destinado al uso en",
                                                                         "ejemplos de documentación sin"])})()
        ok, detail = ext_smoke.cond_smoke_frame_any(j, {"texts": ["documentation examples", "ejemplos de documentaci"]}, {})
        self.assertTrue(ok)
        self.assertEqual(detail["matched"], "ejemplos de documentaci")
        j.app.read_text = staticmethod(lambda image: ["Ask anything"])
        self.assertFalse(ext_smoke.cond_smoke_frame_any(j, {"texts": ["documentation examples"]}, {})[0])

    def test_a_frame_never_lost_passes(self):
        result, _driver = self.run_step(None)
        self.assertTrue(result)

    def test_a_frame_lost_during_the_settle_is_not_judged(self):
        sys.path.insert(0, str(HERE))
        sys.path.insert(0, str(HERE.parent / "cmux-next"))
        import driver
        with self.assertRaises(driver.NotRun):
            self.run_step(0.3)



class Burst(unittest.TestCase):
    """smoke_burst: one debug.key sequence of real key events (TIP RED 1193's hold path, cmux-ad 11:05Z)."""

    def setUp(self):
        sys.path.insert(0, str(HERE))
        import ext_smoke

        class StepError(Exception):
            pass

        class NotRun(Exception):
            pass

        ext_smoke.install(type("D", (), {"StepError": StepError, "NotRun": NotRun, "now": staticmethod(lambda: 0.0)}))
        self.ext, self.NotRun = ext_smoke, NotRun

    def test_a_line_becomes_key_codes_with_shift_for_the_shifted_characters(self):
        steps = self.ext._seq_text("echo $(", 0)
        downs = [(st["key_code"], st["down"]) for st in steps]
        self.assertEqual(downs[:2], [(14, True), (14, False)])  # e
        self.assertIn((56, True), downs)  # shift for $ and (
        self.assertEqual(downs[-4:], [(56, True), (25, True), (25, False), (56, False)])  # ( = shift 9
        cmd_d = self.ext._seq_key(2, ("cmd",))
        self.assertEqual([(st["key_code"], st["down"]) for st in cmd_d], [(55, True), (2, True), (2, False), (55, False)])

    def test_the_burst_is_one_sequence_in_order_and_needs_the_key_window(self):
        sent = []

        class App:
            def rpc(self_, method, params=None):
                if method == "debug.key":
                    sent.append(params)
                    return {"scheduled": len(params["sequence"]), "duration_ms": 0}
                if method == "debug.input":
                    return {"holds": [{"path": "creation", "stage": {"count": len(sent) * 5}}]}
                if method == "debug.window_list":
                    return {"windows": [{"id": "W1", "kind": "main", "key": True}]}
                return {}

        class J:
            app, vars, marks, key_window, smoke_key_ok = App(), {}, {}, "W1", True

            def sub(self_, x):
                return x
        sleep = self.ext.time.sleep
        self.ext.time.sleep = lambda s: None
        try:
            result = self.ext.step_smoke_burst(J(), {"burst": [{"key": "d", "modifiers": ["cmd"], "mark": "m"},
                                                                {"text": "ab"}]})
        finally:
            self.ext.time.sleep = sleep
        self.assertEqual(len(sent), 1)
        codes = [(st["key_code"], st["down"]) for st in sent[0]["sequence"]]
        self.assertEqual(codes[:4], [(55, True), (2, True), (2, False), (55, False)])
        self.assertEqual(codes[-2:], [(36, True), (36, False)])  # Return after the line
        self.assertEqual(result["held_keys"], {"creation": 5})
        j = J()
        j.smoke_key_ok = False
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_burst(j, {"burst": [{"text": "a"}]})


    def _burst(self, replies, key=True, burst=None):
        class App:
            def rpc(self_, method, params=None):
                if method == "debug.key":
                    return replies
                if method == "debug.window_list":
                    return {"windows": [{"id": "W1", "kind": "main", "key": key}]}
                return {}

        class J:
            app, vars, marks, key_window, smoke_key_ok = App(), {}, {}, "W1", True

            def sub(self_, x):
                return x
        sleep = self.ext.time.sleep
        self.ext.time.sleep = lambda s: None
        try:
            return self.ext.step_smoke_burst(J(), {"burst": burst or [{"text": "a"}]})
        finally:
            self.ext.time.sleep = sleep

    def test_a_host_refusal_or_a_lost_key_window_is_not_run_and_a_bad_request_is_a_red(self):
        for error in ("no event timestamp to start the sequence from", "no window", "did not become key"):
            with self.assertRaises(self.NotRun):
                self._burst({"error": error})
        with self.assertRaises(self.ext.D.StepError):
            self._burst({"error": "each step needs key_code and down"})
        with self.assertRaises(self.NotRun):  # posted keys dropped with no key window
            self._burst({"scheduled": 2, "duration_ms": 0}, key=False)
        with self.assertRaises(self.ext.D.StepError):  # an unknown key name: a step error, never a traceback
            self._burst({"scheduled": 2}, burst=[{"key": "f13"}])


class HoldPath(unittest.TestCase):
    """smoke_hold_path: a TIP RED 1193 pass counts only on the hold path (cmux-ad 11:05Z)."""

    def setUp(self):
        sys.path.insert(0, str(HERE))
        import ext_smoke

        class StepError(Exception):
            pass

        class NotRun(Exception):
            pass

        ext_smoke.install(type("D", (), {"StepError": StepError, "NotRun": NotRun, "now": staticmethod(lambda: 0.0)}))
        self.ext, self.NotRun = ext_smoke, NotRun

    def _j(self, *typed, burst="none"):
        j = type("J", (), {"sub": lambda self_, x: x})()
        j.smoke_typed_paths = [{"line": line, "paths": paths} for line, paths in typed]
        if burst != "none":
            j.smoke_burst_holds = burst
        return j

    def test_responder_only_is_not_proven_and_one_held_key_is(self):
        with self.assertRaises(self.NotRun) as no:
            self.ext.step_smoke_hold_path(self._j(("echo d1", ["responder"] * 8), ("echo d2", ["responder"] * 8)),
                                          {"lines": ["echo d1", "echo d2"]})
        self.assertIn("hold path not proven", str(no.exception))
        done = self.ext.step_smoke_hold_path(self._j(("echo w1", ["app"] * 8), ("echo d1", ["app", "responder"]),
                                                     ("echo d2", ["responder"])), {"lines": ["echo d1", "echo d2"]})
        self.assertEqual((done["hold_path"], done["held_keys"]), (True, 1))  # w1's held keys do not count

    def test_the_second_cmd_d_and_each_d2_line_must_be_held_when_asked(self):
        j = self._j(("echo d1", ["app"] * 3), ("echo d2", ["app", "responder"]))
        j.spec = {"steps": [{"do": "key", "mark": "split1"}, {"do": "key", "mark": "split2"}]}
        j.steps = [{"index": 1, "result": {"reply": {"handled_by": "app"}}},
                   {"index": 2, "result": {"reply": {"handled_by": "window"}}}]
        want = {"lines": ["echo d2"], "every_line": True, "held_marks": ["split2"]}
        with self.assertRaises(self.NotRun) as no:  # the second Cmd-D went to the window: not the hold path
            self.ext.step_smoke_hold_path(j, want)
        self.assertIn("'split2' was not held (handled_by 'window'", str(no.exception))
        # "app" with a dispatcher trace: the router RAN the split at once (no creation pending): not a hold.
        j.steps[1]["result"]["reply"] = {"handled_by": "app", "trace": ["dispatcher: run(split.right)"]}
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_hold_path(j, want)
        j.steps[1]["result"]["reply"] = {"handled_by": "app", "trace": []}  # held: capture returned before dispatch
        done = self.ext.step_smoke_hold_path(j, want)
        self.assertEqual((done["hold_path"], done["marks"]["split2"]["held"]), (True, True))
        j.smoke_typed_paths[1]["paths"] = ["responder"]  # d2 not held: not proven
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_hold_path(j, want)

    def test_the_creation_hold_report_proves_the_hold_path_and_a_build_without_the_hook_is_not_run(self):
        calls = []

        class App:
            def __init__(self_, replies):
                self_.replies = replies

            def rpc(self_, method, params=None):
                calls.append((method, params))
                reply = self_.replies[method]
                if isinstance(reply, Exception):
                    raise reply
                return reply
        j = self._j(("echo d2", ["responder"]))
        j.app = App({"debug.creation.hold": {"armed": [1], "started": 0, "held": [], "released": []},
                     "debug.creation.release": {"armed": [1], "started": 2, "held": [], "released": [1]}})
        self.ext.step_smoke_creation(j, {"action": "hold", "n": 1})
        self.ext.step_smoke_creation(j, {"action": "release", "n": 1})
        self.assertEqual(calls, [("debug.creation.hold", {"n": 1}), ("debug.creation.release", {"n": 1})])
        done = self.ext.step_smoke_hold_path(j, {"lines": ["echo d2"], "creation_held": 1})
        self.assertTrue(done["creation_pending"])
        j.smoke_creation["release"] = {"started": 1, "held": [], "released": [1]}  # the second Cmd-D never started
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_hold_path(j, {"creation_held": 1})
        # A hook that reports `resumed`: creation 1 released but never waiting is not proven.
        j.smoke_creation["release"] = {"started": 2, "held": [], "released": [1], "resumed": []}
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_hold_path(j, {"creation_held": 1})
        j.smoke_creation["release"]["resumed"] = [1]
        self.assertTrue(self.ext.step_smoke_hold_path(j, {"creation_held": 1})["creation_pending"])
        j.app = App({"debug.creation.hold": self.ext.D.StepError("debug.creation.hold: method_not_found")})
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_creation(j, {"action": "hold", "n": 1})

    def test_the_wait_ends_when_the_new_panes_terminal_view_is_first_responder(self):
        seq = [{"windows": [{"id": "W", "is_key": True, "appkit": {"first_responder": "TerminalSurfaceView", "classified": "content:A"}}]},
               {"windows": [{"id": "W", "is_key": True, "appkit": {"first_responder": "NSView", "classified": "content:B"}}]},
               {"windows": [{"id": "W", "is_key": True, "appkit": {"first_responder": "TerminalSurfaceView", "classified": "content:B"}}]}]

        class App:
            def rpc(self_, method, params=None):
                return seq.pop(0) if len(seq) > 1 else seq[0]
        j = self._j()
        j.app, j.smoke_snapshots = App(), {"before_splits": {"focused_pane": "A"}}
        sleep, self.ext.time.sleep = self.ext.time.sleep, lambda s: None
        clock = iter(range(1000))
        now, self.ext.D.now = self.ext.D.now, staticmethod(lambda: next(clock) * 0.01)
        try:
            done = self.ext.step_smoke_wait_new_view(j, {"since": "before_splits", "timeout": 5})
        finally:
            self.ext.time.sleep, self.ext.D.now = sleep, now
        self.assertEqual((done["reached"], done["pane"]), (True, "B"))

    def test_the_stand_in_hold_needs_shown_and_a_dispatched_second_cmd_d(self):
        calls = []

        class App:
            def rpc(self_, method, params=None):
                calls.append((method, params))
                return {"debug.creation.hold": {"armed": [1], "stand_in": [2], "started": 0},
                        "debug.creation.release": {"started": 2, "released": [1], "resumed": [1], "shown": [2]}}[method]
        j = self._j(("echo d2", ["responder"]))
        j.app = App()
        j.spec = {"steps": [{"do": "key", "mark": "split2"}]}
        j.steps = [{"index": 1, "result": {"reply": {"handled_by": "app", "trace": ["dispatcher: run(splitRight)"]}}}]
        self.ext.step_smoke_creation(j, {"action": "hold", "n": [1], "stand_in": [2]})
        self.ext.step_smoke_creation(j, {"action": "release"})
        self.assertEqual(calls, [("debug.creation.hold", {"n": [1], "stand_in": [2]}), ("debug.creation.release", {})])
        want = {"creation_held": 1, "dispatched_marks": ["split2"]}
        self.assertTrue(self.ext.step_smoke_hold_path(j, want)["hold_path"])
        j.steps[0]["result"]["reply"]["trace"] = []  # the second Cmd-D was held, creation 2 never raced
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_hold_path(j, want)
        j.steps[0]["result"]["reply"]["trace"] = ["dispatcher: run(splitRight)"]
        j.smoke_creation["release"] = {"started": 2, "released": [1], "resumed": [1], "shown": []}  # stand-in not held
        with self.assertRaises(self.NotRun):
            self.ext.step_smoke_hold_path(j, want)

    def test_a_burst_without_a_hold_counter_is_not_proven(self):
        with self.assertRaises(self.NotRun) as no:
            self.ext.step_smoke_hold_path(self._j(burst=None), {})
        self.assertIn("no debug.input late_keys hold counter", str(no.exception))
        self.assertTrue(self.ext.step_smoke_hold_path(self._j(burst={"creation": 3}), {})["hold_path"])


class Loads(unittest.TestCase):
    def test_the_smoke_journey_and_its_steps_load(self):
        done = subprocess.run([sys.executable, str(HERE / "run.py"), "--check"], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        listed = subprocess.run([sys.executable, str(HERE / "run.py"), "--list"], capture_output=True, text=True, timeout=120)
        self.assertIn("smoke-dogfood", listed.stdout)


if __name__ == "__main__":
    unittest.main()
