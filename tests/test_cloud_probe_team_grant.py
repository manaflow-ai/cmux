"""Unit tests for scripts/ci/cloud_probe_team_grant.py (no network: a fake Stack transport)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "ci"))

import cloud_probe_team_grant as g  # noqa: E402

PROJECT = g.PRODUCTION_PROJECT_ID


class FakeStack:
    def __init__(self, teams, members, metadata=None):
        self.teams, self.members = teams, members
        self.metadata = dict(metadata or {})
        self.calls = []

    def __call__(self, method, url, headers, body):
        assert headers["x-stack-access-type"] == "server"
        path = url[len(g.STACK_API):]
        self.calls.append((method, path.split("?")[0]))
        if method == "GET" and path.startswith("/users?query="):
            return 200, {}, {"items": [{"id": "u-probe", "primary_email": "cmux-cloud-capture-test@manaflow.dev"},
                                       {"id": "u-person", "primary_email": "someone@example.com"}]}
        if method == "GET" and path.startswith("/teams?user_id="):
            return 200, {}, {"items": self.teams if "u-probe" in path else [{"id": "t-other", "display_name": g.TEAM_NAME}]}
        if method == "GET" and path.startswith("/users?team_id="):
            return 200, {}, {"items": self.members}
        if method == "GET" and path.startswith("/teams/"):
            return 200, {}, {"id": path[7:], "display_name": g.TEAM_NAME, "client_read_only_metadata": dict(self.metadata)}
        if method == "PATCH" and path.startswith("/teams/"):
            self.metadata = body["client_read_only_metadata"]
            return 200, {}, {}
        return 404, {}, None


class GrantTests(unittest.TestCase):
    def setUp(self):
        self.saved = g.TEAM_ID
        g.TEAM_ID = g.cmux_team_id(PROJECT, "t-probe")

    def tearDown(self):
        g.TEAM_ID = self.saved

    def probe_team(self):
        return [{"id": "t-probe", "display_name": g.TEAM_NAME}, {"id": "t-own", "display_name": "cmux cloud capture"}]

    def test_grants_and_keeps_other_metadata(self):
        fake = FakeStack(self.probe_team(), [{"primary_email": "cmux-cloud-capture-test@manaflow.dev"}], {"other": 1})
        before = g.grant(g.Stack(PROJECT, "k", fake), log=lambda _: None)
        self.assertIsNone(before)
        self.assertEqual(fake.metadata, {"other": 1, "cmuxVmPlan": "pro"})

    def test_rerun_writes_nothing(self):
        fake = FakeStack(self.probe_team(), [{"primary_email": "cmux-cloud-capture-test@manaflow.dev"}], {"cmuxVmPlan": "pro"})
        g.grant(g.Stack(PROJECT, "k", fake), log=lambda _: None)
        self.assertNotIn(("PATCH", "/teams/t-probe"), fake.calls)

    def test_refuses_a_team_with_a_person(self):
        fake = FakeStack(self.probe_team(), [{"primary_email": "cmux-cloud-capture-test@manaflow.dev"},
                                            {"primary_email": "someone@example.com"}])
        with self.assertRaises(g.GrantError):
            g.grant(g.Stack(PROJECT, "k", fake), log=lambda _: None)
        self.assertFalse(any(m == "PATCH" for m, _ in fake.calls))

    def test_refuses_a_team_with_another_id(self):
        g.TEAM_ID = "team_00000000000000000000"
        fake = FakeStack(self.probe_team(), [{"primary_email": "cmux-cloud-capture-test@manaflow.dev"}])
        with self.assertRaises(g.GrantError):
            g.grant(g.Stack(PROJECT, "k", fake), log=lambda _: None)

    def test_refuses_another_project(self):
        with self.assertRaises(g.GrantError):
            g.Stack("454ecd03-1db2-4050-845e-4ce5b0cd9895", "k", FakeStack([], []))

    def test_cmux_id_matches_platform(self):
        self.assertEqual(g.cmux_team_id("p", "s"), "team_" + __import__("hashlib").sha256(b"stack-team:p:s").hexdigest()[:20])


if __name__ == "__main__":
    unittest.main()
