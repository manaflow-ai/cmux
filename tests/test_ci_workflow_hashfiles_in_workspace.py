#!/usr/bin/env python3
"""No workflow gates a step on hashFiles() of a path outside the workspace.

hashFiles() matches only files under GITHUB_WORKSPACE. It answers '' for runner.temp, RUNNER_TEMP, /tmp or
any absolute path, even when the file is there. So a `hashFiles('<runner.temp>/x') != ''` gate never
fires. swift-linux-packages.yml handed its Linux failures to the Mac fallback that way: the handoff
step was skipped on every run, and a red Linux suite (CmuxAuthRuntime, CmuxPhonePush, CmuxTabsKit on
2026-11-26) passed the run green with no Mac rerun.

A failure names the file and line. Test the file in the step's shell (`[[ -s "$RUNNER_TEMP/x" ]] || exit 0`
and set an output), or give upload-artifact `if-no-files-found: ignore`.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
OUTSIDE = re.compile(r"hashFiles\([^)]*(runner\.temp|RUNNER_TEMP|['\"]/)")


def findings(paths: list[Path]) -> list[str]:
    out = []
    for path in sorted(paths):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if OUTSIDE.search(line):
                rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
                out.append(
                    f"{rel}:{number}: hashFiles() of a path outside the workspace is always '': "
                    f"test the file in the step's shell, or use upload-artifact's if-no-files-found: ignore")
    return out


class HashFilesInWorkspace(unittest.TestCase):
    def test_no_workflow_hashes_a_path_outside_the_workspace(self) -> None:
        paths = [*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]
        self.assertTrue(paths)
        self.assertEqual(findings(paths), [])

    def test_the_detector_catches_the_runner_temp_gate(self) -> None:
        sample = ROOT / "tests" / "_hashfiles_sample.yml"
        try:
            sample.write_text(
                "steps:\n"
                "  - if: always() && hashFiles(format('{0}/linux-failed.tsv', runner.temp)) != ''\n"
                "  # hashFiles(format('{0}/x', runner.temp)) in a comment is fine\n"
                "  - if: hashFiles('**/Package.resolved') != ''\n")
            self.assertEqual(len(findings([sample])), 1)
        finally:
            sample.unlink()


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
