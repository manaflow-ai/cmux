#!/usr/bin/env python3
"""Behavior tests for the live per-label macOS pool rule."""

from __future__ import annotations

import dataclasses
import importlib.util
import json
import sys
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("simple_pool_picker", ROOT / "scripts/ci/simple_pool_picker.py")
assert spec and spec.loader
picker = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = picker
spec.loader.exec_module(picker)


def pool(label: str, capacity: int, running: int = 0, queued: int = 0, *, reserved: int = 0,
         free: int | None = None, xcode_app: str = ""):
    return picker.Pool(label, capacity, running, queued, free=free, reserved=reserved, xcode_app=xcode_app)


class PickRuleTests(unittest.TestCase):
    def test_table_driven_rule(self):
        cases = [
            (
                "2026-09-30 12vcpu full with 100 queued, 6vcpu-26 idle",
                picker.State(
                    jobs=1,
                    blacksmith=(pool(picker.BLACKSMITH[0], 5, 5, 100), pool(picker.BLACKSMITH[1], 10), pool(picker.BLACKSMITH[2], 10)),
                ),
                picker.BLACKSMITH[1],
            ),
            (
                "owned free slots win",
                picker.State(jobs=2, owned=(pool("glaeda-std-xcode-26.6", 8, free=2),),
                             blacksmith=(pool(picker.BLACKSMITH[0], 5),), owned_enabled=True),
                "glaeda-std-xcode-26.6",
            ),
            (
                "forks use an ephemeral Blacksmith pool",
                picker.State(jobs=1, fork=True, owned=(pool("glaeda-std-xcode-26.6", 8, free=8),),
                             blacksmith=(pool(picker.BLACKSMITH[0], 5),), owned_enabled=True),
                picker.BLACKSMITH[0],
            ),
            (
                "queued release consumes only its slots",
                picker.State(jobs=1, blacksmith=(pool(picker.BLACKSMITH[0], 5, reserved=1),
                                                 pool(picker.BLACKSMITH[1], 10))),
                picker.BLACKSMITH[0],
            ),
            (
                "all full uses the lowest queued plus running ratio",
                picker.State(jobs=1, blacksmith=(pool(picker.BLACKSMITH[0], 5, 5, 1),
                                                 pool(picker.BLACKSMITH[1], 10, 10, 0),
                                                 pool(picker.BLACKSMITH[2], 10, 10, 5))),
                picker.BLACKSMITH[1],
            ),
        ]
        for name, state, expected in cases:
            with self.subTest(name=name):
                self.assertEqual(picker.pick(state).label, expected)

    def test_ties_follow_blacksmith_order(self):
        state = picker.State(jobs=1, blacksmith=tuple(pool(label, picker.BLACKSMITH_CAPACITY[label],
                                                         picker.BLACKSMITH_CAPACITY[label]) for label in picker.BLACKSMITH))
        self.assertEqual(picker.pick(state).label, picker.BLACKSMITH[0])

    def test_owned_capacity_uses_free_not_queue(self):
        state = picker.State(jobs=3, owned=(pool("glaeda-std-xcode-26.6", 8, running=5, queued=20),),
                             blacksmith=(pool(picker.BLACKSMITH[0], 5),), owned_enabled=True)
        self.assertEqual(picker.pick(state).label, "glaeda-std-xcode-26.6")

    def test_gui_required_skips_aws_owned_pool(self):
        state = picker.State(
            jobs=1,
            owned=(pool("glaeda-aws-std-xcode-26.6", 5, free=5),),
            blacksmith=(pool(picker.BLACKSMITH[1], 10),),
            owned_enabled=True,
            gui_required=True,
        )
        choice = picker.pick(state)
        self.assertEqual(choice.label, picker.BLACKSMITH[1])
        self.assertFalse(choice.owned)

    def test_gui_required_prefers_a_gui_capable_mini_over_aws(self):
        state = picker.State(
            jobs=1,
            owned=(
                pool("glaeda-aws-std-xcode-26.6", 5, free=5),
                pool("glaeda-std-xcode-26.6", 5, free=5),
            ),
            blacksmith=(pool(picker.BLACKSMITH[1], 10),),
            owned_enabled=True,
            gui_required=True,
        )
        self.assertEqual(picker.pick(state).label, "glaeda-std-xcode-26.6")

    def test_owned_retry_uses_matching_blacksmith_xcode(self):
        state = picker.State(
            jobs=1,
            owned=(pool("glaeda-aws-std-xcode-26.3", 5, free=5,
                        xcode_app="/Applications/Xcode_26.3.app"),),
            blacksmith=(
                pool(picker.BLACKSMITH[0], 5, xcode_app="/Applications/Xcode_26.6.app"),
                pool(picker.BLACKSMITH[2], 10, xcode_app="/Applications/Xcode_26.3.app"),
            ),
            owned_enabled=True,
        )
        choice = picker.pick(state)
        self.assertEqual(choice.label, "glaeda-aws-std-xcode-26.3")
        self.assertEqual(choice.retry_label, picker.BLACKSMITH[2])


