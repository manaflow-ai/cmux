"""Every continuation job that sends gh calls waits through a GitHub API rate limit.

2026-11-26 16:37Z: run 45859181110's poll job (job 140045779351) gave up on
`gh run download` after gh_app_token.sh's four tries (60+120+240 s) with "API rate
limit exceeded for installation", so a signed nightly was never published and the
NEXT feed stalled at 15:39Z. preflight, publish and republish-deltas install
scripts/ci/gh_budget_wait.sh (waits until the budget's reset, at most an hour per
job); poll, wait-and-staple, poll-outer, staple-outer, poll-stapled and
staple-stapled did not. This test holds the whole class: a job that installs the
token wrapper installs the budget wrapper right after it.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "auto-resume-nightly-notarization.yml"


def jobs(text: str) -> dict[str, str]:
    body = text.split("\njobs:\n", 1)[1]
    parts = re.split(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", body)
    return {parts[i]: parts[i + 1] for i in range(1, len(parts) - 1, 2)}


class ContinuationJobsWaitThroughRateLimits(unittest.TestCase):
    def test_every_job_with_the_token_wrapper_installs_the_budget_wrapper_after_it(self) -> None:
        missing = []
        for name, job in jobs(WORKFLOW.read_text()).items():
            token = job.find("gh_app_token.sh --install")
            if token < 0:
                continue
            budget = job.find("gh_budget_wait.sh --install", token)
            if budget < 0:
                missing.append(name)
        self.assertEqual(missing, [], "jobs that give up on a rate limit instead of waiting for its reset")

    def test_no_step_calls_the_github_api_around_the_gh_wrapper(self) -> None:
        # 2026-11-26 18:12Z: run 45868042226's publish job died in "Reject stale continuation
        # before publication", which read releases/tags/<tag> with urllib and got HTTP 403 on
        # a spent budget; gh_budget_wait.sh wraps gh only. Every API read goes through gh.
        text = WORKFLOW.read_text()
        self.assertNotIn("urlopen(", text)
        self.assertNotIn("https://api.github.com/", text)

    def test_no_gh_call_is_killed_before_the_budget_wait_can_finish(self) -> None:
        # gh_budget_wait.sh reserves its whole wait (up to GH_BUDGET_WAIT_MAX_SECONDS, 3600 s)
        # before sleeping. #59218's publish guard ran gh under subprocess timeout=240, so a reset
        # more than 4 min away was killed mid-wait, its reservation spent, and the next try
        # failed at once: the same refusal 45868042226 died on. A gh call's timeout outlasts it.
        text = WORKFLOW.read_text()
        short = [int(t) for t in re.findall(r'\["gh",[^\n]*\n?[^\n]*?timeout=(\d+)', text) if int(t) <= 3600]
        self.assertEqual(short, [], "gh calls killed before an hour-long budget wait ends")


if __name__ == "__main__":
    unittest.main()
