#!/usr/bin/env python3
"""The job's clock, not the step's own cap, stops "Record What's New clips".

Job 139295566977 (nightly tip e3e28d91, 2026-11-25): setup, both app builds and
the before/after capture took 116 min, so the job's 120 min cap cancelled the
clip step and the "Keep the media" hand-off after it. No clip that night.

Job 140119006420 (nightly tip 48d6f5ac, 2026-11-26): the clip step started
59 min in. The afters recorded in a minute, then the older nightly's before app
(a644014a) was still compiling Rust when the step's fixed 45 min cap killed it
at 20:48Z, while the job's own clock ran to 21:52Z. space-button-spacing and
warn-before-quit-shortcut kept no before for another night.

So the step stops at TOUR_DEADLINE (the job's cap less a hand-off margin, read
from this file), and the step's own cap must not come first for any lead seen.
"""

import os
import re
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-next-media.yml")

# Minutes from the job's start to the clip step's start, shortest seen (job 140119006420).
SHORTEST_LEAD_MIN = 59
# Minutes from the job's start to the clip step's start, longest seen (job 139295566977).
LONGEST_LEAD_MIN = 116


class TourTimeoutTest(unittest.TestCase):
    def setUp(self):
        with open(WORKFLOW) as f:
            wf = yaml.safe_load(f)
        self.tour = wf["jobs"]["tour"]
        self.clip = next(s for s in self.tour["steps"] if s.get("name") == "Record What's New clips")
        m = re.search(r"\(cap - (\d+)\) \* 60", self.clip["run"])
        self.assertIsNotNone(m, "the clip step no longer stops at the job's clock (TOUR_DEADLINE)")
        self.margin = int(m.group(1))

    def test_job_clock_leaves_the_hand_off_its_margin(self):
        self.assertIn('["jobs"]["tour"]["timeout-minutes"]', self.clip["run"])
        self.assertGreaterEqual(self.margin, 10, "the steps after the clips need their minutes")

    def test_step_cap_does_not_cut_before_the_job_clock(self):
        job_cap = int(self.tour["timeout-minutes"])
        step_cap = int(self.clip["timeout-minutes"])
        clock_left = job_cap - self.margin - SHORTEST_LEAD_MIN
        self.assertGreaterEqual(
            step_cap, clock_left,
            f"clip step cap {step_cap} min ends before the job's clock: job {job_cap} - "
            f"margin {self.margin} - shortest lead {SHORTEST_LEAD_MIN} = {clock_left} min")

    def test_longest_lead_still_gets_clip_time(self):
        job_cap = int(self.tour["timeout-minutes"])
        self.assertGreaterEqual(job_cap - self.margin - LONGEST_LEAD_MIN, 45)


if __name__ == "__main__":
    unittest.main()