class NeverQueueBehindBlacksmithTests(unittest.TestCase):
    """Minis first; Blacksmith only while a label has a free, moving slot; else the fleet's queue.

    2026-10-20: blacksmith-12vcpu-macos-26 (5 runners) queued 5+ hours, about 95 PRs behind 318 runs.
    """

    FULL = (pool(picker.BLACKSMITH[0], 5, 5, 1), pool(picker.BLACKSMITH[1], 10, 10, 0),
            pool(picker.BLACKSMITH[2], 10, 10, 5))

    def state(self, blacksmith, **kwargs):
        defaults = dict(jobs=2, owned=(pool("glaeda-std-xcode-26.6", 8, running=8, free=0, queued=1),
                                       pool("glaeda-light-xcode-26.6", 4, free=1, queued=1)),
                        blacksmith=blacksmith, owned_enabled=True, wait_on_owned=True)
        defaults.update(kwargs)
        return picker.State(**defaults)

    def test_a_full_fleet_and_full_blacksmith_wait_on_the_owned_label(self):
        choice = picker.pick(self.state(self.FULL))
        self.assertEqual(choice.label, "glaeda-std-xcode-26.6")
        self.assertTrue(choice.owned)
        # retry_runner stays Blacksmith: ci-macos.yml sends it the jobs the minis cannot run.
        self.assertTrue(choice.retry_label.startswith("blacksmith-"))
        self.assertTrue(picker.write_outputs(choice, 2)["retry_runner"].startswith("blacksmith-"))

    def test_a_free_blacksmith_slot_still_takes_the_overflow(self):
        free = (pool(picker.BLACKSMITH[0], 5, 3), *self.FULL[1:])
        self.assertEqual(picker.pick(self.state(free)).label, picker.BLACKSMITH[0])

    def test_an_owned_pick_retries_on_a_free_blacksmith_label_first(self):
        state = self.state((self.FULL[0], pool(picker.BLACKSMITH[1], 10, 2), self.FULL[2]),
                           owned=(pool("glaeda-std-xcode-26.6", 8, free=4),))
        self.assertEqual(picker.pick(state).retry_label, picker.BLACKSMITH[1])

    def test_an_old_queued_macos_26_job_with_nothing_starting_waits_on_the_fleet(self):
        """DEV publish 40454509260: the oldest macOS 26 job had waited past BLACKSMITH_STALL_MINUTES with
        runners busy, so the label is no room; a wait_on_owned pick waits on the fleet."""
        snapshot = {"generated_at": "2000-01-01T00:00:00Z", "pools": {
            picker.BLACKSMITH[1]: {"queued": 4, "running": 3, "oldest_queued_minutes": 11}}}
        with mock.patch.object(picker, "snapshot_age", return_value=0.0):
            base = picker.state_from(jobs=2, env={}, fork=False, runners=None, snapshot=snapshot,
                                     fallback=picker.BLACKSMITH[1], owned_enabled=True)
        mac26 = next(p for p in base.blacksmith if p.label == picker.BLACKSMITH[1])
        self.assertTrue(mac26.stalled)
        self.assertEqual(mac26.unreserved_available, 0)
        state = self.state((mac26,))
        choice = picker.pick(state)
        self.assertEqual(choice.label, "glaeda-std-xcode-26.6")
        self.assertTrue(choice.owned)
        # A young queue on a label with room still takes Blacksmith.
        young = dataclasses.replace(mac26, stalled=False, waited=picker.BLACKSMITH_STALL_MINUTES - 1)
        self.assertEqual(picker.pick(self.state((young,))).label, picker.BLACKSMITH[1])

    def test_a_stalled_macos_26_label_beside_a_free_macos_15_slot_picks_macos_15(self):
        """2026-10-27 06:13Z: macOS 26 queued 50 min with nothing starting and a macOS 15 slot free."""
        pools = {picker.BLACKSMITH[0]: {"queued": 3, "running": 4, "oldest_queued_minutes": 50},
                 picker.BLACKSMITH[1]: {"queued": 3, "running": 4, "oldest_queued_minutes": 50},
                 picker.BLACKSMITH[2]: {"queued": 0, "running": 1}}
        with mock.patch.object(picker, "snapshot_age", return_value=0.0):
            state = picker.state_from(jobs=1, env={}, fork=False, runners=None, fallback=picker.BLACKSMITH[1],
                                      snapshot={"generated_at": "2000-01-01T00:00:00Z", "pools": pools},
                                      owned_enabled=False)
        self.assertEqual(picker.pick(state).label, picker.BLACKSMITH[2])
        self.assertEqual(picker.BLACKSMITH_STALL_MINUTES, 10)
        self.assertFalse(picker.blacksmith_stalled(2, picker.BLACKSMITH_STALL_MINUTES - 1))
        self.assertTrue(picker.blacksmith_stalled(2, picker.BLACKSMITH_STALL_MINUTES))

    def test_a_stalled_blacksmith_label_has_no_free_slot(self):
        stalled = dataclasses.replace(pool(picker.BLACKSMITH[1], 10, 0, 3), stalled=True)
        choice = picker.pick(self.state((self.FULL[0], stalled, self.FULL[2])))
        self.assertEqual(choice.label, "glaeda-std-xcode-26.6")
        self.assertTrue(picker.stalled(queued=2, running=4, oldest_queued_minutes=picker.STALL_MINUTES))
        self.assertTrue(picker.stalled(queued=1, running=0, oldest_queued_minutes=picker.IDLE_STALL_MINUTES))
        self.assertTrue(picker.stalled(queued=1, running=3, oldest_queued_minutes=6, age=4))
        self.assertFalse(picker.stalled(queued=1, running=3, oldest_queued_minutes=9))
        self.assertFalse(picker.stalled(queued=0, running=0, oldest_queued_minutes=90))

    def test_the_snapshot_marks_a_stalled_label(self):
        state = picker.state_from(jobs=1, env={}, fork=False, runners=None, fallback=picker.BLACKSMITH[1],
                                  owned_enabled=False, snapshot={"generated_at": "", "pools": {
                                      picker.BLACKSMITH[1]: {"queued": 2, "running": 0, "oldest_queued_minutes": 9}}})
        by_label = {item.label: item for item in state.blacksmith}
        self.assertTrue(by_label[picker.BLACKSMITH[1]].stalled)
        self.assertFalse(by_label[picker.BLACKSMITH[0]].stalled)

    def test_only_a_rescued_head_waits_on_the_fleet(self):
        # A trusted fork (CI_PR_POOL_FORK_ALLOWED) may take a free mini, but owned_pool_rescue never
        # rescues a fork head, and the bot's re-run already waited once: both keep the old rule.
        choice = picker.pick(self.state(self.FULL, wait_on_owned=False))
        self.assertEqual(choice.label, picker.BLACKSMITH[1])
        self.assertFalse(choice.owned)
        repo = "manaflow-ai/cmux"
        self.assertTrue(picker.wait_on_owned({}, head=repo, repository=repo))
        self.assertTrue(picker.wait_on_owned({"GITHUB_RUN_ATTEMPT": "2", "GITHUB_TRIGGERING_ACTOR": "lawrencecchen"},
                                             head=repo, repository=repo))
        self.assertFalse(picker.wait_on_owned({}, head="teamleaderleo/cmux", repository=repo))
        self.assertFalse(picker.wait_on_owned({"GITHUB_RUN_ATTEMPT": "2", "GITHUB_TRIGGERING_ACTOR": "github-actions[bot]"},
                                              head=repo, repository=repo))
        self.assertFalse(picker.wait_on_owned({}, head="", repository=""))

    def test_main_passes_the_wait_gate_for_a_trusted_fork(self):
        seen = {}
        original = picker.observe
        picker.observe = lambda **kwargs: seen.update(kwargs) or picker.State(jobs=0)
        try:
            picker.main([], {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "HEAD_REPO": "teamleaderleo/cmux",
                             "CI_PR_POOL_FORK_ALLOWED": "1", "RUN_JOBS": "2"})
        finally:
            picker.observe = original
        self.assertEqual((seen["fork"], seen["wait_owned"]), (False, False))

    def test_a_pool_with_no_online_runner_is_no_queue_to_wait_in(self):
        state = self.state(self.FULL, owned=(pool("glaeda-std-xcode-26.6", 0, free=0),
                                             pool("glaeda-light-xcode-26.6", 4, free=0, queued=2)))
        self.assertEqual(picker.pick(state).label, "glaeda-light-xcode-26.6")
        state = self.state(self.FULL, owned=(pool("glaeda-std-xcode-26.6", 0, free=0),))
        self.assertFalse(picker.pick(state).owned)

    def test_the_wait_takes_the_shortest_queue_for_its_size(self):
        state = self.state(self.FULL, owned=(pool("glaeda-std-xcode-26.6", 8, free=0, queued=16),
                                             pool("glaeda-light-xcode-26.6", 4, free=0, queued=2)))
        self.assertEqual(picker.pick(state).label, "glaeda-light-xcode-26.6")
        # A tie keeps owned order (std before light).
        state = self.state(self.FULL, owned=(pool("glaeda-std-xcode-26.6", 8, free=0, queued=4),
                                             pool("glaeda-light-xcode-26.6", 4, free=0, queued=2)))
        self.assertEqual(picker.pick(state).label, "glaeda-std-xcode-26.6")

    def test_the_wait_ranks_by_measured_turnover_not_queue_per_runner(self):
        # A busy 4-runner light pool with 12 queued (3 a runner) against a busy 30-runner std pool with
        # 108 (3.6 a runner): queued / capacity picked light, where the run starts 46.3 min out (four
        # 11.58 min turnovers) against std's 30.0 (four of 7.51).
        light = pool("glaeda-light-xcode-26.6", 4, running=4, free=0, queued=12)
        std = pool("glaeda-std-xcode-26.6", 30, running=30, free=0, queued=108)
        self.assertLess(light.queued / light.capacity, std.queued / std.capacity)
        self.assertAlmostEqual(picker.expected_wait_minutes(light, 2), 4 * 11.58)
        self.assertAlmostEqual(picker.expected_wait_minutes(std, 2), 4 * 7.51)
        self.assertEqual(picker.pick(self.state(self.FULL, owned=(std, light))).label, "glaeda-std-xcode-26.6")

    def test_a_pool_smaller_than_the_run_waits_a_turnover_per_extra_wave(self):
        # One online runner, nothing queued: the second job starts one turnover after the first.
        tiny = pool("glaeda-light-xcode-26.6", 1, free=1)
        self.assertEqual(picker.expected_wait_minutes(tiny, 1), 0)
        self.assertAlmostEqual(picker.expected_wait_minutes(tiny, 2), 11.58)
        # Idle runners take the queue ahead first; a busy pool's job waits one turnover, the slowest
        # measured one for a class with no figure.
        self.assertEqual(picker.expected_wait_minutes(pool("glaeda-std-xcode-26.6", 8, running=4, queued=2), 2), 0)
        self.assertEqual(picker.expected_wait_minutes(pool("glaeda-xl-xcode-26.6", 1, running=1), 1),
                         max(picker.TURNOVER_MINUTES.values()))

    def test_turnover_is_the_measured_fixture(self):
        # TURNOVER_MINUTES is derived, never typed: total runner minutes over jobs per pool class.
        data = json.loads((ROOT / "tests/fixtures/owned-pool-turnover/2026-10-20-to-26.json").read_text())
        totals: dict[str, list[float]] = {}
        for row in data["jobs"]:
            total = totals.setdefault(row["pool"], [0, 0.0])
            total[0] += row["n"]
            total[1] += row["runner_minutes"]
        self.assertEqual(set(totals), set(picker.TURNOVER_MINUTES))
        for klass, (jobs, minutes) in totals.items():
            with self.subTest(klass=klass):
                self.assertEqual(round(minutes / jobs, 2), picker.TURNOVER_MINUTES[klass])
        self.assertEqual({klass: jobs for klass, (jobs, _) in totals.items()}, {"std": 20003, "light": 1360})

    def test_without_an_owned_pool_to_wait_on_the_rule_is_unchanged(self):
        # A fork, owned pools off or an unread runner list has no fleet queue to wait on.
        for state in (self.state(self.FULL, fork=True), self.state(self.FULL, owned_enabled=False),
                      self.state(self.FULL, owned=())):
            with self.subTest(state=state):
                choice = picker.pick(state)
                self.assertEqual(choice.label, picker.BLACKSMITH[1])
                self.assertFalse(choice.owned)


