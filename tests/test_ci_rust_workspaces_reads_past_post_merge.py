#!/usr/bin/env python3
"""A landing head still tests the workspaces that read a file it changes, under the post-merge tier.

The post-merge tier (scripts/ci/head_tier.py, CI_POST_MERGE_TIER_PR) gives rust-workspaces `none` on a feat-cmux-next
pull request head, and plan then planned nothing, not even the `--reads-only` workspaces the reads job exists for.
#63394, #63368 and #64613 changed cmux-tui/spec/sdk-schema.json and acpmux-protocol.json, never ran
cmux-mobile-host's phone_api_contract test (which reads both) and left feat-cmux-next red until #65473.

This checks:
- plan keeps planning --reads-only when the tier is the post-merge tier's none (other none tiers still plan nothing);
- no run workspace reads the whole tree (a CARGO_MANIFEST_DIR root join needs a `// affected-reads:` list), so
  that plan stays a few workspaces, not every one on every landing head;
- the two specs plan cmux-next-ios/rust.

Run: python3 tests/test_ci_rust_workspaces_reads_past_post_merge.py
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "rust-workspaces.yml"


def planner():
    spec = importlib.util.spec_from_file_location("rust_workspaces", ROOT / ".github" / "scripts" / "rust-workspaces.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def step(job: str, step_id: str) -> dict:
    jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
    return next(s for s in jobs[job]["steps"] if s.get("id") == step_id)


class ReadsPastPostMergeTier(unittest.TestCase):
    def test_tier_step_writes_its_reason(self):
        run = step("plan", "tier")["run"]
        self.assertIn("scripts/ci/head_tier.py\n", run + "\n", "the tier step must write reason= (head_tier.py, no argument)")
        self.assertNotIn("head_tier.py tier)", run)

    def test_post_merge_none_still_plans_reads_only(self):
        plan = step("plan", "plan")
        self.assertEqual(plan["env"].get("TIER_REASON"), "${{ steps.tier.outputs.reason }}")
        run = plan["run"]
        branch = run.index('"$TIER_REASON" == "post-merge tier"*')
        self.assertLess(branch, run.index('elif [[ "$TIER" == none ]]'), "the post-merge branch must come first")
        self.assertIn('"$OWN_ONLY" == --reads-only', run[branch:branch + 200])

    def test_no_workspace_reads_the_whole_tree(self):
        module = planner()
        tree = module.Tree(ROOT)
        whole = []
        for entry in module.load_list(ROOT):
            if entry.get("run") is not True:
                continue
            own = tree.members(entry["root"]) | {entry["root"]}
            broad = {p for p in tree.read_paths(own) if p == "." or p in ("cmux-tui", "cmux-next-ios", "cmux-tui/crates")}
            if broad:
                whole.append(f"{entry['root']}: {sorted(broad)}")
        self.assertEqual(whole, [], "list the files a root join reads in a `// affected-reads:` comment")

    def test_phone_contract_inputs_plan_the_ios_workspace(self):
        module = planner()
        for path in ("cmux-tui/spec/sdk-schema.json", "cmux-tui/crates/acpmux/spec/acpmux-protocol.json"):
            roots = [job["root"] for job in module.plan_paths(ROOT, [path], reads_only=True)]
            self.assertIn("cmux-next-ios/rust", roots, path)


if __name__ == "__main__":
    unittest.main()
