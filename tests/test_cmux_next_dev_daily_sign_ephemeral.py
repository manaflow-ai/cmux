#!/usr/bin/env python3
"""cmux-next-dev-daily.yml's "Sign cmux NEXT DEV" signs only on ephemeral Blacksmith macOS.

main's copy of this workflow (the one a dispatch on main runs) signs on Blacksmith Linux and never reaches an owned
Mac. This copy picked a drained owned Mac on the side lane's label (vars.CI_SIDE_LANE_RUNNER) first. Those minis run
pull request jobs as the same macOS user, so DEV signing secrets could reach a mini a pull request had run on, once
main took this copy. Now:

1. The pick offers no owned Mac: its step has no ENABLED, OWNED_LABELS or ROUTE_TOKEN, so signing_runner.py's
   `owned` is always empty (owned_pick returns nothing unless ENABLED is 1).
2. sign's runs-on reads no repository variable and no owned output, and resolves to a Blacksmith macOS label (the
   pick's, or blacksmith-6vcpu-macos-26) on every attempt, whatever the pick wrote.
"""
from __future__ import annotations

import random
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ci_fork_runner_routing import parse_expression  # noqa: E402
from test_nightly_trusted_routing import evaluate  # noqa: E402

import yaml  # noqa: E402

WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/cmux-next-dev-daily.yml").read_text(encoding="utf-8"))
JOBS = WORKFLOW["jobs"]
BLACKSMITH_MAC = re.compile(r"blacksmith-\d+vcpu-macos-\d+")
REF = re.compile(r"\b(?:needs|vars|github|inputs)\.[A-Za-z0-9_.-]+")
# What the pick writes: runner and alternate a Blacksmith label (nightly_sign_runner.place) or nothing; owned an owned
# pin on the side lane's label, or nothing. A repository variable may hold the side lane's label.
BLACKSMITH = ("blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26", "")
OWNED = ('["glaeda-side-std-xcode-26.6","glaeda-runner-cmux12-glaeda"]', "")
SHARED = ("glaeda-side-std-xcode-26.6", "")


def sign_route() -> str:
    runs_on = str(JOBS["sign"]["runs-on"])
    runs_on = re.sub(r"github\.repository_owner != 'manaflow-ai' && '[^']*' \|\|", "", runs_on)
    return runs_on.strip().removeprefix("${{").removesuffix("}}").strip()


class DevDailySignIsEphemeral(unittest.TestCase):
    def test_the_pick_offers_no_owned_mac(self) -> None:
        step = next(step for step in JOBS["pick-sign-runner"]["steps"] if step.get("id") == "pick")
        for name in ("ENABLED", "OWNED_LABELS", "ROUTE_TOKEN"):
            with self.subTest(name=name):
                self.assertNotIn(name, step.get("env") or {})

    def test_sign_reads_no_variable_and_no_owned_pick(self) -> None:
        route = sign_route()
        self.assertNotRegex(route, r"\bvars\.")
        self.assertNotIn("outputs.owned", route)

    def test_sign_resolves_only_to_blacksmith_macos(self) -> None:
        route = sign_route()
        expression = parse_expression(route)
        rng = random.Random(20261105)
        for _ in range(500):
            context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": rng.choice((1, 2, 3))}
            for ref in set(REF.findall(route)):
                leaf = ref.rsplit(".", 1)[-1]
                context.setdefault(ref, rng.choice(OWNED if leaf == "owned" else
                                                   BLACKSMITH if ref.startswith("needs.") else SHARED))
            value = evaluate(expression, context)
            with self.subTest(context=context):
                self.assertIsInstance(value, str)
                self.assertTrue(BLACKSMITH_MAC.fullmatch(value), value)


if __name__ == "__main__":
    unittest.main()
