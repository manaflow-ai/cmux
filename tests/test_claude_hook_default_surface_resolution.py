#!/usr/bin/env python3
"""Regression: agent hooks do not default to an arbitrary unfocused surface."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from claude_teams_test_utils import resolve_cmux_cli


class HookSocketServer:
    def __init__(self, workspace_id: str, surface_id: str, focused: bool) -> None:
        self.workspace_id = workspace_id
        self.surface_id = surface_id
        self.focused = focused
        self.commands: list[str] = []
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.error: Exception | None = None
        self.root = tempfile.TemporaryDirectory(prefix="cmux-hook-default-surface-")
        self.socket_path = os.path.join(self.root.name, "cmux.sock")
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.server: socket.socket | None = None

    def __enter__(self) -> "HookSocketServer":
        self.thread.start()
        if not self.ready.wait(timeout=2.0):
            raise RuntimeError("socket server did not become ready")
        if self.error is not None:
            raise self.error
        return self

    def __exit__(self, _exc_type: object, _exc: object, _tb: object) -> None:
        self.stop.set()
        if self.server is not None:
            self.server.close()
        self.thread.join(timeout=2.0)
        self.root.cleanup()

    def _run(self) -> None:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                self.server = server
                server.bind(self.socket_path)
                server.listen(8)
                server.settimeout(0.1)
                self.ready.set()
                while not self.stop.is_set():
                    try:
                        conn, _ = server.accept()
                    except socket.timeout:
                        continue
                    except OSError:
                        return
                    threading.Thread(target=self._handle, args=(conn,), daemon=True).start()
        except Exception as exc:
            self.error = exc
            self.ready.set()

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            buffer = b""
            while not self.stop.is_set():
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    raw_line, buffer = buffer.split(b"\n", 1)
                    if not raw_line:
                        continue
                    line = raw_line.decode("utf-8", errors="replace")
                    self.commands.append(line)
                    conn.sendall((self._response_for(line) + "\n").encode("utf-8"))

    def _response_for(self, line: str) -> str:
        if not line.startswith("{"):
            return "OK"
        request = json.loads(line)
        method = request.get("method")
        result: dict[str, object] = {}
        if method == "surface.list":
            result = {
                "surfaces": [
                    {
                        "index": 0,
                        "id": self.surface_id,
                        "ref": "surface:1",
                        "focused": self.focused,
                    }
                ]
            }
        elif method == "workspace.current":
            result = {"workspace_id": self.workspace_id}
        elif method == "workspace.list":
            result = {
                "workspaces": [
                    {
                        "index": 0,
                        "id": self.workspace_id,
                        "ref": "workspace:1",
                    }
                ]
            }
        elif method == "window.list":
            result = {"windows": [{"id": str(uuid.uuid4()).upper()}]}
        elif method == "debug.terminals":
            result = {"terminals": []}
        return json.dumps({"id": request.get("id"), "ok": True, "result": result})


def run_session_start(cli_path: str, server: HookSocketServer) -> subprocess.CompletedProcess[str]:
    state_path = Path(server.root.name) / "claude-hook-state.json"
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = server.socket_path
    env["CMUX_WORKSPACE_ID"] = server.workspace_id
    env.pop("CMUX_SURFACE_ID", None)
    env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    return subprocess.run(
        [cli_path, "--socket", server.socket_path, "claude-hook", "session-start"],
        input=json.dumps({"session_id": f"session-{uuid.uuid4().hex}", "source": "clear", "cwd": "/tmp"}),
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )


def has_command(commands: list[str], fragment: str) -> bool:
    return any(fragment in command for command in commands)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()

    with HookSocketServer(workspace_id, surface_id, focused=False) as server:
        proc = run_session_start(cli_path, server)
        if proc.returncode != 0:
            print(f"FAIL: unfocused hook failed: {proc.stderr}")
            return 1
        if proc.stdout.strip() != "OK":
            print(f"FAIL: unfocused hook should no-op successfully, got stdout={proc.stdout!r}")
            return 1
        if has_command(server.commands, "set_status claude_code"):
            print(f"FAIL: unfocused hook targeted an arbitrary surface: {server.commands!r}")
            return 1

    with HookSocketServer(workspace_id, surface_id, focused=True) as server:
        proc = run_session_start(cli_path, server)
        if proc.returncode != 0:
            print(f"FAIL: focused hook failed: {proc.stderr}")
            return 1
        if not has_command(server.commands, f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id} --panel={surface_id}"):
            print(f"FAIL: focused hook did not target focused surface: {server.commands!r}")
            return 1

    print("PASS: claude hook default surface resolution requires a focused surface")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
