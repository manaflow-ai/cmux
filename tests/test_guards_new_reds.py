#!/usr/bin/env python3
"""scripts/ci/guards_new_reds.py fails only on guard steps a change turns red; the base's reds are warnings.

The ci guard group never ran for feat-cmux-next before cmux-next-guards.yml's job, and 24 of its 134 steps were
already red there (2026-10-21). A job red on every pull request would hide the red a change adds, so the job
compares each step's result on the head with the same runner's result on the base.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/guards_new_reds.py"
RUNNER_GUARD = ROOT / "tests/test_ci_self_hosted_guard.sh"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import run_ci_guards  # noqa: E402


class NewReds(unittest.TestCase):
    def run_it(self, head, base):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for name, results in (("head", head), ("base", base)):
                path = Path(tmp) / f"{name}.json"
                if results is not None:
                    path.write_text(json.dumps(results))
                paths.append(str(path))
            return subprocess.run([sys.executable, str(SCRIPT), *paths], capture_output=True, text=True)

    def run_flaky(self, head, base, flaky):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for name, results in (("head", head), ("base", base)):
                path = Path(tmp) / f"{name}.json"
                path.write_text(json.dumps(results))
                paths.append(str(path))
            listed = Path(tmp) / "flaky"
            if flaky is not None:
                listed.write_text("".join(f"{name}\n" for name in flaky))
            return subprocess.run([sys.executable, str(SCRIPT), "--label", "Webview test", "--flaky", str(listed), *paths],
                                  capture_output=True, text=True)

    def test_a_new_red_that_flips_on_the_base_is_a_warning(self):
        # agent-pane-suggested-tasks' sent image failed now and then on the base and passed its one
        # replay there by chance: 9 of 40 sampled red pull request runs were charged with it (2026-10-30).
        flake = "test/agent-pane-suggested-tasks.test.ts > sends the image"
        done = self.run_flaky({flake: False}, {flake: True}, [flake])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn(f"::warning title=Webview test flaky on the base::{flake}", done.stdout)
        self.assertNotIn("::error", done.stdout)
        self.assertIn("0 webview test steps red on this change, 0 red on the base too, 1 flaky on the base", done.stdout)

    def test_a_flaky_list_excuses_only_the_names_it_lists(self):
        done = self.run_flaky({"test/a.test.ts > flake": False, "test/a.test.ts > broken": False, "test/b.test.ts": False},
                              {}, ["test/a.test.ts > flake", "test/a.test.ts"])
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("::warning title=Webview test flaky on the base::test/a.test.ts > flake", done.stdout)
        self.assertIn("::error title=Webview test red on this change::test/a.test.ts > broken", done.stdout)
        self.assertIn("::error title=Webview test red on this change::test/b.test.ts", done.stdout)

    def test_a_missing_flaky_list_lists_nothing(self):
        done = self.run_flaky({"lint": False}, {"lint": True}, None)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("::error title=Webview test red on this change::lint", done.stdout)

    def test_a_step_red_only_on_the_head_fails(self):
        done = self.run_it({"lint": False, "wired": True}, {"lint": True, "wired": True})
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("::error title=Guard red on this change::lint", done.stdout)

    def test_a_step_red_on_the_base_too_is_a_warning(self):
        done = self.run_it({"lint": False, "wired": True}, {"lint": False, "wired": True})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("::warning title=Guard red on the base too::lint", done.stdout)

    def test_a_new_step_that_fails_is_the_changes(self):
        done = self.run_it({"new step": False}, {})
        self.assertEqual(done.returncode, 1)

    def test_a_step_the_change_fixes_is_said(self):
        done = self.run_it({"lint": True}, {"lint": False})
        self.assertEqual(done.returncode, 0)
        self.assertIn("fixed by this change: lint", done.stdout)

    def test_no_base_results_means_every_red_is_the_changes(self):
        done = self.run_it({"lint": False}, None)
        self.assertEqual(done.returncode, 1)
        self.assertIn("no base results", done.stdout)

    def test_no_head_results_fails(self):
        done = self.run_it(None, {"lint": True})
        self.assertEqual(done.returncode, 1)


class OneCheckCannotMaskAnother(unittest.TestCase):
    """tests/test_ci_self_hosted_guard.sh runs ~30 runner checks as one CI step. When one check went red on
    the base (chief-evals.yml's hosted ubuntu-24.04, 2026-10-26) the whole step was a base warning, and under
    `set -e` the checks after it never ran, so a new hosted or self-hosted runner line in the same step landed
    as a warning. Each check now runs on its own and is compared on its own."""

    STEP = "Validate macOS runner guards"

    def guard_step(self, tmp: Path, failing: list[str]) -> str:
        """A guard script built from the real run_check, with two checks that fail when named in `failing`."""
        source = RUNNER_GUARD.read_text(encoding="utf-8")
        helper = re.search(r"^FAILED_CHECKS=\(\)\nrun_check\(\) \{\n.*?^\}\n", source, re.M | re.S)
        self.assertIsNotNone(helper, "run_check is gone from test_ci_self_hosted_guard.sh")
        tail = re.search(r'^if \[ "\$\{#FAILED_CHECKS\[@\]\}" -ne 0 \]; then\n.*?^fi\n', source, re.M | re.S)
        self.assertIsNotNone(tail, "test_ci_self_hosted_guard.sh no longer fails once after every check ran")
        script = tmp / "guard.sh"
        script.write_text(
            "set -euo pipefail\nROOT_DIR=/nonexistent\n" + helper.group()
            + "check_hosted() { [ %d -eq 0 ] || { echo 'FAIL: hosted'; false; }; echo PASS; }\n" % ("hosted" in failing)
            + "check_fleet() { [ %d -eq 0 ] || { echo 'FAIL: fleet'; exit 1; }; echo PASS; }\n" % ("fleet" in failing)
            + "run_check check_hosted\nrun_check check_fleet\n" + tail.group(),
            encoding="utf-8",
        )
        return f"bash {script}"

    def results(self, failing: list[str]) -> dict[str, bool]:
        with tempfile.TemporaryDirectory() as tmp:
            step = run_ci_guards.Step(self.STEP, self.guard_step(Path(tmp), failing), {}, None)
            unit = run_ci_guards.Unit("workflow-guard-tests", "preflight", [step])
            env = {"PATH": os.environ["PATH"], "HOME": tmp}
            [result] = run_ci_guards.run_steps(unit, [step], env, "0" * 40, keep_going=True)
        outcome = {result.step.name: bool(result.ok)}
        outcome.update({f"{result.step.name}{run_ci_guards.CHECK_SEPARATOR}{c}": ok for c, ok in result.checks.items()})
        return outcome

    def compare(self, head: dict[str, bool], base: dict[str, bool]) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for name, results in (("head", head), ("base", base)):
                path = Path(tmp) / f"{name}.json"
                path.write_text(json.dumps(results))
                paths.append(str(path))
            return subprocess.run([sys.executable, str(SCRIPT), *paths], capture_output=True, text=True)

    def test_every_check_runs_after_an_earlier_one_fails(self):
        head = self.results(["hosted", "fleet"])
        self.assertFalse(head[self.STEP])
        self.assertFalse(head[f"{self.STEP} :: check_hosted"])
        self.assertFalse(head[f"{self.STEP} :: check_fleet"], "the second check never ran after the first failed")

    def test_a_base_red_check_does_not_mask_a_new_red_check_in_the_same_step(self):
        base = self.results(["hosted"])
        head = self.results(["hosted", "fleet"])
        done = self.compare(head, base)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn(f"::error title=Guard red on this change::{self.STEP} :: check_fleet", done.stdout)
        self.assertIn(f"::warning title=Guard red on the base too::{self.STEP} :: check_hosted", done.stdout)

    def test_the_same_base_red_alone_stays_a_warning(self):
        base = self.results(["hosted"])
        done = self.compare(self.results(["hosted"]), base)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_a_base_from_before_the_split_excuses_no_check(self):
        # The base's step was red as a whole: that says nothing about which check, so every red check is
        # the change's until the base reports its checks (fails closed for one landing).
        done = self.compare(self.results(["hosted"]), {self.STEP: False})
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn(f"::error title=Guard red on this change::{self.STEP} :: check_hosted", done.stdout)


if __name__ == "__main__":
    unittest.main()
