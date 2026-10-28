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


SHIP = f"Review (subagent, correctness first): SHIP at {HEAD}"


class ReceiptRules(unittest.TestCase):
    def test_a_ship_receipt_comment_naming_the_head_passes(self):
        self.assertIn("SHIP", receipt.receipt(pr([comment(SHIP)]), HEAD))

    def test_a_ship_must_name_the_full_head(self):
        # cmux#22762 merged at 3a97b47e on a receipt that named 0b4c5bf3: a prefix is too easy to misread or
        # reuse, so a SHIP names all 40 characters of the head (Leo, 2026-10-21).
        for short in (HEAD[:7], HEAD[:12], HEAD[:39]):
            with self.subTest(short=short):
                self.assertEqual(receipt.receipt(pr([comment(f"Review (subagent): SHIP at {short}")]), HEAD), "")
        self.assertIn("SHIP", receipt.receipt(pr([comment(f"Review (subagent): SHIP at {HEAD}")]), HEAD))
        self.assertEqual(receipt.receipt(pr([comment(f"Review (subagent): SHIP at {HEAD}0")]), HEAD), "")
        # A wait verdict still counts when it names the head by a prefix: refusing more is safe.
        later_block = comment(f"Review (subagent): BLOCK at {HEAD[:12]}", at="2026-10-21T06:00:00Z")
        self.assertEqual(receipt.receipt(pr([comment(SHIP), later_block]), HEAD), "")

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


class NewestReviewSaysWait(unittest.TestCase):
    """A SHIP receipt on the head does not merge when the newest review-like comment on any head says wait,
    as next-autoland's review_state() judges it (review of cmux#23067)."""
    LATER = "2026-10-21T06:00:00Z"

    def refused(self, *later_comments, reviews=()):
        found = receipt.decide(pr([comment(SHIP), *later_comments], reviews), HEAD)
        self.assertEqual(found[0], "", found)
        return found[1]

    def test_a_newer_hold_refuses(self):
        why = self.refused(comment("Hold: do not merge until #1 lands", at=self.LATER))
        self.assertIn("Hold", why)

    def test_a_newer_review_block_without_a_sha_refuses(self):
        self.refused(comment("Review (codex): BLOCK, the socket path leaks", at=self.LATER))

    def test_a_newer_verdict_block_refuses(self):
        self.refused(comment("Verdict: BLOCK\nthe wait loop never ends", at=self.LATER))

    def test_newer_changes_requested_on_an_earlier_commit_refuses(self):
        why = self.refused(reviews=[review("CHANGES_REQUESTED", oid=OTHER, at=self.LATER)])
        self.assertIn("changes requested", why)

    def test_a_tool_comment_starting_with_a_marker_is_not_a_review(self):
        tool = comment("<!-- base-red-watch -->\nReview: BLOCK on base", at=self.LATER)
        self.assertIn("SHIP", receipt.decide(pr([comment(SHIP), tool]), HEAD)[0])

    def test_an_older_hold_does_not_refuse_a_newer_receipt(self):
        hold = comment("Hold: do not merge until #1 lands", at="2026-10-21T04:00:00Z")
        self.assertIn("SHIP", receipt.decide(pr([hold, comment(SHIP)]), HEAD)[0])


