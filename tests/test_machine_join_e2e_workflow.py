#!/usr/bin/env python3
"""machine-join-e2e.yml keeps the scope it was cleared for.

The workflow holds the repo's dev stack account and adds an OS user, so these
hold for good: manual dispatch only; feat-cmux-next only; top-level
`permissions: contents: read` and nothing else (no job-level grants); the stack
secrets reach exactly one step, through `env`; no `set -x`; the platform origin
is development's; the runner is an ephemeral Blacksmith label (never a runner
variable that can name a persistent host); the evidence check, the upload and
the disposable user's removal run under `always()`, the upload only when the
check found the evidence clean; nothing else is uploaded.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/machine-join-e2e.yml"
SCRIPT = ROOT / "scripts/cmux-next/machine-join-e2e.ts"
DEV = "https://cmux-platform-development.debussy.workers.dev"
RUNS_ON = (
    "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_CLOUD_OVERFLOW_SAVED"
    " && 'blacksmith-32vcpu-ubuntu-2404' || 'blacksmith-16vcpu-ubuntu-2404' }}"
)


def load() -> dict:
    # BaseLoader keeps `on` a string key and every scalar a string, as GitHub reads them.
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def steps() -> list[dict]:
    return load()["jobs"]["e2e"]["steps"]


def step(name: str) -> dict:
    [found] = [s for s in steps() if s.get("name") == name]
    return found


class MachineJoinE2EWorkflow(unittest.TestCase):
    def test_manual_dispatch_only(self) -> None:
        self.assertEqual(list(load()["on"].keys()), ["workflow_dispatch"])
        self.assertEqual(sorted(load()["on"]["workflow_dispatch"]["inputs"]), ["acpmux_ref", "name"])

    def test_feat_cmux_next_only(self) -> None:
        job = load()["jobs"]["e2e"]
        self.assertEqual(job["if"], "github.ref == 'refs/heads/feat-cmux-next'")
        self.assertIn("refs/heads/feat-cmux-next", steps()[0]["run"])
        self.assertIn("exit 1", steps()[0]["run"])

    def test_read_only_token(self) -> None:
        document = load()
        self.assertEqual(document["permissions"], {"contents": "read"})
        for name, job in document["jobs"].items():
            self.assertNotIn("permissions", job, name)

    def test_stack_secrets_reach_one_step_through_env(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"\$\{\{\s*secrets\.", text)), 2)
        holders = [s for s in steps() if re.search(r"\$\{\{\s*secrets\.", str(s))]
        self.assertEqual([s["name"] for s in holders], ["Mint, join, verify and revoke"])
        mint = holders[0]
        self.assertEqual(mint["env"]["CMUX_UITEST_STACK_EMAIL"], "${{ secrets.CMUX_DOGFOOD_STACK_EMAIL }}")
        self.assertEqual(mint["env"]["CMUX_UITEST_STACK_PASSWORD"], "${{ secrets.CMUX_DOGFOOD_STACK_PASSWORD }}")
        self.assertNotIn("secrets", mint["run"])
        self.assertNotIn("CMUX_UITEST_STACK", mint["run"])

    def test_no_xtrace(self) -> None:
        for s in steps():
            self.assertNotRegex(s.get("run", ""), r"set -[a-z]*x|set -o xtrace|bash -x")

    def test_development_origin_only(self) -> None:
        job = load()["jobs"]["e2e"]
        self.assertEqual(job["env"]["HUB_ORIGIN"], DEV)
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(f'export const DEV_PLATFORM = "{DEV}"', script)
        self.assertIn("if (opts.origin !== DEV_PLATFORM)", script)

    def test_ephemeral_blacksmith_runner(self) -> None:
        job = load()["jobs"]["e2e"]
        self.assertEqual(job["runs-on"], RUNS_ON)
        self.assertNotIn("LINUX_RUNNER", job["runs-on"])
        self.assertIn("timeout-minutes", job)

    def test_cleanup_and_evidence_run_always(self) -> None:
        check = step("Check the evidence")
        self.assertTrue(check["if"].startswith("always()"))
        self.assertIn("cmj_|cmm_|eyJ", check["run"])
        self.assertIn("bearer|authorization", check["run"])
        self.assertIn("revokedListed", check["run"])
        upload = step("Upload the evidence")
        self.assertEqual(upload["if"], "always() && steps.evidence.outputs.clean == 'true'")
        remove = step("Remove the disposable user")
        self.assertTrue(remove["if"].startswith("always()"))
        self.assertIn("userdel --remove", remove["run"])
        self.assertIn('pkill -KILL -u "$JOIN_USER"', remove["run"])

    def test_only_the_evidence_is_uploaded(self) -> None:
        uploads = [s for s in steps() if "upload-artifact" in s.get("uses", "")]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0]["with"]["path"], "${{ runner.temp }}/machine-join-e2e/evidence.json")
        # No restored build cache in a job that later holds secrets.
        self.assertFalse([s for s in steps() if re.search(r"actions/cache|rust-cache", s.get("uses", ""))])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
