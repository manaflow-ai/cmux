#!/usr/bin/env python3
"""Smoke-test cancellation and descendant cleanup for the Bun code-mode MCP."""

import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MCP = ROOT / "cmux-tui/bindings/typescript/code-mode/mcp.mjs"


class CodeModeCancellationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("bun") and shutil.which("bwrap"), "bun and bwrap are required")
    def test_cancel_returns_and_leaves_no_descendants(self):
        with tempfile.TemporaryDirectory(prefix="cmux-code-mode-test-") as temp:
            socket_path = Path(temp) / "target.sock"
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(socket_path))
            server.listen()
            stop = threading.Event()

            def accept_connections():
                server.settimeout(0.1)
                while not stop.is_set():
                    try:
                        connection, _ = server.accept()
                    except socket.timeout:
                        continue
                    connection.close()

            thread = threading.Thread(target=accept_connections, daemon=True)
            thread.start()
            env = {**os.environ, "CMUX_TUI_SOCKET": str(socket_path), "TMPDIR": temp}
            process = subprocess.Popen(
                [shutil.which("bun"), str(MCP)],
                cwd=ROOT,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            try:
                request = {
                    "jsonrpc": "2.0",
                    "id": "cancel-test",
                    "method": "tools/call",
                    "params": {
                        "name": "cmux_exec",
                        "arguments": {"script": "await new Promise(() => {});"},
                    },
                }
                cancellation = {
                    "jsonrpc": "2.0",
                    "method": "notifications/cancelled",
                    "params": {"requestId": "cancel-test"},
                }
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()
                time.sleep(0.2)
                process.stdin.write(json.dumps(cancellation) + "\n")
                process.stdin.flush()
                response = json.loads(process.stdout.readline())
                result = json.loads(response["result"]["content"][0]["text"])
                self.assertTrue(result["cancelled"])
                self.assertTrue(response["result"]["isError"])
                process.stdin.close()
                process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()
                self.assertEqual(process.returncode, 0)
                self.assertEqual(list(Path(temp).glob("cmux-code-mode-proxy.*")), [])
                ps = subprocess.run(["ps", "-eo", "args="], check=True, capture_output=True, text=True)
                self.assertNotIn(temp, ps.stdout)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                stop.set()
                server.close()


if __name__ == "__main__":
    unittest.main()
