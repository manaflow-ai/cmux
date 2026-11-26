#!/usr/bin/env python3
"""A live runner read leaves the routing App a reserve, so the runner census can always be published.

Placement reads the org's runners live only when the trusted census (CI_RUNNER_STATE) is missing or older than
five minutes. The census publisher (cmuxterm-hq runner-state-publish.yml) reads those runners with the same
App, manaflow-glaeda-route, so the two share one hourly quota. On 2026-11-20 the census went stale at 12:37Z
and stayed stale: each placement then read runners live (4 to 12 calls), the App's hour ran out within minutes
of each reset, and every publisher refresh failed with "runner census GET failed; prior variable retained" until
the next reset (08:14-08:37Z on 2026-11-21, readable again at 08:39Z, one minute after the 08:38:24Z reset).
A stale census also costs each placement two GITHUB_TOKEN calls for the queue snapshot, from the hour the
production promote gates share.

GitHub.runners() now stops after its first live read when that answer says fewer than ROUTE_QUOTA_RESERVE
requests are left, and raises RateLimited, which every caller already treats as an unread census. The reserve
is left to the publisher, whose next refresh makes the census fresh again and ends the live reads.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import unittest
import unittest.mock
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
pool = importlib.import_module("pr_runner_pool")
import deadline_http  # noqa: E402

MINI = "glaeda-std-xcode-27.2"
REPO_RUNNERS = "/repos/manaflow-ai/cmux/actions/runners?per_page=100&page=1"
GROUPS = "/orgs/manaflow-ai/actions/runner-groups?per_page=100&visible_to_repository=cmux"
GROUP_RUNNERS = "/orgs/manaflow-ai/actions/runner-groups/23/runners?per_page=100&page=1"


class RouteQuotaReserve(unittest.TestCase):
    def transport(self, remaining: int):
        """deadline_http.request answering from fixed runner listings, each with X-RateLimit-Remaining."""
        mini = {"id": 10, "status": "online", "busy": False, "labels": [{"name": MINI}]}
        answers = {
            REPO_RUNNERS: {"runners": []},
            GROUPS: {"runner_groups": [{"id": 23, "name": pool.RUNNER_GROUP}]},
            GROUP_RUNNERS: {"runners": [mini]},
        }
        calls: list[str] = []

        def request(req, *args, **kwargs):
            url = urllib.parse.urlsplit(req.full_url)
            path = url.path + (f"?{url.query}" if url.query else "")
            calls.append(path)
            headers = deadline_http.Headers({"x-ratelimit-remaining": str(remaining), "x-ratelimit-limit": "5000"})
            return 200, json.dumps(answers[path]).encode(), headers
        return request, calls

    def runners(self, remaining: int):
        request, calls = self.transport(remaining)
        client = pool.GitHub("route-app-token", "manaflow-ai/cmux")
        with unittest.mock.patch.dict(os.environ, {"CI_RUNNER_STATE": ""}), \
                unittest.mock.patch.object(pool.deadline_http, "request", side_effect=request):
            try:
                return client.runners(), calls
            except pool.RateLimited as error:
                return error, calls

    def test_a_live_read_below_the_reserve_stops_after_one_request(self):
        result, calls = self.runners(remaining=300)
        self.assertIsInstance(result, pool.RateLimited, result)
        self.assertIn("census", str(result))
        self.assertEqual(calls, [REPO_RUNNERS])

    def test_a_live_read_with_quota_to_spare_reads_every_group(self):
        result, calls = self.runners(remaining=4000)
        self.assertEqual([runner["id"] for runner in result], [10])
        self.assertEqual(calls, [REPO_RUNNERS, GROUPS, GROUP_RUNNERS])


if __name__ == "__main__":
    unittest.main()
