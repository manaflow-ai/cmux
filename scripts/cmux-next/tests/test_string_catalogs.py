#!/usr/bin/env python3
"""scripts/cmux-next/string_catalogs.py: string tables kept as one file per key.

Two pull requests that each add a string to one table add two files and merge with no conflict (the replay of
2026-11-25 measured 115 conflicts in 14 days on the three busiest catalogs as single files, 5 as one file per key).
A table builds into the same catalog it was split from and splits back with no change, and the real tree's tables
are one file per key with no table committed beside them.

  python3 -I scripts/cmux-next/tests/test_string_catalogs.py
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("string_catalogs", ROOT / "scripts/cmux-next/string_catalogs.py")
sc = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(sc)

TABLES = [
    "webviews/src/agent-session/acpmux/Localizable.xcstrings.d",
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings.d",
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettingsWindow/Localizable.xcstrings.d",
]


def entry(text: str) -> dict:
    return {"extractionState": "manual", "localizations": {"en": {"stringUnit": {"state": "translated", "value": text}}}}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class Layout(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="string-catalogs-")
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def table(self) -> dict:
        return {"sourceLanguage": "en", "strings": {"a.one": entry("One"), "b.two": entry("Two")}, "version": "1.0"}

    def test_split_then_build_is_the_same_table_and_splitting_again_changes_nothing(self):
        catalog = self.dir / "T.xcstrings"
        catalog.write_text(sc.dumps(self.table()), encoding="utf-8")
        directory = self.dir / "T.xcstrings.d"
        self.assertEqual(sc.split(catalog, directory), (2, 0))
        out = self.dir / "out" / "T.xcstrings"
        sc.build(directory, out)
        self.assertEqual(json.loads(out.read_text(encoding="utf-8")), self.table())
        self.assertEqual(sc.split(out, directory, prune=True), (0, 0))

    def test_split_prune_deletes_a_key_the_catalog_dropped(self):
        directory = self.dir / "T.xcstrings.d"
        catalog = self.dir / "T.xcstrings"
        catalog.write_text(sc.dumps(self.table()), encoding="utf-8")
        sc.split(catalog, directory)
        smaller = self.table()
        del smaller["strings"]["b.two"]
        catalog.write_text(sc.dumps(smaller), encoding="utf-8")
        self.assertEqual(sc.split(catalog, directory, prune=True), (0, 1))
        self.assertEqual(sorted(p.name for p in directory.iterdir()), ["a.one.xcstrings"])

    def test_check_refuses_a_misnamed_file_a_case_collision_and_a_generated_looking_key(self):
        directory = self.dir / "T.xcstrings.d"
        directory.mkdir()
        (directory / "a.one.xcstrings").write_text(sc.entry_text("a.two", entry("x")), encoding="utf-8")
        (directory / "b.xcstrings").write_text(sc.entry_text("b", entry("x")), encoding="utf-8")
        (directory / "B.xcstrings").write_text(sc.entry_text("B", entry("x")), encoding="utf-8")
        errors = sc.check([directory], self.dir)
        self.assertTrue(any("its name must be a.two.xcstrings" in e for e in errors), errors)
        if len(list(directory.iterdir())) == 3:  # a case-sensitive file system (Linux CI) holds both b and B
            self.assertTrue(any("differ only in case" in e for e in errors), errors)
        with self.assertRaises(ValueError):
            sc.entry_file(directory, "kind.generated")

    def test_two_branches_that_each_add_a_key_merge_with_no_conflict(self):
        repo = self.dir / "repo"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        directory = repo / "T.xcstrings.d"
        catalog = self.dir / "T.xcstrings"
        catalog.write_text(sc.dumps(self.table()), encoding="utf-8")
        sc.split(catalog, directory)
        git(repo, "add", ".")
        git(repo, "commit", "-qm", "base")
        for branch, key in (("left", "c.left"), ("right", "c.right")):
            git(repo, "checkout", "-q", "-b", branch, "main")
            sc.write_if_changed(sc.entry_file(directory, key), sc.entry_text(key, entry(key)))
            git(repo, "add", ".")
            git(repo, "commit", "-qm", key)
        merged = subprocess.run(["git", "-C", str(repo), "merge-tree", "--write-tree", "left", "right"],
                                capture_output=True, text=True)
        self.assertEqual(merged.returncode, 0, merged.stdout)
        names = git(repo, "ls-tree", "--name-only", merged.stdout.split()[0], "T.xcstrings.d/").splitlines()
        self.assertEqual(sorted(Path(n).name for n in names),
                         ["a.one.xcstrings", "b.two.xcstrings", "c.left.xcstrings", "c.right.xcstrings"])


class RealTree(unittest.TestCase):
    def test_every_table_directory_is_one_file_per_key_and_no_table_is_committed(self):
        dirs = sc.directories(ROOT)
        for table in TABLES:
            self.assertIn(ROOT / table, dirs)
        self.assertEqual(sc.check(dirs, ROOT), [])

    def test_xcstrings_edit_adds_to_a_directory_named_by_its_old_table_path(self):
        with tempfile.TemporaryDirectory(prefix="string-catalogs-edit-") as tmp:
            directory = Path(tmp) / "T.xcstrings.d"
            directory.mkdir()
            sc.write_if_changed(sc.entry_file(directory, "a"), sc.entry_text("a", entry("A")))
            edit = [sys.executable, "-I", str(ROOT / "scripts/xcstrings-edit.py")]
            subprocess.run([*edit, "add", str(Path(tmp) / "T.xcstrings"), "b.new", "--en", "B"], check=True,
                           capture_output=True)
            self.assertEqual(sc.load(directory)["strings"]["b.new"], entry("B"))
            again = subprocess.run([*edit, "add", str(directory), "b.new", "--en", "B"], capture_output=True)
            self.assertEqual(again.returncode, 1)
            subprocess.run([*edit, "remove", str(directory), "b.new"], check=True, capture_output=True)
            self.assertEqual(sorted(sc.load(directory)["strings"]), ["a"])


if __name__ == "__main__":
    unittest.main()