LIGHT = "glaeda-light-xcode-26.6"
STD = "glaeda-std-xcode-26.6"
OWNED_ENV = {
    "GITHUB_REPOSITORY": "manaflow-ai/cmux",
    "CI_PR_POOL_OWNED": "1",
    "CI_OWNED_POOL_SLOTS": json.dumps({STD: 42, LIGHT: 4, "glaeda-root-light-xcode-26.6": 2}),
    "CMUX_CI_XCODE_APP_PR": "/Applications/Xcode_26.6.app",
    "RUN_MACOS": "true",
}


def runner(name, labels, *, busy, status="online"):
    return {"name": name, "status": status, "busy": busy, "labels": [{"name": label} for label in labels]}


def light_runner(index, *, busy, status="online"):
    return runner(f"light-{index}", [LIGHT, "glaeda-root-light-xcode-26.6", "glaeda-side-light-xcode-26.6"],
                  busy=busy, status=status)


def std_runner(index, *, busy):
    return runner(f"std-{index}", [STD, "glaeda-root-std-xcode-26.6", "glaeda-gui-std-xcode-26.6"], busy=busy)


def snapshot(pools):
    return {"version": 1, "generated_at": "2026-10-01T04:15:00Z", "pools": pools}


def observed(runners, pools, *, jobs=4, env=None, runners_error=None):
    """observe() over a fake live read: these runners, this janitor snapshot."""
    class Fake(picker.LiveState):
        def runners(self):
            if runners_error:
                raise runners_error
            return runners

        def snapshot(self):
            return snapshot(pools)

        def active_jobs(self):
            # GitHub has no repository-wide job listing (HTTP 404).
            raise OSError("HTTP Error 404: Not Found")

    original = picker.LiveState
    picker.LiveState = Fake
    try:
        return picker.observe(token="t", repository="manaflow-ai/cmux", jobs=jobs,
                              env=env or OWNED_ENV, fork=False)
    finally:
        picker.LiveState = original


