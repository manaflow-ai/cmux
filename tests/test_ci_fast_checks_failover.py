#!/usr/bin/env python3
"""fast-checks.yml takes its Blacksmith Linux size from the linux runner pool.

On 2026-10-27 the 32 vCPU Blacksmith Linux label started no job for the
organization for a while, and fast-checks.yml named blacksmith-32vcpu-ubuntu-2404
directly. A first fix chose 16 vCPU while the overflow switch's record was set,
but the switch trips only when every probed size stalls, so one stalled size
still held every run. The job now reads fromJSON(vars.RUNNER_POOLS).linux: the
pool (.github/runners.json) declares the sizes, and scripts/ci/runner_pools.py
moves it off a size the probe saw stall. The pool stays on Blacksmith: no job
runs on GitHub-hosted Ubuntu, so it never names vars.LINUX_RUNNER (which the
switch may point at hosted Linux) or a hosted label. Sticky disks work on every
Blacksmith Linux size, so the cache steps stay as they are.
"""

from __future__ import annotations

import re
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "fast-checks.yml"
POOL = "|| fromJSON(vars.RUNNER_POOLS).linux }}"

FORK_BRANCH = re.compile(r"github\.repository_owner != 'manaflow-ai' && 'ubuntu-[0-9.]+' \|\|")
BLACKSMITH_LINUX = re.compile(r"blacksmith-\d+vcpu-ubuntu-\d+(-arm)?")
HOSTED = re.compile(r"ubuntu-(latest|slim|\d)")


def runs_on_lines() -> list[str]:
    text = WORKFLOW.read_text(encoding="utf-8")
    return [line for line in text.splitlines() if re.match(r"^\s*runs-on\s*:", line)]


class FastChecksFailoverTests(unittest.TestCase):
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

    def test_the_label_comes_from_the_linux_pool(self) -> None:
        lines = runs_on_lines()
        self.assertEqual(len(lines), 1)
        line = lines[0].rstrip()
        self.assertTrue(line.endswith(POOL), line.strip())
        # Past the re-dispatch input, no size is written down.
        self.assertNotRegex(line.split("inputs.runner ||")[-1], BLACKSMITH_LINUX)

    def test_the_linux_pool_is_selected_from_the_live_pool_variable(self) -> None:
        lines = runs_on_lines()
        self.assertTrue(lines)
        self.assertTrue(any("fromJSON(vars.RUNNER_POOLS).linux" in line for line in lines))
        for line in lines:
            # The fallback after the broker input is the live pool value, never
            # one hard-coded Blacksmith size.
            self.assertNotRegex(line.split("inputs.runner ||")[-1], BLACKSMITH_LINUX)

    def test_failover_never_reaches_github_hosted_linux(self) -> None:
        lines = runs_on_lines()
        self.assertTrue(lines)
        for line in lines:
            self.assertNotIn("LINUX_RUNNER", line, line.strip())
            # The fork branch is the one hosted label allowed; every other
            # ubuntu image named must be a Blacksmith label.
            rest = FORK_BRANCH.sub("", line, count=1)
            rest = BLACKSMITH_LINUX.sub("", rest)
            self.assertNotRegex(rest, HOSTED, line.strip())

    def test_a_broker_redispatch_may_name_only_a_listed_blacksmith_linux_label(self) -> None:
        # HQ's lane-gh broker dispatches a run again with `runner` when the first waited on a label that started
        # nothing (Leo, 2026-10-28: "just pin the set of the shit that isn't hilariously slow").
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertRegex(text, r"\n      runner:\n(?:        .*\n)*?        default: ''\n")
        line = next(line for line in runs_on_lines() if "inputs.runner" in line)
        listed = re.search(r"contains\(fromJSON\('(\[[^']*\])'\), inputs\.runner\) && inputs\.runner \|\|", line)
        self.assertIsNotNone(listed, line.strip())
        import json
        labels = json.loads(listed.group(1))
        self.assertTrue(labels)
        for label in labels:
            self.assertRegex(label, r"^blacksmith-\d+vcpu-ubuntu-2404$")

    def test_the_hosted_check_catches_hosted_labels(self) -> None:
        for bad in ("runs-on: ubuntu-latest",
                    "runs-on: ${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-latest' || 'blacksmith-32vcpu-ubuntu-2404' }}",
                    'runs-on: "ubuntu-24.04"',
                    "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'ubuntu-22.04' }}"):
            rest = BLACKSMITH_LINUX.sub("", FORK_BRANCH.sub("", bad, count=1))
            self.assertRegex(rest, HOSTED, bad)

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


if __name__ == "__main__":
    unittest.main()
