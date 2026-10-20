#!/usr/bin/env python3
"""scripts/ci/media_tag_lock.py: a tour holds its tag after `hold` returns, a second
tour of that tag waits until the holder's job ends, and other tags never wait.

`claim` gives each concurrent tour on a Mac a slot of its own (tag ci-media-slot<N>),
so a Mac keeps K warm DerivedData pairs however many pull requests it tours.

Each hold here is tied with --worker-pid to a stand-in for the job's Runner.Worker
(a sleep the test kills), so a holder lets go exactly when the test says, whether
or not a real Runner.Worker runs above the test and however loaded the machine is."""

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
        self.workers: list[subprocess.Popen[bytes]] = []
        self.job = self.worker()

    def tearDown(self) -> None:
        for worker in self.workers:
            self.end(worker)
        self.temp.cleanup()

    def worker(self) -> subprocess.Popen[bytes]:
        """A stand-in for a job's Runner.Worker: a hold tied to it lasts until end() kills it."""
        started = subprocess.Popen(["sleep", "600"])
        self.workers.append(started)
        return started

    @staticmethod
    def end(worker: subprocess.Popen[bytes]) -> None:
        worker.kill()
        worker.wait()

    def hold_args(self, tag: str, wait: float, worker: subprocess.Popen[bytes] | None) -> list[str]:
        return [sys.executable, str(SCRIPT), "hold", "--tag", tag, "--lock-dir", str(self.locks),
                "--wait", str(wait), "--max-hold", "600", "--worker-pid", str((worker or self.job).pid)]

    def hold(self, tag: str, wait: float,
             worker: subprocess.Popen[bytes] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(self.hold_args(tag, wait, worker), capture_output=True, text=True, timeout=60)

    def until_free(self, tag: str, why: str) -> None:
        deadline = time.monotonic() + 60
        while not self.free(tag):
            self.assertLess(time.monotonic(), deadline, why)
            time.sleep(0.2)

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
        first_job = self.worker()
        self.assertEqual(self.hold("ci-media-feat-cmux-next", wait=1, worker=first_job).returncode, 0)
        later = subprocess.Popen(self.hold_args("ci-media-feat-cmux-next", 120, None),
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            self.assertIn("waiting for", later.stdout.readline())
            # The first tour's job ends: its holder sees the worker gone and lets go.
            self.end(first_job)
            output, _ = later.communicate(timeout=90)
        finally:
            later.kill()
            later.wait()
        self.assertEqual(later.returncode, 0, output)
        self.assertIn("holding", output)

    def test_without_a_worker_a_hold_ends_after_max_hold(self) -> None:
        # A lost job never keeps a tag: with no worker to watch the holder lets go after --max-hold.
        done = subprocess.run([sys.executable, str(SCRIPT), "hold", "--tag", "ci-media-pr-1", "--lock-dir",
                               str(self.locks), "--wait", "0", "--max-hold", "1", "--worker-pid", "0"],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("held for at most 1s", done.stdout)
        self.until_free("ci-media-pr-1", "a hold with no worker outlived --max-hold")

    def test_a_worker_pid_is_a_process_id(self) -> None:
        done = subprocess.run([sys.executable, str(SCRIPT), "claim", "--lock-dir", str(self.locks),
                               "--worker-pid", "-1"], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)

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

    def claim_args(self, slots: int, env_file: Path, worker: subprocess.Popen[bytes] | None) -> list[str]:
        return [sys.executable, str(SCRIPT), "claim", "--slots", str(slots), "--lock-dir", str(self.locks),
                "--github-env", str(env_file), "--max-hold", "600", "--worker-pid", str((worker or self.job).pid)]

    def claim(self, slots: int, worker: subprocess.Popen[bytes] | None = None) -> dict[str, str]:
        """Run `claim` and return what it wrote to GITHUB_ENV (empty when it failed)."""
        env_file = self.locks / f"github_env.{time.monotonic_ns()}"
        env_file.touch()
        done = subprocess.run(self.claim_args(slots, env_file, worker), capture_output=True, text=True, timeout=60)
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
        # Every racer's job outlives the race, so no slot is freed mid-race however slowly the racers start.
        racers = [subprocess.Popen(self.claim_args(2, path, None), stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
                  for path in files]
        for racer in racers:
            output, _ = racer.communicate(timeout=60)
            self.assertEqual(racer.returncode, 0, output)
        slots = [dict(line.split("=", 1) for line in path.read_text().splitlines())["TOUR_SLOT"] for path in files]
        self.assertEqual(sorted(slots, key=int), [str(n) for n in range(6)])

    def test_a_freed_slot_is_the_next_tour_s_warm_slot(self) -> None:
        first_job = self.worker()
        self.assertEqual(self.claim(slots=2, worker=first_job)["TOUR_SLOT"], "0")
        self.assertEqual(self.claim(slots=2)["TOUR_SLOT"], "1")
        self.end(first_job)
        self.until_free("ci-media-slot0", "slot 0's holder never let go after its job ended")
        self.assertEqual(self.claim(slots=2)["TOUR_SLOT"], "0")
        # Slot 1's job is still running, so its slot stays taken.
        self.assertFalse(self.free("ci-media-slot1"))

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
