#!/usr/bin/env python3
"""Focused tests for the warning-only familiar-intent checker."""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "intent_familiar_warning", ROOT / "scripts/ci/intent_familiar_warning.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def patch(text: str) -> list[dict[str, str]]:
    return [{"filename": "Packages/macOS/CmuxNext/Sources/Chrome.swift", "patch": text}]


class FamiliarIntentWarningTests(unittest.TestCase):
    def test_warns_for_familiar_marker_in_changed_hunk(self) -> None:
        result = MODULE.inspect(
            "Summary\n",
            patch(
                "@@ -1,3 +1,3 @@\n"
                " // @intent owner=lawrence stability=familiar ref=#123\n"
                "-old\n"
                "+new\n"
            ),
        )
        self.assertEqual(
            result["warnings"],
            [{"owner": "lawrence", "path": "Packages/macOS/CmuxNext/Sources/Chrome.swift"}],
        )

    def test_a_missing_or_none_delta_does_not_suppress_warning(self) -> None:
        missing = MODULE.inspect(
            "Changes the sidebar.\n",
            patch("@@ -1,2 +1,2 @@\n // @intent owner=lawrence stability=familiar\n-old\n+new\n"),
        )
        self.assertFalse(missing["intent_delta"])
        self.assertTrue(missing["warnings"])
        result = MODULE.inspect(
            "Intent-Delta: none\n",
            patch("@@ -1,2 +1,2 @@\n // @intent owner=lawrence stability=familiar\n-old\n+new\n"),
        )
        self.assertFalse(result["intent_delta"])
        self.assertTrue(result["warnings"])

    def test_intent_delta_suppresses_warning(self) -> None:
        result = MODULE.inspect(
            "Intent-Delta: modified(group colors)\n",
            patch("@@ -1,2 +1,2 @@\n // @intent owner=lawrence stability=familiar\n-old\n+new\n"),
        )
        self.assertTrue(result["touched_familiar"])
        self.assertEqual(result["warnings"], [])

    def test_unrelated_marker_and_non_familiar_marker_are_ignored(self) -> None:
        result = MODULE.inspect(
            "",
            patch(
                "@@ -1,2 +1,2 @@\n"
                " // @intent owner=lawrence stability=familiar\n"
                "-old\n"
                "+new\n"
                "@@ -20,2 +20,2 @@\n"
                " // @intent owner=leo stability=experimental\n"
                "-old\n"
                "+new\n"
            ),
        )
        self.assertEqual([item["owner"] for item in result["warnings"]], ["lawrence"])


def workflow_steps() -> dict[str, str]:
    """The warn job's steps by name, each as its YAML text."""
    text = (ROOT / ".github/workflows/intent-familiar-review.yml").read_text()
    steps: dict[str, str] = {}
    for chunk in text.split("\n      - ")[1:]:
        first = chunk.splitlines()[0]
        if first.startswith("name: "):
            steps[first[len("name: "):].strip()] = chunk
    return steps


class FamiliarIntentWorkflowTests(unittest.TestCase):
    """The warning is advisory: a GitHub API error (the installation's rate limit failed 27 of 30 runs on
    2026-10-26, and next-autoland read that red as the PR's own) never fails the check."""

    def test_api_steps_continue_on_error_and_later_steps_need_their_input(self) -> None:
        steps = workflow_steps()
        read = steps["Read the pull-request patch"]
        detect = steps["Detect familiar intent changes"]
        warn = steps["Warn CodeRabbit and cubic reviewers"]
        for step in (read, warn):
            self.assertIn("continue-on-error: true", step)
        self.assertIn("id: read", read)
        self.assertIn("if: steps.read.outcome == 'success'", detect)
        self.assertIn("if: steps.detect.outcome == 'success'", warn)
        # the detector itself is this repository's code: a crash there stays a red someone sees
        self.assertNotIn("continue-on-error", detect)


if __name__ == "__main__":
    unittest.main()
