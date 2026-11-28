#!/usr/bin/env python3
"""`cmux restore-session --from` waits for an import that takes a while.

The app replies once every window is open, so a large session can outlast the
CLI's default reply timeout. A timeout there says the import failed while the
windows still open, and running it again opens them all a second time. The case
runs the real CLI against a fake socket that replies after the default timeout.
"""

from __future__ import annotations

import json
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from fake_socket_env import cli_environment, unwrap_capability


DEFAULT_TIMEOUT_SECONDS = 0.3
REPLY_DELAY_SECONDS = 1.0


class SlowReplier(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            time.sleep(REPLY_DELAY_SECONDS)
            response = {"id": request.get("id"), "ok": True, "result": {"source_path": "/tmp/session.json"}}
            try:
                self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
                self.wfile.flush()
            except BrokenPipeError:
                return


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class RestoreSessionSlowReplyTests(unittest.TestCase):
    def test_import_waits_past_the_default_reply_timeout(self) -> None:
        with tempfile.TemporaryDirectory(prefix="cmux-import-", dir="/tmp") as temp:
            socket_path = str(Path(temp) / "s")
            session_path = Path(temp) / "session.json"
            session_path.write_text("{}", encoding="utf-8")
            server = Server(socket_path, SlowReplier)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)

            result = subprocess.run(
                [
                    str(resolve_cmux_cli()),
                    "--socket", socket_path,
                    "restore-session", "--from", str(session_path),
                ],
                env=cli_environment(
                    AppleLanguages="(en)",
                    CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=str(DEFAULT_TIMEOUT_SECONDS),
                ),
                stdin=subprocess.DEVNULL,
                capture_output=True, text=True, timeout=30, check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["OK /tmp/session.json"])


if __name__ == "__main__":
    unittest.main()
