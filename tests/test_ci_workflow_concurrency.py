#!/usr/bin/env python3
"""scripts/ci/check_workflow_concurrency.py flags workflows that can flood the queue.

On 2026-10-19 cmuxterm-hq's cmux-shadow-release-compile.yml queued about 247
sixty-minute macOS runs, because each dispatch got its own concurrency group
(`format('shadow-release-compile-{0}', inputs.sha)`, fixed in cmuxterm-hq#2568).
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "check_workflow_concurrency.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_workflow_concurrency as lint  # noqa: E402

HQ_2568_BEFORE = """
on:
  schedule:
    - cron: "*/10 * * * *"
  workflow_dispatch:
    inputs:
      sha: {required: true, type: string}
concurrency:
  group: ${{ github.event_name == 'workflow_dispatch' && format('shadow-release-compile-{0}', inputs.sha) || 'shadow-release-compile-pick' }}
  cancel-in-progress: false
jobs:
  compile:
    runs-on: blacksmith-12vcpu-macos-26
    timeout-minutes: 60
    steps: [{run: make}]
"""


# cmux-next-cua-helper-dev-sign.yml before the fix: run 42677635673 sat at the
# cef-publish approval from 2026-11-09 and held the workflow's only group, so
# every later dispatch waited and each newer one cancelled the pending one.
DEV_SIGN_BEFORE = """
on:
  workflow_dispatch:
    inputs:
      helper: {type: choice, options: [computer-use, remote], default: computer-use}
concurrency:
  group: cmux-next-cua-helper-dev-sign
  cancel-in-progress: false
jobs:
  build: {runs-on: macos-26, timeout-minutes: 30, steps: [{run: x}]}
  sign: {needs: build, environment: release, runs-on: macos-26, timeout-minutes: 30, steps: [{run: x}]}
  publish: {needs: sign, environment: cef-publish, runs-on: ubuntu-24.04, timeout-minutes: 15, steps: [{run: x}]}
"""

DEV_SIGN_AFTER = """
on:
  workflow_dispatch:
    inputs:
      helper: {type: choice, options: [computer-use, remote], default: computer-use}
jobs:
  build:
    concurrency: {group: "dev-sign-build-${{ inputs.helper }}", cancel-in-progress: false}
    runs-on: macos-26
    timeout-minutes: 30
    steps: [{run: x}]
  sign:
    needs: build
    environment: release
    concurrency: {group: "dev-sign-sign-${{ inputs.helper }}", cancel-in-progress: false}
    runs-on: macos-26
    timeout-minutes: 30
    steps: [{run: x}]
  publish: {needs: sign, environment: cef-publish, runs-on: ubuntu-24.04, timeout-minutes: 45, steps: [{run: x}]}
