#!/usr/bin/env python3
"""`cmux ssh` startup commands must stay far below the kernel argv budget.

The reusable ssh startup command is `/bin/sh -c '<wrapper>'` with the whole
attach script embedded as a base64 literal. Embedding that literal twice (once
per `base64 -d` / `-D` fallback branch) produced a 990 KB argv, within 60 KB of
macOS's 1 MiB ARG_MAX, so spawning it failed with "Argument list too long"
whenever the caller's environment was a little larger (issue #12232; the
app-host suites SSHStartupSignalLifecycleTests and SSHStartupManualReconnectTests
failed with NSPOSIXErrorDomain Code=7 on CI).

This test drives the real CLI against a mock control socket, captures the
`terminal_startup_command` it configures, and asserts:
  1. the base64 payload appears exactly once,
  2. the command is under 640 KB,
  3. `/bin/sh -n -c <command>` still spawns with a 256 KB environment.
"""

from __future__ import annotations

import base64
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_cli_socket_autodiscovery import resolve_cmux_cli  # noqa: E402

WORKSPACE_ID = "11111111-1111-1111-1111-111111111111"
MAX_COMMAND_BYTES = 640 * 1024
PADDED_ENVIRONMENT_BYTES = 256 * 1024


class MockControlSocket:
    def __init__(self, path: str) -> None:
        self.path = path
        self.startup_commands: list[str] = []
        self.methods: list[str] = []
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(path)
        self._server.listen(4)
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def close(self) -> None:
        try:
            self._server.close()
        finally:
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass

    def _serve(self) -> None:
        while True:
            try:
                connection, _ = self._server.accept()
            except OSError:
                return
            with connection, connection.makefile("rwb") as stream:
                for raw in stream:
                    try:
                        request = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    method = request.get("method")
                    request_id = request.get("id")
                    self.methods.append(str(method))
                    if method == "workspace.create":
                        response = {
                            "id": request_id,
                            "ok": True,
                            "result": {"workspace_id": WORKSPACE_ID, "surface_id": "surface:1"},
                        }
                    elif method == "workspace.remote.configure":
                        params = request.get("params") or {}
                        self.startup_commands.append(str(params.get("terminal_startup_command", "")))
                        response = {
                            "id": request_id,
                            "ok": True,
                            "result": {
                                "workspace_id": WORKSPACE_ID,
                                "workspace_ref": "workspace:9",
                                "remote": {"enabled": True, "state": "connecting"},
                            },
                        }
                    else:
                        response = {
                            "id": request_id,
                            "ok": False,
                            "error": {"code": "unexpected", "message": f"Unexpected method {method}"},
                        }
                    stream.write((json.dumps(response) + "\n").encode("utf-8"))
                    stream.flush()


def capture_startup_command(cli: str) -> str:
    with tempfile.TemporaryDirectory(prefix="cmux-ssh-argv-") as temp_dir:
        socket_path = os.path.join("/tmp", f"cmux-ssh-argv-{os.getpid()}.sock")
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass
        server = MockControlSocket(socket_path)
        server.start()
        try:
            env = dict(os.environ)
            env.update(
                {
                    "CMUX_SOCKET_PATH": socket_path,
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                    "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
                    "HOME": temp_dir,
                }
            )
            result = subprocess.run(
                [cli, "ssh", "--no-focus", "--port", "2222", "cmux-macmini"],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        finally:
            server.close()
    if result.returncode != 0:
        raise AssertionError(f"cmux ssh exited {result.returncode}: {result.stderr}\nmethods={server.methods}")
    if not server.startup_commands:
        raise AssertionError(f"cmux ssh never configured a startup command; methods={server.methods}")
    return server.startup_commands[0]


def main() -> int:
    cli = resolve_cmux_cli()
    command = capture_startup_command(cli)
    size = len(command.encode("utf-8"))
    print(f"terminal_startup_command: {size} bytes")

    payloads = re.findall(r"[A-Za-z0-9+/=]{1000,}", command)
    if not payloads:
        print("FAIL: no base64 payload found in the startup command", file=sys.stderr)
        return 1
    decoded = base64.b64decode(payloads[0] + "=" * (-len(payloads[0]) % 4))
    if b"#!/bin/sh" not in decoded[:32]:
        print("FAIL: payload does not decode to the ssh startup script", file=sys.stderr)
        return 1
    if command.count(payloads[0]) != 1:
        print(
            f"FAIL: the {len(payloads[0])}-byte payload is embedded {command.count(payloads[0])} times; "
            "the wrapper must bind it once so argv stays below ARG_MAX",
            file=sys.stderr,
        )
        return 1
    if size > MAX_COMMAND_BYTES:
        print(f"FAIL: startup command is {size} bytes (limit {MAX_COMMAND_BYTES})", file=sys.stderr)
        return 1

    padded_env = dict(os.environ)
    padding = "x" * 4096
    for index in range(PADDED_ENVIRONMENT_BYTES // len(padding)):
        padded_env[f"CMUX_ARGV_BUDGET_PAD_{index}"] = padding
    try:
        check = subprocess.run(
            ["/bin/sh", "-n", "-c", command],
            env=padded_env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except OSError as error:
        print(f"FAIL: spawning the startup command with a padded environment failed: {error}", file=sys.stderr)
        return 1
    if check.returncode != 0:
        print(f"FAIL: /bin/sh -n rejected the startup command: {check.stderr}", file=sys.stderr)
        return 1

    print("PASS: cmux ssh startup command embeds its payload once and spawns with a large environment")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
