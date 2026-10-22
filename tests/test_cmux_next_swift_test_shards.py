#!/usr/bin/env python3
"""scripts/cmux-next/swift-test-shards.json covers every CmuxNext test target once, and cmux-next.yml's
swift-test job runs what it says.

The manifest is the one list of which test target runs where: each test target is in exactly one
shard, each serial step's suite is declared by its target's sources, and the job's parallel run skips
exactly the suites the serial steps run on their own. The workflow side checks the job's serial steps
(name, selecting targets, timeout, hang limit, filter, skips, cases) against the manifest, so a step
added to one and not the other fails here.
"""
from __future__ import annotations

import copy
import importlib.util
import re
import shlex
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
SCRIPT = ROOT / "scripts/cmux-next/swift_test_shards.py"
SAMPLER = "swift-test-with-hang-sampler.sh"

spec = importlib.util.spec_from_file_location("swift_test_shards", SCRIPT)
shards = importlib.util.module_from_spec(spec)
sys.modules["swift_test_shards"] = shards
spec.loader.exec_module(shards)


def swift_test_steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["swift-test"]["steps"]


def sampler_args(run: str) -> list[str]:
    """The arguments of the step's hang sampler call, shell-split (one call per step)."""
    line = next(line for line in run.splitlines() if SAMPLER in line)
    words = shlex.split(line.split(SAMPLER, 1)[1].replace('${filter[@]+"${filter[@]}"}', ""))
    return [word for word in words if not word.startswith(";")]


def flag_values(args: list[str], flag: str) -> list[str]:
    return [args[index + 1] for index, word in enumerate(args[:-1]) if word == flag]


class Manifest(unittest.TestCase):
    def setUp(self):
        self.manifest = shards.load()

    def test_every_test_target_is_in_exactly_one_shard(self):
        self.assertEqual(shards.problems(self.manifest), [])
        declared = shards.package_test_targets((ROOT / self.manifest["package"] / "Package.swift").read_text())
        self.assertGreater(len(declared), 30, "the Package.swift parser found too few test targets")
        self.assertEqual(sorted(shards.all_targets(self.manifest)), sorted(declared))

    def test_a_target_left_out_or_listed_twice_is_named(self):
        dropped = copy.deepcopy(self.manifest)
        target = dropped["shards"][0]["targets"].pop(0)
        self.assertIn(f"{target} is in no shard of scripts/cmux-next/swift-test-shards.json", shards.problems(dropped))
        doubled = copy.deepcopy(self.manifest)
        target = doubled["shards"][0]["targets"][0]
        doubled["shards"][1]["targets"] = sorted(doubled["shards"][1]["targets"] + [target])
        self.assertTrue(any(problem.startswith(f"{target} is in ") for problem in shards.problems(doubled)))
        unknown = copy.deepcopy(self.manifest)
        unknown["shards"][1]["targets"] = sorted(unknown["shards"][1]["targets"] + ["CmuxNextNoSuchTests"])
        self.assertTrue(any("CmuxNextNoSuchTests is not a test target" in problem for problem in shards.problems(unknown)))

    def test_a_serial_suite_the_target_does_not_declare_is_named(self):
        broken = copy.deepcopy(self.manifest)
        step = next(step for shard in broken["shards"] for step in shard["serial"] if "suite" in step)
        step["suite"] = "NoSuchSuiteTests"
        self.assertTrue(any("no NoSuchSuiteTests in" in problem for problem in shards.problems(broken)))

    def test_a_serial_suite_left_in_the_parallel_run_is_named(self):
        broken = copy.deepcopy(self.manifest)
        broken["shards"][0]["parallel_skip"] = broken["shards"][0]["parallel_skip"][1:]
        self.assertTrue(any("parallel_skip" in problem for problem in shards.problems(broken)))

    def test_the_matrix_lists_only_shards_with_work(self):
        everything = shards.matrix(self.manifest, "all")["include"]
        self.assertEqual([entry["shard"] for entry in everything], [shard["name"] for shard in self.manifest["shards"]])
        none = shards.matrix(self.manifest, "")["include"]
        self.assertEqual([entry["script_tests"] for entry in none], [True], "only the script-test shard runs with no target")
        self.assertEqual(none[0]["filter"], "")
        gui = next(shard for shard in self.manifest["shards"] if shard["runner"] == "gui")
        one = shards.matrix(self.manifest, gui["targets"][0])["include"]
        self.assertEqual({entry["shard"] for entry in one}, {gui["name"]} | {entry["shard"] for entry in none})
        self.assertEqual(next(entry for entry in one if entry["shard"] == gui["name"])["filter"],
                         f"^({gui['targets'][0]})\\.")

    def test_a_shard_filter_has_the_route_filter_form(self):
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import cmux_next_route  # noqa: E402

        mac = next(shard for shard in self.manifest["shards"] if shard["runner"] == "mac")
        picked = mac["targets"][:3]
        route = cmux_next_route.Route()
        route.tests = set(picked)
        self.assertEqual(shards.shard_filter(self.manifest, mac["name"], " ".join(picked)), cmux_next_route.swift_filter(route))
        self.assertEqual(shards.shard_filter(self.manifest, mac["name"], "CmuxNextAppTests"), "")


