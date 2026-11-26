#!/usr/bin/env python3
"""Every Swift test target is run by a pull request check, or scripts/ci/swift-test-targets.json says why not.

cmux#43937 added CmuxNextAgentListTests, seven tests, and every check was green while none of them ran:
the fast tier built the target and listed its tests, then ran only its registry's filters, and
`cmux-next swift test` needs full-ci (hq#11644). Before this guard 24 of the 94 Swift test targets in
Packages/ had no pull request runner at all. scripts/ci/swift_test_coverage.py is the check; this test
runs it on the tree (a new test target with no runner and no registry entry fails here), and on fixtures
for the diff check that cmux-next-guards.yml's tooling-tests job runs with the pull request's base.

    python3 -I tests/test_swift_test_coverage.py
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/swift_test_coverage.py"
_spec = importlib.util.spec_from_file_location("swift_test_coverage", SCRIPT)
coverage = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = coverage  # @dataclass reads its module from sys.modules
_spec.loader.exec_module(coverage)
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_fixture_spec = importlib.util.spec_from_file_location("git_fixture_env", ROOT / "tests/git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_fixture_spec)
_fixture_spec.loader.exec_module(git_fixture_env)

GIT_ENV = git_fixture_env.fixture_env()
GIT_ENV.update({"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@example.com"})


class TheTreeHasNoUnrunTarget(unittest.TestCase):
    def test_every_target_has_a_runner_or_an_entry(self):
        errors = coverage.check_tree(ROOT)
        self.assertEqual(errors, [], "\n".join(errors))

    def test_the_scan_sees_every_package(self):
        targets = coverage.discover(ROOT)
        self.assertGreater(len(targets), 90)
        self.assertIn(coverage.Target("Packages/macOS/CmuxNext", "CmuxNextAppTests"), set(targets))
        # A comment between `.testTarget(` and `name:` (CmuxRemote's manifest) is still a target.
        self.assertIn(coverage.Target("Packages/macOS/CmuxRemote", "CmuxRemoteProcessTests"), set(targets))

    def test_every_not_run_reason_says_something(self):
        for entry in coverage.load_registry(ROOT):
            if entry.get("not_run"):
                self.assertGreater(len(entry["not_run"].split()), 4, entry)


def write(root: Path, path: str, text: str) -> None:
    (root / path).parent.mkdir(parents=True, exist_ok=True)
    (root / path).write_text(text, encoding="utf-8")


MANIFEST = """// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "{name}", targets: [
    .target(name: "{name}"),
{tests}
])
"""


def manifest(name: str, *tests: str) -> str:
    rows = "\n".join(f'    .testTarget(\n        // why\n        name: "{t}", dependencies: ["{name}"]),' for t in tests)
    return MANIFEST.format(name=name, tests=rows)


class Fixture(unittest.TestCase):
    """A repository with the four runners, one package of each kind and a CmuxNext package."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        write(self.root, "scripts/ci/swift-linux-packages.txt",
              "# comment\nPackages/Shared/Linuxed  LinuxedTests  -\n")
        write(self.root, ".github/workflows/swift-linux-packages.yml", """jobs:
  swift-linux-packages:
    strategy:
      matrix:
        include:
          - group: listed
          - group: whole
            packages: >-
              Packages/Shared/Grouped
          - group: filtered
            packages: Packages/Shared/Filtered
            test_filter: OnlySome
    steps:
      - run: true
""")
        write(self.root, "scripts/ci/package-test-lane.sh", "select_packages() {\n  PACKAGES=(\n    Laned\n  )\n}\n")
        write(self.root, ".github/workflows/own.yml",
              "on:\n  pull_request:\njobs:\n  t:\n    steps:\n      - run: swift test --package-path Packages/Shared/Owned\n")
        write(self.root, ".github/workflows/pushonly.yml",
              "on:\n  push:\njobs:\n  t:\n    steps:\n      - run: swift test --package-path Packages/Shared/Owned\n")
        for name in ("Linuxed", "Grouped", "Filtered", "Laned", "Owned"):
            write(self.root, f"Packages/Shared/{name}/Package.swift", manifest(name, f"{name}Tests"))
        write(self.root, "Packages/macOS/CmuxNext/Package.swift", manifest("CmuxNextApp", "CmuxNextAppTests"))
        write(self.root, "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/ModelTests.swift",
              "import Testing\nstruct ModelTests {\n  @Test func a() {}\n}\n")
        self.graph({"CmuxNextAppTests": "Tests/CmuxNextAppTests"})
        write(self.root, "scripts/cmux-next/fast-tier.json", json.dumps({"entries": [
            {"name": "model", "kind": "swift", "package": "Packages/macOS/CmuxNext", "filter": "ModelTests",
             "owner": "t"}]}))
        self.registry([{"package": "Packages/Shared/Filtered", "target": "FilteredTests",
                        "not_run": "only OnlySome runs on Linux; the rest needs a display"},
                       {"package": "Packages/Shared/Owned", "target": "OwnedTests", "run_by": ".github/workflows/own.yml"}])

    def tearDown(self):
        self.tmp.cleanup()

    def graph(self, tests: dict[str, str]) -> None:
        write(self.root, "Packages/macOS/CmuxNext/ci-target-graph.json", json.dumps(
            {"targets": {name: {"kind": "test", "path": path} for name, path in tests.items()}}))

    def registry(self, entries: list[dict]) -> None:
        write(self.root, coverage.REGISTRY, json.dumps({"targets": entries}))

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=GIT_ENV, check=True, capture_output=True,
                              text=True).stdout.strip()

    def commit(self) -> str:
        if not (self.root / ".git").exists():
            git_fixture_env.init_repo(self.root, env=GIT_ENV)
        self.git("add", "-A")
        self.git("commit", "-qm", "c")
        return self.git("rev-parse", "HEAD")


