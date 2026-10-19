"""Which agent PRs the nightly stale-PR job closes, lists or keeps."""
import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stale_agent_prs", ROOT / "scripts/ci/stale_agent_prs.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
NOW = dt.datetime(2026, 10, 19, tzinfo=dt.timezone.utc)


def ago(days=0, hours=0):
    return (NOW - dt.timedelta(days=days, hours=hours)).isoformat().replace("+00:00", "Z")


def pr(number=1, *, idle=30, base="main", labels=(), title="cmux-next: tidy", comments=(), reviews=(), rollup="SUCCESS", mergeable="MERGEABLE"):
    return {
        "number": number, "title": title, "body": "", "isDraft": False, "baseRefName": base, "headRefName": "x",
        "createdAt": ago(idle + 5), "mergeable": mergeable,
        "labels": {"nodes": [{"name": name} for name in labels]},
        "commits": {"nodes": [{"commit": {"committedDate": ago(idle), "statusCheckRollup": {"state": rollup}}}]},
        "comments": {"nodes": [{"author": {"login": who}, "createdAt": when, "body": text} for who, when, text in comments]},
        "reviews": {"nodes": [{"author": {"login": who}, "submittedAt": when} for who, when in reviews]},
    }


LANDED = module.Score(present=10, total=10)
MOSTLY = module.Score(present=95, total=100)
PARTIAL = module.Score(present=50, total=100)


def classify(p, *, score=None, successor=None):
    return module.classify(p, now=NOW, score=score, successor=successor, stale_days=14, landed_idle_days=3)


class ClassifyTests(unittest.TestCase):
    def test_fully_landed_and_idle_closes(self):
        v = classify(pr(idle=4), score=LANDED)
        self.assertEqual((v.action, v.reason), ("close", "landed"))

    def test_landed_but_touched_recently_is_kept_or_skipped(self):
        self.assertEqual(classify(pr(idle=1), score=LANDED).action, "keep")
        p = pr(idle=10, comments=[("teamleaderleo", ago(hours=3), "rebased, rechecking")])
        self.assertEqual(classify(p, score=LANDED).reason, "touched in the last 12 hours")

    def test_mostly_landed_is_listed_for_a_human(self):
        v = classify(pr(idle=4), score=MOSTLY)
        self.assertEqual((v.action, v.reason), ("list", "mostly landed 95%"))

    def test_superseded_alone_is_a_lead_not_a_close(self):
        v = classify(pr(idle=5), score=PARTIAL, successor=99)
        self.assertEqual((v.action, v.reason, v.successor), ("list", "superseded", 99))

    def test_superseded_and_landed_closes_naming_the_successor(self):
        v = classify(pr(idle=5), score=LANDED, successor=99)
        self.assertEqual(v.action, "close")
        comment = module.close_comment(v, "main", "f" * 40)
        self.assertIn("#99", comment)
        self.assertIn("ffffffffff", comment)
        self.assertIn("reopen it or re-cut from `main`", comment)

    def test_stale_needs_red_or_conflicting(self):
        self.assertEqual(classify(pr(idle=20), score=PARTIAL).action, "keep")
        self.assertEqual(classify(pr(idle=20, rollup="FAILURE"), score=PARTIAL).reason, "stale, red or conflicting")
        self.assertEqual(classify(pr(idle=20, mergeable="CONFLICTING"), score=PARTIAL).action, "list")

    def test_bot_comments_do_not_count_as_activity(self):
        p = pr(idle=20, rollup="FAILURE", comments=[("coderabbitai", ago(0), "Review skipped"), ("github-actions[bot]", ago(1), "Bead created")])
        self.assertEqual(classify(p).action, "list")

    def test_skips(self):
        cases = {
            "label keep-open": pr(labels=("keep-open",)),
            "waiting on @lawrencecchen": pr(comments=[("teamleaderleo", ago(6), "@lawrencecchen your call on the API shape.")]),
        }
        for reason, p in cases.items():
            with self.subTest(reason=reason):
                v = classify(p, score=LANDED)
                self.assertEqual((v.action, v.reason), ("skip", reason))

    def test_security_and_stacked_are_listed_never_closed(self):
        for reason, p in {"security": pr(title="fix: ACL check in relay"), "stacked on claude/base": pr(base="claude/base")}.items():
            with self.subTest(reason=reason):
                v = classify(p, score=LANDED)
                self.assertEqual((v.action, v.reason), ("list", reason))


class ScoreTests(unittest.TestCase):
    def test_all_added_lines_on_base_and_removed_lines_gone(self):
        files = [{"filename": "a.py", "status": "modified", "patch": "@@ -1,2 +1,2 @@\n x = 1\n-old_value = legacy()\n+value = compute()\n+\n+import os\n"}]
        result = module.score(files, {"a.py": "x = 1\n    value = compute()\n"})
        self.assertEqual((result.present, result.total), (1, 1))
        self.assertTrue(result.landed)

    def test_removed_line_still_on_base_is_not_landed(self):
        files = [{"filename": "a.py", "status": "modified", "patch": "-old_value = legacy()\n+value = compute()\n"}]
        self.assertFalse(module.score(files, {"a.py": "value = compute()\nold_value = legacy()\n"}).landed)

    def test_share_counts_missing_lines(self):
        files = [{"filename": "a.py", "status": "modified", "patch": "+value = compute()\n+other = thing()\n"}]
        result = module.score(files, {"a.py": "value = compute()\n"})
        self.assertEqual(result.share, 0.5)
        self.assertFalse(result.landed)

    def test_generated_files_comments_and_short_lines_are_not_scored(self):
        files = [
            {"filename": "Resources/Localizable.xcstrings", "status": "modified", "patch": "+\"new key that is not there\""},
            {"filename": "bun.lock", "status": "modified", "patch": "+\"pkg@1.2.3\": not on base"},
            {"filename": "a.swift", "status": "modified", "patch": "+// a comment that is not there\n+}\n+let value = compute()\n"},
        ]
        result = module.score(files, {"a.swift": "let value = compute()\n"})
        self.assertEqual((result.present, result.total), (1, 1))
        self.assertTrue(result.landed)

    def test_unreadable_or_empty_diffs_never_close(self):
        self.assertFalse(module.score([], {}).landed)
        self.assertFalse(module.score([{"filename": "b.png", "status": "modified"}], {"b.png": "x"}).landed)
        self.assertFalse(module.score([{"filename": "new.py", "status": "added", "patch": "+value = compute()"}], {}).landed)
        self.assertFalse(module.score([{"filename": "a.py", "status": "modified", "patch": "+}\n"}], {"a.py": "}\n"}).landed)
        self.assertFalse(module.score([{"filename": "gone.py", "status": "removed"}], {"gone.py": "still here"}).landed)


class SuccessorTests(unittest.TestCase):
    def test_explicit_statements_only(self):
        merged = [
            {"number": 200, "body": "Supersedes #101 and #102."},
            {"number": 201, "body": "Re-cut of manaflow-ai/cmux#103"},
            {"number": 202, "body": "replaces other/repo#104"},
            {"number": 203, "body": "Related to #105"},
        ]
        self.assertEqual(module.successors(merged, "manaflow-ai/cmux"), {101: 200, 102: 200, 103: 201})


if __name__ == "__main__":
    unittest.main()
