#!/usr/bin/env python3
"""The pr router's checkout reads the runner git mirror on a same-repo pull request.

A `filter: blob:none` checkout skips the mirror, and the router's sparse checkout then fetches each blob
from GitHub one by one: 57 to 81 s on every head (runs 45543236961, 45543159422, 45543119060,
45543118077), against about 13 s for pr-pipeline's whole-blob checkout of the same commits. A fork's
head, or any other event, keeps blob:none (note-559).

Leo, 2026-11-21: "help 100x ci speed ... lower wall time and lower machine time".

Run: python3 tests/test_ci_router_checkout_mirror.py
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/pr-router.yml"
# Only a pool VM has the mirror: the router's one-job VM (2026-11-26, off the cmux-linux queue) and a fork's runner
# keep blob:none, since an unfiltered depth-2 fetch from GitHub would pull every blob of the tree.
SAME_REPO_NO_FILTER = ("${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name"
                       " == github.repository && startsWith(runner.name, 'cmux-runner-pool-') && '' || 'blob:none' }}")


class RouterCheckoutReadsTheMirror(unittest.TestCase):
    def test_the_router_checkout_drops_the_blob_filter_on_a_same_repo_pull_request(self) -> None:
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        # The route job's sparse checkout is the one note-559 timed; ios-fast-status (#59926) checks out three
        # small files at depth 1 and has no mirror rule.
        checkouts = [step for step in jobs["route"].get("steps", [])
                     if str(step.get("uses", "")).startswith("actions/checkout@")]
        self.assertTrue(checkouts, "pr-router.yml has no checkout step")
        for step in checkouts:
            with self.subTest(step=step.get("name")):
                self.assertEqual(step.get("with", {}).get("filter"), SAME_REPO_NO_FILTER)


if __name__ == "__main__":
    unittest.main()
