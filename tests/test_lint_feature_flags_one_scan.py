#!/usr/bin/env python3
"""The flag linter searches the tree once, not once per flag (#53771).

grep_key_files ran a whole-repository `git grep` inside the per-flag loop, so
19 flags and 3 retired keys spawned 23 searches (6.9 s to 12.3 s) where one
takes about half a second. The cost must not grow with the number of flags.
"""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
from unittest import mock
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
LINTER = REPO_ROOT / "scripts" / "lint-feature-flags.py"


def load_linter():
    spec = importlib.util.spec_from_file_location("lint_feature_flags_one_scan", LINTER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def grep_calls(run):
    return [c for c in run.call_args_list if "grep" in (c.args[0] if c.args else c.kwargs.get("args", []))]


class FlagLinterOneScanTests(unittest.TestCase):
    def setUp(self):
        self.linter = load_linter()

    def test_one_search_for_every_flag_and_retired_key(self):
        real = subprocess.run
        self.linter.errors.clear()
        with mock.patch.object(self.linter.subprocess, "run", side_effect=real) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            self.linter.main(["--today", "2026-06-01", "--base", "HEAD"])
        flags, _ = self.linter.collect_flags()
        self.assertGreater(len(flags), 1)
        # The registry discovery is one search whatever the flag count; the key searches must be one too.
        key_searches = [c for c in grep_calls(run) if self.linter.FLAG_DECLARATION not in c.args[0]]
        self.assertEqual(len(key_searches), 1)

    def test_files_per_key_match_a_search_per_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            (root / "web").mkdir()
            (root / "Packages").mkdir()
            (root / "web" / "a.ts").write_text('flag("alpha-release")\n')
            (root / "Packages" / "b.swift").write_text('"alpha-release" "alpha-release-two"\n')
            (root / "Packages" / "c.swift").write_text("nothing here\n")
            with mock.patch.object(self.linter, "REPO", root):
                keys = ["alpha-release", "alpha-release-two", "missing-release"]
                found = self.linter.key_files(keys)
                for key in keys:
                    self.assertEqual(found.get(key, set()), self.linter.grep_key_files(key), key)
            self.assertEqual(found["alpha-release"], {"web/a.ts", "Packages/b.swift"})
            self.assertEqual(found["alpha-release-two"], {"Packages/b.swift"})


if __name__ == "__main__":
    unittest.main()
