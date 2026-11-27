#!/usr/bin/env python3
"""A tree owner whose latest attempt ended in startup_failure still hands its key on.

2026-11-25: run 45706112297 deferred tree 37e3abb5b26582fab648e8518e5fe260062e43ff to owner run 45704131744. The
owner's latest attempt ended in startup_failure: no job ran, so its notify-unpublished-tree hand-off never fired,
the deferred run was never re-run, and the nightly-next tick refused every commit of that tree. The feat-cmux-next
sweep job now finds such owners and runs the same hand-off for them.

Run: python3 tests/test_cmux_tui_stranded_owner_sweep.py
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux_tui_stranded_owner_sweep.py"
WORKFLOW = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
KEY = "37e3abb5b26582fab648e8518e5fe260062e43ff"
OTHER = "d65ec728a5e4d6e819e95e46cdd94bb8a7fe00fb"
NOW = datetime(2026, 11, 25, 23, 30, tzinfo=timezone.utc)


def load():
    sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("stranded_owner_sweep", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(run_id, conclusion, *, hours_ago=1.0, status="completed", attempt=2):
    created = (NOW - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"id": run_id, "status": status, "conclusion": conclusion, "run_attempt": attempt,
            "created_at": created, "head_branch": "feat-cmux-next"}


def artifact(name, *, expired=False):
    return {"name": name, "expired": expired}


class StrandedOwnersTest(unittest.TestCase):
    def test_only_completed_startup_failures_within_the_marker_lifetime(self):
        sweep = load()
        runs = [run(1, "startup_failure"), run(2, "failure"), run(3, "success"),
                run(4, None, status="in_progress"), run(5, "startup_failure", hours_ago=30),
                run(6, "startup_failure", hours_ago=2), run(7, "startup_failure")]
        self.assertEqual(sweep.stranded_owners(runs, self_run=7, now=NOW), [1, 6])

    def test_keys_come_from_the_owner_markers(self):
        sweep = load()
        artifacts = [artifact(f"cmux-tui-tree-owner-{KEY}"), artifact(f"cmux-tui-tree-feat-builder-{KEY}"),
                     artifact(f"cmux-tui-tree-owner-{OTHER}", expired=True), artifact("cmux-tui-x86_64"),
                     artifact(f"cmux-tui-tree-deferred-{OTHER}"), artifact("cmux-tui-tree-owner-not-a-key")]
        self.assertEqual(sweep.owner_keys(artifacts), [KEY])


class SweepTest(unittest.TestCase):
    def test_the_stranded_owner_hands_its_key_on(self):
        sweep = load()
        reads, handed = [], []
        pages = {
            "repos/o/r/actions/workflows/cmux-tui-artifacts.yml/runs": [run(45704131744, "startup_failure"),
                                                                        run(45706112297, "success")],
            "repos/o/r/actions/runs/45704131744/artifacts": [artifact(f"cmux-tui-tree-owner-{KEY}")],
        }

        def api(path, key):
            reads.append(path)
            return pages[path.split("?")[0]]

        sweep.sweep("o/r", self_run=99, now=NOW, api=api, hand_off=lambda *a: handed.append(a))
        self.assertEqual(handed, [("o/r", 45704131744, KEY)])
        self.assertIn("branch=feat-cmux-next", reads[0])

    def test_one_failed_hand_off_does_not_stop_the_next_owner(self):
        sweep = load()
        handed = []
        pages = {
            "repos/o/r/actions/workflows/cmux-tui-artifacts.yml/runs": [run(11, "startup_failure"),
                                                                        run(12, "startup_failure")],
            "repos/o/r/actions/runs/11/artifacts": [artifact(f"cmux-tui-tree-owner-{KEY}")],
            "repos/o/r/actions/runs/12/artifacts": [artifact(f"cmux-tui-tree-owner-{OTHER}")],
        }

        def hand_off(repo, owner, key):
            handed.append(owner)
            if owner == 11:
                raise RuntimeError("refused")

        failed = sweep.sweep("o/r", self_run=99, now=NOW, api=lambda p, k: pages[p.split("?")[0]], hand_off=hand_off)
        self.assertEqual(handed, [11, 12])
        self.assertEqual(len(failed), 1)

    def test_a_bounded_number_of_owners_per_sweep(self):
        sweep = load()
        runs = [run(i, "startup_failure") for i in range(1, 20)]
        self.assertEqual(len(sweep.stranded_owners(runs, self_run=0, now=NOW)), sweep.MAX_OWNERS)


class WorkflowTest(unittest.TestCase):
    def test_the_feat_cmux_next_sweep_job_runs_it(self):
        steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["sweep-pending-tree-notify"]["steps"]
        runs = [s for s in steps if "cmux_tui_stranded_owner_sweep.py" in str(s.get("run", ""))]
        self.assertEqual(len(runs), 1)
        env = runs[0].get("env", {})
        self.assertIn("GH_TOKEN", env)
        self.assertIn("GH_TOKEN_SPARE", env)


if __name__ == "__main__":
    unittest.main(verbosity=2)
