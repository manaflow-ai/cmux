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
Run 40422130372 (2026-10-27) then failed both tries of a single retry 4 s
apart: its core budget had calls left, so the refusal was GitHub's secondary
limit. The attestation is now tried four times, each failed try backing off
through scripts/ci/gh_budget_wait.sh --backoff (until the reset, else 60, 120,
240 s) within a 15 minute total, and the last try must pass. The job timeouts
leave room for that wait.
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

    def test_attestation_retries_with_backoff(self) -> None:
        for job_name in ("publish", "publish-windows"):
            steps = self.jobs[job_name]["steps"]
            attests = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith(ATTEST)]
            self.assertEqual(len(attests), 4, f"{job_name}: expected four attestation tries")
            tries = [steps[i] for i in attests]
            first, last = tries[0], tries[-1]
            self.assertIsNone(first.get("if"), f"{job_name}: the first try always runs")
            for earlier, later, index in zip(tries, tries[1:], range(1, len(tries))):
                # Only the first try's token differs (the release App's when it minted).
                same = lambda step: {k: v for k, v in step.get("with", {}).items() if k != "github-token"}
                self.assertEqual(same(earlier), same(later), f"{job_name}: every try attests the same subjects")
                self.assertTrue(earlier.get("continue-on-error"), f"{job_name}: a try before the last must not fail the job")
                step_id = earlier.get("id")
                self.assertTrue(step_id, f"{job_name}: an attestation try before the last needs an id")
                gate = f"steps.{step_id}.outcome == 'failure'"
                self.assertEqual(later.get("if"), gate, f"{job_name}: a try runs only after the one before it failed")
                between = steps[attests[index - 1] + 1 : attests[index]]
                self.assertEqual(len(between), 1, f"{job_name}: exactly one backoff sits between two tries")
                backoff = between[0]
                self.assertEqual(backoff.get("if"), gate)
                self.assertRegex(str(backoff.get("run", "")), rf"gh_budget_wait\.sh --backoff {index}\b")
                env = backoff.get("env", {})
                # Without a token the backoff cannot read the reset and the next try hits the same limit.
                self.assertEqual(env.get("GH_TOKEN"), "${{ github.token }}", f"{job_name}: the backoff reads the budget with the job's token")
                self.assertLessEqual(int(env.get("GH_BUDGET_WAIT_MAX_SECONDS", "3600")), 900, f"{job_name}: the backoffs wait 15 minutes at most in all")
            self.assertFalse(last.get("continue-on-error"), f"{job_name}: the last try must pass; nothing ships without provenance")
            self.assertGreaterEqual(
                int(self.jobs[job_name]["timeout-minutes"]), 15 + 15 + 5,
                f"{job_name}: the timeout must leave room for the work plus the 15 minutes the backoffs may take",
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
