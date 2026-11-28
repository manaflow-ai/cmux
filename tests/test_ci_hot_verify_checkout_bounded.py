"""cmux-next-hot-verify.yml: a checkout with an (again) twin is bounded, so the twin can run.

Unbounded, a stalled blobless clone used the whole job: run 46050959640 (2026-11-27, cmux#62150's merge look) hung
in `check the pull request`'s first checkout to the job's 5 min, the run ended cancelled, and the look was lost
with no retry. The job's own bound has to leave both tries their time.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-hot-verify.yml"


class HotVerifyCheckoutBoundedTest(unittest.TestCase):
    def test_every_checkout_with_an_again_twin_is_bounded_inside_its_job(self) -> None:
        doc = yaml.safe_load(WORKFLOW.read_text())
        seen = 0
        for job_name, job in doc["jobs"].items():
            steps = job.get("steps", [])
            names = {step.get("name") for step in steps}
            for step in steps:
                name = step.get("name") or ""
                if not str(step.get("uses", "")).startswith("actions/checkout@") or f"{name} (again)" not in names:
                    continue
                seen += 1
                bound = step.get("timeout-minutes")
                self.assertIsInstance(bound, int, f"{job_name}: {name} has no timeout-minutes")
                self.assertTrue(step.get("continue-on-error"), f"{job_name}: {name} must let its twin run")
                self.assertGreaterEqual(int(job["timeout-minutes"]), 2 * bound + 2,
                                        f"{job_name}: its timeout-minutes leaves no time for the (again) checkout")
        self.assertGreaterEqual(seen, 4)


if __name__ == "__main__":
    unittest.main()
