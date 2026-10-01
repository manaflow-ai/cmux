#!/usr/bin/env python3
"""Passing guard tests print no GitHub workflow commands.

The runner reads every line of a step's output that starts with `::` as a
workflow command, so a fixture that makes a script under test print
`::error::...` becomes a red annotation on the pull request's run page even
though the test passed. PR 15160's run 36420353579 showed "No ci-ui-tests.yml
run titled 'UI tests for CI run 100 attempt 1' appeared" and "https://x/900
ended success without running the UI tests" from test_ci_ui_tests_dispatch.py,
which read as real CI failures.

Each module below exercises code that annotates on purpose. It runs here the
way the guard job runs it, with GITHUB_ACTIONS set, and its output must hold
no line the runner would parse as a command. A module that fails is left to
its own step to report: a failing test's captured output may annotate.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Guard tests whose scripts under test print annotations.
ANNOTATING_MODULES = (
    "tests/test_ci_helper_prebuild_lifecycle.py",
    "tests/test_ci_late_placement.py",
    "tests/test_ci_main_regression_bisect.py",
    "tests/test_ci_parallel_artifact_transport.py",
    "tests/test_ci_pr_media.py",
    "tests/test_ci_prune_pr_media.py",
    "tests/test_ci_ui_tests_dispatch.py",
    "tests/test_ios_upload_batching.py",
)

# unittest's progress characters share stderr with the script's output, so a
# command may follow them on one line of the combined log; the runner reads
# stdout and stderr as separate streams, where it starts the line.
COMMAND = re.compile(r"^\s*[.EFsxu]*::(?:error|warning|notice|debug|group|endgroup|add-mask|stop-commands|echo"
                     r"|set-output|save-state|set-env|add-path|add-matcher|remove-matcher)\b")


def run_module(relative: str) -> tuple[int, str]:
    """Exit code and combined output. Files, not pipes: a descendant a test
    leaves behind would hold a pipe open and hang the read."""
    env = {**os.environ, "GITHUB_ACTIONS": "true"}
    env.pop("GITHUB_OUTPUT", None)
    env.pop("GITHUB_STEP_SUMMARY", None)
    with tempfile.TemporaryFile("w+") as output:
        code = subprocess.run([sys.executable, str(ROOT / relative)], cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                              stdout=output, stderr=output, timeout=600, check=False).returncode
        output.seek(0)
        return code, output.read()


class GuardTestsEmitNoWorkflowCommandsTests(unittest.TestCase):
    def test_passing_guard_tests_print_no_workflow_commands(self) -> None:
        with ThreadPoolExecutor(max_workers=len(ANNOTATING_MODULES)) as pool:
            results = dict(zip(ANNOTATING_MODULES, pool.map(run_module, ANNOTATING_MODULES)))
        checked = 0
        for relative, result in results.items():
            code, output = result
            with self.subTest(module=relative):
                if code != 0:
                    # Its own step reports the failure; say which module this check skipped.
                    self.skipTest(f"{relative} failed here (exit {code}), so its output was not checked")
                checked += 1
                leaked = [line for line in output.splitlines() if COMMAND.match(line)]
                # repr() quotes each line, so this report is never read as a command itself.
                self.assertFalse(leaked, f"{relative} printed workflow commands:\n"
                                 + "\n".join(repr(line) for line in leaked[:10]))
        self.assertGreater(checked, 0, "no annotating guard test passed, so nothing was checked")


if __name__ == "__main__":
    unittest.main(buffer=True)
