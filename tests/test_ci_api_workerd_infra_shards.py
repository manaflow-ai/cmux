#!/usr/bin/env python3
"""The backend `test` gate reruns an api-workerd shard that died without a test verdict (cmux#56511).

Holds three things:

1. scripts/ci/api_workerd_infra_shards.py sorts shards the way the gate needs, from the verdict files the shards
   upload: `success` is pass, `failure` is fail (the tests' answer, never rerun a third time), and no file, an
   empty one or anything else is infra (a lost runner, a stalled setup step, the job limit: rerun).
2. The gate's rerun step itself, run in bash against those files with a stand-in shard script: it reruns exactly
   the infra shards, and says `verdict=pass` only when every one of them passed and no shard failed its tests.
3. backend.yml wires it: each shard records its test step's outcome under the artifact name and path the gate
   downloads, both run the same scripts/ci/api-workerd-shard.sh, and "Fail on the API Worker shards" yields only
   to a rerun that passed. A refactor that drops any of these brings back reds that are not the code's.
"""

from __future__ import annotations

import fnmatch
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "api_workerd_infra_shards.py"
WORKFLOW = ROOT / ".github" / "workflows" / "backend.yml"
TEST_STEP_PREFIX = "API Worker tests (workerd), shard "
RERUN_STEP = "Rerun API Worker shards that died without a test verdict"

spec = importlib.util.spec_from_file_location("api_workerd_infra_shards", SCRIPT)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)


def write_verdicts(directory: Path, recorded: dict[int, str]) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for shard, text in recorded.items():
        (directory / str(shard)).write_text(text + "\n")


def all_pass_but() -> dict[int, str]:
    return {s: "success" for s in range(1, 13)}


def shards_with(verdicts: dict[int, str], verdict: str) -> list[int]:
    return [s for s, v in verdicts.items() if v == verdict]


class Classify(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)

    def classify(self, recorded: dict[int, str]) -> dict[int, str]:
        write_verdicts(self.dir, recorded)
        return mod.classify(self.dir)

    def test_all_recorded_success_is_all_pass(self) -> None:
        self.assertEqual(shards_with(self.classify(all_pass_but()), "pass"), list(range(1, 13)))

    def test_a_shard_with_no_verdict_is_infra(self) -> None:
        # Run 45608130897: shard 6/12 lost its runner, so it never recorded anything.
        recorded = all_pass_but()
        del recorded[6]
        v = self.classify(recorded)
        self.assertEqual(shards_with(v, "infra"), [6])
        self.assertEqual(shards_with(v, "fail"), [])

    def test_a_recorded_failure_is_a_real_fail_not_rerun(self) -> None:
        # Run 45605232679: 6/12's test step failed after rerunning its failed file alone.
        recorded = all_pass_but()
        recorded[6] = "failure"
        v = self.classify(recorded)
        self.assertEqual(shards_with(v, "fail"), [6])
        self.assertEqual(shards_with(v, "infra"), [])

    def test_empty_or_odd_file_is_infra(self) -> None:
        recorded = all_pass_but()
        recorded[2] = ""
        recorded[3] = "cancelled"
        self.assertEqual(shards_with(self.classify(recorded), "infra"), [2, 3])

    def test_no_directory_at_all_is_all_infra(self) -> None:
        self.assertEqual(shards_with(mod.classify(self.dir / "missing"), "infra"), list(range(1, 13)))

    def test_cli_prints_output_lines(self) -> None:
        # Run 45562739059: 1/12 failed its tests; 5/12, 10/12 and 12/12 died before answering.
        recorded = all_pass_but()
        recorded[1] = "failure"
        for s in (5, 10, 12):
            del recorded[s]
        write_verdicts(self.dir, recorded)
        out = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--verdict-dir", str(self.dir)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        self.assertEqual(out, ["infra=5 10 12", "fail=1"])


def workflow_jobs() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]


def find_step(steps: list[dict], name: str) -> dict:
    for s in steps:
        if s.get("name") == name:
            return s
    raise AssertionError(f"no step {name!r}")


