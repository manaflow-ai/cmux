#!/usr/bin/env python3
"""Regression: /clear stays idle until the next Claude turn begins."""

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
        self.delivery_target_available = True
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
            if not self.delivery_target_available:
                return json.dumps(
                    {
                        "id": request.get("id"),
                        "ok": False,
                        "error": {
                            "code": "not_found",
                            "message": "no live target",
                        },
                    }
                )
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


def hook_environment(
    server: HookSocketServer,
    workspace_id: str,
    surface_id: str,
    state_path: Path,
) -> dict[str, str]:
    env = os.environ.copy()
    env.pop("CMUX_CLAUDE_PID", None)
    env["CMUX_SOCKET_PATH"] = server.socket_path
    env["CMUX_WORKSPACE_ID"] = workspace_id
    env["CMUX_SURFACE_ID"] = surface_id
    env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    return env


def verify_stale_start_preserves_pending_clear_handoff(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"pending-old-{uuid.uuid4().hex}"
    stale_session_id = f"pending-stale-{uuid.uuid4().hex}"
    clear_session_id = f"pending-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "pending-clear-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
                "last_assistant_message": "background work continues",
                "background_tasks": [{"id": "task-1", "status": "running"}],
                "session_crons": [],
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "reason": "clear", "cwd": "/tmp"},
            env,
        )

        # A late, non-establishing SessionStart from the old process can race
        # between SessionEnd(clear) and the matching SessionStart(clear).
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": stale_session_id, "source": "startup", "cwd": "/tmp"},
            env,
        )

        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": clear_session_id, "source": "clear", "cwd": "/tmp"},
            env,
        )
        clear_commands = server.commands[clear_start:]

        if not has_command_with(
            clear_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A non-establishing SessionStart erased the pending /clear handoff:\n"
                f"clear_commands={clear_commands!r}"
            )
        if has_command_with(
            clear_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "Pending background work became Idle after a stale SessionStart:\n"
                f"clear_commands={clear_commands!r}"
            )

        state = json.loads(state_path.read_text())
        clear_record = state["sessions"][clear_session_id]
        if clear_record.get("agentLifecycle") != "running":
            raise RuntimeError(
                "The clear session did not inherit the pending lifecycle:\n"
                f"clear_record={clear_record!r}"
            )


def verify_stale_turn_event_preserves_pending_clear_handoff(
    cli_path: str,
    stale_subcommand: str,
) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"{stale_subcommand}-old-{uuid.uuid4().hex}"
    clear_session_id = f"{stale_subcommand}-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / f"{stale_subcommand}-clear-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
                "last_assistant_message": "background work continues",
                "background_tasks": [{"id": "task-1", "status": "running"}],
                "session_crons": [],
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "reason": "clear", "cwd": "/tmp"},
            env,
        )

        if stale_subcommand == "stop":
            stale_payload: dict[str, object] = {
                "session_id": old_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
                "last_assistant_message": "old turn completed late",
                "background_tasks": [],
                "session_crons": [],
            }
        elif stale_subcommand == "prompt-submit":
            stale_payload = {
                "session_id": old_session_id,
                "turn_id": "turn-2",
                "cwd": "/tmp",
            }
        else:
            raise ValueError(f"Unsupported stale hook: {stale_subcommand}")

        run_claude_hook(
            cli_path,
            server.socket_path,
            stale_subcommand,
            stale_payload,
            env,
        )

        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": clear_session_id, "source": "clear", "cwd": "/tmp"},
            env,
        )
        clear_commands = server.commands[clear_start:]

        if not has_command_with(
            clear_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                f"A stale {stale_subcommand} erased the pending /clear handoff:\n"
                f"clear_commands={clear_commands!r}"
            )
        if has_command_with(
            clear_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                f"A stale {stale_subcommand} made pending background work Idle:\n"
                f"clear_commands={clear_commands!r}"
            )

        state = json.loads(state_path.read_text())
        clear_record = state["sessions"][clear_session_id]
        if clear_record.get("agentLifecycle") != "running":
            raise RuntimeError(
                f"The clear session did not survive a stale {stale_subcommand}:\n"
                f"clear_record={clear_record!r}"
            )


def verify_failed_clear_store_preserves_visible_state(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    running_session_id = f"running-{uuid.uuid4().hex}"
    clear_session_id = f"failed-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        valid_state_path = Path(server.root.name) / "running-state.json"
        env = hook_environment(server, workspace_id, surface_id, valid_state_path)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": running_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )

        blocked_parent = Path(server.root.name) / "not-a-directory"
        blocked_parent.write_text("blocks state-store creation")
        failed_store_env = hook_environment(
            server,
            workspace_id,
            surface_id,
            blocked_parent / "claude-hook-state.json",
        )

        failed_clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": clear_session_id, "source": "clear", "cwd": "/tmp"},
            failed_store_env,
        )
        failed_clear_commands = server.commands[failed_clear_start:]

        forbidden_fragments = [
            "set_agent_lifecycle claude_code idle ",
            "set_status claude_code Idle ",
            f"clear_status claude_code --tab={workspace_id}",
            "clear_notifications ",
            '"method":"surface.resume.set"',
        ]
        for fragment in forbidden_fragments:
            if has_command(failed_clear_commands, fragment):
                raise RuntimeError(
                    "A failed /clear state transaction published a new Idle boundary:\n"
                    f"fragment={fragment!r}\ncommands={failed_clear_commands!r}"
                )


