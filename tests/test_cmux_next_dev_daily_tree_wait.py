#!/usr/bin/env python3
"""cmux NEXT DEV daily runs wait for their own cmux-tui tree, then build it.

A DEV daily run builds exactly the SHA the dispatcher asked for. A same-tree
run started later by the tree's publication runs only while feat-cmux-next's
tip is still that SHA, which a busy branch never is, so every DEV daily run
whose tree was cold published nothing (from 01:59Z on 2026-10-14).
"""

from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"


def jobs() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]


class DevDailyTreeWaitTests(unittest.TestCase):
    def test_a_deferred_dev_daily_run_waits_for_its_tree(self):
        wait = jobs()["dev-daily-tree-wait"]
        self.assertEqual(wait["needs"], "path_route")
        for clause in ("inputs.dev_daily == true", "inputs.same_tree_sha == ''",
                       "needs.path_route.outputs.tree_state == 'deferred'"):
            self.assertIn(clause, wait["if"])
        self.assertIn("ubuntu", wait["runs-on"])
        run = "\n".join(step.get("run", "") for step in wait["steps"])
        self.assertIn("scripts/cmux-next/wait-dev-daily-tree.sh", run)

    def test_the_dev_release_compile_runs_after_the_wait(self):
        compile_job = jobs()["cmux-scheme-compile"]
        self.assertIn("dev-daily-tree-wait", compile_job["needs"])
        self.assertIn("needs.dev-daily-tree-wait.outputs.tree_state == 'ready'", compile_job["if"])
        self.assertIn("needs.dev-daily-tree-wait.outputs.tree_fetch_key", compile_job["env"]["CMUX_TUI_TREE_KEY"])

    def test_a_dev_daily_run_leaves_no_same_tree_marker(self):
        steps = {step.get("name"): step for step in jobs()["path_route"]["steps"]}
        self.assertIn("inputs.dev_daily != true", steps["Write the tree wait marker"]["if"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
