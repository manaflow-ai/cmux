import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / ".github/scripts/github_review_receipt.py"
POLICY = ROOT / ".github/review-fabric-policy.json"

spec = importlib.util.spec_from_file_location("github_review_receipt", SCRIPT)
github_review_receipt = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = github_review_receipt
spec.loader.exec_module(github_review_receipt)

gate = github_review_receipt.load_gate()
review_fabric = github_review_receipt.review_fabric

HEAD = "a" * 40
OLD_HEAD = "b" * 40


def review(
    bot="coderabbitai[bot]",
    *,
    oid=HEAD,
    state="COMMENTED",
    at="2026-09-21T12:00:00Z",
    review_id="review-1",
):
    return {
        "id": review_id,
        "author": {"login": bot},
        "state": state,
        "submittedAt": at,
        "commit": {"oid": oid},
    }


def thread(
    bot="coderabbitai[bot]",
    *,
    thread_id="thread-1",
    body="Please fix this",
    bot_at="2026-09-21T12:01:00Z",
    reply=False,
    reply_at="2026-09-21T12:02:00Z",
    resolved=False,
    outdated=False,
    review_id="review-1",
):
    comments = [{
        "author": {"login": bot},
        "body": body,
        "createdAt": bot_at,
        "pullRequestReview": {"id": review_id},
    }]
    if reply:
        comments.append(
            {
                "author": {"login": "agent-author"},
                "body": "Addressed",
                "createdAt": reply_at,
                "pullRequestReview": {"id": review_id},
            }
        )
    return {
        "id": thread_id,
        "isResolved": resolved,
        "isOutdated": outdated,
        "path": "Sources/Foo.swift",
        "line": 10,
        "comments": {"nodes": comments},
    }


def greptile_summary(oid=HEAD):
    return {
        "author": {"login": "greptile-apps[bot]"},
        "body": (
            "<!-- greptile_summary -->\n"
            "<sub>Reviews (2) · Last reviewed commit: "
            f"[reviewed](https://github.com/manaflow-ai/cmux/commit/{oid})</sub>"
        ),
        "createdAt": "2026-09-21T12:03:00Z",
        "updatedAt": "2026-09-21T12:03:00Z",
    }


def make_pr(*, reviews=None, threads=None, comments=None, capture_complete=True, head=HEAD):
    return {
        "number": 42,
        "body": "<!-- agent-pr-review-required -->",
        "headRefOid": head,
        "author": {"login": "agent-author"},
        "reviews": {"nodes": reviews or []},
        "reviewThreads": {"nodes": threads or []},
        "comments": {"nodes": comments or []},
        "captureComplete": capture_complete,
    }


def receipt(pr):
    return github_review_receipt.receipt_from_pr(
        pr,
        bots=gate.DEFAULT_REVIEW_BOTS,
        reply_actors=("agent-author",),
        gate=gate,
    )


