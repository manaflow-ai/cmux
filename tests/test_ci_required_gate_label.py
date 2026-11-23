#!/usr/bin/env python3
"""A required merge gate never queues behind the PR backlog it gates.

main's ruleset requires "CLA Assistant", "CLA policy guard" and "backend migrations applied"
(scripts/ci/required_status_checks.py mirrors the list). Their jobs ran on GitHub-hosted ubuntu-24.04 or an
overflow provider through the CI_TRUSTED_RUNNER selector, the same pools as every PR job. On 2026-11-20 #47869's
required CLA policy guard jobs 136180710145 and 136182264409 sat queued with no runner from 08:41Z, and GitHub
refused the merge on base-branch policy.

So every job behind a required check leads with a label no other job asks for, `cmux-gcp-gate-jit-x64`. The
fleet reconciler serves it with one-job VMs only (no cloud identity, deleted after the job), ahead of every PR
label, under its own cap sized to the gates' volume and with runners kept warm, so a required check starts
however deep the PR backlog is. `vars.CI_GATE_SKIP_FLEET=1` turns the label off and leaves the old selector.

The two CLA workflows are pinned byte for byte by scripts/ci/validate-cla-policy.rb, which runs from the base
branch, so they move in steps: the validator first admits the gate selector (CLA_GATE_RUNNER_EXPRESSION) and
the gate runner guard, then cla-policy-guard.yml moves (a guard-only change), then cla.yml moves to the bytes
the validator already pins (a policy change). STAGED holds a job until its step lands; a staged job that already
leads with the label fails here so the list only shrinks.

This test is the pattern's detector: a job that reports a required check off the label, a required check no
listed job reports, or any other job on the label, fails.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
from required_status_checks import REQUIRED_CHECKS  # noqa: E402

GATE_LABEL = "cmux-gcp-gate-jit-x64"
FORK_BRANCH = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
GATE_OPERAND = "vars.CI_GATE_SKIP_FLEET != '1' && '" + GATE_LABEL + "' || "
# (workflow file, job) -> the required check it reports, or the required check it gates (a job the reporting
# job needs: the check cannot start before it ends).
GATE_JOBS = {
    ("cla.yml", "CLAAssistant"): "CLA Assistant",
    ("cla-policy-guard.yml", "validate"): "CLA policy guard",
    ("backend-migrations.yml", "gate"): "backend migrations applied",
    ("backend-migrations.yml", "plan"): "backend migrations applied",
    ("backend-migrations.yml", "apply-staging"): "backend migrations applied",
    ("backend-migrations.yml", "apply-production"): "backend migrations applied",
    ("merge-group-policy-checks.yml", "cla-assistant"): "CLA Assistant",
    ("merge-group-policy-checks.yml", "cla-policy-guard"): "CLA policy guard",
}
# Jobs whose move waits on a validator that runs from base (see the module docstring), with the step that moves
# them. Each still uses the exact selector the validator admits today.
STAGED = {
    ("cla-policy-guard.yml", "validate"): "a guard-only PR, once the validator admitting the gate selector is on main",
    ("cla.yml", "CLAAssistant"): "a policy PR to the cla.yml bytes CLA_ACTION_RUNNER_SUCCESSOR_PINS pins",
}
# Jobs behind a required check that need no one-job VM lead with cmux-linux, the persistent pool, instead: the
# merge-group bridge only echoes (no token, no checkout, permissions {}). On 2026-11-21 the gate JIT label started
# nothing from about 14:40Z while about 300 persistent runners sat idle, so its jobs queued for hours.
POOL_LABEL = "cmux-linux"
POOL_OPERAND = "vars.CI_GATE_SKIP_FLEET != '1' && '" + POOL_LABEL + "' || "
POOL_JOBS = {
    ("merge-group-policy-checks.yml", "cla-assistant"),
    ("merge-group-policy-checks.yml", "cla-policy-guard"),
}
CLA_SELECTOR = (FORK_BRANCH + "contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-2vcpu-ubuntu-2404\","
                "\"blacksmith-4vcpu-ubuntu-2404\"]'), vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || "
                "'blacksmith-4vcpu-ubuntu-2404' }}")


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8")) or {}


def runs_on(job: dict) -> str:
    value = job.get("runs-on", "")
    return " ".join(value) if isinstance(value, list) else str(value)


def all_jobs():
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        for job_id, job in (load(path.name).get("jobs") or {}).items():
            if isinstance(job, dict):
                yield path.name, job_id, job


class RequiredGateLabelTest(unittest.TestCase):
    def test_every_required_check_has_a_listed_gate_job(self) -> None:
        # A required check added to the ruleset (and its mirror) needs its jobs listed here.
        self.assertEqual(set(GATE_JOBS.values()), set(REQUIRED_CHECKS))

    def test_every_job_reporting_a_required_check_is_listed(self) -> None:
        # A new workflow or job that reports a required name would gate merges from wherever it runs.
        reporting = {(name, job_id) for name, job_id, job in all_jobs() if job.get("name") in REQUIRED_CHECKS}
        self.assertTrue(reporting, "no job reports a required check")
        self.assertLessEqual(reporting, set(GATE_JOBS))

    def test_every_gate_job_leads_with_the_gate_label(self) -> None:
        for (name, job_id), check in sorted(GATE_JOBS.items()):
            if (name, job_id) in STAGED:
                continue
            with self.subTest(workflow=name, job=job_id, check=check):
                value = runs_on(load(name)["jobs"][job_id])
                operand = POOL_OPERAND if (name, job_id) in POOL_JOBS else GATE_OPERAND
                self.assertTrue(value.startswith(FORK_BRANCH + operand), value)

    def test_a_staged_job_keeps_the_admitted_selector_until_its_step(self) -> None:
        for (name, job_id), step in sorted(STAGED.items()):
            with self.subTest(workflow=name, job=job_id):
                value = runs_on(load(name)["jobs"][job_id])
                self.assertNotIn(GATE_LABEL, value, f"moved: drop it from STAGED ({step})")
                self.assertEqual(value, CLA_SELECTOR)

    def test_the_cla_validator_admits_the_gate_selector_and_guard(self) -> None:
        # The staged moves can land only once the base validator admits them.
        validator = (ROOT / "scripts" / "ci" / "validate-cla-policy.rb").read_text(encoding="utf-8")
        gate_selector = CLA_SELECTOR.replace(FORK_BRANCH, FORK_BRANCH + GATE_OPERAND, 1)
        self.assertIn(gate_selector.replace('"', '\\"'), validator)
        self.assertIn("CLA_RUNNERS = ([CLA_RUNNER] + CLA_BLACKSMITH_RUNNERS + [CLA_TRUSTED_RUNNER_EXPRESSION, "
                      "CLA_GATE_RUNNER_EXPRESSION]).freeze", validator)
        self.assertIn('CLA_GATE_RUNNER_PREFIX = "cmux-gha-runner-gt-".freeze', validator)

    def test_only_gate_jobs_ask_for_the_gate_label(self) -> None:
        # The label stays reserved: a PR or build job on it would put the backlog back in front of the gates.
        found = {(name, job_id) for name, job_id, job in all_jobs() if GATE_LABEL in runs_on(job)}
        self.assertEqual(found, set(GATE_JOBS) - set(STAGED) - POOL_JOBS)

    def test_the_switch_leaves_the_previous_selector(self) -> None:
        for name, job_id in sorted(set(GATE_JOBS) - set(STAGED)):
            with self.subTest(workflow=name, job=job_id):
                operand = POOL_OPERAND if (name, job_id) in POOL_JOBS else GATE_OPERAND
                after = runs_on(load(name)["jobs"][job_id]).replace(operand, "", 1)
                self.assertNotIn(GATE_LABEL, after)
                self.assertTrue(after.startswith(FORK_BRANCH), after)
                self.assertRegex(after, r"'blacksmith-\dvcpu-ubuntu-2404' }}$")

    def test_the_operand_refuses_a_shared_or_variable_label(self) -> None:
        operand = re.compile(re.escape(GATE_OPERAND))
        for bad in ("vars.CI_GATE_SKIP_FLEET != '1' && 'cmux-fleet-linux-x64' || ",
                    "vars.CI_GATE_SKIP_FLEET != '1' && 'cmux-gcp-repair-jit-x64' || ",
                    "vars.CI_GATE_SKIP_FLEET != '1' && vars.GATE_RUNNER || ",
                    "'cmux-gcp-gate-jit-x64' || "):
            with self.subTest(operand=bad):
                self.assertIsNone(operand.match(bad))


if __name__ == "__main__":
    unittest.main()
