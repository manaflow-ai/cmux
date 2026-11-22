#!/usr/bin/env python3
"""github_spend counts each picker request per token and reports the last rate-limit headers, never the token."""
from __future__ import annotations

import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import github_spend  # noqa: E402


class GitHubSpend(unittest.TestCase):
    def setUp(self) -> None:
        github_spend._spend.clear()

    def test_counts_per_token_and_keeps_the_last_headers(self) -> None:
        github_spend.record("Bearer app-token", {"X-RateLimit-Limit": "12500", "X-RateLimit-Remaining": "40",
                                                 "X-RateLimit-Resource": "core"}, 200)
        github_spend.record("Bearer app-token", {"X-RateLimit-Limit": "12500", "X-RateLimit-Remaining": "0",
                                                 "X-RateLimit-Resource": "core"}, 403)
        github_spend.record("Bearer github-token", {"X-RateLimit-Limit": "1000"}, 200)
        spend = github_spend.spend()
        app = spend[github_spend.token_id("Bearer app-token")]
        self.assertEqual((app["requests"], app["refused"], app["limit"], app["remaining"]), (2, 1, "12500", "0"))
        self.assertEqual(spend[github_spend.token_id("Bearer github-token")]["requests"], 1)

    def test_the_report_names_no_token(self) -> None:
        github_spend.record("Bearer secret-value", None, 302)
        out = io.StringIO()
        github_spend.report(out)
        self.assertIn("1 requests (0 refused)", out.getvalue())
        self.assertNotIn("secret-value", out.getvalue())

    def test_no_request_no_report(self) -> None:
        out = io.StringIO()
        github_spend.report(out)
        self.assertEqual(out.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
