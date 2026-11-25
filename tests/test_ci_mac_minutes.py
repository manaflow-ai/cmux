#!/usr/bin/env python3
"""Timing inventory must preserve unknowns and count retries, not duplicate pages."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("minutes", Path(__file__).resolve().parents[1] / "scripts/measure/ci-mac-minutes.py")
minutes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(minutes)


class MinutesTests(unittest.TestCase):
    def test_pages_attempts_window_and_partial_steps(self):
        row = {"id": 1, "repo": "manaflow-ai/cmux", "attempt": 1,
               "at": "2026-11-25T00:00:00Z", "runner": "mini", "seconds": 120,
               "workflow_path": "ffi.yml", "job": "build",
               "steps": [{"n": "portable tests", "s": 30}, {"n": "native build", "s": 90}]}
        start = 1795564800
        report = minutes.summarize([row, row, dict(row, attempt=2),
                                   dict(row, id=2, at="2026-11-26T00:00:00Z")], start, start + 86400)
        self.assertEqual(report["unique_records"], 2)
        self.assertEqual(report["duplicate_records"], 1)
        self.assertEqual(report["outside_window"], 1)
        self.assertEqual(report["coverage"], "unknown")
        group = report["inventory"][0]
        self.assertEqual(group["minutes"], 4)
        self.assertEqual(group["steps"]["portable tests"]["seconds"], 60)

    def test_unknown_is_not_linux_or_measured_zero(self):
        row = {"id": 1, "repo": "manaflow-ai/cmux", "at": "2026-11-25T00:00:00Z",
               "runner": "other", "seconds": None, "steps": [{"n": "x", "s": None}]}
        group = minutes.summarize([row], 1795564800, 1795651200)["inventory"][0]
        self.assertEqual(group["os"], "unknown")
        self.assertEqual(group["untimed_jobs"], 1)
        self.assertEqual(group["steps"]["x"]["untimed"], 1)
        self.assertIsNone(minutes.duration(float("nan")))
        self.assertIsNone(minutes.duration(-1))


if __name__ == "__main__":
    unittest.main()
