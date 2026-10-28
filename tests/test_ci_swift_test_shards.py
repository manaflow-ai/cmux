#!/usr/bin/env python3
"""The broad Swift test pass runs as several processes, and every selected test falls in exactly one of them.

One swift test process ran every selected suite: its tests queued on one main thread, the windows they left open
piled up (3 -> 428 in run 40705037968) and the pass hit its limit with 466 tests unfinished.
scripts/cmux-next/swift-test-shards.py splits the selected targets by target and suite-name prefix.
"""

from __future__ import annotations

import importlib.util
import re
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages" / "macOS" / "CmuxNext"
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next.yml"
SCRIPT = ROOT / "scripts" / "cmux-next" / "swift-test-shards.py"

def load(name: str, path: Path):
    """A script as a module, registered in sys.modules first: a @dataclass reads its module from there
    (on Python 3.12 and 3.13 an unregistered module crashes the import)."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


shards = load("swift_test_shards", SCRIPT)


def matching(plan: list[dict], test_id: str) -> list[str]:
    """The shards that run `test_id`: their filter matches it and none of their skips does."""
    return [s["name"] for s in plan
            if re.search(s["filter"], test_id) and not any(re.search(k, test_id) for k in s.get("skip", []))]


class Plan(unittest.TestCase):
    def test_every_suite_of_every_target_is_in_exactly_one_shard(self) -> None:
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "all", 10)
        self.assertGreater(len(plan), 1)
        for target in shards.test_targets(PACKAGE / "Package.swift"):
            for suite in shards.suite_counts(PACKAGE / "Tests" / target):
                with self.subTest(suite=f"{target}.{suite}"):
                    self.assertEqual(len(matching(plan, f"{target}.{suite}/aTest()")), 1)

    def test_a_suite_the_sources_did_not_show_still_lands_in_exactly_one_shard(self) -> None:
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "all", 10)
        for name in ("Zz", "_Hidden", "lowercase", "S", "Sx9", "CmQ", "Ä"):
            with self.subTest(name=name):
                self.assertEqual(len(matching(plan, f"CmuxNextAppTests.{name}/aTest()")), 1)

    def test_the_cloud_suites_run_in_a_shard_of_their_own(self) -> None:
        # Run 40723548016, shard 4: three Cloud tests sat 300 s packed beside other suites, and pass alone.
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "all", 10)
        cloud = [s for s in plan if s["filter"] == r"^(CmuxNextAppTests\.Cloud)"]
        self.assertEqual(len(cloud), 1)
        for suite in ("CloudCodexBrokerTests", "CloudCodexBrokerAdapterTests", "CloudStartSessionTests"):
            with self.subTest(suite=suite):
                self.assertEqual(matching(plan, f"CmuxNextAppTests.{suite}/aTest()"), [cloud[0]["name"]])
        self.assertEqual(len(matching(plan, "CmuxNextAppTests.ClipboardTests/aTest()")), 1)
        self.assertNotIn(cloud[0]["name"], matching(plan, "CmuxNextAppTests.ClipboardTests/aTest()"))
        self.assertEqual([s for s in plan if s["filter"] == r"^(CmuxNextAppTests\.Cloud)"][0]["skip"], [])

    def test_shards_are_balanced_and_the_largest_runs_first(self) -> None:
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "all", 10)
        sizes = [s["tests"] for s in plan]
        self.assertEqual(sizes, sorted(sizes, reverse=True))
        packed = [s["tests"] for s in plan if s["skip"]]
        self.assertLess(max(packed), 1.5 * sum(packed) / len(packed))

    def test_only_the_selected_targets_and_never_an_excluded_one(self) -> None:
        plan = shards.plan(PACKAGE / "Tests", PACKAGE / "Package.swift", "CmuxNextFilesTests CmuxNextControlTests", 10,
                           {"CmuxNextControlTests"})
        self.assertEqual(matching(plan, "CmuxNextFilesTests.Any/aTest()"), ["shard 1"])
        self.assertEqual(matching(plan, "CmuxNextControlTests.Any/aTest()"), [])
        self.assertEqual(matching(plan, "CmuxNextAppTests.Any/aTest()"), [])

    def test_a_small_selection_is_one_process(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text('.testTarget(\n    name: "ATests"\n)\n.testTarget(name: "BTests")\n')
            for target in ("ATests", "BTests"):
                (root / "Tests" / target).mkdir(parents=True)
                (root / "Tests" / target / "X.swift").write_text("struct XTests {\n    @Test func a() {}\n}\n")
            plan = shards.plan(root / "Tests", root / "Package.swift", "all", 8)
        self.assertEqual(len(plan), 1)
        self.assertEqual(matching(plan, "BTests.XTests/a()"), ["shard 1"])


class Width(unittest.TestCase):
    def test_width_comes_from_the_runners_cores_and_memory(self) -> None:
        self.assertEqual(shards.width(10, 64), 5)  # cores bound it
        self.assertEqual(shards.width(10, 16), 4)  # memory bounds it
        self.assertEqual(shards.width(1, 2), 1)
        self.assertEqual(shards.width(10, 64, "2"), 2)


class Route(unittest.TestCase):
    def test_a_change_to_either_script_runs_every_swift_target(self) -> None:
        route = load("cmux_next_route_for_shards", ROOT / "scripts" / "ci" / "cmux_next_route.py")
        for path in ("scripts/cmux-next/swift-test-shards.py", "scripts/cmux-next/main-thread-heavy-suites.py"):
            with self.subTest(path=path):
                self.assertIn(path, route.FULL_INPUTS)


class Workflow(unittest.TestCase):
    def test_the_broad_pass_runs_the_shards(self) -> None:
        steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["swift-test"]["steps"]
        broad = next(s for s in steps if s.get("name", "").startswith("Run package tests (changed suites first"))
        self.assertIn("swift-test-shards.py run", broad["run"])
        self.assertIn('--targets "$SWIFT_TARGETS"', broad["run"])
        self.assertIn("--exclude CmuxNextControlTests", broad["run"])
        self.assertNotIn("swift-test-with-hang-sampler.sh --skip-build ${filter", broad["run"])


if __name__ == "__main__":
    unittest.main()
