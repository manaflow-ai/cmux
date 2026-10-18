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


def days_ago(n):
    return (NOW - dt.timedelta(days=n)).isoformat().replace("+00:00", "Z")


def pr(number=1, *, idle=30, base="main", labels=(), title="cmux-next: tidy", body="", comments=(), reviews=(), review_requests=()):
    return {
        "number": number, "title": title, "body": body, "isDraft": False, "baseRefName": base, "headRefName": "x",
        "createdAt": days_ago(idle + 5),
        "labels": {"nodes": [{"name": name} for name in labels]},
        "reviewRequests": {"nodes": [{"requestedReviewer": {"login": who}} for who in review_requests]},
        "commits": {"nodes": [{"commit": {"committedDate": days_ago(idle)}}]},
        "comments": {"nodes": [{"author": {"login": who}, "createdAt": days_ago(age), "body": text} for who, age, text in comments]},
        "reviews": {"nodes": [{"author": {"login": who}, "submittedAt": days_ago(age)} for who, age in reviews]},
    }


def classify(p, *, landed=None, successor=None):
    return module.classify(p, now=NOW, landed=landed, successor=successor, stale_days=14, landed_idle_days=3)


class ClassifyTests(unittest.TestCase):
    def test_landed_and_idle_closes(self):
        v = classify(pr(idle=4), landed=True)
        self.assertEqual((v.action, v.reason), ("close", "landed"))

    def test_landed_but_recently_touched_is_kept(self):
        self.assertEqual(classify(pr(idle=1), landed=True).action, "keep")

    def test_superseded_and_landed_closes_and_names_successor(self):
        v = classify(pr(idle=5), landed=True, successor=99)
        self.assertEqual((v.action, v.reason, v.successor), ("close", "superseded", 99))
        self.assertIn("#99", module.close_comment(v, "main"))

    def test_superseded_but_not_landed_is_only_listed(self):
        v = classify(pr(idle=5), landed=False, successor=99)
        self.assertEqual((v.action, v.reason, v.successor), ("list", "superseded", 99))

    def test_stale_without_landing_is_only_listed(self):
        v = classify(pr(idle=20), landed=False)
        self.assertEqual((v.action, v.reason), ("list", "stale"))

    def test_bot_comments_do_not_count_as_activity(self):
        p = pr(idle=20, comments=[("coderabbitai", 0, "Review skipped"), ("github-actions[bot]", 1, "receipt")])
        self.assertEqual(classify(p).action, "list")

    def test_human_comment_counts_as_activity(self):
        p = pr(idle=20, comments=[("lawrencecchen", 2, "looking at this")])
        self.assertEqual(classify(p).action, "keep")

    def test_skips(self):
        cases = {
            "label keep-open": pr(labels=("keep-open",)),
            "stacked on claude/base": pr(base="claude/base"),
            "security": pr(title="fix: security hole in relay"),
            "review requested": pr(review_requests=("lawrencecchen",)),
            "waiting on @lawrencecchen": pr(body="Waiting on @lawrencecchen for the API shape."),
        }
        for reason, p in cases.items():
            with self.subTest(reason=reason):
                v = classify(p, landed=True)
                self.assertEqual((v.action, v.reason), ("skip", reason))


class LandedTests(unittest.TestCase):
    def test_all_added_lines_on_base(self):
        files = [{"filename": "a.py", "status": "modified", "patch": "@@ -1 +1,2 @@\n x = 1\n+value = compute()\n+\n"}]
        self.assertTrue(module.added_lines_landed(files, {"a.py": "x = 1\n    value = compute()\n"}))

    def test_missing_line_is_not_landed(self):
        files = [{"filename": "a.py", "status": "modified", "patch": "+value = compute()\n+other = thing()\n"}]
        self.assertFalse(module.added_lines_landed(files, {"a.py": "value = compute()\n"}))

    def test_unreadable_or_trivial_diffs_are_kept(self):
        self.assertFalse(module.added_lines_landed([], {}))
        self.assertFalse(module.added_lines_landed([{"filename": "b.png", "status": "added"}], {"b.png": "x"}))
        self.assertFalse(module.added_lines_landed([{"filename": "a.py", "status": "added", "patch": "+x"}], {}))
        self.assertFalse(module.added_lines_landed([{"filename": "a.py", "status": "modified", "patch": "-old line here\n+}\n"}], {"a.py": "}\n"}))


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
