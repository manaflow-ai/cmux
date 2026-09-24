#!/usr/bin/env python3
"""A main push skips the seed build only when a seed with its inputs exists."""
from pathlib import Path
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import seed_decide  # noqa: E402

REPO = "manaflow-ai/cmux"


def run(run_id, sha, status="completed", conclusion="success"):
    return {"id": run_id, "head_sha": sha, "status": status, "conclusion": conclusion}


def seed_job(conclusion="success", status="completed", saved=True):
    steps = [{"name": "Save seed", "conclusion": "success" if saved else "skipped"}]
    return {"name": "seed", "status": status, "conclusion": conclusion, "steps": steps}


class Api:
    def __init__(self, runs, jobs):
        self.runs, self.jobs, self.calls = runs, jobs, []

    def __call__(self, path):
        self.calls.append(path)
        if "/workflows/" in path:
            return {"workflow_runs": self.runs}
        run_id = int(path.split("/runs/")[1].split("/")[0])
        return {"jobs": self.jobs.get(run_id, [])}


def decide(api, ancestors, prints, event="push"):
    return seed_decide.decide(
        event, REPO, "Xcode.app", api=api,
        ancestors=lambda: ancestors,
        fingerprint_of=lambda revision, _xcode: prints[revision],
    )


class Decide(unittest.TestCase):
    def test_a_replaced_parent_with_other_inputs_does_not_let_a_docs_push_skip(self):
        # p1 changed the app but its pending run was replaced; p2 is seeded.
        api = Api([run(3, "p1", conclusion="cancelled"), run(2, "p2")], {2: [seed_job()]})
        build, reason = decide(api, ["p1", "p2"], {"HEAD": "app-v2", "p1": "app-v2", "p2": "app-v1"})
        self.assertTrue(build, reason)
        self.assertIn("p2", reason)

    def test_inputs_equal_to_the_nearest_seed_skip(self):
        api = Api([run(2, "p1")], {2: [seed_job()]})
        build, reason = decide(api, ["p1"], {"HEAD": "app-v1", "p1": "app-v1"})
        self.assertFalse(build, reason)

    def test_a_chain_of_skipped_pushes_is_compared_with_the_seed_behind_it(self):
        api = Api([run(3, "p1"), run(2, "p2")], {3: [seed_job("skipped")], 2: [seed_job()]})
        self.assertFalse(decide(api, ["p1", "p2"], {"HEAD": "v1", "p2": "v1"})[0])
        self.assertTrue(decide(api, ["p1", "p2"], {"HEAD": "v2", "p2": "v1"})[0])

    def test_a_seed_being_built_counts_but_a_pending_run_does_not(self):
        running = Api([run(2, "p1", status="in_progress", conclusion=None)],
                      {2: [seed_job(conclusion=None, status="in_progress")]})
        self.assertFalse(decide(running, ["p1"], {"HEAD": "v1", "p1": "v1"})[0])
        pending = Api([run(2, "p1", status="pending", conclusion=None), run(1, "p2")], {1: [seed_job()]})
        build, reason = decide(pending, ["p1", "p2"], {"HEAD": "v1", "p1": "v1", "p2": "v0"})
        self.assertTrue(build, reason)

    def test_a_seed_that_was_not_saved_does_not_count(self):
        api = Api([run(2, "p1")], {2: [seed_job(saved=False)]})
        build, reason = decide(api, ["p1"], {"HEAD": "v1", "p1": "v1"})
        self.assertTrue(build, reason)

    def test_no_seeded_ancestor_or_an_api_error_builds(self):
        self.assertTrue(decide(Api([], {}), ["p1"], {"HEAD": "v1", "p1": "v1"})[0])

        def broken(_path):
            raise OSError("network")
        self.assertTrue(decide(broken, ["p1"], {"HEAD": "v1"})[0])

    def test_a_dispatch_always_builds(self):
        api = Api([run(2, "p1")], {2: [seed_job()]})
        self.assertTrue(decide(api, ["p1"], {"HEAD": "v1", "p1": "v1"}, event="workflow_dispatch")[0])


class Wiring(unittest.TestCase):
    def test_decide_uses_the_nearest_seed_with_enough_history(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/seed-derived-data.yml").read_text())
        decide_job = workflow["jobs"]["decide"]
        checkout = decide_job["steps"][0]
        self.assertGreater(checkout["with"]["fetch-depth"], seed_decide.ANCESTOR_LIMIT)
        run_text = "\n".join(step.get("run", "") for step in decide_job["steps"])
        self.assertIn("scripts/ci/seed_decide.py", run_text)
        self.assertNotIn("HEAD^1", run_text)
        self.assertEqual(decide_job["permissions"]["actions"], "read")


if __name__ == "__main__":
    unittest.main()
