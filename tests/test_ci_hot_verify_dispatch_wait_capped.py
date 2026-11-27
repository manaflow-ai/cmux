"""The hot-verify plan job's look dispatch never sleeps out a spent GitHub API hour on a runner.

On 2026-11-24 21:29-23:00Z every token pool was spent and "Dispatch the look" waited for the reset under
GH_BUDGET_WAIT_MAX_SECONDS 3900: 1,425 s in run 45491644909, 1,429 s in run 45501419444, about 50 such runs in the
pages read. The look is advisory (a merged PR with no receipt gets one at its merge commit), so the wait is capped
at 120 s like the file's other dispatches, and a rate limit past it ends the step green with a notice.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next-hot-verify.yml"
MAX_WAIT_S = 120
MAX_JOB_MIN = 20


def job_block(text: str, job: str) -> str:
    lines = text.splitlines()
    start = lines.index(f"  {job}:")
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[i])), len(lines))
    return "\n".join(lines[start:end])


def step_block(job: str, name: str) -> str:
    lines = job.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == f"- name: {name}")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("      - name: ")), len(lines))
    return "\n".join(lines[start:end])


class DispatchWaitCapped(unittest.TestCase):
    def setUp(self) -> None:
        self.text = WORKFLOW.read_text()
        self.plan = job_block(self.text, "plan")
        self.dispatch = step_block(self.plan, "Dispatch the look")

    def test_every_rate_limit_wait_in_the_file_is_capped(self) -> None:
        waits = [int(v) for v in re.findall(r"GH_BUDGET_WAIT_MAX_SECONDS:\s*\"?(\d+)", self.text)]
        self.assertTrue(waits)
        self.assertLessEqual(max(waits), MAX_WAIT_S, waits)

    def test_the_dispatch_sets_its_cap(self) -> None:
        # Unset, gh_budget_wait.sh defaults to 3600 s.
        self.assertRegex(self.dispatch, r"GH_BUDGET_WAIT_MAX_SECONDS:\s*\"?\d+")

    def test_the_plan_job_cannot_hold_a_runner_for_an_hour(self) -> None:
        minutes = int(re.search(r"^    timeout-minutes:\s*(\d+)", self.plan, re.M).group(1))
        self.assertLessEqual(minutes, MAX_JOB_MIN)

    def test_a_spent_hour_skips_the_look_without_a_red(self) -> None:
        rate = self.dispatch.index('grep -qiE "rate limit|HTTP 429"')
        after = self.dispatch[rate:]
        self.assertLess(after.index("exit 0"), after.index("exit 1"))


if __name__ == "__main__":
    unittest.main()
