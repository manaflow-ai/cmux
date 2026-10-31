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


def pr(comments=(), reviews=(), head=HEAD, labels=()):
    return {"headRefOid": head, "comments": {"nodes": list(comments)}, "reviews": {"nodes": list(reviews)},
            "labels": {"nodes": [{"name": name} for name in labels]}}


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

    def test_an_automatic_ship_does_not_clear_a_human_hold(self):
        hold = comment("Hold: dogfood first.", at="2026-10-21T05:00:00Z")
        automatic = comment(
            f"Review (codex, next-review): SHIP at {HEAD}\n"
            "<!-- next-review since=2026-10-21T05:30:00Z run=feed -->\n"
            f"<!-- autoreview verdict=SHIP sha={HEAD} -->",
            at="2026-10-21T06:00:00Z",
        )
        who, why = receipt.decide(pr([hold, automatic]), HEAD)
        self.assertEqual(who, "", why)
        self.assertIn("Hold", why)

    def test_a_later_human_review_releases_the_hold_over_an_automatic_ship(self):
        hold = comment("Hold: dogfood first.", at="2026-10-21T05:00:00Z")
        automatic = comment(
            f"Review (codex, next-review): SHIP at {HEAD}\n"
            "<!-- next-review since=2026-10-21T05:30:00Z run=feed -->\n"
            f"<!-- autoreview verdict=SHIP sha={HEAD} -->",
            at="2026-10-21T06:00:00Z",
        )
        human = comment(SHIP, at="2026-10-21T07:00:00Z")
        self.assertIn("SHIP", receipt.decide(pr([hold, automatic, human]), HEAD)[0])

    def test_a_human_approval_quoting_an_automatic_body_still_releases_the_hold(self):
        hold = comment("Hold: dogfood first.", at="2026-10-21T05:00:00Z")
        body = (
            f"Review (codex, next-review): SHIP at {HEAD}\n"
            "<!-- next-review since=2026-10-21T05:30:00Z run=feed -->\n"
            f"<!-- autoreview verdict=SHIP sha={HEAD} -->"
        )
        automatic = comment(body, at="2026-10-21T06:00:00Z")
        human = review("APPROVED", body=body, at="2026-10-21T07:00:00Z")
        self.assertIn("approved", receipt.decide(pr([hold, automatic], [human]), HEAD)[0])

    def test_a_human_comment_quoting_an_automatic_body_still_releases_the_hold(self):
        hold = comment("Hold: dogfood first.", at="2026-10-21T05:00:00Z")
        body = (
            f"Review (codex, next-review): SHIP at {HEAD}\n"
            "<!-- next-review since=2026-10-21T05:30:00Z run=feed -->\n"
            f"<!-- autoreview verdict=SHIP sha={HEAD} -->"
        )
        automatic = comment(body, at="2026-10-21T06:00:00Z")
        human = comment(body, at="2026-10-21T07:00:00Z")
        self.assertIn("SHIP", receipt.decide(pr([hold, automatic, human]), HEAD)[0])

    def test_a_retained_automatic_marker_on_a_hold_stays_a_hold(self):
        retained = comment(
            f"Hold: dogfood first.\n<!-- next-review since=2026-10-21T05:30:00Z run=feed -->\n"
            f"<!-- autoreview verdict=SHIP sha={HEAD} -->",
            at="2026-10-21T06:00:00Z",
        )
        who, why = receipt.decide(pr([retained]), HEAD)
        self.assertEqual(who, "", why)
        self.assertIn("Hold", why)

    def test_a_hold_lift_line_releases_the_automatic_ship(self):
        hold = comment("Hold: dogfood first.", at="2026-10-21T05:00:00Z")
        automatic = comment(
            f"Review (codex, next-review): SHIP at {HEAD}\n"
            "<!-- next-review since=2026-10-21T05:30:00Z run=feed -->\n"
            f"<!-- autoreview verdict=SHIP sha={HEAD} -->",
            at="2026-10-21T06:00:00Z",
        )
        lift = comment("Hold lifted.", at="2026-10-21T07:00:00Z")
        self.assertIn("SHIP", receipt.decide(pr([hold, automatic, lift]), HEAD)[0])

    def test_a_hold_lift_line_releases_a_prior_human_ship(self):
        prior = comment(SHIP, at="2026-10-21T04:00:00Z")
        hold = comment("Hold: dogfood first.", at="2026-10-21T05:00:00Z")
        lift = comment("Hold lifted.", at="2026-10-21T07:00:00Z")
        self.assertIn("SHIP", receipt.decide(pr([prior, hold, lift]), HEAD)[0])


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


