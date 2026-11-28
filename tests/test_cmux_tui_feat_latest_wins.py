#!/usr/bin/env python3
"""feat-cmux-next tree publishing is latest-wins: the tip publishes first, stale queued runs take no runner.

Leo: "if i wait for the nightly then i might as well just update to the thing".

2026-11-19 17:03Z: runners were back, but the owned lane label handed them out oldest first to about
240 queued feat-cmux-next push runs (the oldest from 11-11), so channels/mac-live.json moved to
edbc6c85 (committed 2026-11-18 18:56Z), about 22 h behind, and none of the last 10 feat-cmux-next
commits had a cmux-tui/<sha>/mac-live.json. The newest commit's mac-live.json lists the older commits
in live_from, so an older commit's own publication is worth nothing once a newer one publishes.

1. tree-preflight: attempt 1 of a feat-cmux-next push shares one job concurrency group with
   cancel-in-progress false (GitHub keeps one admitted, replaces the pending one); a dispatch, a
   nightly-next push, a lane push and a re-run each get a group of their own (a nightly still gets
   its exact commit's tree), and the run-level group stays per commit.
2. supersede-feat-runs cancels the older feat-cmux-next push runs no runner took (runs an older
   definition started, which the group cannot replace), and never a started run, a dispatch or a
   re-run (scripts/ci/cmux_tui_feat_supersede.py decide()).

Run: python3 tests/test_cmux_tui_feat_latest_wins.py
"""
from __future__ import annotations

import importlib.util
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
SCRIPT = ROOT / "scripts/ci/cmux_tui_feat_supersede.py"

spec = importlib.util.spec_from_file_location("cmux_tui_feat_supersede", SCRIPT)
supersede = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supersede)


def jobs():
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]


def preflight_group(event: str, ref: str, attempt: int, run_id: int = 7) -> str:
    """tree-preflight's group expression, evaluated for one run (its only operators: ==, &&, ||, format)."""
    expr = jobs()["tree-preflight"]["concurrency"]["group"]
    body = re.fullmatch(r"\$\{\{(.*)\}\}", expr.strip(), re.S).group(1)
    shared = re.fullmatch(
        r"\s*github\.event_name == 'push' && github\.ref == 'refs/heads/feat-cmux-next' && "
        r"github\.run_attempt == 1 && '([^']+)' \|\| format\('([^']+)', github\.run_id, github\.run_attempt\)\s*", body)
    assert shared, f"unexpected tree-preflight group: {expr}"
    if event == "push" and ref == "refs/heads/feat-cmux-next" and attempt == 1:
        return shared.group(1)
    return shared.group(2).replace("{0}", str(run_id)).replace("{1}", str(attempt))


class PreflightGroup(unittest.TestCase):
    def test_feat_pushes_share_one_group_and_never_cancel_a_started_one(self):
        concurrency = jobs()["tree-preflight"]["concurrency"]
        self.assertIs(concurrency["cancel-in-progress"], False)
        self.assertEqual(preflight_group("push", "refs/heads/feat-cmux-next", 1, 1),
                         preflight_group("push", "refs/heads/feat-cmux-next", 1, 2))

    def test_dispatches_nightly_lanes_and_reruns_stay_outside(self):
        shared = preflight_group("push", "refs/heads/feat-cmux-next", 1)
        for event, ref, attempt in (("workflow_dispatch", "refs/heads/feat-cmux-next", 1),
                                    ("push", "refs/heads/nightly-next", 1),
                                    ("push", "refs/heads/lane/x", 1),
                                    ("push", "refs/heads/main", 1),
                                    ("push", "refs/heads/feat-cmux-next", 2)):
            with self.subTest(event=event, ref=ref, attempt=attempt):
                own = preflight_group(event, ref, attempt, 11)
                self.assertNotEqual(own, shared)
                self.assertNotEqual(own, preflight_group(event, ref, attempt, 12))

    def test_the_run_level_group_stays_per_commit(self):
        group = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["concurrency"]["group"]
        self.assertIn("format('push-{0}', github.sha)", group)

    def test_supersede_job_is_feat_push_only_and_sweeps_once_per_window(self):
        job = jobs()["supersede-feat-runs"]
        # Only the push whose coalesce window runs sweeps; a failed coalesce (empty output) still does, and
        # vars.NEXT_TUI_SUPERSEDE_EVERY_PUSH = '1' sweeps on every push again.
        self.assertEqual(job.get("needs"), "coalesce")
        self.assertIn("!cancelled()", job["if"])
        self.assertIn("needs.coalesce.outputs.run != 'false'", job["if"])
        self.assertIn("vars.NEXT_TUI_SUPERSEDE_EVERY_PUSH", job["if"])
        self.assertIs(job["continue-on-error"], True)
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", job["if"])
        self.assertIn("github.event_name == 'push'", job["if"])
        self.assertIn("github.run_attempt == 1", job["if"])
        self.assertEqual(job["permissions"], {"actions": "write", "contents": "read"})
        self.assertNotIn("cmux-gcp-lane-build-x64", job["runs-on"])


def run(**overrides):
    base = {"id": 100, "event": "push", "head_branch": "feat-cmux-next", "run_attempt": 1, "status": "queued",
            "head_sha": "a" * 40, "created_at": "2026-11-19T08:00:00Z"}
    return {**base, **overrides}


CURRENT = run(id=200, head_sha="b" * 40, created_at="2026-11-19T16:48:27Z", status="in_progress")
QUEUED_PREFLIGHT = {"name": "cmux-tui tree preflight", "status": "queued", "conclusion": None,
                    "runner_name": None, "runner_id": None, "steps": []}


class Decide(unittest.TestCase):
    def test_an_older_never_started_feat_push_is_cancelled(self):
        # Run 44560264985 (8d6746b282, 15:55Z): its preflight queued on cmux-gcp-lane-build-x64, no runner.
        cancel, reason = supersede.decide(run(), [QUEUED_PREFLIGHT], CURRENT)
        self.assertTrue(cancel, reason)
        # A run still pending in its concurrency group has no jobs yet.
        self.assertTrue(supersede.decide(run(status="pending"), [], CURRENT)[0])
        skipped = {**QUEUED_PREFLIGHT, "name": "refuse cmux-tui pin ref", "status": "completed", "conclusion": "skipped"}
        self.assertTrue(supersede.decide(run(), [skipped, QUEUED_PREFLIGHT], CURRENT)[0])

    def test_a_started_run_is_never_cancelled(self):
        for job in ({**QUEUED_PREFLIGHT, "runner_name": "cmux-gcp-lane-build-x64-3", "status": "in_progress"},
                    {**QUEUED_PREFLIGHT, "runner_id": 41},
                    {**QUEUED_PREFLIGHT, "steps": [{"name": "Set up job"}]},
                    {**QUEUED_PREFLIGHT, "status": "completed", "conclusion": "success"}):
            with self.subTest(job=job):
                self.assertFalse(supersede.decide(run(), [job, QUEUED_PREFLIGHT], CURRENT)[0])

    def test_only_older_attempt_one_feat_pushes_at_another_commit(self):
        for overrides in ({"event": "workflow_dispatch"}, {"head_branch": "nightly-next"},
                          {"head_branch": "lane/x"}, {"run_attempt": 2}, {"status": "completed"},
                          {"head_sha": "b" * 40}, {"id": 300}, {"id": 200},
                          {"created_at": "2026-11-19T17:00:00Z"}):
            with self.subTest(overrides=overrides):
                self.assertFalse(supersede.decide(run(**overrides), [QUEUED_PREFLIGHT], CURRENT)[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