"""


class WorkflowConcurrencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-concurrency-lint-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / ".github" / "workflows").mkdir(parents=True)

    def findings(self, text: str, name: str = "w.yml") -> list[str]:
        path = self.root / ".github" / "workflows" / name
        path.write_text(textwrap.dedent(text), encoding="utf-8")
        return lint.check(path)

    def test_the_hq_2568_flood_is_flagged(self):
        [finding] = self.findings(HQ_2568_BEFORE)
        self.assertIn("unique per run", finding)
        self.assertIn("compile", finding)

    def test_the_hq_2568_fix_passes(self):
        fixed = HQ_2568_BEFORE.replace(
            "format('shadow-release-compile-{0}', inputs.sha)", "'shadow-release-compile'"
        )
        self.assertEqual(self.findings(fixed), [])

    def test_per_run_values_are_flagged(self):
        for value in ("github.sha", "github.run_id", "github.event.pull_request.head.sha",
                      "github.run_attempt", "inputs.head_sha", "github.event.after"):
            text = f"""
            on: [pull_request]
            concurrency: ci-${{{{ {value} }}}}
            jobs:
              t: {{runs-on: macos-15, steps: [{{run: x}}]}}
            """
            self.assertEqual(len(self.findings(text)), 1, value)

    def test_a_pr_or_ref_group_passes(self):
        text = """
        on: [pull_request, workflow_dispatch]
        concurrency:
          group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
          cancel-in-progress: true
        jobs:
          t: {runs-on: macos-15, timeout-minutes: 90, steps: [{run: x}]}
        """
        self.assertEqual(self.findings(text), [])

    def test_literal_text_containing_sha_is_not_per_run(self):
        text = """
        on: workflow_dispatch
        concurrency: shadow-sha-compile
        jobs:
          t: {runs-on: macos-15, steps: [{run: x}]}
        """
        self.assertEqual(self.findings(text), [])

    def test_missing_group_on_long_or_macos_jobs_is_flagged(self):
        text = """
        on:
          repository_dispatch:
        jobs:
          long: {runs-on: ubuntu-latest, timeout-minutes: 45, steps: [{run: x}]}
          mac: {runs-on: [self-hosted, glaeda-side-light-xcode-26.6], steps: [{run: x}]}
          short: {runs-on: ubuntu-latest, timeout-minutes: 10, steps: [{run: x}]}
        """
        [finding] = self.findings(text)
        self.assertIn("long, mac", finding)
        self.assertNotIn("short", finding)

    def test_job_level_group_covers_the_job(self):
        text = """
        on: workflow_dispatch
        jobs:
          t:
            runs-on: macos-15
            concurrency: {group: mac-lane, cancel-in-progress: false}
            steps: [{run: x}]
        """
        self.assertEqual(self.findings(text), [])

    def test_matrix_macos_runner_counts(self):
        text = """
        on: pull_request
        jobs:
          t:
            strategy: {matrix: {os: [ubuntu-latest, macos-15]}}
            runs-on: ${{ matrix.os }}
            steps: [{run: x}]
        """
        self.assertEqual(len(self.findings(text)), 1)

    def test_push_and_schedule_only_and_short_linux_are_not_checked(self):
        self.assertEqual(self.findings("""
        on: {push: {branches: [main]}, schedule: [{cron: "0 * * * *"}]}
        jobs:
          t: {runs-on: macos-15, timeout-minutes: 120, steps: [{run: x}]}
        """), [])
        self.assertEqual(self.findings("""
        on: pull_request
        jobs:
          t: {runs-on: ubuntu-latest, timeout-minutes: 15, steps: [{run: x}]}
          call: {uses: ./.github/workflows/other.yml}
        """), [])

    def test_allowlisted_workflow_is_skipped(self):
        lint.ALLOWLIST["allowed.yml"] = "test"
        self.addCleanup(lint.ALLOWLIST.pop, "allowed.yml")
        self.assertEqual(self.findings(HQ_2568_BEFORE, "allowed.yml"), [])

    def test_cli_warns_and_exits_zero_unless_strict(self):
        self.findings(HQ_2568_BEFORE)
        run = [sys.executable, str(SCRIPT), "--root", str(self.root)]
        warn = subprocess.run(run, text=True, capture_output=True)
        self.assertEqual(warn.returncode, 0, warn.stderr)
        self.assertIn("::warning file=.github/workflows/w.yml", warn.stdout)
        self.assertEqual(subprocess.run([*run, "--strict"], capture_output=True).returncode, 1)

    def approval_findings(self, text: str, name: str = "w.yml") -> list[str]:
        path = self.root / ".github" / "workflows" / name
        path.write_text(textwrap.dedent(text), encoding="utf-8")
        return lint.check_approval(path)

    def test_the_dev_sign_approval_hold_is_an_error(self):
        [finding] = self.approval_findings(DEV_SIGN_BEFORE)
        self.assertIn("job publish waits for a reviewer in cef-publish", finding)
        self.assertIn("workflow-level concurrency group cmux-next-cua-helper-dev-sign", finding)
        run = [sys.executable, str(SCRIPT), "--root", str(self.root)]
        refused = subprocess.run(run, text=True, capture_output=True)
        self.assertEqual(refused.returncode, 1, refused.stdout)
        self.assertIn("::error file=.github/workflows/w.yml,title=approval holds a concurrency group", refused.stdout)

    def test_the_dev_sign_fix_passes_both_rules(self):
        self.assertEqual(self.approval_findings(DEV_SIGN_AFTER), [])
        self.assertEqual(lint.check(self.root / ".github" / "workflows" / "w.yml"), [])

    def test_approval_job_in_its_own_shared_group_is_an_error(self):
        text = DEV_SIGN_AFTER.replace(
            "publish: {needs: sign,",
            "publish: {concurrency: {group: dev-sign-publish, cancel-in-progress: false}, needs: sign,",
        )
        [finding] = self.approval_findings(text)
        self.assertIn("job-level concurrency group dev-sign-publish", finding)

    def test_approval_environment_forms(self):
        for environment in ("{name: npm}", "\"${{ github.ref == 'refs/heads/main' && 'pypi' || '' }}\""):
            text = f"""
            on: workflow_dispatch
            concurrency: {{group: one-at-a-time, cancel-in-progress: false}}
            jobs:
              p: {{environment: {environment}, runs-on: ubuntu-latest, steps: [{{run: x}}]}}
            """
            self.assertEqual(len(self.approval_findings(text)), 1, environment)

    def test_per_run_cancelling_or_unreviewed_groups_pass(self):
        for concurrency, environment in (
            ("{group: 'p-${{ github.run_id }}', cancel-in-progress: false}", "cef-publish"),
            ("{group: p, cancel-in-progress: true}", "cef-publish"),
            ("{group: p, cancel-in-progress: false}", "release"),
        ):
            text = f"""
            on: workflow_dispatch
            concurrency: {concurrency}
            jobs:
              p: {{environment: {environment}, runs-on: ubuntu-latest, steps: [{{run: x}}]}}
            """
            self.assertEqual(self.approval_findings(text), [], (concurrency, environment))

    def test_the_repository_has_no_approval_hold(self):
        workflows = ROOT / ".github" / "workflows"
        held = [f for path in sorted(workflows.glob("*.y*ml")) for f in lint.check_approval(path)]
        self.assertEqual(held, [])

    def test_every_approval_allowlist_entry_still_needs_it(self):
        for name, reason in list(lint.APPROVAL_ALLOWLIST.items()):
            path = ROOT / ".github" / "workflows" / name
            self.assertTrue(path.is_file(), name)
            self.assertTrue(reason.strip(), name)
            del lint.APPROVAL_ALLOWLIST[name]
            try:
                self.assertTrue(lint.check_approval(path), f"{name} no longer needs its allowlist entry")
            finally:
                lint.APPROVAL_ALLOWLIST[name] = reason

    def test_every_allowlist_entry_names_a_workflow_and_a_reason(self):
        for name, reason in lint.ALLOWLIST.items():
            self.assertTrue((ROOT / ".github" / "workflows" / name).is_file(), name)
            self.assertTrue(reason.strip(), name)


if __name__ == "__main__":
    unittest.main()
