#!/usr/bin/env python3
"""main's nightly build-nightly-app: the pinned trusted mini only while it can take the build.

scripts/ci/classic_nightly_build_runner.py, and the runs-on in nightly.yml that reads it.
"""

from __future__ import annotations

import datetime as dt
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import classic_nightly_build_runner as picker  # noqa: E402

POOL, RUNNER = "glaeda-trusted-std-xcode-26.6", "glaeda-runner-mini-a"
NOW = dt.datetime(2026, 10, 27, 12, 0, tzinfo=dt.timezone.utc)


def runner(*labels: str, status: str = "online", busy: bool = False) -> dict:
    return {"status": status, "busy": busy, "labels": [{"name": label} for label in labels]}


def snapshot(**oldest: float) -> dict:
    pools = {label: {"queued": 3, "oldest_queued_minutes": minutes} for label, minutes in
             ((picker.LARGE, oldest.get("large", 0)), (picker.SMALL, oldest.get("small", 0)))}
    return {"generated_at": NOW.isoformat(), "pools": pools}


class Clock:
    def __init__(self) -> None:
        self.at = 0.0

    def __call__(self) -> float:
        return self.at

    def sleep(self, seconds: float) -> None:
        self.at += seconds


class TrustedRoute(unittest.TestCase):
    def route(self, reads, enabled=True, attempt="1", pool=POOL, name=RUNNER):
        clock = Clock()
        reads = iter(reads)
        return picker.trusted_route(pool, name, lambda: next(reads), enabled, attempt,
                                    sleep=clock.sleep, clock=clock), clock.at

    def test_an_idle_pinned_runner_keeps_the_build(self) -> None:
        (trusted, _), waited = self.route([[runner(POOL, RUNNER)]])
        self.assertTrue(trusted)
        self.assertEqual(waited, 0)

    def test_a_busy_runner_is_waited_on_then_left(self) -> None:
        busy = [runner(POOL, RUNNER, busy=True)]
        (trusted, why), waited = self.route([busy] * 100)
        self.assertFalse(trusted)
        self.assertIn("stayed busy", why)
        self.assertLessEqual(waited, picker.WAIT_SECONDS)

    def test_a_runner_that_frees_up_inside_the_wait_keeps_the_build(self) -> None:
        busy, idle = [runner(POOL, RUNNER, busy=True)], [runner(POOL, RUNNER)]
        (trusted, _), waited = self.route([busy, busy, idle])
        self.assertTrue(trusted)
        self.assertEqual(waited, 2 * picker.LOOK_SECONDS)

    def test_an_offline_runner_goes_to_the_cloud_at_once(self) -> None:
        (trusted, why), waited = self.route([[runner(POOL, RUNNER, status="offline")]])
        self.assertFalse(trusted)
        self.assertIn("offline", why)
        self.assertEqual(waited, 0)

    def test_only_a_runner_with_both_labels_counts(self) -> None:
        # An idle runner in the trusted pool that is not the pinned one, or the pinned name alone.
        for runners in ([runner(POOL, "glaeda-runner-other")], [runner(RUNNER)], [runner("glaeda-std-xcode-26.6", RUNNER)]):
            with self.subTest(runners=runners):
                (trusted, _), _ = self.route([runners])
                self.assertFalse(trusted)

    def test_an_unreadable_runner_list_keeps_the_pinned_pair(self) -> None:
        (trusted, why), _ = self.route([None])
        self.assertTrue(trusted)
        self.assertIn("could not be read", why)

    def test_off_later_attempts_and_bad_variables_never_ask_for_the_mini(self) -> None:
        idle = [[runner(POOL, RUNNER)]]
        self.assertFalse(self.route(idle, enabled=False)[0][0])
        self.assertFalse(self.route(idle, attempt="2")[0][0])
        for pool, name in (("", RUNNER), (POOL, ""), ("glaeda-std-xcode-26.6", RUNNER), (POOL, "cmux15-glaeda")):
            with self.subTest(pool=pool, name=name):
                self.assertFalse(self.route(idle, pool=pool, name=name)[0][0])


class CloudRoute(unittest.TestCase):
    def test_no_snapshot_keeps_the_old_default(self) -> None:
        self.assertEqual(picker.blacksmith_route(None, NOW)[0], picker.LARGE)

    def test_a_stalled_large_label_is_skipped(self) -> None:
        self.assertEqual(picker.blacksmith_route(snapshot(large=40), NOW)[0], picker.SMALL)
        self.assertEqual(picker.blacksmith_route(snapshot(large=2), NOW)[0], picker.LARGE)

    def test_snapshot_age_counts_toward_the_stall(self) -> None:
        later = NOW + dt.timedelta(minutes=9)
        self.assertEqual(picker.blacksmith_route(snapshot(large=2), later)[0], picker.SMALL)

    def test_both_stalled_takes_the_label_with_more_slots(self) -> None:
        self.assertEqual(picker.blacksmith_route(snapshot(large=40, small=40), NOW)[0], picker.SMALL)


