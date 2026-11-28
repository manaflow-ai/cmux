"""The motion frame checks start on a landing head that touches a motion area (ask-5ad71ec59c).

Leo, 2026-11-27: "These run only when Cmd+W, the palette or split zoom are touched." Before
`land_affected`, pr-router skipped cmux-next-motion-frames.yml on every affected-tier landing head
("landing on the affected tier: the full tier runs once an hour"), so the PR that changed a gesture
never measured it (cmux#63849's router run 46099231920).
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import pr_router  # noqa: E402

NAME = "cmux-next-motion-frames.yml"
MOTION = "Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+Visibility.swift"


class MotionFramesRoute(unittest.TestCase):
    def setUp(self) -> None:
        self.callees = pr_router.load_manifest()
        repo = {"full_name": "manaflow-ai/cmux"}
        self.pr = {"draft": False, "head": {"repo": repo}, "base": {"ref": "feat-cmux-next", "repo": repo},
                   "labels": [{"name": "ready-to-land"}]}

    def route(self, action: str, path: str) -> tuple[bool, str]:
        event = {"action": action, "label": {"name": "ready-to-land"}, "pull_request": self.pr}
        tier = pr_router.head_tier.tier("pull_request", event, land_switch="1", land_full_switch="0")
        self.assertTrue(pr_router.head_tier.land_affected(tier))
        start, why = pr_router.route(event, self.callees, [path], decided=tier)
        return NAME in start, why[NAME]

    def test_a_landing_head_that_touches_a_motion_area_starts_it(self) -> None:
        for action in ("labeled", "synchronize"):
            with self.subTest(action=action):
                starts, why = self.route(action, MOTION)
                self.assertTrue(starts, why)

    def test_a_landing_head_that_touches_no_motion_area_skips_it(self) -> None:
        starts, why = self.route("synchronize", "docs/readme.md")
        self.assertFalse(starts, why)
        starts, why = self.route("synchronize", "Packages/macOS/CmuxNext/Sources/CmuxNext/App.swift")
        self.assertFalse(starts, why)


if __name__ == "__main__":
    unittest.main()
