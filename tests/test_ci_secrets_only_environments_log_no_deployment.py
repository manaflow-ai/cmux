#!/usr/bin/env python3
"""A job in an environment that only holds secrets logs no deployment on the PR.

Leo (2026-11-07), on a PR timeline: "holy shit there's so many of these 'temporarily deployed to...'". Every job
that names an environment makes GitHub record a deployment, and the PR shows each one, though these environments
deploy nothing: they scope an App key or a test account. `deployment: false` keeps the secrets and drops the event.
The environments below have no protection rules (`deployment: false` cannot be used with custom deployment
protection rules). A job that mints an OIDC token skips it too: its one consumer, the controller's tree-claim
endpoint (cmuxterm-hq build-fleet/cmd/controller/tree_claim.go), checks the token's repository and workflow_ref,
not its subject. The `artifacts` environment (R2 credentials) records a deployment only from a base branch, whose
publish moves the Cloud and feat channels; a lane branch's commit-addressed upload logs none on its PR.
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


BASE_ONLY = {"artifacts"}
BASE_ONLY_DEPLOYMENT = ("${{ contains(fromJSON('[\"refs/heads/main\",\"refs/heads/feat-cmux-next\","
                        "\"refs/heads/nightly-next\"]'), github.ref) }}")


def mints_oidc(workflow: dict, job: dict) -> bool:
    permissions = job.get("permissions", workflow.get("permissions")) or {}
    return permissions == "write-all" or (isinstance(permissions, dict) and permissions.get("id-token") == "write")


def records_deployment(workflow: dict, job: object) -> str | None:
    """The secrets-only environment a job enters while still recording a deployment, plain or as a mapping."""
    environment = job.get("environment") if isinstance(job, dict) else None
    name = environment.get("name") if isinstance(environment, dict) else environment
    if not isinstance(name, str) or name not in SECRETS_ONLY | BASE_ONLY:
        return None
    want = False if name in SECRETS_ONLY else BASE_ONLY_DEPLOYMENT
    if isinstance(environment, dict) and environment.get("deployment") == want:
        return None
    return name


def offenders() -> list[str]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (workflow.get("jobs") or {}).items():
            environment = records_deployment(workflow, job)
            if environment:
                want = "false" if environment in SECRETS_ONLY else BASE_ONLY_DEPLOYMENT
                found.append(f"{path.name} {name}: environment {environment!r} needs "
                             f"`environment: {{name: ..., deployment: {want}}}`")
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

    def test_each_form_that_still_records_a_deployment_is_caught(self) -> None:
        self.assertEqual(records_deployment({}, {"environment": "ci-bot"}), "ci-bot")
        self.assertEqual(records_deployment({}, {"environment": {"name": "ci-bot"}}), "ci-bot")
        self.assertIsNone(records_deployment({}, {"environment": {"name": "ci-bot", "deployment": False}}))
        self.assertIsNone(records_deployment({}, {"environment": "release"}))
        self.assertEqual(records_deployment({"permissions": {"id-token": "write"}}, {"environment": "ci-bot"}), "ci-bot")
        self.assertEqual(records_deployment({}, {"environment": "artifacts"}), "artifacts")
        self.assertEqual(records_deployment({}, {"environment": {"name": "artifacts", "deployment": False}}), "artifacts")
        self.assertIsNone(records_deployment({}, {"environment": {"name": "artifacts", "deployment": BASE_ONLY_DEPLOYMENT}}))


if __name__ == "__main__":
    sys.exit(unittest.main())
