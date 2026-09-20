import importlib.util
import unittest
import sys
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


def thread(bot="coderabbitai", *, reply=False, outdated=False, resolved=False):
    comments = [{"author": {"login": bot}, "body": "Please fix this", "createdAt": "2026-01-01T00:00:00Z"}]
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

    def test_outdated_and_informational_threads_are_not_obligations(self):
        informational = thread()
        informational["comments"]["nodes"][0]["body"] = "Review limit reached; no actionable comments"
        passed, _, items = gate.evaluate(make_pr(reviews=[review("coderabbitai"), review("greptile-apps")], threads=[thread(outdated=True), informational]))
        self.assertTrue(passed)
        self.assertEqual(items, [])


if __name__ == "__main__":
    unittest.main()
