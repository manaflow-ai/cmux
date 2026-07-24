#!/usr/bin/env python3
"""Regression: /clear SessionStart keeps Claude Running status current."""

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
        self.root = tempfile.TemporaryDirectory(prefix="cmux-claude-clear-")
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
        if method == "agent.resolve_delivery_target":
            params = request.get("params")
            if isinstance(params, dict) and "pid" in params:
                result = {
                    "source": "pid",
                    "workspace_id": self.workspace_id,
                    "surface_id": self.surface_id,
                }
            else:
                result = {
                    "source": "surface",
                    "workspace_id": self.workspace_id,
                    "surface_id": self.surface_id,
                }
        elif method == "surface.list":
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
        [cli_path, "--socket", socket_path, "claude-hook", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"cmux claude-hook {subcommand} failed:\n"
            f"exit={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )


def has_command(commands: list[str], fragment: str) -> bool:
    return any(fragment in command for command in commands)


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
    old_session_id = f"old-{uuid.uuid4().hex}"
    new_session_id = f"new-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "claude-hook-state.json"
        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = server.socket_path
        env["CMUX_WORKSPACE_ID"] = workspace_id
        env["CMUX_SURFACE_ID"] = surface_id
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        old_pid_env = env.copy()
        old_pid_env["CMUX_CLAUDE_PID"] = "11111"
        clear_pid_env = env.copy()
        clear_pid_env["CMUX_CLAUDE_PID"] = "22222"

        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": old_session_id, "source": "startup", "cwd": "/tmp"},
            old_pid_env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )

        if not has_command(server.commands, f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}"):
            print("FAIL: expected prompt-submit to set Claude Running")
            print(f"commands={server.commands!r}")
            return 1

        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
                "last_assistant_message": "first turn completed",
            },
            env,
        )
        second_turn_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "turn-2", "cwd": "/tmp"},
            env,
        )
        second_turn_commands = server.commands[second_turn_start:]

        if not has_command(second_turn_commands, f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}"):
            print("FAIL: expected second turn prompt-submit to set Claude Running")
            print(f"second_turn_commands={second_turn_commands!r}")
            return 1

        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": new_session_id, "source": "clear", "cwd": "/tmp"},
            clear_pid_env,
        )
        clear_commands = server.commands[clear_start:]

        if not has_command(
            clear_commands,
            f"clear_notifications --tab={workspace_id} --panel={surface_id}",
        ):
            print("FAIL: expected clear SessionStart to clear only the current panel")
            print(f"clear_commands={clear_commands!r}")
            return 1
        if not has_command_with(
            clear_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            print("FAIL: expected clear SessionStart to set Claude Running on the current panel")
            print(f"clear_commands={clear_commands!r}")
            return 1

        late_old_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": old_session_id, "source": "startup", "cwd": "/tmp"},
            old_pid_env,
        )
        late_old_start_commands = server.commands[late_old_start:]

        if has_command(late_old_start_commands, "set_agent_pid claude_code 11111"):
            print("FAIL: stale pre-clear SessionStart must not overwrite active Claude PID")
            print(f"late_old_start_commands={late_old_start_commands!r}")
            return 1

        old_stop_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "turn-2",
                "cwd": "/tmp",
                "last_assistant_message": "old turn completed late",
            },
            env,
        )
        old_stop_commands = server.commands[old_stop_start:]

        if has_command(old_stop_commands, f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}"):
            print("FAIL: stale pre-clear Stop must not overwrite the active clear session")
            print(f"old_stop_commands={old_stop_commands!r}")
            return 1

        old_session_end_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "cwd": "/tmp"},
            env,
        )
        old_session_end_commands = server.commands[old_session_end_start:]

        stale_session_end_forbidden_prefixes = [
            f"clear_status claude_code --tab={workspace_id}",
            f"clear_agent_pid claude_code --tab={workspace_id}",
            f"clear_notifications --tab={workspace_id}",
        ]
        for forbidden_prefix in stale_session_end_forbidden_prefixes:
            if has_command(old_session_end_commands, forbidden_prefix):
                print("FAIL: stale pre-clear SessionEnd must not clear the active clear session")
                print(f"forbidden_prefix={forbidden_prefix!r}")
                print(f"old_session_end_commands={old_session_end_commands!r}")
                return 1

    print("PASS: Claude /clear SessionStart preserves Running against stale Stop and SessionEnd")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
