#!/usr/bin/env python3
"""Workflow files stay under GitHub's workflow file size limit.

GitHub refuses a workflow file over about 512,000 bytes: every run of it fails
at startup with no jobs ("This run likely failed because of a workflow file
issue"). nightly.yml reached 512,052 bytes with #25807 and every nightly push
failed that way until the revert. nightly.yml keeps a margin under the limit so
one more job does not break it again; move a step's script into
scripts/ci/nightly-steps/ (or a job into a reusable workflow) to make room.
"""
from __future__ import annotations

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
GITHUB_LIMIT = 512_000
NIGHTLY_CAP = 490_000


class WorkflowFileSizeTest(unittest.TestCase):
    def test_nightly_keeps_a_margin_under_the_limit(self):
        size = (WORKFLOWS / "nightly.yml").stat().st_size
        self.assertLess(
            size,
            NIGHTLY_CAP,
            f"nightly.yml is {size} bytes; keep it under {NIGHTLY_CAP} (GitHub refuses about {GITHUB_LIMIT}). "
            "Move a run block into scripts/ci/nightly-steps/ to make room.",
        )

    def test_every_workflow_is_under_the_github_limit(self):
        files = sorted(WORKFLOWS.glob("*.y*ml"))
        self.assertTrue(files)
        too_big = {p.name: p.stat().st_size for p in files if p.stat().st_size >= GITHUB_LIMIT}
        self.assertEqual(too_big, {}, f"over GitHub's {GITHUB_LIMIT}-byte workflow file limit")


if __name__ == "__main__":
    unittest.main()
