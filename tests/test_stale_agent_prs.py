"""Which agent PRs the nightly stale-PR job closes, lists or keeps."""
import datetime as dt
import importlib.util
import os
import subprocess
import sys
import tempfile
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


LANDED = module.Score(present=10, total=10)  # with applied=True below
MOSTLY = module.Score(present=95, total=100)
PARTIAL = module.Score(present=50, total=100)


def classify(p, *, score=None, successor=None, applied=None):
    if applied is None:
        applied = score is LANDED
    return module.classify(p, now=NOW, score=score, successor=successor, stale_days=14, landed_idle_days=3, applied=applied)


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

    def test_stacked_on_a_live_base_is_left_to_its_base(self):
        v = module.classify(pr(base="claude/base"), now=NOW, score=LANDED, successor=None, stale_days=14, landed_idle_days=3, live_branches={"claude/base"}, applied=True)
        self.assertEqual(v.action, "keep")

    def test_recent_draft_is_left_alone_even_when_landed(self):
        draft = pr(idle=5)
        draft["isDraft"] = True
        self.assertEqual(classify(draft, score=LANDED).action, "keep")

    def test_full_line_share_without_reverse_apply_is_only_listed(self):
        v = classify(pr(idle=5), score=module.Score(present=10, total=10), applied=False)
        self.assertEqual((v.action, v.reason), ("list", "mostly landed 100%"))

    def test_security_drafts_and_dead_stacks_are_listed_never_closed(self):
        draft = pr(idle=20)
        draft["isDraft"] = True
        for reason, p in {"security": pr(title="fix: ACL check in relay"), "stacked on deleted claude/base": pr(base="claude/base"), "stale draft": draft}.items():
            with self.subTest(reason=reason):
                v = classify(p, score=LANDED)
                self.assertEqual((v.action, v.reason), ("list", reason))


class ScoreTests(unittest.TestCase):
    def test_all_added_lines_on_base_and_removed_lines_gone(self):
        files = [{"filename": "a.py", "status": "modified", "patch": "@@ -1,2 +1,2 @@\n x = 1\n-old_value = legacy()\n+value = compute()\n+\n+import os\n"}]
        result = module.score(files, {"a.py": "x = 1\n    value = compute()\n"})
        self.assertEqual((result.present, result.total, result.removed_left), (1, 1, 0))

    def test_removed_line_still_on_base_is_counted(self):
        files = [{"filename": "a.py", "status": "modified", "patch": "-old_value = legacy()\n+value = compute()\n"}]
        self.assertEqual(module.score(files, {"a.py": "value = compute()\nold_value = legacy()\n"}).removed_left, 1)

    def test_share_counts_missing_lines(self):
        files = [{"filename": "a.py", "status": "modified", "patch": "+value = compute()\n+other = thing()\n"}]
        result = module.score(files, {"a.py": "value = compute()\n"})
        self.assertEqual(result.share, 0.5)

    def test_generated_files_comments_and_short_lines_are_not_scored(self):
        files = [
            {"filename": "Resources/Localizable.xcstrings", "status": "modified", "patch": "+\"new key that is not there\""},
            {"filename": "bun.lock", "status": "modified", "patch": "+\"pkg@1.2.3\": not on base"},
            {"filename": "a.swift", "status": "modified", "patch": "+// a comment that is not there\n+}\n+let value = compute()\n"},
        ]
        result = module.score(files, {"a.swift": "let value = compute()\n"})
        self.assertEqual((result.present, result.total), (1, 1))

    def test_patch_text_refuses_what_it_cannot_rebuild_exactly(self):
        self.assertIsNone(module.patch_text([]))
        self.assertIsNone(module.patch_text([{"filename": "b.png", "status": "modified"}]))
        self.assertIsNone(module.patch_text([{"filename": "n.py", "status": "renamed", "previous_filename": "o.py", "patch": "@@ -1 +1 @@\n-a\n+b"}]))
        self.assertIsNone(module.patch_text([{"filename": f"f{i}", "status": "modified", "patch": "@@ -1 +1 @@\n-a\n+b"} for i in range(3000)]))


class ReverseApplyTests(unittest.TestCase):
    """reverse_applies against a real git tree, the check that gates closing."""

    BEFORE = "def a():\n    load()\n    self.refresh()\n\ndef b():\n    load()\n    save()\n"
    # The PR adds self.refresh() to b(); the same line already exists in a().
    PATCH = "@@ -5,3 +5,4 @@\n def b():\n     load()\n+    self.refresh()\n     save()\n"

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        self.git("init", "-q")
        self.cwd = os.getcwd()
        os.chdir(self.dir)

    def tearDown(self):
        os.chdir(self.cwd)

    def git(self, *args):
        return subprocess.run(["git", "-C", self.dir, *args], check=True, capture_output=True, text=True, env=self.env).stdout.strip()

    def base(self, files):
        for name, text in files.items():
            with open(os.path.join(self.dir, name), "w") as handle:
                handle.write(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def applies(self, files):
        return module.reverse_applies(files, "main", os.path.join(self.dir, "scratch-index"))

    def test_line_elsewhere_in_the_file_is_not_landed(self):
        self.base({"m.py": self.BEFORE})
        files = [{"filename": "m.py", "status": "modified", "patch": self.PATCH}]
        self.assertEqual(module.score(files, {"m.py": self.BEFORE}).share, 1.0, "the line-set score is fooled")
        self.assertFalse(self.applies(files), "reverse apply is not")

    def test_hunk_on_the_base_in_context_is_landed(self):
        self.base({"m.py": self.BEFORE.replace("    load()\n    save()", "    load()\n    self.refresh()\n    save()")})
        self.assertTrue(self.applies([{"filename": "m.py", "status": "modified", "patch": self.PATCH}]))

    def test_added_and_removed_files(self):
        self.base({"new.py": "x = 1\n"})
        self.assertTrue(self.applies([{"filename": "new.py", "status": "added", "patch": "@@ -0,0 +1 @@\n+x = 1"}]))
        self.assertFalse(self.applies([{"filename": "new.py", "status": "removed", "patch": "@@ -1 +0,0 @@\n-x = 1"}]))
        self.assertTrue(self.applies([{"filename": "gone.py", "status": "removed", "patch": "@@ -1 +0,0 @@\n-y = 2"}]))

    def test_generated_file_differences_block_closing(self):
        self.base({"m.py": "a = 1\n", "L.xcstrings": "{}\n"})
        files = [
            {"filename": "m.py", "status": "modified", "patch": "@@ -1 +1 @@\n-a = 0\n+a = 1"},
            {"filename": "L.xcstrings", "status": "modified", "patch": "@@ -1 +1 @@\n-{}\n+{\"k\": 1}"},
        ]
        self.assertFalse(self.applies(files))


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
