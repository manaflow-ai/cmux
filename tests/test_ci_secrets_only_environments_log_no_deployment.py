#!/usr/bin/env python3
"""A job in an environment that only holds secrets logs no deployment on the PR.

Leo (2026-11-07), on a PR timeline: "holy shit there's so many of these 'temporarily deployed to...'". Every job
that names an environment makes GitHub record a deployment, and the PR shows each one, though these environments
deploy nothing: they scope an App key or a test account. `deployment: false` keeps the secrets and drops the event.
The environments below have no protection rules (`deployment: false` cannot be used with custom deployment
protection rules). A job that mints an OIDC token keeps its plain environment, since the token's subject names it.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

SECRETS_ONLY = {
    "ci-attribution-agent",
    "ci-bot",
    "ci-routing-agent",
    "cloud-vm-image-checks",
    "cmux-next-cloud-journey",
    "cmux-next-vm-image-dev",
    "cmux-pr-autofix",
    "ios-streamed-validation",
    "sentry-dsyms",
}


def mints_oidc(workflow: dict, job: dict) -> bool:
    permissions = job.get("permissions", workflow.get("permissions")) or {}
    return permissions == "write-all" or (isinstance(permissions, dict) and permissions.get("id-token") == "write")


def offenders() -> list[str]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (workflow.get("jobs") or {}).items():
            environment = job.get("environment") if isinstance(job, dict) else None
            if not isinstance(environment, str) or environment not in SECRETS_ONLY:
                continue
            if not mints_oidc(workflow, job):
                found.append(f"{path.name} {name}: environment {job['environment']!r} needs "
                             "`environment: {name: ..., deployment: false}`")
    return found


class SecretsOnlyEnvironmentsLogNoDeployment(unittest.TestCase):
    def test_every_plain_secrets_only_environment_skips_the_deployment(self) -> None:
        self.assertEqual(offenders(), [])

    def test_deployment_false_is_used_only_where_no_protection_rule_needs_it(self) -> None:
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            for name, job in (workflow.get("jobs") or {}).items():
                environment = job.get("environment") if isinstance(job, dict) else None
                if isinstance(environment, dict) and environment.get("deployment") is False:
                    self.assertIn(environment.get("name"), SECRETS_ONLY, f"{path.name} {name}")
                    self.assertFalse(mints_oidc(workflow, job), f"{path.name} {name} mints an OIDC token")

    def test_a_plain_secrets_only_environment_is_caught(self) -> None:
        job = {"runs-on": "x", "environment": "ci-bot"}
        self.assertIn(job["environment"], SECRETS_ONLY)
        self.assertFalse(mints_oidc({}, job))
        self.assertTrue(mints_oidc({"permissions": {"id-token": "write"}}, job))


if __name__ == "__main__":
    sys.exit(unittest.main())