class NewestIndependentVerdictWins(unittest.TestCase):
    """cmux#27189 (2026-10-29): SHIP at A, the box review of A said BLOCK, a base merge made C, and a lane's
    "Review (Astra; carried): SHIP at C" landed it. The newest independent verdict on the PR, on any head, decides,
    not the newest SHIP; a carried SHIP is a lane's claim, not a verdict (next-autoland, cmuxterm-hq#4975)."""
    A, B, C = "a1" * 20, "b2" * 20, "c3" * 20

    @staticmethod
    def at(minute):
        return f"2026-10-29T05:{minute:02d}:00Z"

    def ship(self, sha, minute, reviewer="codex gpt-6-astra high"):
        return comment(f"Review ({reviewer}): SHIP at {sha}", at=self.at(minute))

    def carried(self, sha, of, minute):
        return comment(f"Review (codex gpt-6-astra high; carried): SHIP at {sha}\n\n"
                       f"{sha[:8]} is a base merge into {of[:8]}; the SHIP at {of[:8]} carries.", at=self.at(minute))

    def box(self, kind, sha, minute, marker=True):
        # A lane-place review box's verdict (leo-workspace#1455): its receipt line, with or without its markers.
        body = f"Review (codex-review-box/gpt-6-astra high, lane-place): {kind} at {sha}\n\nFindings.\n"
        if marker:
            body += f"<!-- autoreview verdict={kind} sha={sha} -->\n<!-- lane-place-review box=review-1-{sha[:4]} sha={sha} -->"
        return comment(body, at=self.at(minute))

    def blocks(self, sha, minute):
        """A BLOCK of `sha` in every form the matcher reads, as (name, comments, reviews)."""
        return {
            "a receipt line": ([comment(f"Review (codex, box review-1-a1a1): BLOCK at {sha[:7]}: P2", at=self.at(minute))], []),
            "the autoreview marker": ([comment(f"Findings.\n<!-- autoreview verdict=BLOCK sha={sha} -->", at=self.at(minute))], []),
            "a lane-place box with markers": ([self.box("BLOCK", sha, minute)], []),
            "a lane-place box without markers": ([self.box("BLOCK", sha, minute, marker=False)], []),
            "a change request": ([], [review("CHANGES_REQUESTED", at=self.at(minute), oid=sha)]),
        }

    def decide(self, comments, reviews=(), head=None):
        return receipt.decide(pr(comments, reviews, head=head or self.C), head or self.C)

    def refused(self, comments, reviews=(), head=None):
        who, why = self.decide(comments, reviews, head)
        self.assertEqual(who, "", why)
        return why

    def passes(self, comments, reviews=(), head=None):
        who, why = self.decide(comments, reviews, head)
        self.assertNotEqual(who, "", why)
        return who

    def test_ship_then_block_on_the_same_head_then_a_base_merge_refuses_the_carry(self):
        for how, (block, reviews) in self.blocks(self.A, 5).items():
            with self.subTest(how=how):
                # no receipt at C at all
                self.refused([self.ship(self.A, 1), *block], reviews)
                # a lane's carried SHIP at C, posted after the BLOCK, refuses too, and says why
                why = self.refused([self.ship(self.A, 1), *block, self.carried(self.C, self.A, 9)], reviews)
                self.assertRegex(why, r"newest (?:independent verdict is a BLOCK|review says wait)")

    def test_ship_then_block_on_a_later_head_then_a_base_merge_refuses_the_carry(self):
        for how, (block, reviews) in self.blocks(self.B, 5).items():
            with self.subTest(how=how):
                # C off B: the lane carries B's history to C
                self.refused([self.ship(self.A, 1), *block, self.carried(self.C, self.B, 9)], reviews)
                # C off A again, B dropped from the chain: the carry claims A, but the newer BLOCK on B still decides
                self.refused([self.ship(self.A, 1), *block, self.carried(self.C, self.A, 9)], reviews)

    def test_a_ship_older_than_a_block_on_another_head_refuses(self):
        # An independent SHIP that names the head is overtaken by a newer independent BLOCK on any head of the PR.
        for how, (block, reviews) in self.blocks(self.A, 5).items():
            with self.subTest(how=how):
                self.refused([self.ship(self.C, 1), *block], reviews)

    def test_a_carried_ship_does_not_clear_a_hold_or_a_bare_block(self):
        # A carried SHIP is not a review, so it does not become the newest review-like word either.
        for line in ("Hold: do not merge until #1 lands", f"BLOCK at {self.A[:12]}", "Verdict: BLOCK"):
            with self.subTest(line=line):
                self.refused([self.ship(self.A, 1), comment(line, at=self.at(5)), self.carried(self.C, self.A, 9)])

    def test_a_clean_carry_with_no_block_passes(self):
        self.assertIn("carried", self.passes([self.ship(self.A, 1), self.carried(self.C, self.A, 9)]))
        self.passes([self.box("SHIP", self.A, 1), self.carried(self.C, self.A, 9)])
        self.passes([self.carried(self.C, self.A, 9)], [review("APPROVED", at=self.at(1), oid=self.A)])

    def test_a_ship_whose_text_says_carries_is_a_review(self):
        """cmux#27632 (2026-10-29): "Review (independent review subagent): SHIP at <head>. ... the warning carries the
        whole finding." is an independent SHIP; the word marks a carried receipt only in the reviewer label, or as
        "carried from" / "carried over" on the line."""
        line = (f"Review (independent review subagent): SHIP at {self.C}. Both are fixed: the warning carries the "
                "whole finding.")
        self.passes([comment(line, at=self.at(3))])
        self.assertIsNone(receipt.CARRIED.search(line))
        for first in (f"Review (codex gpt-6-astra high; carried): SHIP at {self.C}",
                      f"Review (codex gpt-6-astra high fast, independent box review-26809-7554; carried): SHIP at {self.C}",
                      f"Review (Astra; carried): SHIP at {self.C}", f"Review (Astra, carries): SHIP at {self.C}",
                      f"Review (codex): SHIP at {self.C} (carried from {self.A[:8]})",
                      f"Review (codex): SHIP at {self.C}; the SHIP at {self.A[:8]} is carried over the base merge",
                      f"REVIEW (codex): SHIP at {self.C}, Carried From {self.A[:8]}"):
            with self.subTest(first=first):
                self.assertTrue(receipt.CARRIED.search(first))
                self.refused([comment(first, at=self.at(3))])  # a carried SHIP alone never passes
        for first in (f"Review (subagent): SHIP at {self.C}; the fix carries over to the iOS lane",
                      f"Review (subagent): SHIP at {self.C}, the change carried the old test along"):
            with self.subTest(first=first):
                self.assertIsNone(receipt.CARRIED.search(first))
                self.passes([comment(first, at=self.at(3))])

    def test_a_carried_ship_needs_an_independent_ship_behind_it(self):
        self.refused([self.carried(self.C, self.A, 9)])

    def test_a_new_independent_review_after_the_block_decides(self):
        block, _ = self.blocks(self.A, 5)["a receipt line"]
        base = [self.ship(self.A, 1), *block, self.carried(self.C, self.A, 7)]
        # a SHIP at C itself lands, in either form
        self.passes([*base, self.ship(self.C, 9)])
        self.passes([*base, self.box("SHIP", self.C, 9)])
        # its BLOCK holds
        self.refused([*base, self.box("BLOCK", self.C, 9)])
        # an independent SHIP newer than the BLOCK (the owner's fix, re-reviewed at A, then merged) carries again
        self.passes([self.ship(self.A, 1), *block, self.ship(self.A, 7), self.carried(self.C, self.A, 9)])
        # but a carried SHIP is never the newest independent verdict, so it never clears the BLOCK itself
        self.refused([self.ship(self.A, 1), *block, self.carried(self.A, self.A, 7), self.carried(self.C, self.A, 9)])

    def test_a_ship_on_another_head_cannot_hide_a_newer_block_of_the_heads_ship(self):
        self.refused([self.ship(self.C, 1),
                      comment(f"Review (codex): BLOCK at {self.B}", at=self.at(5)),
                      self.ship(self.A, 9)])

    def test_a_full_window_cannot_hide_a_prior_target_head_verdict_from_a_carry(self):
        # An omitted CHANGES_REQUESTED on C at t1 would refuse the carry. Neutral
        # visible reviews older than the SHIP do not prove that it never existed.
        neutral_reviews = [review("COMMENTED", at=self.at(i), oid=self.B) for i in range(10, 40)]
        self.refused([self.ship(self.A, 20), self.carried(self.C, self.A, 40)], neutral_reviews)
        # The same ambiguity exists when the full comments window hides C's BLOCK.
        neutral_comments = [comment("progress", at=self.at(i)) for i in range(10, 49)]
        self.refused([*neutral_comments, self.carried(self.C, self.A, 49)],
                     [review("APPROVED", at=self.at(20), oid=self.A)])

    def test_the_command_names_the_block_that_refused(self):
        # The marker's comment starts "Findings.", no review-like word, so the newest independent verdict decides it.
        block, _ = self.blocks(self.A, 5)["the autoreview marker"]
        payload = pr([self.ship(self.A, 1), *block, self.carried(self.C, self.A, 9)], head=self.C)
        with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
            json.dump(payload, handle)
            handle.flush()
            err = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                status = receipt.main(["manaflow-ai/cmux", "42", self.C, "--pr-file", handle.name])
        self.assertEqual(status, 1)
        self.assertIn("the newest independent verdict is a BLOCK (autoreview BLOCK by teamleaderleo)", err.getvalue())


