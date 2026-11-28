"""nightly.yml's main tick decide cannot hold the tick queue for an hour.

Why: main's 15-minute ticks share one concurrency group (`nightly-main-tick-decide`): one decide
runs, one waits, and a newer tick replaces the waiting one. Run 46153075055 (2026-11-28) spent
2821 s in decide on one rate-limited GET, two ticks behind it were cancelled, and nightly-next
did not move for an hour. A tick's decide is a few seconds of metadata, so it is bounded below
one tick and fails so the next tick retries; every other decide keeps the whole-reset wait.

Detector for the pattern "an unbounded wait inside a serialized concurrency group": every job
with its own concurrency group sets timeout-minutes (the default is 360).
"""
from pathlib import Path
import re
import unittest

NIGHTLY = Path(__file__).resolve().parents[1] / ".github/workflows/nightly.yml"
TICK_MINUTES = 15


def jobs(text: str) -> dict[str, str]:
    body = text.split("\njobs:\n", 1)[1]
    parts = re.split(r"^  ([A-Za-z0-9_-]+):\s*$", body, flags=re.M)
    return {parts[i]: parts[i + 1] for i in range(1, len(parts), 2)}


def job_timeout(block: str) -> str | None:
    m = re.search(r"^    timeout-minutes:\s*(.+)$", block, re.M)
    return m.group(1).strip() if m else None


class NightlyDecideBounded(unittest.TestCase):
    def setUp(self) -> None:
        self.text = NIGHTLY.read_text()
        self.jobs = jobs(self.text)
        group = re.search(r"^      group: \$\{\{ (.+) && 'nightly-main-tick-decide' \|\|", self.jobs["decide"], re.M)
        self.assertIsNotNone(group, "decide's shared tick group moved")
        self.tick_condition = group.group(1)

    def test_decide_holds_the_shared_tick_group(self) -> None:
        self.assertIn("'nightly-main-tick-decide'", self.jobs["decide"])

    def tick_split(self, value: str) -> tuple[str, str]:
        m = re.fullmatch(r"\$\{\{ (.+) && '?(\d+)'? \|\| '?(\d+)'? \}\}", value.strip().strip('"'))
        self.assertIsNotNone(m, f"not `${{{{ <tick> && N || M }}}}`: {value}")
        self.assertEqual(m.group(1), self.tick_condition, "the bound must key on the shared group's own condition")
        return m.group(2), m.group(3)

    def test_decide_job_ends_within_one_tick(self) -> None:
        timeout = job_timeout(self.jobs["decide"])
        self.assertIsNotNone(timeout, "decide has no timeout-minutes (default 360)")
        tick, other = self.tick_split(timeout)
        self.assertLessEqual(int(tick), TICK_MINUTES)
        self.assertGreaterEqual(int(other) * 60, 3900 + 300, "other decides keep the whole-reset wait")

    def test_tick_decide_waits_less_than_a_tick(self) -> None:
        step = self.jobs["decide"].split("- name: Decide whether a nightly build is needed", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        m = re.search(r"GH_BUDGET_WAIT_MAX_SECONDS:\s*(.+)$", step, re.M)
        self.assertIsNotNone(m, "the decide step inherits the job's hour-long rate-limit wait")
        tick, other = self.tick_split(m.group(1))
        self.assertLess(int(tick) + 300, TICK_MINUTES * 60)
        self.assertGreaterEqual(int(other), 3900)

    def test_every_job_in_its_own_concurrency_group_is_bounded(self) -> None:
        unbounded = [
            name
            for name, block in self.jobs.items()
            if re.search(r"^    concurrency:", block, re.M) and job_timeout(block) is None
        ]
        self.assertEqual(unbounded, [], "jobs in a concurrency group with no timeout-minutes")


if __name__ == "__main__":
    unittest.main()
