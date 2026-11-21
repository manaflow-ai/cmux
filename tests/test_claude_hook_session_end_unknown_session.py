#!/usr/bin/env python3
"""Regression: a SessionEnd naming an unknown session leaves the pane's record alone.

https://github.com/manaflow-ai/cmux/issues/42726
"""

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
from fake_socket_env import cli_environment, unwrap_capability


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
        self.root = tempfile.TemporaryDirectory(prefix="cmux-claude-end-")
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
                    line = unwrap_capability(raw_line.decode("utf-8", errors="replace"))
                    self.commands.append(line)
                    try:
                        conn.sendall((self._response_for(line) + "\n").encode("utf-8"))
                    except (BrokenPipeError, ConnectionResetError):
                        # Hook commands are fire-and-forget: the CLI may close the socket
                        # without reading the reply. The command is already recorded.
                        return

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


def stored_sessions(state_path: Path) -> dict[str, dict[str, object]]:
    state = json.loads(state_path.read_text())
    sessions = state.get("sessions")
    return sessions if isinstance(sessions, dict) else {}


CLEANUP_PREFIXES = (
    "clear_agent_pid claude_code",
    "clear_notifications",
)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    parent_session_id = f"parent-{uuid.uuid4().hex}"
    missing_session_id = f"missing-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "claude-hook-state.json"
        env = cli_environment(server.socket_path)
        env["CMUX_WORKSPACE_ID"] = workspace_id
        env["CMUX_SURFACE_ID"] = surface_id
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_PID"] = "11111"

        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": parent_session_id, "source": "startup", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": parent_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )
        parent = stored_sessions(state_path).get(parent_session_id)
        if not isinstance(parent, dict):
            print("FAIL: expected the parent session to be recorded")
            print(f"state={state_path.read_text()}")
            return 1
        started_at = parent.get("startedAt")

        # Twice: a child's repeated SessionEnd names a session that is
        # already gone, and the first one must not have consumed the parent.
        for attempt in (1, 2):
            end_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "session-end",
                {"session_id": missing_session_id, "cwd": "/tmp"},
                env,
            )
            end_commands = server.commands[end_start:]
            parent = stored_sessions(state_path).get(parent_session_id)
            if not isinstance(parent, dict):
                print(f"FAIL: SessionEnd {attempt} for an unknown session consumed the parent record")
                print(f"state={state_path.read_text()}")
                return 1
            for prefix in CLEANUP_PREFIXES:
                if has_command(end_commands, prefix):
                    print(f"FAIL: SessionEnd {attempt} for an unknown session cleaned up the parent's pane")
                    print(f"prefix={prefix!r}")
                    print(f"end_commands={end_commands!r}")
                    return 1

        # The parent's next prompt keeps its original record.
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": parent_session_id, "turn_id": "turn-2", "cwd": "/tmp"},
            env,
        )
        parent = stored_sessions(state_path).get(parent_session_id)
        if not isinstance(parent, dict) or parent.get("startedAt") != started_at:
            print("FAIL: expected the parent's next prompt to keep its original startedAt")
            print(f"state={state_path.read_text()}")
            return 1

        # A SessionEnd without a session id still ends the pane's session.
        sessionless_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"cwd": "/tmp"},
            env,
        )
        sessionless_commands = server.commands[sessionless_start:]
        if parent_session_id in stored_sessions(state_path):
            print("FAIL: expected a SessionEnd without a session id to end the pane's session")
            print(f"state={state_path.read_text()}")
            return 1
        if not has_command(sessionless_commands, f"clear_agent_pid claude_code --tab={workspace_id}"):
            print("FAIL: expected a SessionEnd without a session id to clear the pane")
            print(f"sessionless_commands={sessionless_commands!r}")
            return 1

    print("PASS: SessionEnd for an unknown session keeps the pane's record; a sessionless one still ends it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
