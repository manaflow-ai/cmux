#!/usr/bin/env python3
"""owned_shard_placement.py puts post-admission consumers on free minis first."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))

import owned_shard_placement as placement  # noqa: E402

STD = "glaeda-std-xcode-26.6"
LIGHT = "glaeda-light-xcode-26.6"
XCODE = "/Applications/Xcode_26.6.app"
BASE_ENV = {
    "EVENT_NAME": "pull_request", "HEAD_REPO": "manaflow-ai/cmux", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
    "GITHUB_RUN_ATTEMPT": "1", "POOL_OWNED": "1", "XCODE_APP": XCODE, "GH_TOKEN": "token",
    "OWNED_SLOTS": json.dumps({STD: 5, LIGHT: 3}), "SHARDS": "[1,2,3,4,5,6,7]", "CLI": "true",
    "RUNNER_NAME": "cmux15-glaeda",
}


def job(label, status="in_progress", runner="other"):
    return {"labels": [label], "status": status, "runner_name": runner}


class Placement(unittest.TestCase):
    def run_main(self, jobs, **env):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp, "out")
            with unittest.mock.patch.object(placement, "in_flight_jobs", return_value=jobs), \
                    unittest.mock.patch("sys.stdout"):
                placement.main({**BASE_ENV, "GITHUB_OUTPUT": str(out), **env})
            line = out.read_text().strip()
        self.assertTrue(line.startswith("placement="), line)
        return json.loads(line.removeprefix("placement="))

    def test_idle_minis_take_every_consumer_std_then_light(self):
        got = self.run_main([])
        self.assertEqual([got[str(n)] for n in range(1, 6)], [STD] * 5)
        self.assertEqual([got["6"], got["7"], got["cli"]], [LIGHT] * 3)

    def test_only_what_does_not_fit_overflows(self):
        # 3 std busy elsewhere, 1 light busy, this job's own mini is free.
        jobs = [[job(STD), job(STD), job(STD, "queued"), job(STD, runner="cmux15-glaeda")],
                [job(LIGHT), job("blacksmith-6vcpu-macos-26")]]
        got = self.run_main(jobs)
        self.assertEqual(got, {"1": STD, "2": STD, "3": LIGHT, "4": LIGHT})

    def test_changed_suites_shard_and_no_cli(self):
        self.assertEqual(self.run_main([], SHARDS="[8]", CLI="false"), {"8": STD})

    def test_nothing_placed_when_not_allowed(self):
        for env in ({"EVENT_NAME": "workflow_dispatch"}, {"HEAD_REPO": "someone/cmux"},
                    {"GITHUB_RUN_ATTEMPT": "2"}, {"POOL_OWNED": ""}, {"XCODE_APP": "/Applications/Xcode_26.3.app"},
                    {"OWNED_SLOTS": ""}):
            self.assertEqual(self.run_main([], **env), {}, env)

    def test_a_failed_read_places_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp, "out")
            with unittest.mock.patch.object(placement, "in_flight_jobs", side_effect=RuntimeError("500")), \
                    unittest.mock.patch("sys.stdout"):
                placement.main({**BASE_ENV, "GITHUB_OUTPUT": str(out)})
            self.assertEqual(out.read_text(), "placement={}\n")

    def test_in_flight_jobs_lists_each_run_once(self):
        client = unittest.mock.Mock()
        pages = {
            "/actions/runs?status=in_progress&per_page=100&page=1": {"workflow_runs": [{"id": 1}, {"id": 2}]},
            "/actions/runs?status=queued&per_page=100&page=1": {"workflow_runs": [{"id": 2}]},
            "/actions/runs/1/jobs?filter=latest&per_page=100&page=1": {"jobs": [job(STD)]},
            "/actions/runs/2/jobs?filter=latest&per_page=100&page=1": {"jobs": [job(LIGHT)]},
        }
        client.get.side_effect = lambda path: pages.get(path, {})
        self.assertEqual(placement.in_flight_jobs(client), [[job(STD)], [job(LIGHT)]])


if __name__ == "__main__":
    unittest.main()
