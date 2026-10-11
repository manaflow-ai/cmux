#!/usr/bin/env python3
"""Regression tests for deterministic per-package Swift test input keys."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ci/package_input_key.py"


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout.strip()


def make_repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    git(root, "init", "-q", "-b", "main")
    for path, text in {
        "Packages/macOS/Base/Package.swift": 'let package = Package(dependencies: [])\n',
        "Packages/macOS/Base/Sources/Base/Base.swift": "public struct Base {}\n",
        "Packages/macOS/Base/Tests/BaseTests/BaseTests.swift": "import XCTest\n",
        "Packages/macOS/Top/Package.swift": 'let package = Package(dependencies: [.package(path: "../Base")])\n',
        "Packages/macOS/Top/Sources/Top/Top.swift": "public struct Top {}\n",
        ".github/workflows/ci-macos.yml": "swift-package-tests\n",
        "scripts/ci/package-test-lane.sh": "lane\n",
        ".xcode-version": "26.0\n",
    }.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    git(root, "add", "-A")
    subprocess.run(
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-qm", "base"],
        cwd=root, check=True,
    )
    return root


def receipt(root: Path, *packages: str) -> dict:
    args = [sys.executable, str(HELPER), "--root", str(root)]
    for package in packages:
        args += ["--package", package]
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


class PackageInputKeyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = make_repo(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_dependency_closure_and_global_inputs_are_keyed(self) -> None:
        top = receipt(self.root, "Top")["packages"][0]
        self.assertIn("Packages/macOS/Base/Sources/Base/Base.swift", top["paths"])
        self.assertIn(".github/workflows/ci-macos.yml", top["paths"])
        self.assertEqual(top["key"], top["input_sha256"])

    def test_unrelated_files_do_not_change_a_key(self) -> None:
        before = receipt(self.root, "Top")["packages"][0]["key"]
        (self.root / "README.md").write_text("docs\n")
        self.assertEqual(before, receipt(self.root, "Top")["packages"][0]["key"])

    def test_input_changes_and_package_order_are_deterministic(self) -> None:
        before = receipt(self.root, "Base", "Top")
        (self.root / "Packages/macOS/Base/Tests/BaseTests/BaseTests.swift").write_text(
            "import XCTest\nfinal class NewTest {}\n"
        )
        changed = receipt(self.root, "Base", "Top")
        self.assertNotEqual(before["packages"][0]["key"], changed["packages"][0]["key"])
        self.assertNotEqual(before["packages"][1]["key"], changed["packages"][1]["key"])
        self.assertEqual([item["package"] for item in changed["packages"]], ["Base", "Top"])

    def test_receipt_file_is_single_line_json(self) -> None:
        packages = self.root / "packages.txt"
        packages.write_text("Top\n")
        output = Path(self.tmp.name) / "receipt.json"
        subprocess.run(
            [sys.executable, str(HELPER), "--root", str(self.root), "--packages-file", str(packages), "--output", str(output)],
            check=True,
        )
        self.assertEqual(len(output.read_text().splitlines()), 1)
        self.assertEqual(json.loads(output.read_text())["version"], 1)


if __name__ == "__main__":
    unittest.main()