def verify_session_crons_do_not_cross_clear(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"cron-old-{uuid.uuid4().hex}"
    clear_session_id = f"cron-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "cron-clear-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
                "last_assistant_message": "scheduled work remains",
                "background_tasks": [],
                "session_crons": [{"id": "cron-1"}],
            },
            env,
        )

        stopped_record = json.loads(state_path.read_text())["sessions"][old_session_id]
        if stopped_record.get("hadPendingBackgroundWorkAtStop") is not True:
            raise RuntimeError(
                "Session crons must still suppress idle reminders before /clear:\n"
                f"stopped_record={stopped_record!r}"
            )

        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "reason": "clear", "cwd": "/tmp"},
            env,
        )

        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": clear_session_id, "source": "clear", "cwd": "/tmp"},
            env,
        )
        clear_commands = server.commands[clear_start:]

        if not has_command_with(
            clear_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A session-scoped cron crossed /clear and kept the new session Running:\n"
                f"clear_commands={clear_commands!r}"
            )
        if has_command_with(
            clear_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "Session-scoped cron work must not transfer into the clear session:\n"
                f"clear_commands={clear_commands!r}"
            )

        clear_record = json.loads(state_path.read_text())["sessions"][clear_session_id]
        if clear_record.get("agentLifecycle") != "idle":
            raise RuntimeError(
                "The clear session inherited a lifecycle from a retired cron:\n"
                f"clear_record={clear_record!r}"
            )


def verify_clear_handoff_follows_moved_surface(cli_path: str) -> None:
    old_workspace_id = str(uuid.uuid4()).upper()
    new_workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"moved-old-{uuid.uuid4().hex}"
    clear_session_id = f"moved-clear-{uuid.uuid4().hex}"

    with HookSocketServer(
        workspace_id=old_workspace_id,
        surface_id=surface_id,
    ) as server:
        state_path = Path(server.root.name) / "moved-clear-state.json"
        env = hook_environment(server, old_workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
                "last_assistant_message": "background work continues",
                "background_tasks": [{"id": "task-1", "status": "running"}],
                "session_crons": [],
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "reason": "clear", "cwd": "/tmp"},
            env,
        )

        # Surface identity is stable across workspace moves. The live resolver
        # re-homes it before the replacement SessionStart consumes the handoff.
        server.workspace_id = new_workspace_id
        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": clear_session_id, "source": "clear", "cwd": "/tmp"},
            env,
        )
        clear_commands = server.commands[clear_start:]

        if not has_command_with(
            clear_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={new_workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A workspace move dropped live background work from the clear handoff:\n"
                f"clear_commands={clear_commands!r}"
            )
        if has_command_with(
            clear_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={new_workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A moved surface became Idle while transferred work was still running:\n"
                f"clear_commands={clear_commands!r}"
            )

        clear_record = json.loads(state_path.read_text())["sessions"][clear_session_id]
        if clear_record.get("workspaceId") != new_workspace_id:
            raise RuntimeError(
                "The replacement clear session did not follow its moved surface:\n"
                f"clear_record={clear_record!r}"
            )
        if clear_record.get("agentLifecycle") != "running":
            raise RuntimeError(
                "The moved clear session did not inherit the running lifecycle:\n"
                f"clear_record={clear_record!r}"
            )


def verify_guessed_surface_does_not_consume_clear_handoff(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"authoritative-old-{uuid.uuid4().hex}"
    guessed_session_id = f"guessed-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "guessed-clear-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
                "last_assistant_message": "background work continues",
                "background_tasks": [{"id": "task-1", "status": "running"}],
                "session_crons": [],
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "reason": "clear", "cwd": "/tmp"},
            env,
        )

        fallback_env = env.copy()
        fallback_env.pop("CMUX_SURFACE_ID")
        server.delivery_target_available = False
        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": guessed_session_id, "source": "clear", "cwd": "/tmp"},
            fallback_env,
        )
        clear_commands = server.commands[clear_start:]

        forbidden_fragments = [
            "set_agent_pid claude_code ",
            "set_agent_lifecycle claude_code ",
            "set_status claude_code ",
            "clear_notifications ",
            '"method":"surface.resume.set"',
        ]
        for fragment in forbidden_fragments:
            if has_command(clear_commands, fragment):
                raise RuntimeError(
                    "A non-authoritative fallback published a clear boundary:\n"
                    f"fragment={fragment!r}\ncommands={clear_commands!r}"
                )

        state = json.loads(state_path.read_text())
        transfers = state.get("clearBackgroundWorkTransfersBySurface", {})
        if surface_id not in transfers:
            raise RuntimeError(
                "A guessed surface consumed another pane's clear handoff:\n"
                f"state={state!r}"
            )
        if guessed_session_id in state.get("sessions", {}):
            raise RuntimeError(
                "A rejected clear boundary persisted a guessed pane as authoritative:\n"
                f"state={state!r}"
            )


