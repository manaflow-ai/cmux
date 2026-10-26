#!/usr/bin/env python3
"""check-package-dependency-lists.py: the CmuxNextAppTests dependencies stay one sorted entry per
line, so two pull requests that each add a module merge without a conflict (2026-10-20: six
pull requests were CONFLICTING again within twenty minutes of a rebase on that list)."""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "check-package-dependency-lists.py"
SPEC = importlib.util.spec_from_file_location("check_package_dependency_lists", SCRIPT)
assert SPEC and SPEC.loader
lint = importlib.util.module_from_spec(SPEC)
sys.modules["check_package_dependency_lists"] = lint
SPEC.loader.exec_module(lint)


def manifest(*entries: str) -> str:
    body = "".join(f"                {entry}\n" for entry in entries)
    return (
        "let package = Package(\n"
        "    targets: [\n"
        "        .testTarget(\n"
        '            name: "CmuxNextAppTests",\n'
        f"            dependencies: [ {lint.MARKER}\n"
        f"{body}"
        "            ],\n"
        "            swiftSettings: uiSwiftSettings\n"
        "        ),\n"
        "    ]\n"
        ")\n"
    )


BASE = ('"CmuxNextActions",', '"CmuxNextFeed",', '"CmuxNextTabs",',
        '.product(name: "CmuxHomeCore", package: "CmuxHomeCore"),')


class CheckTests(unittest.TestCase):
    def problems(self, text: str) -> list[str]:
        return lint.check(text, fix=False)[0]

    def test_the_committed_manifest_is_canonical(self):
        self.assertEqual(self.problems(lint.DEFAULT_MANIFEST.read_text(encoding="utf-8")), [])

    def test_a_sorted_list_passes(self):
        self.assertEqual(self.problems(manifest(*BASE)), [])

    def test_an_unsorted_list_fails_and_fix_sorts_it_with_its_comments(self):
        text = manifest('"CmuxNextTabs",', "// Feed's tests read the timeline.", '"CmuxNextFeed",')
        self.assertIn("CmuxNextAppTests: entries are not sorted (run with --fix)", self.problems(text))
        fixed = lint.check(text, fix=True)[1]
        self.assertEqual(fixed, manifest("// Feed's tests read the timeline.", '"CmuxNextFeed",', '"CmuxNextTabs",'))
        self.assertEqual(self.problems(fixed), [])

    def test_two_entries_on_a_line_fail(self):
        problems = self.problems(manifest('"CmuxNextActions", "CmuxNextFeed",'))
        self.assertTrue(any("one entry per line" in p for p in problems), problems)

    def test_a_missing_trailing_comma_fails(self):
        problems = self.problems(manifest('"CmuxNextActions",', '"CmuxNextFeed"'))
        self.assertTrue(any("must end in a comma" in p for p in problems), problems)

    def test_a_duplicate_fails(self):
        problems = self.problems(manifest('"CmuxNextFeed",', '"CmuxNextFeed",'))
        self.assertIn('CmuxNextAppTests: duplicate entry "CmuxNextFeed",', problems)

    def test_a_trailing_comment_fails(self):
        problems = self.problems(manifest('"CmuxNextFeed", // the timeline'))
        self.assertTrue(any("own line above" in p for p in problems), problems)

    def test_the_app_tests_list_must_carry_the_marker(self):
        text = manifest(*BASE).replace(f" {lint.MARKER}", "")
        self.assertTrue(any("lacks the marker" in p for p in self.problems(text)))

    def test_fix_on_the_command_line_rewrites_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Package.swift"
            path.write_text(manifest('"CmuxNextTabs",', '"CmuxNextFeed",'), encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), "--fix", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(path.read_text(encoding="utf-8"), manifest('"CmuxNextFeed",', '"CmuxNextTabs",'))


