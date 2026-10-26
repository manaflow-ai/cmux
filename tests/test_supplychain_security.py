#!/usr/bin/env python3
"""Supply-chain trust boundaries for workflows, images, and vendored source."""

from __future__ import annotations

import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
SHA256_IMAGE = re.compile(r"^[^@\s]+@sha256:[0-9a-f]{64}$")


def workflow(name: str) -> dict:
    return yaml.load((WORKFLOWS / name).read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def run_text(job: dict) -> str:
    return "\n".join(str(step.get("run", "")) for step in job.get("steps", []))


def test_secret_dispatch_jobs_use_branch_restricted_environments_and_ephemeral_runners() -> None:
    cases = (
        (
            "build-ghosttykit.yml",
            "build-ghosttykit",
            "ghostty-release",
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || 'blacksmith-6vcpu-macos-15' }}",
        ),
        (
            "ios-streamed-validate.yml",
            "validate",
            "ios-streamed-validation",
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || 'blacksmith-6vcpu-macos-26' }}",
        ),
    )
    for name, job_name, environment, runner in cases:
        job = workflow(name)["jobs"][job_name]
        assert job.get("environment") == environment, f"{name} secrets need {environment}"
        assert job.get("runs-on") == runner, f"{name} must use a literal ephemeral runner"
        assert "vars." not in runner

    shared_secret_readers = (
        ("claude.yml", "claude", "claude-agent"),
        ("ci-compile-attribution.yml", "fix", "ci-attribution-agent"),
    )
    for name, job_name, environment in shared_secret_readers:
        job = workflow(name)["jobs"][job_name]
        assert job.get("environment") == environment, f"{name} secrets need {environment}"

    claude_triggers = set(workflow("claude.yml")["on"])
    assert claude_triggers == {"issue_comment", "issues"}, (
        "the Claude secret-bearing workflow must stay on trusted default-branch events"
    )


def test_pull_request_target_jobs_never_receive_oidc() -> None:
    checked = 0
    for path in sorted(WORKFLOWS.glob("*.yml")):
        document = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        triggers = document.get("on") or {}
        if "pull_request_target" not in triggers:
            continue
        checked += 1
        top_permissions = document.get("permissions") or {}
        assert top_permissions.get("id-token") != "write", f"{path.name} grants workflow-level OIDC"
        for job_name, job in (document.get("jobs") or {}).items():
            permissions = job.get("permissions") or {}
            assert permissions.get("id-token") != "write", f"{path.name} {job_name} grants OIDC"
    assert checked >= 5, "no pull_request_target workflows were inspected"


def test_dispatchable_jobs_with_external_credentials_use_environments() -> None:
    checked = 0
    for path in sorted(WORKFLOWS.glob("*.yml")):
        document = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        if "workflow_dispatch" not in (document.get("on") or {}):
            continue
        for job_name, job in (document.get("jobs") or {}).items():
            rendered = yaml.dump(job)
            names = set(re.findall(r"secrets\.([A-Z][A-Z0-9_]*)", rendered)) - {"GITHUB_TOKEN"}
            inherited = job.get("secrets") == "inherit"
            if not names and not inherited:
                continue
            checked += 1
            assert job.get("environment"), (
                f"{path.name} {job_name} can receive external credentials without an environment"
            )
            assert not inherited, f"{path.name} {job_name} inherits every caller secret"
    assert checked >= 50, "dispatchable credential consumers were not comprehensively inspected"

    secretless_pr_jobs = (
        ("ci.yml", "changes", "ci-routing-agent", True),
        ("ci-macos.yml", "admission-placement", "ci-routing-agent", True),
        ("ci-macos.yml", "macos-compile-admission", "ci-build-cache-reader", True),
        ("ci-macos.yml", "late-placement", "ci-routing-agent", True),
        ("cmux-next.yml", "macos-placement", "ci-routing-agent", False),
        ("cmux-next.yml", "release-compile", "ci-build-cache-reader", False),
        ("test-ios.yml", "runner", "ci-routing-agent", True),
    )
    for name, job_name, trusted_environment, has_merge_group in secretless_pr_jobs:
        environment = workflow(name)["jobs"][job_name].get("environment", "")
        assert trusted_environment in environment
        assert "pull_request" in environment and f"'{trusted_environment}' || ''" in environment, (
            f"{name} {job_name} exposes an environment credential to PR code"
        )
        if has_merge_group:
            assert "merge_group" in environment


