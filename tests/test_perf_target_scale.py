#!/usr/bin/env python3
"""Behavior-level tests for the target-scale benchmark contract.

These tests deliberately run on Linux/CI too.  macOS command parsing is fed
fixture text, while the four acceptance faults are injected through the pure
budget evaluator.  No test launches cmux or charges child RSS to app budgets.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import perf_target_scale as runner  # noqa: E402
import perf_target_scale_metrics as metrics  # noqa: E402


class TargetScaleMetricsTests(unittest.TestCase):
    def test_size_parser_accepts_macos_units(self) -> None:
        self.assertEqual(metrics.parse_size("1K"), 1024)
        self.assertEqual(metrics.parse_size("1.5 MB"), int(1.5 * metrics.BYTES_PER_MIB))
        self.assertEqual(metrics.parse_size("12,345"), 12345)

    def test_footprint_parser_keeps_gpu_categories_separate(self) -> None:
        parsed = metrics.parse_footprint_output(
            """
            Physical footprint: 500.0M
            Peak physical footprint: 512.0M
            Dirty Graphics: 120.0M
            IOSurface: 40.0M
            IOAccelerator: 12.0M
            """
        )
        self.assertEqual(parsed["phys_footprint_bytes"], 500 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["phys_footprint_peak_bytes"], 512 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["dirty_graphics_bytes"], 120 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["iosurface_bytes"], 40 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["ioaccelerator_bytes"], 12 * metrics.BYTES_PER_MIB)

    def test_footprint_parser_reads_dirty_before_table_category(self) -> None:
        parsed = metrics.parse_footprint_output(
            """
             53 MB        0 B        0 B         27    IOSurface
             39 MB        0 B      9152 KB      164    IOAccelerator (graphics)
             11 MB        0 B        0 B          4    Owned physical footprint (unmapped) (graphics)
            Auxiliary data:
                phys_footprint: 110 MB
                phys_footprint_peak: 120 MB
            """
        )
        self.assertEqual(parsed["phys_footprint_bytes"], 110 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["phys_footprint_peak_bytes"], 120 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["iosurface_bytes"], 53 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["ioaccelerator_bytes"], 39 * metrics.BYTES_PER_MIB)
        self.assertEqual(parsed["dirty_graphics_bytes"], 50 * metrics.BYTES_PER_MIB)

    def test_thread_roles_are_stable(self) -> None:
        listing = """\
