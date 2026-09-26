#!/usr/bin/env python3
"""Run the real current command against an isolated socket; never contacts a live app.

CMUX_CLI_BIN=/path/to/freshly-built/cmux python3 tests/test_cli_current.py
"""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import unittest

from claude_teams_test_utils import resolve_cmux_cli


SNAPSHOT = {
    "schema_version": 1,
    "authority": "read_only_projection",
    "observed_at": "2026-09-20T19:00:00Z",
    "total_observed": 3,
    "truncated": True,
    "owner_availability": {"agent_sessions": "unavailable"},
    "items": [{
        "resource_ref": "local/terminal/fixture-runtime",
        "durable_surface_id": "11111111-1111-4111-8111-111111111111",
        "label": "Review cmux",
        "kind": "terminal",
        "placement": {"kind": "local", "machine": "local"},
        "projections": [{"resource_ref": "local/terminal/fixture-runtime",
                         "workspace_id": "22222222-2222-4222-8222-222222222222",
                         "panel_id": "33333333-3333-4333-8333-333333333333",
                         "stable_surface_id": "11111111-1111-4111-8111-111111111111"}],
        "cwd": "/fixture/cmux",
        "agents": [],
        "attention": [{"kind": "unread_notification", "scope": "surface",
                       "evidence": {"owner": "notifications", "reference": "fixture:notification",
                                    "observed_at": "2026-09-20T19:00:00Z"}}],
        "pull_requests": [{"number": 123, "status": "open"}],
        "freshness": {"state": "unknown", "reason": "fixture"},
        "possible_human_obligations": [],
        "cursor": None,
        "receipt_refs": [],
        "future_owner_field": {"preserved": True},
    }],
}


class FakeServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path):
        self.requests = []
        self.payload = copy.deepcopy(SNAPSHOT)
        self.error = None
        super().__init__(path, FakeHandler)


class FakeHandler(socketserver.StreamRequestHandler):
    def handle(self):
        while line := self.rfile.readline():
            request = json.loads(line)
            self.server.requests.append((request["method"], request.get("params", {})))
            if request["method"] != "current.list":
                error = {"code": "unexpected_mutation", "message": request["method"]}
            else:
                error = self.server.error
            response = {"id": request.get("id"), "ok": error is None}
            response["error" if error else "result"] = error or self.server.payload
            self.wfile.write((json.dumps(response) + "\n").encode())
            self.wfile.flush()


class CurrentCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli = resolve_cmux_cli()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-current-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.path = str(Path(self.temp.name) / "s.sock")
        self.server = FakeServer(self.path)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def invoke(self, *args):
        env = dict(os.environ, CMUX_CLI_SENTRY_DISABLED="1")
        for key in ("CMUX_SOCKET_PASSWORD", "CMUX_SOCKET_CAPABILITY", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"):
            env.pop(key, None)
        return subprocess.run([self.cli, "--socket", self.path, *args], capture_output=True,
                              text=True, timeout=10, env=env)

    def test_json_preserves_owner_facts_and_identity_under_id_format(self):
        for id_format in ("refs", "uuids", "both"):
            with self.subTest(id_format=id_format):
                result = self.invoke("--id-format", id_format, "current", "--json", "--limit", "1")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), SNAPSHOT)
        self.assertEqual(self.server.requests, [("current.list", {"limit": 1})] * 3)

    def test_text_uses_same_snapshot_and_reports_unknowns_and_truncation(self):
        result = self.invoke("current")
        self.assertEqual(result.returncode, 0, result.stderr)
        for text in ("Review cmux", "local/terminal/fixture-runtime", "/fixture/cmux", "freshness: unknown",
                     "attention: unread_notification", "PR: #123", "Limit reached", "agent_sessions: unavailable"):
            self.assertIn(text, result.stdout)
        self.assertEqual(self.server.requests, [("current.list", {})])

    def test_window_option_does_not_focus_or_issue_any_mutation(self):
        result = self.invoke("--window", "window:3", "--json", "current", "--limit=2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), SNAPSHOT)
        self.assertEqual(self.server.requests, [("current.list", {"limit": 2})])

    def test_invalid_or_unbounded_requests_fail_before_query(self):
        for flags in (("--limit", "0"), ("--limit", "201"), ("--limit", "-1"),
                      ("--limit", "999999999999999999999999"), ("--limit",),
                      ("--limit=1.5",), ("--limit=",), ("--refresh",),
                      ("--limit", "1", "--limit", "2")):
            with self.subTest(flags=flags):
                result = self.invoke("current", *flags)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("current:", result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_owner_error_is_not_replaced_with_empty_success_or_retried(self):
        self.server.error = {"code": "unavailable", "message": "current owner unavailable"}
        result = self.invoke("current", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("current owner unavailable", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.server.requests, [("current.list", {})])

    def test_help_needs_no_query(self):
        result = self.invoke("current", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--limit <1...200>", result.stdout)
        self.assertEqual(self.server.requests, [])

    def test_text_sanitizes_controls_but_json_preserves_data(self):
        self.server.payload["items"][0]["label"] = "first\nsecond\x1b[2J"
        text = self.invoke("current")
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertNotIn("\x1b", text.stdout)
        self.assertIn("first second [2J", text.stdout)
        result = self.invoke("current", "--json")
        self.assertEqual(json.loads(result.stdout), self.server.payload)


if __name__ == "__main__":
    unittest.main()
