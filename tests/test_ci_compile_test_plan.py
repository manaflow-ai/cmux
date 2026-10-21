#!/usr/bin/env python3
"""The fleet compile check compiles the test targets a change can break.

fleet/compile-check compiled only the app executable. On 2026-10-21 two pull
requests passed it and then broke feat-cmux-next's test build: #23360 put a
throwing call inside `#expect` without `try` in PaletteMenuVocabularyTests
(CmuxNextActionsTests), and #23163 added a FakeClient to CmuxNextAppTests that
missed a requirement #21258 had added. Every Mac job that builds tests was
still queued when they merged.

scripts/ci/compile_test_plan.py picks what the check compiles from the
changed files: the CmuxNext test targets that depend on a changed target (the
SwiftPM target graph cmux_next_route.py already reads), and the macOS-tested
local packages whose sources or path dependencies changed. package-test-lane.sh
`compile-tests MERGE_BASE` builds that plan on a fleet Mac, as the advisory
fleet-test-compile.yml check; fleet/compile-check stays the app compile.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "compile_test_plan.py"
LANE = ROOT / "scripts" / "ci" / "package-test-lane.sh"
CMUXNEXT = "Packages/macOS/CmuxNext"

# #23360's diff against its base (ef40118cea25..4f867f5e57c2).
PR_23360 = [
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionCatalog.xcstrings",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/AppStoreActions.xcstrings",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/AppStoreActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/BrowserActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/CloudActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/HistoryActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/RemoteActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/WorkspaceActionCatalog.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/HistoryActions.xcstrings",
    "Packages/macOS/CmuxNext/Sources/CmuxNextActions/RemoteActions.xcstrings",
    "Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/PaletteMenuVocabularyTests.swift",
    "plans/cmux-next/palette-audit.md",
]


def load():
    spec = importlib.util.spec_from_file_location("compile_test_plan", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["compile_test_plan"] = module
    spec.loader.exec_module(module)
    return module


class CompileTestPlanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load()

    def plan(self, changed: list[str]) -> dict[str, list[str] | None]:
        return dict(self.module.plan(ROOT, changed))

    def test_pr_23360_compiles_the_test_target_it_broke(self) -> None:
        plan = self.plan(PR_23360)
        self.assertIn(CMUXNEXT, plan)
        targets = plan[CMUXNEXT]
        self.assertIsNotNone(targets, "a CmuxNextActions change is not every test target")
        self.assertIn("CmuxNextActionsTests", targets)
        # Test targets that depend on CmuxNextActions are reverse dependents: they compile too.
        self.assertIn("CmuxNextAppTests", targets)
        # One that does not reach CmuxNextActions stays out.
        graph = self.module.load_graph(ROOT)
        unrelated = [
            name for name, target in graph["targets"].items()
            if target["kind"] == "test" and "CmuxNextActions" not in self.module.closure(graph, {name})
        ]
        self.assertTrue(unrelated, "every test target depends on CmuxNextActions; pick another fixture")
        self.assertFalse(set(unrelated) & set(targets), unrelated)
        self.assertEqual(targets, sorted(targets))

    def test_a_new_test_file_compiles_its_own_target(self) -> None:
        # #23163: the FakeClient in a new CmuxNextAppTests file.
        plan = self.plan([f"{CMUXNEXT}/Tests/CmuxNextAppTests/RemoteChildSessionsTests.swift"])
        self.assertEqual(plan, {CMUXNEXT: ["CmuxNextAppTests"]})

    def test_manifest_change_compiles_every_test_target(self) -> None:
        self.assertEqual(self.plan([f"{CMUXNEXT}/Package.swift"]), {CMUXNEXT: None})

    def test_local_package_change_compiles_it_and_its_dependents(self) -> None:
        plan = self.plan(["Packages/Shared/CMUXAuthCore/Sources/CMUXAuthCore/AuthTokens.swift"])
        # CMUXAuthCore and CmuxAuthRuntime are in the macOS package lane; CmuxNext uses both.
        self.assertIsNone(plan.get("Packages/Shared/CMUXAuthCore", "missing"))
        self.assertIsNone(plan.get("Packages/Shared/CmuxAuthRuntime", "missing"))
        self.assertIn(CMUXNEXT, plan)
        self.assertTrue(plan[CMUXNEXT], "the CmuxNext test targets that use CMUXAuthCore")

    def test_packages_outside_the_macos_lanes_are_not_compiled(self) -> None:
        # iOS packages build in the iOS jobs, not with a macOS `swift build`.
        plan = self.plan(["Packages/iOS/CmuxTabsKit/Sources/CmuxTabsKit/Tabs.swift"])
        self.assertNotIn("Packages/iOS/CmuxTabsKit", plan)

    def test_changes_that_compile_no_test_are_an_empty_plan(self) -> None:
        self.assertEqual(self.plan(["docs/ci/merge-freeze.md", "web/app/page.tsx", "README.md"]), {})
        self.assertEqual(self.plan([f"{CMUXNEXT}/README.md"]), {})
        # CI and app-host changes compile no package test: the advisory check queues no Mac.
        self.assertEqual(self.plan(["scripts/ci/cmux_next_route.py", "scripts/cmux-next/prepush-gate.py",
                                    "App/CmuxNextApp.swift", "webviews/src/app.tsx"]), {})

    def test_cli_prints_one_line_per_package(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            changed = Path(scratch) / "changed.txt"
            changed.write_text("\n".join(PR_23360) + "\n", encoding="utf-8")
            done = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(ROOT), "--changed-files", str(changed)],
                capture_output=True, text=True, check=True,
            )
        lines = done.stdout.splitlines()
        self.assertEqual(len(lines), 1, done.stdout)
        words = lines[0].split()
        self.assertEqual(words[0], CMUXNEXT)
        self.assertIn("CmuxNextActionsTests", words[1:])


class CompileTestsPhaseArgsTests(unittest.TestCase):
    """package-test-lane.sh compile-tests refuses a bad merge base before it builds anything."""

    def run_lane(self, *args: str) -> subprocess.CompletedProcess:
        env = {key: value for key, value in os.environ.items() if not key.startswith("GITHUB_")}
        return subprocess.run(["bash", str(LANE), "compile-tests", *args], cwd=ROOT, env=env,
                              capture_output=True, text=True, timeout=60)

    def test_needs_one_full_merge_base_sha(self) -> None:
        for args in ((), ("abc123",), ("A" * 40,), ("0" * 40, "extra")):
            done = self.run_lane(*args)
            self.assertEqual(done.returncode, 2, (args, done.stdout, done.stderr))
            self.assertIn("compile-tests MERGE_BASE_SHA", done.stderr)


if __name__ == "__main__":
    unittest.main()
