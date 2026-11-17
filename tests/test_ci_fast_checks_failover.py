#!/usr/bin/env python3
"""fast-checks.yml uses the fleet first and broker-controlled overflow.

The default label is the shared fleet pool.  The lane-gh broker re-dispatches
after its three-minute no-start window with a measured Blacksmith Linux size,
so a missing fleet runner does not leave a run queued forever.  The workflow
does not read mutable repository runner variables or trust an arbitrary input
label.  Cache paths use RUNNER_TEMP because fast checks can run on GCP fleet
workers, owned minis, or Blacksmith.
"""

from __future__ import annotations

import re
import shutil
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

from test_ci_fork_runner_routing import evaluate_runs_on, parse_expression, runner_label_errors

WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "fast-checks.yml"
POOL = "cmux-fleet-linux-x64"

FORK_BRANCH = re.compile(r"github\.repository_owner != 'manaflow-ai' && 'ubuntu-[0-9.]+' \|\|")
BLACKSMITH_LINUX = re.compile(r"blacksmith-\d+vcpu-ubuntu-\d+(-arm)?")
HOSTED = re.compile(r"ubuntu-(latest|slim|\d)")


def runs_on_lines() -> list[str]:
    text = WORKFLOW.read_text(encoding="utf-8")
    return [line for line in text.splitlines() if re.match(r"^\s*runs-on\s*:", line)]


def checks_runs_on() -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    section = text.split("\n  checks:\n", 1)[1]
    return next(line for line in section.splitlines() if re.match(r"^\s*runs-on\s*:", line))


