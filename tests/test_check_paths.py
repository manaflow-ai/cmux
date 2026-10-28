#!/usr/bin/env python3
"""scripts/ci/check-paths.txt: the check paths a merger reads to tell a stale fast-gates result.

next-autoland and gh-merge-green read the file from the base they merge into. When a file that
changed on the base after a pull request's `cmux-next/fast-gates` base matches a pattern, they
dispatch the fast gates against the current tip before merging (2026-10-21: #22967, #22975 and
#23094 merged after #23365 added check:fixed-waits, never ran it, and turned it red on the base).

Each pattern must match a tracked file, so a renamed check never silently drops out; #23365's
check files match; a pull request's ordinary source files do not.
"""
from __future__ import annotations

import fnmatch
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECK_PATHS = ROOT / "scripts/ci/check-paths.txt"


def patterns() -> list[str]:
    lines = CHECK_PATHS.read_text(encoding="utf-8").splitlines()
    return [line.strip() for line in lines if line.strip() and not line.lstrip().startswith("#")]


def matching(files: list[str]) -> list[str]:
    return [path for path in files if any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns())]


class CheckPaths(unittest.TestCase):
    def test_every_pattern_matches_a_tracked_file(self):
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files"], check=True, capture_output=True,
                                 text=True).stdout.splitlines()
        for pattern in patterns():
            with self.subTest(pattern=pattern):
                self.assertTrue(any(fnmatch.fnmatchcase(path, pattern) for path in tracked), pattern)

    def test_the_check_that_landed_under_three_merges_is_a_check_path(self):
        # #23365's files: the base changed these after #22975's CI, and none was #22975's.
        landed = [".github/workflows/ci-web.yml", "webviews/package.json", "webviews/scripts/check-fixed-waits.ts",
                  "webviews/scripts/fixed-waits-baseline.tsv", "webviews/test/check-fixed-waits.test.ts",
                  "webviews/test/support/pageSwitch.ts"]
        self.assertEqual(matching(landed), landed[:4])

    def test_ordinary_source_files_are_not_check_paths(self):
        # #22975's own files: a source change makes no other pull request's result stale.
        files = ["Packages/CmuxNextAgents/Sources/AcpmuxPaneMethods+Params.swift",
                 "cmux-tui/crates/cmux-agent-pane-policy/policy.json",
                 "webviews/src/agent-session/acpmux/App.tsx",
                 "webviews/src/agent-session/acpmux/ComposerQueue.test.tsx",
                 "webviews/src/agent-session/acpmux/composerStates.css",
                 "scripts/cmux-next/build-web-bundles.sh", "docs/ci.md", "web/app/page.tsx"]
        self.assertEqual(matching(files), [])

    def test_the_checks_and_workflows_are_covered(self):
        for path in ("scripts/check-pbxproj.sh", "scripts/ci/check-bash32-parse.sh",
                     "scripts/cmux-next/check-layers.py", "scripts/cmux-next/layers-baseline.tsv",
                     ".github/workflows/cmux-next-fast-gates.yml", "scripts/ci/cmux_next_fast_gates.py",
                     "scripts/ci/fast_gate_webviews_checks.py"):
            self.assertEqual(matching([path]), [path], path)

    def test_every_fast_gate_script_is_a_check_path(self):
        # A change to a gate on the base changes what the gate enforces on every open pull request.
        source = (ROOT / "scripts/ci/cmux_next_fast_gates.py").read_text(encoding="utf-8")
        scripts = sorted(set(re.findall(r'"(scripts/[\w./-]+\.(?:py|sh))"', source)))
        self.assertGreaterEqual(len(scripts), 6, scripts)  # the defaults-stamp gate left with the committed stamp
        self.assertEqual(matching(scripts), scripts)
        self.assertEqual(matching(["scripts/ci/crash-class-gate.sh", "webviews/src/protocol/codegen/ir.ts",
                                   "webviews/scripts/acpmux-protocol-codegen.ts", "scripts/cmux-next/lint/swiftlint.yml",
                                   "web/.oxlintrc.json", "scripts/lint-namespace-types-baseline.txt",
                                   "scripts/cmux-next/crash-allowlist.json", "config/vite-plus/check.ts"]),
                         ["scripts/ci/crash-class-gate.sh", "webviews/src/protocol/codegen/ir.ts",
                          "webviews/scripts/acpmux-protocol-codegen.ts", "scripts/cmux-next/lint/swiftlint.yml",
                          "web/.oxlintrc.json", "scripts/lint-namespace-types-baseline.txt",
                          "scripts/cmux-next/crash-allowlist.json", "config/vite-plus/check.ts"])

    def test_only_the_workflows_a_dispatch_reruns(self):
        # Another workflow's change is churn a dispatch cannot catch: the fast gates rerun only their own gates.
        self.assertEqual(matching([".github/workflows/nightly.yml", ".github/workflows/cmux-next.yml"]), [])


if __name__ == "__main__":
    unittest.main()