class GateRerunStep(unittest.TestCase):
    """Runs the rerun step's own bash with a stand-in for scripts/ci/api-workerd-shard.sh."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.step = find_step(workflow_jobs()["test"]["steps"], RERUN_STEP)
        ws = self.tmp / "ws"
        (ws / "scripts" / "ci").mkdir(parents=True)
        shutil.copy(SCRIPT, ws / "scripts" / "ci" / SCRIPT.name)
        self.ran = self.tmp / "ran"
        (ws / "scripts" / "ci" / "api-workerd-shard.sh").write_text(
            '#!/usr/bin/env bash\necho "$1/$2" >> "$RAN_LOG"\n'
            'case " ${FAIL_SHARDS:-} " in *" $1 "*) exit 1 ;; esac\nexit 0\n'
        )
        self.ws = ws
        self.runner_temp = self.tmp / "runner"
        self.output = self.tmp / "output"
        self.output.write_text("")

    def run_step(self, recorded: dict[int, str], fail_shards: str = "") -> tuple[list[str], str, str]:
        write_verdicts(self.runner_temp / "api-workerd-verdict", recorded)
        env = {
            "PATH": os.environ["PATH"],
            "GITHUB_WORKSPACE": str(self.ws),
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_OUTPUT": str(self.output),
            "RAN_LOG": str(self.ran),
            "FAIL_SHARDS": fail_shards,
            **{k: str(v) for k, v in self.step.get("env", {}).items()},
        }
        proc = subprocess.run(
            ["bash", "-e", "-c", self.step["run"]], cwd=self.tmp, env=env, capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        ran = self.ran.read_text().split() if self.ran.exists() else []
        return ran, self.output.read_text(), proc.stdout

    def test_reruns_only_the_shards_without_a_verdict_and_passes(self) -> None:
        recorded = all_pass_but()
        del recorded[3]
        del recorded[10]
        ran, output, _ = self.run_step(recorded)
        self.assertEqual(ran, ["3/12", "10/12"])
        self.assertIn("verdict=pass", output)

    def test_a_rerun_that_fails_stays_red(self) -> None:
        recorded = all_pass_but()
        del recorded[3]
        ran, output, stdout = self.run_step(recorded, fail_shards="3")
        self.assertEqual(ran, ["3/12"])
        self.assertNotIn("verdict=pass", output)
        self.assertIn("::error", stdout)

    def test_a_shard_that_failed_its_tests_is_not_rerun_and_stays_red(self) -> None:
        recorded = all_pass_but()
        recorded[6] = "failure"
        del recorded[3]
        ran, output, _ = self.run_step(recorded)
        self.assertEqual(ran, [])
        self.assertNotIn("verdict=pass", output)

    def test_more_than_the_budget_is_an_outage_and_stays_red(self) -> None:
        budget = int(self.step["env"]["MAX_INFRA_SHARDS"])
        recorded = {s: "success" for s in range(budget + 2, 13)}
        ran, output, _ = self.run_step(recorded)
        self.assertEqual(ran, [])
        self.assertNotIn("verdict=pass", output)


class WorkflowWiring(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = workflow_jobs()

    def test_each_shard_records_its_test_steps_outcome_where_the_gate_reads_it(self) -> None:
        steps = self.jobs["api-workerd"]["steps"]
        tests = [s for s in steps if str(s.get("name", "")).startswith(TEST_STEP_PREFIX)]
        self.assertEqual(len(tests), 1)
        test_step = tests[0]
        self.assertIn("scripts/ci/api-workerd-shard.sh", test_step["run"])
        sid = test_step["id"]
        record = find_step(steps, "Record the shard's test verdict")
        upload = find_step(steps, "Upload the shard's test verdict")
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(test_step["name"]), names.index(record["name"]))
        self.assertLess(names.index(record["name"]), names.index(upload["name"]))
        for s in (record, upload):
            self.assertIn(f"steps.{sid}.outcome == 'success'", s["if"])
            self.assertIn(f"steps.{sid}.outcome == 'failure'", s["if"])
        self.assertIn(f"${{{{ steps.{sid}.outcome }}}}", record["run"])
        self.assertIn('"$RUNNER_TEMP/api-workerd-verdict/${{ matrix.shard }}"', record["run"])
        self.assertTrue(upload["uses"].startswith("actions/upload-artifact@"))
        self.assertTrue(upload.get("continue-on-error"))
        self.assertEqual(upload["with"]["path"], "${{ runner.temp }}/api-workerd-verdict/${{ matrix.shard }}")
        self.shard_artifact = upload["with"]["name"]

        gate = self.jobs["test"]["steps"]
        download = find_step(gate, "Download the API Worker shards' test verdicts")
        self.assertTrue(download["uses"].startswith("actions/download-artifact@"))
        self.assertTrue(download.get("continue-on-error"))
        self.assertTrue(download["with"]["merge-multiple"])
        self.assertEqual(download["with"]["path"], "${{ runner.temp }}/api-workerd-verdict")
        for shard in ("1", "12"):
            self.assertTrue(
                fnmatch.fnmatchcase(upload["with"]["name"].replace("${{ matrix.shard }}", shard), download["with"]["pattern"])
            )
        rerun = find_step(gate, RERUN_STEP)
        self.assertIn('--verdict-dir "$RUNNER_TEMP/api-workerd-verdict"', rerun["run"])
        self.assertEqual(download["if"], rerun["if"])

    def test_node_is_an_exact_pin_restored_from_the_bucket_first(self) -> None:
        # A range made setup-node read GitHub's manifest and copy a fresh download into the tool cache on every
        # new runner; both stalled shards past the step's bound (run 45606215566).
        for job in ("api-workerd", "test"):
            steps = self.jobs[job]["steps"]
            setup = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("actions/setup-node@")]
            self.assertEqual(len(setup), 1, job)
            version = steps[setup[0]]["with"]["node-version"]
            self.assertRegex(version, r"^\d+\.\d+\.\d+$", job)
            restore = steps[setup[0] - 1]
            self.assertIn(f"toolchain-r2.sh\" restore node {version}", restore["run"], job)
            self.assertEqual(restore["env"]["TOOLCHAIN_R2_ALL"], "1", job)
            self.assertTrue(restore.get("continue-on-error"), job)
            pins = (ROOT / "scripts" / "ci" / "toolchain-archives.sha256").read_text()
            self.assertIn(f"node-v{version}-linux-x64.tar.gz", pins)

    def test_gate_fails_only_without_a_passing_rerun(self) -> None:
        test = self.jobs["test"]
        rerun = find_step(test["steps"], RERUN_STEP)
        self.assertEqual(rerun["id"], "shard-rerun")
        self.assertIn("scripts/ci/api-workerd-shard.sh", rerun["run"])
        self.assertGreaterEqual(test["timeout-minutes"], 55 + rerun["timeout-minutes"])
        fail = find_step(test["steps"], "Fail on the API Worker shards")
        self.assertIn("steps.shard-rerun.outputs.verdict != 'pass'", fail["if"])
        names = [s.get("name") for s in test["steps"]]
        self.assertLess(names.index(rerun["name"]), names.index(fail["name"]))


if __name__ == "__main__":
    unittest.main()
