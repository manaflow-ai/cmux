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


class FirstAndAlternate(unittest.TestCase):
    def test_first_puts_the_six_vcpu_label_ahead_while_it_moves(self) -> None:
        now = NOW
        self.assertEqual(picker.blacksmith_route(None, now, picker.SMALL)[0], picker.SMALL)
        self.assertEqual(picker.blacksmith_route(snapshot(), now, picker.SMALL)[0], picker.SMALL)
        # The 2026-10-27 12:03-12:46Z case: 6 vCPU stalled, 12 vCPU moving.
        self.assertEqual(picker.blacksmith_route(snapshot(small=52), now, picker.SMALL)[0], picker.LARGE)
        # A size names the same label.
        self.assertEqual(picker.blacksmith_route(None, now, "6vcpu")[0], picker.SMALL)
        self.assertEqual(picker.blacksmith_route(snapshot(small=52), now, "6vcpu")[0], picker.LARGE)
        self.assertEqual(picker.blacksmith_route(snapshot(), now, "12vcpu")[0], picker.LARGE)
        # Only an exact size counts: a fragment of a label changes nothing.
        for fragment in ("6vcpu-macos", "macos", "6vcpu-macos-26", "vcpu"):
            self.assertEqual(picker.candidates(fragment), picker.CANDIDATES, fragment)
        # A label that is not a candidate changes nothing.
        self.assertEqual(picker.blacksmith_route(None, now, "glaeda-std-xcode-26.6")[0], picker.LARGE)

    def test_the_alternate_is_always_the_other_blacksmith_label(self) -> None:
        self.assertEqual(picker.alternate(picker.SMALL), picker.LARGE)
        self.assertEqual(picker.alternate(picker.LARGE), picker.SMALL)
        self.assertTrue(all(label.startswith("blacksmith-") for label in picker.CANDIDATES))

    def test_successive_reruns_never_return_to_the_label_that_stalled(self) -> None:
        """A consumer's runs-on: attempt > 1 and an older pick -> alternate, else the pick."""
        def route(outputs: dict, attempt: int) -> str:
            if attempt > 1 and outputs["attempt"] != str(attempt):
                return outputs["alternate"]
            return outputs["cloud"]

        def pick(attempt: int, **stalled: float) -> dict:
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "out"
                picker.main({"GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": str(attempt), "FIRST": "6vcpu",
                             "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r"},
                            read_snapshot=lambda token, repo: snapshot(**stalled), now=NOW,
                            sleep=lambda seconds: None, clock=Clock())
                return dict(line.split("=", 1) for line in output.read_text().split())

        # Attempt 1 picks 6 vCPU; it stalls; re-run failed jobs (attempt 2) keeps the outputs.
        first = pick(1)
        self.assertEqual((route(first, 1), route(first, 2)), (picker.SMALL, picker.LARGE))
        # Re-run all jobs on attempt 2 with 6 vCPU stalled: a fresh pick of 12 vCPU, taken as is.
        fresh = pick(2, small=52)
        self.assertEqual(route(fresh, 2), picker.LARGE)
        # 12 vCPU then stalls; re-run failed jobs on attempt 3 keeps attempt 2's outputs and leaves it.
        self.assertEqual(route(fresh, 3), picker.SMALL)

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
                         {"trusted": "true", "cloud": picker.LARGE, "alternate": picker.SMALL, "attempt": "1"})
        self.assertEqual(self.run_main({}, [runner(POOL, RUNNER, status="offline")], snapshot(large=30)),
                         {"trusted": "false", "cloud": picker.SMALL, "alternate": picker.LARGE, "attempt": "1"})

    def test_a_failing_read_never_fails_the_job(self) -> None:
        def boom(token, repo):
            raise RuntimeError("403")
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "out"
            picker.main({"GITHUB_REPOSITORY": "o/r", "ROUTE_TOKEN": "t", "SNAPSHOT_TOKEN": "s", "TRUSTED_POOL": POOL,
                         "TRUSTED_RUNNER": RUNNER, "ENABLED": "1", "GITHUB_OUTPUT": str(out)},
                        read_runners=boom, read_snapshot=boom, now=NOW)
            self.assertIn(f"cloud={picker.LARGE}", out.read_text())


class Prepare(unittest.TestCase):
    """`prepare`: prepare-nightly-variant takes the pinned mini only while it is idle now."""

    def run_prepare(self, runners, **env):
        clock = Clock()
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "out"
            read = runners if callable(runners) else (lambda token, repo: runners)
            picker.main({"GITHUB_REPOSITORY": "o/r", "ROUTE_TOKEN": "t", "TRUSTED_POOL": POOL, "TRUSTED_RUNNER": RUNNER,
                         "ENABLED": "1", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": str(out), **env},
                        argv=["prepare"], read_runners=read, read_snapshot=lambda token, repo: None,
                        now=NOW, sleep=clock.sleep, clock=clock)
            return out.read_text(), clock.at

    def test_an_idle_mini_takes_the_prepare_legs(self) -> None:
        self.assertEqual(self.run_prepare([runner(POOL, RUNNER)]), ("trusted=true\n", 0))

    def test_busy_offline_unread_off_or_a_rerun_keep_blacksmith_with_no_wait(self) -> None:
        def boom(token, repo):
            raise RuntimeError("403")
        cases = {"busy": ([runner(POOL, RUNNER, busy=True)], {}),
                 "offline": ([runner(POOL, RUNNER, status="offline")], {}),
                 "unread": (boom, {}),
                 "off": ([runner(POOL, RUNNER)], {"ENABLED": "0"}),
                 "rerun": ([runner(POOL, RUNNER)], {"GITHUB_RUN_ATTEMPT": "2"})}
        for name, (runners, env) in cases.items():
            with self.subTest(name):
                self.assertEqual(self.run_prepare(runners, **env), ("trusted=false\n", 0))


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

    def test_prepare_takes_the_pinned_mini_only_on_the_prepare_pick(self) -> None:
        job = self.job("prepare-nightly-variant")
        runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
        self.assertIn("pick-classic-prepare-runner", re.search(r"^    needs: (.+)$", job, re.MULTILINE).group(1))
        self.assertIn("github.run_attempt == 1 && vars.CI_SEED_TRUSTED_POOL != '' && vars.CI_NIGHTLY_TRUSTED_RUNNER != '' "
                      "&& needs.pick-classic-prepare-runner.outputs.trusted == 'true' && fromJSON(", runs_on)
        self.assertTrue(runs_on.endswith("|| needs.pick-classic-sign-runner.outputs.runner || 'blacksmith-6vcpu-macos-26' }}"))
        self.assertNotIn("secrets.", job)
        self.assertNotIn("environment:", job)
        pick = self.job("pick-classic-prepare-runner")
        self.assertIn("run: python3 scripts/ci/classic_nightly_build_runner.py prepare", pick)
        self.assertIn("github.ref == 'refs/heads/main'", pick)
        # Signing and verify keep the Blacksmith-only pick.
        for name in ("build-sign-notarize-nightly", "verify-signed-nightly"):
            self.assertNotIn("pick-classic-prepare-runner", self.job(name))

    def test_the_picker_runs_on_linux_and_never_fails(self) -> None:
        for name in ("pick-nightly-app-runner", "pick-classic-prepare-runner"):
            with self.subTest(name):
                self.check_picker(name)

    def check_picker(self, name: str) -> None:
        job = self.job(name)
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
