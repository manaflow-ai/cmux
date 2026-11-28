#!/usr/bin/env python3
"""Tests for digest.py: highlight files added in a range become a valid nightly digest.

  python3 scripts/whats-new/test_digest.py
"""
import os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import digest, validate  # noqa: E402


def run(cwd, *args):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class DigestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        run(self.repo, "git", "init", "-q")
        run(self.repo, "git", "config", "user.email", "test@example.com")
        run(self.repo, "git", "config", "user.name", "Test")
        self.commit("README", "base\n")
        self.base = run(self.repo, "git", "rev-parse", "HEAD")
        self.cwd = os.getcwd()
        os.chdir(self.repo)

    def tearDown(self):
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def commit(self, path, text):
        full = os.path.join(self.repo, path)
        os.makedirs(os.path.dirname(full) or self.repo, exist_ok=True)
        with open(full, "w") as f:
            f.write(text)
        run(self.repo, "git", "add", path)
        run(self.repo, "git", "commit", "-q", "-m", f"add {path}")
        return run(self.repo, "git", "rev-parse", "HEAD")

    def test_highlights_in_the_range_become_entries(self):
        self.commit("release-notes/next/highlights/fix-scroll.md",
                    "title: Smoother scrolling\ncategory: fixed\ndocs: https://cmux.com/docs\n\nLong lists no longer stutter.\n")
        head = self.commit("release-notes/next/highlights/whats-new-page.md",
                           "title: See what changed\naction: updates.whatsNew | Try it\n\nA page lists what is new.\n")
        document = digest.build("1.0.0-nightly.9", "2026-10-07", head, self.base)
        self.assertEqual([e["id"] for e in document["entries"]], ["whats-new-page", "fix-scroll"])
        self.assertEqual(document["entries"][0]["tryIt"], {"action": "updates.whatsNew"})
        self.assertEqual(document["headline"]["en"], "See what changed, and 1 more")
        self.assertEqual(validate.validate_document("1.0.0-nightly.9.json", document), [])

    def test_a_bad_highlight_is_skipped_not_the_whole_digest(self):
        self.commit("release-notes/next/highlights/good.md", "title: Good\ndocs: https://cmux.com/docs\n\nIt works.\n")
        self.commit("release-notes/next/highlights/no-link.md", "title: No link\n\nNothing to try.\n")
        head = self.commit("release-notes/next/highlights/no-title.md", "category: new\n\nNo title line.\n")
        reports = []
        document = digest.build("1.0.0-nightly.12", "2026-10-07", head, self.base, report=reports.append)
        self.assertEqual([e["id"] for e in document["entries"]], ["good"])
        self.assertEqual(len(reports), 2)
        self.assertEqual(validate.validate_document("1.0.0-nightly.12.json", document), [])

    def test_a_range_without_highlights_has_no_entries(self):
        head = self.commit("src/code.txt", "x\n")
        document = digest.build("1.0.0-nightly.10", "2026-10-07", head, self.base)
        self.assertEqual(document["entries"], [])
        self.assertEqual(validate.validate_document("1.0.0-nightly.10.json", document), [])

    def test_highlights_from_before_the_range_are_not_repeated(self):
        old = self.commit("release-notes/next/highlights/old.md", "title: Old\ndocs: https://cmux.com\n\nOld news.\n")
        head = self.commit("src/code.txt", "x\n")
        document = digest.build("1.0.0-nightly.11", "2026-10-07", head, old)
        self.assertEqual(document["entries"], [])

    def test_the_repository_highlights_validate(self):
        root = os.path.dirname(os.path.dirname(HERE))
        folder = os.path.join(root, digest.HIGHLIGHTS)
        if not os.path.isdir(folder):
            self.skipTest("no highlight files in this checkout")
        entries = []
        for name in sorted(os.listdir(folder)):
            if name.endswith(".md"):
                with open(os.path.join(folder, name), encoding="utf-8") as f:
                    entries.append(digest.parse(name, f.read()))
        document = {"schemaVersion": 1, "version": "1.0.0-nightly.1", "channel": "nightly", "date": "2026-10-07",
                    "headline": {"en": digest.headline(entries)}, "entries": entries}
        self.assertEqual(validate.validate_document("1.0.0-nightly.1.json", document), [])


if __name__ == "__main__":
    unittest.main()
