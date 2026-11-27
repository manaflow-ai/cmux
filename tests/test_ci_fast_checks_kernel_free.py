#!/usr/bin/env python3
"""fast-checks.yml's setup=kernel-free runs the exact snapshot on an owned Mac.

`cmux-ci test --setup kernel-free -- CMD` asks for a command that needs no Linux kernel, apt or Docker:
Python, git, shell and macOS tools (`uname -s` prints Darwin there). Before this, cmux's workflow refused
the setup (HTTP 422, not in the allowed values), so an agent that needed macOS for scripts/measure had to
reach a mini by hand. The shared cmux-mac runners take it (the one own-branch Mac label); every other
setup stays on the Linux job. The Mac job keeps the Linux job's trust boundary: dispatch only, a read-only
token, no secrets, the exact snapshot sha, and checkout metadata cleared before checkout.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "fast-checks.yml"
MAC_JOB = "checks-mac"
MAC_LABEL = "cmux-mac"


def document() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8")) or {}


def mac_steps() -> list[dict]:
    return document()["jobs"][MAC_JOB]["steps"]


def run_script(command: str, timeout: str = "30", source: str | None = None) -> tuple[subprocess.CompletedProcess[str], dict | None]:
    run = next(step["run"] for step in mac_steps() if step.get("name") == "Run fast checks")
    script = run.split("python3 - <<'PY'\n", 1)[1].split("\nPY", 1)[0]
    source = source or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    with tempfile.TemporaryDirectory() as temp:
        env = os.environ.copy()
        env.update({"FAST_CHECKS_COMMAND": command, "FAST_CHECKS_DIRECTORY": ".", "FAST_CHECKS_SOURCE": source,
                    "FAST_CHECKS_TIMEOUT": timeout, "RUNNER_TEMP": temp, "GITHUB_RUN_ID": "test-run"})
        result = subprocess.run([sys.executable, "-c", script], cwd=ROOT, env=env, capture_output=True, text=True)
        path = Path(temp) / "fast-checks.json"
        receipt = json.loads(path.read_text()) if path.exists() else None
    return result, receipt


class KernelFreeMacRouteTests(unittest.TestCase):
    def test_kernel_free_is_a_setup_choice(self) -> None:
        on = document().get(True) or document().get("on")
        self.assertIn("kernel-free", on["workflow_dispatch"]["inputs"]["setup"]["options"])

    def test_only_kernel_free_leaves_the_linux_job(self) -> None:
        jobs = document()["jobs"]
        self.assertIn("inputs.setup != 'kernel-free'", jobs["checks"]["if"])
        self.assertIn("inputs.setup == 'kernel-free'", jobs[MAC_JOB]["if"])
        for name in ("checks", MAC_JOB):
            self.assertIn("github.repository == 'manaflow-ai/cmux'", jobs[name]["if"])

    def test_the_mac_job_runs_on_the_owned_side_light_pool(self) -> None:
        # The one own-branch Mac label: no caller-chosen label or paid label reaches the Mac job; the overflow
        # switch (vars.CI_OVERFLOW_MAC, unset by default) is the only other input (docs/design/ci-v2.md).
        self.assertEqual(document()["jobs"][MAC_JOB]["runs-on"],
                         "${{ vars.CI_OVERFLOW_MAC || '" + MAC_LABEL + "' }}")

    def test_the_mac_job_holds_no_secret_or_write_token(self) -> None:
        job = document()["jobs"][MAC_JOB]
        self.assertEqual(job.get("permissions"), {"contents": "read"})
        self.assertNotIn("environment", job)
        text = yaml.safe_dump(job)
        self.assertNotIn("secrets.", text)
        checkouts = [s for s in job["steps"] if str(s.get("uses", "")).startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 1)
        self.assertEqual(checkouts[0]["with"]["ref"], "${{ inputs.source_sha }}")
        self.assertIs(checkouts[0]["with"]["persist-credentials"], False)
        # The Linux job's Blacksmith sticky disks, apt and sudo never run on a Mac.
        for linux_only in ("stickydisk", "sudo ", "apt-get"):
            self.assertNotIn(linux_only, text)

    def test_the_whole_git_directory_goes_before_checkout(self) -> None:
        # The mini keeps the folder between jobs; a kept object store would let one dispatch's command plant objects
        # a later checkout trusts, so nothing of the old .git survives.
        steps = mac_steps()
        clear = next(i for i, s in enumerate(steps) if s.get("name") == "Clear stale checkout metadata")
        checkout = next(i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("actions/checkout@"))
        self.assertLess(clear, checkout)
        self.assertIn("rm -rf -- .fast-checks-checkout/.git", steps[clear]["run"])

    def test_the_receipt_has_the_linux_jobs_fields(self) -> None:
        result, receipt = run_script("uname -s")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FAST_CHECKS_RECEIPT=", result.stdout)
        for key in ("source_sha", "source_tree", "head_after", "exit_code", "command_seconds", "run_id", "cpu_count"):
            self.assertIn(key, receipt)
        self.assertEqual(receipt["exit_code"], 0)

    def test_a_failing_command_fails(self) -> None:
        result, receipt = run_script("exit 3")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(receipt["exit_code"], 3)

    def test_the_deadline_needs_no_gnu_timeout(self) -> None:
        # macOS has no GNU `timeout`: Python keeps the deadline and ends the command's own process group.
        run = next(step["run"] for step in mac_steps() if step.get("name") == "Run fast checks")
        self.assertNotIn("'timeout', '--signal", run)
        result, receipt = run_script("sleep 30", timeout="1")
        self.assertEqual(result.returncode, 124)
        self.assertTrue(receipt["timed_out"])

    def test_a_source_mismatch_writes_no_receipt(self) -> None:
        result, receipt = run_script("true", source="0" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(receipt)


if __name__ == "__main__":
    unittest.main()
