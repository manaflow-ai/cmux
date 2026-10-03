#!/usr/bin/env python3
"""Behavior tests for the live per-label macOS pool rule."""

from __future__ import annotations

import dataclasses
import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("simple_pool_picker", ROOT / "scripts/ci/simple_pool_picker.py")
assert spec and spec.loader
picker = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = picker
spec.loader.exec_module(picker)


def pool(label: str, capacity: int, running: int = 0, queued: int = 0, *, reserved: int = 0, free: int | None = None):
    return picker.Pool(label, capacity, running, queued, free=free, reserved=reserved)


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
    def test_live_reader_reads_the_org_runners_once(self):
        class Fake(picker.LiveState):
            def __init__(self):
                super().__init__("token", "manaflow-ai/cmux")
                self.paths = []

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