class TreeCheck(Fixture):
    def test_the_fixture_passes(self):
        self.assertEqual(coverage.check_tree(self.root), [])
        runners = coverage.runners(self.root)
        self.assertIn("listed", runners[coverage.Target("Packages/Shared/Linuxed", "LinuxedTests")])
        self.assertIn("whole", runners[coverage.Target("Packages/Shared/Grouped", "GroupedTests")])
        self.assertIn("swift-package-tests", runners[coverage.Target("Packages/Shared/Laned", "LanedTests")])
        self.assertNotIn(coverage.Target("Packages/Shared/Filtered", "FilteredTests"), runners)

    def test_a_new_target_with_no_runner_fails_and_names_the_ways_out(self):
        write(self.root, "Packages/Shared/Laned/Package.swift", manifest("Laned", "LanedTests"))
        write(self.root, "Packages/iOS/Fresh/Package.swift", manifest("Fresh", "FreshTests"))
        errors = coverage.check_tree(self.root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("Packages/iOS/Fresh: test target FreshTests is run by no pull request check", errors[0])
        for way in ("swift-linux-packages.txt", "package-test-lane.sh", "run_by", "not_run"):
            self.assertIn(way, errors[0])

    def test_a_cmuxnext_target_missing_from_the_graph_fails(self):
        write(self.root, "Packages/macOS/CmuxNext/Package.swift",
              manifest("CmuxNextApp", "CmuxNextAppTests", "CmuxNextNewTests"))
        errors = coverage.check_tree(self.root)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("CmuxNextNewTests", errors[0])

    def test_a_stale_or_redundant_entry_fails(self):
        self.registry([{"package": "Packages/Shared/Filtered", "target": "FilteredTests", "not_run": "a b c d e"},
                       {"package": "Packages/Shared/Owned", "target": "OwnedTests", "run_by": ".github/workflows/own.yml"},
                       {"package": "Packages/Shared/Gone", "target": "GoneTests", "not_run": "a b c d e"},
                       {"package": "Packages/Shared/Laned", "target": "LanedTests", "not_run": "a b c d e"}])
        errors = coverage.check_tree(self.root)
        self.assertEqual(len(errors), 2, errors)
        self.assertTrue(any("declares no test target GoneTests" in e for e in errors))
        self.assertTrue(any("LanedTests already runs in" in e for e in errors))

    def test_run_by_must_run_the_whole_package_on_pull_requests(self):
        for workflow, why in ((".github/workflows/pushonly.yml", "does not run on pull requests"),
                              (".github/workflows/missing.yml", "does not exist")):
            with self.subTest(workflow=workflow):
                self.registry([{"package": "Packages/Shared/Filtered", "target": "FilteredTests", "not_run": "a b c d e"},
                               {"package": "Packages/Shared/Owned", "target": "OwnedTests", "run_by": workflow}])
                errors = coverage.check_tree(self.root)
                self.assertEqual(len(errors), 1, errors)
                self.assertIn(why, errors[0])
        write(self.root, ".github/workflows/own.yml", "on:\n  pull_request:\njobs:\n  t:\n    steps:\n"
              "      - run: swift test --package-path Packages/Shared/Owned --filter One\n")
        self.registry([{"package": "Packages/Shared/Filtered", "target": "FilteredTests", "not_run": "a b c d e"},
                       {"package": "Packages/Shared/Owned", "target": "OwnedTests", "run_by": ".github/workflows/own.yml"}])
        self.assertIn("without a --filter", coverage.check_tree(self.root)[0])
        # A filter naming exactly the registered target runs it (the package's other targets run on Linux).
        write(self.root, ".github/workflows/own.yml", "on:\n  pull_request:\njobs:\n  t:\n    steps:\n"
              "      - run: swift test --package-path Packages/Shared/Owned --filter OwnedTests\n")
        self.assertEqual(coverage.check_tree(self.root), [])

    def test_a_malformed_registry_is_exit_2(self):
        self.registry([{"package": "Packages/Shared/Owned", "target": "OwnedTests"}])
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(self.root)], capture_output=True,
                                text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("exactly one of run_by", result.stderr)


