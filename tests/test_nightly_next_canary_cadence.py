"""The scheduled nightly-next canary looks at the feed every 5 minutes.

A build moves from Dev to Nightly only after a scheduled canary passes it
(nightly-next-verdict.yml accepts a pass only from a schedule run), so the
tick interval is added to every Nightly's age. At every 15 minutes, plus
GitHub's schedule delay, a published build waited about 10 to 20 minutes
before its canary even started. Leo, 2026-10-23: the Nightly should publish
about every 30 minutes while feat-cmux-next is active. A tick with no new
build only reads the feed and the "already checked" cache on Linux.
"""

import pathlib
import re
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-canary.yml"
MAX_GAP_MINUTES = 5


def minutes(field: str) -> list[int]:
    if field == "*":
        return list(range(60))
    step = re.fullmatch(r"\*/(\d+)", field)
    if step:
        return list(range(0, 60, int(step.group(1))))
    return sorted(int(m) for m in field.split(","))


class CanaryCadence(unittest.TestCase):
    def test_every_hour_is_covered_with_no_gap_over_five_minutes(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        crons = re.findall(r'^    - cron: "([^"]+)"$', text, re.M)
        self.assertTrue(crons, "the canary must keep a schedule (a pass needs a schedule run)")
        ticks: set[int] = set()
        for cron in crons:
            fields = cron.split()
            self.assertEqual(len(fields), 5, f"{cron!r} is not a five-field cron")
            minute, *rest = fields
            self.assertEqual(rest, ["*"] * 4, f"{cron!r} must run every hour of every day")
            ticks.update(minutes(minute))
        ordered = sorted(ticks)
        gaps = [b - a for a, b in zip(ordered, ordered[1:])] + [ordered[0] + 60 - ordered[-1]]
        self.assertLessEqual(max(gaps), MAX_GAP_MINUTES, f"canary ticks {ordered} leave a {max(gaps)} minute gap")


if __name__ == "__main__":
    unittest.main()
