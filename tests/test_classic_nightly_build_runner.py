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

    def test_the_alternate_is_the_other_blacksmith_label_while_it_moves(self) -> None:
        self.assertEqual(picker.alternate(picker.SMALL), picker.LARGE)
        self.assertEqual(picker.alternate(picker.LARGE), picker.SMALL)
        self.assertEqual(picker.alternate(picker.SMALL, snapshot(), NOW), picker.LARGE)
        # Never a label the fresh snapshot saw stalled.
        self.assertEqual(picker.alternate(picker.SMALL, snapshot(large=40), NOW), picker.SMALL)
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
        # Re-run failed jobs on attempt 3 keeps attempt 2's outputs: the snapshot saw 6 vCPU stalled, so the
        # alternate is the pick itself, never the label it saw stalled.
        self.assertEqual(route(fresh, 3), picker.LARGE)
        # A pick made with both moving offers the other label for a re-run.
        self.assertEqual(route(pick(2), 3), picker.LARGE)

def observed(generated: dt.datetime = NOW, **overrides: dict) -> dict:
    """The queue janitor's 2026-10-30 18:37Z snapshot, as of `generated`: both labels stalled by the queue rule,
    blacksmith-12vcpu-macos-26 with nothing running and no start (absent from label_started), 6 vCPU busy."""
    pools = {picker.LARGE: {"queued": 180, "running": 0, "oldest_queued_minutes": 1399},
             picker.SMALL: {"queued": 77, "running": 5, "oldest_queued_minutes": 552}}
    started = {picker.SMALL: (generated - dt.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")}
    for label, entry in overrides.items():
        pools[label] = {**pools[label], **entry}
    return {"generated_at": generated.strftime("%Y-%m-%dT%H:%M:%SZ"), "pools": pools, "label_started": started}


class DeadLabel(unittest.TestCase):
    """A label that started nothing for an hour is dead, not busy: never picked or offered for a re-run while
    another label shows life (2026-10-30: DEV daily verify and tip-dmg-build re-runs queued on 12 vCPU)."""

    def outputs(self, snap, attempt: int = 1, first: str = "6vcpu", **env) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            picker.main({"GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": str(attempt), "FIRST": first,
                         "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r", **env},
                        read_snapshot=lambda token, repo: snap, now=NOW, sleep=lambda seconds: None, clock=Clock())
            return dict(line.split("=", 1) for line in output.read_text().split())

    def test_the_dev_daily_rerun_never_takes_the_dead_label(self) -> None:
        out = self.outputs(observed())
        self.assertEqual((out["cloud"], out["alternate"]), (picker.SMALL, picker.SMALL))

    def test_a_dead_first_label_is_skipped_even_with_its_queue_cleared(self) -> None:
        # The janitor cancelled 12 vCPU's queue: the stall rule sees nothing waiting there, but nothing started.
        snap = observed(**{picker.LARGE: {"queued": 0, "oldest_queued_minutes": 0}})
        self.assertEqual(picker.blacksmith_route(snap, NOW, picker.LARGE)[0], picker.SMALL)
        self.assertEqual(picker.blacksmith_route(snap, NOW, picker.SMALL)[0], picker.SMALL)
        self.assertEqual(picker.alternate(picker.SMALL, snap, NOW), picker.SMALL)

    def test_a_stale_snapshot_still_proves_a_label_dead(self) -> None:
        stale = observed(NOW - dt.timedelta(minutes=50))
        # Too old for the stall rule (the caller passes it as evidence only): 12 vCPU first would be the default.
        self.assertEqual(picker.blacksmith_route(None, NOW, picker.LARGE, stale)[0], picker.SMALL)
        self.assertEqual(picker.alternate(picker.SMALL, None, NOW, stale), picker.SMALL)
        # Past the evidence window it proves nothing: the old defaults hold.
        old = observed(NOW - dt.timedelta(hours=7))
        self.assertEqual(picker.blacksmith_route(None, NOW, picker.LARGE, old)[0], picker.LARGE)
        self.assertEqual(picker.alternate(picker.SMALL, None, NOW, old), picker.LARGE)

    def test_main_reads_a_stale_snapshot_for_dead_labels(self) -> None:
        out = self.outputs(observed(NOW - dt.timedelta(minutes=50)), first="12vcpu")
        self.assertEqual((out["cloud"], out["alternate"]), (picker.SMALL, picker.SMALL))

    def test_a_dead_small_label_gives_way_to_a_busy_large_one(self) -> None:
        snap = observed(**{picker.SMALL: {"running": 0}, picker.LARGE: {"running": 4}})
        snap["label_started"] = {picker.LARGE: snap["label_started"][picker.SMALL]}
        label, why = picker.blacksmith_route(snap, NOW, picker.SMALL)
        self.assertEqual(label, picker.LARGE, why)
        self.assertEqual(picker.alternate(picker.LARGE, snap, NOW), picker.LARGE)

    def test_a_label_that_started_a_job_lately_or_runs_one_is_alive(self) -> None:
        snap = observed()
        snap["label_started"][picker.LARGE] = (NOW - dt.timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertFalse(picker.picker.blacksmith_dead(snap, picker.LARGE, NOW))
        snap["label_started"][picker.LARGE] = (NOW - dt.timedelta(minutes=90)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertTrue(picker.picker.blacksmith_dead(snap, picker.LARGE, NOW))
        self.assertFalse(picker.picker.blacksmith_dead(observed(**{picker.LARGE: {"running": 1}}), picker.LARGE, NOW))

    def test_a_truncated_snapshot_proves_no_label_dead(self) -> None:
        # Its listing missed in-flight runs, so it can miss a running job or a start on the label.
        for flag in (True, "yes", None):
            with self.subTest(truncated=flag):
                snap = dict(observed(NOW - dt.timedelta(minutes=50)), truncated=flag)
                self.assertFalse(picker.picker.blacksmith_dead(snap, picker.LARGE, NOW))
                self.assertEqual(picker.blacksmith_route(None, NOW, picker.LARGE, snap)[0], picker.LARGE)
        complete = dict(observed(NOW - dt.timedelta(minutes=50)), truncated=False)
        self.assertTrue(picker.picker.blacksmith_dead(complete, picker.LARGE, NOW))

    def test_no_label_showing_life_or_no_start_map_changes_nothing(self) -> None:
        both = observed(**{picker.SMALL: {"running": 0}})
        both["label_started"] = {}
        self.assertEqual(picker.blacksmith_route(both, NOW, picker.SMALL)[0], picker.SMALL)
        self.assertEqual(picker.blacksmith_route(None, NOW, picker.LARGE, both)[0], picker.LARGE)
        older_janitor = observed()
        del older_janitor["label_started"]
        self.assertFalse(picker.picker.blacksmith_dead(older_janitor, picker.LARGE, NOW))
        self.assertEqual(picker.blacksmith_route(None, NOW, picker.LARGE, older_janitor)[0], picker.LARGE)


def stamp(moment: dt.datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def both_dead(generated: dt.datetime) -> dict:
    """2026-10-31 05:44Z: blacksmith-12vcpu-macos-26 88 queued, none running, the oldest 1403 min; 6 vCPU had
    started nothing for an hour either, so the snapshot shows both labels dead."""
    snap = observed(generated, **{picker.LARGE: {"queued": 88, "oldest_queued_minutes": 1403},
                                  picker.SMALL: {"running": 0}})
    snap["label_started"] = {picker.SMALL: stamp(generated - dt.timedelta(minutes=70))}
    return snap


class EveryLabelDead(unittest.TestCase):
    """A re-run never takes a label the snapshot or RUNNER_POOLS' `_dead` marks show dead, even when every
    candidate shows dead: dead_macos_26() drops evidence that names both, so a stale snapshot showing both dead
    still offered blacksmith-12vcpu-macos-26 as `alternate` (DEV daily verify and tip-dmg-build re-runs)."""

    outputs = DeadLabel.outputs

    def test_a_stale_snapshot_showing_both_dead_offers_no_dead_alternate(self) -> None:
        stale = both_dead(NOW - dt.timedelta(minutes=50))
        self.assertEqual(picker.dead_labels(stale, NOW), set())
        self.assertEqual(picker.every_dead(stale, NOW), {picker.LARGE, picker.SMALL})
        out = self.outputs(stale)
        self.assertEqual((out["cloud"], out["alternate"]), (picker.SMALL, picker.SMALL))
        # Fresh too: the alternate is never the dead label.
        out = self.outputs(both_dead(NOW))
        self.assertEqual(out["alternate"], out["cloud"])

    def test_dead_is_true_only_when_every_label_shows_dead(self) -> None:
        # cmux-next-dev-daily.yml's tip-deltas skips on it rather than queue on a label that starts nothing.
        self.assertEqual(self.outputs(both_dead(NOW - dt.timedelta(minutes=50)))["dead"], "true")
        self.assertEqual(self.outputs(both_dead(NOW))["dead"], "true")
        pools = {"macos_26": picker.SMALL, "_dead": {picker.LARGE: stamp(NOW)}}
        self.assertEqual(self.outputs(None, RUNNER_POOLS=__import__("json").dumps(pools))["dead"], "false")
        pools["_dead"][picker.SMALL] = stamp(NOW)
        self.assertEqual(self.outputs(None, RUNNER_POOLS=__import__("json").dumps(pools))["dead"], "true")

    def test_runner_pools_marks_count_as_dead(self) -> None:
        pools = {"macos_26": picker.SMALL, "_dead": {picker.LARGE: stamp(NOW - dt.timedelta(minutes=5))}}
        # No snapshot at all: the mark alone keeps the re-run off 12 vCPU and the 12 vCPU-first pick off it.
        self.assertEqual(picker.alternate(picker.SMALL, None, NOW, None, pools), picker.SMALL)
        self.assertEqual(picker.blacksmith_route(None, NOW, picker.LARGE, None, pools)[0], picker.SMALL)
        out = self.outputs(None, first="12vcpu", RUNNER_POOLS=__import__("json").dumps(pools))
        self.assertEqual((out["cloud"], out["alternate"]), (picker.SMALL, picker.SMALL))
        # A mark older than runner_pools.DEAD_TTL, one in the future, or a malformed one proves nothing.
        for since in (stamp(NOW - dt.timedelta(minutes=45)), stamp(NOW + dt.timedelta(hours=1)), "soon", None):
            with self.subTest(since=since):
                old = {"macos_26": picker.SMALL, "_dead": {picker.LARGE: since}}
                self.assertEqual(picker.alternate(picker.SMALL, None, NOW, None, old), picker.LARGE)
        for raw in ("", "not json", "[1]", '{"_dead": []}'):
            with self.subTest(raw=raw):
                self.assertEqual(picker.marked_dead(picker.runner_pools(raw), NOW), set())

    def test_every_label_dead_takes_the_pools_live_member(self) -> None:
        stale = both_dead(NOW - dt.timedelta(minutes=50))
        pools = {"macos_26": picker.SMALL, "_dead": {picker.LARGE: stamp(NOW), picker.SMALL: stamp(NOW)}}
        for first in ("12vcpu", "6vcpu"):
            with self.subTest(first=first):
                self.assertEqual(picker.blacksmith_route(None, NOW, first, stale, pools)[0], picker.SMALL)
                self.assertEqual(picker.blacksmith_route(stale, NOW, first, None, pools)[0], picker.SMALL)
                self.assertEqual(picker.blacksmith_route(None, NOW, first, None, pools)[0], picker.SMALL)
        self.assertEqual(picker.alternate(picker.SMALL, None, NOW, stale, pools), picker.SMALL)
        # A member that is not a candidate is never printed; the caller's order holds.
        odd = {**pools, "macos_26": "blacksmith-6vcpu-macos-15"}
        self.assertEqual(picker.blacksmith_route(None, NOW, picker.LARGE, None, odd)[0], picker.LARGE)
        self.assertEqual(picker.alternate(picker.LARGE, None, NOW, None, odd), picker.LARGE)

    def test_the_mark_ttl_is_the_writers(self) -> None:
        text = (ROOT / "scripts" / "ci" / "runner_pools.py").read_text()
        self.assertIn(f'DEAD_KEY = "{picker.DEAD_KEY}"', text)
        minutes = int(picker.MARK_TTL.total_seconds() // 60)
        self.assertIn(f"DEAD_TTL = dt.timedelta(minutes={minutes})", text)

    def test_every_picker_step_reads_runner_pools(self) -> None:
        for name in ("nightly.yml", "cmux-next-dev-daily.yml"):
            text = (ROOT / ".github" / "workflows" / name).read_text()
            steps = re.findall(r"env:\n((?:          .*\n)+?)        run: python3 scripts/ci/classic_nightly_build_runner.py\n",
                               text)
            with self.subTest(workflow=name):
                self.assertTrue(steps)
                for env in steps:
                    self.assertIn("RUNNER_POOLS: ${{ vars.RUNNER_POOLS }}", env)


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
                         {"trusted": "true", "cloud": picker.LARGE, "alternate": picker.SMALL, "attempt": "1",
                          "dead": "false"})
        self.assertEqual(self.run_main({}, [runner(POOL, RUNNER, status="offline")], snapshot(large=30)),
                         {"trusted": "false", "cloud": picker.SMALL, "alternate": picker.SMALL, "attempt": "1",
                          "dead": "false"})

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

    def test_dev_daily_reads_every_dead_label(self) -> None:
        text = (ROOT / ".github" / "workflows" / "cmux-next-dev-daily.yml").read_text(encoding="utf-8")
        runner = text[text.index("\n  runner:\n"):text.index("\n  verify:\n")]
        self.assertIn("cloud_dead: ${{ steps.cloud.outputs.dead }}", runner)
        pool = runner[runner.index("id: pool"):]
        self.assertIn("RUNNER_POOLS: ${{ vars.RUNNER_POOLS }}", pool)
        deltas = text[text.index("\n  tip-deltas:\n"):]
        condition = re.search(r"^    if: (.+)$", deltas, re.MULTILINE).group(1)
        self.assertIn("needs.runner.outputs.cloud_dead != 'true'", condition)

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
