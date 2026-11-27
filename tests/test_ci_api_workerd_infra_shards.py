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
import json
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

    def test_an_older_attempts_failure_is_infra_but_its_success_stands(self) -> None:
        # Attempt 2 after "Re-run failed jobs": shard 3 failed in attempt 1 and was rerun but died before answering
        # (its attempt 1 file is still there); shard 4 passed in attempt 1 and was not rerun; shard 5 failed again.
        recorded = {s: "success 1" for s in range(1, 13)}
        recorded[3] = "failure 1"
        recorded[5] = "failure 2"
        write_verdicts(self.dir, recorded)
        v = mod.classify(self.dir, attempt=2)
        self.assertEqual(shards_with(v, "infra"), [3])
        self.assertEqual(shards_with(v, "fail"), [5])
        self.assertEqual(v[4], "pass")

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
            "GITHUB_RUN_ATTEMPT": "1",
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


@unittest.skipUnless(shutil.which("node"), "the shard script reads vitest's report with node")
class ShardScript(unittest.TestCase):
    """Runs scripts/ci/api-workerd-shard.sh with a stand-in `bun` that writes a vitest JSON report."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        # First call: write REPORT_1 to $VITEST_JSON_OUT and exit EXIT_1; later calls exit EXIT_2.
        (bin_dir / "bun").write_text(
            "#!/usr/bin/env bash\n"
            'echo "$*" >> "$CALLS"\n'
            'if [ ! -e "$CALLS.first" ]; then : > "$CALLS.first"; [ -n "${VITEST_JSON_OUT:-}" ] && cp "$REPORT_1" "$VITEST_JSON_OUT"; exit "$EXIT_1"; fi\n'
            'exit "$EXIT_2"\n'
        )
        (bin_dir / "bun").chmod(0o755)
        if not shutil.which("nproc"):
            (bin_dir / "nproc").write_text("#!/bin/sh\necho 4\n")
            (bin_dir / "nproc").chmod(0o755)
        self.bin = bin_dir
        self.calls = self.tmp / "calls"
        self.marker = self.tmp / "no-verdict"

    def run_shard(self, report: dict, exit_1: int, exit_2: int = 0, no_verdict_file: bool = True) -> tuple[int, list[str]]:
        report_path = self.tmp / "report.json"
        report_path.write_text(json.dumps(report))
        env = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "RUNNER_TEMP": str(self.tmp),
            "CALLS": str(self.calls),
            "REPORT_1": str(report_path),
            "EXIT_1": str(exit_1),
            "EXIT_2": str(exit_2),
        }
        if no_verdict_file:
            env["API_WORKERD_NO_VERDICT_FILE"] = str(self.marker)
        proc = subprocess.run(
            ["bash", str(ROOT / "scripts" / "ci" / "api-workerd-shard.sh"), "10", "12"],
            cwd=self.tmp, env=env, capture_output=True, text=True,
        )
        return proc.returncode, self.calls.read_text().splitlines() if self.calls.exists() else []

    @staticmethod
    def report(*statuses: str) -> dict:
        failed = sum(1 for s in statuses if s == "failed")
        return {
            "numTotalTests": 3 * len(statuses),
            "numFailedTests": failed,
            "testResults": [{"name": f"/w/test/f{i}.test.ts", "status": s} for i, s in enumerate(statuses)],
        }

    def test_all_passed_with_errors_outside_the_tests_is_no_verdict_not_a_rerun_here(self) -> None:
        # Shard 10/12 of run 45621873127: 69 of 69 passed, 6 pool start timeouts, exit 1.
        code, calls = self.run_shard(self.report("passed", "passed"), exit_1=1)
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 1, "no rerun on the same slow host")
        self.assertTrue(self.marker.exists())

    def test_without_the_marker_path_it_still_reruns_the_whole_shard(self) -> None:
        # The gate's own rerun sets no marker path: there it is the second runner's answer.
        code, calls = self.run_shard(self.report("passed", "passed"), exit_1=1, exit_2=1, no_verdict_file=False)
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)
        self.assertFalse(self.marker.exists())

    def test_a_failed_file_reruns_alone_and_decides(self) -> None:
        code, calls = self.run_shard(self.report("passed", "failed"), exit_1=1, exit_2=0)
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 2)
        self.assertIn("/w/test/f1.test.ts", calls[1])
        self.assertIn("--maxWorkers=1", calls[1])
        self.assertFalse(self.marker.exists())

    def test_a_green_first_run_is_green(self) -> None:
        code, calls = self.run_shard(self.report("passed"), exit_1=0)
        self.assertEqual((code, len(calls)), (0, 1))
        self.assertFalse(self.marker.exists())


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
        self.assertGreaterEqual(upload["with"]["retention-days"], 30, "a re-run needs the passing shards' verdicts")
        self.assertIn("${{ github.run_attempt }}", record["run"])
        marker = test_step["env"]["API_WORKERD_NO_VERDICT_FILE"]
        self.assertEqual(marker, "${{ runner.temp }}/api-workerd-no-verdict")
        self.assertIn('"$RUNNER_TEMP/api-workerd-no-verdict"', record["run"])
        self.assertEqual(upload["with"]["if-no-files-found"], "ignore")
        # A tree-result hit skips the tests (this input tree already passed them): it still records `success`, or the
        # gate would take the missing verdict for a dead runner and rerun a green shard.
        if "steps.tree.outputs.hit" in str(test_step.get("if", "")):
            for s in (record, upload):
                self.assertIn("steps.tree.outputs.hit == 'true'", s["if"])
            self.assertIn('[ "${{ steps.tree.outputs.hit }}" = true ] && outcome=success', record["run"])

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
        self.assertIn('--verdict-dir "$RUNNER_TEMP/api-workerd-verdict" --attempt "$GITHUB_RUN_ATTEMPT"', rerun["run"])
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
            self.assertIn(f"node-v{version}-linux-arm64.tar.gz", pins)

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
