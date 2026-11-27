#!/usr/bin/env python3
"""The pull request jobs that compile or lint Rust start from the live base, not GitHub's stale merge ref.

Leo, 2026-11-27: "shouldn't a build check fail beforehand fast like fast-fail is useful ci all stuff". cmux#51044's
web preflight passed on a merge commit 73 min behind the base and the head broke the base. Every job below checks out
the pull_request merge commit and diffs against its first parent, so each takes the same step right after checkout.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
USES = "- name: Merge the head onto the live base"
JOBS = (
    (".github/workflows/cmux-next.yml", "fast-tier-cargo"),
    (".github/workflows/cmux-tui-spec.yml", "rustfmt"),
    (".github/workflows/cmux-tui-spec.yml", "clippy"),
)


def job_block(text: str, job: str) -> str:
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  \S|\Z)", text, re.M | re.S)
    if not match:
        raise AssertionError(f"no job {job}")
    return match.group(1)


class LiveBaseJobs(unittest.TestCase):
    def test_each_job_merges_onto_the_live_base_right_after_checkout(self) -> None:
        for path, job in JOBS:
            with self.subTest(job=job):
                block = job_block((ROOT / path).read_text(), job)
                self.assertIn(USES, block)
                self.assertLess(block.index("actions/checkout@"), block.index(USES))
                # Before the first step that reads the diff against the base.
                for later in ("List the changed paths", "Fetch the comparison base", "Install Linux build dependencies"):
                    if later in block:
                        self.assertLess(block.index(USES), block.index(later), later)

    def test_the_step_only_runs_on_pull_requests_and_calls_the_helper(self) -> None:
        for path, job in JOBS:
            with self.subTest(job=job):
                block = job_block((ROOT / path).read_text(), job)
                step = block[block.index(USES):]
                step = step[: step.index("\n\n")] if "\n\n" in step else step
                self.assertIn("github.event_name == 'pull_request'", step)
                self.assertIn("compile_preflight.py merge-live-base . \"$BASE_REF\" \"$PR_NUMBER\"", step)
                self.assertIn("github.event.pull_request.base.ref", step)


if __name__ == "__main__":
    unittest.main()
