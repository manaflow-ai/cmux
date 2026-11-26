#!/usr/bin/env python3
"""The job's clock, not a step cap, ends "Record What's New clips", and it leaves the hand-off its time.

Job 139295566977 (nightly tip e3e28d91, 2026-11-25) reached the clip step 115.6 min in, and the
job's 120 min cap cancelled it 4.5 min into its 45 min along with the "Keep the media" hand-off.
The clip step now stops on the job's clock, a fixed margin before the job's cap.

Job 140119006420 (run 45880649238, 2026-11-26) shows the step's own 45 min cap then got in the way:
it reached the clip step 58 min in, recorded the afters, built the before app at a644014a for
41 min and was killed at 20:48Z, 17 min before the job's clock. Both befores were lost. The step
cap now sits at the job cap minus the clock's margin, so it never fires before the clock does.
"""

import os
import re
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-next-media.yml")

# The steps after the clip step (stop apps, keep media, unregister worktree).
HAND_OFF_MARGIN_MIN = 10


def tour_and_clip():
    with open(WORKFLOW) as f:
        wf = yaml.safe_load(f)
    tour = wf["jobs"]["tour"]
    clip = next(s for s in tour["steps"] if s.get("name") == "Record What's New clips")
    return tour, clip


def clock_margin(clip) -> int:
    m = re.search(r"\(cap - (\d+)\) \* 60", clip["run"])
    assert m, "the clip step no longer sets TOUR_DEADLINE from the job cap"
    return int(m.group(1))


class TourTimeoutTest(unittest.TestCase):
    def test_clock_leaves_hand_off_its_time(self):
        _, clip = tour_and_clip()
        self.assertGreaterEqual(clock_margin(clip), HAND_OFF_MARGIN_MIN)

    def test_step_cap_never_fires_before_the_clock(self):
        tour, clip = tour_and_clip()
        clock = int(tour["timeout-minutes"]) - clock_margin(clip)
        self.assertGreaterEqual(
            int(clip["timeout-minutes"]), clock,
            f"clip step cap {clip['timeout-minutes']} min can end the step before the job's clock "
            f"({tour['timeout-minutes']} - {clock_margin(clip)} = {clock} min from the job's start)")

    def test_before_tree_network_steps_run_on_the_clock(self):
        _, clip = tour_and_clip()
        run = clip["run"]
        for cmd in ("git fetch --no-tags", "\"$MEDIA_TOUR_CI/media_tree_submodules.sh\"",
                    "./scripts/download-prebuilt-ghosttykit.sh"):
            line = next(l for l in run.splitlines() if cmd in l)
            self.assertIn(f"bounded {cmd}", line, f"{cmd} is not under bounded")


if __name__ == "__main__":
    unittest.main()
