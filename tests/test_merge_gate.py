#!/usr/bin/env python3
"""Pure merge-gate decisions over GitHub API-shaped JSON fixtures."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import merge_gate  # noqa: E402


HEAD = "abc123"
PUSHED = "2026-10-03T15:00:00Z"


def base(**overrides: object) -> dict:
    data: dict = {
        "repository": "manaflow-ai/cmux",
        "head_sha": HEAD,
        "head_pushed_at": PUSHED,
        "required_checks": ["ci-status"],
        "check_runs": [
            {
                "name": "ci-status",
                "head_sha": HEAD,
                "conclusion": "failure",
                "completed_at": "2026-10-03T15:05:00Z",
            }
        ],
        "statuses": [],
        "comments": [],
        "main_runs": [],
        "trusted_logins": ["leo-agent"],
    }
    data.update(overrides)
    return data


def override(
    body: str,
    *,
    login: str = "leo-agent",
    created_at: str = "2026-10-03T15:10:00Z",
    **extra: object,
) -> dict:
    comment = {
        "body": body,
        "created_at": created_at,
        "updated_at": created_at,
        "user": {"login": login},
    }
    comment.update(extra)
    return comment


class MergeGateDecisionTests(unittest.TestCase):
    def test_workflow_event_selects_pull_request_matching_event_head(self) -> None:
        event = {
            "workflow_run": {
                "head_sha": HEAD,
                "head_branch": "feature",
                "head_repository": {"full_name": "manaflow-ai/cmux"},
                "pull_requests": [
                    {"number": 15570, "head": {"sha": "other", "ref": "feature", "repo": {"full_name": "manaflow-ai/cmux"}}},
                    {"number": 17241, "head": {"sha": HEAD, "ref": "feature", "repo": {"full_name": "manaflow-ai/cmux"}}},
                ],
            }
        }
        self.assertEqual(merge_gate._event_pull_request_number(event), 17241)

    def test_workflow_event_with_ambiguous_pull_requests_fails_closed(self) -> None:
        source = {
            "head_sha": HEAD,
            "pull_requests": [
                {"number": 1, "head": {"sha": HEAD}},
                {"number": 2, "head": {"sha": HEAD}},
            ],
        }
        self.assertIsNone(merge_gate._event_pull_request_number({"workflow_run": source}))

    def test_diagnostic_comment_403_is_reported_without_raising(self) -> None:
        class FailingGitHub:
            def request(self, path, method="GET", body=None):
                raise RuntimeError(f"GitHub API {method} {path} failed: HTTP Error 403")

        error = merge_gate._publish_diagnostic(
            FailingGitHub(),
            "manaflow-ai/cmux",
            17241,
            [],
            "<!-- merge-gate -->\nmerge-override required",
        )
        self.assertIn("PR #17241", error or "")
        self.assertIn("403", error or "")
        self.assertIn("REPAIR.md#merging", error or "")

    def test_opened_event_seeds_freshness_for_current_head(self) -> None:
        event = {
            "action": "opened",
            "pull_request": {"head": {"sha": HEAD}, "updated_at": PUSHED},
        }
        self.assertEqual(merge_gate._event_push_time(event, HEAD, []), PUSHED)

    def test_lifecycle_event_for_old_head_does_not_seed_current_head(self) -> None:
        event = {
            "action": "reopened",
            "pull_request": {"head": {"sha": "old-head"}, "updated_at": PUSHED},
        }
        self.assertIsNone(merge_gate._event_push_time(event, HEAD, []))

    def test_current_ci_status_success_passes_without_override(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                check_runs=[
                    {
                        "name": "ci-status",
                        "head_sha": HEAD,
                        "conclusion": "success",
                        "completed_at": "2026-10-03T15:05:00Z",
                    }
                ]
            )
        )
        self.assertTrue(result.passed)
        self.assertEqual(result.conclusion, "success")
        self.assertIn("ci-status", result.reason)

    def test_newer_in_progress_run_does_not_reuse_an_older_success(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                check_runs=[
                    {
                        "name": "ci-status",
                        "head_sha": HEAD,
                        "status": "completed",
                        "conclusion": "success",
                        "completed_at": "2026-10-03T15:05:00Z",
                    },
                    {
                        "name": "ci-status",
                        "head_sha": HEAD,
                        "status": "in_progress",
                        "conclusion": None,
                        "started_at": "2026-10-03T15:06:00Z",
                    },
                ]
            )
        )
        self.assertFalse(result.passed)
        self.assertIn("fresh merge-override", result.reason)

    def test_untimestamped_queued_run_fails_closed(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                check_runs=[
                    {
                        "name": "ci-status",
                        "head_sha": HEAD,
                        "conclusion": "success",
                        "completed_at": "2026-10-03T15:05:00Z",
                    },
                    {
                        "name": "ci-status",
                        "head_sha": HEAD,
                        "status": "queued",
                        "conclusion": None,
                    },
                ]
            )
        )
        self.assertFalse(result.passed)

    def test_fresh_write_access_override_links_main_failures_for_each_check(self) -> None:
        checks = [
            {"name": "ci-status", "head_sha": HEAD, "conclusion": "failure", "completed_at": "2026-10-03T15:05:00Z"},
            {"name": "CI fast guards", "head_sha": HEAD, "conclusion": "failure", "completed_at": "2026-10-03T15:06:00Z"},
        ]
        rationale = (
            "merge-override: ci-status and CI fast guards are failing. "
            "https://github.com/manaflow-ai/cmux/actions/runs/101 shows both checks failing on main. "
            "The failures are unrelated to this change because the touched code is isolated and reviewed."
        )
        result = merge_gate.evaluate_gate(
            base(
                required_checks=["ci-status", "CI fast guards"],
                check_runs=checks,
                comments=[override(rationale)],
                main_runs=[
                    {
                        "id": 101,
                        "head_branch": "main",
                        "head_repository": {"full_name": "manaflow-ai/cmux"},
                        "check_runs": [
                            {"name": "ci-status", "run_id": 101, "conclusion": "failure"},
                            {"name": "CI fast guards", "run_id": 101, "conclusion": "failure"},
                        ],
                    }
                ],
            )
        )
        self.assertTrue(result.passed)
        self.assertEqual(result.failing_checks, ("ci-status", "CI fast guards"))
        self.assertEqual(result.override_comment["user"]["login"], "leo-agent")

    def test_missing_push_timestamp_rejects_override(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                head_pushed_at=None,
                head_commit_timestamp="2026-10-03T14:00:00Z",
                comments=[
                    override(
                        "merge-override: ci-status is not on main. "
                        "This is safe because the affected path is isolated and tested."
                    )
                ],
            )
        )
        self.assertFalse(result.passed)
        self.assertIn("fresh merge-override", result.reason)

    def test_unrelated_check_on_same_main_sha_does_not_prove_failure(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                comments=[
                    override(
                        "merge-override: ci-status https://github.com/manaflow-ai/cmux/actions/runs/202 "
                        "is safe because the change is isolated and tested."
                    )
                ],
                main_runs=[
                    {
                        "id": 202,
                        "head_branch": "main",
                        "head_repository": {"full_name": "manaflow-ai/cmux"},
                        "jobs": [{"name": "ci-status", "run_id": 202, "conclusion": "success"}],
                        "check_runs": [{"name": "ci-status", "run_id": 999, "conclusion": "failure"}],
                    }
                ],
            )
        )
        self.assertFalse(result.passed)

    def test_not_on_main_reason_must_name_each_failing_check(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                required_checks=["ci-status", "CI fast guards"],
                check_runs=[
                    {"name": "ci-status", "head_sha": HEAD, "conclusion": "failure", "completed_at": "2026-10-03T15:05:00Z"},
                    {"name": "CI fast guards", "head_sha": HEAD, "conclusion": "failure", "completed_at": "2026-10-03T15:06:00Z"},
                ],
                comments=[
                    override(
                        "merge-override: ci-status is not on main. CI fast guards failed, "
                        "and the change is safe because review and focused tests cover the affected behavior."
                    )
                ],
            )
        )
        self.assertFalse(result.passed)

    def test_fresh_override_can_explain_that_failure_is_not_on_main(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                comments=[
                    override(
                        "merge-override: ci-status is not on main. "
                        "This is safe because the check is new for this pull request and the change has been reviewed."
                    )
                ]
            )
        )
        self.assertTrue(result.passed)

    def test_override_before_current_head_is_stale(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                comments=[
                    override(
                        "merge-override: ci-status is not on main. "
                        "This was safe for the previous head after review and targeted testing.",
                        created_at="2026-10-03T14:59:59Z",
                    )
                ]
            )
        )
        self.assertFalse(result.passed)
        self.assertIn("fresh merge-override", result.reason)

    def test_override_from_user_without_write_access_is_rejected(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                comments=[
                    override(
                        "merge-override: ci-status is not on main. "
                        "The change is safe because the affected path is isolated and tested.",
                        login="drive-by-contributor",
                    )
                ]
            )
        )
        self.assertFalse(result.passed)
        self.assertEqual(result.failing_checks, ("ci-status",))

    def test_explicit_read_permission_overrides_member_association(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                comments=[
                    override(
                        "merge-override: ci-status is not on main. "
                        "The change is safe because the affected path is isolated and tested.",
                        login="read-only-member",
                        author_permission="read",
                        author_association="MEMBER",
                    )
                ]
            )
        )
        self.assertFalse(result.passed)

    def test_short_boilerplate_override_is_rejected(self) -> None:
        result = merge_gate.evaluate_gate(
            base(comments=[override("merge-override: LGTM")])
        )
        self.assertFalse(result.passed)
        self.assertIn("real sentence", result.reason)

    def test_reusing_an_earlier_rationale_is_rejected(self) -> None:
        body = (
            "merge-override: ci-status is not on main. "
            "The isolated change is safe because review and focused tests cover the affected behavior."
        )
        result = merge_gate.evaluate_gate(
            base(
                comments=[
                    override(body, created_at="2026-10-03T14:00:00Z"),
                    override(body, created_at="2026-10-03T15:10:00Z"),
                ]
            )
        )
        self.assertFalse(result.passed)
        self.assertIn("ci-status", result.reason)

    def test_missing_check_or_main_evidence_is_reported(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                required_checks=["ci-status", "macOS compile"],
                check_runs=[
                    {
                        "name": "ci-status",
                        "head_sha": HEAD,
                        "conclusion": "failure",
                        "completed_at": "2026-10-03T15:05:00Z",
                    },
                    {
                        "name": "macOS compile",
                        "head_sha": HEAD,
                        "conclusion": "failure",
                        "completed_at": "2026-10-03T15:06:00Z",
                    },
                ],
                comments=[
                    override(
                        "merge-override: ci-status is not on main. "
                        "The change is safe because it has focused tests and review."
                    )
                ],
            )
        )
        self.assertFalse(result.passed)
        self.assertEqual(result.failing_checks, ("ci-status", "macOS compile"))
        self.assertIn("macOS compile", result.reason)
        self.assertIn("main run", result.reason)

    def test_link_to_successful_or_non_main_run_does_not_satisfy_override(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                comments=[
                    override(
                        "merge-override: ci-status https://github.com/manaflow-ai/cmux/actions/runs/202 "
                        "is safe because the change is isolated and tested."
                    )
                ],
                main_runs=[
                    {
                        "id": 202,
                        "head_branch": "feature",
                        "check_runs": [{"name": "ci-status", "conclusion": "success"}],
                    }
                ],
            )
        )
        self.assertFalse(result.passed)

    def test_main_failure_evidence_must_match_the_current_conclusion(self) -> None:
        result = merge_gate.evaluate_gate(
            base(
                check_runs=[
                    {
                        "name": "ci-status",
                        "head_sha": HEAD,
                        "conclusion": "timed_out",
                        "completed_at": "2026-10-03T15:05:00Z",
                    }
                ],
                comments=[
                    override(
                        "merge-override: ci-status https://github.com/manaflow-ai/cmux/actions/runs/202 "
                        "is safe because the change is isolated and tested."
                    )
                ],
                main_runs=[
                    {
                        "id": 202,
                        "head_branch": "main",
                        "head_repository": {"full_name": "manaflow-ai/cmux"},
                        "check_runs": [{"name": "ci-status", "conclusion": "failure"}],
                    }
                ],
            )
        )
        self.assertFalse(result.passed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