def test_cloud_dogfood_keeps_the_public_installer_out_of_the_secret_job() -> None:
    jobs = workflow("cloud-vm-dogfood.yml")["jobs"]
    smoke = jobs["public-installer-smoke"]
    installer = jobs["installer"]
    journey = jobs["journey"]

    assert smoke.get("environment") is None
    assert "secrets." not in yaml.dump(smoke)
    assert "vars." not in smoke["runs-on"]
    assert "https://cmux.com/tui/install.sh" in run_text(smoke)
    assert "CMUX_TUI_INSTALL_MS" in run_text(smoke)
    assert any("actions/upload-artifact@" in str(step.get("uses", "")) for step in smoke["steps"])

    assert installer.get("environment") is None
    assert installer.get("needs") == "public-installer-smoke"
    assert (installer.get("permissions") or {}).get("attestations") == "read"
    assert "secrets." not in yaml.dump(installer)
    assert "vars." not in installer["runs-on"]
    installer_script = run_text(installer)
    assert "gh attestation verify" in installer_script
    assert "--source-ref refs/heads/main" in installer_script
    assert "sourceRepositoryDigest" in installer_script
    assert "latest/manifest.json" not in installer_script
    assert "$RUNNER_TEMP/public-cmux/cmux" in installer_script
    assert 'cmux-tui/$commit/$artifact' not in installer_script
    assert any("actions/download-artifact@" in str(step.get("uses", "")) for step in installer["steps"])
    assert any("actions/upload-artifact@" in str(step.get("uses", "")) for step in installer["steps"])

    assert journey.get("needs") == "installer"
    assert journey.get("environment") == "cloud-vm-${{ inputs.target }}"
    assert "vars." not in journey["runs-on"]
    assert "STACK_SECRET_SERVER_KEY" not in (journey.get("env") or {})
    assert any("actions/download-artifact@" in str(step.get("uses", "")) for step in journey["steps"])
    assert "CMUX_TUI_INSTALL_MS" in run_text(journey)
    secret_steps = [
        step for step in journey["steps"]
        if "STACK_SECRET_SERVER_KEY" in (step.get("env") or {})
    ]
    assert len(secret_steps) == 1
    assert secret_steps[0].get("name") == "Journey"


