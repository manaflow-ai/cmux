#!/usr/bin/env python3
"""nightly-next-one's Release compile has its own step bound.

The job's timeout-minutes (300) covers Apple's notarization wait and the publish lease's wait, so a compile that
stalls holds nightly-next's push slot, and every nightly behind it, for up to five hours. Run 43673773157 on
2026-11-15: "Build nightly app (Release)" on ultra1 ran 80+ minutes against 6-19 minute one-job builds on cmux15.
The step's own bound fails such a build within an hour, and the loop retry builds again.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

import workflow_jobs  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/nightly.yml"
STEP = "Build nightly app (Release)"
# Two cold builds (app-build-release.sh retries once on a compilation cache failure) fit; hours do not.
MAX_MINUTES = 90


class NightlyNextBuildStepBoundTest(unittest.TestCase):
    def test_one_job_release_build_is_bounded_below_the_job(self):
        job = workflow_jobs.jobs(WORKFLOW)["nightly-next-one"]
        steps = [step for step in job["steps"] if isinstance(step, dict) and step.get("name") == STEP]
        self.assertEqual(len(steps), 1, f"nightly-next-one has one {STEP!r} step")
        bound = steps[0].get("timeout-minutes")
        self.assertIsInstance(bound, int, f"nightly-next-one {STEP!r} needs its own literal timeout-minutes")
        self.assertGreater(bound, 0)
        self.assertLessEqual(bound, MAX_MINUTES)
        self.assertLess(bound, int(job["timeout-minutes"]), "the step bound must end the compile before the job's")


if __name__ == "__main__":
    unittest.main()
