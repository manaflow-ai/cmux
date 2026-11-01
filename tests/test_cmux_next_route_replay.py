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
    out = {key: "true" if on.get(key) else "false" for key in keys} | {"swift_targets": on.get("targets", "")}
    # The fast tier follows macos unless a case names it (a base router from before fast_tier has none).
    if "fast_tier" in on:
        out["fast_tier"] = "true" if on["fast_tier"] else "false"
    return out


NO_FAST = "the Mac fast tier's package build reads none of these files (no Mac fast tier)"
DOC = "plans/cmux-next/sidebar-owner.md is a doc no test or generator names (no Mac tier)"


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


class SwiftCompileDrops(unittest.TestCase):
    BASE = {"native": "true", "macos": "true", "scheme": "true", "generated": "false", "swift": "false",
            "daemon": "true", "full": "false", "swift_targets": ""}

    def test_dropped_swift_compiles_with_the_reason_are_explained(self):
        new = dict(self.BASE, native="false", scheme="false")
        reason = ["cmux-tui/crates/acpmux/src/peer.rs is Rust the daemon tier builds (no Swift compile reads it)"]
        self.assertEqual(replay.explain(self.BASE, new, reason).kind, "explained")
        self.assertEqual(replay.explain(self.BASE, dict(self.BASE, native="false"), reason).kind, "explained")

    def test_without_the_reason_they_stay_unexplained(self):
        new = dict(self.BASE, native="false", scheme="false")
        self.assertEqual(replay.explain(self.BASE, new, []).kind, "unexplained")

    def test_the_reason_explains_no_other_dropped_tier(self):
        reason = ["x (no Swift compile reads it)"]
        for change in ({"daemon": "false"}, {"native": "false", "macos": "false"}, {"native": "false", "swift_targets": "A"}):
            with self.subTest(change=change):
                self.assertEqual(replay.explain(self.BASE, dict(self.BASE, **change), reason).kind, "unexplained")

    def test_the_real_router_explains_its_own_rust_routes(self):
        """The replay of a Rust-only PR against a router that compiled the app for it passes."""
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import cmux_next_route as route_module
        for files in (["cmux-tui/crates/acpmux/src/peer.rs"], ["cmux-tui/crates/cmux-wg/src/lib.rs"]):
            with self.subTest(files=files):
                result = route_module.route(ROOT, "pull_request", files, set())
                after = route_module.outputs(result)
                before = dict(after, native="true", scheme="true")
                self.assertEqual(replay.explain(before, after, list(result.reasons)).kind, "explained")


class FastTierAndDocs(unittest.TestCase):
    """#28326 (one design note) and the daemon-only pull requests that queued a Mac fast tier."""

    def test_a_base_router_without_fast_tier_ran_it_with_any_mac_tier(self):
        self.assertEqual(replay.tier(tiers(macos=True), "fast_tier"), "true")
        self.assertEqual(replay.tier(tiers(), "fast_tier"), "false")
        self.assertEqual(replay.compare(tiers(daemon=True, macos=True), tiers(daemon=True, macos=True, fast_tier=True), []).kind,
                         "same")

    def test_a_dropped_fast_tier_is_explained_by_its_reason(self):
        old = tiers(daemon=True, macos=True)
        new = tiers(daemon=True, macos=True, fast_tier=False)
        self.assertEqual(replay.compare(old, new, [NO_FAST]).kind, "explained")
        self.assertEqual(replay.compare(old, new, ["x reaches the daemon"]).kind, "unexplained")

    def test_the_fast_tier_reason_explains_no_other_tier(self):
        old = tiers(daemon=True, swift=True, macos=True, targets="A")
        new = tiers(macos=True, daemon=True, fast_tier=False)
        self.assertEqual(replay.compare(old, new, [NO_FAST]).kind, "unexplained")

    def test_a_design_note_dropping_its_reads_is_explained(self):
        old = tiers(generated=True, swift=True, macos=True, targets="CmuxNextActionsTests CmuxNextAppTests")
        self.assertEqual(replay.compare(old, tiers(), [DOC]).kind, "explained")
        self.assertEqual(replay.compare(old, tiers(), []).kind, "unexplained")

    def test_a_note_beside_swift_narrows_the_targets_only_with_its_reason(self):
        old = tiers(swift=True, macos=True, targets="A B")
        new = tiers(swift=True, macos=True, targets="A")
        self.assertEqual(replay.compare(old, new, [DOC]).kind, "explained")
        self.assertEqual(replay.compare(old, new, []).kind, "unexplained")
        self.assertEqual(replay.compare(new, old, [DOC]).kind, "unexplained", "a widened set is never explained")


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