class GitHubReviewReceiptTests(unittest.TestCase):
    def test_current_head_review_becomes_external_review_run(self):
        result = receipt(make_pr(reviews=[review()]))
        self.assertTrue(result["capture_complete"])
        self.assertEqual(len(result["runs"]), 1)
        run = result["runs"][0]
        self.assertEqual(run["head_sha"], HEAD)
        self.assertEqual(run["provider"], "coderabbitai")
        self.assertEqual(run["harness"], "github-review")
        self.assertEqual(run["capability_class"], "external")
        self.assertEqual(run["disposition"], "accept")

    def test_external_review_alone_cannot_satisfy_default_fabric_policy(self):
        result = receipt(make_pr(reviews=[review()]))
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        report = review_fabric.evaluate(result, policy)
        self.assertFalse(report["passed"])
        self.assertTrue(any("independent review quorum" in reason for reason in report["reasons"]))
        self.assertTrue(any("capability quorum frontier" in reason for reason in report["reasons"]))

    def test_inline_comment_can_precede_parent_review_submission(self):
        result = receipt(
            make_pr(
                reviews=[
                    review(
                        at="2026-09-21T12:26:30Z",
                        review_id="review-real-order",
                    )
                ],
                threads=[
                    thread(
                        bot_at="2026-09-21T12:26:28Z",
                        review_id="review-real-order",
                    )
                ],
            )
        )
        self.assertTrue(result["capture_complete"])
        self.assertEqual(len(result["runs"]), 1)
        self.assertEqual(len(result["findings"]), 1)
        self.assertEqual(result["findings"][0]["run_id"], result["runs"][0]["id"])
        self.assertEqual(result["findings"][0]["head_sha"], HEAD)
        self.assertEqual(result["runs"][0]["disposition"], "repair")

    def test_old_review_can_source_current_actionable_thread_without_counting_as_current_review(self):
        result = receipt(
            make_pr(
                reviews=[review(oid=OLD_HEAD)],
                threads=[thread()],
            )
        )
        self.assertTrue(result["capture_complete"])
        self.assertEqual(result["runs"][0]["head_sha"], OLD_HEAD)
        self.assertEqual(result["runs"][0]["disposition"], "repair")
        self.assertEqual(result["findings"][0]["head_sha"], HEAD)
        self.assertEqual(result["findings"][0]["disposition"], "pending")

        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        report = review_fabric.evaluate(result, policy)
        self.assertIn(result["runs"][0]["id"], report["stale_run_ids"])
        self.assertTrue(any("actionable finding" in reason for reason in report["reasons"]))

    def test_active_thread_without_structured_review_fails_capture_closed(self):
        result = receipt(make_pr(threads=[thread()]))
        self.assertFalse(result["capture_complete"])
        self.assertEqual(result["findings"], [])

    def test_replied_thread_remains_unverified(self):
        result = receipt(
            make_pr(
                reviews=[review()],
                threads=[thread(reply=True)],
            )
        )
        finding = result["findings"][0]
        self.assertEqual(finding["disposition"], "answered_unverified")
        self.assertTrue(finding["actionable"])
        self.assertFalse(finding["verified"])

    def test_resolved_thread_states_remain_distinct(self):
        replied = receipt(
            make_pr(
                reviews=[review()],
                threads=[thread(reply=True, resolved=True)],
            )
        )
        self.assertEqual(replied["findings"][0]["disposition"], "resolved_unverified")

        unanswered = receipt(
            make_pr(
                reviews=[review()],
                threads=[thread(resolved=True)],
            )
        )
        self.assertEqual(unanswered["findings"][0]["disposition"], "resolved_unanswered")

    def test_outdated_thread_is_retained_but_inactive(self):
        result = receipt(
            make_pr(
                reviews=[review(oid=OLD_HEAD)],
                threads=[thread(outdated=True)],
            )
        )
        finding = result["findings"][0]
        self.assertEqual(finding["disposition"], "outdated")
        self.assertFalse(finding["actionable"])

    def test_changes_requested_marks_source_run_for_repair(self):
        result = receipt(make_pr(reviews=[review(state="CHANGES_REQUESTED")]))
        self.assertEqual(result["runs"][0]["disposition"], "repair")

    def test_greptile_summary_provides_exact_head_review_evidence(self):
        result = receipt(make_pr(comments=[greptile_summary()]))
        self.assertEqual(len(result["runs"]), 1)
        run = result["runs"][0]
        self.assertEqual(run["provider"], "greptile-apps")
        self.assertEqual(run["head_sha"], HEAD)
        self.assertEqual(run["harness"], "github-summary")

    def test_unconfigured_reviewers_are_ignored(self):
        result = receipt(make_pr(reviews=[review(bot="some-other-bot[bot]")]))
        self.assertEqual(result["runs"], [])
        self.assertTrue(result["capture_complete"])

    def test_dismissed_reviews_are_not_receipts(self):
        result = receipt(make_pr(reviews=[review(state="DISMISSED")]))
        self.assertEqual(result["runs"], [])

    def test_provider_thread_disposition_does_not_invent_severity(self):
        result = receipt(
            make_pr(
                reviews=[review()],
                threads=[thread(body="P1 maybe, please investigate")],
            )
        )
        self.assertEqual(result["findings"][0]["severity"], "unknown")

    def test_ci_executes_github_review_adapter_contracts(self):
        workflow = (ROOT / ".github/workflows/ci-guards.yml").read_text(encoding="utf-8")
        detector = (ROOT / "scripts/ci/detect_linux_guard_changes.py").read_text(encoding="utf-8")
        self.assertIn("python3 tests/test_github_review_receipt.py", workflow)
        for path in (
            ".github/scripts/github_review_receipt.py",
            "tests/test_github_review_receipt.py",
        ):
            self.assertIn(f'"{path}"', detector)


if __name__ == "__main__":
    unittest.main()
