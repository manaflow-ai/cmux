#!/usr/bin/env python3
"""The backend `test` gate reruns an api-workerd shard that died without a test verdict (cmux#56511).

Holds two things:

1. scripts/ci/api_workerd_infra_shards.py sorts shards the way the gate needs, on job listings saved from real
   feat-cmux-next runs (tests/fixtures/api_workerd_jobs/): a lost runner, a stalled setup step and the job limit
   are `infra` (rerun); a test step that ended `failure` is `fail` (stays red, never rerun a third time).
2. backend.yml wires it: the shard job and the gate's rerun run the same scripts/ci/api-workerd-shard.sh, the
   gate job can read the run's jobs, and the final "Fail on the API Worker shards" step yields only to a rerun
   that passed. A refactor that drops any of these brings back reds that are not the code's.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "api_workerd_infra_shards.py"
FIXTURES = ROOT / "tests" / "fixtures" / "api_workerd_jobs"
WORKFLOW = ROOT / ".github" / "workflows" / "backend.yml"

spec = importlib.util.spec_from_file_location("api_workerd_infra_shards", SCRIPT)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)


def run_jobs(run_id: int) -> list[dict]:
    return json.loads((FIXTURES / f"run-{run_id}.json").read_text())["jobs"]


def shards_with(verdicts: dict[int, str], verdict: str) -> list[int]:
    return [s for s, v in verdicts.items() if v == verdict]


class ClassifyRealRuns(unittest.TestCase):
    def test_green_run_is_all_pass(self) -> None:
        v = mod.classify(run_jobs(45525542601))
        self.assertEqual(shards_with(v, "pass"), list(range(1, 13)))

    def test_lost_runner_with_no_step_finished_is_infra(self) -> None:
        # Shard 6/12 ended failure with no steps and no log (the runner went away).
        v = mod.classify(run_jobs(45608130897))
        self.assertEqual(shards_with(v, "infra"), [6])
        self.assertEqual(shards_with(v, "fail"), [])

    def test_setup_node_timeout_and_lost_runner_are_infra(self) -> None:
        # 1/12: setup-node past its 5 min bound; 2/12: lost mid setup-node (steps null).
        v = mod.classify(run_jobs(45607473333))
        self.assertEqual(shards_with(v, "infra"), [1, 2])

    def test_job_limit_cancel_is_infra(self) -> None:
        # 6/12 and 12/12 ran into the 45 min job limit on a slow host: the test step was cancelled.
        v = mod.classify(run_jobs(45600237340))
        self.assertEqual(shards_with(v, "infra"), [6, 12])

    def test_a_failed_test_step_is_a_real_fail_not_rerun(self) -> None:
        # 6/12's test step failed after rerunning its failed file alone: the tests' answer.
        v = mod.classify(run_jobs(45605232679))
        self.assertEqual(shards_with(v, "fail"), [6])
        self.assertEqual(shards_with(v, "infra"), [])

    def test_mixed_run_keeps_both(self) -> None:
        # 1/12 failed its tests; 5/12 and 12/12 lost their runner mid-test; 10/12 cancelled at Set up job.
        v = mod.classify(run_jobs(45562739059))
        self.assertEqual(shards_with(v, "fail"), [1])
        self.assertEqual(shards_with(v, "infra"), [5, 10, 12])

    def test_a_missing_shard_job_is_infra(self) -> None:
        jobs = [j for j in run_jobs(45525542601) if j["name"] != "api-workerd (3/12)"]
        self.assertEqual(shards_with(mod.classify(jobs), "infra"), [3])

    def test_cli_prints_output_lines(self) -> None:
        out = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--jobs-json", str(FIXTURES / "run-45562739059.json")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        self.assertEqual(out, ["infra=5 10 12", "fail=1"])


class WorkflowWiring(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def step(self, job: str, name: str) -> dict:
        for s in self.jobs[job]["steps"]:
            if s.get("name") == name:
                return s
        self.fail(f"{job} has no step {name!r}")

    def test_shard_job_runs_the_shared_script_in_the_classified_step(self) -> None:
        steps = [s for s in self.jobs["api-workerd"]["steps"] if str(s.get("name", "")).startswith(mod.TEST_STEP_PREFIX)]
        self.assertEqual(len(steps), 1, "the classifier finds the test step by this name prefix")
        self.assertIn("scripts/ci/api-workerd-shard.sh", steps[0]["run"])

    def test_gate_reruns_infra_shards_and_fails_only_without_a_passing_rerun(self) -> None:
        test = self.jobs["test"]
        self.assertEqual(test["permissions"].get("actions"), "read")
        rerun = self.step("test", "Rerun API Worker shards that died without a test verdict")
        self.assertEqual(rerun["id"], "shard-rerun")
        self.assertIn("scripts/ci/api_workerd_infra_shards.py", rerun["run"])
        self.assertIn("scripts/ci/api-workerd-shard.sh", rerun["run"])
        self.assertIn("timeout-minutes", rerun)
        self.assertGreaterEqual(test["timeout-minutes"], 55 + rerun["timeout-minutes"])
        fail = self.step("test", "Fail on the API Worker shards")
        self.assertIn("steps.shard-rerun.outputs.verdict != 'pass'", fail["if"])
        names = [s.get("name") for s in test["steps"]]
        self.assertLess(names.index(rerun["name"]), names.index(fail["name"]))


if __name__ == "__main__":
    unittest.main()
