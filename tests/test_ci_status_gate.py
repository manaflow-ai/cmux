#!/usr/bin/env python3
"""Behavior tests for the base-owned CI status gate."""

from __future__ import annotations

import importlib.util
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts" / "ci" / "ci_status_gate.py"
WORKFLOW = ROOT / ".github" / "workflows" / "ci-status-gate.yml"

spec = importlib.util.spec_from_file_location("ci_status_gate", GATE)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


HEAD_SHA = "a" * 40
BASE_SHA = "c" * 40


def check(
    name: str,
    *,
    number: int,
    status: str = "completed",
    conclusion: str = "success",
    head_sha: str = HEAD_SHA,
    app_id: int = 15368,
) -> dict[str, object]:
    return {
        "id": number,
        "name": name,
        "status": status,
        "conclusion": conclusion if status == "completed" else None,
        "head_sha": head_sha,
        "app": {"id": app_id},
    }


def complete_checks() -> list[dict[str, object]]:
    names = [
        "changes",
        "workflow-guard-tests",
        "GhosttyKit release check",
        "linux-preflight",
        "tests",
        "tests-build-and-lag",
        "swift-package-tests",
        "release-build",
        "web-typecheck",
        "react-apps-check",
        "diff-sidecar-check",
        "web-db-migrations",
        "remote-daemon-tests",
        "agent-session-web-resources",
    ]
    checks = [check(name, number=index + 1) for index, name in enumerate(names)]
    checks.extend(
        check(f"app-host unit tests ({index}/6)", number=100 + index)
        for index in range(1, 7)
    )
    return checks


class FakeAPI:
    """In-memory GitHub API fixture for the end-to-end gate path."""

    repository = "manaflow-ai/cmux"

    def __init__(self, checks: list[dict[str, object]]) -> None:
        self.checks = checks
        self.requests: list[str] = []

    def get(self, endpoint: str, *, paginate: bool = False) -> object:
        self.requests.append(endpoint)
        if endpoint.endswith("/pulls/1"):
            return {
                "number": 1,
                "state": "open",
                "changed_files": 1,
                "user": {"login": "contributor"},
                "base": {
                    "ref": "main",
                    "sha": BASE_SHA,
                    "repo": {"full_name": self.repository},
                },
                "head": {"sha": HEAD_SHA},
            }
        if "/actions/runs?event=" in endpoint:
            return {
                "workflow_runs": [
                    {
                        "id": 900,
                        "path": module.CI_WORKFLOW_PATH,
                        "event": "pull_request",
                        "head_sha": HEAD_SHA,
                        "status": "completed",
                        "created_at": "2026-09-01T00:00:00Z",
                        "pull_requests": [{"number": 1}],
                    }
                ]
            }
        if endpoint.endswith("/actions/runs/900/jobs?per_page=100"):
            jobs = []
            for item in self.checks:
                jobs.append(
                    {
                        "name": item["name"],
                        "head_sha": HEAD_SHA,
                        "check_run_url": f"https://api.github.com/repos/manaflow-ai/cmux/check-runs/{item['id']}",
                    }
                )
            return [{"jobs": jobs}]
        if "/commits/" in endpoint and "/check-runs" in endpoint:
            return [{"check_runs": self.checks}]
        if "/contents/.github/workflows/ci.yml?ref=" in endpoint:
            return {"type": "file", "path": module.CI_WORKFLOW_PATH, "sha": BASE_SHA}
        if endpoint.endswith("/pulls/1/reviews?per_page=100"):
            return []
        if endpoint.endswith("/pulls/1/files?per_page=100"):
            return [[{"filename": "README.md"}]]
        raise AssertionError(f"unexpected API endpoint: {endpoint}")


def test_docs_only_snapshot_accepts_skipped_routes() -> None:
    failures = module.validate_snapshot(
        complete_checks(),
        ["docs/ci-required-checks.md"],
        head_sha=HEAD_SHA,
    )
    assert failures == []


