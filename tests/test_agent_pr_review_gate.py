import importlib.util
import unittest
from unittest import mock
import sys
import urllib.error
from pathlib import Path

path = Path(__file__).parents[1] / ".github/scripts/agent-pr-review-gate.py"
spec = importlib.util.spec_from_file_location("gate", path)
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)


def make_pr(*, body="<!-- agent-pr-review-required -->", head="abc", threads=None, reviews=None, author="agent-author"):
    return {"body": body, "headRefOid": head, "author": {"login": author}, "reviews": {"nodes": reviews or []}, "reviewThreads": {"nodes": threads or []}}


def review(bot="coderabbitai", oid="abc"):
    return {"author": {"login": bot}, "state": "COMMENTED", "commit": {"oid": oid}}


def thread(bot="coderabbitai", *, reply=False, outdated=False, resolved=False, body="Please fix this"):
    comments = [{"author": {"login": bot}, "body": body, "createdAt": "2026-01-01T00:00:00Z"}]
    if reply:
        comments.append({"author": {"login": "agent-author"}, "body": "Fixed in abc", "createdAt": "2026-01-01T00:01:00Z"})
    return {"id": f"thread-{bot}-{reply}", "isOutdated": outdated, "isResolved": resolved, "path": "Sources/Foo.swift", "line": 10, "comments": {"nodes": comments}}


