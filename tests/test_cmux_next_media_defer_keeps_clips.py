#!/usr/bin/env python3
"""A nightly tip under the tour gap still plans its What's New clips, and tours when one waits.

On 2026-11-25 tip 4755643e (run 45692277328) deferred under the 3 h gap, 50 min after tour run
45680711758 failed at checkout. The deferral also skipped "Plan the What's New clips", so the clips
that failed tour owed waited for a tip past the gap. The plan now runs on every push, and a
deferred tip holds (takes no Mac) only when the plan is empty.
"""

import os
import subprocess
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-next-media.yml")


def _route_steps():
    with open(WORKFLOW) as f:
        doc = yaml.safe_load(f)
    return {s.get("name"): s for s in doc["jobs"]["route"]["steps"] if s.get("name")}


class MediaDeferKeepsClipsTest(unittest.TestCase):
    def setUp(self):
        self.steps = _route_steps()
        self.names = list(self.steps)

    def test_the_clip_plan_runs_on_a_deferred_tip(self):
        cond = self.steps["Plan the What's New clips"]["if"]
        self.assertNotIn("defer", cond)
        self.assertIn("pull_request", cond)

    def test_the_pick_waits_only_on_the_hold(self):
        hold = self.steps["Hold a tip under the gap with no clips waiting"]
        self.assertEqual(hold["id"], "hold")
        self.assertIn("steps.last_toured.outputs.defer == 'true'", hold["if"])
        self.assertIn("steps.clips.outputs.plan", hold["env"]["CLIPS_PLAN"])
        pick = self.steps["Pick an owned gui runner"]["if"]
        self.assertIn("steps.hold.outputs.held != 'true'", pick)
        self.assertNotIn("last_toured.outputs.defer", pick)
        order = [self.names.index(n) for n in (
            "Find the last toured tip",
            "Plan the What's New clips",
            "Hold a tip under the gap with no clips waiting",
            "Pick an owned gui runner",
        )]
        self.assertEqual(order, sorted(order))

    def test_listing_paths_still_skips_a_deferred_tip(self):
        # It runs before the plan; without its file the picker takes a Mac, which a waiting clip forces anyway.
        self.assertIn("steps.last_toured.outputs.defer != 'true'", self.steps["List the changed paths"]["if"])

    def _hold(self, plan):
        run = self.steps["Hold a tip under the gap with no clips waiting"]["run"]
        out = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"hold-out-{os.getpid()}")
        try:
            subprocess.run(["bash", "-c", run], check=True, capture_output=True,
                           env={"CLIPS_PLAN": plan, "GITHUB_OUTPUT": out, "PATH": os.environ["PATH"]})
            with open(out) as f:
                return f.read().strip()
        finally:
            if os.path.exists(out):
                os.unlink(out)

    def test_the_hold_reads_the_plan(self):
        self.assertEqual(self._hold(""), "held=true")
        self.assertEqual(self._hold("[]"), "held=true")
        self.assertEqual(self._hold('[{"id":"space-button-spacing"}]'), "held=false")


if __name__ == "__main__":
    unittest.main()