def test_web_snapshot_requires_web_jobs() -> None:
    checks = complete_checks()
    checks[8]["conclusion"] = "failure"
    failures = module.validate_snapshot(
        checks,
        ["web/app/page.tsx"],
        head_sha=HEAD_SHA,
    )
    assert any("web-typecheck" in failure for failure in failures)


def test_missing_matrix_shard_fails_closed() -> None:
    checks = [
        item
        for item in complete_checks()
        if item["name"] != "app-host unit tests (6/6)"
    ]
    failures = module.validate_snapshot(
        checks,
        ["Sources/AppDelegate.swift"],
        head_sha=HEAD_SHA,
    )
    assert any("app-host-unit-tests" in failure for failure in failures)


def test_pending_check_does_not_pass() -> None:
    checks = complete_checks()
    checks[0] = check("changes", number=1, status="in_progress")
    failures = module.validate_snapshot(
        checks,
        ["README.md"],
        head_sha=HEAD_SHA,
    )
    assert any("changes" in failure for failure in failures)


def test_stale_or_untrusted_app_checks_are_not_accepted() -> None:
    checks = complete_checks()
    checks[0] = check("changes", number=1, head_sha="b" * 40)
    checks[1] = check("workflow-guard-tests", number=2, app_id=999)
    failures = module.validate_snapshot(
        checks,
        ["README.md"],
        head_sha=HEAD_SHA,
    )
    assert any("changes" in failure for failure in failures)
    assert any("workflow-guard-tests" in failure for failure in failures)


def test_unexpected_ci_job_is_rejected() -> None:
    checks = complete_checks()
    checks.append(check("unreviewed-job", number=999))
    failures = module.validate_snapshot(
        checks,
        ["README.md"],
        head_sha=HEAD_SHA,
    )
    assert any("unreviewed-job" in failure for failure in failures)


def test_workflow_is_base_owned_with_limited_check_publication() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "pull_request_target:" in text
    assert "pull_request_review:" in text
    assert "workflow_run:" in text
    assert "pull_request:" not in text
    assert "refs/heads/main" in text
    assert "github.sha" not in text
    assert "ci-status-gate:" in text
    assert "ci-status:" in text
    assert "needs: ci-status-gate" in text
    assert "GATE_RESULT" in text
    assert "actions: read" in text
    assert "checks: write" in text
    assert "pull-requests: read" in text
    assert "contents: write" not in text
    assert ".ci-trusted/scripts/ci/ci_status_gate.py" in text


def test_event_payload_parser_rejects_invalid_json() -> None:
    try:
        module.parse_event("not-json")
    except module.GateError as error:
        assert "event payload" in str(error)
    else:
        raise AssertionError("invalid event payload was accepted")


def test_pull_request_review_event_resolves_live_head() -> None:
    api = FakeAPI(complete_checks())
    pull, head, number, workflow_run_id = module._event_target(
        api,
        "pull_request_review",
        {"pull_request": {"number": 1, "head": {"sha": HEAD_SHA}}},
    )
    assert pull["number"] == 1
    assert head == HEAD_SHA
    assert number == 1
    assert workflow_run_id is None


def test_workflow_run_with_multiple_pull_requests_fails_closed() -> None:
    class AmbiguousAPI(FakeAPI):
        def get(self, endpoint: str, *, paginate: bool = False) -> object:
            if endpoint.endswith("/actions/runs/900"):
                return {"pull_requests": [{"number": 1}, {"number": 2}]}
            return super().get(endpoint, paginate=paginate)

    try:
        module._event_target(
            AmbiguousAPI(complete_checks()),
            "workflow_run",
            {"workflow_run": {"id": 900, "head_sha": HEAD_SHA}},
        )
    except module.GateError as error:
        assert "multiple pull requests" in str(error)
    else:
        raise AssertionError("ambiguous workflow run was accepted")