class ConfiguredPoolTests(unittest.TestCase):
    """Only the pools CI_OWNED_POOL_SLOTS lists are owned pools."""

    def test_an_unlisted_owned_looking_label_is_never_picked(self):
        # Ten idle aws runners carry glaeda-std-xcode-26.3, which sorts before
        # the minis' 26.6; picking it sent compile admission to five runners
        # per EC2 Mac while the minis sat idle (cmux#17207).
        aws = [runner(f"aws-{index}", ["glaeda-std-xcode-26.3", "glaeda-root-std-xcode-26.3"], busy=False)
               for index in range(10)]
        minis = [std_runner(index, busy=False) for index in range(8)]
        choice = picker.pick(observed(aws + minis, {}))
        self.assertEqual(choice.label, STD)
        busy_minis = [std_runner(index, busy=True) for index in range(8)]
        self.assertNotEqual(picker.pick(observed(aws + busy_minis, {})).label, "glaeda-std-xcode-26.3")


class LiveRunnerReadTests(unittest.TestCase):
    """The organization has hundreds of runners; the minis are not on the first page."""

    def test_runners_reads_every_page(self):
        pages = {
            1: [runner(f"other-{index}", ["blacksmith-6vcpu-macos-26"], busy=False) for index in range(100)],
            2: [std_runner(index, busy=False) for index in range(30)],
        }
        asked = []

        class Paged(picker.LiveState):
            def _group_runners(self):
                raise RuntimeError("group unread")

            def _get(self, path):
                asked.append(path)
                page = int(path.rsplit("page=", 1)[1]) if "&page=" in path else 1
                return {"total_count": 130, "runners": pages.get(page, [])}

        runners = Paged("t", "manaflow-ai/cmux").runners()
        self.assertEqual(len(runners), 130)
        self.assertEqual(len(asked), 2)

    def test_unconfigured_aws_family_is_not_discovered(self):
        aws = [runner(f"aws-{index}", [
            "glaeda-aws-std-xcode-26.3",
            "glaeda-aws-root-std-xcode-26.3",
        ], busy=False) for index in range(10)]
        minis = [std_runner(index, busy=False) for index in range(8)]
        choice = picker.pick(observed(aws + minis, {}))
        self.assertEqual(choice.label, STD)

    def test_configured_aws_family_can_be_selected(self):
        aws_label = "glaeda-aws-std-xcode-26.3"
        env = {**OWNED_ENV, "CMUX_CI_XCODE_APP_PR": "/Applications/Xcode_26.3.app",
               "CI_OWNED_POOL_SLOTS": json.dumps({aws_label: 10})}
        aws = [runner(f"aws-{index}", [aws_label], busy=False) for index in range(10)]
        choice = picker.pick(observed(aws, {}, env=env))
        self.assertEqual(choice.label, aws_label)
        self.assertEqual(choice.xcode_app, "/Applications/Xcode_26.3.app")

    def test_aws_family_queue_does_not_charge_the_mini_family(self):
        aws_label = "glaeda-aws-std-xcode-26.6"
        env = {**OWNED_ENV,
               "CI_OWNED_POOL_SLOTS": json.dumps({STD: 8, aws_label: 8})}
        runners = [std_runner(index, busy=False) for index in range(8)]
        runners += [runner(f"aws-{index}", [aws_label], busy=False) for index in range(8)]
        state = observed(runners, {aws_label: {"queued": 8}}, env=env, jobs=1)
        by_label = {pool.label: pool for pool in state.owned}
        self.assertEqual(by_label[STD].available, 8)
        self.assertEqual(by_label[aws_label].available, 0)

    def test_owned_order_uses_numeric_versions_and_namespace_tie_break(self):
        labels = [
            "glaeda-aws-std-xcode-26.10",
            "glaeda-std-xcode-26.6",
            "glaeda-aws-std-xcode-26.6",
            "glaeda-std-xcode-26.10",
        ]
        self.assertEqual(sorted(labels, key=picker.owned_order), [
            "glaeda-std-xcode-26.6",
            "glaeda-aws-std-xcode-26.6",
            "glaeda-std-xcode-26.10",
            "glaeda-aws-std-xcode-26.10",
        ])


