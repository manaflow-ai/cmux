#!/usr/bin/env python3
"""The tour job's own timeout leaves "Record What's New clips" its whole step budget.

Job 139295566977 (nightly tip e3e28d91, 2026-11-25) started at 14:59:02. Runner
setup, both app builds and the before/after capture ended at 16:54:41, 115.6
min in. The job's 120 min cap then cancelled the clip step 4.5 min into its
45 min, and the "Keep the media" hand-off after it. That night published no
What's New clip. This test checks that the job cap covers that observed lead
plus the clip step's cap and a hand-off margin.
"""

import os
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-next-media.yml")

# Minutes from the job's start to the clip step's start in job 139295566977.
OBSERVED_LEAD_MIN = 116
# The steps after the clip step (stop apps, keep media, unregister worktree).
HAND_OFF_MARGIN_MIN = 10


class TourTimeoutTest(unittest.TestCase):
    def test_job_cap_leaves_clip_step_its_budget(self):
        with open(WORKFLOW) as f:
            wf = yaml.safe_load(f)
        tour = wf["jobs"]["tour"]
        clip = next(s for s in tour["steps"] if s.get("name") == "Record What's New clips")
        need = OBSERVED_LEAD_MIN + int(clip["timeout-minutes"]) + HAND_OFF_MARGIN_MIN
        self.assertGreaterEqual(
            int(tour["timeout-minutes"]), need,
            f"tour job cap {tour['timeout-minutes']} min cuts the clip step: "
            f"observed lead {OBSERVED_LEAD_MIN} + clip cap {clip['timeout-minutes']} "
            f"+ hand-off {HAND_OFF_MARGIN_MIN} = {need}")


if __name__ == "__main__":
    unittest.main()
