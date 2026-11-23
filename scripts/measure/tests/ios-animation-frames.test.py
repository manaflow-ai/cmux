#!/usr/bin/env python3
"""Exercise 120 Hz CPU budgets and heavy replay evidence without a simulator."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ios_animation_frames import measure, read_run


def sample(label="composer-typing", cpu_ms=1.0, drops=0):
    return {"label": label, "frames": 20, "expectedMs": 1000 / 60, "displayMaximumHz": 60,
            "p50Ms": 16.67, "p95Ms": 16.67, "maxMs": 33.34, "droppedFrames": drops,
            "mainThreadCPUPerFrameMs": [cpu_ms] * 20}


class FrameBudgetTests(unittest.TestCase):
    def test_cpu_and_drops_gate_independently_on_a_60_hz_simulator(self):
        self.assertFalse(measure(sample(cpu_ms=8.33, drops=2))["failures"])
        self.assertTrue(measure(sample(cpu_ms=8.34))["failures"])
        self.assertTrue(measure(sample(drops=3))["failures"])

    def test_heavy_evidence_requires_the_window_that_checks_replay(self):
        with tempfile.TemporaryDirectory() as folder:
            evidence = Path(folder)
            path = evidence / "ui-duress-heavy-framelog.jsonl"
            path.write_text(json.dumps(sample()) + "\n")
            self.assertTrue(read_run(evidence, "heavy")[1])
            path.write_text(json.dumps(sample("composer-typing-heavy")) + "\n")
            rows, errors = read_run(evidence, "heavy")
            self.assertEqual(errors, [])
            self.assertEqual((rows[0]["animation"], rows[0]["profile"]), ("composer-typing", "heavy"))


if __name__ == "__main__":
    unittest.main()
