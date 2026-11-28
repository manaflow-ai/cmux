"""The screen share budget gate in PR CI: an over-budget run fails naming the stage, a clean run passes,
and a run cut before its judgement stays the fail-by-default record naming the last stage it reached.
It runs scripts/measure/budget_gate/budget_gate.py (the shared runner, screen-share probe) and the
old-path shim scripts/measure/screen-stream-eval/budget_gate.py, which .github/workflows/screen-stream-eval.yml calls.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "scripts/measure/budget_gate/budget_gate.py"
SHIM = ROOT / "scripts/measure/screen-stream-eval/budget_gate.py"


def results(encode_ms: float) -> dict:
    def part(p50):
        return {"n": 50, "p50": p50, "p95": p50 * 2}
    split = {"encode_ms": encode_ms, "transport_ms": 6.0, "decode_ms": 2.0,
             "input_to_capture_parts": {"render_ms": part(9.0), "sck_ms": part(3.0), "pickup_ms": part(1.0),
                                        "gate_ms": part(1.0), "encode_ms": part(encode_ms)}}
    return {"schema": "cmux.screen-stream-eval/1", "run": {"link": "lan", "rev": "0123456789abcdef0123"},
            "targets": {"rd": {"latency": {"key": {"p50_ms": 40.0}}, "split": {"key": split}}}}


class ScreenShareBudgetGateTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.dir = Path(folder.name)
        self.out = self.dir / "gate.json"

    def gate(self, script: Path, *argv: str) -> int:
        probe = ["--probe", "screen-share"] if script == SHARED else []  # the shim's probe is fixed
        return subprocess.run([sys.executable, "-I", str(script), *argv, *probe, "--out", str(self.out)],
                              capture_output=True, text=True, timeout=60).returncode

    def record(self) -> dict:
        return json.loads(self.out.read_text())

    def judge(self, script: Path, encode_ms: float) -> int:
        source = self.dir / "results.json"
        source.write_text(json.dumps(results(encode_ms)))
        self.assertEqual(self.gate(script, "init"), 0)
        self.assertEqual(self.gate(script, "mark-stage", "eval stage rd latency"), 0)
        return self.gate(script, "check", str(source))

    def test_over_budget_fails_naming_the_stage(self):
        for script in (SHARED, SHIM):
            with self.subTest(script=script.name, path=str(script.parent.name)):
                self.assertEqual(self.judge(script, encode_ms=20.0), 1)
                rec = self.record()
                self.assertEqual((rec["verdict"], rec["stage"], rec["over"]), ("fail", "Encode", ["Encode"]))
                self.assertEqual(rec["schema"], "cmux.screen-share-budget-gate/1")
                self.assertEqual(rec["suspect"]["sha"], "0123456789abcdef0123")

    def test_clean_passes(self):
        self.assertEqual(self.judge(SHIM, encode_ms=5.0), 0)
        self.assertEqual((self.record()["verdict"], self.record()["over"]), ("pass", []))

    def test_cut_before_judgement_is_a_fail_naming_the_last_stage(self):
        self.assertEqual(self.gate(SHIM, "init"), 0)
        self.assertEqual(self.gate(SHIM, "mark-stage", "eval started on cmux18"), 0)
        rec = self.record()
        self.assertEqual((rec["verdict"], rec["stage"], rec["last_stage_reached"]),
                         ("fail", "unknown", "eval started on cmux18"))


if __name__ == "__main__":
    unittest.main()
