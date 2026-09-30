#!/usr/bin/env python3
"""Behavior tests for the live per-label macOS pool rule."""

from __future__ import annotations

import importlib.util
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
                "queued release protects its pool",
                picker.State(jobs=1, blacksmith=(pool(picker.BLACKSMITH[0], 5, reserved=1),
                                                 pool(picker.BLACKSMITH[1], 10))),
                picker.BLACKSMITH[1],
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


if __name__ == "__main__":
    unittest.main()
