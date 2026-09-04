#!/usr/bin/env python3
"""Behavior tests for the nightly auth callback plist rewrite."""

from __future__ import annotations

import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "set-nightly-auth-callback-scheme.py"


class NightlyAuthCallbackSchemeTests(unittest.TestCase):
    def _run(self, plist: Path, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(plist), "cmux-nightly", "--base-scheme", "cmux", *extra],
            check=False,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def _write(path: Path, url_types: list[dict[str, object]]) -> None:
        with path.open("wb") as handle:
            plistlib.dump(
                {"CFBundleIdentifier": "com.cmuxterm.app", "CFBundleURLTypes": url_types},
                handle,
                sort_keys=False,
            )

    @staticmethod
    def _read(path: Path) -> dict[str, object]:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
        if not isinstance(value, dict):
            raise AssertionError("plist root was not a dictionary")
        return value

    def test_reordered_url_types_update_only_the_auth_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plist = Path(directory) / "Info.plist"
            self._write(
                plist,
                [
                    {"CFBundleURLName": "SSH URL", "CFBundleURLSchemes": ["ssh"]},
                    {"CFBundleURLName": "com.cmuxterm.app.web", "CFBundleURLSchemes": ["http", "https"]},
                    {"CFBundleURLName": "com.cmuxterm.app.auth", "CFBundleURLSchemes": ["cmux"]},
                ],
            )

            result = self._run(plist)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("index 2", result.stdout)
            url_types = self._read(plist)["CFBundleURLTypes"]
            self.assertIsInstance(url_types, list)
            self.assertEqual(url_types[0]["CFBundleURLSchemes"], ["ssh"])
            self.assertEqual(url_types[1]["CFBundleURLSchemes"], ["http", "https"])
            self.assertEqual(url_types[2]["CFBundleURLSchemes"], ["cmux-nightly"])

    def test_scheme_identifies_auth_entry_when_name_is_not_descriptive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plist = Path(directory) / "Info.plist"
            self._write(
                plist,
                [
                    {"CFBundleURLName": "web", "CFBundleURLSchemes": ["http", "https"]},
                    {"CFBundleURLName": "callback", "CFBundleURLSchemes": ["legacy-auth", "cmux"]},
                ],
            )

            result = self._run(plist)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                self._read(plist)["CFBundleURLTypes"][1]["CFBundleURLSchemes"],
                ["legacy-auth", "cmux-nightly"],
            )

    def test_ambiguous_auth_entries_fail_closed_without_mutating_the_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plist = Path(directory) / "Info.plist"
            self._write(
                plist,
                [
                    {"CFBundleURLName": "one.auth", "CFBundleURLSchemes": ["cmux"]},
                    {"CFBundleURLName": "two.auth", "CFBundleURLSchemes": ["cmux-alt"]},
                ],
            )
            before = plist.read_bytes()

            result = self._run(plist)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one", result.stderr)
            self.assertEqual(plist.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
