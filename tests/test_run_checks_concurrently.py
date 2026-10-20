#!/usr/bin/env python3
"""scripts/ci/run-checks-concurrently.sh runs the cmux-next checks job's script tests a few at a time.

The step ran 72 scripts one after another for 203 s of the job's 6 min, two of
them 55 s and 42 s (job 118379816214). Run concurrently, the step takes about as
long as its slowest script; every script still runs, its output still prints
whole and in order, and any failure fails the step by name.
"""

import subprocess
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts/ci/run-checks-concurrently.sh"
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"


def run(commands: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(RUNNER), *args], input=commands, capture_output=True,
                          text=True, timeout=60, cwd=ROOT)


class RunChecksConcurrently(unittest.TestCase):
    def test_runs_commands_at_the_same_time(self):
        start = time.monotonic()
        result = run("sleep 1\nsleep 1\nsleep 1\nsleep 1\n", "--jobs", "4")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(time.monotonic() - start, 3.5)

    def test_prints_each_output_whole_in_input_order(self):
        result = run("sleep 1; echo first\necho second\n", "--jobs", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(result.stdout.index("first"), result.stdout.index("second"))
        self.assertIn("::group::sleep 1; echo first: ok", result.stdout)

    def test_a_failure_fails_by_name_and_the_rest_still_run(self):
        result = run("echo before\nexit 3\necho after\n", "--jobs", "1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("after", result.stdout)
        self.assertIn("::error title=check failed::exit 3", result.stdout)
        self.assertIn("2 passed, 1 failed", result.stdout)

    def test_skips_blank_lines_and_comments(self):
        result = run("\n  # a note\n  echo only\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 checks", result.stdout)

    def test_refuses_empty_input(self):
        self.assertEqual(run("# nothing\n").returncode, 2)

    def test_the_checks_job_runs_its_script_tests_through_it(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        step = next(step for step in document["jobs"]["checks"]["steps"] if step.get("id") == "script-tests")
        self.assertIn("scripts/ci/run-checks-concurrently.sh <<'CHECKS'", step["run"])
        pool, timed = step["run"].split("--jobs 2 <<'CHECKS'", 1)
        # These two assert wall-clock limits: never in the wide pool.
        for script in ("pin-cmux-tui-run-check.test.sh", "pin-cmux-tui-probe.test.sh"):
            self.assertNotIn(script, pool)
            self.assertIn(f"bash scripts/cmux-next/tests/{script}", timed)
        self.assertIn('exit "$status"', step["run"])


if __name__ == "__main__":
    unittest.main()