def test_workflow_run_duplicate_association_is_deduplicated() -> None:
    class DuplicateAPI(FakeAPI):
        def get(self, endpoint: str, *, paginate: bool = False) -> object:
            if endpoint.endswith("/actions/runs/900"):
                return {"pull_requests": [{"number": 1}, {"number": 1}]}
            return super().get(endpoint, paginate=paginate)

    pull, head, number, workflow_run_id = module._event_target(
        DuplicateAPI(complete_checks()),
        "workflow_run",
        {"workflow_run": {"id": 900, "head_sha": HEAD_SHA}},
    )
    assert pull["number"] == 1
    assert head == HEAD_SHA
    assert number == 1
    assert workflow_run_id == 900


def test_external_fork_workflow_run_fallback_keeps_empty_association() -> None:
    class ForkRunAPI(FakeAPI):
        def get(self, endpoint: str, *, paginate: bool = False) -> object:
            if endpoint.endswith("/actions/runs/900"):
                return {
                    "id": 900,
                    "path": module.CI_WORKFLOW_PATH,
                    "event": "pull_request",
                    "head_sha": HEAD_SHA,
                    "status": "completed",
                    "created_at": "2026-09-01T00:00:00Z",
                    "pull_requests": [],
                }
            if endpoint.endswith(f"/commits/{HEAD_SHA}/pulls?per_page=100"):
                return [
                    {
                        "number": 1,
                        "state": "open",
                        "base": {
                            "ref": "main",
                            "repo": {"full_name": self.repository},
                        },
                        "head": {"sha": HEAD_SHA},
                    }
                ]
            return super().get(endpoint, paginate=paginate)

    api = ForkRunAPI(complete_checks())
    pull, head, number, workflow_run_id = module._event_target(
        api,
        "workflow_run",
        {"workflow_run": {"id": 900, "head_sha": HEAD_SHA}},
    )
    selected = module._select_ci_run(api, pull, head, workflow_run_id)
    assert number == 1
    assert selected["id"] == 900


def _fallback_run_api(rows: object) -> FakeAPI:
    class FallbackRunAPI(FakeAPI):
        def get(self, endpoint: str, *, paginate: bool = False) -> object:
            if endpoint.endswith("/actions/runs/900"):
                return {
                    "id": 900,
                    "path": module.CI_WORKFLOW_PATH,
                    "event": "pull_request",
                    "head_sha": HEAD_SHA,
                    "status": "completed",
                    "created_at": "2026-09-01T00:00:00Z",
                    "pull_requests": [],
                }
            if endpoint.endswith(f"/commits/{HEAD_SHA}/pulls?per_page=100"):
                return rows
            return super().get(endpoint, paginate=paginate)

    return FallbackRunAPI(complete_checks())


def _valid_commit_pull(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "number": 1,
        "state": "open",
        "base": {"ref": "main", "repo": {"full_name": "manaflow-ai/cmux"}},
        "head": {"sha": HEAD_SHA},
    }
    value.update(overrides)
    return value


def test_empty_workflow_run_fallback_rejects_wrong_base() -> None:
    api = _fallback_run_api(
        [_valid_commit_pull(base={"ref": "release", "repo": {"full_name": "manaflow-ai/cmux"}})]
    )
    try:
        module._event_target(
            api,
            "workflow_run",
            {"workflow_run": {"id": 900, "head_sha": HEAD_SHA}},
        )
    except module.GateError as error:
        assert "base" in str(error)
    else:
        raise AssertionError("wrong-base commit association was accepted")


def test_empty_workflow_run_fallback_rejects_multiple_matches() -> None:
    api = _fallback_run_api(
        [_valid_commit_pull(), _valid_commit_pull(number=2)]
    )
    try:
        module._event_target(
            api,
            "workflow_run",
            {"workflow_run": {"id": 900, "head_sha": HEAD_SHA}},
        )
    except module.GateError as error:
        assert "multiple" in str(error) or "exactly one" in str(error)
    else:
        raise AssertionError("multiple commit associations were accepted")


