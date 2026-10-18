#!/usr/bin/env python3
"""scripts/ci/pr_status.py keeps one sectioned status comment per pull request.

Runs upsert against an in-memory fake of the four comment endpoints; nothing reaches GitHub.
"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
import pr_status  # noqa: E402

REPO, PR = "manaflow-ai/cmux", 7


class FakeGitHub:
    def __init__(self):
        self.comments = {}  # id -> {"id", "body", "user"}
        self.next_id = 100
        self.writes = []
        self.on_read = None  # hook: runs before a list, to simulate another writer

    def add(self, body, user=pr_status.BOT):
        self.next_id += 1
        self.comments[self.next_id] = {"id": self.next_id, "body": body, "user": user}
        return self.next_id

    def __call__(self, method, path, payload):
        if method == "GET":
            if self.on_read:
                hook, self.on_read = self.on_read, None
                hook()
            return [{"id": c["id"], "body": c["body"], "user": {"login": c["user"]}}
                    for c in self.comments.values()]
        self.writes.append(method)
        if method == "POST":
            self.add(payload["body"])
        elif method == "PATCH":
            self.comments[int(path.rsplit("/", 1)[1])]["body"] = payload["body"]
        elif method == "DELETE":
            del self.comments[int(path.rsplit("/", 1)[1])]
        return None

    def status(self):
        found = [c for c in self.comments.values() if c["body"].startswith(pr_status.MARKER)]
        assert len(found) == 1, found
        return pr_status.parse(found[0]["body"])


def upsert(gh, key, text, **kw):
    return pr_status.upsert(REPO, PR, key, text, api=gh, sleep=lambda _: None, **kw)


class PrStatusTests(unittest.TestCase):
    def test_a_clean_pull_request_gets_no_comment(self):
        gh = FakeGitHub()
        self.assertEqual(upsert(gh, "checks", None), "unchanged")
        self.assertEqual(gh.comments, {})

    def test_sections_share_one_comment_in_display_order(self):
        gh = FakeGitHub()
        upsert(gh, "receipt", "Merge receipt")
        upsert(gh, "bead", "Bead: `cx-abc1`")
        upsert(gh, "checks", "red: web / lint")
        self.assertEqual(gh.status(), {"bead": "Bead: `cx-abc1`", "checks": "red: web / lint",
                                       "receipt": "Merge receipt"})
        body = next(iter(gh.comments.values()))["body"]
        self.assertLess(body.index("cx-abc1"), body.index("red: web"))
        self.assertLess(body.index("red: web"), body.index("Merge receipt"))
        self.assertEqual(gh.writes, ["POST", "PATCH", "PATCH"])

    def test_clearing_removes_only_that_section_and_an_unchanged_write_is_skipped(self):
        gh = FakeGitHub()
        upsert(gh, "bead", "Bead: `cx-abc1`")
        upsert(gh, "checks", "red: web / lint")
        upsert(gh, "checks", None)
        self.assertEqual(gh.status(), {"bead": "Bead: `cx-abc1`"})
        writes = len(gh.writes)
        self.assertEqual(upsert(gh, "bead", "Bead: `cx-abc1`"), "unchanged")
        self.assertEqual(len(gh.writes), writes)

    def test_a_lost_write_is_written_again(self):
        gh = FakeGitHub()
        cid = gh.add(pr_status.render({"bead": "Bead: `cx-abc1`"}))
        stale = gh.comments[cid]["body"]

        def other_writer_overwrites():
            # Another writer read the comment before ours and writes after it.
            gh.on_read = lambda: gh.comments[cid].update(body=stale)
        upsert_calls = []
        orig = gh.__call__

        def gh_with_race(method, path, payload):
            out = orig(method, path, payload)
            if method == "PATCH" and not upsert_calls:
                upsert_calls.append(1)
                other_writer_overwrites()
            return out
        pr_status.upsert(REPO, PR, "checks", "red: web / lint", api=gh_with_race, sleep=lambda _: None)
        self.assertEqual(gh.status(), {"bead": "Bead: `cx-abc1`", "checks": "red: web / lint"})

    def test_two_status_comments_fold_into_the_oldest(self):
        gh = FakeGitHub()
        first = gh.add(pr_status.render({"bead": "Bead: `cx-abc1`"}))
        gh.add(pr_status.render({"review": "links"}))
        upsert(gh, "checks", "red: web / lint")
        self.assertEqual(list(gh.comments), [first])
        self.assertEqual(gh.status(), {"bead": "Bead: `cx-abc1`", "review": "links", "checks": "red: web / lint"})

    def test_the_legacy_comment_becomes_the_status_comment_and_a_persons_is_kept(self):
        gh = FakeGitHub()
        old = gh.add("<!-- cmux-red-checks -->\nred: web / lint")
        gh.add("<!-- cmux-red-checks -->\nan older duplicate")
        person = gh.add("<!-- cmux-red-checks --> quoted by a person", user="teamleaderleo")
        upsert(gh, "checks", "red: web / lint", legacy="<!-- cmux-red-checks -->")
        self.assertEqual(sorted(gh.comments), [old, person])
        self.assertEqual(gh.writes, ["PATCH", "DELETE"])
        self.assertEqual(pr_status.parse(gh.comments[old]["body"]), {"checks": "red: web / lint"})

    def test_a_marker_at_the_end_of_a_legacy_comment_counts(self):
        gh = FakeGitHub()
        gh.add("**Merge receipt** for `abc`\n<!-- cmux:merge-receipt -->")
        upsert(gh, "receipt", "Merge receipt <!-- cmux:merge-receipt -->", legacy="<!-- cmux:merge-receipt -->")
        self.assertEqual(len(gh.comments), 1)
        self.assertEqual(gh.status(), {"receipt": "Merge receipt <!-- cmux:merge-receipt -->"})

    def test_an_oversized_section_is_cut_to_fit(self):
        body = pr_status.render({"bead": "Bead: `cx-abc1`", "tour": "x" * 90000})
        self.assertLessEqual(len(body), pr_status.LIMIT)
        self.assertEqual(pr_status.parse(body)["bead"], "Bead: `cx-abc1`")
        self.assertIn("cut to fit", pr_status.parse(body)["tour"])

    def test_dispatched_fields_accept_only_valid_values(self):
        self.assertEqual(pr_status.field_text("cx-bi1nt", None), ("bead", "Bead: `cx-bi1nt`"))
        key, text = pr_status.field_text(None, "a" * 40)
        self.assertEqual(key, "preview")
        self.assertIn("`aaaaaaa`", text)
        for bead, preview in (("cx-x`; @everyone", None), ("not-a-bead", None), (None, "abc"), (None, None)):
            with self.assertRaises(ValueError):
                pr_status.field_text(bead, preview)


if __name__ == "__main__":
    unittest.main()
