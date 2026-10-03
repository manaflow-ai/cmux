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
                            {"name": "ci-status", "conclusion": "failure"},
                            {"name": "CI fast guards", "conclusion": "failure"},
                        ],
                    }
                ],
            )
        )
        self.assertTrue(result.passed)
        self.assertEqual(result.failing_checks, ("ci-status", "CI fast guards"))
        self.assertEqual(result.override_comment["user"]["login"], "leo-agent")

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
