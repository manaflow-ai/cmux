#!/usr/bin/env python3
"""One runner guard check red on the base can neither skip nor excuse a different one red on the change.

tests/test_ci_self_hosted_guard.sh runs ~30 runner checks in one CI step. It used to run them under
`set -e`, so the first red check stopped the rest, and the step failed as a whole. Once one check went
red on the base (a hosted `runs-on: ubuntu-24.04` in chief-evals.yml, 2026-10-26), the base-red
comparison saw the same red step on the base and the change, and every later runner violation landed
as the base's. Now `run_check` runs each check on its own and prints each failed check as a cargo-style
`test runner-guard/<check> ... FAILED` line. scripts/ci/base_red_excuse.py (gh-merge-green) always
compares failing test names with the base's, even beside other failing tests in the job, so a head with
a red check the base does not have is never excused.
"""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNNER_GUARD = ROOT / "tests/test_ci_self_hosted_guard.sh"
STEP = "Validate macOS runner guards"
JOB = "workflow-guard-tests / preflight"

# Imported by name, never loaded by path: one module object per file, so a test that patches it
# patches what every other test reads (tests/test_script_module_loads.py).
import sys  # noqa: E402
if str(ROOT / "scripts/ci") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
import base_red_excuse as excuse  # noqa: E402


def fixture_env() -> dict[str, str]:
    """The fixtures' red checks are not this step's: the guard runner (run_ci_guards.py) points
    CMUX_GUARD_CHECK_RESULTS at the running step's results, so the fixtures must not inherit it."""
    return {k: v for k, v in os.environ.items() if k != "CMUX_GUARD_CHECK_RESULTS"}


def guard_script(failing: set[str]) -> str:
    """A guard script built from the real run_check, with two checks that fail when named in `failing`.
    check_hosted fails with `false` under set -e, check_fleet with `exit 1`."""
    source = RUNNER_GUARD.read_text(encoding="utf-8")
    helper = re.search(r"^FAILED_CHECKS=\(\)\nrun_check\(\) \{\n.*?^\}\n", source, re.M | re.S)
    tail = re.search(r'^if \[ "\$\{#FAILED_CHECKS\[@\]\}" -ne 0 \]; then\n.*?^fi\n', source, re.M | re.S)
    assert helper and tail, "run_check or its final verdict is gone from test_ci_self_hosted_guard.sh"
    return (
        "set -euo pipefail\nROOT_DIR=/nonexistent\n" + helper.group()
        + "check_hosted() { [ %d -eq 0 ] || { echo 'FAIL: hosted runner in chief-evals.yml:35'; false; }; echo PASS; }\n"
        % ("hosted" in failing)
        + "check_fleet() { [ %d -eq 0 ] || { echo 'FAIL: self-hosted fleet label in ci.yml:12'; exit 1; }; echo PASS; }\n"
        % ("fleet" in failing)
        + "run_check check_hosted\nrun_check check_fleet\n" + tail.group()
    )


def run_guard(failing: set[str]) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / "guard.sh"
        script.write_text(guard_script(failing), encoding="utf-8")
        return subprocess.run(["bash", str(script)], capture_output=True, text=True, env=fixture_env())


def job_and_log(failing: set[str], other_test: bool = False) -> tuple[dict, str]:
    """The failed CI job and its `gh run view --log` text, as base_red_excuse.py reads them; with
    `other_test`, an unrelated failing unittest in the same job, red on the base too."""
    done = run_guard(failing)
    # Framed as the runner logs a job, so base_red_excuse.step_owners places each line in its step (a log it does
    # not place has no signature): "Set up job", one `Run` header per step, "Complete job".
    def step(number, name, conclusion, start, end):
        return {"number": number, "name": name, "status": "completed", "conclusion": conclusion,
                "started_at": f"2026-10-27T02:10:{start:02d}Z", "completed_at": f"2026-10-27T02:10:{end:02d}Z"}

    job = {"id": 1, "run_id": 1, "name": JOB, "status": "completed", "conclusion": "failure",
           "steps": [step(1, "Set up job", "success", 0, 2), step(2, "Checkout", "success", 3, 5),
                     step(3, STEP, "failure", 10, 40), step(4, "Complete job", "success", 40, 40)]}
    lines = done.stdout.splitlines() + ["##[error]Process completed with exit code 1."]
    if other_test:
        lines = ["FAIL: test_unrelated (test_other.Other.test_unrelated)"] + lines
    framed = ([("Set up job", 0, "Current runner version: '2.338.2'"),
               ("Checkout", 3, "##[group]Run actions/checkout@v6"), (STEP, 10, "##[group]Run tests/run-guards.sh"),
               (STEP, 10, "##[endgroup]")] + [(STEP, 37, line) for line in lines])
    log = "\n".join(f"{JOB}\t{name}\t2026-10-27T02:10:{at:02d}.8032610Z {line}" for name, at, line in framed)
    return job, log


