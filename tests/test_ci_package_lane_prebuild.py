#!/usr/bin/env python3
"""package-test-lane.sh prebuild-one: a compile step never passes without compiling.

2026-10-04 false green: lanes gave prebuild-one a package PATH
(Packages/macOS/CmuxNext); the script looked it up as a NAME, printed
"Prebuild skipped ... (not found)" and exited 0 with nothing compiled. A
build failure also exited 0. A fake `swift` records the calls.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FAKE_SWIFT = """#!/bin/bash
echo "swift $*" >> "$FAKE_SWIFT_LOG"
if [ -n "${FAKE_SWIFT_FAIL:-}" ]; then echo "error: compile failed"; exit 1; fi
echo "Build complete!"
"""


class PrebuildOneTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lane-prebuild-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "cmux"
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copytree(ROOT / "scripts/ci", self.repo / "scripts/ci")
        pkg = self.repo / "Packages/macOS/Pkg"
        pkg.mkdir(parents=True)
        (pkg / "Package.swift").write_text("// swift-tools-version: 6.0\n")
        (self.repo / "Packages/macOS/NotAPackage").mkdir()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "swift").write_text(FAKE_SWIFT)
        (bin_dir / "swift").chmod(0o755)
        self.calls = self.tmp / "swift.log"
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_SWIFT_LOG": str(self.calls),
                    "RUNNER_TEMP": str(self.tmp)}

    def prebuild(self, package, **env):
        log = self.tmp / "prebuild.log"
        return subprocess.run(["bash", "scripts/ci/package-test-lane.sh", "prebuild-one", package, str(log)],
                              cwd=self.repo, env={**self.env, **env}, capture_output=True, text=True, timeout=120)

    def swift_calls(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def test_an_unknown_package_fails_without_compiling(self):
        for package in ("NoSuchPackage", "Packages/macOS/NoSuch", "Packages/macOS/NotAPackage", "../outside"):
            with self.subTest(package=package):
                done = self.prebuild(package)
                self.assertNotEqual(done.returncode, 0, f"{package}: {done.stdout}{done.stderr}")
                self.assertIn("not found", done.stdout + done.stderr)
        self.assertEqual(self.swift_calls(), "")

    def test_a_package_path_or_name_compiles_that_package(self):
        for package in ("Packages/macOS/Pkg", "Pkg"):
            with self.subTest(package=package):
                done = self.prebuild(package)
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.swift_calls().count("--package-path Packages/macOS/Pkg"), 2, self.swift_calls())

    def test_a_build_failure_fails_the_step(self):
        done = self.prebuild("Pkg", FAKE_SWIFT_FAIL="1")
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)


if __name__ == "__main__":
    sys.exit(unittest.main())
