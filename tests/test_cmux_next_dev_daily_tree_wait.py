#!/usr/bin/env python3
"""cmux NEXT DEV daily runs build the app head against a published tree.

A DEV daily run builds exactly the SHA the dispatcher asked for. If its daemon
tree is cold, path routing falls back to the newest published compatible tree;
it does not wait for nightly's tree publisher.
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

    def test_dev_daily_probe_uses_the_newest_published_tree(self):
        steps = {step.get("name"): step for step in jobs()["path_route"]["steps"]}
        probe = steps["Probe the same-tree cmux-tui"]
        self.assertIn("inputs.dev_daily == true", probe["env"]["CMUX_TUI_TREE_BASE_FALLBACK"])
        fetch_steps = [
            step
            for job in jobs().values()
            for step in job.get("steps", [])
            if step.get("name") == "Fetch the same-tree cmux-tui"
        ]
        self.assertTrue(fetch_steps)
        self.assertTrue(any(
            "needs.path_route.outputs.tree_fetch_key" in step.get("env", {}).get("CMUX_TUI_TREE_KEY", "")
            for step in fetch_steps
        ))

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