class Main(unittest.TestCase):
    def run_main(self, env, runners, snap):
        clock = Clock()
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "out"
            env = {"GITHUB_REPOSITORY": "o/r", "ROUTE_TOKEN": "t", "SNAPSHOT_TOKEN": "s", "TRUSTED_POOL": POOL,
                   "TRUSTED_RUNNER": RUNNER, "ENABLED": "1", "GITHUB_RUN_ATTEMPT": "1",
                   "GITHUB_OUTPUT": str(out), **env}
            picker.main(env, read_runners=lambda token, repo: runners, read_snapshot=lambda token, repo: snap,
                        now=NOW, sleep=clock.sleep, clock=clock)
            return dict(line.split("=", 1) for line in out.read_text().split())

    def test_outputs(self) -> None:
        self.assertEqual(self.run_main({}, [runner(POOL, RUNNER)], snapshot()),
                         {"trusted": "true", "cloud": picker.LARGE})
        self.assertEqual(self.run_main({}, [runner(POOL, RUNNER, status="offline")], snapshot(large=30)),
                         {"trusted": "false", "cloud": picker.SMALL})

    def test_a_failing_read_never_fails_the_job(self) -> None:
        def boom(token, repo):
            raise RuntimeError("403")
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "out"
            picker.main({"GITHUB_REPOSITORY": "o/r", "ROUTE_TOKEN": "t", "SNAPSHOT_TOKEN": "s", "TRUSTED_POOL": POOL,
                         "TRUSTED_RUNNER": RUNNER, "ENABLED": "1", "GITHUB_OUTPUT": str(out)},
                        read_runners=boom, read_snapshot=boom, now=NOW)
            self.assertIn(f"cloud={picker.LARGE}", out.read_text())


class WallClock(unittest.TestCase):
    def test_the_wait_is_counted_once_without_an_injected_now(self) -> None:
        # Busy for the whole wait; a snapshot made at the start shows 12 vCPU moving (oldest 4 min).
        # Read after the 5-min wait its oldest job has waited 9 min, under the 10-min stall rule; counting
        # the wait twice (14 min) would wrongly call it stalled. The wall clock moves with the fake clock.
        clock = Clock()
        start = NOW
        snap = {"generated_at": start.isoformat(), "pools": {picker.LARGE: {"queued": 1, "oldest_queued_minutes": 4}}}
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "out"
            picker.main({"GITHUB_REPOSITORY": "o/r", "ROUTE_TOKEN": "t", "SNAPSHOT_TOKEN": "s", "TRUSTED_POOL": POOL,
                         "TRUSTED_RUNNER": RUNNER, "ENABLED": "1", "GITHUB_OUTPUT": str(out)},
                        read_runners=lambda token, repo: [runner(POOL, RUNNER, busy=True)],
                        read_snapshot=lambda token, repo: snap, sleep=clock.sleep, clock=clock,
                        wall=lambda: start + dt.timedelta(seconds=clock()))
            self.assertIn(f"cloud={picker.LARGE}", out.read_text())
            self.assertIn("trusted=false", out.read_text())


class Workflow(unittest.TestCase):
    TEXT = (ROOT / ".github" / "workflows" / "nightly.yml").read_text(encoding="utf-8")

    def job(self, name: str) -> str:
        start = self.TEXT.index(f"\n  {name}:\n")
        following = re.search(r"\n  [A-Za-z0-9_-]+:\n", self.TEXT[start + 1:])
        return self.TEXT[start: start + 1 + following.start()] if following else self.TEXT[start:]

    def test_the_build_reads_the_picker_and_keeps_a_literal_fallback(self) -> None:
        job = self.job("build-nightly-app")
        runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
        self.assertIn("pick-nightly-app-runner", re.search(r"^    needs: (.+)$", job, re.MULTILINE).group(1))
        self.assertIn("needs.pick-nightly-app-runner.outputs.trusted != 'false' && fromJSON(", runs_on)
        self.assertIn("|| needs.pick-nightly-app-runner.outputs.cloud || 'blacksmith-12vcpu-macos-26' }}", runs_on)
        # A failed or skipped picker never skips the build.
        self.assertRegex(re.search(r"^    if: (.+)$", job, re.MULTILINE).group(1), r"^\"!cancelled\(\) && needs\.decide\.result == 'success'")

    def test_the_picker_runs_on_linux_and_never_fails(self) -> None:
        job = self.job("pick-nightly-app-runner")
        self.assertIn("'blacksmith-2vcpu-ubuntu-2404'", job)
        self.assertNotIn("macos", re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1).split("||")[-1])
        # Every step continues on error and their budgets fit inside the job's, so the job ends green.
        steps = job[job.index("    steps:"):]
        names = re.findall(r"^      - name: ", steps, re.MULTILINE)
        self.assertEqual(steps.count("continue-on-error: true"), len(names))
        budgets = [int(value) for value in re.findall(r"^        timeout-minutes: (\d+)$", steps, re.MULTILINE)]
        self.assertEqual(len(budgets), len(names))
        self.assertLess(sum(budgets), int(re.search(r"^    timeout-minutes: (\d+)$", job, re.MULTILINE).group(1)))
        step = job[job.index("id: pick"):]
        self.assertIn("continue-on-error: true", step[:200])
        self.assertIn("scripts/ci/classic_nightly_build_runner.py", step)


if __name__ == "__main__":
    unittest.main()