class BareWaitLine(unittest.TestCase):
    """Re-review of cmux#23067 at 9d98aee: a first line that is only a verdict ("BLOCK at <sha>", "**BLOCK at
    <sha>**", "Do not merge") names no review, so review_state() skipped it and the older SHIP merged."""
    LATER = "2026-10-21T06:00:00Z"

    def decide(self, *later, reviews=()):
        return receipt.decide(pr([comment(SHIP), *later], reviews), HEAD)

    def test_bare_wait_lines_after_a_ship_refuse(self):
        for line in (f"BLOCK at {HEAD[:12]}", f"**BLOCK at {HEAD[:12]}**", "Do not merge", "do not merge until #1 lands",
                     f"NOT SHIP at {HEAD[:12]}", "BLOCK: the lock is dropped", "HOLD"):
            with self.subTest(line=line):
                who, why = self.decide(comment(line + "\ndetails", at=self.LATER))
                self.assertEqual(who, "", why)
                self.assertIn("says wait", why)

    def test_a_bare_wait_line_in_a_review_body_refuses(self):
        who, why = self.decide(reviews=[review("COMMENTED", body=f"**BLOCK at {HEAD[:12]}**", oid=OTHER, at=self.LATER)])
        self.assertEqual(who, "", why)

    def test_an_older_bare_block_does_not_refuse_a_newer_ship(self):
        block = comment(f"BLOCK at {HEAD[:12]}", at="2026-10-21T04:00:00Z")
        self.assertIn("SHIP", receipt.decide(pr([block, comment(SHIP)]), HEAD)[0])

    def test_words_that_only_start_with_a_verdict_do_not_count(self):
        for line in ("Blocked on CI, rerunning", "Blockers: none", "Not shipping docs yet? fine either way"):
            with self.subTest(line=line):
                self.assertIn("SHIP", self.decide(comment(line, at=self.LATER))[0])


class FullWindow(unittest.TestCase):
    """The read sees the newest 30 reviews and 40 comments. When a list comes back full and its oldest entry is not
    older than the SHIP, items newer than the SHIP may have been cut off, so the gate cannot confirm nothing newer
    says wait."""

    @staticmethod
    def at(minute):
        return f"2026-10-21T{5 + minute // 60:02d}:{minute % 60:02d}:00Z"

    def test_a_full_comment_window_whose_oldest_entry_is_the_ship_refuses(self):
        chatter = [comment(f"status {i}", at=self.at(i + 1)) for i in range(39)]
        who, why = receipt.decide(pr([comment(SHIP, at=self.at(0)), *chatter]), HEAD)
        self.assertEqual(who, "", why)
        self.assertIn("window full", why)

    def test_a_full_review_window_newer_than_the_ship_refuses(self):
        reviews = [review("COMMENTED", body=f"note {i}", oid=OTHER, at=self.at(i + 1)) for i in range(30)]
        who, why = receipt.decide(pr([comment(SHIP, at=self.at(0))], reviews), HEAD)
        self.assertEqual(who, "", why)
        self.assertIn("window full", why)

    def test_an_unsubmitted_review_does_not_make_a_full_window_reach_past_the_ship(self):
        # A pending review has submittedAt null; read as "", it looked older than the SHIP and let the gate pass.
        reviews = [review("COMMENTED", body=f"note {i}", oid=OTHER, at=self.at(i + 1)) for i in range(29)]
        pending = review("PENDING", oid=OTHER, at=None)
        who, why = receipt.decide(pr([comment(SHIP, at=self.at(0))], [pending, *reviews]), HEAD)
        self.assertEqual(who, "", why)
        self.assertIn("window full", why)

    def test_a_full_window_that_reaches_past_the_ship_passes(self):
        older = [comment(f"status {i}", at=self.at(i)) for i in range(20)]
        newer = [comment(f"status {i}", at=self.at(i + 30)) for i in range(19)]
        self.assertIn("SHIP", receipt.decide(pr([*older, comment(SHIP, at=self.at(25)), *newer]), HEAD)[0])

    def test_a_window_below_its_cap_passes(self):
        chatter = [comment(f"status {i}", at=self.at(i + 1)) for i in range(38)]
        self.assertIn("SHIP", receipt.decide(pr([comment(SHIP, at=self.at(0)), *chatter]), HEAD)[0])


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
        self.assertIn(f"Review (subagent, correctness first): SHIP at {HEAD}", err)
        # A base merge makes a new head, which needs its own receipt.
        self.assertIn("merge-main.sh", err)
        self.assertIn("update-branch", err)

    def test_a_newest_review_that_says_wait_refuses(self):
        status, _, err = self.run_main(pr([comment(SHIP), comment("Hold: waiting on #1", at="2026-10-21T06:00:00Z")]))
        self.assertEqual(status, 1)
        self.assertIn("the newest review says wait", err)

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
        # next-autoland's windows, so the two tools judge the same reviews and comments.
        for field in ("__typename", "authorAssociation", "commit{oid}", "reviews(last:30)", "comments(last:40)"):
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
