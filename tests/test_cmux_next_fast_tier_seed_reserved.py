"""A queued fast-tier seed holds its Blacksmith label against pull request placements.

cmux-next-fast-tier-seed.yml's job seeds the cache every PR's fast tier restores. On 2026-11-28 seed run
46139555693 queued 65 minutes on blacksmith-6vcpu-macos-26 behind PR jobs while those PRs built cold.
queue_janitor.RESERVED_POOL_WORKFLOW counts its queued job as `reserved_queued`, and next_macos_cascade gives a
reserved label to no PR job.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SEED = ".github/workflows/cmux-next-fast-tier-seed.yml"
SMALL = "blacksmith-6vcpu-macos-26"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class FastTierSeedReservesItsLabel(unittest.TestCase):
    def snapshot(self, path: str) -> dict:
        janitor = load_module("queue_janitor", ROOT / "scripts/ci/queue_janitor.py")
        runs = [{"id": 1, "name": "cmux-next fast-tier seed", "path": path}]
        jobs = {1: [{"labels": [SMALL], "status": "queued", "created_at": "2026-11-28T11:22:00Z",
                     "name": "Seed the fast-tier build cache"}]}
        now = dt.datetime(2026, 11, 28, 11, 40, tzinfo=dt.timezone.utc)
        return janitor.pool_load_snapshot(runs, jobs, now=now)["pools"][SMALL]

    def test_its_queued_seed_holds_the_label(self):
        held = self.snapshot(SEED)
        self.assertEqual((held["queued"], held["reserved_queued"]), (1, 1))

    def test_look_alike_workflows_hold_nothing(self):
        for path in (".github/workflows/my-cmux-next-fast-tier-seed.yml",
                     ".github/workflows/cmux-next-fast-tier-seed-shadow.yml",
                     ".github/workflows/cmux-next-fast-tier.yml"):
            self.assertEqual(self.snapshot(path)["reserved_queued"], 0, path)

    def test_a_held_label_goes_to_no_pull_request_job(self):
        cascade = load_module("next_macos_cascade", ROOT / "scripts/ci/next_macos_cascade.py")
        live, waiting = {cascade.LARGE: 0, SMALL: 0}, {SMALL: 1}
        self.assertEqual(cascade.cascade(["fast-tier"], live, waiting, reserved=(SMALL,))[SMALL], ())

    def test_the_seed_runs_on_the_label_it_reserves(self):
        workflow = yaml.safe_load((ROOT / SEED).read_text())
        text = json.dumps(workflow)
        self.assertIn(SMALL, text)
        self.assertEqual(Path(SEED).name, "cmux-next-fast-tier-seed.yml")


if __name__ == "__main__":
    unittest.main()
