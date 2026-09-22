from pathlib import Path

ROOT = Path(__file__).parents[1]
WORKFLOW = ROOT / ".github/workflows/review-fabric-observe.yml"


def test_review_fabric_observer_is_trusted_read_only_shadow_mode() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    assert "  pull_request_target:" in workflow
    assert "  pull_request_review:" in workflow
    assert "  pull_request_review_comment:" in workflow
    assert "  issue_comment:" in workflow

    assert "permissions:\n  contents: read\n  issues: read\n  pull-requests: read" in workflow
    assert "actions: write" not in workflow
    assert "contents: write" not in workflow
    assert "pull-requests: write" not in workflow
    assert "issues: write" not in workflow

    assert "github.event.pull_request.base.sha || github.event.repository.default_branch" in workflow
    assert "persist-credentials: false" in workflow
    assert "github.event.pull_request.head.sha" not in workflow

    assert "python3 .github/scripts/github_review_receipt.py" in workflow
    assert "python3 .github/scripts/review_fabric.py" in workflow
    assert "--input artifacts/review-fabric/github-review-receipt.json" in workflow

    assert "policy_exit=$?" in workflow
    assert "Shadow mode records the verdict without making it authoritative." in workflow
    assert "exit 0" in workflow

    assert "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" in workflow
    assert "review-fabric-${{ github.event.pull_request.number || github.event.issue.number }}" in workflow