def verify_stale_clear_start_preserves_handoff(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"pid-old-{uuid.uuid4().hex}"
    stale_session_id = f"pid-stale-{uuid.uuid4().hex}"
    clear_session_id = f"pid-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "pid-clear-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)
        source_env = env.copy()
        source_env["CMUX_CLAUDE_PID"] = "11111"
        stale_env = env.copy()
        stale_env["CMUX_CLAUDE_PID"] = "22222"

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            source_env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
                "last_assistant_message": "background work continues",
                "background_tasks": [{"id": "task-1", "status": "running"}],
                "session_crons": [],
            },
            source_env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "reason": "clear", "cwd": "/tmp"},
            source_env,
        )

        stale_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": stale_session_id, "source": "clear", "cwd": "/tmp"},
            stale_env,
        )
        stale_commands = server.commands[stale_start:]
        forbidden_fragments = [
            "set_agent_pid claude_code ",
            "set_agent_lifecycle claude_code ",
            "set_status claude_code ",
            "clear_notifications ",
            '"method":"surface.resume.set"',
        ]
        for fragment in forbidden_fragments:
            if has_command(stale_commands, fragment):
                raise RuntimeError(
                    "A stale process generation established a clear boundary:\n"
                    f"fragment={fragment!r}\ncommands={stale_commands!r}"
                )

        state_after_stale_start = json.loads(state_path.read_text())
        transfers = state_after_stale_start.get(
            "clearBackgroundWorkTransfersBySurface",
            {},
        )
        if surface_id not in transfers:
            raise RuntimeError(
                "A stale clear start consumed the live process's handoff:\n"
                f"state={state_after_stale_start!r}"
            )

        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": clear_session_id, "source": "clear", "cwd": "/tmp"},
            source_env,
        )
        clear_commands = server.commands[clear_start:]
        if not has_command_with(
            clear_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "The matching process could not consume its clear handoff:\n"
                f"clear_commands={clear_commands!r}"
            )


def verify_clear_handoff_outlives_session_end_budget(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"delayed-old-{uuid.uuid4().hex}"
    clear_session_id = f"delayed-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "delayed-clear-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)
        # Claude permits an explicit SessionEnd budget beyond its 60-second
        # settings ceiling. The handoff must outlive that configured budget.
        env["CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS"] = "600000"

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
                "last_assistant_message": "background work continues",
                "background_tasks": [{"id": "task-1", "status": "running"}],
                "session_crons": [],
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "reason": "clear", "cwd": "/tmp"},
            env,
        )

        state = json.loads(state_path.read_text())
        transfer = state["clearBackgroundWorkTransfersBySurface"][surface_id]
        transfer["updatedAt"] = time.time() - 601
        state_path.write_text(json.dumps(state))

        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": clear_session_id, "source": "clear", "cwd": "/tmp"},
            env,
        )
        clear_commands = server.commands[clear_start:]
        if not has_command_with(
            clear_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A valid delayed clear start lost its live background handoff:\n"
                f"clear_commands={clear_commands!r}"
            )


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
        env = hook_environment(server, workspace_id, surface_id, state_path)
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
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            print("FAIL: expected clear SessionStart to set Claude Idle on the current panel")
            print(f"clear_commands={clear_commands!r}")
            return 1
        if has_command_with(
            clear_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            print("FAIL: clear SessionStart must not begin a turn")
            print(f"clear_commands={clear_commands!r}")
            return 1

        state = json.loads(state_path.read_text())
        clear_record = state["sessions"][new_session_id]
        if clear_record.get("agentLifecycle") != "idle":
            print("FAIL: clear SessionStart must persist an idle lifecycle")
            print(f"clear_record={clear_record!r}")
            return 1

        clear_prompt_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": new_session_id,
                "turn_id": "clear-turn-1",
                "cwd": "/tmp",
            },
            clear_pid_env,
        )
        clear_prompt_commands = server.commands[clear_prompt_start:]

        if not has_command_with(
            clear_prompt_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            print("FAIL: prompt-submit after /clear must begin the turn")
            print(f"clear_prompt_commands={clear_prompt_commands!r}")
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

    try:
        verify_stale_start_preserves_pending_clear_handoff(cli_path)
        verify_stale_turn_event_preserves_pending_clear_handoff(cli_path, "stop")
        verify_stale_turn_event_preserves_pending_clear_handoff(
            cli_path,
            "prompt-submit",
        )
        verify_failed_clear_store_preserves_visible_state(cli_path)
        verify_session_crons_do_not_cross_clear(cli_path)
        verify_clear_handoff_follows_moved_surface(cli_path)
        verify_guessed_surface_does_not_consume_clear_handoff(cli_path)
        verify_stale_clear_start_preserves_handoff(cli_path)
        verify_clear_handoff_outlives_session_end_budget(cli_path)
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    print("PASS: Claude /clear lifecycle boundaries remain idle, current, and failure-safe")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
