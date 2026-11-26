#!/usr/bin/env python3
"""The tree path's checkouts retry once after a stalled github.com fetch.

Owner run 45704131744 (2026-11-25 22:05Z) lost its tree when the pool runners' fetches stalled
("Operation too slow", "RPC failed; curl 28", a blob:none "could not fetch ... from promisor
remote"); every commit deferred to it then stayed refused by the nightly-next tick.
"""
from __future__ import annotations

from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
# The jobs that build or key a cmux-tui tree: one failed checkout there leaves the tree unpublished.
TREE_PATH = {
    "cmux-tui-artifacts.yml": ["tree-preflight"],
    "cmux-tui-build-package.yml": ["build", "build-windows", "build-windows-acpmux", "package"],
}


def steps(workflow: str, job: str) -> list[dict]:
    return yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8"))["jobs"][job]["steps"]


class TreePathCheckoutRetryTests(unittest.TestCase):
    def test_every_tree_path_checkout_retries_once_from_a_fresh_git(self):
        for workflow, jobs in TREE_PATH.items():
            for job in jobs:
                with self.subTest(workflow=workflow, job=job):
                    listed = steps(workflow, job)
                    checkouts = [i for i, s in enumerate(listed) if str(s.get("uses", "")).startswith("actions/checkout@")]
                    self.assertEqual(len(checkouts), 2, "one checkout and its one retry")
                    first, retry = (listed[i] for i in checkouts)
                    self.assertEqual(first.get("id"), "checkout")
                    self.assertIs(first.get("continue-on-error"), True)
                    self.assertEqual(retry.get("if"), "steps.checkout.outcome == 'failure'")
                    self.assertNotIn("continue-on-error", retry, "a second failure fails the job")
                    self.assertEqual(retry["uses"], first["uses"])
                    self.assertEqual(retry["with"], first["with"])
                    between = listed[checkouts[0] + 1:checkouts[1]]
                    self.assertTrue(any('rm -rf "$GITHUB_WORKSPACE/.git"' in str(s.get("run", ""))
                                        and s.get("if") == "steps.checkout.outcome == 'failure'" for s in between),
                                    "the retry starts from a fresh .git, not the stalled partial clone")


if __name__ == "__main__":
    unittest.main(verbosity=2)