class OwnedQueueTests(unittest.TestCase):
    """An owned pool's free runners are its idle runners less the jobs queued on its family."""

    def test_stale_xcode_pool_labels_are_not_eligible(self):
        stale = runner("stale", ["glaeda-std-xcode-26.3"], busy=False)
        current = std_runner(0, busy=False)
        state = observed([stale, current], {}, jobs=1)
        self.assertNotIn("glaeda-std-xcode-26.3", {pool.label for pool in state.owned})
        self.assertEqual(picker.pick(state).label, STD)

    def test_many_queued_on_light_and_none_free_never_picks_light(self):
        # 2026-10-01 04:15Z: 25 jobs queued on the light family (14 root, 6
        # plain, 5 side), its 3 online runners busy and 1 offline, and every std
        # mini busy. #16306's admission still went to light and waited an hour.
        runners = [light_runner(i, busy=True) for i in range(3)] + [light_runner(3, busy=False, status="offline")]
        runners += [std_runner(i, busy=True) for i in range(12)]
        pools = {"glaeda-root-light-xcode-26.6": {"queued": 14, "running": 1},
                 LIGHT: {"queued": 6, "running": 2},
                 "glaeda-side-light-xcode-26.6": {"queued": 5, "running": 1},
                 STD: {"queued": 4, "running": 3},
                 picker.BLACKSMITH[0]: {"queued": 0, "running": 2},
                 picker.BLACKSMITH[1]: {"queued": 0, "running": 4}}
        choice = picker.pick(observed(runners, pools))
        self.assertFalse(choice.owned, choice)
        self.assertNotEqual(choice.label, LIGHT)
        self.assertTrue(choice.label.startswith("blacksmith-"), choice)

    def test_idle_runners_do_not_count_while_their_family_has_a_queue(self):
        # Two light runners idle, but six jobs queued on the light root label:
        # they take those runners first.
        runners = [light_runner(0, busy=False), light_runner(1, busy=False), light_runner(2, busy=True)]
        pools = {"glaeda-root-light-xcode-26.6": {"queued": 6, "running": 1}}
        state = observed(runners, pools, jobs=1)
        light = next(pool for pool in state.owned if pool.label == LIGHT)
        self.assertEqual((light.available, light.queued), (0, 6))
        self.assertFalse(picker.pick(state).owned)
        # With the queue drained, the idle runners take the run.
        self.assertEqual(picker.pick(observed(runners, {}, jobs=1)).label, LIGHT)

    def test_std_is_preferred_over_light(self):
        runners = [light_runner(i, busy=False) for i in range(4)] + [std_runner(i, busy=False) for i in range(6)]
        self.assertEqual(picker.pick(observed(runners, {}, jobs=4)).label, STD)

    def test_without_a_runners_read_no_owned_pool_is_eligible(self):
        state = observed([], {}, runners_error=OSError("HTTP Error 403"))
        self.assertEqual(state.owned, ())
        self.assertFalse(picker.pick(state).owned)
        # No token at all: no live read either.
        offline = picker.observe(token="", repository="manaflow-ai/cmux", jobs=1, env=OWNED_ENV, fork=False)
        self.assertFalse(picker.pick(offline).owned)

    def test_blacksmith_load_comes_from_the_snapshot(self):
        pools = {picker.BLACKSMITH[0]: {"queued": 7, "running": 5, "reserved_queued": 1},
                 picker.BLACKSMITH[1]: {"queued": 2, "running": 10}}
        state = observed([], pools, runners_error=OSError("no runners"))
        by_label = {pool.label: pool for pool in state.blacksmith}
        self.assertEqual((by_label[picker.BLACKSMITH[0]].queued, by_label[picker.BLACKSMITH[0]].reserved), (7, 1))
        self.assertEqual(by_label[picker.BLACKSMITH[1]].running, 10)
        # The reserved count consumes one slot; the pool may still be picked
        # when its remaining capacity is sufficient.
        self.assertNotEqual(picker.pick(state).label, picker.BLACKSMITH[0])

    def test_logged_picker_inputs_use_unreserved_slots(self):
        # Janitor snapshots at 00:32 and 00:52 had ordinary CI jobs falsely
        # counted as reservations. The two real nightly jobs consume only
        # two 6vcpu-26 slots; PRs can still use any remaining capacity.
        at_0032 = picker.State(
            jobs=5,
            blacksmith=(
                pool(picker.BLACKSMITH[0], 5, running=5, queued=7),
                pool(picker.BLACKSMITH[1], 10, running=10, queued=43, reserved=2),
                pool(picker.BLACKSMITH[2], 10, running=8, queued=13),
            ),
        )
        self.assertEqual(picker.pick(at_0032).label, picker.BLACKSMITH[2])

        at_0052 = picker.State(
            jobs=3,
            blacksmith=(
                pool(picker.BLACKSMITH[0], 5, running=4, queued=1),
                pool(picker.BLACKSMITH[1], 10, running=10, queued=37, reserved=2),
                pool(picker.BLACKSMITH[2], 10, running=7, queued=4),
            ),
        )
        self.assertEqual(picker.pick(at_0052).label, picker.BLACKSMITH[2])

    def test_an_owned_pick_names_a_blacksmith_retry_runner(self):
        """github-actions[bot]'s rescue attempt 3 takes pr_retry_runner; the owned label kept it queued."""
        runners = [std_runner(i, busy=False) for i in range(6)]
        pools = {picker.BLACKSMITH[0]: {"queued": 9, "running": 5}}
        choice = picker.pick(observed(runners, pools, jobs=4))
        self.assertEqual(choice.label, STD)
        values = picker.write_outputs(choice, 4, env=OWNED_ENV)
        self.assertEqual(values["runner"], STD)
        self.assertEqual(values["retry_runner"], picker.BLACKSMITH[1])
        self.assertTrue(values["retry_runner"].startswith("blacksmith-"))


