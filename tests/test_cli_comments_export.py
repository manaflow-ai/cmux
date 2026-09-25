#!/usr/bin/env python3
"""Exercise comment exports through a built CLI and a private fake socket."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import unittest


class CommentHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        self.connection.settimeout(10)
        for raw in self.rfile:
            if raw.startswith(b"auth "):
                self.wfile.write(b"OK\n")
                continue
            request = json.loads(raw)
            self.server.requests.append(request)
            response = {"id": request["id"], "ok": True, "result": self.server.payload}
            self.wfile.write(json.dumps(response).encode() + b"\n")


class CommentsExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cli = os.environ.get("CMUX_CLI_BIN", "")
        if not cls.cli or not os.access(cls.cli, os.X_OK):
            raise RuntimeError("Set CMUX_CLI_BIN to the built CLI")

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="comments-export-", dir="/tmp")
        self.root = Path(self.temporary.name).resolve()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("CMUX", "GIT_"))}
        self.env.update(CMUX_CLI_SENTRY_DISABLED="1", AppleLanguages="(en)", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
        subprocess.run(["git", "init", "-q", str(self.root)], env=self.env, check=True)
        (self.root / "nested").mkdir()
        self.server = socketserver.UnixStreamServer(str(self.root / "socket"), CommentHandler)
        self.server.requests = []
        self.server.payload = {
            "repo_root": str(self.root), "count": 2, "comments": [
                {"id": "12345678-1234-1234-1234-123456789abc", "filePath": "a`b.md",
                 "side": "deletions", "startLine": 10, "endLine": 12,
                 "lineText": "```quoted```", "message": "First line\n\nSecond line",
                 "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z"},
                {"id": "22345678-1234-1234-1234-123456789abc", "filePath": "other.md",
                 "side": "additions", "startLine": 2, "endLine": 2, "lineText": "anchor",
                 "message": "Delivered", "consumedAt": "2026-01-03T00:00:00Z",
                 "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z"}
            ]
        }
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=5)
        self.server.server_close()
        self.temporary.cleanup()

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([self.cli, "--socket", str(self.root / "socket"), "comments", *args],
                              cwd=self.root / "nested", env=self.env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=15, check=False)

    def test_default_and_explicit_json_preserve_records_and_request_all(self) -> None:
        for options in ([], ["--format", "json"], ["--json"]):
            with self.subTest(options=options):
                result = self.run_cli("export", *options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), self.server.payload)
                request = self.server.requests[-1]
                self.assertEqual(request["method"], "comments.list")
                self.assertEqual(request["params"], {"repo_root": str(self.root), "include_consumed": True})

    def test_markdown_preserves_multiline_messages_and_fences_anchor(self) -> None:
        result = self.run_cli("export", "--repo", str(self.root / "nested"), "--format=markdown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("### `` a`b.md ``:10-12 (deletions, pending)", result.stdout)
        self.assertIn("````\n```quoted```\n````", result.stdout)
        self.assertIn("> First line\n> \n> Second line", result.stdout)
        self.assertIn("(additions, consumed)", result.stdout)
        self.assertIn("<!-- cmux-comment: 12345678-1234-1234-1234-123456789abc -->", result.stdout)

    def test_invalid_export_arguments_do_not_read_comments(self) -> None:
        for options in (["--format"], ["--format", "xml"], ["--repo"], ["--repo", "--format", "json"], ["unexpected"], ["--all"]):
            with self.subTest(options=options):
                result = self.run_cli("export", *options)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.server.requests, [])

    def test_export_help_is_available_without_reading_comments(self) -> None:
        result = self.run_cli("export", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("export [--repo <path>] [--format json|markdown]", result.stdout)
        self.assertEqual(self.server.requests, [])

    def test_empty_exports_are_valid(self) -> None:
        self.server.payload.update(count=0, comments=[])
        result = self.run_cli("export")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), self.server.payload)
        result = self.run_cli("export", "--format", "markdown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
