#!/usr/bin/env python3
"""iPhone YOLO builds: scripts/ci/ios_internal_yolo.py stacks PRs onto feat-cmux-next for cmux INTERNAL."""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_internal_yolo", ROOT / "scripts/ci/ios_internal_yolo.py")
yolo = importlib.util.module_from_spec(SPEC)
sys.modules["ios_internal_yolo"] = yolo  # its dataclasses look their module up
SPEC.loader.exec_module(yolo)
NOTES_SPEC = importlib.util.spec_from_file_location("ios_internal_notes", ROOT / "scripts/ci/ios_internal_notes.py")
notes = importlib.util.module_from_spec(NOTES_SPEC)
sys.modules["ios_internal_notes"] = notes
NOTES_SPEC.loader.exec_module(notes)

UTC = dt.timezone.utc
NOW = dt.datetime(2026, 11, 23, 10, 30, tzinfo=UTC)


def pr(number, **kw):
    return yolo.PullRequest(number=number, title=f"PR {number}", sha=kw.pop("sha", "0" * 40), **kw)


class ChooseTests(unittest.TestCase):
    def test_parses_a_typed_list(self):
        self.assertEqual(yolo.parse_numbers("#12, 34 56 12"), [12, 34, 56])
        with self.assertRaises(ValueError):
            yolo.parse_numbers("12 main")

    def test_stacks_open_same_repo_prs_in_number_order(self):
        take, refused = yolo.choose([pr(9), pr(3), pr(5, cross_repo=True), pr(7, state="MERGED")])
        self.assertEqual([p.number for p in take], [3, 9])
        self.assertEqual({p.number: why for p, why in refused},
                         {5: "is from a fork; a YOLO build signs only this repository's branches", 7: "is merged"})

    def test_caps_the_stack(self):
        take, refused = yolo.choose([pr(n) for n in range(1, yolo.MAX_PRS + 3)])
        self.assertEqual(len(take), yolo.MAX_PRS)
        self.assertEqual([p.number for p, _ in refused], [yolo.MAX_PRS + 1, yolo.MAX_PRS + 2])


class BranchTests(unittest.TestCase):
    def test_branch_is_a_utc_stamp_the_nightly_plan_reads(self):
        name = yolo.branch_name(NOW)
        self.assertEqual(name, "ios-yolo/20261123T103000Z")
        builder = importlib.util.spec_from_file_location("ib", ROOT / "scripts/ci/ios_internal_builder.py")
        self.assertTrue(name.startswith(Path(builder.origin).read_text().split('YOLO_PREFIX = "')[1].split('"')[0]))

    def test_prunes_only_its_own_old_branches(self):
        self.assertTrue(yolo.expired("refs/heads/ios-yolo/20261101T000000Z", NOW))
        self.assertFalse(yolo.expired("refs/heads/ios-yolo/20261120T000000Z", NOW))
        self.assertFalse(yolo.expired("refs/heads/ios-yolo/keep-me", NOW))
        self.assertFalse(yolo.expired("refs/heads/feat-cmux-next", NOW))


class StackTests(unittest.TestCase):
    """A real clone: two PRs stack, a conflicting one is left out, and the note names what went in."""

    def git(self, *args, cwd=None):
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd or self.repo,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, files, message):
        for path, text in files.items():
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / path).write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "feat-cmux-next")
        self.base = self.commit({"cmux-next-ios/a.swift": "a\n", "cmux-next-ios/b.swift": "b\n"}, "base")
        self.git("checkout", "-q", "-b", "one", self.base)
        self.one = self.commit({"cmux-next-ios/a.swift": "a1\n"}, "one")
        self.git("checkout", "-q", "-b", "two", self.base)
        self.two = self.commit({"cmux-next-ios/b.swift": "b2\n"}, "two")
        self.git("checkout", "-q", "-b", "three", self.base)
        self.three = self.commit({"cmux-next-ios/a.swift": "a3\n"}, "three")
        self.git("checkout", "-q", "feat-cmux-next")
        self.cwd = os.getcwd()
        os.chdir(self.repo)
        os.environ["GIT_AUTHOR_NAME"] = os.environ["GIT_COMMITTER_NAME"] = "t"
        os.environ["GIT_AUTHOR_EMAIL"] = os.environ["GIT_COMMITTER_EMAIL"] = "t@t"

    def tearDown(self):
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def test_stacks_in_order_and_leaves_out_a_conflict(self):
        stack = yolo.build_stack(self.base, [pr(1, sha=self.one), pr(2, sha=self.two), pr(3, sha=self.three)])
        self.assertEqual([p.number for p in stack.included], [1, 2])
        self.assertEqual([p.number for p, _ in stack.dropped], [3])
        self.assertIn("cmux-next-ios/a.swift", stack.dropped[0][1])
        self.assertEqual(self.git("show", f"{stack.head}:cmux-next-ios/a.swift"), "a1")
        self.assertEqual(self.git("show", f"{stack.head}:cmux-next-ios/b.swift"), "b2")
        self.assertEqual(self.git("status", "--porcelain"), "")
        subjects = self.git("log", "--first-parent", "--merges", "--reverse", "--format=%s",
                            f"{self.base}..{stack.head}").splitlines()
        # The INTERNAL builder's note reads these subjects for its first line.
        self.assertEqual(notes.yolo_prs(subjects), [1, 2])

    def test_summary_names_the_stack_and_what_was_left_out(self):
        stack = yolo.build_stack(self.base, [pr(1, sha=self.one), pr(3, sha=self.three), pr(2, sha=self.two)])
        text = yolo.summary(stack, "ios-yolo/x", True, [(pr(5), "is from a fork")])
        self.assertIn(f"`feat-cmux-next` {self.base[:12]} + #1 #2", text)
        self.assertIn("- left out #3: conflicts", text)
        self.assertIn("- left out #5: is from a fork", text)
        self.assertIn("Dispatched to cmux INTERNAL", text)


if __name__ == "__main__":
    unittest.main()
