"""The cmux-tui tree request job waits out the installation's API limit instead of failing.

Run 46170141626 (2026-11-28 17:24Z) was dispatched to publish the tree the NEXT nightly's signing step needs
("no published cmux-tui tree in the last 300 commits"); its first `gh api` runs listing got HTTP 403 "API rate
limit exceeded for installation" and the job ended without requesting anything. Every gh call in the job now
goes through scripts/ci/gh_budget_wait.sh, and the job's timeout covers the longest wait.
"""
from __future__ import annotations

from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-tree-request.yml"


class TreeRequestWaitsOutTheLimit(unittest.TestCase):
    def setUp(self) -> None:
        self.job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["request"]
        self.steps = self.job["steps"]

    def test_gh_budget_wait_is_installed_before_the_first_gh_call(self) -> None:
        runs = [str(s.get("run", "")) for s in self.steps]
        installs = [i for i, r in enumerate(runs) if "gh_budget_wait.sh --install" in r]
        callers = [i for i, r in enumerate(runs) if "gh api" in r or "gh run" in r]
        self.assertTrue(installs, "no step installs gh_budget_wait.sh")
        self.assertTrue(callers)
        self.assertLess(installs[0], callers[0])

    def test_the_checkout_holds_the_wrapper(self) -> None:
        checkout = next(s for s in self.steps if str(s.get("uses", "")).startswith("actions/checkout@"))
        self.assertIn("scripts/ci", str(checkout["with"].get("sparse-checkout", "")).split())
        self.assertTrue((ROOT / "scripts/ci/gh_budget_wait.sh").is_file())

    def test_the_wait_ends_inside_the_job(self) -> None:
        timeout = int(self.job["timeout-minutes"]) * 60
        for step in self.steps:
            env = step.get("env") or {}
            if "GH_TOKEN" in env:
                wait = int(env.get("GH_BUDGET_WAIT_MAX_SECONDS", 3600))
                self.assertLess(wait, timeout - 300, step.get("name"))


if __name__ == "__main__":
    unittest.main()
