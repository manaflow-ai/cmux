#!/usr/bin/env python3
"""Focused tests for the host-load launch-budget gate."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "launch_budget_gate", ROOT / "scripts/ci/launch_budget_gate.py"
)
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class LaunchBudgetGate(unittest.TestCase):
    def test_threshold_has_a_floor_and_scales_with_cpu_count(self):
        self.assertEqual(gate.threshold(None), 16)
        self.assertEqual(gate.threshold(4), 16)
        self.assertEqual(gate.threshold(15), 30)

    def test_known_high_load_skips_and_normal_load_runs(self):
        self.assertTrue(gate.should_skip(31, 15))
        self.assertFalse(gate.should_skip(30, 15))
        self.assertTrue(gate.should_skip(100, None))
        self.assertFalse(gate.should_skip(None, 15))

    def test_main_records_the_load_and_skip_decision(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory, "output")
            summary = Path(directory, "summary")
            with mock.patch.object(gate.os, "getloadavg", return_value=(35.0, 20.0, 10.0)), \
                    mock.patch.object(gate.os, "cpu_count", return_value=15):
                self.assertEqual(gate.main(["--output", str(output), "--summary", str(summary)]), 0)
            self.assertIn("skip=true", output.read_text())
            self.assertIn("load1=35.00", output.read_text())
            self.assertIn("threshold=30", output.read_text())
            self.assertIn("skipped launch-time budget", summary.read_text())


if __name__ == "__main__":
    unittest.main()
