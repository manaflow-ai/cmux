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
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/pr-router.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))
from pr_test_lanes import Expression


def checkout_filter(step, event, head_repo):
    value = step.get("with", {}).get("filter", "")
    if value.startswith("${{") and value.endswith("}}"):
        return Expression(value[3:-2], {
            "github.event_name": event,
            "github.repository": "manaflow-ai/cmux",
            "github.event.pull_request.head.repo.full_name": head_repo,
        }).evaluate()
    return value


class RouterCheckoutReadsTheMirror(unittest.TestCase):
    def test_the_router_checkout_drops_the_blob_filter_on_a_same_repo_pull_request(self) -> None:
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        checkouts = [step for job in jobs.values() for step in job.get("steps", [])
                     if str(step.get("uses", "")).startswith("actions/checkout@")]
        self.assertTrue(checkouts, "pr-router.yml has no checkout step")
        for step in checkouts:
            with self.subTest(step=step.get("name")):
                self.assertEqual(checkout_filter(step, "pull_request", "manaflow-ai/cmux"), "")
                # An explicit filter preserves blob:none for forks and non-PR events.
                if "filter" in step.get("with", {}):
                    self.assertEqual(checkout_filter(step, "pull_request", "contributor/fork"), "blob:none")
                    self.assertEqual(checkout_filter(step, "push", "manaflow-ai/cmux"), "blob:none")

    def test_an_empty_true_operand_does_not_disable_the_filter(self):
        broken = {"with": {"filter": "${{ true && '' || 'blob:none' }}"}}
        self.assertEqual(checkout_filter(broken, "pull_request", "manaflow-ai/cmux"), "blob:none")


if __name__ == "__main__":
    unittest.main()
