"""scripts/ci/review_receipt.py: gh-merge-green merges into feat-cmux-next only a head with a SHIP review receipt.

Autoland paused 2026-10-21 after it merged cmux#22899 before its re-review (which found cmux#22988); next-autoland
now lands only a head an independent review passed (leo-workspace e2a34f6). gh-merge-green applies the same rule.
"""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("review_receipt", ROOT / "scripts/ci/review_receipt.py")
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)

HEAD = "4b438e85a74f" + "0" * 28
OTHER = "9" * 40
USER = {"__typename": "User", "login": "teamleaderleo"}


def comment(body, at="2026-10-21T05:00:00Z", author=USER, association="MEMBER"):
    return {"createdAt": at, "body": body, "authorAssociation": association, "author": author}


def review(state="COMMENTED", body="", at="2026-10-21T05:00:00Z", oid=HEAD, author=USER, association="MEMBER"):
    return {"state": state, "submittedAt": at, "body": body, "authorAssociation": association, "author": author,
            "commit": {"oid": oid}}


def pr(comments=(), reviews=(), head=HEAD):
    return {"headRefOid": head, "comments": {"nodes": list(comments)}, "reviews": {"nodes": list(reviews)}}


SHIP = f"Review (subagent, correctness first): SHIP at {HEAD[:12]}"


class ReceiptRules(unittest.TestCase):
    def test_a_ship_receipt_comment_naming_the_head_passes(self):
        self.assertIn("SHIP", receipt.receipt(pr([comment(SHIP)]), HEAD))

    def test_no_receipt_refuses(self):
        self.assertEqual(receipt.receipt(pr([comment("Addressed review findings: nothing blocking")]), HEAD), "")
        self.assertEqual(receipt.receipt(pr(), HEAD), "")

    def test_a_receipt_for_another_commit_does_not_count(self):
        self.assertEqual(receipt.receipt(pr([comment(f"Review (subagent): SHIP at {OTHER[:12]}")]), HEAD), "")

    def test_a_self_review_does_not_count(self):
        self.assertEqual(receipt.receipt(pr([comment(f"Review (self): SHIP at {HEAD[:12]}")]), HEAD), "")
        self.assertEqual(receipt.receipt(pr([comment(f"Review (self-check, subagent): SHIP at {HEAD}")]), HEAD), "")

    def test_the_receipt_must_be_the_first_non_empty_line(self):
        self.assertIn("SHIP", receipt.receipt(pr([comment("\n\n  " + SHIP + "\nall good")]), HEAD))
        self.assertEqual(receipt.receipt(pr([comment("Status update\n" + SHIP)]), HEAD), "")

    def test_bots_and_outside_accounts_do_not_count(self):
        bot = {"__typename": "Bot", "login": "github-actions"}
        self.assertEqual(receipt.receipt(pr([comment(SHIP, author=bot)]), HEAD), "")
        self.assertEqual(receipt.receipt(pr([comment(SHIP, association="CONTRIBUTOR")]), HEAD), "")
        self.assertEqual(receipt.receipt(pr([comment(SHIP, association="NONE")]), HEAD), "")
        self.assertEqual(receipt.receipt(pr(reviews=[review("APPROVED", author=bot)]), HEAD), "")
        for association in ("OWNER", "MEMBER", "COLLABORATOR"):
            self.assertIn("SHIP", receipt.receipt(pr([comment(SHIP, association=association)]), HEAD))

    def test_an_approval_of_the_head_passes_and_of_another_commit_does_not(self):
        self.assertIn("approved", receipt.receipt(pr(reviews=[review("APPROVED")]), HEAD))
        self.assertEqual(receipt.receipt(pr(reviews=[review("APPROVED", oid=OTHER)]), HEAD), "")

    def test_a_newer_block_beats_an_older_ship(self):
        block = comment(f"Independent review (codex): BLOCK at {HEAD[:12]}: leaks a socket", at="2026-10-21T06:00:00Z")
        self.assertEqual(receipt.receipt(pr([comment(SHIP), block]), HEAD), "")
        changes = review("CHANGES_REQUESTED", at="2026-10-21T06:00:00Z")
        self.assertEqual(receipt.receipt(pr([comment(SHIP)], [changes]), HEAD), "")
        for verdict in ("FIX", "not ship", "hold"):
            later = comment(f"Review (subagent): {verdict} at {HEAD[:12]}", at="2026-10-21T06:00:00Z")
            self.assertEqual(receipt.receipt(pr([comment(SHIP), later]), HEAD), "", verdict)

    def test_a_newer_ship_beats_an_older_block(self):
        block = comment(f"Review (subagent): BLOCK at {HEAD[:12]}", at="2026-10-21T04:00:00Z")
        self.assertIn("SHIP", receipt.receipt(pr([block, comment(SHIP)]), HEAD))

    def test_the_autoreview_marker_decides_its_comment(self):
        ship = f"Looks fine.\n<!-- autoreview verdict=SHIP sha={HEAD} -->"
        self.assertIn("autoreview SHIP", receipt.receipt(pr([comment(ship)]), HEAD))
        block = f"{SHIP}\n<!-- autoreview verdict=BLOCK sha={HEAD} -->"
        self.assertEqual(receipt.receipt(pr([comment(block)]), HEAD), "")
        # A marker for another commit decides its comment too: the SHIP line above it does not count.
        other = f"{SHIP}\n<!-- autoreview verdict=SHIP sha={OTHER} -->"
        self.assertEqual(receipt.receipt(pr([comment(other)]), HEAD), "")

    def test_a_review_body_can_carry_the_receipt(self):
        self.assertIn("SHIP", receipt.receipt(pr(reviews=[review("COMMENTED", body=SHIP, oid=OTHER)]), HEAD))

    def test_a_verdict_word_must_end_the_word(self):
        self.assertEqual(receipt.receipt(pr([comment(f"Review (subagent): shipping-ready at {HEAD[:12]}")]), HEAD), "")
        self.assertEqual(receipt.receipt(pr([comment(f"Review (subagent): shipit at {HEAD[:12]}")]), HEAD), "")