class RiskHighExactHead(unittest.TestCase):
    """cmux-ad, 2026-10-30, decision 788: a risk:high pull request needs a receipt on the exact head; no carried SHIP
    (a lane's or next-review's carry across a base merge) counts for it. risk:normal and risk:low keep the carry."""
    REVIEWED = "ab" * 20

    def carried(self, line):
        return pr([comment(f"Review (subagent, correctness first): SHIP at {self.REVIEWED}", at="2026-10-21T05:00:00Z"),
                   comment(line, at="2026-10-21T06:00:00Z")], labels=self.labels)

    def test_a_carried_ship_never_clears_risk_high(self):
        for line in (f"Review (next-review patch-id; carried): SHIP at {HEAD}",
                     f"Review (subagent): SHIP at {HEAD} (carried from {self.REVIEWED[:12]})"):
            for labels, passes in ((("risk:high",), False), (("RISK:HIGH", "ready-to-land"), False),
                                   (("risk:normal",), True), (("risk:low",), True), ((), True)):
                with self.subTest(line=line, labels=labels):
                    self.labels = labels
                    who, why = receipt.decide(self.carried(line), HEAD)
                    self.assertEqual(bool(who), passes, why)
                    if not passes:
                        self.assertIn("risk:high needs an independent review of this exact head", why)

    def test_an_own_ship_on_the_exact_head_clears_risk_high(self):
        who, why = receipt.decide(pr([comment(SHIP)], labels=("risk:high",)), HEAD)
        self.assertIn("SHIP", who, why)
        self.assertIn("approved", receipt.decide(pr(reviews=[review("APPROVED")], labels=("risk:high",)), HEAD)[0])
        # A newer BLOCK on another head still takes it back.
        block = comment(f"Review (subagent): BLOCK at {OTHER}", at="2026-10-21T07:00:00Z")
        self.assertEqual(receipt.decide(pr([comment(SHIP), block], labels=("risk:high",)), HEAD)[0], "")


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
        for field in ("__typename", "authorAssociation", "commit{oid}", "reviews(last:30)", "comments(last:40)",
                      "labels(first:100){nodes{name}}"):
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
