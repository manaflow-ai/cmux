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


if __name__ == "__main__":
    unittest.main()