class EveryCheckRuns(unittest.TestCase):
    def test_a_red_check_does_not_stop_the_next(self):
        done = run_guard({"hosted", "fleet"})
        self.assertEqual(done.returncode, 1)
        self.assertIn("FAIL: self-hosted fleet label", done.stdout, "the second check never ran")
        self.assertIn("FAIL: 2 runner guard check(s) failed", done.stdout)

    def test_all_green_passes(self):
        self.assertEqual(run_guard(set()).returncode, 0)

    def test_a_check_with_arguments_is_one_test_name(self):
        source = guard_script({"hosted"}).replace("run_check check_hosted\n",
                                                  "run_check check_hosted \"$ROOT_DIR/ci.yml\" job\n")
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "guard.sh"
            script.write_text(source, encoding="utf-8")
            out = subprocess.run(["bash", str(script)], capture_output=True, text=True, env=fixture_env()).stdout
        self.assertIn("test runner-guard/check_hosted_ci.yml_job ... FAILED\n", out)

    def test_each_failed_check_and_finding_is_an_error_line(self):
        out = run_guard({"hosted", "fleet"}).stdout
        for line in ("error: check_hosted: FAIL: hosted runner in chief-evals.yml:35",
                     "test runner-guard/check_hosted ... FAILED",
                     "error: check_fleet: FAIL: self-hosted fleet label in ci.yml:12",
                     "test runner-guard/check_fleet ... FAILED"):
            self.assertIn(line + "\n", out)

    def test_every_runner_check_goes_through_run_check(self):
        source = RUNNER_GUARD.read_text(encoding="utf-8")
        bare = re.findall(r"^(check_[a-z0-9_]+)(?: .*)?$", source, re.M)
        self.assertEqual(bare, [], "call these as `run_check NAME` so a red one cannot skip or hide the rest")
        defined = set(re.findall(r"^(check_[a-z0-9_]+)\(\) \{", source, re.M))
        called = set(re.findall(r"^run_check (check_[a-z0-9_]+)", source, re.M))
        self.assertEqual(defined - called, set(), "defined but never run")


class ABaseRedCannotExcuseAnother(unittest.TestCase):
    def missing(self, head_failing: set[str], base_failing: set[str], *, other_test: bool = False) -> set[str]:
        """What base_red_excuse.py finds on the head and not the base: failing test names, always compared,
        or error lines when no test name failed."""
        head_steps, head_tests, head_errors = excuse.signature(excuse.failed_view(
            *job_and_log(head_failing, other_test), step_names=excuse.STEP_NAMES_UNKNOWN, base=False))
        base_steps, base_tests, base_errors = excuse.signature(excuse.failed_view(
            *job_and_log(base_failing, other_test), step_names=excuse.STEP_NAMES_UNKNOWN, base=True))
        self.assertEqual(head_steps, base_steps)
        if head_tests:
            return head_tests - base_tests
        return head_errors - base_errors

    def test_a_new_red_check_beside_a_base_red_one_is_the_changes(self):
        missing = self.missing({"hosted", "fleet"}, {"hosted"})
        self.assertTrue(missing, "the base's red check excused a different red check")
        self.assertTrue(all("check_fleet" in line for line in missing), missing)

    def test_the_same_base_red_alone_is_excused(self):
        self.assertEqual(self.missing({"hosted"}, {"hosted"}), set())

    def test_another_failing_test_in_the_job_does_not_hide_a_new_red_check(self):
        missing = self.missing({"hosted", "fleet"}, {"hosted"}, other_test=True)
        self.assertEqual(missing, {"runner-guard/check_fleet"})
        self.assertEqual(self.missing({"hosted"}, {"hosted"}, other_test=True), set())


if __name__ == "__main__":
    unittest.main()
