#!/usr/bin/env python3
"""scripts/live-code/patch.py's from_tree: the build's file list read from a PR's tree (try-pr --live-code).

A fleet step's DerivedData sits inside its checkout (wsrc/.build/...), so Xcode's generated sources
(DerivedSources/resource_bundle_accessor.swift) are under the checkout root but in no commit. They come
from the build; a tracked file comes from the tree; a file the tree deleted still needs a rebuild.
"""
import importlib.util
import os
import subprocess
import tempfile
import unittest

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
spec = importlib.util.spec_from_file_location("patch", os.path.join(ROOT, "scripts", "live-code", "patch.py"))
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)

VIEW = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/HomeHostView.swift"
GONE = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Gone.swift"
DERIVED = ".build/DerivedData/x/CmuxNextApp.build/DerivedSources/resource_bundle_accessor.swift"


def write(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class FromTreeTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.build, self.tree = os.path.join(tmp.name, "build"), os.path.join(tmp.name, "tree")
        for rel in (VIEW, GONE, DERIVED):
            write(os.path.join(self.build, rel))
        os.makedirs(self.tree)
        subprocess.run(["git", "init", "-q", self.tree], check=True)
        write(os.path.join(self.tree, ".gitignore"), ".build/\n")
        write(os.path.join(self.tree, VIEW), "edited")

    def test_a_generated_source_comes_from_the_build(self):
        files = [os.path.join(self.build, VIEW), os.path.join(self.build, DERIVED)]
        self.assertEqual(patch.from_tree(files, self.tree, self.build),
                         [os.path.join(self.tree, VIEW), os.path.join(self.build, DERIVED)])

    def test_a_file_the_tree_deleted_still_needs_a_rebuild(self):
        files = [os.path.join(self.build, VIEW), os.path.join(self.build, GONE)]
        with self.assertRaises(SystemExit) as raised:
            patch.from_tree(files, self.tree, self.build)
        self.assertIn("a deleted file needs a rebuild", str(raised.exception))
        self.assertIn(GONE, str(raised.exception))


if __name__ == "__main__":
    unittest.main()
