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
    ("cla.yml", "CLAAssistant"): "a policy PR to the cla.yml bytes CLA_ACTION_RUNNER_SUCCESSOR_PINS pins",
}
# The persistent pool (runner group 31 cmux-fleet-linux, runners named cmux-runner-pool-*) reuses its VMs across
# jobs. Since 2026-11-20 it also registers the overflow provider's Ubuntu size labels (Leo, 11:32Z: "4V CPU, 8, 16,
# 32, who gives a s***? Just send it somewhere."), so GitHub may schedule a job asking for one of them on a pool VM.
# On cmux#47869 the CLA policy guard asked for blacksmith-4vcpu-ubuntu-2404, ran on cmux-runner-pool-w4bb-0020 and
# its runner guard failed the required check (job 136287113965, cmux#48035).
POOL_CARRIED_LABEL = re.compile(r"\A(?:self-hosted|linux|x64|cmux-linux|cmux-fleet-linux(?:-x64)?|blacksmith-\d+vcpu-ubuntu-2404)\Z")
POOL_RUNNER_NAMES = ("cmux-runner-pool-w4bb-0020", "cmux-runner-pool-a1b2-0001")
GATE_RUNNER_NAME = "cmux-gha-runner-gt-1763650000-0a1b2c"
# Gate jobs whose selector after the gate operand (vars.CI_GATE_SKIP_FLEET=1) still names a label the pool carries.
# The switch is an outage escape hatch; the default route above never reaches it. This list may only shrink.
SKIP_FLEET_FALLBACK_SHARES_POOL = {
    ("backend-migrations.yml", "gate"),
    ("backend-migrations.yml", "plan"),
    ("backend-migrations.yml", "apply-staging"),
    ("backend-migrations.yml", "apply-production"),
    ("merge-group-policy-checks.yml", "cla-assistant"),
    ("merge-group-policy-checks.yml", "cla-policy-guard"),
    ("cla-policy-guard.yml", "validate"),
    ("cla.yml", "CLAAssistant"),
}
# Jobs behind a required check that need no one-job VM lead with cmux-linux, the persistent pool, instead: the
# merge-group bridge only echoes (no token, no checkout, permissions {}). On 2026-11-21 the gate JIT label started
# nothing from about 14:40Z while about 300 persistent runners sat idle, so its jobs queued for hours.
POOL_LABEL = "cmux-linux"
# The pool operand goes through the Linux overflow switch (docs/ci/runner-labels.md): unset, cmux-linux.
POOL_OPERAND = "vars.CI_GATE_SKIP_FLEET != '1' && (vars.CI_OVERFLOW_LINUX || '" + POOL_LABEL + "') || "
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


def operands(expression: str) -> list[str]:
    """The top-level `||` operands of a `${{ a || b || c }}` runs-on, fork branch first."""
    body = expression.strip()
    if not (body.startswith("${{") and body.endswith("}}")):
        return [f"'{body}'"]
    return [part.strip() for part in body[3:-2].split(" || ")]


def default_label(expression: str) -> str | None:
    """The label manaflow-ai's runs-on resolves to with every repository variable unset."""
    if not expression.strip().startswith("${{"):
        return expression.strip()
    for operand in operands(expression)[1:]:
        if re.fullmatch(r"'[^']+'", operand):
            return operand.strip("'")
        switch = re.fullmatch(r"vars\.\w+ != '1' && '([^']+)'", operand)
        if switch:
            return switch.group(1)
    return None


def skip_fleet_labels(expression: str) -> set[str] | None:
    """Every label the selector after the gate operand can reach; None when a variable can name any label."""
    rest = " || ".join(operands(expression)[1:]).replace(GATE_OPERAND.removesuffix(" || "), "", 1)
    if re.search(r"(?:^|\|\| )vars\.\w+(?: \|\||$)", rest.strip(" |")):
        return None
    return set(re.findall(r"[\"']([A-Za-z0-9][A-Za-z0-9.-]*)[\"']", rest)) - {"1"}


