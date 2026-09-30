#!/usr/bin/env python3
"""Behavior tests for the live per-label macOS pool rule."""

from __future__ import annotations

import contextlib
import importlib.util
import io
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
                    blacksmith=(pool(picker.BLACKSMITH[0], 5, 5, 100), pool(picker.BLACKSMITH[1], 10)),
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
                "queued release protects its pool",
                picker.State(jobs=1, blacksmith=(pool(picker.BLACKSMITH[0], 5, reserved=1),
                                                 pool(picker.BLACKSMITH[1], 10))),
                picker.BLACKSMITH[1],
            ),
            (
                "all full uses the lowest queued plus running ratio",
                picker.State(jobs=1, blacksmith=(pool(picker.BLACKSMITH[0], 5, 5, 1),
                                                 pool(picker.BLACKSMITH[1], 10, 10, 0))),
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


class MacOS15IsNotAPullRequestPoolTests(unittest.TestCase):
    """Pull request, merge-queue, E2E and iOS runs test on main's macOS 26 and Xcode."""

    MACOS_15 = "blacksmith-6vcpu-macos-15"

    def test_blacksmith_overflow_is_macos_26_only(self):
        self.assertEqual(picker.BLACKSMITH, ("blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"))
        self.assertNotIn(self.MACOS_15, picker.CAPACITY)

    def test_a_pool_outside_the_order_is_never_chosen(self):
        # 2026-09-24: 6vcpu macOS 26 queued 45 and 12vcpu 18 while macOS 15
        # ran 1 of its 10. The run still queues on macOS 26.
        state = picker.State(jobs=3, blacksmith=(pool(picker.BLACKSMITH[0], 5, 5, 18),
                                                 pool(picker.BLACKSMITH[1], 10, 10, 45),
                                                 pool(self.MACOS_15, 10, 1, 0)))
        choice = picker.pick(state)
        self.assertEqual(choice.label, picker.BLACKSMITH[0])
        self.assertEqual(choice.xcode_app, "")

    def test_live_state_counts_only_the_macos_26_pools(self):
        class Fake(picker.LiveState):
            def __init__(self, token, repository):
                super().__init__(token, repository)

            def runners(self):
                return []

            def active_jobs(self):
                return [{"labels": [self.MACOS_15], "status": "queued"} for _ in range(3)] + [
                    {"labels": [picker.BLACKSMITH[1]], "status": "in_progress"}]
        Fake.MACOS_15 = self.MACOS_15
        original = picker.LiveState
        picker.LiveState = Fake
        try:
            state = picker.observe(token="t", repository="manaflow-ai/cmux", jobs=1, env={}, fork=False)
        finally:
            picker.LiveState = original
        self.assertEqual([item.label for item in state.blacksmith], list(picker.BLACKSMITH))
        self.assertEqual(state.blacksmith[1].running, 1)

    def test_merge_group_takes_an_ephemeral_pool(self):
        """A merge group can carry fork code, so it never takes an owned Mac."""
        env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "CI_PR_POOL_OWNED": "1",
               "CI_OWNED_POOL_SLOTS": '{"glaeda-std-xcode-26.6": 8}', "RUN_MACOS": "true",
               "CI_PR_POOL_FORK_ALLOWED": "1"}
        for event, owned in (("merge_group", False), ("workflow_dispatch", True), ("pull_request", True)):
            with self.subTest(event=event):
                with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
                    picker.main([], env={**env, "EVENT_NAME": event})
                values = dict(line.split("=", 1) for line in out.getvalue().splitlines() if "=" in line)
                self.assertEqual(values["persistent"], "true" if owned else "false")
                if not owned:
                    self.assertIn(values["runner"], picker.BLACKSMITH)


class LiveReaderTests(unittest.TestCase):
    def test_live_reader_batches_runners_and_jobs(self):
        class Fake(picker.LiveState):
            def __init__(self):
                super().__init__("token", "manaflow-ai/cmux")
                self.paths = []

            def _get(self, path):
                self.paths.append(path)
                if "/runners" in path:
                    return {"runners": []}
                return {"jobs": []}

        api = Fake()
        self.assertEqual(api.runners(), [])
        self.assertEqual(api.active_jobs(), [])
        self.assertEqual(len(api.paths), 2)
        self.assertIn("/orgs/manaflow-ai/actions/runners", api.paths[0])
        self.assertIn("/repos/manaflow-ai/cmux/actions/jobs", api.paths[1])

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
        base = {
            "GITHUB_REPOSITORY": "manaflow-ai/cmux",
            "CI_PR_POOL_OWNED": "1",
            "CI_OWNED_POOL_SLOTS": '{"glaeda-std-xcode-26.6": 2}',
            "RUN_MACOS": "true",
            "MACOS_RUNNER_PR": picker.BLACKSMITH[1],
        }
        trusted = picker.observe(token="", repository="manaflow-ai/cmux", jobs=1,
                                 env={**base, "CI_PR_POOL_FORK_ALLOWED": "1"},
                                 fork=False)
        untrusted = picker.observe(token="", repository="manaflow-ai/cmux", jobs=1,
                                   env=base, fork=True)
        self.assertTrue(picker.pick(trusted).owned)
        self.assertFalse(picker.pick(untrusted).owned)


if __name__ == "__main__":
    unittest.main()