tid thcomm
1 Main Thread
2 CVDisplayLink
3 Ghostty renderer
4 pty-io
5 dispatch-worker
"""
        parsed = metrics.parse_thread_listing(listing)
        self.assertEqual(parsed["total"], 5)
        self.assertEqual(parsed["roles"]["main"], 1)
        self.assertEqual(parsed["roles"]["display_link"], 1)
        self.assertEqual(parsed["roles"]["renderer"], 1)
        self.assertEqual(parsed["roles"]["pty_io"], 1)
        self.assertEqual(parsed["roles"]["dispatch"], 1)

    def test_balanced_layout_has_exact_visible_panes(self) -> None:
        def leaves(node: dict) -> list[dict]:
            if "pane" in node:
                return [node]
            result: list[dict] = []
            for child in node["children"]:
                result.extend(leaves(child))
            return result

        self.assertEqual(len(leaves(metrics.balanced_layout(5))), 5)
        self.assertEqual(len(leaves(metrics.balanced_layout(1))), 1)

    def test_healthy_series_passes_and_child_workload_is_excluded(self) -> None:
        runs = [metrics.synthetic_run(size) for size in metrics.FIXTURE_SIZES]
        result = metrics.evaluate_series(runs)
        self.assertTrue(result["passed"], result)
        # synthetic_run intentionally carries a huge child RSS value.  It must
        # not become an app-footprint failure.
        self.assertFalse(any(failure["code"] == "child_workload" for failure in result["failures"]))

    def test_each_acceptance_fault_fails_the_expected_budget(self) -> None:
        expected = {
            "hidden-renderer": "gpu_hidden_slope",
            "hidden-wakeup": "cpu_hidden_slope",
            "retained-allocation": "soak_footprint",
            "display-link": "display_link_model",
        }
        for fault, code in expected.items():
            with self.subTest(fault=fault):
                result = metrics.evaluate_series([metrics.synthetic_run(size, fault) for size in metrics.FIXTURE_SIZES])
                self.assertIn(code, {failure["code"] for failure in result["failures"]})

    def test_artifact_is_machine_readable_and_declares_contract(self) -> None:
        artifact = metrics.make_artifact(
            [metrics.synthetic_run(size) for size in metrics.FIXTURE_SIZES],
            metadata={"app_version": "synthetic", "hardware": {"model": "test"}},
        )
        encoded = json.dumps(artifact)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["schema_version"], metrics.SCHEMA_VERSION)
        self.assertEqual(decoded["fixture_contract"]["sizes"], list(metrics.FIXTURE_SIZES))
        self.assertFalse(decoded["fixture_contract"]["child_workload_charged_to_app"])
        self.assertEqual(len(decoded["runs"]), 4)

    def test_short_cpu_sample_is_rejected(self) -> None:
        run = metrics.synthetic_run(200)
        run["cpu"]["duration_seconds"] = metrics.MIN_CPU_SECONDS - 1
        codes = {failure["code"] for failure in metrics.evaluate_run(run)}
        self.assertIn("cpu_duration", codes)

    def test_missing_app_footprint_is_rejected(self) -> None:
        run = metrics.synthetic_run(10)
        run["first_settled"]["phys_footprint_bytes"] = None
        run["first_settled"]["phys_footprint_peak_bytes"] = None
        codes = {failure["code"] for failure in metrics.evaluate_run(run)}
        self.assertIn("app_footprint_unavailable", codes)

    def test_artifact_preserves_requested_cycle_count(self) -> None:
        artifact = metrics.make_artifact(
            [metrics.synthetic_run(1)],
            metadata={"app_version": "synthetic"},
            reveal_hide_cycles=7,
        )
        self.assertEqual(artifact["fixture_contract"]["reveal_hide_cycles"], 7)


class TargetScaleCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.output_dir = Path(self._tmp.name)

    def test_self_test_cli_passes(self) -> None:
        self.assertEqual(runner.main(["--self-test", "--output", str(self.output_dir / "self-test.json")]), 0)

    def test_real_run_requires_tag(self) -> None:
        self.assertEqual(
            runner.main(
                [
                    "--sizes",
                    "1",
                    "--cpu-seconds",
                    "30",
                    "--output",
                    str(self.output_dir / "missing-tag.json"),
                ]
            ),
            2,
        )


class TargetScaleArtifactTests(unittest.TestCase):
    def test_junit_emits_one_case_per_budget_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "target-scale.junit.xml"
            runner._write_junit(
                output,
                {
                    "evaluation": {
                        "failures": [
                            {"code": "cpu_hidden_slope", "message": "CPU slope exceeded"},
                            {"code": "soak_footprint", "message": "footprint grew"},
                        ]
                    }
                },
            )
            suite = ET.parse(output).getroot()

        self.assertEqual(suite.attrib["tests"], "2")
        self.assertEqual(suite.attrib["failures"], "2")
        cases = suite.findall("testcase")
        self.assertEqual([case.attrib["name"] for case in cases], ["cpu_hidden_slope_0", "soak_footprint_1"])
        self.assertEqual(
            [case.find("failure").attrib["type"] for case in cases],
            ["cpu_hidden_slope", "soak_footprint"],
        )

    def test_junit_emits_a_passing_case_when_no_budget_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "target-scale.junit.xml"
            runner._write_junit(output, {"evaluation": {"failures": []}})
            suite = ET.parse(output).getroot()

        self.assertEqual(suite.attrib["tests"], "1")
        self.assertEqual(suite.attrib["failures"], "0")
        self.assertEqual(len(suite.findall("testcase")), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
