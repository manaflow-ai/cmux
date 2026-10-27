#!/usr/bin/env python3
"""crash_ratchet.py's report-only `raw_continuation` class (p10-stability-083).

`--report raw_continuation` counts with(Checked|Unsafe)(Throwing)?Continuation per module over every package's
Sources, less CmuxSafeConcurrency (which implements OnceContinuation), tests, comments and strings; it judges
nothing. The class never reaches the CI compare: the baseline gains no row (`--update-baseline` on a tree full of
hits writes none) and the plain compare stays green over new hits. guardrails.py's raw-continuation rule reads the
same class; its cases run in `guardrails.py --self-test`.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the class:
  python3 -I scripts/cmux-next/tests/test_raw_continuation_report.py
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

SCRIPTS = Path(__file__).resolve().parents[1]
APP_MANIFEST = ('// swift-tools-version: 6.2\nimport PackageDescription\n'
                'let package = Package(name: "CmuxNext", dependencies: [.package(path: "../../Shared/Linked")])\n')
LINKED_MANIFEST = '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Linked")\n'
WAIT = "func f() async {\n    await withCheckedContinuation { $0.resume() }\n}\n"
FILES = {
    "Packages/macOS/CmuxNext/Package.swift": APP_MANIFEST,
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift": WAIT
    + "func g() async throws {\n    try await withUnsafeThrowingContinuation { $0.resume() }\n}\n"
    + "// withCheckedContinuation in a comment\nlet s = \"withUnsafeContinuation\"\n",
    "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/ATests.swift": WAIT,
    "Packages/Shared/Linked/Package.swift": LINKED_MANIFEST,
    "Packages/Shared/Linked/Sources/Linked/L.swift": WAIT,
    # Outside the app's closure: the report reads every package, the ratchet only the closure.
    "Packages/iOS/Phone/Sources/Phone/P.swift": "let x = 1 ; func p() async throws {\n"
    "    try await withCheckedThrowingContinuation { $0.resume() }\n"
    "    try await withCheckedThrowingContinuation { $0.resume() }\n}\n",
    "Packages/Shared/CmuxSafeConcurrency/Sources/CmuxSafeConcurrency/Once.swift": WAIT,
    "cmux-tui/crates/x/src/lib.rs": "pub fn f() {}\n",
}


class RawContinuationReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Path(tempfile.mkdtemp(prefix="raw-continuation-report-"))
        self.addCleanup(shutil.rmtree, self.repo, True)
        (self.repo / "scripts/cmux-next").mkdir(parents=True)
        shutil.copy(SCRIPTS / "crash_ratchet.py", self.repo / "scripts/cmux-next/crash_ratchet.py")
        for relative, text in FILES.items():
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git("init", "--quiet")
        self.git("add", "-A")
        self.git("commit", "--quiet", "-m", "fixture")

    def git(self, *args: str) -> None:
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t",
                        "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)

    def ratchet(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(self.repo / "scripts/cmux-next/crash_ratchet.py"),
                               "--repo", str(self.repo), *args], capture_output=True, text=True)

    def test_the_report_counts_every_package_outside_the_owner_tests_and_comments(self):
        run = self.ratchet("--report", "raw_continuation")
        self.assertEqual(run.returncode, 0, run.stderr)
        app, linked, phone = ("Packages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift",
                              "Packages/Shared/Linked/Sources/Linked/L.swift", "Packages/iOS/Phone/Sources/Phone/P.swift")
        sites = [(app, 2, "CmuxNextApp"), (app, 5, "CmuxNextApp"), (phone, 2, "Phone"), (phone, 3, "Phone"),
                 (linked, 2, "Linked")]
        self.assertEqual(json.loads(run.stdout), {"raw_continuation": {
            "total": 5, "modules": {"CmuxNextApp": 2, "Linked": 1, "Phone": 2},
            "hits": [{"path": path, "line": line, "class": "raw_continuation", "module": module, "hits": 1}
                     for path, line, module in sorted(sites)]}})

    def test_an_unknown_report_class_is_refused(self):
        run = self.ratchet("--report", "raw_continuations")
        self.assertEqual(run.returncode, 2)
        self.assertIn("raw_continuation", run.stderr)

    def test_the_report_does_not_go_with_a_baseline_update(self):
        self.assertNotEqual(self.ratchet("--report", "raw_continuation", "--update-baseline").returncode, 0)

    def test_the_class_never_reaches_the_ci_baseline_or_compare(self):
        update = self.ratchet("--update-baseline")
        self.assertIn(update.returncode, (0, 1), update.stderr)
        baseline = (self.repo / "scripts/cmux-next/crash-safety-baseline.json").read_text()
        self.assertNotIn("raw_continuation", baseline)
        compare = self.ratchet()
        self.assertEqual(compare.returncode, 0, compare.stdout + compare.stderr)
        self.assertNotIn("raw_continuation", compare.stdout)

    def test_the_checked_in_ci_baseline_has_no_report_class(self):
        baseline = (SCRIPTS / "crash-safety-baseline.json").read_text()
        self.assertNotIn("raw_continuation", baseline)


if __name__ == "__main__":
    unittest.main()