class DiffCheck(Fixture):
    """The cmux#43937 shape: a new CmuxNext test target, built by the fast tier and run by nothing."""

    def add_agent_list_target(self, tests: int = 7) -> None:
        write(self.root, "Packages/macOS/CmuxNext/Package.swift",
              manifest("CmuxNextApp", "CmuxNextAppTests", "CmuxNextAgentListTests"))
        body = "".join(f"  @Test func t{i}() {{}}\n" for i in range(tests))
        write(self.root, "Packages/macOS/CmuxNext/Tests/CmuxNextAgentListTests/AgentListDriverTests.swift",
              f"import Testing\nstruct AgentListDriverTests {{\n{body}}}\n")
        # ci-target-graph.json paths are repository-relative; a package-relative one reads the same.
        self.graph({"CmuxNextAppTests": "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests",
                    "CmuxNextAgentListTests": "Tests/CmuxNextAgentListTests"})

    def run_script(self, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(self.root), *extra],
                              capture_output=True, text=True)

    def test_a_new_target_no_fast_tier_entry_covers_fails_without_full_ci(self):
        base = self.commit()
        self.add_agent_list_target()
        self.commit()
        result = self.run_script("--base", base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("::error title=Swift test target coverage::Packages/macOS/CmuxNext: the new test target"
                      " CmuxNextAgentListTests (7 tests) is run by no pull request check", result.stdout)
        self.assertIn("fast-tier.json swift entry", result.stdout)
        self.assertIn("full-ci", result.stdout)
        # The tree check alone passes: the target is in the graph, so full-ci would run it.
        self.assertEqual(self.run_script().returncode, 0)

    def test_full_ci_turns_it_into_a_warning(self):
        base = self.commit()
        self.add_agent_list_target()
        self.commit()
        result = self.run_script("--base", base, "--full-ci")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("::warning title=Swift test target coverage::", result.stdout)
        self.assertIn("runs here only because of full-ci", result.stdout)

    def test_a_fast_tier_entry_for_the_target_or_its_suite_passes(self):
        base = self.commit()
        self.add_agent_list_target()
        for flt in ("CmuxNextAgentListTests", "AgentListDriverTests", "CmuxNextAgentListTests.AgentListDriverTests"):
            with self.subTest(filter=flt):
                write(self.root, "scripts/cmux-next/fast-tier.json", json.dumps({"entries": [
                    {"name": "agent list", "kind": "swift", "package": "Packages/macOS/CmuxNext", "filter": flt,
                     "owner": "t"}]}))
                self.commit()
                result = self.run_script("--base", base)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("::warning", result.stdout)

    def test_a_target_swift_linux_packages_lists_passes(self):
        # swift-linux-packages.yml runs a listed CmuxNext target on the pull requests that touch it.
        base = self.commit()
        self.add_agent_list_target()
        listed = (self.root / "scripts/ci/swift-linux-packages.txt").read_text(encoding="utf-8")
        write(self.root, "scripts/ci/swift-linux-packages.txt",
              listed + "# comment\nPackages/macOS/CmuxNext  CmuxNextOtherTests,CmuxNextAgentListTests"
              "  CMUX_SWIFTPM_TARGET_LINUX=1\n")
        self.commit()
        result = self.run_script("--base", base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("::error", result.stdout)

    def test_a_new_file_no_fast_tier_entry_covers_warns(self):
        base = self.commit()
        write(self.root, "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SidebarTests.swift",
              "import Testing\nstruct SidebarTests { @Test func a() {} }\n")
        self.commit()
        result = self.run_script("--base", base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SidebarTests.swift: a new test file in CmuxNextAppTests", result.stdout)

    def test_a_new_file_a_fast_tier_entry_names_does_not_warn(self):
        self.commit()
        write(self.root, "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/ModelTests.swift",
              "import Testing\nstruct ModelTests {\n  @Test func a() {}\n  @Test func b() {}\n}\n")
        self.git("rm", "-q", "--cached", "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/ModelTests.swift")
        self.git("commit", "-qm", "drop")
        base = self.git("rev-parse", "HEAD")
        self.commit()
        result = self.run_script("--base", base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("::warning", result.stdout)

    def test_an_unreadable_base_skips_with_a_warning(self):
        self.commit()
        result = self.run_script("--base", "0" * 40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("the new-target check is skipped", result.stdout)


if __name__ == "__main__":
    unittest.main()