class FastChecksFailoverTests(unittest.TestCase):
    def test_broker_overflow_also_moves_queued_admission(self) -> None:
        selector = yaml.safe_load(WORKFLOW.read_text())["jobs"]["admit"]["runs-on"]
        for requested in (
            "blacksmith-8vcpu-ubuntu-2404",
            "blacksmith-16vcpu-ubuntu-2404",
            "blacksmith-32vcpu-ubuntu-2404",
            "", POOL, "self-hosted", "macos-26", "ubuntu-latest",
            "blacksmith-8vcpu-ubuntu-2404-arm",
            "blacksmith-8vcpu-ubuntu-2404,self-hosted",
            '["blacksmith-8vcpu-ubuntu-2404","self-hosted"]',
        ):
            with self.subTest(requested=requested):
                actual = (evaluate_runs_on(parse_expression(selector[3:-2]), {"inputs.runner": requested})
                          if selector.startswith("${{") else selector)
                # Only the smallest measured Blacksmith size: a picker's re-run
                # route is never 16 or 32 vCPU.
                expected = requested if requested == "blacksmith-8vcpu-ubuntu-2404" else "ubuntu-24.04"
                self.assertEqual(actual, expected)

    def test_admission_guard_keeps_the_overflow_set_exact(self) -> None:
        selector = yaml.safe_load(WORKFLOW.read_text())["jobs"]["admit"]["runs-on"]
        self.assertEqual(runner_label_errors(selector), [])
        for unsafe in (
            selector.replace("blacksmith-8vcpu-ubuntu-2404", POOL),
            selector.replace("'ubuntu-24.04'", "'self-hosted'"),
            selector.replace("contains(", "startsWith("),
            selector.replace("&& inputs.runner", "&& inputs.other_runner"),
            # A picker's re-run route is the smallest measured size only.
            selector.replace('"blacksmith-8vcpu-ubuntu-2404"',
                             '"blacksmith-8vcpu-ubuntu-2404","blacksmith-16vcpu-ubuntu-2404"'),
            selector.replace('"blacksmith-8vcpu-ubuntu-2404"', '"blacksmith-32vcpu-ubuntu-2404"'),
        ):
            with self.subTest(selector=unsafe):
                self.assertNotEqual(runner_label_errors(unsafe), [])

    def run_fast_checks_script(self, command: str, source: str | None = None) -> tuple[subprocess.CompletedProcess[str], dict | None]:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        run_step = workflow.split("      - name: Run fast checks\n", 1)[1]
        script = run_step.split("          python3 - <<'PY'\n", 1)[1].split("\n          PY", 1)[0]
        script = textwrap.dedent(script)
        source = source or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=WORKFLOW.parents[2], text=True).strip()
        with tempfile.TemporaryDirectory() as temp:
            env = os.environ.copy()
            env.update({
                "FAST_CHECKS_COMMAND": command,
                "FAST_CHECKS_DIRECTORY": ".",
                "FAST_CHECKS_SOURCE": source,
                "FAST_CHECKS_TIMEOUT": "30",
                "RUNNER_TEMP": temp,
                "GITHUB_RUN_ID": "test-run",
            })
            result = subprocess.run(
                [sys.executable, "-c", script],
                cwd=WORKFLOW.parents[2],
                env=env,
                capture_output=True,
                text=True,
            )
            receipt_path = Path(temp) / "fast-checks.json"
            receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else None
        return result, receipt

    def run_hosted_guard(self, extra_job: str = "", admission_change: tuple[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        root = WORKFLOW.parents[2]
        guard = (root / "tests/test_ci_self_hosted_guard.sh").read_text()
        function = guard.split("check_no_github_hosted_runners() {", 1)[1].split(
            "\ncheck_no_self_hosted_fleet_runners() {", 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp)
            shutil.copytree(root / ".github/workflows", target / ".github/workflows")
            shutil.copy(root / ".github/runners.json", target / ".github/runners.json")
            workflow = target / ".github/workflows/fast-checks.yml"
            text = workflow.read_text()
            if admission_change:
                before, after = admission_change
                text = text.replace(before, after, 1)
            workflow.write_text(text + extra_job)
            env = os.environ.copy()
            env["ROOT_DIR"] = str(target)
            return subprocess.run(["bash", "-c", "set -euo pipefail\ncheck_no_github_hosted_runners() {"
                                   + function + "\ncheck_no_github_hosted_runners"],
                                  env=env, capture_output=True, text=True)

    def test_main_hosted_guard_accepts_light_admission(self) -> None:
        result = self.run_hosted_guard()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_main_hosted_guard_rejects_copied_admission_exception(self) -> None:
        result = self.run_hosted_guard(extra_job="\n  unrelated:\n    runs-on: ubuntu-24.04 # github-hosted-required: light read-only runner admission\n    steps: []\n")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("FAIL:", result.stdout)

    def test_main_hosted_guard_rejects_release_admission(self) -> None:
        result = self.run_hosted_guard(admission_change=("  admit:\n", "  admit:\n    environment: release\n"))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("FAIL:", result.stdout)

    def test_main_hosted_guard_rejects_privileged_or_macos_admission(self) -> None:
        for before, after in (
            (" || 'ubuntu-24.04' }} #", " || 'macos-26' }} #"),
            ("    permissions:\n      contents: read", "    permissions:\n      contents: write"),
        ):
            with self.subTest(change=after):
                result = self.run_hosted_guard(admission_change=(before, after))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("FAIL:", result.stdout)

    def test_the_label_comes_from_the_linux_pool(self) -> None:
        line = checks_runs_on().rstrip()
        self.assertIn("needs.admit.outputs.runner", line, line.strip())
        self.assertNotIn("CI_CONTROL_RUNNER", line, line.strip())
        self.assertNotIn("RUNNER_POOLS", line, line.strip())
        self.assertIn("blacksmith-8vcpu-ubuntu-2404", line, line.strip())

    def test_the_linux_pool_is_selected_from_the_live_pool_variable(self) -> None:
        line = checks_runs_on()
        self.assertIn("needs.admit.outputs.runner", line)
        self.assertNotIn("CI_CONTROL_RUNNER", line)
        self.assertNotIn("RUNNER_POOLS", line)

    def test_failover_never_reaches_github_hosted_linux(self) -> None:
        line = checks_runs_on()
        self.assertNotIn("LINUX_RUNNER", line, line.strip())
        self.assertNotRegex(line.replace("blacksmith-8vcpu-ubuntu-2404", ""), HOSTED, line.strip())

    def test_a_broker_redispatch_may_name_only_a_listed_blacksmith_linux_label(self) -> None:
        # HQ's lane-gh broker dispatches a run again with `runner` when the first waited on a label that started
        # nothing (Leo, 2026-10-28: "just pin the set of the shit that isn't hilariously slow").
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertRegex(text, r"\n      runner:\n(?:        .*\n)*?        default: ''\n")
        self.assertIn("REQUESTED_RUNNER", text)
        # The runtime allowlist is reviewed on feat-cmux-next and checked out
        # by the admission job; the main wiring must carry both files.
        self.assertIn("scripts/ci/fast_checks_runner.py", text)
        self.assertIn("scripts/ci/pr_runner_pool.py", text)

    def test_cache_paths_are_portable_across_runner_families(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("/home/runner", text)
        self.assertIn("${{ runner.temp }}/fast-checks-cache", text)

    def test_the_hosted_check_catches_hosted_labels(self) -> None:
        for bad in ("runs-on: ubuntu-latest",
                    "runs-on: ${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-latest' || 'blacksmith-32vcpu-ubuntu-2404' }}",
                    'runs-on: "ubuntu-24.04"',
                    "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'ubuntu-22.04' }}"):
            rest = BLACKSMITH_LINUX.sub("", FORK_BRANCH.sub("", bad, count=1))
            self.assertRegex(rest, HOSTED, bad)

    def test_admission_job_is_a_read_only_live_picker(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("permission-organization-self-hosted-runners: read", text)
        admission = text.split("\n  admit:\n", 1)[1].split("\n  checks:\n", 1)[0]
        self.assertRegex(admission, r"(?m)^          ref: [0-9a-f]{40}$")
        self.assertIn("python3 .fast-checks-tools/scripts/ci/fast_checks_runner.py", text)
        self.assertRegex(text, r"sparse-checkout: \|\n\s+scripts/ci/fast_checks_runner\.py\n\s+scripts/ci/pr_runner_pool\.py")
        # pr_runner_pool imports github_spend at load (#34270): without it every admit step failed.
        self.assertRegex(admission, r"\n\s+scripts/ci/github_spend\.py\n")
        self.assertIn("needs: admit", text)
        self.assertIn("if: startsWith(needs.admit.outputs.runner, 'blacksmith-')", text)

    def test_display_commands_skip_with_a_success_receipt(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("import json, os, pathlib, shlex, signal, subprocess, time", text)
        self.assertIn("command_words[:2] == ['cmux-ci', 'run']", text)
        self.assertIn("not any(operator in command_text for operator in ('&&', '||', ';', '|', '&', '\\n'))", text)
        self.assertIn("assert actual == os.environ['FAST_CHECKS_SOURCE']", text)
        self.assertIn("head_after=actual", text)
        self.assertIn("skipped_display=True", text)
        self.assertIn("display checks are advisory and skipped on the fast-checks gating path", text)
        self.assertIn("raise SystemExit(0)", text)

    def test_display_skip_receipt_is_source_verified(self) -> None:
        result, receipt = self.run_fast_checks_script(
            "cmux-ci run --class light --display --script scripts/ci/package-test-lane.sh"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(receipt and receipt["skipped_display"])
        self.assertEqual(receipt["source_sha"], receipt["head_after"])
        self.assertIn("source_tree", receipt)

    def test_mixed_display_command_does_not_skip_a_failure(self) -> None:
        result, receipt = self.run_fast_checks_script(
            "false && printf %s --display"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(receipt and receipt.get("skipped_display"))

    def test_background_display_command_does_not_skip_a_failure(self) -> None:
        result, receipt = self.run_fast_checks_script(
            "cmux-ci run --class light --display --script example.sh & false"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(receipt and receipt.get("skipped_display"))

    def test_display_marker_in_a_shell_comment_does_not_skip_a_failure(self) -> None:
        result, receipt = self.run_fast_checks_script(
            "cmux-ci run --script failing.sh # --display"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(receipt and receipt.get("skipped_display"))

    def test_missing_non_display_command_stays_a_real_failure(self) -> None:
        result, receipt = self.run_fast_checks_script("definitely-missing-fast-check-command")
        self.assertEqual(result.returncode, 127)
        self.assertEqual(receipt and receipt.get("exit_code"), 127)

    def test_shell_comment_with_an_apostrophe_stays_on_the_normal_path(self) -> None:
        result, receipt = self.run_fast_checks_script("printf ok # don't parse this comment")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(receipt and receipt.get("skipped_display"))
        self.assertEqual(receipt and receipt.get("exit_code"), 0)

    def test_display_skip_rejects_a_source_mismatch(self) -> None:
        result, receipt = self.run_fast_checks_script(
            "cmux-ci run --class light --display --script scripts/ci/package-test-lane.sh",
            source="0" * 40,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(receipt)



class HostedLightJobsGuardTests(unittest.TestCase):
    """check_no_github_hosted_runners admits hosted Ubuntu only for the jobs `hosted_light_jobs` declares.

    Leo, 2026-11-01: hosted Ubuntu for declared light jobs. A declaration never admits hosted macOS or Windows,
    or a job that builds, signs, notarizes, publishes or releases.
    """

    def run_guard(self, workflow: str, declare: dict | None) -> subprocess.CompletedProcess[str]:
        root = WORKFLOW.parents[2]
        guard = (root / "tests/test_ci_self_hosted_guard.sh").read_text()
        function = guard.split("check_no_github_hosted_runners() {", 1)[1].split(
            "\ncheck_no_self_hosted_fleet_runners() {", 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp)
            shutil.copytree(root / ".github/workflows", target / ".github/workflows")
            runners = json.loads((root / ".github/runners.json").read_text())
            if declare is not None:
                runners["hosted_light_jobs"]["light-probe.yml:probe"] = declare
            (target / ".github/runners.json").write_text(json.dumps(runners))
            (target / ".github/workflows/light-probe.yml").write_text(workflow)
            env = os.environ.copy()
            env["ROOT_DIR"] = str(target)
            return subprocess.run(["bash", "-c", "set -euo pipefail\ncheck_no_github_hosted_runners() {"
                                   + function + "\ncheck_no_github_hosted_runners"],
                                  env=env, capture_output=True, text=True)

    LIGHT = """\
        name: light probe
        on: workflow_dispatch
        permissions: {}
        jobs:
          probe:
            runs-on: RUNNER
            steps:
              - run: STEP
        """

    def workflow(self, runner: str = "ubuntu-24.04", step: str = "echo ok") -> str:
        return textwrap.dedent(self.LIGHT).replace("RUNNER", runner).replace("STEP", step)

    def test_a_declared_light_job_passes(self) -> None:
        result = self.run_guard(self.workflow(), {"runner": "ubuntu-24.04", "why": "reads one file"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_an_undeclared_hosted_job_fails(self) -> None:
        result = self.run_guard(self.workflow(), None)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("light-probe.yml", result.stdout)

    def test_a_declared_build_or_release_job_fails(self) -> None:
        for step in ("xcodebuild -scheme cmux build", "cargo build --release", "swift build -c release",
                     "./scripts/ci/release-cut.sh", "xcrun notarytool submit x.zip", "gh release create v1"):
            with self.subTest(step=step):
                result = self.run_guard(self.workflow(step=step), {"runner": "ubuntu-24.04", "why": "x"})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("FAIL: hosted light job", result.stdout)

    def test_hosted_macos_or_windows_fails_even_when_declared(self) -> None:
        for runner in ("macos-15", "windows-2025"):
            with self.subTest(runner=runner):
                result = self.run_guard(self.workflow(runner=runner), {"runner": runner, "why": "x"})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("FAIL:", result.stdout)

    def test_a_declared_job_with_write_permission_or_an_environment_fails(self) -> None:
        for before, after in (("permissions: {}", "permissions:\n  contents: write"),
                              ("    runs-on:", "    environment: release\n    runs-on:")):
            with self.subTest(change=after):
                result = self.run_guard(self.workflow().replace(before, after, 1), {"runner": "ubuntu-24.04", "why": "x"})
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_a_declared_job_without_explicit_read_only_permissions_fails(self) -> None:
        # No permissions block inherits the repository's default token, which may write.
        for before, after in (("permissions: {}\n", ""), ("permissions: {}", "permissions: write-all")):
            with self.subTest(change=after or "no block"):
                result = self.run_guard(self.workflow().replace(before, after, 1), {"runner": "ubuntu-24.04", "why": "x"})
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_a_declaration_without_a_usable_why_fails(self) -> None:
        for why in (None, False, 0, [], "", "   "):
            with self.subTest(why=why):
                result = self.run_guard(self.workflow(), {"runner": "ubuntu-24.04", "why": why})
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_a_declared_job_that_releases_through_an_action_fails(self) -> None:
        # docker/build-push-action builds and pushes through its inputs, with no run line (review of #36918).
        for step in ("uses: docker/build-push-action@v6\n        with:\n          push: true",
                     "uses: softprops/action-gh-release@v2",
                     "uses: pypa/gh-action-pypi-publish@release/v1",
                     "uses: actions/github-script@v7\n        with:\n          script: exec('xcodebuild build')",
                     "uses: some/tool@v1\n        env:\n          CMD: cargo build --release"):
            with self.subTest(step=step.split("\n")[0]):
                text = self.workflow().replace("- run: echo ok", "- " + step, 1)
                result = self.run_guard(text, {"runner": "ubuntu-24.04", "why": "x"})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("FAIL: hosted light job", result.stdout)

    def test_a_declared_light_job_may_check_out_and_read(self) -> None:
        text = self.workflow().replace("- run: echo ok", "- uses: actions/checkout@v6\n        with:\n          sparse-checkout: x", 1)
        result = self.run_guard(text, {"runner": "ubuntu-24.04", "why": "x"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_copied_declared_line_on_another_job_fails(self) -> None:
        text = self.workflow() + "  other:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi\n"
        result = self.run_guard(text, {"runner": "ubuntu-24.04", "why": "x"})
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_a_declared_job_whose_selector_could_pick_another_runner_fails(self) -> None:
        # A dispatch input or variable could name macos-15 at run time; only the declared label, or the reviewed
        # fast-checks admission selector (an allowlisted Blacksmith label or the declared one), may be its runs-on.
        for runner in ("${{ inputs.runner || 'ubuntu-24.04' }}", "${{ vars.X || 'ubuntu-24.04' }}",
                       "${{ github.event_name == 'push' && 'ubuntu-24.04' || inputs.runner }}"):
            with self.subTest(runner=runner):
                result = self.run_guard(self.workflow(runner=runner), {"runner": "ubuntu-24.04", "why": "x"})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("FAIL:", result.stdout)


if __name__ == "__main__":
    unittest.main()
