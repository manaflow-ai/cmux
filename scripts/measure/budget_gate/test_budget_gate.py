"""The shared budget gate: a run starts as a fail, each stage it reaches is recorded, and only a judged run can
pass. A run killed mid-way leaves a gate.json naming the last stage it reached.

  python3 -m unittest scripts/measure/budget_gate/test_budget_gate.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHARED = HERE / "budget_gate.py"
SHIM = HERE.parent / "screen-stream-eval" / "budget_gate.py"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = _load("budget_gate_shared_under_test", SHARED)
shim = _load("screen_eval_budget_gate_shim_under_test", SHIM)

# The eval step's log as the cmux-ci client streams it (run 46111989381, cut).
LOG_LINES = [
    "cmux-ci: step c0840b8b0e40038086059817 (exclusive, key cmux31-glaeda-15-46111989381-1-9cdaab30e96e)",
    "cmux-ci: step c0840b8b0e40038086059817 still queued after 10 min (class exclusive); no worker has taken it yet",
    "cmux-ci: step c0840b8b0e40038086059817 still queued after 20 min (class exclusive); no worker has taken it yet",
    "ci-step source: 723495072 bytes over the LAN from the controller",
    'SCREEN-STREAM-EVAL-MACHINE {"host": "cmux18", "cpu": "Apple M6", "macos": "27.0"}',
    "some build noise that names no stage",
    "SCREEN-STREAM-EVAL-STAGE tools",
    "SCREEN-STREAM-EVAL-STAGE rd latency",
]


def results(encode=5.0):
    def part(p50):
        return {"n": 50, "p50": p50, "p95": p50 * 2}
    return {"schema": "cmux.screen-stream-eval/1", "run": {"link": "lan", "rev": "0123456789abcdef0123"}, "targets": {
        "rd": {"latency": {"key": {"p50_ms": 40.0}},
               "split": {"key": {"encode_ms": encode, "transport_ms": 6.0, "decode_ms": 2.0,
                                 "input_to_capture_parts": {"render_ms": part(9.0), "sck_ms": part(3.0),
                                                            "pickup_ms": part(1.0), "gate_ms": part(1.0),
                                                            "encode_ms": part(encode)}}}}}}


class SharedGateTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.dir = Path(folder.name)
        self.out = self.dir / "gate.json"

    def run_main(self, module, *argv):
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            code = module.main(list(argv))
        return code, printed.getvalue()

    def record(self):
        return json.loads(self.out.read_text())

    def test_init_writes_a_fail_by_default_record(self):
        code, _ = self.run_main(gate, "init", "--probe", "screen-share", "--out", str(self.out))
        self.assertEqual(code, 0)
        rec = self.record()
        self.assertEqual(rec["schema"], "cmux.screen-share-budget-gate/1")
        self.assertEqual((rec["verdict"], rec["stage"], rec["last_stage_reached"]), ("fail", "unknown", None))
        self.assertEqual((rec["rows"], rec["over"], rec["overrides"], rec["judged"]), ([], [], {}, False))
        self.assertIn("before it reached its first stage", rec["reason"])

    def test_init_keeps_budget_overrides_so_a_proof_run_is_never_the_nightly(self):
        self.run_main(gate, "init", "--probe", "screen-share", "--out", str(self.out), "--budget", "encode=0.1")
        self.assertEqual(self.record()["overrides"], {"Encode": 0.1})

    def test_mark_stage_records_the_last_stage_and_stays_a_fail(self):
        self.run_main(gate, "init", "--probe", "screen-share", "--out", str(self.out))
        self.run_main(gate, "mark-stage", "eval stage tools", "--probe", "screen-share", "--out", str(self.out))
        self.run_main(gate, "mark-stage", "eval stage rd latency", "--probe", "screen-share", "--out", str(self.out))
        rec = self.record()
        self.assertEqual(rec["verdict"], "fail")
        self.assertEqual(rec["last_stage_reached"], "eval stage rd latency")
        self.assertIn("'eval stage rd latency'", rec["reason"])
        self.assertEqual([p["stage"] for p in rec["progress"]], ["eval stage tools", "eval stage rd latency"])

    def test_mark_stage_without_init_still_writes_a_fail(self):
        self.run_main(gate, "mark-stage", "eval stage tools", "--probe", "screen-share", "--out", str(self.out))
        self.assertEqual((self.record()["verdict"], self.record()["last_stage_reached"]), ("fail", "eval stage tools"))

    def test_follow_names_each_marker_and_folds_the_queue_wait(self):
        log = self.dir / "eval.log"
        log.write_text("\n".join(LOG_LINES) + "\n")
        self.run_main(gate, "init", "--probe", "screen-share", "--out", str(self.out))
        self.run_main(gate, "follow", str(log), "--probe", "screen-share", "--out", str(self.out), "--once")
        stages = [p["stage"] for p in self.record()["progress"]]
        self.assertEqual(stages, ["submitted to the fleet (step c0840b8b0e40038086059817)", "queued in the fleet 20 min",
                                  "taken by a worker (source fetched)", "eval started on cmux18", "eval stage tools",
                                  "eval stage rd latency"])
        self.assertEqual(self.record()["last_stage_reached"], "eval stage rd latency")

    def test_a_killed_follower_leaves_the_last_stage_reached(self):
        log = self.dir / "eval.log"
        log.write_text("")
        self.run_main(gate, "init", "--probe", "screen-share", "--out", str(self.out))
        proc = subprocess.Popen([sys.executable, "-I", str(SHARED), "follow", str(log), "--probe", "screen-share",
                                 "--out", str(self.out)])
        try:
            with log.open("a") as f:
                for line in LOG_LINES[:7]:
                    f.write(line + "\n")
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and self.record().get("last_stage_reached") != "eval stage tools":
                time.sleep(0.2)
        finally:
            proc.send_signal(signal.SIGKILL)
            proc.wait(10)
        rec = self.record()
        self.assertEqual((rec["verdict"], rec["last_stage_reached"]), ("fail", "eval stage tools"))

    def test_check_overwrites_with_a_pass_and_keeps_the_progress(self):
        source = self.dir / "results.json"
        source.write_text(json.dumps(results()))
        self.run_main(gate, "init", "--probe", "screen-share", "--out", str(self.out))
        self.run_main(gate, "mark-stage", "eval stage rd latency", "--probe", "screen-share", "--out", str(self.out))
        code, _ = self.run_main(gate, "check", str(source), "--probe", "screen-share", "--out", str(self.out))
        rec = self.record()
        self.assertEqual(code, 0)
        self.assertEqual((rec["verdict"], rec["stage"], rec["judged"]), ("pass", None, True))
        self.assertEqual(rec["progress"][-1]["stage"], "eval stage rd latency")
        self.assertIsNone(rec["suspect"])

    def test_check_over_budget_fails_naming_the_stage_and_the_suspect(self):
        source = self.dir / "results.json"
        source.write_text(json.dumps(results(encode=20.0)))
        code, printed = self.run_main(gate, "check", str(source), "--probe", "screen-share", "--out", str(self.out))
        rec = self.record()
        self.assertEqual(code, 1)
        self.assertEqual((rec["verdict"], rec["stage"], rec["over"]), ("fail", "Encode", ["Encode"]))
        self.assertEqual(rec["suspect"]["sha"], "0123456789abcdef0123")
        self.assertIn("::error title=screen share budget: Encode::", printed)

    def test_marks_after_check_never_reopen_a_judged_record(self):
        source = self.dir / "results.json"
        source.write_text(json.dumps(results()))
        self.run_main(gate, "check", str(source), "--probe", "screen-share", "--out", str(self.out))
        self.run_main(gate, "mark-stage", "late line", "--probe", "screen-share", "--out", str(self.out))
        self.assertEqual(self.record()["verdict"], "pass")

    def test_nothing_judged_still_writes_a_fail(self):
        source = self.dir / "results.json"
        source.write_text(json.dumps({"schema": "cmux.screen-stream-eval/1", "targets": {}}))
        self.run_main(gate, "init", "--probe", "screen-share", "--out", str(self.out))
        self.run_main(gate, "mark-stage", "fleet step exited 5", "--probe", "screen-share", "--out", str(self.out))
        code, _ = self.run_main(gate, "check", str(source), "--probe", "screen-share", "--out", str(self.out))
        rec = self.record()
        self.assertEqual(code, 2)
        self.assertEqual((rec["verdict"], rec["stage"], rec["last_stage_reached"]),
                         ("fail", "nothing judged", "fleet step exited 5"))

    def test_an_unknown_probe_is_refused_by_name(self):
        with self.assertRaises(SystemExit) as raised:
            gate.load_probe("tabs-keep-speed-not-yet")
        self.assertIn("screen-share", str(raised.exception))


class ShimTests(unittest.TestCase):
    """The old path keeps its CLI (check, exit codes, schema) and gains init and mark-stage."""

    def test_old_path_runs_init_check_with_the_screen_share_probe(self):
        with tempfile.TemporaryDirectory() as folder:
            out, source = Path(folder) / "gate.json", Path(folder) / "results.json"
            source.write_text(json.dumps(results(encode=20.0)))
            for argv in (["init", "--out", str(out)], ["mark-stage", "eval stage tools", "--out", str(out)]):
                self.assertEqual(subprocess.run([sys.executable, "-I", str(SHIM), *argv]).returncode, 0)
            self.assertEqual(json.loads(out.read_text())["last_stage_reached"], "eval stage tools")
            done = subprocess.run([sys.executable, "-I", str(SHIM), "check", str(source), "--out", str(out)],
                                  capture_output=True, text=True)
            self.assertEqual(done.returncode, 1)
            rec = json.loads(out.read_text())
            self.assertEqual((rec["schema"], rec["over"], rec["stage"]),
                             ("cmux.screen-share-budget-gate/1", ["Encode"], "Encode"))

    def test_shim_reexports_the_old_names(self):
        self.assertEqual(shim.BUDGETS["Total"], 57)
        self.assertEqual(shim.RESULTS_SCHEMA, "cmux.screen-stream-eval/1")
        self.assertEqual(shim.parse_overrides(["encode=1"]), {"Encode": 1.0})


if __name__ == "__main__":
    unittest.main()
