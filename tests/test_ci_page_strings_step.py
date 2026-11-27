#!/usr/bin/env python3
"""The page-strings step of ci/steps.toml routes on the pull request that edits a catalog or a setting.

Leo, 2026-11-25: "making sure that like these asynchronous things, like they don't randomly wait each other
forever and deadlock ... compile breaks and like things not publishing in time".

#55301 (2026-11-26) edited a settings source and its catalog with English-only strings; the strict generation ran
only in cmux-next-guards.yml static-checks, which a feat-cmux-next pull request skips, so the push's Release compile
was red on every later commit and no nightly promoted for 3 h. #51725 did the same on 11-23. This holds that the
step routes on those pull requests' files and stays off a change that cannot alter a page's strings.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ci_steps  # noqa: E402

PR_55301 = [
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/AgentPaneSettings.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings",
]
PR_51725 = [
    "schemas/settings/source/agent-defaults.json",
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings",
]


class PageStringsStepTest(unittest.TestCase):
    def setUp(self) -> None:
        self.table = ci_steps.load()
        self.assertIn("page-strings", self.table.steps)

    def routed(self, paths: list[str]) -> bool:
        return "page-strings" in ci_steps.route(self.table, paths, pr_scope=True).get("linux", [])

    def test_the_pull_requests_that_broke_base_route_it(self) -> None:
        self.assertTrue(self.routed(PR_55301))
        self.assertTrue(self.routed(PR_51725))

    def test_a_catalog_anywhere_routes_it(self) -> None:
        self.assertTrue(self.routed(["webviews/src/shared/Localizable.xcstrings"]))
        self.assertTrue(self.routed(["Packages/macOS/CmuxNext/Sources/CmuxNextAgents/Localizable.xcstrings"]))
        self.assertTrue(self.routed(["webviews/scripts/pages/gen-strings.mjs"]))

    def test_a_change_that_cannot_alter_strings_does_not(self) -> None:
        self.assertFalse(self.routed(["webviews/src/agent-session/acpmux/VirtualTranscript.tsx"]))
        self.assertFalse(self.routed(["docs/ci/landing.md"]))

    def test_it_blocks_and_runs_alone_with_node(self) -> None:
        step = self.table.steps["page-strings"]
        self.assertTrue(step.blocks)
        self.assertTrue(step.alone)
        self.assertIn("node", step.needs)


if __name__ == "__main__":
    unittest.main()
