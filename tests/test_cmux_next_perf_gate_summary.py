#!/usr/bin/env python3
"""Manual perf-gate reporting regressions; no app, display, or CI job is required.

Run with the existing unlit-window tests:
    python3 -m unittest discover -s tests -p 'test_cmux_next_perf_gate*.py'
"""
import contextlib
import io
import json
import os
import tempfile
import types
import unittest
from unittest.mock import patch

from test_cmux_next_perf_gate_unlit import FakeApp, perf_gate


class FrameSummaryTests(unittest.TestCase):
    def setUp(self):
        del perf_gate.failures[:], perf_gate.warnings[:]
        perf_gate.report.clear()
        perf_gate.report.update({"checks": [], "phases": {}})

    def gate(self, lit, frames="auto"):
        gate = perf_gate.Gate(FakeApp(lit), types.SimpleNamespace(frames=frames, only=None))
        gate.grid = (16, 48)
        return gate

    def run_timed(self, gate):
        gate.tabs()
        gate.new_workspaces()

    def write_report(self):
        with tempfile.TemporaryDirectory() as directory:
            report_path = os.path.join(directory, "report.json")
            summary_path = os.path.join(directory, "summary.md")
            stdout = io.StringIO()
            with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": summary_path}), contextlib.redirect_stdout(stdout):
                perf_gate.write_report(report_path)
            with open(report_path) as handle:
                result = json.load(handle)
            with open(summary_path) as handle:
                summary = handle.read()
        self.assertEqual(stdout.getvalue(), summary + "\n")
        return result, summary

    def test_auto_summary_names_skipped_scenarios_once_beside_pass(self):
        gate = self.gate(lit=False)
        self.run_timed(gate)
        gate.frames_ok("tabs")
        result, summary = self.write_report()
        self.assertTrue(result["ok"])
        self.assertIn("PASS (frames skipped: new_workspaces, tabs):", summary)
        self.assertEqual(result.get("frames_skipped"), ["new_workspaces", "tabs"])

    def test_required_summary_names_unmeasured_scenarios_beside_failure(self):
        self.run_timed(self.gate(lit=False, frames="required"))
        result, summary = self.write_report()
        self.assertFalse(result["ok"])
        self.assertIn("FAIL (frames skipped: new_workspaces, tabs):", summary)
        self.assertEqual(result.get("frames_skipped"), ["new_workspaces", "tabs"])

    def test_frame_summary_lists_only_scenarios_that_skipped(self):
        gate = self.gate(lit=False)
        for scenario in ("theme", "drag", "pane_focus", "drag"):
            gate.frames_ok(scenario)
        _, summary = self.write_report()
        self.assertIn("PASS (frames skipped: drag, pane_focus, theme):", summary)

    def test_lit_summary_does_not_claim_frames_were_skipped(self):
        self.assertTrue(self.gate(lit=True).frames_ok("tabs"))
        _, summary = self.write_report()
        self.assertIn("PASS:", summary)
        self.assertNotIn("frames skipped", summary)

    def test_source_only_summary_does_not_claim_frame_coverage(self):
        _, summary = self.write_report()
        self.assertIn("PASS:", summary)
        self.assertNotIn("frames", summary)


if __name__ == "__main__":
    unittest.main()
