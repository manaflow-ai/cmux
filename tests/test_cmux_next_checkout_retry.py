"""cmux-next's self-hosted checkouts retry once from a fresh repository.

The Macs reuse one workspace across workflows, and a blob-filtered checkout
there leaves a partial clone behind. The next shallow checkout then fetches
missing blobs from GitHub during `git checkout`, which actions/checkout does
not retry, so one network timeout failed the Release compile ("could not
fetch <sha> from promisor remote", run 37887570270). Each such checkout keeps
going on failure, drops the workspace repository, and checks out once more;
a second failure fails the job.
"""
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
REUSED = "Clear stale git locks (self-hosted reused workspace)"
CHECKOUT = "actions/checkout@"
FAILED = "steps.checkout.outcome == 'failure'"


class CmuxNextCheckoutRetryTests(unittest.TestCase):
    def test_every_reused_workspace_checkout_retries_once_from_a_fresh_repository(self):
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        reused = {name: job["steps"] for name, job in jobs.items()
                  if any(step.get("name") == REUSED for step in job.get("steps", []))}
        self.assertTrue(reused)
        for name, steps in reused.items():
            with self.subTest(job=name):
                checkouts = [i for i, step in enumerate(steps) if CHECKOUT in str(step.get("uses", ""))]
                self.assertEqual(len(checkouts), 2, "one checkout and one retry")
                first, retry = (steps[i] for i in checkouts)
                self.assertEqual(first.get("id"), "checkout")
                self.assertIs(first.get("continue-on-error"), True)
                self.assertEqual(retry.get("if"), FAILED)
                self.assertNotIn("continue-on-error", retry)
                self.assertEqual(retry.get("with"), first.get("with"))
                discard = steps[checkouts[0] + 1]
                self.assertEqual(discard.get("if"), FAILED)
                self.assertEqual(discard.get("run", "").strip(), 'rm -rf "$GITHUB_WORKSPACE/.git"')
                self.assertEqual(checkouts[1], checkouts[0] + 2)


if __name__ == "__main__":
    unittest.main()
