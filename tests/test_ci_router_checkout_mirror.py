#!/usr/bin/env python3
"""The pr router's and the fast gates' checkouts read the runner git mirror on a same-repo pull request.

A `filter: blob:none` checkout skips the mirror, and the router's sparse checkout then fetches each blob
from GitHub one by one: 57 to 81 s on every head (runs 45543236961, 45543159422, 45543119060,
45543118077), against about 13 s for pr-pipeline's whole-blob checkout of the same commits. A fork's
head, or any other event, keeps blob:none (note-559).

cmux-next-fast-gates.yml's three checkouts (resolve, fast check route, the gates) had the same filter: on
2026-11-25 the gates' checkout took 1.6 to 5.3 min on the heads the fast-gates status ended (the NOW verdict
wall's top check, 10 of 20 heads), against 17 s for pr-pipeline's unfiltered checkout.

Leo, 2026-11-21: "help 100x ci speed ... lower wall time and lower machine time".

Run: python3 tests/test_ci_router_checkout_mirror.py
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = (ROOT / ".github/workflows/pr-router.yml", ROOT / ".github/workflows/cmux-next-fast-gates.yml")
SAME_REPO_NO_FILTER = ("${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name"
                       " == github.repository && '' || 'blob:none' }}")


class RouterCheckoutReadsTheMirror(unittest.TestCase):
    def test_each_checkout_drops_the_blob_filter_on_a_same_repo_pull_request(self) -> None:
        for workflow in WORKFLOWS:
            jobs = yaml.safe_load(workflow.read_text())["jobs"]
            checkouts = [step for job in jobs.values() for step in job.get("steps", [])
                         if str(step.get("uses", "")).startswith("actions/checkout@")
                         and "filter" in step.get("with", {})]
            self.assertTrue(checkouts, f"{workflow.name} has no filtered checkout step")
            for step in checkouts:
                with self.subTest(workflow=workflow.name, step=step.get("name")):
                    self.assertEqual(step.get("with", {}).get("filter"), SAME_REPO_NO_FILTER)


if __name__ == "__main__":
    unittest.main()
