#!/usr/bin/env python3
"""The package interface fingerprint's classification (RFC #15391, Work 2).

Each case builds a repository with an allowlisted package, commits a base and
a head, and runs the fingerprint with a stand-in for `swift build` that
"emits" the lines of the package's sources that start with `public`. The real
build runs in the swift-package-tests lane.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "package_interface_fingerprint.py"

spec = importlib.util.spec_from_file_location("package_interface_fingerprint", HELPER)
assert spec and spec.loader
fp = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = fp
spec.loader.exec_module(fp)

GIT_ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
}
PKG = "Packages/macOS/FixtureLaunch"
SOURCE = f"{PKG}/Sources/FixtureLaunch/Launch.swift"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, env=GIT_ENV, check=True, capture_output=True, text=True,
    ).stdout.strip()


def fake_build(package: Path, modules, scratch: Path) -> str:
    lines = []
    for source in sorted(package.glob("Sources/**/*.swift")):
        lines += [line for line in source.read_text().splitlines() if line.startswith("public")]
    return "\n".join(lines)


def failing_build(package: Path, modules, scratch: Path) -> str:
    raise RuntimeError("swift build exited 1:\nerror: boom")


class FingerprintTests(unittest.TestCase):
    def setUp(self) -> None:
        # No real package is allowlisted today; exercise the classifier with a fixture one.
        patch = unittest.mock.patch.dict(fp.ALLOWLIST, {"FixtureLaunch": ("FixtureLaunch",)})
        patch.start()
        self.addCleanup(patch.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.work = Path(self.tmp.name) / "work"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        self.write(f"{PKG}/Package.swift", "// swift-tools-version: 6.0\n")
        self.write(SOURCE, "public func launch() {}\nfunc helper() { print(1) }\n")
        self.write(f"{PKG}/Tests/FixtureLaunchTests/LaunchTests.swift", "// test\n")
        self.write("Sources/App.swift", "import FixtureLaunch\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def run_head(self, build=fake_build) -> dict:
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "head")
        changed = git(self.repo, "diff", "--no-renames", "--name-only", "HEAD^1", "HEAD").splitlines()
        return fp.fingerprint(self.repo, "HEAD^1", changed, self.work, build=build)

    def test_private_edit_is_interface_equivalent(self) -> None:
        self.write(SOURCE, "public func launch() {}\nfunc helper() { print(2) }\n")
        receipt = self.run_head()
        self.assertEqual(receipt["class"], "interface_equivalent")
        self.assertTrue(receipt["would_skip_app_compile"])
        package = receipt["packages"]["FixtureLaunch"]
        self.assertEqual(package["interface"], "equivalent")
        self.assertEqual(package["base_sha256"], package["head_sha256"])

    def test_public_edit_is_interface_changing(self) -> None:
        self.write(SOURCE, "public func launch() {}\npublic func helper() { print(1) }\n")
        receipt = self.run_head()
        self.assertEqual(receipt["class"], "interface_changing")
        self.assertFalse(receipt["would_skip_app_compile"])
        self.assertEqual(receipt["packages"]["FixtureLaunch"]["interface"], "changed")

    def test_package_tests_only(self) -> None:
        self.write(f"{PKG}/Tests/FixtureLaunchTests/LaunchTests.swift", "// test 2\n")
        receipt = self.run_head(build=failing_build)
        self.assertEqual(receipt["class"], "package_tests_only")
        self.assertTrue(receipt["would_skip_app_compile"])

    def test_app_edit_beside_package_edit_is_ineligible(self) -> None:
        self.write(SOURCE, "public func launch() {}\nfunc helper() { print(2) }\n")
        self.write("Sources/App.swift", "import FixtureLaunch\n// edited\n")
        receipt = self.run_head(build=failing_build)
        self.assertEqual(receipt["class"], "ineligible")
        self.assertFalse(receipt["would_skip_app_compile"])
        self.assertIn("Sources/App.swift", receipt["reason"])

    def test_manifest_edit_is_ineligible(self) -> None:
        self.write(f"{PKG}/Package.swift", "// swift-tools-version: 6.0\n// edited\n")
        receipt = self.run_head(build=failing_build)
        self.assertEqual(receipt["class"], "ineligible")

    def test_unlisted_package_is_not_applicable(self) -> None:
        self.write("Packages/macOS/CmuxOther/Sources/CmuxOther/Other.swift", "public let x = 1\n")
        receipt = self.run_head(build=failing_build)
        self.assertEqual(receipt["class"], "not_applicable")
        self.assertFalse(receipt["would_skip_app_compile"])

    def test_build_failure_is_unknown(self) -> None:
        self.write(SOURCE, "public func launch() {}\nfunc helper() { print(2) }\n")
        receipt = self.run_head(build=failing_build)
        self.assertEqual(receipt["class"], "unknown")
        self.assertFalse(receipt["would_skip_app_compile"])

    def test_receipt_is_one_marker_line(self) -> None:
        output = Path(self.tmp.name) / "github-output"
        env = {"GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": ""}
        with unittest.mock.patch.dict(os.environ, env), \
                unittest.mock.patch("builtins.print") as printed:
            fp.emit({"class": "interface_equivalent", "would_skip_app_compile": True, "reason": "r"})
        line = printed.call_args.args[0]
        self.assertTrue(line.startswith(fp.MARKER))
        receipt = json.loads(line[len(fp.MARKER):])
        self.assertEqual(receipt["version"], 1)
        self.assertEqual(output.read_text(), "interface_fingerprint=" + line[len(fp.MARKER):] + "\n")


if __name__ == "__main__":
    unittest.main()
