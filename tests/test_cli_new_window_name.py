#!/usr/bin/env python3
"""Check create-time window naming through the built CLI and an isolated socket."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import unittest


WINDOW_ID = "11111111-1111-4111-8111-111111111111"


class WindowHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while raw := self.rfile.readline():
            line = raw.decode().strip()
            if line.startswith("auth "):
                self.wfile.write(b"OK\n")
            elif line.startswith("{"):
                request = json.loads(line)
                self.server.requests.append(request)
                response = {"id": request["id"], "ok": True,
                            "result": {"window_id": WINDOW_ID, "window_ref": "window:1"}}
                self.wfile.write(json.dumps(response).encode() + b"\n")
            else:
                self.server.requests.append({"legacy": line})
                self.wfile.write(f"OK {WINDOW_ID}\n".encode())
            self.wfile.flush()


class NewWindowNameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cli = os.environ["CMUX_CLI_BIN"]

    def setUp(self) -> None:
        self.root = tempfile.TemporaryDirectory(prefix="cmux-window-", dir="/tmp")
        self.path = str(Path(self.root.name, "socket"))
        self.server = socketserver.ThreadingUnixStreamServer(self.path, WindowHandler)
        self.server.requests = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.root.cleanup()

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        environment = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
        environment.update({"CMUX_CLI_SENTRY_DISABLED": "1", "AppleLanguages": "(en)"})
        return subprocess.run([self.cli, "--socket", self.path, "new-window", *args],
                              env=environment, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=10, check=False)

    def test_name_is_sent_in_the_creation_request(self) -> None:
        name = 'Build 日本語 "quotes" \\ path\nsecond line'
        for args in (("--name", name), (f"--name={name}",)):
            with self.subTest(args=args):
                self.server.requests.clear()
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"OK {WINDOW_ID}")
                self.assertEqual(len(self.server.requests), 1)
                request = self.server.requests[0]
                self.assertEqual(request.get("method"), "window.create", request)
                self.assertEqual(request["params"], {"title": name})

    def test_no_name_keeps_existing_output(self) -> None:
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"OK {WINDOW_ID}")

    def test_invalid_name_does_not_create_a_window(self) -> None:
        for args in (("--name",), ("--name=",), ("--name", " \t "), ("--name", "--unknown")):
            with self.subTest(args=args):
                self.server.requests.clear()
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.server.requests, [])

    def test_help_advertises_naming_without_contacting_socket(self) -> None:
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--name", result.stdout)
        self.assertEqual(self.server.requests, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
