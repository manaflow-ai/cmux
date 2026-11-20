#!/usr/bin/env python3
"""No job gated on `always()` in a run its concurrency group can cancel.

A cancelled run still schedules its `if: always()` jobs; on a saturated label
they queue for hours and the run keeps its concurrency group, so the newer
run waits `pending` with no jobs (cmux#46109's clippy, 7 h, 2026-11-19;
cmuxterm-hq#14963). The check lives in
scripts/ci/check_always_in_cancellable_runs.py.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/check_always_in_cancellable_runs.py"
SPEC = importlib.util.spec_from_file_location("check_always_in_cancellable_runs", SCRIPT)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = guard
SPEC.loader.exec_module(guard)


def scan(files: dict[str, str]) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name, text in files.items():
            (root / name).write_text(textwrap.dedent(text), encoding="utf-8")
        return guard.scan(root)


# The shape of rust-workspaces.yml before the fix.
RUST_WORKSPACES = """\
    name: rust workspaces
    on: [pull_request]
    concurrency:
      group: rust-workspaces-${{ github.ref }}
      cancel-in-progress: ${{ github.event_name == 'pull_request' }}
    jobs:
      workspace:
        runs-on: ubuntu-24.04
        steps: [{run: "true"}]
      summary:
        name: rust workspaces
        needs: [workspace]
        if: ${{ CONDITION }}
        runs-on: blacksmith-8vcpu-ubuntu-2404
        steps:
          - if: always()
            run: "true"
"""


class NoAlwaysInCancellableRunsTests(unittest.TestCase):
    def test_checked_in_workflows_pass(self) -> None:
        self.assertEqual(guard.scan(), [])

    def test_always_summary_in_cancel_in_progress_run_is_refused(self) -> None:
        found = scan({"rust-workspaces.yml": RUST_WORKSPACES.replace("CONDITION", "always()")})
        self.assertEqual(len(found), 1)
        self.assertIn("rust-workspaces.yml: job `summary`", found[0])
        self.assertIn("!cancelled()", found[0])

    def test_always_inside_a_larger_condition_is_refused(self) -> None:
        found = scan({"w.yml": RUST_WORKSPACES.replace("CONDITION", "always() && needs.workspace.result != 'skipped'")})
        self.assertEqual(len(found), 1)

    def test_not_cancelled_passes_and_step_always_is_ignored(self) -> None:
        for condition in ("!cancelled()", "always() && !cancelled()", "!cancelled() && github.event_name == 'push'"):
            with self.subTest(condition=condition):
                self.assertEqual(scan({"w.yml": RUST_WORKSPACES.replace("CONDITION", condition)}), [])

    def test_run_that_cannot_cancel_is_not_checked(self) -> None:
        text = RUST_WORKSPACES.replace("CONDITION", "always()")
        literal_false = text.replace("${{ github.event_name == 'pull_request' }}", "false")
        self.assertEqual(scan({"w.yml": literal_false}), [])
        # An expression is not literally false: the check cannot prove it never cancels.
        expression = text.replace("${{ github.event_name == 'pull_request' }}", "${{ false }}")
        self.assertEqual(len(scan({"w.yml": expression})), 1)
        no_group = "\n".join(
            line for line in text.splitlines() if "concurrency" not in line and "group:" not in line and "cancel-in-progress" not in line
        )
        self.assertEqual(scan({"w.yml": no_group}), [])

    def test_reusable_workflow_called_from_a_cancellable_run_is_checked(self) -> None:
        caller = """\
            on: [pull_request]
            concurrency:
              group: ci-${{ github.ref }}
              cancel-in-progress: true
            jobs:
              web:
                uses: ./.github/workflows/web.yml
        """
        callee = """\
            on: {workflow_call: {}}
            jobs:
              rollup:
                if: always()
                runs-on: ubuntu-24.04
                steps: [{run: "true"}]
        """
        found = scan({"ci.yml": caller, "web.yml": callee})
        self.assertEqual(len(found), 1)
        self.assertIn("web.yml: job `rollup`", found[0])
        self.assertEqual(scan({"web.yml": callee}), [])

    def test_reasoned_marker_keeps_a_cleanup_job(self) -> None:
        text = RUST_WORKSPACES.replace("CONDITION", "always()").replace(
            "      summary:\n", "      summary:\n        # runs-after-cancel: releases the lease the cancelled job took\n"
        )
        self.assertEqual(scan({"w.yml": text}), [])
        empty = RUST_WORKSPACES.replace("CONDITION", "always()").replace(
            "      summary:\n", "      summary:\n        # runs-after-cancel:\n"
        )
        self.assertEqual(len(scan({"w.yml": empty})), 1)

    def test_marker_in_another_job_does_not_cover_this_one(self) -> None:
        text = RUST_WORKSPACES.replace("CONDITION", "always()").replace(
            "      workspace:\n", "      workspace:\n        # runs-after-cancel: not this job\n"
        )
        self.assertEqual(len(scan({"w.yml": text})), 1)


if __name__ == "__main__":
    unittest.main()
