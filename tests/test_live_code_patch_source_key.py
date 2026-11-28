#!/usr/bin/env python3
"""scripts/live-code/patch.py's source_key: the same edited files give the same key, so the app reuses the
image it already loaded for that code (LiveEngine.apply); any byte, file, target or -O change gives a new one.

    python3 -I tests/test_live_code_patch_source_key.py
"""
import importlib.util
import os
import tempfile
import unittest

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
spec = importlib.util.spec_from_file_location("patch", os.path.join(ROOT, "scripts", "live-code", "patch.py"))
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)

TARGET = "arm64-apple-ios17.0-simulator"


class SourceKeyTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.a = os.path.join(tmp.name, "A.swift")
        self.b = os.path.join(tmp.name, "B.swift")
        self.write(self.a, "let color = 1\n")
        self.write(self.b, "let other = 2\n")

    def write(self, path, text):
        with open(path, "w") as f:
            f.write(text)

    def key(self, modules, target=TARGET, optimize=False):
        return patch.source_key(target, optimize, modules)

    def test_the_same_files_give_the_same_key_in_any_order(self):
        self.assertEqual(self.key({"App": [self.a, self.b]}), self.key({"App": [self.b, self.a]}))

    def test_an_edit_back_to_earlier_code_gives_its_earlier_key(self):
        first = self.key({"App": [self.a]})
        self.write(self.a, "let color = 2\n")
        self.assertNotEqual(self.key({"App": [self.a]}), first)
        self.write(self.a, "let color = 1\n")
        self.assertEqual(self.key({"App": [self.a]}), first)

    def test_files_module_target_and_optimize_each_change_it(self):
        base = self.key({"App": [self.a]})
        self.assertNotEqual(self.key({"App": [self.a, self.b]}), base)
        self.assertNotEqual(self.key({"Kit": [self.a]}), base)
        self.assertNotEqual(self.key({"App": [self.a]}, target="arm64-apple-macos14.0"), base)
        self.assertNotEqual(self.key({"App": [self.a]}, optimize=True), base)


if __name__ == "__main__":
    unittest.main()