def test_environment_secret_rollout_keeps_untrusted_jobs_secretless() -> None:
    reachability = workflow("cloud-vm-image-reachability.yml")["jobs"]["reachable"]
    reachability_environment = reachability.get("environment", "")
    assert "cloud-vm-image-reachability" in reachability_environment
    assert "pull_request" in reachability_environment
    assert "'cloud-vm-image-reachability' || ''" in reachability_environment

    promotion = workflow("cloud-vm-image-contract.yml")["jobs"]["promote"]
    assert promotion.get("environment") == "cloud-vm-image-promotion"

    image_promote = workflow("cloud-vm-image-promote.yml")
    assert set(image_promote["on"]) == {"workflow_dispatch"}
    assert image_promote.get("permissions") == {"contents": "read", "actions": "read"}
    assert image_promote["jobs"]["promote"].get("environment") == "cmux-next-vm-image-dev"

    backend_jobs = workflow("backend.yml")["jobs"]
    for job_name in ("migrations-development", "preview", "preview-cleanup"):
        assert "vars.CMUX_NEXT_PREVIEW_BROKER_ENABLED == '1'" in backend_jobs[job_name].get("if", ""), (
            f"backend {job_name} must skip before its protected environment is evaluated"
        )

    docs_caller = workflow("docs-channels.yml")["jobs"]
    assert "secrets" not in docs_caller["nightly"]
    assert "secrets" not in docs_caller["release"]
    docs_deploy = workflow("docs-deploy-reusable.yml")["jobs"]["deploy"]
    assert docs_deploy.get("environment") == "docs-${{ inputs.channel }}"
    docs_run = run_text(docs_deploy)
    for secret in ("VERCEL_ORG_ID", "VERCEL_PROJECT_ID", "VERCEL_TOKEN"):
        assert secret in yaml.dump(docs_deploy)
    assert "secrets.vercel_" not in yaml.dump(docs_deploy)

    namespace = workflow("namespace-autofix.yml")["jobs"]["autofix"]
    assert namespace.get("environment") == "ci-routing-agent"

    pr_autofix = workflow("cmux-next-pr-autofix.yml")["jobs"]["push"]
    assert pr_autofix.get("environment") == "cmux-pr-autofix"
    assert "github.event_name != 'pull_request'" in pr_autofix.get("if", ""), (
        "the protected App job must skip PR refs before environment evaluation"
    )

    trusted_automation = (
        ("ci-failure-attribution.yml", "attribute", "ci-attribution-agent"),
        ("ci-guard-attribution.yml", "analyze", "ci-attribution-agent"),
        ("ci-guard-attribution.yml", "report", "ci-attribution-agent"),
        ("ci-hosted-queue-rescue.yml", "rescue", "ci-bot"),
        ("dogfood-artifact-publish.yml", "capture", "ci-bot"),
    )
    for name, job_name, environment in trusted_automation:
        assert workflow(name)["jobs"][job_name].get("environment") == environment


def test_ci_and_deployment_container_images_are_digest_pinned() -> None:
    workflow_images = (
        ("backend.yml", "test", "postgres"),
        ("backend.yml", "test", "mysql"),
        ("release-rails.yml", "rails", "postgres"),
        ("web-validation.yml", "database", "postgres"),
        ("ci-web.yml", "web-db-migrations", "postgres"),
    )
    for name, job_name, service in workflow_images:
        image = workflow(name)["jobs"][job_name]["services"][service]["image"]
        assert SHA256_IMAGE.fullmatch(image), f"{name} {job_name}/{service} is mutable: {image}"

    dockerfile = ROOT / "backend/chief-opencode/image/Dockerfile"
    bases = [
        line.split(maxsplit=1)[1].split()[0]
        for line in dockerfile.read_text(encoding="utf-8").splitlines()
        if line.startswith("FROM ")
    ]
    assert len(bases) == 2
    for image in bases:
        assert SHA256_IMAGE.fullmatch(image), f"{dockerfile}: mutable base {image}"


def test_vendored_stack_auth_records_origin_patch_and_license_status() -> None:
    provenance = ROOT / "vendor/stack-auth-swift-sdk-prerelease/README.cmux.md"
    text = provenance.read_text(encoding="utf-8")
    assert "https://github.com/stack-auth/swift-sdk-prerelease" in text
    assert "784d147c4c0510c33f591d13b7a1142bbf094c65" in text
    assert "No upstream license file" in text
    for changed in (
        "Sources/StackAuth/APIClient.swift",
        "Sources/StackAuth/Models/User.swift",
        "Sources/StackAuth/StackClientApp.swift",
        "Tests/StackAuthTests/OAuthTests.swift",
        "Tests/StackAuthTests/TestConfig.swift",
    ):
        assert f"`{changed}`" in text


if __name__ == "__main__":
    test_secret_dispatch_jobs_use_branch_restricted_environments_and_ephemeral_runners()
    test_pull_request_target_jobs_never_receive_oidc()
    test_dispatchable_jobs_with_external_credentials_use_environments()
    test_cloud_dogfood_keeps_the_public_installer_out_of_the_secret_job()
    test_environment_secret_rollout_keeps_untrusted_jobs_secretless()
    test_ci_and_deployment_container_images_are_digest_pinned()
    test_vendored_stack_auth_records_origin_patch_and_license_status()
    print("supply-chain security checks passed")
