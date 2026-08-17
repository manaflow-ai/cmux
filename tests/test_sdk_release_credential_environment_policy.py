from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "sdk-release-cut.yml"


def workflow_job(text: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        text,
    )
    assert match is not None
    return match.group(1)


def test_sdk_release_credential_environment_policy_is_fail_closed() -> None:
    release = WORKFLOW.read_text()
    policy = workflow_job(release, "credential-environment-preflight")
    cut_tags = workflow_job(release, "cut-tags")

    assert "name: verify credential environment policy" in policy
    assert "actions: read" not in policy
    assert "contents: read" in policy
    assert "GITHUB_TOKEN: ${{ github.token }}" in policy
    assert "verify_github_environment_policy.py" in policy
    assert "--environment sdk-release-credentials" in policy
    assert "--dispatcher \"$GITHUB_ACTOR\"" in policy
    assert "credential-environment-preflight" in cut_tags
    assert release.index("revalidate-tags:") < release.index(
        "credential-environment-preflight:"
    ) < release.index("cut-tags:")
