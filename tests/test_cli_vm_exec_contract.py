#!/usr/bin/env python3
"""Verify that ``vm exec`` preserves argv boundaries at the socket boundary."""

from __future__ import annotations

import json
import os
import shlex
import socket
import subprocess
import tempfile
import threading
import uuid

from claude_teams_test_utils import resolve_cmux_cli


class ExecServer:
    def __init__(self) -> None:
        self.root = tempfile.TemporaryDirectory(prefix="cmux-vm-exec-contract-", dir="/tmp")
        self.path = os.path.join(self.root.name, f"cmux-{uuid.uuid4().hex}.sock")
        self.requests: list[dict[str, object]] = []
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.server: socket.socket | None = None

    def __enter__(self) -> "ExecServer":
        self.thread.start()
        if not self.ready.wait(timeout=2):
            raise RuntimeError("fake vm.exec socket did not become ready")
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.stop.set()
        if self.server is not None:
            self.server.close()
        self.thread.join(timeout=2)
        self.root.cleanup()

    def _serve(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            self.server = server
            server.bind(self.path)
            server.listen(4)
            server.settimeout(0.1)
            self.ready.set()
            while not self.stop.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                with connection:
                    data = b""
                    while b"\n" not in data:
                        chunk = connection.recv(4096)
                        if not chunk:
                            return
                        data += chunk
                    request = json.loads(data.splitlines()[0].decode("utf-8"))
                    self.requests.append(request)
                    response = {
                        "ok": True,
                        "result": {"stdout": "ok\n", "stderr": "", "exit_code": 0},
                        "id": request.get("id"),
                    }
                    connection.sendall((json.dumps(response) + "\n").encode("utf-8"))


def run_exec(cli: str, server: ExecServer, command_argv: list[str]) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    for key in ("CMUX_SOCKET_PASSWORD", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"):
        env.pop(key, None)
    env["CMUX_SOCKET_PATH"] = server.path
    env["CMUX_SOCKET"] = server.path
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    return subprocess.run(
        [cli, "--socket", server.path, "vm", "exec", "demo", "--", *command_argv],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=10,
    )


def main() -> int:
    try:
        cli = resolve_cmux_cli()
        with ExecServer() as server:
            first = run_exec(cli, server, ["printf", "%s", "a b"])
            second = run_exec(cli, server, ["sh", "-c", "printf '%s\\n' \"$HOME\""])
            if first.returncode != 0 or second.returncode != 0:
                raise AssertionError(
                    f"vm exec failed: first={first.stderr!r}, second={second.stderr!r}"
                )
            if len(server.requests) != 2:
                raise AssertionError(f"expected two vm.exec requests, got {server.requests!r}")
            first_params = server.requests[0].get("params") or {}
            second_params = server.requests[1].get("params") or {}
            first_command = first_params.get("command")
            second_command = second_params.get("command")
            if shlex.split(str(first_command)) != ["printf", "%s", "a b"]:
                raise AssertionError(f"spaced argv was not preserved: {first_command!r}")
            if shlex.split(str(second_command)) != ["sh", "-c", "printf '%s\\n' \"$HOME\""]:
                raise AssertionError(f"explicit shell argv was not preserved: {second_command!r}")
    except (AssertionError, OSError, RuntimeError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}")
        return 1

    print("PASS: vm exec preserves argv semantics")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
