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
        rows = [{"interaction": "sidebar_scroll", "workspaces": 1, "p95": 10},
                {"interaction": "sidebar_scroll", "workspaces": 1000, "p95": 11.1}]
        warning = bench.scaling_warnings(rows)
        self.assertEqual(len(warning), 1)
        self.assertEqual(warning[0]["ratio"], 1.11)

    def test_flat_ratio_has_no_warning(self):
        rows = [{"interaction": "type", "workspaces": 1, "p95": 10},
                {"interaction": "type", "workspaces": 1000, "p95": 11}]
        self.assertEqual(bench.scaling_warnings(rows), [])

    def test_single_workspace_switch_is_explicitly_undefined(self):
        rows = bench.collect({1: {"instant": {}, "sidebar": {}, "typing": {}}})
        switch = next(row for row in rows if row["interaction"] == "switch")
        self.assertEqual(switch["status"], "undefined")
        self.assertIsNone(switch["p95"])


if __name__ == "__main__":
    unittest.main()
