#!/usr/bin/env python3
"""Regression: Claude AskUserQuestion PreToolUse publishes Needs input once."""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit:
        if os.path.exists(explicit) and os.access(explicit, os.X_OK):
            return explicit
        raise RuntimeError(f"Configured cmux CLI is not executable: {explicit}")

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class HookSocketServer:
    def __init__(self, workspace_id: str, surface_id: str) -> None:
        self.workspace_id = workspace_id
        self.surface_id = surface_id
        self.commands: list[str] = []
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.error: Exception | None = None
        self.root = tempfile.TemporaryDirectory(prefix="cmux-claude-ask-question-")
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
            conn.settimeout(0.1)
            buffer = b""
            idle_deadline = time.time() + 6.0
            while not self.stop.is_set() and time.time() < idle_deadline:
                try:
                    chunk = conn.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                idle_deadline = time.time() + 2.0
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
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            return "OK"

        method = request.get("method")
        result: dict[str, object] = {}
        if method == "surface.list":
            result = {
                "surfaces": [
                    {
                        "index": 0,
                        "id": self.surface_id,
                        "ref": "surface:1",
                        "focused": True,
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


def run_claude_hook(
    cli_path: str,
    socket_path: str,
    subcommand: str,
    payload: dict[str, object],
    env: dict[str, str],
) -> None:
    proc = subprocess.run(
        [cli_path, "--socket", socket_path, "hooks", "claude", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"cmux hooks claude {subcommand} failed:\n"
            f"exit={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )
    if proc.stdout.strip() != "OK":
        raise RuntimeError(
            f"cmux hooks claude {subcommand} returned unexpected stdout: {proc.stdout!r}"
        )


def has_command_with(commands: list[str], *fragments: str) -> bool:
    return any(all(fragment in command for fragment in fragments) for command in commands)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"ask-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "claude-hook-state.json"
        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = server.socket_path
        env["CMUX_WORKSPACE_ID"] = workspace_id
        env["CMUX_SURFACE_ID"] = surface_id
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        payload = {
            "session_id": session_id,
            "hook_event_name": "PreToolUse",
            "cwd": "/tmp/cmux-4257",
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    {
                        "question": "Which approach should I use?",
                        "options": [
                            {"label": "Fast path"},
                            {"label": "Careful path"},
                        ],
                    }
                ]
            },
        }

        run_claude_hook(
            cli_path,
            server.socket_path,
            "pre-tool-use",
            payload,
            env,
        )

        if not has_command_with(
            server.commands,
            f"set_status claude_code Needs input --icon=bell.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            print("FAIL: AskUserQuestion PreToolUse should set Claude Needs input status")
            print(f"commands={server.commands!r}")
            return 1

        if not has_command_with(
            server.commands,
            f"notify_target_async {workspace_id} {surface_id} Claude Code|Waiting|",
            "Which approach should I use?",
            "[Fast path]",
            "[Careful path]",
        ):
            print("FAIL: AskUserQuestion PreToolUse should register a target notification")
            print(f"commands={server.commands!r}")
            return 1

        notification_payload = {
            "session_id": session_id,
            "hook_event_name": "Notification",
            "message": "入力が必要です",
        }
        run_claude_hook(
            cli_path,
            server.socket_path,
            "notification",
            notification_payload,
            env,
        )

        notify_commands = [
            command for command in server.commands
            if command.startswith(f"notify_target_async {workspace_id} {surface_id} ")
        ]
        if len(notify_commands) != 1:
            print("FAIL: generic Notification hook should not duplicate AskUserQuestion notification")
            print(f"commands={server.commands!r}")
            return 1

    print("PASS: Claude AskUserQuestion PreToolUse publishes Needs input once")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