class ImportTests(unittest.TestCase):
    """A target that imports another local target declares it (2026-10-24: CmuxNextDaemonTests imported
    CmuxNextCompat undeclared, and incremental builds linked a stale object against an old Mutex symbol)."""

    PACKAGE = (
        "let package = Package(\n"
        "    targets: [\n"
        "        .target(\n"
        '            name: "CmuxNextCompat",\n'
        "            dependencies: []\n"
        "        ),\n"
        "        .target(\n"
        '            name: "CmuxNextDaemon",\n'
        '            dependencies: ["CmuxNextCompat"]\n'
        "        ),\n"
        "        .testTarget(\n"
        '            name: "CmuxNextDaemonTests",\n'
        "            dependencies: [DEPS]\n"
        "        ),\n"
        "    ]\n"
        ")\n"
    )

    def problems(self, deps: str, source: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for folder in ("Sources/CmuxNextCompat", "Sources/CmuxNextDaemon", "Tests/CmuxNextDaemonTests"):
                (root / folder).mkdir(parents=True)
            (root / "Sources/CmuxNextDaemon/A.swift").write_text("import CmuxNextCompat\n", encoding="utf-8")
            (root / "Tests/CmuxNextDaemonTests/RetryWakeFolderTests.swift").write_text(source, encoding="utf-8")
            text = self.PACKAGE.replace("DEPS", deps)
            with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset()):
                return lint.import_problems(text, root)

    def test_an_undeclared_local_import_fails(self):
        problems = self.problems('"CmuxNextDaemon"', "import CmuxNextCompat\n@testable import CmuxNextDaemon\n")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("CmuxNextDaemonTests: imports CmuxNextCompat but does not declare it", problems[0])

    def test_a_declared_import_and_a_system_import_pass(self):
        self.assertEqual(self.problems('"CmuxNextCompat", "CmuxNextDaemon"',
                                       "import Foundation\nimport CmuxNextCompat\n@testable import CmuxNextDaemon\n"), [])

    def test_a_baseline_line_that_is_fixed_must_go(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Sources/CmuxNextCompat").mkdir(parents=True)
            text = "let package = Package(\n    targets: [\n        .target(\n            name: \"CmuxNextCompat\"\n        ),\n    ]\n)\n"
            with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset({"CmuxNextApp: CmuxNextFileGrid"})):
                problems = lint.import_problems(text, root)
        self.assertEqual(problems, ["IMPORT_BASELINE lists CmuxNextApp: CmuxNextFileGrid, which is declared or gone now: drop its line"])

    def test_the_committed_package_declares_its_imports(self):
        root = lint.DEFAULT_MANIFEST.parent
        self.assertEqual(lint.import_problems(lint.DEFAULT_MANIFEST.read_text(encoding="utf-8"), root), [])


class MergeTests(unittest.TestCase):
    """Git's own line merge (what GitHub runs) on two branches that each add a module."""

    def git(self, *args: str) -> subprocess.CompletedProcess:
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@e", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(["git", "-C", self.root, *args], env=env, capture_output=True, text=True)

    def branch(self, name: str, *entries: str) -> None:
        self.git("checkout", "-q", "-b", name, "main")
        Path(self.root, "Package.swift").write_text(manifest(*sorted(entries)), encoding="utf-8")
        self.git("commit", "-qam", name)

    def merge(self, left: tuple, right: tuple) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            self.root = tmp
            self.git("init", "-q", "-b", "main")
            Path(tmp, "Package.swift").write_text(manifest(*BASE), encoding="utf-8")
            self.git("add", ".")
            self.git("commit", "-qm", "base")
            self.branch("left", *BASE, *left)
            self.branch("right", *BASE, *right)
            result = self.git("merge", "-q", "--no-edit", "left")
            result.merged = Path(tmp, "Package.swift").read_text(encoding="utf-8")
            return result

    def test_additions_in_different_places_merge_cleanly_and_stay_sorted(self):
        result = self.merge(('"CmuxNextBrowserHistory",',), ('"CmuxNextNowPlaying",',))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(lint.check(result.merged, fix=False)[0], [])
        self.assertIn('"CmuxNextBrowserHistory",', result.merged)
        self.assertIn('"CmuxNextNowPlaying",', result.merged)


if __name__ == "__main__":
    unittest.main()