def admitted_runner_prefixes(job: dict) -> list[list[str]]:
    """The runner.name prefixes each runner identity step of the job admits."""
    guards = []
    for step in job.get("steps") or []:
        condition = str(step.get("if", ""))
        if "runner.name" in condition and "exit 1" in str(step.get("run", "")):
            guards.append(re.findall(r"startsWith\(runner\.name, '([^']+)'\)", condition))
    return guards


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

    def test_expression_named_required_gate_runs_without_migration_changes(self) -> None:
        # GitHub does not evaluate an expression name when a skippable job is skipped. Keep the required
        # fallback name, while ensuring the no-migration path reaches the gate and reports it.
        gate = load("backend-migrations.yml")["jobs"]["gate"]
        self.assertIn("${{", gate["name"])
        self.assertIn("'backend migrations applied'", gate["name"])
        self.assertNotIn("needs.plan.outputs.migrations != 'true'", str(gate["if"]))

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

    def test_the_gate_label_is_not_a_pool_label(self) -> None:
        self.assertIsNone(POOL_CARRIED_LABEL.match(GATE_LABEL))
        for label in ("blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404",
                      "cmux-fleet-linux-x64"):
            self.assertIsNotNone(POOL_CARRIED_LABEL.match(label), label)

    def test_a_required_gate_never_defaults_to_a_pool_label(self) -> None:
        # With no repository variable set, every required gate asks for a label only one-job VMs serve.
        for (name, job_id), check in sorted(GATE_JOBS.items()):
            if (name, job_id) in STAGED or (name, job_id) in POOL_JOBS:
                continue
            with self.subTest(workflow=name, job=job_id, check=check):
                label = default_label(runs_on(load(name)["jobs"][job_id]))
                self.assertEqual(label, GATE_LABEL)
                self.assertIsNone(POOL_CARRIED_LABEL.match(label or ""), label)

    def test_a_required_gate_runner_guard_refuses_the_pool(self) -> None:
        # A runner identity step admits by runner.name prefix: never one a pool runner's name starts with, and on
        # the gate label it admits the gate JIT VMs, so the default route passes its own guard.
        for (name, job_id), check in sorted(GATE_JOBS.items()):
            job = load(name)["jobs"][job_id]
            for prefixes in admitted_runner_prefixes(job):
                with self.subTest(workflow=name, job=job_id, prefixes=prefixes):
                    self.assertTrue(prefixes)
                    for pool_name in POOL_RUNNER_NAMES:
                        self.assertFalse(any(pool_name.startswith(p) for p in prefixes), pool_name)
                    if (name, job_id) not in STAGED:
                        self.assertTrue(any(GATE_RUNNER_NAME.startswith(p) for p in prefixes), prefixes)

    def test_the_skip_fleet_fallbacks_that_share_the_pool_only_shrink(self) -> None:
        shares = set()
        for (name, job_id) in GATE_JOBS:
            labels = skip_fleet_labels(runs_on(load(name)["jobs"][job_id]))
            if labels is None or any(POOL_CARRIED_LABEL.match(label) for label in labels):
                shares.add((name, job_id))
        self.assertLessEqual(shares, SKIP_FLEET_FALLBACK_SHARES_POOL, "a new gate fallback shares the pool")
        self.assertEqual(SKIP_FLEET_FALLBACK_SHARES_POOL - shares, set(), "fixed: drop it from the list")

    def test_the_route_helpers(self) -> None:
        gate = CLA_SELECTOR.replace(FORK_BRANCH, FORK_BRANCH + GATE_OPERAND, 1)
        self.assertEqual(default_label(gate), GATE_LABEL)
        self.assertEqual(default_label(CLA_SELECTOR), "blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(default_label("ubuntu-24.04"), "ubuntu-24.04")
        self.assertEqual(skip_fleet_labels(gate),
                         {"ubuntu-24.04", "blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"})
        self.assertIsNone(skip_fleet_labels(FORK_BRANCH + GATE_OPERAND + "vars.LINUX_RUNNER || 'x' }}"))
        guard = {"if": "(runner.environment != 'github-hosted' && !startsWith(runner.name, 'cmux-runner-')) "
                       "|| contains(runner.name, 'glaeda')", "run": "exit 1"}
        self.assertEqual(admitted_runner_prefixes({"steps": [guard]}), [["cmux-runner-"]])
        self.assertTrue(any(POOL_RUNNER_NAMES[0].startswith(p) for p in ["cmux-runner-"]))

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
