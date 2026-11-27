#!/usr/bin/env python3
"""ci/steps.toml's nightly-guards step: a pull request that changes a nightly or cmux-tui workflow runs the
release-notary guards it can break, before the merge (scripts/ci/nightly_guard_steps.py).

The replay: the culprits whose guard reds showed only on the feat-cmux-next push. On their merge commits the
pull request pipeline routed r2-upload, cache-receipts and security-holes, none of which runs a release-notary
guard, and ci-guard-group (Tier B pull_request_skip) was skipped. Each now routes nightly-guards, and its pick
holds the guard steps that went red."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import ci_steps  # noqa: E402
import nightly_guard_steps  # noqa: E402
import run_ci_guards  # noqa: E402

# Each culprit's workflow changes (its merged diff, .github/ part) and the release-notary steps it turned red.
CULPRITS = {
    "#54859": ([".github/workflows/nightly.yml"],
               ["Validate the nightly signing jobs take a Blacksmith label with a moving queue",
                "Validate universal nightly workflow",
                "Validate every nightly step has a pull request counterpart"]),
    "#56394": ([".github/workflows/nightly.yml"],
               ["Validate every nightly job runs on our own Mac minis and the publishers hold the whole Mac",
                "Validate the nightly signing jobs take a Blacksmith label with a moving queue"]),
    "#53840": ([".github/workflows/app-store-shelf.yml", ".github/workflows/nightly.yml"],
               ["Validate every nightly step has a pull request counterpart"]),
    "#53861": ([".github/workflows/cmux-tui-artifacts.yml", ".github/workflows/cmux-tui-build-package.yml",
                ".github/workflows/nightly-next-tick.yml", ".github/workflows/nightly.yml"],
               ["Validate nightly API tag finalization", "Validate universal nightly workflow"]),
    "#55067": ([".github/workflows/cmux-tui-artifacts.yml"],
               ["Validate that recovery jobs run after a timeout",
                "Validate superseded cmux-tui pushes skip their builds and daemon tests"]),
}


class NightlyGuardsStep(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.table = ci_steps.load()
        cls.steps = nightly_guard_steps.release_notary_steps()

    def test_every_culprit_routes_the_step_and_picks_its_red_guards(self) -> None:
        for culprit, (paths, reds) in CULPRITS.items():
            with self.subTest(culprit=culprit):
                self.assertIn("nightly-guards", ci_steps.route(self.table, paths).get("linux", []))
                picked = nightly_guard_steps.pick(self.steps, paths)
                for name in reds:
                    self.assertIn(name, picked)

    def test_a_change_outside_the_nightly_workflows_does_not_route_it(self) -> None:
        for paths in (["web/app/page.tsx"], ["Sources/cmux/App.swift"], ["docs/x.md"]):
            with self.subTest(paths=paths):
                self.assertNotIn("nightly-guards", ci_steps.route(self.table, paths).get("linux", []))

    def test_the_guard_files_route_it(self) -> None:
        for path in (".github/nightly-step-coverage.json", "tests/test_nightly_owned_minis_only.py",
                     "tests/test_cmux_tui_superseded_push.py", ".github/workflows/nightly-sign.yml",
                     "tests/test_ci_recovery_runs_after_a_timeout.py"):
            with self.subTest(path=path):
                self.assertIn("nightly-guards", ci_steps.route(self.table, [path]).get("linux", []))

    def test_it_runs_release_notary_steps_and_none_that_hands_state(self) -> None:
        workflow = run_ci_guards.load_yaml(ROOT / ".github/workflows/ci-guards.yml")
        group = {s.name for u in run_ci_guards.plan(workflow, "BASE_SHA", "HEAD") if u.group == "release-notary"
                 for s in u.steps}
        names = {step.name for step in self.steps}
        self.assertTrue(names)
        self.assertLessEqual(names, group)
        self.assertFalse([s.name for s in self.steps if run_ci_guards.hands_state(s)])

    def test_no_change_list_picks_every_step(self) -> None:
        self.assertEqual(set(nightly_guard_steps.pick(self.steps, None)), {s.name for s in self.steps})


if __name__ == "__main__":
    unittest.main()
