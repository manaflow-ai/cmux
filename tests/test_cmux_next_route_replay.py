#!/usr/bin/env python3
"""The routing replay: recent PRs' changed files through the base router and the PR's router.

A router change may only drop tiers for files the new router names as cheap (its fast tiers).
Any other tier change, added or dropped, is unexplained and fails the checks job.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_route_replay as replay  # noqa: E402

FAST = "only web files changed: Linux checks cover them (no Mac tier)"


def tiers(**on: bool) -> dict[str, str]:
    keys = ("native", "macos", "scheme", "generated", "swift", "daemon", "full")
    return {key: "true" if on.get(key) else "false" for key in keys} | {"swift_targets": on.get("targets", "")}


class Compare(unittest.TestCase):
    def test_the_same_tiers_are_unchanged(self):
        verdict = replay.compare(tiers(native=True, macos=True), tiers(native=True, macos=True), [])
        self.assertEqual(verdict.kind, "same")

    def test_tiers_dropped_by_a_fast_tier_are_explained(self):
        verdict = replay.compare(tiers(scheme=True, macos=True), tiers(), [FAST])
        self.assertEqual(verdict.kind, "explained")
        self.assertIn("scheme", verdict.detail)

    def test_a_dropped_tier_without_a_fast_reason_is_unexplained(self):
        verdict = replay.compare(tiers(swift=True, macos=True, targets="A"), tiers(), ["x is read by A"])
        self.assertEqual(verdict.kind, "unexplained")

    def test_an_added_tier_is_unexplained(self):
        verdict = replay.compare(tiers(), tiers(native=True, macos=True), [])
        self.assertEqual(verdict.kind, "unexplained")

    def test_changed_swift_targets_are_unexplained(self):
        verdict = replay.compare(tiers(swift=True, targets="A"), tiers(swift=True, targets="A B"), [])
        self.assertEqual(verdict.kind, "unexplained")


class Replay(unittest.TestCase):
    def test_the_report_fails_on_any_unexplained_pr(self):
        def old(files):
            return tiers(scheme=True, macos=True), []

        def new(files):
            return (tiers(), [FAST]) if files == ["webviews/a.ts"] else (tiers(native=True, macos=True), [])

        prs = [(1, ["webviews/a.ts"]), (2, ["App/main.swift"])]
        lines, failed = replay.replay(prs, old, new)
        self.assertTrue(failed)
        self.assertTrue(any(line.startswith("#1 explained") for line in lines), lines)
        self.assertTrue(any(line.startswith("#2 UNEXPLAINED") for line in lines), lines)

    def test_identical_routers_pass(self):
        def same(files):
            return tiers(native=True, macos=True), []

        _, failed = replay.replay([(1, ["a"]), (2, ["b"])], same, same)
        self.assertFalse(failed)

    def test_the_base_router_loads_from_a_git_ref(self):
        """The old router is the PR's base parent (HEAD^1 of the merge commit); here, HEAD."""
        route = replay.load_router(ROOT, "HEAD")
        result, reasons = route(["docs/cmux-next.md"])
        self.assertEqual(result["macos"], "false")
        self.assertIsInstance(reasons, list)


if __name__ == "__main__":
    unittest.main()
