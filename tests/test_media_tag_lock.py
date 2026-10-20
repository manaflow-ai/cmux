#!/usr/bin/env python3
"""scripts/ci/media_tag_lock.py: a tour holds its tag after `hold` returns, a second
tour of that tag waits until the holder's job ends, and other tags never wait."""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/media_tag_lock.py"
WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next-media.yml"


class MediaTagLockTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tag-lock.")
        self.locks = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def hold(self, tag: str, wait: float, max_hold: float = 4) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(SCRIPT), "hold", "--tag", tag, "--lock-dir", str(self.locks),
                               "--wait", str(wait), "--max-hold", str(max_hold)],
                              capture_output=True, text=True, timeout=60)

    def test_the_tag_stays_held_after_hold_returns(self) -> None:
        first = self.hold("ci-media-pr-1", wait=1)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        second = self.hold("ci-media-pr-1", wait=1)
        self.assertEqual(second.returncode, 1, second.stdout)
        self.assertIn("still held", second.stdout)

    def test_another_tag_never_waits(self) -> None:
        self.assertEqual(self.hold("ci-media-pr-1", wait=1).returncode, 0)
        other = self.hold("ci-media-pr-2", wait=0)
        self.assertEqual(other.returncode, 0, other.stdout)

    def test_a_waiting_tour_gets_the_tag_when_the_holder_lets_go(self) -> None:
        # No Runner.Worker above the test, so the holder lets go after --max-hold.
        self.assertEqual(self.hold("ci-media-feat-cmux-next", wait=1, max_hold=3).returncode, 0)
        started = time.monotonic()
        later = self.hold("ci-media-feat-cmux-next", wait=30)
        self.assertEqual(later.returncode, 0, later.stdout)
        self.assertIn("waiting for", later.stdout)
        self.assertLess(time.monotonic() - started, 25)

    def test_the_workflow_waits_for_a_warm_merge_tour_and_leaves_room_to_build(self) -> None:
        # A merge tour holds the feat-cmux-next tag for its whole job (54 min seen warm), and a dispatch of that
        # tag waits behind it. The wait outlasts a warm merge tour, but it also ends early enough that the waiter
        # still has time for a cold build and the tour (35+ min) inside its own job timeout, which counts from
        # job start. Otherwise a starved tour is cancelled by the job timeout instead of failing with "still held".
        text = WORKFLOW.read_text()
        tour = text[text.index("\n  tour:\n"):text.index("\n  publish:\n")]
        timeout = re.search(r"^    timeout-minutes: (\d+)$", tour, re.M)
        wait = re.search(r"(?:media_tag_lock\.py\"?|\"\$lock\") hold --tag \"\$TOUR_TAG\" --wait (\d+)", tour)
        self.assertIsNotNone(timeout, "the tour job has a timeout-minutes")
        self.assertIsNotNone(wait, "the tour holds its tag with an explicit --wait")
        self.assertGreaterEqual(int(wait.group(1)), 60 * 60, "the wait outlasts a warm merge tour")
        self.assertLessEqual(int(wait.group(1)), (int(timeout.group(1)) - 45) * 60,
                             "the wait leaves 45 min of the job for a cold build and the tour")

    def test_a_tag_that_is_not_a_name_is_refused(self) -> None:
        self.assertEqual(self.hold("../x", wait=0).returncode, 2)


if __name__ == "__main__":
    unittest.main()
