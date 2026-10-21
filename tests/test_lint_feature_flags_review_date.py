#!/usr/bin/env python3
"""A lapsed reviewBy date fails only the change that touches that flag.

The zombie-flag guard used to fail whenever reviewBy < today, so a calendar
date turned main and every open PR red with no code change (2026-10-19:
conversation-sidebar-release). A past date now warns everywhere and fails only
when the diff edits that flag's own declaration. Missing or malformed dates
still fail unconditionally.
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

EXPIRED = (
    "// FLAG(key: expired-thing-release, owner: someone,\n"
    "//      reviewBy: 2020-01-01, defaultWhenUnavailable: false)\n"
)
CURRENT = (
    "// FLAG(key: current-thing-release, owner: someone,\n"
    "//      reviewBy: 2099-01-01, defaultWhenUnavailable: false)\n"
)


def load_linter():
    spec = importlib.util.spec_from_file_location("lint_feature_flags", LINTER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(root, *args):
    return subprocess.run(
        ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t",
         "-c", "commit.gpgsign=false", *args],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


class ReviewDateScopeTests(unittest.TestCase):
    def setUp(self):
        self.linter = load_linter()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        git(self.root, "init", "-q")
        self.registry = self.root / "Example.swift"

    def tearDown(self):
        self.temp.cleanup()

    def commit_base(self, text):
        self.registry.write_text(text)
        (self.root / "Other.swift").write_text("let x = 1\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "base")
        return git(self.root, "rev-parse", "HEAD")

    def run_lint(self, *argv):
        self.linter.errors.clear()
        out = io.StringIO()
        with mock.patch.object(self.linter, "REPO", self.root), \
             mock.patch.object(self.linter, "WEB_REGISTRY", self.root / "missing.ts"), \
             mock.patch.object(self.linter, "swift_registry_files", return_value=["Example.swift"]), \
             mock.patch.object(self.linter, "grep_key_files", return_value=set()), \
             contextlib.redirect_stdout(out):
            status = self.linter.main(list(argv))
        return status, out.getvalue()

    def test_expired_flag_in_untouched_file_warns_and_passes(self):
        base = self.commit_base(EXPIRED + CURRENT)
        (self.root / "Other.swift").write_text("let x = 2\n")
        status, output = self.run_lint("--base", base)
        self.assertEqual(status, 0, output)
        self.assertIn("warning", output.lower())
        self.assertIn("expired-thing-release", output)

    def test_expired_flag_beside_an_edited_flag_warns_and_passes(self):
        """Editing a neighbouring declaration does not adopt the expired one."""
        base = self.commit_base(EXPIRED + "\n" + CURRENT)
        self.registry.write_text(EXPIRED + "\n" + CURRENT.replace("2099-01-01", "2099-02-01"))
        status, output = self.run_lint("--base", base)
        self.assertEqual(status, 0, output)
        self.assertIn("expired-thing-release", output)

    def test_expired_flag_whose_declaration_is_touched_fails(self):
        base = self.commit_base(EXPIRED + CURRENT)
        self.registry.write_text(EXPIRED.replace("owner: someone", "owner: someone-else") + CURRENT)
        status, output = self.run_lint("--base", base)
        self.assertEqual(status, 1, output)
        self.assertTrue(
            any("expired-thing-release" in error for error in self.linter.errors),
            self.linter.errors,
        )

    def test_extending_to_another_past_date_fails(self):
        base = self.commit_base(EXPIRED + CURRENT)
        self.registry.write_text(EXPIRED.replace("2020-01-01", "2020-06-01") + CURRENT)
        status, output = self.run_lint("--base", base)
        self.assertEqual(status, 1, output)

    def test_extending_to_a_future_date_passes(self):
        base = self.commit_base(EXPIRED + CURRENT)
        self.registry.write_text(EXPIRED.replace("2020-01-01", "2099-06-01") + CURRENT)
        status, output = self.run_lint("--base", base)
        self.assertEqual(status, 0, output)

    def test_newly_added_expired_flag_fails(self):
        base = self.commit_base(CURRENT)
        self.registry.write_text(CURRENT + EXPIRED)
        status, output = self.run_lint("--base", base)
        self.assertEqual(status, 1, output)

    def test_malformed_date_fails_without_any_diff(self):
        base = self.commit_base(EXPIRED.replace("2020-01-01", "2026-13-01"))
        status, output = self.run_lint("--base", base)
        self.assertEqual(status, 1, output)

    def test_missing_date_fails_without_any_diff(self):
        base = self.commit_base(EXPIRED.replace("reviewBy: 2020-01-01, ", ""))
        status, output = self.run_lint("--base", base)
        self.assertEqual(status, 1, output)

    def test_unresolvable_base_only_warns(self):
        self.commit_base(EXPIRED)
        with mock.patch.object(self.linter, "default_base", return_value=None):
            status, output = self.run_lint()
        self.assertEqual(status, 0, output)
        self.assertIn("expired-thing-release", output)


if __name__ == "__main__":
    unittest.main()
