#!/usr/bin/env python3
"""A superseded lane-branch push of cmux-tui artifacts never waits for a Blacksmith runner.

Leo, 2026-11-18: "why does cmux-tui artifacts keep sitting pending?"

At 06:35Z 418 cmux-tui artifacts runs sat queued, the oldest since 11-17 22:00Z, each
waiting for a Blacksmith Linux runner for tree-preflight. 164 of them (39%) were already
superseded (a moved or deleted branch, or a head no open pull request had), which
tree-preflight's stale step finds only once it has that runner.

1. push-gate runs the same superseded check (scripts/ci/cmux_tui_superseded_push.py,
   the same command and environment as tree-preflight's stale step) on the one-minute
   control pool (RUNNER_POOLS.linux_2), holding no secret, and never fails the run.
2. It runs only for lane-branch pushes: trunk and integration refs, which the check
   never supersedes, skip it.
3. tree-preflight needs push-gate, still runs when the gate is skipped or failed
   (!cancelled()), and stops only on the gate's stale=true. Every other job hangs off
   tree-preflight, so a superseded push takes no Blacksmith runner at all.

Run: python3 tests/test_cmux_tui_superseded_gate.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
SCRIPT = "scripts/ci/cmux_tui_superseded_push.py"
# Refs the superseded check never supersedes: they skip the gate.
TRUNK = ("refs/heads/main", "refs/heads/feat-cmux-next", "refs/heads/nightly-next",
         "refs/heads/release-next", "refs/heads/feat-cmux-next-cloud-dev-stack",
         "refs/heads/next-batch/42", "refs/heads/rc/0.70", "refs/heads/cmux-tui-pin-abc")
LANES = ("refs/heads/lane/fix-thing", "refs/heads/scratch/probe", "refs/heads/perf/x", "refs/heads/leo/y")


def jobs() -> dict:
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]


def step(job: dict, step_id: str) -> dict:
    found = [s for s in job["steps"] if s.get("id") == step_id]
    assert len(found) == 1, step_id
    return found[0]


def gate_runs(condition: str, event: str, ref: str, repository: str = "manaflow-ai/cmux") -> bool:
    """Evaluate the gate's `if:`, a conjunction of ==, != and startsWith terms."""
    body = condition.strip()
    body = body[3:-2].strip() if body.startswith("${{") else body
    values = {"github.event_name": event, "github.ref": ref, "github.repository": repository}
    for term in (t.strip() for t in body.split("&&")):
        m = re.fullmatch(r"(!?)startsWith\((github\.\w+), '([^']*)'\)", term)
        if m:
            hit = values[m.group(2)].startswith(m.group(3))
            if hit == (m.group(1) == "!"):
                return False
            continue
        m = re.fullmatch(r"(github\.\w+) (==|!=) '([^']*)'", term)
        assert m, f"push-gate's if: has a term this test cannot read: {term}"
        if (values[m.group(1)] == m.group(3)) != (m.group(2) == "=="):
            return False
    return True


class SupersededGateTest(unittest.TestCase):
    def test_the_gate_runs_the_preflight_check_on_the_control_pool_without_secrets(self) -> None:
        all_jobs = jobs()
        gate, preflight = all_jobs["push-gate"], all_jobs["tree-preflight"]
        # The one-minute control pool, never GitHub-hosted (its queue waited hours on 2026-11-18).
        self.assertEqual(gate["runs-on"],
                         "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_2 }}")
        self.assertNotIn("environment", gate, "the gate must hold no secret")
        self.assertEqual(gate.get("continue-on-error"), "true", "a failed gate must not fail the run")
        mine, theirs = step(gate, "stale"), step(preflight, "stale")
        self.assertIn(SCRIPT, mine["run"])
        self.assertEqual(mine["run"], theirs["run"])
        self.assertEqual(mine["env"], theirs["env"])
        self.assertTrue(all("secrets." not in str(v) for v in mine["env"].values()))
        checkout = gate["steps"][0]["with"]
        self.assertIn(SCRIPT, checkout["sparse-checkout"])
        self.assertEqual(gate["outputs"]["stale"], "${{ steps.stale.outputs.stale }}")

    def test_only_lane_branch_pushes_take_the_gate(self) -> None:
        condition = jobs()["push-gate"]["if"]
        for ref in TRUNK:
            with self.subTest(ref=ref):
                self.assertFalse(gate_runs(condition, "push", ref))
        for ref in LANES:
            with self.subTest(ref=ref):
                self.assertTrue(gate_runs(condition, "push", ref))
                self.assertFalse(gate_runs(condition, "workflow_dispatch", ref))
                self.assertFalse(gate_runs(condition, "push", ref, "someone-else/cmux"))

    def test_preflight_waits_for_the_gate_and_stops_only_on_stale(self) -> None:
        preflight = jobs()["tree-preflight"]
        needs = preflight["needs"]
        self.assertIn("push-gate", [needs] if isinstance(needs, str) else needs)
        condition = preflight["if"]
        self.assertIn("!cancelled()", condition, "a skipped gate (trunk, dispatch) must not skip preflight")
        self.assertIn("needs.push-gate.outputs.stale != 'true'", condition)
        self.assertNotIn("needs.push-gate.result", condition, "a failed gate must not skip preflight")

    def test_no_other_job_starts_before_preflight(self) -> None:
        for name, job in jobs().items():
            # coalesce (base-coalesce.yml) is the other upfront gate: one 2 vCPU job, as push-gate.
            if name in ("push-gate", "coalesce", "tree-preflight", "reject-untrusted-pin-ref"):
                continue
            with self.subTest(job=name):
                self.assertIn("needs", job, f"{name} would start beside the gate and take a runner")


if __name__ == "__main__":
    unittest.main()
