#!/usr/bin/env python3
"""One runner guard check red on the base can neither skip nor excuse a different one red on the change.

tests/test_ci_self_hosted_guard.sh runs ~30 runner checks in one CI step. It used to run them under
`set -e`, so the first red check stopped the rest, and the step failed as a whole. Once one check went
red on the base (a hosted `runs-on: ubuntu-24.04` in chief-evals.yml, 2026-10-26), the base-red
comparison saw the same red step on the base and the change, and every later runner violation landed
as the base's. Now `run_check` runs each check on its own and prints one `error:` line per failed check
and per finding. scripts/ci/base_red_excuse.py (gh-merge-green) compares a red step's error lines with
the base's, so a head with a red check the base does not have is never excused.
"""
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNNER_GUARD = ROOT / "tests/test_ci_self_hosted_guard.sh"
STEP = "Validate macOS runner guards"
JOB = "workflow-guard-tests / preflight"

spec = importlib.util.spec_from_file_location("base_red_excuse", ROOT / "scripts/ci/base_red_excuse.py")
excuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(excuse)


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
        return subprocess.run(["bash", str(script)], capture_output=True, text=True)


def job_and_log(failing: set[str]) -> tuple[dict, str]:
    """The failed CI job and its `gh run view --log` text, as base_red_excuse.py reads them."""
    done = run_guard(failing)
    job = {"id": 1, "run_id": 1, "name": JOB, "status": "completed", "conclusion": "failure",
           "steps": [{"name": "Checkout", "status": "completed", "conclusion": "success"},
                     {"name": STEP, "status": "completed", "conclusion": "failure"}]}
    lines = done.stdout.splitlines() + ["##[error]Process completed with exit code 1."]
    log = "\n".join(f"{JOB}\t{STEP}\t2026-10-27T02:10:37.8032610Z {line}" for line in lines)
    return job, log


class EveryCheckRuns(unittest.TestCase):
    def test_a_red_check_does_not_stop_the_next(self):
        done = run_guard({"hosted", "fleet"})
        self.assertEqual(done.returncode, 1)
        self.assertIn("FAIL: self-hosted fleet label", done.stdout, "the second check never ran")
        self.assertIn("FAIL: 2 runner guard check(s) failed", done.stdout)

    def test_all_green_passes(self):
        self.assertEqual(run_guard(set()).returncode, 0)

    def test_each_failed_check_and_finding_is_an_error_line(self):
        out = run_guard({"hosted", "fleet"}).stdout
        for line in ("error: check_hosted: FAIL: hosted runner in chief-evals.yml:35",
                     "error: runner guard check failed: check_hosted",
                     "error: check_fleet: FAIL: self-hosted fleet label in ci.yml:12",
                     "error: runner guard check failed: check_fleet"):
            self.assertIn(line + "\n", out)

    def test_every_runner_check_goes_through_run_check(self):
        source = RUNNER_GUARD.read_text(encoding="utf-8")
        bare = re.findall(r"^(check_[a-z0-9_]+)(?: .*)?$", source, re.M)
        self.assertEqual(bare, [], "call these as `run_check NAME` so a red one cannot skip or hide the rest")
        defined = set(re.findall(r"^(check_[a-z0-9_]+)\(\) \{", source, re.M))
        called = set(re.findall(r"^run_check (check_[a-z0-9_]+)", source, re.M))
        self.assertEqual(defined - called, set(), "defined but never run")


class ABaseRedCannotExcuseAnother(unittest.TestCase):
    def missing(self, head_failing: set[str], base_failing: set[str]) -> set[str]:
        """The head's error lines the base lacks: what base_red_excuse.py refuses to excuse
        (it compares error lines when no test name failed, as here)."""
        head_steps, head_tests, head_errors = excuse.signature(*job_and_log(head_failing))
        base_steps, base_tests, base_errors = excuse.signature(*job_and_log(base_failing))
        self.assertEqual(head_tests, set(), "a check's finding parsed as a test name, so errors are not compared")
        self.assertEqual(head_steps, base_steps)
        return head_errors - base_errors

    def test_a_new_red_check_beside_a_base_red_one_is_the_changes(self):
        missing = self.missing({"hosted", "fleet"}, {"hosted"})
        self.assertTrue(missing, "the base's red check excused a different red check")
        self.assertTrue(all("check_fleet" in line for line in missing), missing)

    def test_the_same_base_red_alone_is_excused(self):
        self.assertEqual(self.missing({"hosted"}, {"hosted"}), set())


if __name__ == "__main__":
    unittest.main()
