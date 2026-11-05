#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("workspace_scaling", ROOT / "scripts/cmux-next/workspace-scaling-bench.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class WorkspaceScalingTests(unittest.TestCase):
    def test_percentiles_include_p99(self):
        result = bench.stats([1, 2, 3, 4, 5])
        self.assertEqual(result["p50"], 3.0)
        self.assertEqual(result["p95"], 4.8)
        self.assertEqual(result["p99"], 4.96)

    def test_warning_is_advisory_above_ten_percent(self):
        rows = [{"interaction": "sidebar_scroll", "workspaces": 100, "p95": 10},
                {"interaction": "sidebar_scroll", "workspaces": 1000, "p95": 11.1}]
        warning = bench.scaling_warnings(rows)
        self.assertEqual(len(warning), 1)
        self.assertEqual(warning[0]["baseline_workspaces"], 100)
        self.assertEqual(warning[0]["ratio"], 1.11)

    def test_flat_ratio_has_no_warning(self):
        rows = [{"interaction": "type", "workspaces": 1, "p95": 10},
                {"interaction": "type", "workspaces": 1000, "p95": 11}]
        self.assertEqual(bench.scaling_warnings(rows), [])

    def test_incomplete_probe_does_not_publish_rows(self):
        rows = bench.collect({1: {"invalid_probes": ["typing"], "typing": {"phases": []}}})
        self.assertFalse(any(row["interaction"] == "type" for row in rows))

    def test_switch_uses_real_two_row_baseline(self):
        rows = [{"interaction": "switch", "workspaces": 100, "p95": 10},
                {"interaction": "switch", "workspaces": 1000, "p95": 11.1}]
        warning = bench.scaling_warnings(rows)
        self.assertEqual(warning[0]["baseline_workspaces"], 100)

    def test_sidebar_rows_reject_incomplete_frame_capture(self):
        report = {"sizes": {"100": {"scroll": {"frames": {
            "intervals_ms": [8.3], "frame_metrics": {"complete": False}}}}}}
        self.assertNotIn("sidebar_scroll", bench.sidebar_rows(report, 100))

    def test_single_workspace_switch_is_explicitly_undefined(self):
        rows = bench.collect({1: {"instant": {}, "sidebar": {}, "typing": {}}})
        switch = next(row for row in rows if row["interaction"] == "switch")
        self.assertEqual(switch["status"], "undefined")
        self.assertIsNone(switch["p95"])

    def test_empty_report_replay_is_incomplete(self):
        failures = bench.coverage_failures(bench.collect({1: {}, 100: {}, 1000: {}}))
        self.assertEqual([failure["workspaces"] for failure in failures], [1, 100, 1000])
        self.assertIn("new_workspace", failures[0]["missing"])

    def test_one_workspace_sidebar_is_undefined_without_probe_rows(self):
        rows = bench.collect({1: {"instant": {}, "typing": {}, "sidebar": {}}})
        sidebar = {row["interaction"]: row for row in rows if row["workspaces"] == 1}
        self.assertEqual(sidebar["sidebar_scroll"]["status"], "undefined")
        self.assertEqual(sidebar["switch"]["status"], "undefined")

    def test_non_object_probe_report_is_treated_as_missing(self):
        rows = bench.collect({1: {"instant": [], "sidebar": "bad", "typing": 3}})
        failures = bench.coverage_failures(rows)
        self.assertTrue(any(failure["workspaces"] == 1 for failure in failures))

    def test_malformed_nested_report_is_treated_as_missing(self):
        rows = bench.collect({1: {"instant": {"summary": "bad"},
                                  "sidebar": {"sizes": []},
                                  "typing": {"phases": ["bad"]}}})
        failures = bench.coverage_failures(rows)
        self.assertTrue(any(failure["workspaces"] == 1 for failure in failures))

    def test_raw_sidebar_report_replays_bootstrap_offset(self):
        report = {"sizes": {"99": {"scroll": {"frames": {
            "intervals_ms": [8.3], "frame_metrics": {"complete": True}},
            "switch": {"frames": {"frame_metrics": {"complete": True}},
                       "click_to_idle_ms": {"p50": 8, "p95": 9, "p99": 9}}}}}}
        rows = bench.collect({100: {"sidebar": report}})
        self.assertEqual({row["interaction"] for row in rows}, {"sidebar_scroll", "switch"})


if __name__ == "__main__":
    unittest.main()