class Command(unittest.TestCase):
    def run_main(self, payload, sha=HEAD):
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(payload, handle)
            handle.flush()
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                status = receipt.main(["manaflow-ai/cmux", "42", sha, "--pr-file", handle.name])
        return status, out.getvalue(), err.getvalue()

    def test_a_receipt_prints_who_passed_the_head(self):
        status, out, _ = self.run_main({"data": {"repository": {"pullRequest": pr([comment(SHIP)])}}})
        self.assertEqual(status, 0)
        self.assertTrue(out.startswith("receipt="), out)

    def test_no_receipt_refuses_with_the_comment_to_post(self):
        status, _, err = self.run_main(pr())
        self.assertEqual(status, 1)
        self.assertIn(f"Review (subagent, correctness first): SHIP at {HEAD[:12]}", err)

    def test_a_moved_head_refuses(self):
        status, _, err = self.run_main(pr([comment(SHIP)], head=OTHER))
        self.assertEqual(status, 1)
        self.assertIn("head", err)

    def test_the_read_asks_for_author_types_and_review_commits(self):
        calls = []

        def run(args):
            calls.append(args)
            return 0, json.dumps({"data": {"repository": {"pullRequest": pr([comment(SHIP)])}}}), ""

        self.assertEqual(receipt.read_pr("manaflow-ai/cmux", "42", run=run)["headRefOid"], HEAD)
        self.assertEqual(len(calls), 1)
        query = " ".join(calls[0])
        for field in ("__typename", "authorAssociation", "commit{oid}", "reviews(last:100)", "comments(last:100)"):
            self.assertIn(field, query)

    def test_a_rate_limited_read_exits_3(self):
        def run(args):
            return 1, "", "gh: API rate limit exceeded for user ID 1. (HTTP 403)"

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status = receipt.main(["manaflow-ai/cmux", "42", HEAD], run=run)
        self.assertEqual(status, 3, err.getvalue())

    def test_an_unreadable_pull_request_refuses(self):
        def run(args):
            return 1, "", "HTTP 502"

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status = receipt.main(["manaflow-ai/cmux", "42", HEAD], run=run)
        self.assertEqual(status, 1, err.getvalue())


if __name__ == "__main__":
    unittest.main()