class LiveReaderTests(unittest.TestCase):
    def test_the_minis_come_from_their_runner_group_not_the_org_pages(self):
        """2,862 org runners on 2026-10-27: the org pages held no mini, so every owned pool read offline."""
        minis = [{"id": index, "status": "online", "busy": False,
                  "labels": [{"name": "glaeda-std-xcode-26.6"}]} for index in range(3)]

        class Grouped(picker.LiveState):
            def _group_runners(self):
                return minis

            def _get(self, path):
                raise AssertionError(f"read the org-wide pages: {path}")

        self.assertEqual(Grouped("token", "manaflow-ai/cmux").runners(), minis)
        self.assertIn("runner-groups", (ROOT / "scripts/ci/pr_runner_pool.py").read_text())

    def test_a_mini_past_page_ten_of_the_org_list_is_still_read(self):
        """More than MAX_RUNNER_PAGES * 100 org runners, the minis only in the glaeda-minis group:
        the minis are still read, and an owned pick takes them (2026-10-27, 2,862 org runners)."""
        org = [runner(f"blacksmith-{index}", ["blacksmith-6vcpu-macos-26"], busy=True)
               for index in range(picker.MAX_RUNNER_PAGES * 100 + 400)]
        minis = [std_runner(index, busy=False) for index in range(6)]
        for index, item in enumerate(org + minis):
            item["id"] = index
        org_tail = org + minis  # the org-wide list holds the minis only past page MAX_RUNNER_PAGES

        def page_of(items, path):
            page = int(path.rsplit("page=", 1)[1]) if "page=" in path else 1
            return {"runners": items[(page - 1) * 100: page * 100]}

        def group_api(_self, path):
            if "/runner-groups?" in path:
                return {"runner_groups": [{"id": 7, "name": "glaeda-minis"}]}
            if "/runner-groups/7/runners" in path:
                return page_of(minis, path)
            if path.startswith("/repos/"):
                return {"runners": []}
            raise AssertionError(path)

        class Live(picker.LiveState):
            def _get(self, path):
                return page_of(org_tail, path)

        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import pr_runner_pool

        with mock.patch.object(pr_runner_pool.GitHub, "get_api", group_api):
            read = Live("token", "manaflow-ai/cmux").runners()
        self.assertEqual({item["name"] for item in read}, {item["name"] for item in minis})
        # The old org-wide read stops at MAX_RUNNER_PAGES and never sees a mini.
        with mock.patch.object(pr_runner_pool.GitHub, "get_api", side_effect=RuntimeError("no group")):
            fallback = Live("token", "manaflow-ai/cmux").runners()
        self.assertEqual(len(fallback), picker.MAX_RUNNER_PAGES * 100)
        self.assertFalse(any(item["name"].startswith("std-") for item in fallback))
        # observe() over the group read: the owned pool is online and picked.
        self.assertEqual(picker.pick(observed(read, {}, jobs=1)).label, STD)
        self.assertFalse(picker.pick(observed(fallback, {}, jobs=1)).owned)

    def test_live_reader_reads_the_org_runners_once(self):
        class Fake(picker.LiveState):
            def __init__(self):
                super().__init__("token", "manaflow-ai/cmux")
                self.paths = []

            def _group_runners(self):
                raise RuntimeError("group unread")

            def _get(self, path):
                self.paths.append(path)
                return {"runners": []}

        api = Fake()
        self.assertEqual(api.runners(), [])
        self.assertEqual(len(api.paths), 1)
        self.assertIn("/orgs/manaflow-ai/actions/runners", api.paths[0])

    def test_outputs_keep_workflow_contract_for_owned_choice(self):
        values = picker.write_outputs(
            picker.Choice("glaeda-std-xcode-26.6", "owned", owned=True), 3,
            env={"RUN_MACOS": "true", "RUN_FULL_SUITE": "true", "RUN_CLI": "true"})
        self.assertEqual(values["runner"], "glaeda-std-xcode-26.6")
        self.assertEqual(values["persistent"], "true")
        self.assertEqual(values["jobs"], "3")
        self.assertIn(" admission ", values["owned_jobs"])
        self.assertIn(" shard-8 ", values["owned_jobs"])
        self.assertIn(" cli-product ", values["owned_jobs"])

        values = picker.write_outputs(
            picker.Choice("glaeda-std-xcode-26.6", "owned", owned=True), 1,
            env={"RUN_MACOS": "true", "CI_OWNED_POOL_SLOTS": '{"glaeda-std-xcode-26.6": 8, "glaeda-root-std-xcode-26.6": 2}'})
        self.assertEqual(values["root_runner"], "glaeda-root-std-xcode-26.6")
        self.assertEqual(values["admission_runner"], '["glaeda-root-std-xcode-26.6"]')

    def test_outputs_preserve_aws_namespace_for_root_and_side_labels(self):
        choice = picker.Choice("glaeda-aws-std-xcode-26.3", "owned", owned=True)
        values = picker.write_outputs(choice, 1, env={
            "RUN_MACOS": "true",
            "CI_OWNED_POOL_SLOTS": json.dumps({
                "glaeda-aws-std-xcode-26.3": 8,
                "glaeda-aws-root-std-xcode-26.3": 2,
                "glaeda-aws-side-std-xcode-26.3": 6,
            }),
        })
        self.assertEqual(values["root_runner"], "glaeda-aws-root-std-xcode-26.3")
        self.assertEqual(values["side_runner"], "glaeda-aws-side-std-xcode-26.3")
        self.assertEqual(values["admission_runner"], '["glaeda-aws-root-std-xcode-26.3"]')

    def test_an_overflow_run_compiles_on_a_free_12vcpu_slot(self):
        """Compile admission is the critical leg; on 6vcpu it takes about 18 min, on 12vcpu about 10."""
        large, small, mac15 = picker.BLACKSMITH
        state = picker.State(jobs=3, blacksmith=(pool(large, 5, 3), pool(small, 10), pool(mac15, 10)))
        choice = picker.pick(state)
        self.assertEqual((choice.label, choice.admission_label), (small, large))
        values = picker.write_outputs(choice, 3, env={"RUN_MACOS": "true"})
        self.assertEqual(values["runner"], small)
        self.assertEqual(values["retry_runner"], small)
        self.assertEqual(values["admission_runner"], json.dumps([large]))
        # No compile, nothing to move.
        self.assertEqual(picker.write_outputs(choice, 3, env={"RUN_CLI": "true"})["admission_runner"], "")

    def test_the_compile_stays_put_without_a_free_12vcpu_slot(self):
        large, small, mac15 = picker.BLACKSMITH
        for busy in (pool(large, 5, 5), pool(large, 5, 4, reserved=1)):
            choice = picker.pick(picker.State(jobs=3, blacksmith=(busy, pool(small, 10), pool(mac15, 10))))
            self.assertEqual((choice.label, choice.admission_label), (small, ""), busy)
        # A run that fits 12vcpu already compiles there.
        choice = picker.pick(picker.State(jobs=2, blacksmith=(pool(large, 5), pool(small, 10))))
        self.assertEqual((choice.label, choice.admission_label), (large, ""))

    def test_owned_runs_and_the_macos_15_pool_never_borrow_12vcpu(self):
        large, small, mac15 = picker.BLACKSMITH
        owned = picker.pick(picker.State(jobs=2, owned=(pool("glaeda-std-xcode-26.6", 8, free=2),),
                                         blacksmith=(pool(large, 5), pool(small, 10)), owned_enabled=True))
        self.assertEqual(owned.admission_label, "")
        # The macOS 15 pool runs another Xcode; its product must come from that Xcode.
        older = picker.pick(picker.State(jobs=4, blacksmith=(pool(large, 5, 3), pool(small, 10, 10),
                                                             pool(mac15, 10, xcode_app="/Applications/Xcode_26.3.app"))))
        self.assertEqual((older.label, older.admission_label), (mac15, ""))
        # A fork is placed on its own route.
        fork = picker.pick(picker.State(jobs=3, fork=True, blacksmith=(pool(large, 5, 3), pool(small, 10))))
        self.assertEqual(fork.admission_label, "")

    def test_the_compile_route_takes_the_overflow_admission_runner_on_attempt_one(self):
        workflow = (ROOT / ".github/workflows/ci-macos.yml").read_text()
        borrowed = ("!contains(inputs.pr_owned_jobs, ' admission ')) && (github.run_attempt == 1 && "
                    "!contains(inputs.pr_owned_jobs, ' admission ') && inputs.pr_admission_runner && "
                    "fromJSON(inputs.pr_admission_runner){index} || inputs.pr_retry_runner)")
        # runs-on takes the list; the product's runner output names its label.
        self.assertEqual(workflow.count(borrowed.format(index="")), 1)
        self.assertEqual(workflow.count(borrowed.format(index="[0]")), 1)

    def test_full_suite_release_build_keeps_swift_package_off_the_minis(self):
        """swift-package-tests builds the SDK 15 helper there, which the minis cannot."""
        owned = picker.Choice("glaeda-std-xcode-26.6", "owned", owned=True)
        helper = picker.write_outputs(owned, 3, env={
            "RUN_MACOS": "true", "RUN_FULL_SUITE": "true",
            "RUN_SWIFT_PACKAGES": "true", "RUN_RELEASE_BUILD": "true"})
        self.assertNotIn(" swift-package ", helper["owned_jobs"])
        self.assertIn(" release-build ", helper["owned_jobs"])

        routed = picker.write_outputs(owned, 1, env={
            "RUN_MACOS": "true", "RUN_SWIFT_PACKAGES": "true"})
        self.assertIn(" swift-package ", routed["owned_jobs"])

    def test_only_explicitly_allowed_fork_can_use_owned_pool(self):
        runners = [std_runner(i, busy=False) for i in range(2)]
        trusted = observed(runners, {}, jobs=1, env={**OWNED_ENV, "CI_PR_POOL_FORK_ALLOWED": "1"})
        untrusted = dataclasses.replace(trusted, fork=True)
        self.assertTrue(picker.pick(trusted).owned)
        self.assertFalse(picker.pick(untrusted).owned)

if __name__ == "__main__":
    unittest.main()
