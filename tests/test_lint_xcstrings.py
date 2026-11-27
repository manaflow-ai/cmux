#!/usr/bin/env python3
"""Behavior tests for the XCStrings catalog structure lint."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
LINT_PATH = REPO_ROOT / "scripts" / "lint-xcstrings.py"


class XCStringsLintTests(unittest.TestCase):
    """Exercise catalog validation through the lint command's public interface."""

    def run_lint(self, *paths: Path) -> subprocess.CompletedProcess[str]:
        """Run the linter for explicit paths or all tracked catalogs."""
        command = [sys.executable, str(LINT_PATH)]
        for path in paths:
            command.extend(("--catalog", str(path)))
        return subprocess.run(command, cwd=REPO_ROOT, capture_output=True, text=True)

    def write_catalog(self, root: dict[str, object]) -> Path:
        """Write a catalog fixture into this test's temporary directory."""
        directory = Path(self.temp_directory.name)
        path = directory / "Localizable.xcstrings"
        path.write_text(json.dumps(root), encoding="utf-8")
        return path

    def setUp(self) -> None:
        """Create an isolated directory for catalog fixtures."""
        self.temp_directory = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        """Remove the catalog fixtures after each test."""
        self.temp_directory.cleanup()

    def test_accepts_catalog_with_entries_inside_strings(self) -> None:
        """Accept localization entries nested under the strings object."""
        path = self.write_catalog(
            {"sourceLanguage": "en", "strings": {"example": {}}, "version": "1.0"}
        )
        result = self.run_lint(path)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_entries_outside_strings(self) -> None:
        """Identify misplaced root entries and explain the expected nesting."""
        path = self.write_catalog(
            {
                "sourceLanguage": "en",
                "strings": {},
                "misplaced": {"localizations": {}},
                "version": "1.0",
            }
        )
        result = self.run_lint(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("misplaced", result.stderr)
        self.assertIn("inside 'strings'", result.stderr)

    def test_checked_in_catalogs_have_no_misplaced_entries(self) -> None:
        """Validate every tracked catalog using the default discovery path."""
        result = self.run_lint()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_utf8_is_reported_without_stopping_other_catalogs(self) -> None:
        """Report decoding errors and continue collecting errors from later catalogs."""
        invalid_path = Path(self.temp_directory.name) / "invalid.xcstrings"
        invalid_path.write_bytes(b"\xff")
        misplaced_path = self.write_catalog(
            {"sourceLanguage": "en", "strings": {}, "misplaced": {}, "version": "1.0"}
        )

        result = self.run_lint(invalid_path, misplaced_path)

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{invalid_path}: invalid JSON:", result.stderr)
        self.assertIn(f"{misplaced_path}: unexpected top-level key(s): misplaced", result.stderr)
        self.assertIn("XCStrings lint failed: 2 error(s)", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
