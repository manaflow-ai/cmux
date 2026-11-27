"""cmux-next's self-hosted checkouts retry once from a fresh repository.

The Macs reuse one workspace across workflows, and a blob-filtered checkout
there leaves a partial clone behind. The next shallow checkout then fetches
missing blobs from GitHub during `git checkout`, which actions/checkout does
not retry, so one network timeout failed the Release compile ("could not
fetch <sha> from promisor remote", run 37887570270). Each such checkout keeps
going on failure, drops the workspace repository, and checks out again
(path routing tries three times, pausing between); the last failure fails
the job.

path routing and generated files check out blob-filtered on a reused cmux-linux
workspace too; one promisor blob fetch timed out there after 63 s
(cmux#55016) and left the PR with no verdict. Every blob-filtered checkout in
the workflow retries the same way.
"""
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
REUSED = "Clear stale git locks (self-hosted reused workspace)"
CHECKOUT = "actions/checkout@"
FAILED = "steps.checkout.outcome == 'failure'"


def blob_filtered(step) -> bool:
    return CHECKOUT in str(step.get("uses", "")) and (step.get("with") or {}).get("filter") == "blob:none"


class CmuxNextCheckoutRetryTests(unittest.TestCase):
    def test_every_reused_workspace_checkout_retries_once_from_a_fresh_repository(self):
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        reused = {name: job["steps"] for name, job in jobs.items()
                  if any(step.get("name") == REUSED or blob_filtered(step) for step in job.get("steps", []))}
        self.assertTrue(reused)
        self.assertIn("path_route", reused)
        self.assertIn("generated-files-linux", reused)
        for name, steps in reused.items():
            with self.subTest(job=name):
                checkouts = [i for i, step in enumerate(steps) if CHECKOUT in str(step.get("uses", ""))]
                self.assertGreaterEqual(len(checkouts), 2, "one checkout and at least one retry")
                first = steps[checkouts[0]]
                self.assertEqual(first.get("id"), "checkout")
                self.assertIs(first.get("continue-on-error"), True)
                for n, i in enumerate(checkouts[1:], start=1):
                    retry = steps[i]
                    self.assertIn(FAILED, retry.get("if", ""))
                    self.assertEqual(retry.get("with"), first.get("with"))
                    discard = steps[checkouts[n - 1] + 1]
                    self.assertIn(FAILED, discard.get("if", ""))
                    self.assertTrue(discard.get("run", "").strip().startswith('rm -rf "$GITHUB_WORKSPACE/.git"'))
                    # A step between the discard and the retry (release compile borrows the
                    # host's git mirror again) runs only after a failed checkout too.
                    for between in steps[checkouts[n - 1] + 2:i]:
                        self.assertIn(FAILED, str(between.get("if", "")), between.get("name"))
                self.assertNotIn("continue-on-error", steps[checkouts[-1]], "the last try fails the job")

if __name__ == "__main__":
    unittest.main()
