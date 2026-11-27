#!/usr/bin/env python3
"""nightly.yml stays under the size GitHub will start.

GitHub refuses a workflow file over 512,000 bytes before any job starts: the run fails with
no jobs and only "This run likely failed because of a workflow file issue" (2026-10-27, push
runs 40422918338 and 40424952395 at 518,322 bytes; a comment-padded copy at 512,100 bytes
failed the same way, one at 511,900 did not). Steps repeated across jobs are written once as
YAML anchors to stay under it; this keeps headroom for the next change.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
GITHUB_LIMIT = 512_000
HEADROOM = 4_000  # a PR's worth of new steps, so the limit is found here, not on a nightly


class NightlyWorkflowSize(unittest.TestCase):
    def test_under_githubs_limit_with_headroom(self) -> None:
        size = WORKFLOW.stat().st_size
        self.assertLess(size, GITHUB_LIMIT - HEADROOM,
                        f"nightly.yml is {size} bytes; GitHub starts nothing over {GITHUB_LIMIT}. "
                        "Reuse a repeated step with a YAML anchor (&name / *name) or move logic into a script.")

    def test_every_alias_has_its_anchor_earlier_in_the_file(self) -> None:
        text = WORKFLOW.read_text()
        seen: set[str] = set()
        for match in re.finditer(r"(?m)^\s+- ([&*])([A-Za-z0-9-]+)\s*$", text):
            kind, name = match.groups()
            if kind == "&":
                self.assertNotIn(name, seen, f"anchor &{name} is defined twice")
                seen.add(name)
            else:
                self.assertIn(name, seen, f"alias *{name} comes before its anchor")
        yaml.safe_load(text)  # an alias to a missing anchor does not parse


if __name__ == "__main__":
    unittest.main()
