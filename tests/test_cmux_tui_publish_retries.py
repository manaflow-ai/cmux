#!/usr/bin/env python3
"""A transient GitHub or R2 hiccup never leaves a cmux-tui tree unpublished.

Nightly-next promotion needs a published cmux-tui tree (request-nightly-next.sh),
so a failed publish run holds the NEXT nightly back until a later commit's
tree publishes. On 2026-10-26 promotions stopped from 18:42 to 19:44 UTC:
- runs 40376958903 and 40380418761 failed in actions/attest-build-provenance
  with "API rate limit exceeded for installation" (the hourly budget other
  workflows had spent);
- run 40376958903's publish-tree timed out after 120 s on a 40 MB companion,
  with no retry.
The attestation now retries once after a bounded wait for the API budget
(scripts/ci/gh_budget_wait.sh --reserve, as nightly.yml's daemon attestation
does), and the retry must pass. The job timeouts leave room for that wait.
publish-tree's fetch retries timeouts and server errors. (A short remote read
during manifest verification is retried in verify_published_manifest.py; its
unit tests cover that.)
"""

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
ATTEST = "actions/attest-build-provenance@"


def load() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


class PublishRetries(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = load()["jobs"]

    def test_attestation_retries_after_a_budget_wait(self) -> None:
        for job_name in ("publish", "publish-windows"):
            steps = self.jobs[job_name]["steps"]
            attests = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith(ATTEST)]
            self.assertEqual(len(attests), 2, f"{job_name}: expected a first attestation and one retry")
            first, retry = (steps[i] for i in attests)
            self.assertTrue(first.get("continue-on-error"), f"{job_name}: the first attestation must not fail the job")
            step_id = first.get("id")
            self.assertTrue(step_id, f"{job_name}: the first attestation needs an id")
            gate = f"steps.{step_id}.outcome == 'failure'"
            self.assertEqual(retry.get("if"), gate, f"{job_name}: the retry runs only after a failed first try")
            self.assertFalse(retry.get("continue-on-error"), f"{job_name}: the retry must pass; nothing ships without provenance")
            self.assertEqual(first.get("with"), retry.get("with"), f"{job_name}: the retry attests the same subjects")
            waits = [s for s in steps[attests[0] + 1 : attests[1]] if "gh_budget_wait.sh --reserve" in str(s.get("run", ""))]
            self.assertEqual(len(waits), 1, f"{job_name}: one bounded budget wait sits between the tries")
            self.assertEqual(waits[0].get("if"), gate)
            # Without a token the wait silently skips and the retry hits the same empty budget.
            self.assertEqual(waits[0].get("env", {}).get("GH_TOKEN"), "${{ github.token }}", f"{job_name}: the wait reads the budget with the job's token")
            self.assertGreaterEqual(
                int(self.jobs[job_name]["timeout-minutes"]), 75,
                f"{job_name}: the timeout must leave room for the hour the budget wait may take",
            )

    def test_publish_tree_fetch_retries_transient_failures(self) -> None:
        script = "\n".join(str(s.get("run", "")) for s in self.jobs["publish-tree"]["steps"])
        fetch = re.search(r"^\s*fetch\(\) \{ (curl [^}]*)\}", script, re.M)
        self.assertIsNotNone(fetch, "publish-tree defines fetch()")
        command = fetch.group(1)
        self.assertRegex(command, r"--retry [1-9]", "fetch must retry timeouts and server errors")
        self.assertNotIn("--retry-all-errors", command, "a 404 is how fetch learns a tree has no source.json yet")
        max_time = re.search(r"--max-time (\d+)", command)
        self.assertTrue(max_time and int(max_time.group(1)) >= 300, "a 100 MB companion needs more than 120 s")
        retries = int(re.search(r"--retry (\d+)", command).group(1))
        delay = re.search(r"--retry-delay (\d+)", command)
        one_fetch = (retries + 1) * int(max_time.group(1)) + retries * (int(delay.group(1)) if delay else 0)
        # publish-tree-windows runs publish-tree's steps; both must outlast one fetch's full retry budget.
        for job_name in ("publish-tree", "publish-tree-windows"):
            self.assertGreater(
                int(self.jobs[job_name]["timeout-minutes"]) * 60, one_fetch,
                f"{job_name}: its timeout cuts one fetch's retries ({one_fetch} s) short",
            )


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if result.wasSuccessful() else 1)
