#!/usr/bin/env python3
"""scripts/ci/run-checks-concurrently.sh runs the cmux-next checks job's script tests a few at a time.

The step ran 72 scripts one after another for 203 s of the job's 6 min, two of
them 55 s and 42 s (job 118379816214). Run concurrently, the step takes about as
long as its slowest script; every script still runs, its output still prints
whole and in order, and any failure fails the step by name.
"""

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts/ci/run-checks-concurrently.sh"
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"


def run(commands: str, *args: str, budget: str | None = None) -> subprocess.CompletedProcess:
    env = {key: value for key, value in os.environ.items() if key != "CMUX_CI_CPU_BUDGET"}
    if budget is not None:
        env["CMUX_CI_CPU_BUDGET"] = budget
    return subprocess.run(["bash", str(RUNNER), *args], input=commands, capture_output=True,
                          text=True, timeout=60, cwd=ROOT, env=env)


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

    def test_the_job_cpu_share_caps_the_pool(self):
        # A mini's runner hook grants a job its cores (CMUX_CI_CPU_BUDGET). The checks job asked for one check per
        # core of the whole 14-core mini while it held 5 (job 131984422217: prepush gate 693 s there, 238 s on a
        # 16 vCPU Linux runner), so the pool runs no wider than the grant.
        result = run("echo a\necho b\necho c\n", "--jobs", "14", budget="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3 checks, 2 at a time", result.stdout)
        self.assertIn("CMUX_CI_CPU_BUDGET=2 caps the pool at 2 (was 14)", result.stdout)
        # A narrower --jobs, an unset or a malformed budget keep --jobs
        self.assertIn("3 checks, 1 at a time", run("echo a\necho b\necho c\n", "--jobs", "1", budget="4").stdout)
        self.assertIn("3 checks, 3 at a time", run("echo a\necho b\necho c\n", "--jobs", "3").stdout)
        self.assertIn("3 checks, 3 at a time", run("echo a\necho b\necho c\n", "--jobs", "3", budget="x").stdout)

    def test_the_checks_job_starts_the_prepush_gate_first(self):
        # The prepush gate suite is the pool's longest command (238 s on Linux, 693 s on a mini): started first, a
        # pool as narrow as the job's share does not leave it for last.
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        start = next(s for s in document["jobs"]["checks"]["steps"]
                     if "run-checks-concurrently.sh --start" in str(s.get("run", "")))
        commands = [line.strip() for line in start["run"].split("<<'CHECKS'", 1)[1].splitlines()
                    if line.strip() and not line.strip().startswith(("[", "#"))]
        self.assertEqual(commands[0], "python3 tests/test_cmux_next_prepush_gate.py")
        self.assertEqual(commands.count("python3 tests/test_cmux_next_prepush_gate.py"), 1)

    def test_skips_blank_lines_and_comments(self):
        result = run("\n  # a note\n  echo only\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 checks", result.stdout)

    def test_refuses_empty_input(self):
        self.assertEqual(run("# nothing\n").returncode, 2)

    def test_the_checks_job_runs_its_script_tests_through_it(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        checks = document["jobs"]["checks"]["steps"]
        step = next(step for step in checks if step.get("id") == "script-tests")
        self.assertIn('scripts/ci/run-checks-concurrently.sh --wait "$RUNNER_TEMP/background-checks" script-tests',
                      step["run"])
        # The background start lists them under the step's id, before that step.
        start = next(s for s in checks if "run-checks-concurrently.sh --start" in str(s.get("run", "")))
        self.assertLess(checks.index(start), checks.index(step))
        self.assertIn("""scripts/ci/run-checks-concurrently.sh --start "$RUNNER_TEMP/background-checks" """,
                      start["run"])
        listed = start["run"].split("[script-tests]", 1)[1]
        # The waits these two assert run on a virtual clock, so the wide pool cannot slow them into a failure.
        for script in ("pin-cmux-tui-run-check.test.sh", "pin-cmux-tui-probe.test.sh"):
            self.assertIn(f"bash scripts/cmux-next/tests/{script}", listed.split("[", 1)[0])
            source = (ROOT / "scripts/cmux-next/tests" / script).read_text(encoding="utf-8")
            self.assertIn('fake_clock_install "$TMP/clock"', source)

class APoolDeadlineEndsInAVerdict(unittest.TestCase):
    """cmux#42669's checks job (job 132210422131, cmuxs-mac-mini-6-glaeda-3) was cancelled at its 35 min cap inside
    "Tier routing": that step waited 8 min for its 7 background commands, which had run since 22:38:10, and the cap
    cancelled it at 23:05:55 with no line naming the command still running. A command past the pool's deadline
    stops, fails by name and says why, so the job reaches its verdict step before the cap."""

    def test_a_command_past_the_deadline_stops_and_fails_by_name(self):
        start = time.monotonic()
        result = run("sleep 40\necho fast\n", "--jobs", "2", "--deadline-at", str(int(time.time()) + 2))
        self.assertLess(time.monotonic() - start, 20, "the deadline did not stop the slow command")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("::group::echo fast: ok", result.stdout)
        self.assertIn("::error title=check failed::sleep 40", result.stdout)
        self.assertRegex(result.stdout, r"sleep 40: timed out at the pool deadline after \d+s")

    def test_a_background_wait_ends_at_the_deadline_and_names_what_ran(self):
        with tempfile.TemporaryDirectory() as tmp:
            pool = Path(tmp, "pool")
            started = subprocess.run(
                ["bash", str(RUNNER), "--start", str(pool), "--jobs", "2", "--deadline-at", str(int(time.time()) + 2)],
                input="[slow]\nsleep 40\n[quick]\necho quick\n", capture_output=True, text=True, timeout=30, cwd=ROOT)
            self.assertEqual(started.returncode, 0, started.stdout + started.stderr)
            start = time.monotonic()
            waited = subprocess.run(["bash", str(RUNNER), "--wait", str(pool), "slow"], capture_output=True, text=True,
                                    timeout=60, cwd=ROOT, env={**os.environ, "CHECK_POOL_HEARTBEAT": "1"})
            self.assertLess(time.monotonic() - start, 20, "the wait outlived the pool deadline")
            self.assertEqual(waited.returncode, 1, waited.stdout + waited.stderr)
            # While it waits, it names the command still running (a cap cancel then shows which one).
            self.assertRegex(waited.stdout, r"slow: still running after \d+s: sleep 40")
            self.assertRegex(waited.stdout, r"sleep 40: timed out at the pool deadline after \d+s")
            quick = subprocess.run(["bash", str(RUNNER), "--wait", str(pool), "quick"], capture_output=True,
                                   text=True, timeout=30, cwd=ROOT)
            self.assertEqual(quick.returncode, 0, quick.stdout + quick.stderr)

    def test_no_deadline_keeps_a_command_running(self):
        result = run("sleep 2; echo late\n", "--jobs", "1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("late", result.stdout)

    def test_the_checks_job_sets_a_deadline_inside_its_cap(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        job = document["jobs"]["checks"]
        start = next(s for s in job["steps"] if "run-checks-concurrently.sh --start" in str(s.get("run", "")))
        self.assertIn('--deadline-at "$deadline"', start["run"])
        # The step reads the job's own cap, never a copy of it that can drift.
        self.assertEqual(start["env"]["JOB_TIMEOUT_MINUTES"], job["timeout-minutes"])
        # The job clock starts when the runner writes the event file (Set up job), before the runner hook's wait.
        self.assertIn('"$GITHUB_EVENT_PATH"', start["run"])
        self.assertIn("POOL_TAIL_SECONDS", start["run"])


if __name__ == "__main__":
    unittest.main()
