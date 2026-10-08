#!/usr/bin/env python3
"""Routing tests for the optional reverse test impact report."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import reverse_test_impact_route as route  # noqa: E402


class ReverseTestImpactRouteTests(unittest.TestCase):
    def test_known_non_app_diff_skips_the_report(self) -> None:
        self.assertFalse(route.should_report(["docs/ci.md", ".github/workflows/ci.yml"]))

    def test_app_source_diff_runs_the_report(self) -> None:
        self.assertTrue(route.should_report(["Sources/App.swift"]))
        self.assertTrue(route.should_report(["Packages/macOS/Shared/Sources/Thing.swift"]))

    def test_known_empty_diff_skips_the_report(self) -> None:
        self.assertFalse(route.should_report([]))

    def test_unreadable_diff_runs_the_report(self) -> None:
        self.assertTrue(route.should_report(None))

    def test_workflow_uses_the_route_output_and_keeps_inner_defense(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
        changes = workflow["jobs"]["changes"]
        self.assertEqual(
            changes["outputs"]["reverse_test_impact"],
            "${{ steps.reverse-impact.outputs.reverse_test_impact }}",
        )
        route_step = next(step for step in changes["steps"] if step.get("id") == "reverse-impact")
        self.assertIn("reverse_test_impact=true", route_step["run"])

        report = workflow["jobs"]["reverse-test-impact"]
        self.assertIn("needs.changes.outputs.reverse_test_impact == 'true'", report["if"])
        report_script = next(step["run"] for step in report["steps"] if step.get("name") == "Report reverse test impact (report only)")
        self.assertIn("No app source changes; nothing to report.", report_script)


if __name__ == "__main__":
    unittest.main()
