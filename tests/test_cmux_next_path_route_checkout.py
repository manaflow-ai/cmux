#!/usr/bin/env python3
"""cmux-next.yml path_route: its checkout survives a slow GitHub, and the breaker still decides after it.

2026-11-25 from 12Z: path routing's actions/checkout failed 702 times ("Operation too slow", "could not fetch ...
from promisor remote"; 8 on 11-24). A failed path_route leaves its outputs empty, so the base-red breaker's
`base_red_jobs` was empty and cargo ran in full on red-base PRs: 2,211 min that day. The checkout is tried three
times with a fresh .git and a backoff, inside a bound. Cargo still runs when all three fail: with path routing
failed, cargo found 107 reds on green-base PRs (of 303 finished), so skipping it would let reds into the base.
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"


class PathRouteCheckout(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        cls.route = cls.jobs["path_route"]
        cls.steps = cls.route["steps"]

    def checkouts(self) -> list[dict]:
        return [s for s in self.steps if str(s.get("uses", "")).startswith("actions/checkout@")]

    def test_three_bounded_tries_of_the_same_checkout(self) -> None:
        first, again, last = self.checkouts()
        self.assertEqual(self.steps[0], first, "the checkout stays the first step")
        for step in (first, again, last):
            self.assertEqual(step["uses"], first["uses"])
            self.assertEqual(step["with"], first["with"])
            self.assertTrue(0 < step.get("timeout-minutes", 0) <= 3, step.get("id"))
        self.assertTrue(first.get("continue-on-error"))
        self.assertTrue(again.get("continue-on-error"))
        self.assertFalse(last.get("continue-on-error"), "a third failure fails path routing: a red check, not silence")
        self.assertEqual(again["if"], f"steps.{first['id']}.outcome == 'failure'")
        self.assertEqual(last["if"], f"steps.{first['id']}.outcome == 'failure' && steps.{again['id']}.outcome == 'failure'")

    def test_each_retry_starts_from_a_fresh_git_after_a_wait(self) -> None:
        _, again, last = self.checkouts()
        waits = 0
        for retry in (again, last):
            before = self.steps[self.steps.index(retry) - 1]
            self.assertEqual(before.get("if"), retry["if"])
            self.assertIn('rm -rf "$GITHUB_WORKSPACE/.git"', before["run"])
            self.assertIn("sleep ", before["run"])
            waits += int(before["run"].split("sleep ")[1].split()[0])
        tries = sum(s["timeout-minutes"] for s in self.checkouts())
        self.assertLess(tries + waits / 60 + 4, self.route["timeout-minutes"], "the tries fit the job's bound")

    def test_the_breaker_decides_even_when_routing_fails(self) -> None:
        step = next(s for s in self.steps if s.get("id") == "base-red")
        self.assertTrue(str(step["if"]).startswith("${{ !cancelled() &&"), step["if"])
        self.assertTrue(step.get("continue-on-error"))
        self.assertIn("steps.base-red.outputs.red_jobs", self.route["outputs"]["base_red_jobs"])

    def test_cargo_keeps_its_coverage_when_routing_fails(self) -> None:
        gate = str(self.jobs["fast-tier-cargo"]["if"])
        self.assertIn("!cancelled()", gate)
        self.assertNotIn("needs.path_route.result", gate, "a failed path route must not skip cargo: it finds real reds")


if __name__ == "__main__":
    unittest.main()
