#!/usr/bin/env python3
"""The dogfood smoke gate's verdict rules, with a stand-in for run.py: no fleet, no app.

    python3 scripts/journeys/test_smoke_gate.py

PASS (and the .pass file) only when every round passes; FAIL when one round failed; NOT JUDGED when no round
failed but one did not run, a known gap included; never a .pass file from a gate with uncommitted changes.
Also: the smoke journey and its step group load in the driver (`run.py --check`).
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
row = {"id": "smoke-dogfood", "status": status, "reason": "", "host": "cmux99"}
if status == "gap":
    row["status"], row["reason"] = "not run", "known gap: the capture slot could not make the window key"
if status == "fail":
    json.dump({"steps": [{"do": "smoke_type_now", "ok": False, "error": "keys lost"}]},
              open(os.path.join(out, "smoke-dogfood", "result.json"), "w"))
open(os.path.join(out, "results.jsonl"), "w").write(json.dumps(row) + "\n")
print("leased slot-cmux99-abc")
'''


def gate(plan, tmp, extra=()):
    runner = os.path.join(tmp, "fake_run.py")
    with open(runner, "w") as f:
        f.write(FAKE)
    env = {**os.environ, "SMOKE_PLAN": json.dumps(plan)}
    done = subprocess.run([sys.executable, str(GATE), "--build", "job123", "--rounds", str(len(plan)), "--runner", runner,
                           "--out", os.path.join(tmp, "out"), "--handoff", os.path.join(tmp, "handoff"), *extra],
                          capture_output=True, text=True, env=env, timeout=120)
    with open(os.path.join(tmp, "out", "summary.json")) as f:
        return done.returncode, json.load(f)


class Verdicts(unittest.TestCase):
    def test_pass_needs_every_round_and_a_committed_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, summary = gate(["pass"] * 3, tmp)
            self.assertEqual(summary["verdict"], "PASS")
            self.assertEqual(summary["rounds_detail"][0]["leases"], ["slot-cmux99-abc"])
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


class Loads(unittest.TestCase):
    def test_the_smoke_journey_and_its_steps_load(self):
        done = subprocess.run([sys.executable, str(HERE / "run.py"), "--check"], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        listed = subprocess.run([sys.executable, str(HERE / "run.py"), "--list"], capture_output=True, text=True, timeout=120)
        self.assertIn("smoke-dogfood", listed.stdout)


if __name__ == "__main__":
    unittest.main()