class AgentPRReviewGateTests(unittest.TestCase):
    def test_non_opted_in_pr_passes_without_reviews(self):
        passed, reasons, items = gate.evaluate(make_pr(body="ordinary human PR", reviews=[]))
        self.assertTrue(passed)
        self.assertFalse(items)
        self.assertIn("not opted", reasons[0])

    def test_current_head_requires_each_configured_bot(self):
        import os
        previous = os.environ.get("REQUIRE_BOT_REVIEW_COVERAGE")
        os.environ["REQUIRE_BOT_REVIEW_COVERAGE"] = "1"
        try:
            passed, reasons, _ = gate.evaluate(make_pr(reviews=[review("coderabbitai")]))
        finally:
            if previous is None:
                os.environ.pop("REQUIRE_BOT_REVIEW_COVERAGE", None)
            else:
                os.environ["REQUIRE_BOT_REVIEW_COVERAGE"] = previous
        self.assertFalse(passed)
        self.assertTrue(any("greptile-apps" in reason for reason in reasons))

    def test_unanswered_thread_blocks_even_when_resolved(self):
        passed, reasons, items = gate.evaluate(make_pr(reviews=[review("coderabbitai"), review("greptile-apps")], threads=[thread(resolved=True)]))
        self.assertFalse(passed)
        self.assertEqual(len(items), 1)
        self.assertTrue(any("unanswered" in reason for reason in reasons))

    def test_reply_after_bot_comment_satisfies_thread(self):
        passed, reasons, items = gate.evaluate(make_pr(reviews=[review("coderabbitai"), review("greptile-apps")], threads=[thread(reply=True)]))
        self.assertTrue(passed)
        self.assertTrue(items[0].replied)
        self.assertIn("answered", reasons[0])

    def test_configured_reply_actor_is_recorded_and_used(self):
        passed, _, items = gate.evaluate(
            make_pr(
                reviews=[review("coderabbitai"), review("greptile-apps")],
                threads=[thread(reply=False)],
            ),
            reply_actors=("review-agent",),
        )
        self.assertFalse(passed)
        pr = make_pr(reviews=[review("coderabbitai"), review("greptile-apps")], threads=[thread(reply=True)])
        pr["reviewThreads"]["nodes"][0]["comments"]["nodes"][1]["author"]["login"] = "review-agent"
        passed, _, items = gate.evaluate(pr, reply_actors=("review-agent",))
        self.assertTrue(passed)
        self.assertEqual(items[0].reply_actor, "review-agent")

    def test_reply_and_resolution_are_reported_as_unverified(self):
        pr = make_pr(
            reviews=[review("coderabbitai"), review("greptile-apps")],
            threads=[thread(reply=True, resolved=True)],
        )
        ledger = gate.review_ledger(pr, gate.DEFAULT_REVIEW_BOTS, ("agent-author",))
        self.assertEqual(ledger[0].disposition, "resolved_unverified")

    def test_attention_needed_tracks_unanswered_actionable_findings(self):
        unanswered = gate.review_ledger(
            make_pr(threads=[thread()]),
            gate.DEFAULT_REVIEW_BOTS,
            ("agent-author",),
        )
        self.assertTrue(gate.attention_needed(unanswered))

        answered = gate.review_ledger(
            make_pr(threads=[thread(reply=True)]),
            gate.DEFAULT_REVIEW_BOTS,
            ("agent-author",),
        )
        self.assertFalse(gate.attention_needed(answered))

        outdated = gate.review_ledger(
            make_pr(threads=[thread(outdated=True)]),
            gate.DEFAULT_REVIEW_BOTS,
            ("agent-author",),
        )
        self.assertFalse(gate.attention_needed(outdated))

    def test_unavailable_provider_is_not_an_actionable_thread(self):
        pr = make_pr(
            reviews=[review("coderabbitai")],
            threads=[thread("greptile-apps", body="Bugbot is paused — on-demand spend limit reached")],
        )
        passed, _, items = gate.evaluate(pr)
        self.assertTrue(passed)
        self.assertEqual(items, [])
        report = gate.ledger_report(pr, gate.DEFAULT_REVIEW_BOTS, ("agent-author",))
        self.assertEqual(report["coverage"][0]["status"], "reviewed")
        self.assertEqual(report["coverage"][1]["status"], "unavailable")

    def test_incomplete_capture_never_passes(self):
        pr = make_pr(reviews=[review("coderabbitai"), review("greptile-apps")])
        pr["captureComplete"] = False
        passed, reasons, _ = gate.evaluate(pr)
        self.assertFalse(passed)
        self.assertTrue(any("capture incomplete" in reason for reason in reasons))

    def test_rate_limit_wording_in_a_finding_remains_actionable(self):
        pr = make_pr(
            reviews=[review("coderabbitai"), review("greptile-apps")],
            threads=[thread(body="Please add rate limiting to this endpoint")],
        )
        passed, _, items = gate.evaluate(pr)
        self.assertFalse(passed)
        self.assertEqual(items[0].kind, "finding")

    def test_walkthrough_is_informational(self):
        pr = make_pr(
            reviews=[review("coderabbitai"), review("greptile-apps")],
            threads=[thread(body="<!-- walkthrough_start -->\\n## Walkthrough")],
        )
        passed, _, items = gate.evaluate(pr)
        self.assertTrue(passed)
        self.assertEqual(items, [])

    def test_dismissed_review_does_not_count_for_coverage(self):
        import os
        previous = os.environ.get("REQUIRE_BOT_REVIEW_COVERAGE")
        os.environ["REQUIRE_BOT_REVIEW_COVERAGE"] = "1"
        try:
            pr = make_pr(reviews=[review("coderabbitai"), review("greptile-apps")])
            pr["reviews"]["nodes"][0]["state"] = "DISMISSED"
            passed, reasons, _ = gate.evaluate(pr)
        finally:
            if previous is None:
                os.environ.pop("REQUIRE_BOT_REVIEW_COVERAGE", None)
            else:
                os.environ["REQUIRE_BOT_REVIEW_COVERAGE"] = previous
        self.assertFalse(passed)
        self.assertTrue(any("coderabbitai" in reason for reason in reasons))

    def test_sync_attention_label_creates_and_adds_missing_label(self):
        pr = make_pr()
        pr["number"] = 42
        items = gate.review_ledger(
            make_pr(threads=[thread()]),
            gate.DEFAULT_REVIEW_BOTS,
            ("agent-author",),
        )
        not_found = urllib.error.HTTPError("https://api.github.test", 404, "missing", {}, None)
        calls = []

        def github_rest(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                raise not_found
            return {}

        with mock.patch.object(gate, "github_rest", side_effect=github_rest):
            self.assertEqual(gate.sync_attention_label(pr, items, "review: needs-attention"), "present")

        self.assertEqual(calls[0][:2], ("GET", "labels/review%3A%20needs-attention"))
        self.assertEqual(calls[1][0:2], ("POST", "labels"))
        self.assertEqual(calls[2], (
            "POST",
            "issues/42/labels",
            {"labels": ["review: needs-attention"]},
        ))

    def test_sync_attention_label_tolerates_create_race(self):
        pr = make_pr()
        pr["number"] = 42
        items = gate.review_ledger(
            make_pr(threads=[thread()]),
            gate.DEFAULT_REVIEW_BOTS,
            ("agent-author",),
        )
        not_found = urllib.error.HTTPError("https://api.github.test", 404, "missing", {}, None)
        exists = urllib.error.HTTPError("https://api.github.test", 422, "exists", {}, None)

        def github_rest(method, path, payload=None):
            if method == "GET":
                raise not_found
            if method == "POST" and path == "labels":
                raise exists
            return {}

        with mock.patch.object(gate, "github_rest", side_effect=github_rest):
            self.assertEqual(gate.sync_attention_label(pr, items, "review: needs-attention"), "present")

    def test_sync_attention_label_removes_stale_label_and_ignores_missing(self):
        pr = make_pr()
        pr["number"] = 42
        missing = urllib.error.HTTPError("https://api.github.test", 404, "missing", {}, None)
        calls = []

        def github_rest(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "DELETE":
                raise missing
            return {}

        with mock.patch.object(gate, "github_rest", side_effect=github_rest):
            self.assertEqual(gate.sync_attention_label(pr, [], "review: needs-attention"), "absent")

        self.assertEqual(calls[-1][0:2], ("DELETE", "issues/42/labels/review%3A%20needs-attention"))

    def test_outdated_and_informational_threads_are_not_obligations(self):
        informational = thread()
        informational["comments"]["nodes"][0]["body"] = "Review limit reached; no actionable comments"
        passed, _, items = gate.evaluate(make_pr(reviews=[review("coderabbitai"), review("greptile-apps")], threads=[thread(outdated=True), informational]))
        self.assertTrue(passed)
        self.assertEqual(items, [])


if __name__ == "__main__":
    unittest.main()
