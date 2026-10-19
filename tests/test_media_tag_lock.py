#!/usr/bin/env python3
"""scripts/ci/media_tag_lock.py: a tour holds its tag after `hold` returns, a second
tour of that tag waits until the holder's job ends, and other tags never wait.

`claim` gives each concurrent tour on a Mac a slot of its own (tag ci-media-slot<N>),
so a Mac keeps K warm DerivedData pairs however many pull requests it tours."""

from __future__ import annotations

import fcntl
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import yaml

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

    def free(self, tag: str) -> bool:
        """Whether no process holds tag's lock; the probe lets go at once."""
        path = self.locks / f"{tag}.lock"
        if not path.exists():
            return True
        fd = os.open(path, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            return False
        finally:
            os.close(fd)

    def claim(self, slots: int, max_hold: float = 4) -> dict[str, str]:
        """Run `claim` and return what it wrote to GITHUB_ENV (empty when it failed)."""
        env_file = self.locks / f"github_env.{time.monotonic_ns()}"
        env_file.touch()
        done = subprocess.run([sys.executable, str(SCRIPT), "claim", "--slots", str(slots), "--lock-dir",
                               str(self.locks), "--github-env", str(env_file), "--max-hold", str(max_hold)],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return dict(line.split("=", 1) for line in env_file.read_text().splitlines())

    def test_a_claim_holds_a_slot_whose_tag_names_its_derived_data(self) -> None:
        # The tour builds cmux-<TOUR_TAG>-base and -head: one warm pair per slot on the Mac,
        # whichever pull request it tours.
        claimed = self.claim(slots=2)
        self.assertEqual(claimed, {"TOUR_SLOT": "0", "TOUR_TAG": "ci-media-slot0"})
        # The slot is the tag lock that `hold` and the DerivedData prune take, so neither gets it now.
        held = self.hold("ci-media-slot0", wait=0)
        self.assertEqual(held.returncode, 1, held.stdout)

    def test_concurrent_tours_take_distinct_slots_and_never_wait(self) -> None:
        started = time.monotonic()
        tags = [self.claim(slots=2)["TOUR_TAG"] for _ in range(3)]
        # Past K the tour takes an overflow slot (cold, pruned once idle) instead of waiting
        # for a slot while it holds the runner.
        self.assertEqual(tags, ["ci-media-slot0", "ci-media-slot1", "ci-media-slot2"])
        self.assertLess(time.monotonic() - started, 20)

    def test_racing_claims_never_share_a_slot(self) -> None:
        files = [self.locks / f"race.{n}" for n in range(6)]
        for path in files:
            path.touch()
        racers = [subprocess.Popen([sys.executable, str(SCRIPT), "claim", "--slots", "2", "--lock-dir",
                                    str(self.locks), "--github-env", str(path), "--max-hold", "6"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                  for path in files]
        for racer in racers:
            output, _ = racer.communicate(timeout=60)
            self.assertEqual(racer.returncode, 0, output)
        slots = [dict(line.split("=", 1) for line in path.read_text().splitlines())["TOUR_SLOT"] for path in files]
        self.assertEqual(sorted(slots, key=int), [str(n) for n in range(6)])

    def test_a_freed_slot_is_the_next_tour_s_warm_slot(self) -> None:
        # No Runner.Worker above the test, so a holder lets go after --max-hold.
        self.assertEqual(self.claim(slots=2, max_hold=2)["TOUR_SLOT"], "0")
        self.assertEqual(self.claim(slots=2, max_hold=30)["TOUR_SLOT"], "1")
        deadline = time.monotonic() + 20
        while not self.free("ci-media-slot0"):
            self.assertLess(time.monotonic(), deadline, "slot 0's holder never let go")
            time.sleep(0.5)
        self.assertEqual(self.claim(slots=2)["TOUR_SLOT"], "0")

    def test_the_workflow_tours_in_a_claimed_slot(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text())
        tour = workflow["jobs"]["tour"]
        self.assertNotIn("TOUR_TAG", tour["env"], "the tag comes from the slot, not from the pull request")
        self.assertIn("CMUX_MEDIA_TOUR_SLOTS", tour["env"])
        runs = "\n".join(step.get("run", "") for step in tour["steps"])
        self.assertRegex(runs, r'media_tag_lock\.py"? claim --slots "\$CMUX_MEDIA_TOUR_SLOTS" --github-env "\$GITHUB_ENV"')
        self.assertNotIn(" hold --tag", runs, "a tour never waits for a tag")

    def test_a_tag_that_is_not_a_name_is_refused(self) -> None:
        self.assertEqual(self.hold("../x", wait=0).returncode, 2)


if __name__ == "__main__":
    unittest.main()
