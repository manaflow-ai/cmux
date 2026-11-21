#!/usr/bin/env python3
"""The runner census carries a large runner group as per-label-set counts, and placement reads them as runners.

The census (CI_RUNNER_STATE, published by cmuxterm-hq runner_state.py) lists every approved runner by row. The
cmux-fleet-linux group grew to about 3,676 registrations (3,582 online, 2026-11-21): over the reader's 2,000-row
cap per list and the 48 KiB variable, and 37 pages a refresh against the publisher's budget of 10 reads. The census
has not been published since 2026-11-20 12:37Z. Without it every placement reads runners live from the routing
App (4 to 12 calls) and the queue snapshot from the job's GITHUB_TOKEN (2 calls), the hour the production promote
gates share.

Placement reads only a Linux runner's status, busy flag, os and labels, so the publisher can send that group as
`runner_group_tallies`: for each exact (os, labels) set, how many runners are idle, busy and offline. The reader
validates the tallies as strictly as rows and expands them into the same rows, so every placement rule is
unchanged. A group with tallies is read from its tallies only (its rows, if any, stay for older readers). The
required mini group stays rows: placement uses each mini's runner names.
"""

from __future__ import annotations

import base64
import datetime as dt
import gzip
import importlib
import json
import os
import sys
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
pool = importlib.import_module("pr_runner_pool")
placement = importlib.import_module("portable_job_placement")
fast_checks = importlib.import_module("fast_checks_runner")

# The census reader checks freshness against the real clock, so the documents are dated from it.
NOW = dt.datetime.now(dt.timezone.utc)
LINUX = "cmux-fleet-linux"
FLEET = "cmux-fleet-linux-x64"
LINUX_LABELS = ["self-hosted", "Linux", "X64", FLEET]
MINI = {"id": 10, "name": "cmux-mini-1-glaeda", "os": "macOS", "status": "online", "busy": False,
        "labels": [{"name": "glaeda-std-xcode-26.6"}]}


def tally(idle: int, busy: int, offline: int, labels=None, os_name: str = "Linux") -> dict:
    return {"os": os_name, "labels": list(LINUX_LABELS if labels is None else labels), "idle": idle, "busy": busy, "offline": offline}


def document(tallies: dict | None, groups: dict | None = None) -> dict:
    doc = {"schema": pool.RUNNER_STATE_SCHEMA, "repository": "manaflow-ai/cmux", "complete": True,
           "generated_at": (NOW - dt.timedelta(seconds=30)).isoformat().replace("+00:00", "Z"),
           "repository_runners": [], "runner_groups": groups or {pool.RUNNER_GROUP: [MINI]}, "scale_sets": {}}
    if tallies is not None:
        doc["runner_group_tallies"] = tallies
    return doc


def encode(doc: dict) -> str:
    """The publisher's encoding: sorted compact JSON, gzip, base64."""
    body = json.dumps(doc, separators=(",", ":"), sort_keys=True).encode()
    return base64.b64encode(gzip.compress(body)).decode()


class CensusTallies(unittest.TestCase):
    def state(self, doc: dict):
        return pool.runner_state("manaflow-ai/cmux", raw=encode(doc), now=NOW)

    def runners(self, doc: dict):
        """GitHub.runners() from the census alone: any API call fails the test."""
        client = pool.GitHub("route-token", "manaflow-ai/cmux")
        with unittest.mock.patch.dict(os.environ, {"CI_RUNNER_STATE": encode(doc)}), \
                unittest.mock.patch.object(pool.deadline_http, "request", side_effect=AssertionError("API read")):
            return client.runners()

    def test_the_linux_fleet_as_tallies_fits_the_variable_and_reads_as_its_runners(self):
        doc = document({LINUX: [tally(idle=88, busy=3494, offline=94)]})
        self.assertLess(len(encode(doc)), 48 * 1024)
        self.assertIsNotNone(self.state(doc))
        rows = self.runners(doc)
        linux = [row for row in rows if (row.get("os") or "").lower() == "linux"]
        self.assertEqual(len(linux), 88 + 3494 + 94)
        self.assertEqual(sum(row["status"] == "online" and row["busy"] is False for row in linux), 88)
        self.assertEqual(sum(row["status"] == "online" and row["busy"] is True for row in linux), 3494)
        self.assertEqual(sum(row["status"] == "offline" for row in linux), 94)
        self.assertTrue(all(pool.runner_labels(row) == set(LINUX_LABELS) for row in linux))
        self.assertEqual(len({row["name"] for row in linux}), len(linux))
        self.assertTrue(all(pool.runner_member(row["name"]) == "" for row in linux))
        self.assertIn(MINI["name"], {row["name"] for row in rows})

    def test_fast_checks_and_portable_placement_see_an_idle_fleet_runner(self):
        doc = document({LINUX: [tally(idle=1, busy=3000, offline=0)]})
        rows = self.runners(doc)
        self.assertEqual(fast_checks.idle_runner(rows), FLEET)
        # A Linux-only picker (the cmux-tui daemon marker's shape) reads the Linux group from the census alone.
        env = {"CI_RUNNER_STATE": encode(doc), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
               "JOBS": "checks", "LINUX_ONLY": "checks"}
        runners, _ = placement.read(env, NOW)
        self.assertIsNotNone(runners)
        self.assertEqual(fast_checks.idle_runner(runners), FLEET)

    def test_a_fully_busy_fleet_has_no_idle_runner_but_is_online(self):
        rows = self.runners(document({LINUX: [tally(idle=0, busy=3582, offline=94)]}))
        self.assertEqual(fast_checks.idle_runner(rows), "")
        self.assertTrue(fast_checks.online_fleet(rows))

    def test_tallies_replace_the_groups_rows_kept_for_older_readers(self):
        subset = [{"id": 900 + i, "name": f"cmux-runner-pool-w1a-{i}", "os": "Linux", "status": "online",
                   "busy": False, "labels": [{"name": name} for name in LINUX_LABELS]} for i in range(5)]
        doc = document({LINUX: [tally(idle=2, busy=7, offline=0)]},
                       groups={pool.RUNNER_GROUP: [MINI], LINUX: subset})
        linux = [row for row in self.runners(doc) if (row.get("os") or "").lower() == "linux"]
        self.assertEqual(len(linux), 9)
        self.assertEqual(sum(row["busy"] is False for row in linux), 2)

    def test_malformed_tallies_make_the_census_unusable(self):
        bad = {
            "the required mini group": {pool.RUNNER_GROUP: [tally(1, 0, 0, labels=["glaeda-std-xcode-26.6"],
                                                                  os_name="macOS")]},
            "an unapproved group": {"someone-elses-pool": [tally(1, 0, 0)]},
            "a negative count": {LINUX: [tally(-1, 0, 0)]},
            "a count that is not an int": {LINUX: [tally(True, 0, 0)]},
            "an empty label set": {LINUX: [tally(1, 0, 0, labels=[])]},
            "a repeated label set": {LINUX: [tally(1, 0, 0), tally(2, 0, 0, labels=list(reversed(LINUX_LABELS)))]},
            "an unknown field": {LINUX: [{**tally(1, 0, 0), "names": ["x"]}]},
            "too many runners": {LINUX: [tally(pool.RUNNER_TALLY_MAX_RUNNERS, 1, 0)]},
            "not a list": {LINUX: tally(1, 0, 0)},
        }
        for why, tallies in bad.items():
            with self.subTest(why):
                self.assertIsNone(self.state(document(tallies)))


if __name__ == "__main__":
    unittest.main()
