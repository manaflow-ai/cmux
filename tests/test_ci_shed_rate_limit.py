#!/usr/bin/env python3
"""scripts/ci/shed_superseded_runs.py survives the token's primary rate limit (no network).

2026-11-21: 34 of the last 100 sweeps died on "403 API rate limit exceeded for installation" while listing runs and
shed nothing. A sweep that meets the limit now sheds what it listed and exits 0.
"""

from __future__ import annotations

import datetime as dt
import email.message
import io
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/shed_superseded_runs.py"
if str(SCRIPT.parent) not in sys.path:
    sys.path.insert(0, str(SCRIPT.parent))
import shed_superseded_runs as shed  # noqa: E402

LIMIT_BODY = b'{"message": "API rate limit exceeded for installation. If you reach out to GitHub Support..."}'


def http_error(code: int, body: bytes, **headers: str) -> urllib.error.HTTPError:
    msg = email.message.Message()
    for k, v in headers.items():
        msg[k] = v
    return urllib.error.HTTPError("https://api.github.com/x", code, "Forbidden", msg, io.BytesIO(body))


class PrimaryLimitTests(unittest.TestCase):
    def test_classifies_primary_and_secondary(self):
        self.assertTrue(shed.is_primary_limit(403, LIMIT_BODY.decode(), "0"))
        self.assertTrue(shed.is_primary_limit(403, "{}", "0"))
        self.assertFalse(shed.is_primary_limit(403, "You have exceeded a secondary rate limit", "10"))
        self.assertFalse(shed.is_primary_limit(403, "Resource not accessible by integration", "900"))
        self.assertFalse(shed.is_primary_limit(500, LIMIT_BODY.decode(), "0"))

    def test_request_raises_rate_limited_without_retrying(self):
        gh = shed.GitHub("o/r", "t")
        err = http_error(403, LIMIT_BODY, **{"x-ratelimit-remaining": "0", "x-ratelimit-limit": "15000",
                                             "x-ratelimit-reset": "1795260000"})
        with mock.patch.object(shed.urllib.request, "urlopen", side_effect=err) as opened, \
                mock.patch.object(shed.time, "sleep"):
            with self.assertRaises(shed.RateLimited) as caught:
                gh.request("GET", "/repos/o/r/actions/runs")
        self.assertEqual(opened.call_count, 1)
        self.assertEqual(caught.exception.reset, 1795260000)
        self.assertIs(gh.limited, caught.exception)
        self.assertEqual((gh.remaining, gh.limit), (0, 15000))
        self.assertFalse(gh.can_spend_on_reads(25))


class ListingTests(unittest.TestCase):
    since = dt.datetime(2026, 11, 21, 0, 0, tzinfo=dt.timezone.utc)
    until = dt.datetime(2026, 11, 21, 10, 0, tzinfo=dt.timezone.utc)

    def test_limit_during_bisection_keeps_windows_already_read(self):
        gh = shed.GitHub("o/r", "t")
        runs = [{"id": i, "status": "queued"} for i in range(40)]
        calls = []

        def page(lo, hi, page_no, status="queued"):
            calls.append((lo, hi))
            if len(calls) == 1:
                return {"total_count": 1500, "workflow_runs": []}  # whole span: bisect
            if len(calls) == 2:
                return {"total_count": 40, "workflow_runs": runs}  # first half read whole
            gh.limited = shed.RateLimited("rate limited (403)", 0)
            raise gh.limited

        with mock.patch.object(gh, "_page", side_effect=page):
            listed, failed = gh.queued_runs(self.since, self.until)
        self.assertEqual([r["id"] for r in listed], list(range(40)))
        self.assertEqual(failed, 1)
        # Once limited, the in_progress listing costs no call.
        with mock.patch.object(gh, "_page", side_effect=AssertionError("no call once limited")):
            self.assertEqual(gh.queued_runs(self.since, self.until, "in_progress"), ([], 1))

    def test_low_quota_stops_job_reads(self):
        gh = shed.GitHub("o/r", "t")
        gh.limit, gh.remaining = 1000, 300
        self.assertTrue(gh.can_spend_on_reads(25))
        gh.remaining = 200
        self.assertFalse(gh.can_spend_on_reads(25))
        gh.limit = gh.remaining = None
        self.assertTrue(gh.can_spend_on_reads(25))


class MainTests(unittest.TestCase):
    def test_sweep_that_meets_the_limit_exits_zero(self):
        env = {"GH_REPO": "o/r", "GH_TOKEN": "t", "GITHUB_STEP_SUMMARY": ""}

        def listing(self, since, until, status="queued"):
            self.limited = shed.RateLimited("rate limited (403)", 1795260000)
            return [], 1

        with mock.patch.dict(shed.os.environ, env), \
                mock.patch.object(shed.GitHub, "branch_tips", return_value={"main": "a"}), \
                mock.patch.object(shed.GitHub, "queued_runs", listing), \
                mock.patch.object(shed.GitHub, "cancel", side_effect=AssertionError("no cancel")), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            self.assertEqual(shed.main([]), 0)
        self.assertIn("rate limit was met", out.getvalue())


if __name__ == "__main__":
    unittest.main()
