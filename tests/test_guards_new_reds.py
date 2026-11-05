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

    def run_rerun(self, head, base, rerun, *extra):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for name, results in (("head", head), ("base", base), ("rerun", rerun)):
                path = Path(tmp) / f"{name}.json"
                if results is not None:
                    path.write_text(json.dumps(results))
                paths.append(str(path))
            return subprocess.run([sys.executable, str(SCRIPT), "--label", "Webview test", *extra,
                                   "--head-rerun", paths[2], paths[0], paths[1]], capture_output=True, text=True)

    def test_a_head_red_that_passes_alone_on_the_head_is_a_warning(self):
        # #27710 (run 41525196343): three gallery-frame timeouts on long head shards with no retry budget left,
        # each passing on the base replay; the base push after the merge passed all three.
        red = "test/reasoning-own-control.test.ts"
        named = "test/session-info-per-pane.test.ts > chromium: closing Session Info in one pane leaves the other pane's open"
        done = self.run_rerun({red: False, named: False, "test/ok.test.ts": True}, {red: True, named: True},
                              {red: True, "test/session-info-per-pane.test.ts": True})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertNotIn("::error", done.stdout)
        self.assertIn(f"::warning title=Webview test passed again alone on the head::{red}", done.stdout)
        self.assertIn(f"webview test red step (flaky): {named}", done.stdout)
        self.assertIn("0 webview test steps red on this change, 0 red on the base too, 2 flaky on the base", done.stdout)
        self.assertIn("2 of the flaky passed again when re-run alone on the head", done.stdout)

    def test_a_head_red_not_on_the_base_that_fails_again_on_the_head_is_the_changes(self):
        red = "test/composer-history.test.ts > older page"
        for rerun in ({"test/composer-history.test.ts > older page": False}, {}, None):
            done = self.run_rerun({red: False}, {"test/composer-history.test.ts": True}, rerun)
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            self.assertIn(f"::error title=Webview test red on this change::{red}", done.stdout)
            self.assertNotIn("passed again", done.stdout)

    def test_a_head_rerun_never_clears_a_base_red_or_another_files_red(self):
        done = self.run_rerun({"test/a.test.ts > x": False, "test/b.test.ts > y": False},
                              {"test/a.test.ts > x": False, "test/b.test.ts > y": True}, {"test/a.test.ts": True})
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("webview test red step (base): test/a.test.ts > x", done.stdout)
        self.assertIn("::error title=Webview test red on this change::test/b.test.ts > y", done.stdout)

    def test_a_named_pass_in_a_failed_rerun_clears_only_that_test(self):
        done = self.run_rerun(
            {"test/a.test.ts > passed": False, "test/a.test.ts > remains": False},
            {"test/a.test.ts": True},
            {"test/a.test.ts > passed": True, "test/a.test.ts > remains": False},
        )
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("::warning title=Webview test passed again alone on the head::test/a.test.ts > passed", done.stdout)
        self.assertIn("::error title=Webview test red on this change::test/a.test.ts > remains", done.stdout)

    def test_a_green_head_with_reds_only_on_the_base_is_green(self):
        done = self.run_it({"test/a.test.ts": True, "test/b.test.ts": True}, {"test/a.test.ts": False})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertNotIn("::error", done.stdout)

    def test_new_files_lists_the_files_of_the_changes_reds_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            head, base, flaky = (Path(tmp) / name for name in ("head.json", "base.json", "flaky"))
            head.write_text(json.dumps({"test/a.test.ts > x": False, "test/a.test.ts > y": False, "test/b.test.ts": False,
                                        "test/c.test.ts > z": False, "test/d.test.ts > w": False, "test/e.test.ts": True}))
            base.write_text(json.dumps({"test/b.test.ts": False}))
            flaky.write_text("test/c.test.ts > z\n")
            done = subprocess.run([sys.executable, str(SCRIPT), "--new-files", "--flaky", str(flaky), str(head), str(base)],
                                  capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertEqual(done.stdout.splitlines(), ["test/a.test.ts", "test/d.test.ts"])
            done = subprocess.run([sys.executable, str(SCRIPT), "--new-files", str(Path(tmp) / "none.json"), str(base)],
                                  capture_output=True, text=True)
            self.assertEqual((done.returncode, done.stdout), (0, ""))

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


class RedStepsForTheBaseRerun(unittest.TestCase):
    """cmux-next-guards.yml re-runs on the base only the steps red on the head (--red-steps, then
    run_ci_guards.py --step): a step green on the head is never the change's, whatever the base says."""

    def red(self, head):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "head.json"
            if head is not None:
                path.write_text(json.dumps(head))
            return subprocess.run([sys.executable, str(SCRIPT), "--red-steps", str(path)], capture_output=True, text=True)

    def test_each_red_step_once_with_its_checks_folded_in(self):
        done = self.red({"lint": False, "ok": True, "wired :: a": False, "wired :: b": False, "wired": False,
                         "fleet :: x": True})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.splitlines(), ["lint", "wired"])
        self.assertEqual(run_ci_guards.CHECK_SEPARATOR, " :: ")

    def test_a_green_or_missing_head_names_nothing(self):
        self.assertEqual((self.red({"lint": True}).stdout, self.red(None).stdout), ("", ""))

    def test_steps_the_base_did_not_rerun_are_not_charged_to_the_change(self):
        # Base results hold only the re-run steps; a head step missing from them passed on the head.
        done = NewReds.run_it(self, {"lint": False, "ok": True}, {"lint": False})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("0 guard steps red on this change, 1 red on the base too", done.stdout)


class TipAndRedStepLines(unittest.TestCase):
    """A feat-cmux-next push that touches what the guards read is judged at its tip (--tip): every red step fails.
    Judged against the previous tip, a red that persists stayed green, and 18 guard steps sat red on the branch
    unseen until #31366. Each red step is also printed as a plain `guard red step (KIND): STEP` line, the one
    scripts/ci/base_red_excuse.py compares a pull request's red steps with (GitHub drops annotation titles)."""

    def run_tip(self, head):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "head.json"
            path.write_text(json.dumps(head))
            return subprocess.run([sys.executable, str(SCRIPT), "--tip", str(path)], capture_output=True, text=True)

    def test_every_red_step_at_the_tip_fails(self):
        done = self.run_tip({"lint": False, "wired": True, "fleet": False})
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("::error title=Guard red at the tip::lint", done.stdout)
        self.assertIn("guard red step (tip): fleet", done.stdout)
        self.assertNotIn("wired", done.stdout)
        self.assertIn("2 guard steps red at the tip", done.stdout)

    def test_a_green_tip_passes(self):
        done = self.run_tip({"lint": True})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("0 guard steps red at the tip", done.stdout)

    def test_a_comparison_names_each_red_step_with_its_kind(self):
        done = NewReds.run_it(self, {"new": False, "old": False, "ok": True}, {"new": True, "old": False, "ok": True})
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("guard red step (new): new", done.stdout)
        self.assertIn("guard red step (base): old", done.stdout)
        self.assertNotIn("step (new): old", done.stdout)


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
