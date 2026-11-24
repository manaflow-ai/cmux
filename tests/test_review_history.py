import argparse
import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "review-history.py"
_spec = importlib.util.spec_from_file_location("review_history", SCRIPT)
assert _spec and _spec.loader
review_history = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(review_history)


def page(remaining, cost):
    return {
        "rateLimit": {"cost": cost, "remaining": remaining, "resetAt": "2026-01-01T00:00:00Z"},
        "search": {"issueCount": 0, "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": []},
    }


class CollectFloorGuard(unittest.TestCase):
    def run_collect(self, remaining, cost, floor):
        calls = []

        def fake_graphql(query, variables):
            if "search(" not in query:  # the rateLimit-only preflight, not a search page
                return {"rateLimit": {"cost": cost, "remaining": remaining, "resetAt": "2026-01-01T00:00:00Z"}}
            calls.append(variables)
            return page(remaining, cost)

        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "cache.jsonl"
            args = argparse.Namespace(
                repo="manaflow-ai/cmux", since="2026-08-01", until="2026-08-02", window_days=2,
                cache=str(cache), page=20, max_pages=5, floor=floor, restart=False, command="collect",
            )
            err = io.StringIO()
            with mock.patch.object(review_history, "graphql", fake_graphql), contextlib.redirect_stderr(err):
                code = review_history.collect(args)
            return code, calls, err.getvalue()

    def test_no_search_page_is_spent_when_the_quota_is_already_below_the_floor(self):
        # Issue #40391: remaining 6 - cost 5 < floor 10, so the first page must not be sent.
        code, calls, err = self.run_collect(remaining=6, cost=5, floor=10)
        self.assertEqual(code, 0)
        self.assertEqual(calls, [], "a search page was sent although the floor was already reached")
        self.assertIn("stopping: GraphQL quota near the floor", err)


if __name__ == "__main__":
    unittest.main()
