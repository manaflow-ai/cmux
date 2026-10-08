#!/usr/bin/env python3
"""Routing tests for the optional reverse test impact report."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