def test_empty_workflow_run_fallback_rejects_stale_or_closed_match() -> None:
    for row in (
        _valid_commit_pull(head={"sha": "b" * 40}),
        _valid_commit_pull(state="closed"),
        _valid_commit_pull(base={"ref": "main", "repo": {"full_name": "other/repo"}}),
    ):
        api = _fallback_run_api([row])
        try:
            module._event_target(
                api,
                "workflow_run",
                {"workflow_run": {"id": 900, "head_sha": HEAD_SHA}},
            )
        except module.GateError:
            continue
        raise AssertionError("ambiguous commit association was accepted")


def test_gate_queries_exact_head_and_ci_run_jobs() -> None:
    api = FakeAPI(complete_checks())
    stdout = StringIO()
    stderr = StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        result = module._run_gate(
            api,
            "pull_request_target",
            {"number": 1, "pull_request": {"head": {"sha": HEAD_SHA}}},
        )
    assert result == 0, stderr.getvalue()
    assert any(
        f"/commits/{HEAD_SHA}/check-runs?per_page=100" in request
        for request in api.requests
    )
    assert "CI status gate passed." in stdout.getvalue()


def test_gate_publisher_targets_both_contexts_on_exact_head() -> None:
    class PublishingAPI(FakeAPI):
        def __init__(self) -> None:
            super().__init__(complete_checks())
            self.published: list[tuple[str, str, str]] = []

        def publish_check(
            self, name: str, head_sha: str, conclusion: str, summary: str
        ) -> None:
            self.published.append((name, head_sha, conclusion))

    api = PublishingAPI()
    result = module._run_gate(
        api,
        "pull_request_target",
        {"number": 1, "pull_request": {"head": {"sha": HEAD_SHA}}},
        publish=True,
    )
    assert result == 0
    assert api.published == [
        ("ci-status-gate", HEAD_SHA, "success"),
        ("ci-status", HEAD_SHA, "success"),
    ]


def test_check_publisher_updates_only_our_exact_head_run() -> None:
    class CheckAPI(module.GitHubAPI):
        def __init__(self) -> None:
            super().__init__("manaflow-ai/cmux", token="test")
            self.writes: list[tuple[str, str, dict[str, object]]] = []
            self.existing = False

        def get(self, endpoint: str, *, paginate: bool = False) -> object:
            assert "check_name=ci-status-gate" in endpoint
            if self.existing:
                return [
                    {
                        "check_runs": [
                            {
                                "id": 77,
                                "name": "ci-status-gate",
                                "head_sha": HEAD_SHA,
                                "app": {"id": module.ACTIONS_APP_ID},
                                "external_id": module._publisher_external_id(
                                    "ci-status-gate", HEAD_SHA
                                ),
                            }
                        ]
                    }
                ]
            return [{"check_runs": []}]

        def write(
            self, method: str, endpoint: str, payload: dict[str, object]
        ) -> object:
            self.writes.append((method, endpoint, payload))
            return {
                "name": payload["name"],
                "head_sha": payload["head_sha"],
                "app": {"id": module.ACTIONS_APP_ID},
                "external_id": payload["external_id"],
            }

    api = CheckAPI()
    api.publish_check("ci-status-gate", HEAD_SHA, "success", "ok")
    assert api.writes[0][0] == "POST"
    assert api.writes[0][2]["head_sha"] == HEAD_SHA
    api.existing = True
    api.publish_check("ci-status-gate", HEAD_SHA, "failure", "bad")
    assert api.writes[1][0] == "PATCH"
    assert api.writes[1][1].endswith("/check-runs/77")


