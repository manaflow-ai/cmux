#!/usr/bin/env python3
"""Exercise transfer progress with the real CLI, a PTY, and a fake VM socket."""

from __future__ import annotations

import base64
import errno
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import socket
import subprocess
import tempfile
import threading
import unittest


class TransferProgressTests(unittest.TestCase):
    def test_transfer_progress(self) -> None:
        cli = os.environ.get("CMUX_CLI_BIN")
        self.assertTrue(cli and os.access(cli, os.X_OK), "Set CMUX_CLI_BIN to the built CLI")
        for direction in ("push", "pull"):
            for tty in (False, True):
                for fail_second_chunk in (False, True):
                    with self.subTest(direction=direction, tty=tty, failure=fail_second_chunk):
                        self.run_transfer(cli, direction, tty, fail_second_chunk)

    def run_transfer(self, cli: str, direction: str, tty: bool, fail: bool) -> None:
        with tempfile.TemporaryDirectory(prefix="vm-progress-", dir="/tmp") as root:
            payload = b"x" * (128 * 1024 if direction == "push" else 1024 * 1024)
            digest = hashlib.sha256(payload).hexdigest()
            local_path = Path(root, "payload")
            local_path.write_bytes(payload)
            socket_path = str(Path(root, "s"))
            chunks: list[str] = []
            errors: list[Exception] = []

            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(socket_path)
                listener.listen(1)
                listener.settimeout(20)

                def serve() -> None:
                    try:
                        connection, _ = listener.accept()
                        connection.settimeout(20)
                        with connection, connection.makefile("rwb") as stream:
                            for raw in stream:
                                if raw.startswith(b"auth "):
                                    stream.write(b"OK\n")
                                    stream.flush()
                                    continue
                                request = json.loads(raw)
                                if request["method"] != "vm.exec":
                                    raise AssertionError(f"Unexpected method: {request['method']}")
                                command = request["params"]["command"]
                                output = ""
                                is_chunk = "| base64 -d >>" in command or command.startswith("dd if=")
                                if is_chunk:
                                    chunks.append(command)
                                    if direction == "pull":
                                        offset = (len(chunks) - 1) * 512 * 1024
                                        output = base64.b64encode(payload[offset:offset + 512 * 1024]).decode()
                                elif "CMUX_FILE" in command:
                                    output = "CMUX_FILE\n"
                                elif command.startswith("wc -c"):
                                    output = f"{len(payload)}\n{digest}  payload\n"
                                elif "sha256sum" in command:
                                    output = f"{digest}  payload\n"
                                response = {
                                    "id": request["id"], "ok": True,
                                    "result": {"stdout": output, "stderr": "", "exit_code": 0},
                                }
                                if is_chunk and len(chunks) == 2 and fail:
                                    response = {
                                        "id": request["id"], "ok": False,
                                        "error": {"code": "probe_failure", "message": "second chunk failed"},
                                    }
                                stream.write(json.dumps(response).encode() + b"\n")
                                stream.flush()
                    except Exception as error:
                        errors.append(error)

                server = threading.Thread(target=serve, daemon=True)
                server.start()
                environment = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
                environment.update({
                    "HOME": root, "CFFIXED_USER_HOME": root,
                    "CMUX_SOCKET_PATH": socket_path, "CMUX_CLI_SENTRY_DISABLED": "1",
                    "AppleLanguages": "(en)", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                })
                args = [cli, "vm", direction, "probe-machine"]
                args += [str(local_path), "payload"] if direction == "push" else ["payload", str(Path(root, "received"))]
                master, slave = pty.openpty() if tty else (None, None)
                stderr = b""
                try:
                    # This fixture emits less than 256 bytes of progress. Keep the
                    # parent slave open until drained: macOS discards unread PTY
                    # output when the last slave closes.
                    result = subprocess.run(
                        args, env=environment, stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE, stderr=slave if tty else subprocess.PIPE,
                        timeout=20, check=False,
                    )
                    stderr = result.stderr or b""
                    if master is not None:
                        while select.select([master], [], [], 0)[0]:
                            try:
                                chunk = os.read(master, 65536)
                            except OSError as error:
                                if error.errno == errno.EIO:
                                    break
                                raise
                            if not chunk:
                                break
                            stderr += chunk
                finally:
                    if slave is not None:
                        os.close(slave)
                    if master is not None:
                        os.close(master)
                server.join(timeout=2)

                self.assertFalse(server.is_alive(), "Mock server did not finish")
                self.assertEqual(errors, [])
                self.assertEqual(len(chunks), 2)
                self.assertEqual(result.returncode, 1 if fail else 0, stderr)
                newline = b"\r\n" if tty else b"\n"
                prefix = b"\r" if tty else b""
                first = f"cmux vm {direction}: 1/2 chunks".encode()
                expected = prefix + first
                if fail:
                    expected += newline + b"Error: probe_failure: second chunk failed" + newline
                else:
                    if not tty:
                        expected += newline
                    expected += prefix + f"cmux vm {direction}: 2/2 chunks".encode() + newline
                    if direction == "pull":
                        self.assertEqual(Path(root, "received").read_bytes(), payload)
                self.assertEqual(stderr, expected)


if __name__ == "__main__":
    unittest.main()