class Workflow(unittest.TestCase):
    def setUp(self):
        self.manifest = shards.load()
        self.steps = swift_test_steps()
        self.by_name = {step.get("name"): step for step in self.steps}

    def serial_steps(self):
        return [(shard, step) for shard in self.manifest["shards"] for step in shard["serial"]]

    def test_the_parallel_run_skips_the_serial_suites(self):
        main = next(step for step in self.steps if step.get("name", "").startswith("Run package tests"))
        skipped = flag_values(sampler_args(main["run"]), "--skip")
        expected = [suite for shard in self.manifest["shards"] for suite in shard["parallel_skip"]]
        self.assertEqual(sorted(skipped), sorted(expected))

    def test_each_serial_step_matches_the_manifest(self):
        for shard, entry in self.serial_steps():
            with self.subTest(step=entry["name"]):
                step = self.by_name.get(entry["name"])
                self.assertIsNotNone(step, f"cmux-next.yml swift-test has no step {entry['name']!r}")
                gates = re.findall(r"contains\(env\.SWIFT_TARGETS, '([A-Za-z]+)'\)", step["if"])
                self.assertEqual(sorted(gates), sorted(entry["when_targets"]))
                self.assertIn("steps.build-tests.outcome == 'success'", step["if"])
                self.assertEqual(step["timeout-minutes"], entry["timeout_minutes"])
                self.assertEqual(str(step["env"]["CMUX_NEXT_TEST_HANG_SECONDS"]), str(entry["hang_seconds"]))
                args = sampler_args(step["run"])
                self.assertIn("--skip-build", args)
                self.assertEqual("--no-parallel" in args, entry["no_parallel"])
                self.assertEqual(flag_values(args, "--skip"), entry.get("skip", []))
                if "each_case" in entry:
                    cases = re.findall(rf"\b{entry['suite']}\.(\w+)", step["run"])
                    self.assertEqual(cases, entry["each_case"])
                    self.assertEqual(str(step["env"]["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"]), "1")
                else:
                    self.assertEqual(flag_values(args, "--filter"), [entry.get("filter") or entry["suite"]])

    def test_every_sampler_step_is_the_parallel_run_or_a_listed_serial_step(self):
        listed = {entry["name"] for _, entry in self.serial_steps()}
        for step in self.steps:
            if SAMPLER in step.get("run", "") and not step["name"].startswith("Run package tests"):
                self.assertIn(step["name"], listed, "a serial swift test step not in swift-test-shards.json")

    def test_the_script_tests_run_in_the_job(self):
        self.assertIn("Script tests (bundle-server-helper)", self.by_name)
        self.assertIn("Test sidebar layout reducer", self.by_name)


if __name__ == "__main__":
    unittest.main()