def test_check_publisher_ignores_foreign_producer_and_rejects_race() -> None:
    class ForeignCheckAPI(module.GitHubAPI):
        def __init__(self, response_external_id: str | None = None) -> None:
            super().__init__("manaflow-ai/cmux", token="test")
            self.response_external_id = response_external_id
            self.writes: list[tuple[str, str, dict[str, object]]] = []

        def get(self, endpoint: str, *, paginate: bool = False) -> object:
            return [
                {
                    "check_runs": [
                        {
                            "id": 78,
                            "name": "ci-status-gate",
                            "head_sha": HEAD_SHA,
                            "app": {"id": module.ACTIONS_APP_ID},
                            "external_id": "legacy-or-foreign-producer",
                        }
                    ]
                }
            ]

        def write(
            self, method: str, endpoint: str, payload: dict[str, object]
        ) -> object:
            self.writes.append((method, endpoint, payload))
            return {
                "name": payload["name"],
                "head_sha": payload["head_sha"],
                "app": {"id": module.ACTIONS_APP_ID},
                "external_id": self.response_external_id
                if self.response_external_id is not None
                else payload["external_id"],
            }

    api = ForeignCheckAPI()
    api.publish_check("ci-status-gate", HEAD_SHA, "success", "ok")
    assert api.writes[0][0] == "POST"
    assert api.writes[0][1].endswith("/check-runs")
    assert api.writes[0][2]["external_id"] == module._publisher_external_id(
        "ci-status-gate", HEAD_SHA
    )

    raced = ForeignCheckAPI(response_external_id="legacy-or-foreign-producer")
    try:
        raced.publish_check("ci-status-gate", HEAD_SHA, "success", "ok")
    except module.GateError as error:
        assert "external ID" in str(error)
    else:
        raise AssertionError("publisher accepted a foreign response after a race")


def test_pr_file_pagination_accepts_slurped_array_pages() -> None:
    api = FakeAPI(complete_checks())
    assert module._pr_files(api, 1, 1) == ["README.md"]


def test_pr_file_count_must_be_present_and_exact() -> None:
    api = FakeAPI(complete_checks())
    for expected_count in (None, 0, 2):
        try:
            module._pr_files(api, 1, expected_count)
        except module.GateError as error:
            assert "pull request file" in str(error)
        else:
            raise AssertionError("incomplete pull request file metadata was accepted")


def test_workflow_definition_mismatch_requires_trusted_review() -> None:
    class WorkflowAPI(FakeAPI):
        def __init__(self, *, approved: bool) -> None:
            super().__init__(complete_checks())
            self.approved = approved

        def get(self, endpoint: str, *, paginate: bool = False) -> object:
            if "/contents/.github/workflows/ci.yml?ref=" in endpoint:
                return {
                    "type": "file",
                    "path": module.CI_WORKFLOW_PATH,
                    "sha": BASE_SHA if f"ref={BASE_SHA}" in endpoint else "d" * 40,
                }
            if endpoint.endswith("/pulls/1/reviews?per_page=100"):
                return (
                    [
                        {
                            "id": 1,
                            "user": {"id": 38676809, "login": "austinywang", "type": "User"},
                            "state": "APPROVED",
                            "commit_id": HEAD_SHA,
                            "submitted_at": "2026-09-01T00:00:00Z",
                        }
                    ]
                    if self.approved
                    else []
                )
            return super().get(endpoint, paginate=paginate)

    unapproved = WorkflowAPI(approved=False)
    pull = {"number": 1, "user": {"login": "contributor"}, "base": {"sha": BASE_SHA}}
    try:
        module.verify_ci_workflow_revision(unapproved, pull, HEAD_SHA)
    except module.GateError as error:
        assert "workflow definition" in str(error)
    else:
        raise AssertionError("unreviewed workflow change was accepted")

    module.verify_ci_workflow_revision(WorkflowAPI(approved=True), pull, HEAD_SHA)

    self_authored = {
        **pull,
        "user": {"id": 38676809, "login": "austinywang"},
    }
    try:
        module.verify_ci_workflow_revision(WorkflowAPI(approved=True), self_authored, HEAD_SHA)
    except module.GateError as error:
        assert "workflow definition" in str(error)
    else:
        raise AssertionError("self-approval was accepted")


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: base-owned CI status gate")
