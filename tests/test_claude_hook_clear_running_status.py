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
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


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
        self.connection_condition = threading.Condition()
        self.next_connection_id = 0
        self.completed_connection_ids: set[int] = set()
        self.delivery_target_available = True
        self.listed_surface_ids = [surface_id]
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
                    with self.connection_condition:
                        connection_id = self.next_connection_id
                        self.next_connection_id += 1
                    threading.Thread(
                        target=self._handle,
                        args=(conn, connection_id),
                        daemon=True,
                    ).start()
        except Exception as exc:
            self.error = exc
            self.ready.set()

    def _handle(self, conn: socket.socket, connection_id: int) -> None:
        try:
            with conn:
                conn.settimeout(0.1)
                buffer = b""
                while not self.stop.is_set():
                    try:
                        chunk = conn.recv(4096)
                    except socket.timeout:
                        continue
                    if not chunk:
                        break
                    buffer += chunk
                    while b"\n" in buffer:
                        raw_line, buffer = buffer.split(b"\n", 1)
                        if not raw_line:
                            continue
                        line = raw_line.decode("utf-8", errors="replace")
                        if line == "__test_barrier__":
                            self._wait_for_earlier_connections(connection_id)
                            conn.sendall(b"OK\n")
                            continue
                        self.commands.append(line)
                        response = self._response_for(line)
                        if response is not None:
                            conn.sendall((response + "\n").encode("utf-8"))
        finally:
            with self.connection_condition:
                self.completed_connection_ids.add(connection_id)
                self.connection_condition.notify_all()

    def _wait_for_earlier_connections(self, connection_id: int) -> None:
        with self.connection_condition:
            drained = self.connection_condition.wait_for(
                lambda: all(
                    earlier_id in self.completed_connection_ids
                    for earlier_id in range(connection_id)
                ),
                timeout=2.0,
            )
        if not drained:
            raise RuntimeError("hook socket connections did not drain")

    def _response_for(self, line: str) -> str | None:
        if not line.startswith("{"):
            return "OK"
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            return "OK"

        # JSON-RPC notifications intentionally omit an id and receive no reply.
        # Replying races the one-way client closing its socket and can starve the
        # immediately following hook connection under load.
        if "id" not in request:
            return None

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
                        "index": index,
                        "id": listed_surface_id,
                        "ref": f"surface:{index + 1}",
                        "focused": index == 0,
                    }
                    for index, listed_surface_id in enumerate(
                        self.listed_surface_ids
                    )
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
    hook_args: list[str] | None = None,
) -> None:
    proc = subprocess.run(
        [
            cli_path,
            "--socket",
            socket_path,
            "claude-hook",
            subcommand,
            *(hook_args or []),
        ],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as barrier:
        barrier.settimeout(2.0)
        barrier.connect(socket_path)
        barrier.sendall(b"__test_barrier__\n")
        response = b""
        while not response.endswith(b"\n") and len(response) <= 16:
            chunk = barrier.recv(16)
            if not chunk:
                break
            response += chunk
        if response != b"OK\n":
            raise RuntimeError("hook socket barrier failed")
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
    env["CMUX_CLAUDE_PID"] = str(os.getpid())
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    return env


@contextmanager
def live_process_pid() -> Iterator[int]:
    process = subprocess.Popen(
        ["/bin/cat"],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        yield process.pid
    finally:
        process.terminate()
        process.wait(timeout=2)


def assert_no_claude_lifecycle_mutations(
    commands: list[str],
    *,
    context: str,
) -> None:
    forbidden_fragments = [
        "set_agent_pid claude_code ",
        "clear_agent_pid claude_code ",
        "set_agent_lifecycle claude_code ",
        "set_status claude_code ",
        "clear_status claude_code ",
        "clear_notifications ",
        "notify_target_async ",
        '"method":"surface.resume.set"',
        '"method":"surface.resume.clear"',
        '"method":"feed.push"',
    ]
    for fragment in forbidden_fragments:
        if has_command(commands, fragment):
            raise RuntimeError(
                f"{context} published a rejected lifecycle mutation:\n"
                f"fragment={fragment!r}\ncommands={commands!r}"
            )


def verify_stop_first_clear_transfers_background_work(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"stop-first-old-{uuid.uuid4().hex}"
    clear_session_id = f"stop-first-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "stop-first-clear-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        # A reset or missing state file can make Stop the first stored hook.
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
                "A Stop-first /clear lost its surviving background work:\n"
                f"clear_commands={clear_commands!r}"
            )
        if not has_command_with(
            clear_commands,
            f"set_agent_pid claude_code {os.getpid()} --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A Stop-first /clear did not publish replacement ownership:\n"
                f"clear_commands={clear_commands!r}"
            )
        if not has_command_with(
            clear_commands,
            '"method":"feed.push"',
            '"_cmux_agent_lifecycle":"running"',
        ):
            raise RuntimeError(
                "A Stop-first /clear did not publish its accepted lifecycle to "
                f"Feed:\nclear_commands={clear_commands!r}"
            )

        state = json.loads(state_path.read_text())
        clear_record = state["sessions"].get(clear_session_id)
        if clear_record is None or clear_record.get("agentLifecycle") != "running":
            raise RuntimeError(
                "A Stop-first /clear did not persist the inherited lifecycle:\n"
                f"clear_record={clear_record!r}\nstate={state!r}"
            )
        surface_owner = state["activeSessionsBySurface"].get(surface_id)
        if surface_owner is None or surface_owner.get("sessionId") != clear_session_id:
            raise RuntimeError(
                "A Stop-first /clear did not publish its active surface owner:\n"
                f"surface_owner={surface_owner!r}\nstate={state!r}"
            )


def verify_unrelated_turn_event_preserves_pending_clear_handoff(
    cli_path: str,
    unrelated_subcommand: str,
) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"{unrelated_subcommand}-source-{uuid.uuid4().hex}"
    unrelated_session_id = (
        f"{unrelated_subcommand}-unrelated-{uuid.uuid4().hex}"
    )
    clear_session_id = f"{unrelated_subcommand}-replacement-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = (
            Path(server.root.name)
            / f"{unrelated_subcommand}-unrelated-clear-state.json"
        )
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": old_session_id, "turn_id": "source-turn", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": old_session_id,
                "turn_id": "source-turn",
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

        if unrelated_subcommand == "prompt-submit":
            unrelated_payload: dict[str, object] = {
                "session_id": unrelated_session_id,
                "turn_id": "unrelated-turn",
                "cwd": "/tmp",
            }
        elif unrelated_subcommand == "stop":
            unrelated_payload = {
                "session_id": unrelated_session_id,
                "turn_id": "unrelated-turn",
                "cwd": "/tmp",
                "last_assistant_message": "unrelated turn completed late",
                "background_tasks": [],
                "session_crons": [],
            }
        elif unrelated_subcommand == "notification":
            unrelated_payload = {
                "session_id": unrelated_session_id,
                "cwd": "/tmp",
                "notification_type": "permission_prompt",
                "message": "unrelated permission request",
            }
        elif unrelated_subcommand == "pre-tool-use":
            unrelated_payload = {
                "session_id": unrelated_session_id,
                "cwd": "/tmp",
                "tool_name": "Bash",
                "tool_input": {"command": "echo unrelated"},
            }
        elif unrelated_subcommand == "push-notification":
            unrelated_payload = {
                "session_id": unrelated_session_id,
                "hook_event_name": "PostToolUse",
                "cwd": "/tmp",
                "tool_name": "PushNotification",
                "tool_input": {
                    "message": "unrelated push",
                    "status": "proactive",
                },
                "tool_response": {
                    "message": "unrelated push",
                    "localSent": True,
                },
            }
        else:
            raise ValueError(f"Unsupported unrelated hook: {unrelated_subcommand}")

        # With no active owner between SessionEnd(clear) and SessionStart(clear),
        # an unrelated late event must not erase the pane's one-shot handoff.
        unrelated_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            unrelated_subcommand,
            unrelated_payload,
            env,
        )
        unrelated_commands = server.commands[unrelated_start:]
        forbidden_fragments = [
            "set_agent_pid claude_code ",
            "set_agent_lifecycle claude_code ",
            "set_status claude_code ",
            "clear_notifications ",
            "notify_target_async ",
            '"method":"surface.resume.set"',
            '"method":"surface.resume.clear"',
            '"method":"feed.push"',
        ]
        for fragment in forbidden_fragments:
            if has_command(unrelated_commands, fragment):
                raise RuntimeError(
                    f"An unrelated {unrelated_subcommand} published inside the "
                    f"/clear ownership gap:\nfragment={fragment!r}\n"
                    f"commands={unrelated_commands!r}"
                )

        pending_state = json.loads(state_path.read_text())
        if unrelated_session_id in pending_state.get("sessions", {}):
            raise RuntimeError(
                f"An unrelated {unrelated_subcommand} persisted inside the "
                f"/clear ownership gap:\nstate={pending_state!r}"
            )
        if surface_id in pending_state.get("activeSessionsBySurface", {}):
            raise RuntimeError(
                f"An unrelated {unrelated_subcommand} claimed the clear-tombstoned "
                f"surface:\nstate={pending_state!r}"
            )
        if surface_id not in pending_state.get(
            "clearBackgroundWorkTransfersBySurface",
            {},
        ):
            raise RuntimeError(
                f"An unrelated {unrelated_subcommand} erased the pending clear "
                f"tombstone:\nstate={pending_state!r}"
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
                f"An unrelated {unrelated_subcommand} erased the /clear handoff:\n"
                f"clear_commands={clear_commands!r}"
            )
        if has_command_with(
            clear_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                f"An unrelated {unrelated_subcommand} made the /clear handoff idle:\n"
                f"clear_commands={clear_commands!r}"
            )

        state = json.loads(state_path.read_text())
        clear_record = state["sessions"].get(clear_session_id)
        if clear_record is None or clear_record.get("agentLifecycle") != "running":
            raise RuntimeError(
                f"The clear replacement did not inherit after an unrelated "
                f"{unrelated_subcommand}:\nclear_record={clear_record!r}\n"
                f"state={state!r}"
            )
        surface_owner = state["activeSessionsBySurface"].get(surface_id)
        if surface_owner is None or surface_owner.get("sessionId") != clear_session_id:
            raise RuntimeError(
                f"The clear replacement did not reclaim ownership after an unrelated "
                f"{unrelated_subcommand}:\nsurface_owner={surface_owner!r}\n"
                f"state={state!r}"
            )


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
        source_env["CMUX_CLAUDE_PID"] = str(os.getpid())
        stale_env = env.copy()
        stale_env["CMUX_CLAUDE_PID"] = "1"

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


def verify_clear_handoff_outlives_creator_budget_across_readers(
    cli_path: str,
) -> None:
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
        # A different pane's default-budget reader must not shorten the
        # creator's explicitly configured lifetime.
        transfer["updatedAt"] = 0
        state_path.write_text(json.dumps(state))
        default_reader_env = hook_environment(
            server,
            workspace_id,
            surface_id,
            state_path,
        )

        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": clear_session_id, "source": "clear", "cwd": "/tmp"},
            default_reader_env,
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


def verify_repeated_clear_end_does_not_retire_replacement(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"repeated-old-{uuid.uuid4().hex}"
    clear_session_id = f"repeated-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "repeated-clear-state.json"
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
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": clear_session_id, "source": "clear", "cwd": "/tmp"},
            env,
        )

        # Claude can deliver a repeated or late SessionEnd for the retired ID.
        # It must not fall back to the replacement session on the same surface.
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "reason": "clear", "cwd": "/tmp"},
            env,
        )

        state = json.loads(state_path.read_text())
        clear_record = state.get("sessions", {}).get(clear_session_id)
        if clear_record is None:
            raise RuntimeError(
                "A repeated clear end retired the replacement session:\n"
                f"state={state!r}"
            )
        if clear_record.get("agentLifecycle") != "running":
            raise RuntimeError(
                "A repeated clear end changed the replacement lifecycle:\n"
                f"clear_record={clear_record!r}"
            )

        prompt_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": clear_session_id,
                "turn_id": "turn-2",
                "cwd": "/tmp",
            },
            env,
        )
        prompt_commands = server.commands[prompt_start:]
        if not has_command_with(
            prompt_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "The repeated clear end tombstoned the replacement session:\n"
                f"prompt_commands={prompt_commands!r}"
            )


def verify_guessed_clear_end_uses_stored_surface(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    guessed_surface_id = str(uuid.uuid4()).upper()
    old_session_id = f"guessed-end-old-{uuid.uuid4().hex}"
    clear_session_id = f"guessed-end-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "guessed-end-state.json"
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

        fallback_env = env.copy()
        fallback_env.pop("CMUX_SURFACE_ID")
        server.delivery_target_available = False
        server.listed_surface_ids = [guessed_surface_id, surface_id]
        end_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {"session_id": old_session_id, "reason": "clear", "cwd": "/tmp"},
            fallback_env,
        )
        end_commands = server.commands[end_start:]
        if has_command(
            end_commands,
            f"clear_agent_pid claude_code --tab={workspace_id} --panel={surface_id}",
        ):
            raise RuntimeError(
                "A guessed SessionEnd route cleared live background work:\n"
                f"end_commands={end_commands!r}"
            )

        state = json.loads(state_path.read_text())
        transfers = state.get("clearBackgroundWorkTransfersBySurface", {})
        if surface_id not in transfers or guessed_surface_id in transfers:
            raise RuntimeError(
                "A guessed SessionEnd surface replaced the stored ownership key:\n"
                f"state={state!r}"
            )

        server.delivery_target_available = True
        server.listed_surface_ids = [surface_id]
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
                "The stored surface could not consume its clear handoff:\n"
                f"clear_commands={clear_commands!r}"
            )


def verify_authoritative_resume_supersedes_clear_tombstone(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"resume-source-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "resume-clear-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": session_id,
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
            {"session_id": session_id, "reason": "clear", "cwd": "/tmp"},
            env,
        )

        resume_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": session_id, "source": "resume", "cwd": "/tmp"},
            env,
        )
        resume_commands = server.commands[resume_start:]
        if not has_command_with(
            resume_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "An authoritative resume could not supersede its clear tombstone:\n"
                f"resume_commands={resume_commands!r}"
            )

        state = json.loads(state_path.read_text())
        transfers = state.get("clearBackgroundWorkTransfersBySurface", {})
        if surface_id in transfers:
            raise RuntimeError(
                "An authoritative resume left its clear tombstone active:\n"
                f"state={state!r}"
            )

        prompt_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": session_id, "turn_id": "turn-2", "cwd": "/tmp"},
            env,
        )
        prompt_commands = server.commands[prompt_start:]
        if not has_command_with(
            prompt_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "The resumed session remained blocked by its clear tombstone:\n"
                f"prompt_commands={prompt_commands!r}"
            )


def verify_unproven_process_cannot_consume_clear_handoff(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    retired_session_id = f"unproven-retired-{uuid.uuid4().hex}"
    clear_session_id = f"unproven-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "unproven-clear-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": retired_session_id,
                "turn_id": "turn-1",
                "cwd": "/tmp",
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": retired_session_id,
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
            {
                "session_id": retired_session_id,
                "reason": "clear",
                "cwd": "/tmp",
            },
            env,
        )

        unproven_env = env.copy()
        unproven_env.pop("CMUX_CLAUDE_PID")
        rejected_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": clear_session_id,
                "source": "clear",
                "cwd": "/tmp",
            },
            unproven_env,
        )
        rejected_commands = server.commands[rejected_start:]
        forbidden_fragments = [
            "set_agent_pid claude_code ",
            "set_agent_lifecycle claude_code ",
            "set_status claude_code ",
            "clear_notifications ",
            '"method":"surface.resume.set"',
        ]
        for fragment in forbidden_fragments:
            if has_command(rejected_commands, fragment):
                raise RuntimeError(
                    "An identity-free process consumed a clear handoff:\n"
                    f"fragment={fragment!r}\ncommands={rejected_commands!r}"
                )

        state = json.loads(state_path.read_text())
        transfers = state.get("clearBackgroundWorkTransfersBySurface", {})
        if surface_id not in transfers:
            raise RuntimeError(
                "An identity-free process erased the proven clear handoff:\n"
                f"state={state!r}"
            )

        matching_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": clear_session_id,
                "source": "clear",
                "cwd": "/tmp",
            },
            env,
        )
        matching_commands = server.commands[matching_start:]
        if not has_command_with(
            matching_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "The proven process could not consume its clear handoff:\n"
                f"matching_commands={matching_commands!r}"
            )


def verify_vacant_surface_accepts_authoritative_resume(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"ordinary-resume-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "ordinary-resume-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        resume_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": session_id, "source": "resume", "cwd": "/tmp"},
            env,
        )
        resume_commands = server.commands[resume_start:]
        if not has_command_with(
            resume_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "An ordinary resume did not establish an idle vacant surface:\n"
                f"resume_commands={resume_commands!r}"
            )

        state = json.loads(state_path.read_text())
        surface_owner = state["activeSessionsBySurface"][surface_id]
        if surface_owner.get("sessionId") != session_id:
            raise RuntimeError(
                "An ordinary resume did not claim its vacant surface:\n"
                f"surface_owner={surface_owner!r}\nstate={state!r}"
            )
        resume_record = state["sessions"][session_id]
        if resume_record.get("agentLifecycle") != "idle":
            raise RuntimeError(
                "An ordinary resume did not persist its idle lifecycle:\n"
                f"resume_record={resume_record!r}"
            )


def verify_inactive_session_resume_requires_newer_generation(cli_path: str) -> None:
    with live_process_pid() as older_pid:
        with live_process_pid() as newer_pid:
            for replay_kind in ["older", "same", "unavailable"]:
                workspace_id = str(uuid.uuid4()).upper()
                surface_id = str(uuid.uuid4()).upper()
                session_id = f"inactive-{replay_kind}-{uuid.uuid4().hex}"

                with HookSocketServer(
                    workspace_id=workspace_id,
                    surface_id=surface_id,
                ) as server:
                    state_path = (
                        Path(server.root.name)
                        / f"inactive-{replay_kind}-resume-state.json"
                    )
                    env = hook_environment(
                        server,
                        workspace_id,
                        surface_id,
                        state_path,
                    )
                    newer_env = env.copy()
                    newer_env["CMUX_CLAUDE_PID"] = str(newer_pid)
                    run_claude_hook(
                        cli_path,
                        server.socket_path,
                        "session-start",
                        {
                            "session_id": session_id,
                            "source": "startup",
                            "cwd": "/tmp",
                        },
                        newer_env,
                    )

                    replay_env = newer_env.copy()
                    if replay_kind == "older":
                        replay_env["CMUX_CLAUDE_PID"] = str(older_pid)
                    elif replay_kind == "unavailable":
                        replay_env.pop("CMUX_CLAUDE_PID")

                    replay_start = len(server.commands)
                    run_claude_hook(
                        cli_path,
                        server.socket_path,
                        "session-start",
                        {
                            "session_id": session_id,
                            "source": "resume",
                            "cwd": "/tmp",
                        },
                        replay_env,
                    )
                    replay_commands = server.commands[replay_start:]
                    forbidden_fragments = [
                        "set_agent_pid claude_code ",
                        "set_agent_lifecycle claude_code ",
                        "set_status claude_code ",
                        "clear_notifications ",
                        '"method":"surface.resume.set"',
                        '"method":"surface.resume.clear"',
                        '"method":"feed.push"',
                    ]
                    for fragment in forbidden_fragments:
                        if has_command(replay_commands, fragment):
                            raise RuntimeError(
                                f"An inactive session accepted a {replay_kind} "
                                f"generation resume:\nfragment={fragment!r}\n"
                                f"commands={replay_commands!r}"
                            )

                    state = json.loads(state_path.read_text())
                    record = state["sessions"][session_id]
                    if record.get("pid") != newer_pid:
                        raise RuntimeError(
                            f"A {replay_kind} resume rewrote an inactive session:\n"
                            f"record={record!r}"
                        )
                    if surface_id in state.get("activeSessionsBySurface", {}):
                        raise RuntimeError(
                            f"A {replay_kind} resume claimed an inactive session's "
                            f"surface:\nstate={state!r}"
                        )

            workspace_id = str(uuid.uuid4()).upper()
            surface_id = str(uuid.uuid4()).upper()
            session_id = f"inactive-newer-{uuid.uuid4().hex}"
            with HookSocketServer(
                workspace_id=workspace_id,
                surface_id=surface_id,
            ) as server:
                state_path = Path(server.root.name) / "inactive-newer-resume-state.json"
                env = hook_environment(server, workspace_id, surface_id, state_path)
                older_env = env.copy()
                older_env["CMUX_CLAUDE_PID"] = str(older_pid)
                newer_env = env.copy()
                newer_env["CMUX_CLAUDE_PID"] = str(newer_pid)
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-start",
                    {
                        "session_id": session_id,
                        "source": "startup",
                        "cwd": "/tmp",
                    },
                    older_env,
                )

                resume_start = len(server.commands)
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-start",
                    {
                        "session_id": session_id,
                        "source": "resume",
                        "cwd": "/tmp",
                    },
                    newer_env,
                )
                resume_commands = server.commands[resume_start:]
                if not has_command_with(
                    resume_commands,
                    f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
                    f"--panel={surface_id}",
                ):
                    raise RuntimeError(
                        "A proven newer generation could not claim an inactive "
                        f"session:\ncommands={resume_commands!r}"
                    )

                state = json.loads(state_path.read_text())
                record = state["sessions"][session_id]
                surface_owner = state["activeSessionsBySurface"][surface_id]
                if (
                    record.get("pid") != newer_pid
                    or surface_owner.get("sessionId") != session_id
                ):
                    raise RuntimeError(
                        "A proven newer resume did not publish inactive-session "
                        f"ownership:\nrecord={record!r}\n"
                        f"surface_owner={surface_owner!r}"
                    )


def verify_older_generation_resume_is_rejected(cli_path: str) -> None:
    with live_process_pid() as older_pid:
        with live_process_pid() as newer_pid:
            workspace_id = str(uuid.uuid4()).upper()
            surface_id = str(uuid.uuid4()).upper()
            session_id = f"newer-live-{uuid.uuid4().hex}"

            with HookSocketServer(
                workspace_id=workspace_id,
                surface_id=surface_id,
            ) as server:
                state_path = Path(server.root.name) / "older-live-resume-state.json"
                env = hook_environment(server, workspace_id, surface_id, state_path)
                older_env = env.copy()
                older_env["CMUX_CLAUDE_PID"] = str(older_pid)
                newer_env = env.copy()
                newer_env["CMUX_CLAUDE_PID"] = str(newer_pid)

                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-start",
                    {"session_id": session_id, "source": "resume", "cwd": "/tmp"},
                    newer_env,
                )
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "prompt-submit",
                    {
                        "session_id": session_id,
                        "turn_id": "newer-turn",
                        "cwd": "/tmp",
                    },
                    newer_env,
                )

                replay_start = len(server.commands)
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-start",
                    {"session_id": session_id, "source": "resume", "cwd": "/tmp"},
                    older_env,
                )
                replay_commands = server.commands[replay_start:]
                if has_command_with(
                    replay_commands,
                    f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
                    f"--panel={surface_id}",
                ) or has_command(
                    replay_commands,
                    f"set_agent_pid claude_code {older_pid}",
                ):
                    raise RuntimeError(
                        "An older process generation replaced a live same-session "
                        f"owner:\ncommands={replay_commands!r}"
                    )

                state = json.loads(state_path.read_text())
                record = state["sessions"][session_id]
                if (
                    record.get("pid") != newer_pid
                    or record.get("agentLifecycle") != "running"
                ):
                    raise RuntimeError(
                        "An older resume rewrote the live generation record:\n"
                        f"record={record!r}"
                    )

            workspace_id = str(uuid.uuid4()).upper()
            surface_id = str(uuid.uuid4()).upper()
            stopped_session_id = f"newer-stopped-{uuid.uuid4().hex}"
            replay_session_id = f"older-replay-{uuid.uuid4().hex}"

            with HookSocketServer(
                workspace_id=workspace_id,
                surface_id=surface_id,
            ) as server:
                state_path = Path(server.root.name) / "older-stopped-resume-state.json"
                env = hook_environment(server, workspace_id, surface_id, state_path)
                older_env = env.copy()
                older_env["CMUX_CLAUDE_PID"] = str(older_pid)
                newer_env = env.copy()
                newer_env["CMUX_CLAUDE_PID"] = str(newer_pid)

                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-start",
                    {
                        "session_id": stopped_session_id,
                        "source": "resume",
                        "cwd": "/tmp",
                    },
                    newer_env,
                )
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "prompt-submit",
                    {
                        "session_id": stopped_session_id,
                        "turn_id": "stopped-turn",
                        "cwd": "/tmp",
                    },
                    newer_env,
                )
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "stop",
                    {
                        "session_id": stopped_session_id,
                        "turn_id": "stopped-turn",
                        "cwd": "/tmp",
                        "last_assistant_message": "newer owner stopped",
                        "background_tasks": [],
                        "session_crons": [],
                    },
                    newer_env,
                )

                replay_start = len(server.commands)
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-start",
                    {
                        "session_id": replay_session_id,
                        "source": "resume",
                        "cwd": "/tmp",
                    },
                    older_env,
                )
                replay_commands = server.commands[replay_start:]
                if has_command_with(
                    replay_commands,
                    f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
                    f"--panel={surface_id}",
                ) or has_command(
                    replay_commands,
                    f"set_agent_pid claude_code {older_pid}",
                ):
                    raise RuntimeError(
                        "An older process generation replaced a newer stopped "
                        f"owner:\ncommands={replay_commands!r}"
                    )

                state = json.loads(state_path.read_text())
                surface_owner = state["activeSessionsBySurface"][surface_id]
                if surface_owner.get("sessionId") != stopped_session_id:
                    raise RuntimeError(
                        "An older resume stole the stopped owner's surface:\n"
                        f"surface_owner={surface_owner!r}\nstate={state!r}"
                    )
                if replay_session_id in state["sessions"]:
                    raise RuntimeError(
                        "An older resume persisted over the stopped owner:\n"
                        f"state={state!r}"
                    )

            workspace_id = str(uuid.uuid4()).upper()
            surface_id = str(uuid.uuid4()).upper()
            retired_session_id = f"newer-retired-{uuid.uuid4().hex}"

            with HookSocketServer(
                workspace_id=workspace_id,
                surface_id=surface_id,
            ) as server:
                state_path = Path(server.root.name) / "older-retired-resume-state.json"
                env = hook_environment(server, workspace_id, surface_id, state_path)
                older_env = env.copy()
                older_env["CMUX_CLAUDE_PID"] = str(older_pid)
                newer_env = env.copy()
                newer_env["CMUX_CLAUDE_PID"] = str(newer_pid)

                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "prompt-submit",
                    {
                        "session_id": retired_session_id,
                        "turn_id": "retired-turn",
                        "cwd": "/tmp",
                    },
                    newer_env,
                )
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "stop",
                    {
                        "session_id": retired_session_id,
                        "turn_id": "retired-turn",
                        "cwd": "/tmp",
                        "last_assistant_message": "background work continues",
                        "background_tasks": [{"id": "task-1", "status": "running"}],
                        "session_crons": [],
                    },
                    newer_env,
                )
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-end",
                    {
                        "session_id": retired_session_id,
                        "reason": "clear",
                        "cwd": "/tmp",
                    },
                    newer_env,
                )

                replay_start = len(server.commands)
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-start",
                    {
                        "session_id": retired_session_id,
                        "source": "resume",
                        "cwd": "/tmp",
                    },
                    older_env,
                )
                replay_commands = server.commands[replay_start:]
                if has_command_with(
                    replay_commands,
                    f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
                    f"--panel={surface_id}",
                ) or has_command(
                    replay_commands,
                    f"set_agent_pid claude_code {older_pid}",
                ):
                    raise RuntimeError(
                        "An older process generation superseded a newer retired "
                        f"generation:\ncommands={replay_commands!r}"
                    )

                state = json.loads(state_path.read_text())
                transfers = state.get("clearBackgroundWorkTransfersBySurface", {})
                if surface_id not in transfers:
                    raise RuntimeError(
                        "An older resume consumed the newer generation's handoff:\n"
                        f"state={state!r}"
                    )
                if retired_session_id in state.get("sessions", {}):
                    raise RuntimeError(
                        "An older resume recreated the retired session record:\n"
                        f"state={state!r}"
                    )


def verify_new_generation_resumes_same_session(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"same-session-resume-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "same-session-resume-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": session_id, "source": "resume", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": session_id,
                "turn_id": "original-turn",
                "cwd": "/tmp",
            },
            env,
        )

        duplicate_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": session_id, "source": "resume", "cwd": "/tmp"},
            env,
        )
        duplicate_commands = server.commands[duplicate_start:]
        if has_command_with(
            duplicate_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A duplicate same-generation resume idled the active turn:\n"
                f"duplicate_commands={duplicate_commands!r}"
            )

        with live_process_pid() as replacement_pid:
            replacement_env = env.copy()
            replacement_env["CMUX_CLAUDE_PID"] = str(replacement_pid)
            replacement_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "session-start",
                {"session_id": session_id, "source": "resume", "cwd": "/tmp"},
                replacement_env,
            )
            replacement_commands = server.commands[replacement_start:]
            if not has_command_with(
                replacement_commands,
                f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "A proven new process generation could not resume its stored session:\n"
                    f"replacement_commands={replacement_commands!r}"
                )

            state = json.loads(state_path.read_text())
            record = state["sessions"][session_id]
            if record.get("pid") != replacement_pid:
                raise RuntimeError(
                    "The resumed session kept its stale process identity:\n"
                    f"record={record!r}"
                )

            stale_events: list[tuple[str, dict[str, object]]] = [
                (
                    "prompt-submit",
                    {
                        "session_id": session_id,
                        "turn_id": "displaced-prompt",
                        "cwd": "/tmp",
                    },
                ),
                (
                    "stop",
                    {
                        "session_id": session_id,
                        "turn_id": "displaced-stop",
                        "cwd": "/tmp",
                        "last_assistant_message": "old process stopped late",
                        "background_tasks": [],
                        "session_crons": [],
                    },
                ),
            ]
            for stale_subcommand, stale_payload in stale_events:
                stale_start = len(server.commands)
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    stale_subcommand,
                    stale_payload,
                    env,
                )
                stale_commands = server.commands[stale_start:]
                forbidden_fragments = [
                    "set_agent_pid claude_code ",
                    "set_agent_lifecycle claude_code ",
                    "set_status claude_code ",
                    "clear_notifications ",
                    "notify_target_async ",
                    '"method":"surface.resume.set"',
                    '"method":"surface.resume.clear"',
                    '"method":"feed.push"',
                ]
                for fragment in forbidden_fragments:
                    if has_command(stale_commands, fragment):
                        raise RuntimeError(
                            f"A displaced process {stale_subcommand} published over "
                            f"the resumed generation:\nfragment={fragment!r}\n"
                            f"commands={stale_commands!r}"
                        )

                state = json.loads(state_path.read_text())
                record = state["sessions"][session_id]
                if (
                    record.get("pid") != replacement_pid
                    or record.get("agentLifecycle") != "idle"
                ):
                    raise RuntimeError(
                        f"A displaced process {stale_subcommand} rewrote the resumed "
                        f"generation:\nrecord={record!r}"
                    )
                surface_owner = state["activeSessionsBySurface"][surface_id]
                if surface_owner.get("sessionId") != session_id or surface_owner.get(
                    "turnId"
                ):
                    raise RuntimeError(
                        f"A displaced process {stale_subcommand} rewrote active "
                        f"ownership:\nsurface_owner={surface_owner!r}\nstate={state!r}"
                    )


def verify_new_generation_resume_clears_stale_background_work(
    cli_path: str,
) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"stale-work-resume-{uuid.uuid4().hex}"
    clear_session_id = f"stale-work-clear-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "stale-work-resume-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": session_id, "turn_id": "old-turn", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": session_id,
                "turn_id": "old-turn",
                "cwd": "/tmp",
                "last_assistant_message": "old background work continues",
                "background_tasks": [{"id": "old-task", "status": "running"}],
                "session_crons": [],
            },
            env,
        )

        # SessionEnd can be missed when the old Claude process exits. A proven
        # newer process resumes the stored conversation without inheriting the
        # old generation's process-owned background task.
        with live_process_pid() as replacement_pid:
            replacement_env = env.copy()
            replacement_env["CMUX_CLAUDE_PID"] = str(replacement_pid)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "session-start",
                {"session_id": session_id, "source": "resume", "cwd": "/tmp"},
                replacement_env,
            )
            run_claude_hook(
                cli_path,
                server.socket_path,
                "session-end",
                {"session_id": session_id, "reason": "clear", "cwd": "/tmp"},
                replacement_env,
            )

            clear_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "session-start",
                {
                    "session_id": clear_session_id,
                    "source": "clear",
                    "cwd": "/tmp",
                },
                replacement_env,
            )
            clear_commands = server.commands[clear_start:]
            if not has_command_with(
                clear_commands,
                f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "A clear after a new-generation resume inherited stale "
                    f"background work:\ncommands={clear_commands!r}"
                )
            if has_command_with(
                clear_commands,
                f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "A new generation's clear became Running from old Stop state:\n"
                    f"commands={clear_commands!r}"
                )

            state = json.loads(state_path.read_text())
            clear_record = state["sessions"][clear_session_id]
            if clear_record.get("agentLifecycle") != "idle":
                raise RuntimeError(
                    "A new-generation clear persisted stale running lifecycle:\n"
                    f"clear_record={clear_record!r}"
                )


def verify_new_generation_resume_discards_source_handoff(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"source-generation-resume-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "source-generation-resume-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": session_id, "turn_id": "retired-turn", "cwd": "/tmp"},
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": session_id,
                "turn_id": "retired-turn",
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
            {"session_id": session_id, "reason": "clear", "cwd": "/tmp"},
            env,
        )

        with live_process_pid() as replacement_pid:
            replacement_env = env.copy()
            replacement_env["CMUX_CLAUDE_PID"] = str(replacement_pid)
            resume_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "session-start",
                {"session_id": session_id, "source": "resume", "cwd": "/tmp"},
                replacement_env,
            )
            resume_commands = server.commands[resume_start:]
            if not has_command_with(
                resume_commands,
                f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "A new process generation could not resume the cleared source:\n"
                    f"resume_commands={resume_commands!r}"
                )
            if has_command_with(
                resume_commands,
                f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "A new process generation inherited retired background work:\n"
                    f"resume_commands={resume_commands!r}"
                )

            state = json.loads(state_path.read_text())
            transfers = state.get("clearBackgroundWorkTransfersBySurface", {})
            if surface_id in transfers:
                raise RuntimeError(
                    "A new process generation left the retired handoff blocking hooks:\n"
                    f"state={state!r}"
                )
            record = state["sessions"][session_id]
            if record.get("pid") != replacement_pid:
                raise RuntimeError(
                    "The cleared-source resume kept its retired process identity:\n"
                    f"record={record!r}"
                )

            prompt_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "prompt-submit",
                {
                    "session_id": session_id,
                    "turn_id": "replacement-turn",
                    "cwd": "/tmp",
                },
                replacement_env,
            )
            prompt_commands = server.commands[prompt_start:]
            if not has_command_with(
                prompt_commands,
                f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "The cleared-source resume remained blocked by its old handoff:\n"
                    f"prompt_commands={prompt_commands!r}"
                )


def verify_late_resume_cannot_replace_clear_successor(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    retired_session_id = f"late-resume-retired-{uuid.uuid4().hex}"
    successor_session_id = f"late-resume-successor-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "late-resume-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": retired_session_id,
                "turn_id": "retired-turn",
                "cwd": "/tmp",
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": retired_session_id,
                "turn_id": "retired-turn",
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
            {
                "session_id": retired_session_id,
                "reason": "clear",
                "cwd": "/tmp",
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": successor_session_id,
                "source": "clear",
                "cwd": "/tmp",
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": successor_session_id,
                "turn_id": "successor-turn",
                "cwd": "/tmp",
            },
            env,
        )

        late_resume_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": retired_session_id,
                "source": "resume",
                "cwd": "/tmp",
            },
            env,
        )
        late_resume_commands = server.commands[late_resume_start:]
        if has_command_with(
            late_resume_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A delayed resume made the active clear successor idle:\n"
                f"late_resume_commands={late_resume_commands!r}"
            )

        state = json.loads(state_path.read_text())
        surface_owner = state["activeSessionsBySurface"][surface_id]
        if surface_owner.get("sessionId") != successor_session_id:
            raise RuntimeError(
                "A delayed resume replaced the active clear successor:\n"
                f"surface_owner={surface_owner!r}\nstate={state!r}"
            )

        successor_stop_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": successor_session_id,
                "turn_id": "successor-turn",
                "cwd": "/tmp",
                "last_assistant_message": "successor turn completed",
                "background_tasks": [],
                "session_crons": [],
            },
            env,
        )
        successor_stop_commands = server.commands[successor_stop_start:]
        if not has_command_with(
            successor_stop_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "The clear successor lost ownership after a delayed resume:\n"
                f"successor_stop_commands={successor_stop_commands!r}"
            )

        stopped_late_resume_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": retired_session_id,
                "source": "resume",
                "cwd": "/tmp",
            },
            env,
        )
        stopped_late_resume_commands = server.commands[stopped_late_resume_start:]
        if has_command_with(
            stopped_late_resume_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A delayed resume replaced the stopped clear successor:\n"
                f"stopped_late_resume_commands={stopped_late_resume_commands!r}"
            )

        state = json.loads(state_path.read_text())
        stopped_surface_owner = state["activeSessionsBySurface"][surface_id]
        if stopped_surface_owner.get("sessionId") != successor_session_id:
            raise RuntimeError(
                "A delayed resume stole ownership after the clear successor stopped:\n"
                f"stopped_surface_owner={stopped_surface_owner!r}\nstate={state!r}"
            )

        next_prompt_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": successor_session_id,
                "turn_id": "successor-turn-2",
                "cwd": "/tmp",
            },
            env,
        )
        next_prompt_commands = server.commands[next_prompt_start:]
        if not has_command_with(
            next_prompt_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "The stopped successor could not begin another turn after a delayed resume:\n"
                f"next_prompt_commands={next_prompt_commands!r}"
            )


def verify_session_end_requires_current_process_generation(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"session-end-generation-{uuid.uuid4().hex}"

    with live_process_pid() as displaced_pid:
        with live_process_pid() as replacement_pid:
            with HookSocketServer(
                workspace_id=workspace_id,
                surface_id=surface_id,
            ) as server:
                state_path = Path(server.root.name) / "session-end-generation-state.json"
                env = hook_environment(server, workspace_id, surface_id, state_path)
                displaced_env = env.copy()
                displaced_env["CMUX_CLAUDE_PID"] = str(displaced_pid)
                replacement_env = env.copy()
                replacement_env["CMUX_CLAUDE_PID"] = str(replacement_pid)

                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "prompt-submit",
                    {
                        "session_id": session_id,
                        "turn_id": "displaced-turn",
                        "cwd": "/tmp",
                    },
                    displaced_env,
                )
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "stop",
                    {
                        "session_id": session_id,
                        "turn_id": "displaced-turn",
                        "cwd": "/tmp",
                        "last_assistant_message": "old generation stopped",
                        "background_tasks": [],
                        "session_crons": [],
                    },
                    displaced_env,
                )
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-start",
                    {
                        "session_id": session_id,
                        "source": "resume",
                        "cwd": "/tmp",
                    },
                    replacement_env,
                )

                stale_end_start = len(server.commands)
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-end",
                    {
                        "session_id": session_id,
                        "reason": "clear",
                        "cwd": "/tmp",
                    },
                    displaced_env,
                )
                stale_end_commands = server.commands[stale_end_start:]
                assert_no_claude_lifecycle_mutations(
                    stale_end_commands,
                    context="A displaced-process SessionEnd",
                )

                state = json.loads(state_path.read_text())
                record = state["sessions"].get(session_id)
                if (
                    record is None
                    or record.get("pid") != replacement_pid
                    or record.get("agentLifecycle") != "idle"
                ):
                    raise RuntimeError(
                        "A displaced-process SessionEnd consumed the replacement "
                        f"generation:\nrecord={record!r}\nstate={state!r}"
                    )
                surface_owner = state["activeSessionsBySurface"].get(surface_id)
                if (
                    surface_owner is None
                    or surface_owner.get("sessionId") != session_id
                ):
                    raise RuntimeError(
                        "A displaced-process SessionEnd cleared replacement "
                        f"ownership:\nsurface_owner={surface_owner!r}\nstate={state!r}"
                    )
                if surface_id in state.get(
                    "clearBackgroundWorkTransfersBySurface",
                    {},
                ):
                    raise RuntimeError(
                        "A displaced-process SessionEnd created a clear tombstone "
                        f"for the replacement generation:\nstate={state!r}"
                    )


def verify_resume_checks_displaced_and_inactive_target_generations(
    cli_path: str,
) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    displaced_session_id = f"resume-displaced-{uuid.uuid4().hex}"
    target_session_id = f"resume-inactive-target-{uuid.uuid4().hex}"

    with live_process_pid() as displaced_pid:
        with live_process_pid() as incoming_pid:
            with live_process_pid() as target_pid:
                with HookSocketServer(
                    workspace_id=workspace_id,
                    surface_id=surface_id,
                ) as server:
                    state_path = (
                        Path(server.root.name)
                        / "resume-dual-generation-state.json"
                    )
                    env = hook_environment(
                        server,
                        workspace_id,
                        surface_id,
                        state_path,
                    )
                    displaced_env = env.copy()
                    displaced_env["CMUX_CLAUDE_PID"] = str(displaced_pid)
                    incoming_env = env.copy()
                    incoming_env["CMUX_CLAUDE_PID"] = str(incoming_pid)
                    target_fixture_path = (
                        Path(server.root.name)
                        / "resume-inactive-target-fixture-state.json"
                    )
                    target_fixture_env = env.copy()
                    target_fixture_env["CMUX_CLAUDE_PID"] = str(target_pid)
                    target_fixture_env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(
                        target_fixture_path
                    )

                    # Capture the target's authenticated newest generation
                    # through the real hook path in an isolated store.
                    run_claude_hook(
                        cli_path,
                        server.socket_path,
                        "session-start",
                        {
                            "session_id": target_session_id,
                            "source": "startup",
                            "cwd": "/tmp",
                        },
                        target_fixture_env,
                    )
                    target_record = json.loads(
                        target_fixture_path.read_text()
                    )["sessions"][target_session_id]

                    # Install the older stopped owner, then seed the authenticated
                    # target record as inactive without changing pane ownership.
                    run_claude_hook(
                        cli_path,
                        server.socket_path,
                        "prompt-submit",
                        {
                            "session_id": displaced_session_id,
                            "turn_id": "displaced-turn",
                            "cwd": "/tmp",
                        },
                        displaced_env,
                    )
                    run_claude_hook(
                        cli_path,
                        server.socket_path,
                        "stop",
                        {
                            "session_id": displaced_session_id,
                            "turn_id": "displaced-turn",
                            "cwd": "/tmp",
                            "last_assistant_message": "displaced owner stopped",
                            "background_tasks": [],
                            "session_crons": [],
                        },
                        displaced_env,
                    )
                    state = json.loads(state_path.read_text())
                    state["sessions"][target_session_id] = target_record
                    state_path.write_text(json.dumps(state))

                    resume_start = len(server.commands)
                    run_claude_hook(
                        cli_path,
                        server.socket_path,
                        "session-start",
                        {
                            "session_id": target_session_id,
                            "source": "resume",
                            "cwd": "/tmp",
                        },
                        incoming_env,
                    )
                    resume_commands = server.commands[resume_start:]
                    assert_no_claude_lifecycle_mutations(
                        resume_commands,
                        context="A resume older than its inactive target",
                    )

                    state = json.loads(state_path.read_text())
                    target_record = state["sessions"].get(target_session_id)
                    if target_record is None or target_record.get("pid") != target_pid:
                        raise RuntimeError(
                            "A resume newer than the displaced owner but older than "
                            "its inactive target rewrote that target:\n"
                            f"target_record={target_record!r}\nstate={state!r}"
                        )
                    surface_owner = state["activeSessionsBySurface"].get(surface_id)
                    if (
                        surface_owner is None
                        or surface_owner.get("sessionId") != displaced_session_id
                    ):
                        raise RuntimeError(
                            "A resume that failed its target-generation check stole "
                            f"the stopped owner's pane:\nstate={state!r}"
                        )


def verify_only_prompt_submit_replaces_stopped_owner(cli_path: str) -> None:
    events: list[tuple[str, dict[str, object]]] = [
        (
            "notification",
            {
                "notification_type": "permission_prompt",
                "message": "late permission request",
            },
        ),
        (
            "pre-tool-use",
            {
                "tool_name": "Bash",
                "tool_input": {"command": "echo late"},
            },
        ),
        (
            "push-notification",
            {
                "hook_event_name": "PostToolUse",
                "tool_name": "PushNotification",
                "tool_input": {"message": "late push"},
                "tool_response": {
                    "message": "late push",
                    "localSent": True,
                },
            },
        ),
        (
            "stop",
            {
                "turn_id": "late-turn",
                "last_assistant_message": "late stop",
                "background_tasks": [],
                "session_crons": [],
            },
        ),
    ]

    for subcommand, event_fields in events:
        workspace_id = str(uuid.uuid4()).upper()
        surface_id = str(uuid.uuid4()).upper()
        stopped_session_id = f"{subcommand}-stopped-{uuid.uuid4().hex}"
        candidate_session_id = f"{subcommand}-candidate-{uuid.uuid4().hex}"
        with HookSocketServer(
            workspace_id=workspace_id,
            surface_id=surface_id,
        ) as server:
            state_path = (
                Path(server.root.name)
                / f"{subcommand}-stopped-owner-state.json"
            )
            env = hook_environment(server, workspace_id, surface_id, state_path)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "prompt-submit",
                {
                    "session_id": stopped_session_id,
                    "turn_id": "owner-turn",
                    "cwd": "/tmp",
                },
                env,
            )
            run_claude_hook(
                cli_path,
                server.socket_path,
                "stop",
                {
                    "session_id": stopped_session_id,
                    "turn_id": "owner-turn",
                    "cwd": "/tmp",
                    "last_assistant_message": "owner stopped",
                    "background_tasks": [],
                    "session_crons": [],
                },
                env,
            )

            candidate_payload = {
                "session_id": candidate_session_id,
                "cwd": "/tmp",
                **event_fields,
            }
            candidate_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                subcommand,
                candidate_payload,
                env,
            )
            candidate_commands = server.commands[candidate_start:]
            assert_no_claude_lifecycle_mutations(
                candidate_commands,
                context=f"A different-session {subcommand} after Stop",
            )

            state = json.loads(state_path.read_text())
            if candidate_session_id in state.get("sessions", {}):
                raise RuntimeError(
                    f"A different-session {subcommand} persisted over a stopped "
                    f"owner:\nstate={state!r}"
                )
            surface_owner = state["activeSessionsBySurface"].get(surface_id)
            if (
                surface_owner is None
                or surface_owner.get("sessionId") != stopped_session_id
            ):
                raise RuntimeError(
                    f"A different-session {subcommand} replaced a stopped owner:\n"
                    f"state={state!r}"
                )

            # UserPromptSubmit is the turn-establishing event that may claim
            # a stopped owner's pane for the new session.
            prompt_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "prompt-submit",
                {
                    "session_id": candidate_session_id,
                    "turn_id": "candidate-turn",
                    "cwd": "/tmp",
                },
                env,
            )
            prompt_commands = server.commands[prompt_start:]
            if not has_command_with(
                prompt_commands,
                f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "UserPromptSubmit could not claim a stopped owner's pane "
                    f"after rejected {subcommand}:\ncommands={prompt_commands!r}"
                )
            state = json.loads(state_path.read_text())
            surface_owner = state["activeSessionsBySurface"].get(surface_id)
            if (
                surface_owner is None
                or surface_owner.get("sessionId") != candidate_session_id
            ):
                raise RuntimeError(
                    "UserPromptSubmit did not establish replacement ownership "
                    f"after rejected {subcommand}:\nstate={state!r}"
                )


def verify_clear_end_without_work_creates_one_shot_tombstone(
    cli_path: str,
) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    source_session_id = f"no-work-clear-source-{uuid.uuid4().hex}"
    unrelated_session_id = f"no-work-clear-unrelated-{uuid.uuid4().hex}"
    replacement_session_id = f"no-work-clear-replacement-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "no-work-clear-tombstone-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": source_session_id,
                "turn_id": "source-turn",
                "cwd": "/tmp",
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": source_session_id,
                "turn_id": "source-turn",
                "cwd": "/tmp",
                "last_assistant_message": "no work survives",
                "background_tasks": [],
                "session_crons": [],
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {
                "session_id": source_session_id,
                "reason": "clear",
                "cwd": "/tmp",
            },
            env,
        )

        state = json.loads(state_path.read_text())
        tombstone = state.get("clearBackgroundWorkTransfersBySurface", {}).get(
            surface_id
        )
        if tombstone is None:
            raise RuntimeError(
                "SessionEnd(clear) without surviving work did not tombstone the "
                f"ownership gap:\nstate={state!r}"
            )
        if tombstone.get("preservedPendingBackgroundWork") is not False:
            raise RuntimeError(
                "The clear tombstone did not store work survival independently "
                f"from ownership:\ntombstone={tombstone!r}"
            )

        unrelated_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "notification",
            {
                "session_id": unrelated_session_id,
                "notification_type": "permission_prompt",
                "message": "late unrelated notification",
                "cwd": "/tmp",
            },
            env,
        )
        unrelated_commands = server.commands[unrelated_start:]
        assert_no_claude_lifecycle_mutations(
            unrelated_commands,
            context="An unrelated event inside a no-work clear gap",
        )

        state = json.loads(state_path.read_text())
        if unrelated_session_id in state.get("sessions", {}):
            raise RuntimeError(
                "An unrelated event persisted inside a no-work clear gap:\n"
                f"state={state!r}"
            )
        if surface_id not in state.get(
            "clearBackgroundWorkTransfersBySurface",
            {},
        ):
            raise RuntimeError(
                "An unrelated event consumed a no-work clear tombstone:\n"
                f"state={state!r}"
            )

        replacement_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": replacement_session_id,
                "source": "clear",
                "cwd": "/tmp",
            },
            env,
        )
        replacement_commands = server.commands[replacement_start:]
        if not has_command_with(
            replacement_commands,
            f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "A matching clear start did not consume its no-work tombstone "
                f"as Idle:\ncommands={replacement_commands!r}"
            )
        if has_command_with(
            replacement_commands,
            f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "Tombstone ownership was conflated with surviving work:\n"
                f"commands={replacement_commands!r}"
            )

        state = json.loads(state_path.read_text())
        if surface_id in state.get(
            "clearBackgroundWorkTransfersBySurface",
            {},
        ):
            raise RuntimeError(
                "A matching clear start did not consume the one-shot tombstone:\n"
                f"state={state!r}"
            )


def verify_clear_start_requires_session_end_transfer(
    cli_path: str,
) -> None:
    vacant_workspace_id = str(uuid.uuid4()).upper()
    vacant_surface_id = str(uuid.uuid4()).upper()
    vacant_session_id = f"clear-vacant-{uuid.uuid4().hex}"
    with HookSocketServer(
        workspace_id=vacant_workspace_id,
        surface_id=vacant_surface_id,
    ) as server:
        state_path = Path(server.root.name) / "clear-vacant-state.json"
        env = hook_environment(
            server,
            vacant_workspace_id,
            vacant_surface_id,
            state_path,
        )
        clear_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": vacant_session_id,
                "source": "clear",
                "cwd": "/tmp",
            },
            env,
        )
        clear_commands = server.commands[clear_start:]
        assert_no_claude_lifecycle_mutations(
            clear_commands,
            context="A clear start on a vacant pane without a transfer",
        )
        if state_path.exists():
            state = json.loads(state_path.read_text())
            if vacant_session_id in state.get("sessions", {}):
                raise RuntimeError(
                    "A clear start claimed a vacant pane without SessionEnd(clear):\n"
                    f"state={state!r}"
                )

    with live_process_pid() as older_pid:
        with live_process_pid() as current_pid:
            for generation_kind in ["same", "older", "unavailable"]:
                workspace_id = str(uuid.uuid4()).upper()
                surface_id = str(uuid.uuid4()).upper()
                source_session_id = (
                    f"clear-no-transfer-source-{generation_kind}-{uuid.uuid4().hex}"
                )
                replacement_session_id = (
                    f"clear-no-transfer-replacement-{generation_kind}-"
                    f"{uuid.uuid4().hex}"
                )
                with HookSocketServer(
                    workspace_id=workspace_id,
                    surface_id=surface_id,
                ) as server:
                    state_path = (
                        Path(server.root.name)
                        / f"clear-no-transfer-{generation_kind}-state.json"
                    )
                    env = hook_environment(
                        server,
                        workspace_id,
                        surface_id,
                        state_path,
                    )
                    current_env = env.copy()
                    current_env["CMUX_CLAUDE_PID"] = str(current_pid)
                    rejected_env = env.copy()
                    if generation_kind == "same":
                        rejected_env["CMUX_CLAUDE_PID"] = str(current_pid)
                    elif generation_kind == "older":
                        rejected_env["CMUX_CLAUDE_PID"] = str(older_pid)
                    else:
                        rejected_env.pop("CMUX_CLAUDE_PID", None)

                    run_claude_hook(
                        cli_path,
                        server.socket_path,
                        "prompt-submit",
                        {
                            "session_id": source_session_id,
                            "turn_id": "source-turn",
                            "cwd": "/tmp",
                        },
                        current_env,
                    )
                    run_claude_hook(
                        cli_path,
                        server.socket_path,
                        "stop",
                        {
                            "session_id": source_session_id,
                            "turn_id": "source-turn",
                            "cwd": "/tmp",
                            "last_assistant_message": "source stopped",
                            "background_tasks": [],
                            "session_crons": [],
                        },
                        current_env,
                    )

                    # SessionEnd(clear) is intentionally absent. Process
                    # generation alone cannot prove that Claude crossed a
                    # clear boundary.
                    clear_start = len(server.commands)
                    run_claude_hook(
                        cli_path,
                        server.socket_path,
                        "session-start",
                        {
                            "session_id": replacement_session_id,
                            "source": "clear",
                            "cwd": "/tmp",
                        },
                        rejected_env,
                    )
                    clear_commands = server.commands[clear_start:]
                    assert_no_claude_lifecycle_mutations(
                        clear_commands,
                        context=(
                            f"A {generation_kind}-generation clear start without "
                            "a transfer"
                        ),
                    )

                    state = json.loads(state_path.read_text())
                    if replacement_session_id in state.get("sessions", {}):
                        raise RuntimeError(
                            f"A {generation_kind}-generation clear start persisted "
                            f"without a transfer:\nstate={state!r}"
                        )
                    surface_owner = state["activeSessionsBySurface"].get(surface_id)
                    if (
                        surface_owner is None
                        or surface_owner.get("sessionId") != source_session_id
                    ):
                        raise RuntimeError(
                            f"A {generation_kind}-generation clear start stole "
                            f"ownership without a transfer:\nstate={state!r}"
                        )
                    if surface_id in state.get(
                        "clearBackgroundWorkTransfersBySurface",
                        {},
                    ):
                        raise RuntimeError(
                            f"A {generation_kind}-generation clear start invented "
                            f"a transfer:\nstate={state!r}"
                        )


def verify_non_turn_session_start_cannot_replace_stopped_owner(
    cli_path: str,
) -> None:
    for source in ["startup", "compact"]:
        workspace_id = str(uuid.uuid4()).upper()
        surface_id = str(uuid.uuid4()).upper()
        owner_session_id = f"{source}-owner-{uuid.uuid4().hex}"
        candidate_session_id = f"{source}-candidate-{uuid.uuid4().hex}"
        with HookSocketServer(
            workspace_id=workspace_id,
            surface_id=surface_id,
        ) as server:
            state_path = Path(server.root.name) / f"{source}-owner-state.json"
            env = hook_environment(server, workspace_id, surface_id, state_path)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "prompt-submit",
                {
                    "session_id": owner_session_id,
                    "turn_id": "owner-turn",
                    "cwd": "/tmp",
                },
                env,
            )
            run_claude_hook(
                cli_path,
                server.socket_path,
                "stop",
                {
                    "session_id": owner_session_id,
                    "turn_id": "owner-turn",
                    "cwd": "/tmp",
                    "last_assistant_message": "owner stopped",
                    "background_tasks": [],
                    "session_crons": [],
                },
                env,
            )

            session_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "session-start",
                {
                    "session_id": candidate_session_id,
                    "source": source,
                    "cwd": "/tmp",
                },
                env,
            )
            session_start_commands = server.commands[session_start:]
            assert_no_claude_lifecycle_mutations(
                session_start_commands,
                context=f"A {source} SessionStart after a stopped owner",
            )

            state = json.loads(state_path.read_text())
            if candidate_session_id in state.get("sessions", {}):
                raise RuntimeError(
                    f"A {source} SessionStart persisted over a stopped owner:\n"
                    f"state={state!r}"
                )
            surface_owner = state["activeSessionsBySurface"].get(surface_id)
            if (
                surface_owner is None
                or surface_owner.get("sessionId") != owner_session_id
            ):
                raise RuntimeError(
                    f"A {source} SessionStart replaced a stopped owner:\n"
                    f"state={state!r}"
                )

            prompt_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "prompt-submit",
                {
                    "session_id": candidate_session_id,
                    "turn_id": "candidate-turn",
                    "cwd": "/tmp",
                },
                env,
            )
            prompt_commands = server.commands[prompt_start:]
            if not has_command_with(
                prompt_commands,
                f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "UserPromptSubmit could not establish ownership after a "
                    f"rejected {source} SessionStart:\ncommands={prompt_commands!r}"
                )


def verify_metadata_session_start_preserves_authority(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"metadata-current-{uuid.uuid4().hex}"
    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "metadata-current-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": session_id,
                "turn_id": "current-turn",
                "cwd": "/tmp",
            },
            env,
        )

        metadata_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": session_id,
                "source": "compact",
                "cwd": "/tmp/metadata",
            },
            env,
        )
        metadata_commands = server.commands[metadata_start:]
        state = json.loads(state_path.read_text())
        record = state["sessions"].get(session_id)
        if record is None or record.get("agentLifecycle") != "running":
            raise RuntimeError(
                "A current metadata SessionStart overwrote the accepted lifecycle:\n"
                f"record={record!r}\nstate={state!r}"
            )
        if not has_command_with(
            metadata_commands,
            '"method":"feed.push"',
            '"_cmux_agent_lifecycle":"running"',
        ):
            raise RuntimeError(
                "A current metadata SessionStart did not publish the preserved "
                f"lifecycle:\ncommands={metadata_commands!r}"
            )

    with live_process_pid() as stale_pid:
        with live_process_pid() as current_pid:
            workspace_id = str(uuid.uuid4()).upper()
            surface_id = str(uuid.uuid4()).upper()
            session_id = f"metadata-stale-{uuid.uuid4().hex}"
            with HookSocketServer(
                workspace_id=workspace_id,
                surface_id=surface_id,
            ) as server:
                state_path = Path(server.root.name) / "metadata-stale-state.json"
                env = hook_environment(
                    server,
                    workspace_id,
                    surface_id,
                    state_path,
                )
                stale_env = env.copy()
                stale_env["CMUX_CLAUDE_PID"] = str(stale_pid)
                current_env = env.copy()
                current_env["CMUX_CLAUDE_PID"] = str(current_pid)
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "prompt-submit",
                    {
                        "session_id": session_id,
                        "turn_id": "current-turn",
                        "cwd": "/tmp",
                    },
                    current_env,
                )

                metadata_start = len(server.commands)
                run_claude_hook(
                    cli_path,
                    server.socket_path,
                    "session-start",
                    {
                        "session_id": session_id,
                        "source": "compact",
                        "cwd": "/tmp/stale",
                    },
                    stale_env,
                )
                metadata_commands = server.commands[metadata_start:]
                assert_no_claude_lifecycle_mutations(
                    metadata_commands,
                    context="A stale-generation metadata SessionStart",
                )
                state = json.loads(state_path.read_text())
                record = state["sessions"].get(session_id)
                if (
                    record is None
                    or record.get("pid") != current_pid
                    or record.get("agentLifecycle") != "running"
                ):
                    raise RuntimeError(
                        "A stale-generation metadata SessionStart rewrote the "
                        f"accepted record:\nrecord={record!r}\nstate={state!r}"
                    )


def verify_legacy_session_end_claim_requires_live_authoritative_identity(
    cli_path: str,
) -> None:
    cases: list[
        tuple[
            str,
            dict[str, int],
            bool,
            bool,
            bool,
        ]
    ] = [
        ("authoritative-live", {}, True, True, True),
        ("authoritative-missing", {}, False, True, False),
        ("non-authoritative-live", {}, True, False, False),
        ("partial-pid", {"pid": os.getpid()}, True, True, False),
        (
            "partial-start",
            {"pidStartSeconds": 1, "pidStartMicroseconds": 1},
            True,
            True,
            False,
        ),
    ]
    for (
        case_name,
        identity_fields,
        has_incoming_pid,
        route_is_authoritative,
        should_accept,
    ) in cases:
        workspace_id = str(uuid.uuid4()).upper()
        surface_id = str(uuid.uuid4()).upper()
        session_id = f"legacy-end-{case_name}-{uuid.uuid4().hex}"
        with HookSocketServer(
            workspace_id=workspace_id,
            surface_id=surface_id,
        ) as server:
            state_path = Path(server.root.name) / f"{case_name}-state.json"
            now = time.time()
            record: dict[str, object] = {
                "sessionId": session_id,
                "workspaceId": workspace_id,
                "surfaceId": surface_id if route_is_authoritative else "",
                "cwd": "/tmp",
                "agentLifecycle": "idle",
                "startedAt": now,
                "updatedAt": now,
                **identity_fields,
            }
            state_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "sessions": {session_id: record},
                    }
                )
            )
            env = hook_environment(server, workspace_id, surface_id, state_path)
            hook_args: list[str] = []
            if not has_incoming_pid:
                env.pop("CMUX_CLAUDE_PID", None)
            if not route_is_authoritative:
                env.pop("CMUX_SURFACE_ID", None)
                hook_args = ["--workspace", workspace_id]

            session_end_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "session-end",
                {
                    "session_id": session_id,
                    "cwd": "/tmp",
                },
                env,
                hook_args=hook_args,
            )
            session_end_commands = server.commands[session_end_start:]
            state = json.loads(state_path.read_text())
            saved_record = state.get("sessions", {}).get(session_id)
            if should_accept:
                if saved_record is not None or not has_command(
                    session_end_commands,
                    "clear_agent_pid claude_code ",
                ):
                    raise RuntimeError(
                        "An authoritative live SessionEnd could not claim a "
                        f"legacy identity-free record:\ncommands={session_end_commands!r}"
                        f"\nstate={state!r}"
                    )
            else:
                assert_no_claude_lifecycle_mutations(
                    session_end_commands,
                    context=f"A rejected {case_name} SessionEnd",
                )
                if saved_record is None:
                    raise RuntimeError(
                        f"A rejected {case_name} SessionEnd consumed its record:\n"
                        f"state={state!r}"
                    )


def verify_retired_clear_source_cannot_reclaim_stopped_successor(
    cli_path: str,
) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    retired_session_id = f"retired-clear-source-{uuid.uuid4().hex}"
    successor_session_id = f"clear-successor-{uuid.uuid4().hex}"
    with HookSocketServer(
        workspace_id=workspace_id,
        surface_id=surface_id,
    ) as server:
        state_path = Path(server.root.name) / "retired-source-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": retired_session_id,
                "source": "startup",
                "cwd": "/tmp",
            },
            env,
        )
        source_state = json.loads(state_path.read_text())
        source_record = source_state.get("sessions", {}).get(retired_session_id)
        if (
            source_record is None
            or source_record.get("surfaceId") != surface_id
        ):
            raise RuntimeError(
                "The pre-clear source was not registered for the pane:\n"
                f"state={source_state!r}"
            )

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": retired_session_id,
                "turn_id": "pre-clear-turn",
                "cwd": "/tmp",
            },
            env,
        )
        running_state = json.loads(state_path.read_text())
        running_record = running_state.get("sessions", {}).get(
            retired_session_id
        )
        surface_owner = running_state.get("activeSessionsBySurface", {}).get(
            surface_id
        )
        if (
            running_record is None
            or running_record.get("agentLifecycle") != "running"
            or surface_owner is None
            or surface_owner.get("sessionId") != retired_session_id
        ):
            raise RuntimeError(
                "The pre-clear prompt did not establish active pane ownership:\n"
                f"state={running_state!r}"
            )

        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": retired_session_id,
                "turn_id": "pre-clear-turn",
                "cwd": "/tmp",
                "last_assistant_message": "ready to clear",
                "background_tasks": [],
                "session_crons": [],
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {
                "session_id": retired_session_id,
                "reason": "clear",
                "cwd": "/tmp",
            },
            env,
        )
        retired_state = json.loads(state_path.read_text())
        transfer = retired_state.get(
            "clearBackgroundWorkTransfersBySurface",
            {},
        ).get(surface_id)
        retired_record = retired_state.get("retiredSessions", {}).get(
            retired_session_id
        )
        if (
            transfer is None
            or transfer.get("sourceSessionId") != retired_session_id
            or retired_record is None
        ):
            raise RuntimeError(
                "The accepted pre-clear source did not establish a durable "
                "retirement boundary:\n"
                f"state={retired_state!r}"
            )

        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {
                "session_id": successor_session_id,
                "source": "clear",
                "cwd": "/tmp",
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": successor_session_id,
                "turn_id": "successor-turn",
                "cwd": "/tmp",
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": successor_session_id,
                "turn_id": "successor-turn",
                "cwd": "/tmp",
                "last_assistant_message": "successor stopped",
                "background_tasks": [],
                "session_crons": [],
            },
            env,
        )

        replay_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": retired_session_id,
                "turn_id": "late-pre-clear-turn",
                "cwd": "/tmp",
            },
            env,
        )
        replay_commands = server.commands[replay_start:]
        assert_no_claude_lifecycle_mutations(
            replay_commands,
            context="A retired pre-clear prompt after its successor stopped",
        )

        state = json.loads(state_path.read_text())
        if retired_session_id in state.get("sessions", {}):
            raise RuntimeError(
                "A late prompt recreated its retired pre-clear session:\n"
                f"state={state!r}"
            )
        successor = state.get("sessions", {}).get(successor_session_id)
        if successor is None or successor.get("agentLifecycle") != "idle":
            raise RuntimeError(
                "A retired pre-clear prompt rewrote its idle successor:\n"
                f"successor={successor!r}\nstate={state!r}"
            )
        surface_owner = state.get("activeSessionsBySurface", {}).get(surface_id)
        if (
            surface_owner is None
            or surface_owner.get("sessionId") != successor_session_id
        ):
            raise RuntimeError(
                "A retired pre-clear prompt reclaimed its successor's pane:\n"
                f"state={state!r}"
            )


def verify_new_prompt_replaces_dead_needs_input_owner(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    dead_session_id = f"dead-needs-input-{uuid.uuid4().hex}"
    replacement_session_id = f"replacement-{uuid.uuid4().hex}"
    with HookSocketServer(
        workspace_id=workspace_id,
        surface_id=surface_id,
    ) as server:
        state_path = Path(server.root.name) / "dead-needs-input-owner-state.json"

        with live_process_pid() as dead_pid:
            dead_env = hook_environment(
                server,
                workspace_id,
                surface_id,
                state_path,
            )
            dead_env["CMUX_CLAUDE_PID"] = str(dead_pid)
            dead_env["CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"] = "0"
            dead_env.pop("CMUX_SOCKET_CAPABILITY", None)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "prompt-submit",
                {
                    "session_id": dead_session_id,
                    "turn_id": "abandoned-turn",
                    "cwd": "/tmp",
                },
                dead_env,
            )
            run_claude_hook(
                cli_path,
                server.socket_path,
                "notification",
                {
                    "session_id": dead_session_id,
                    "turn_id": "abandoned-turn",
                    "notification_type": "permission_prompt",
                    "message": "Claude needs permission",
                    "cwd": "/tmp",
                },
                dead_env,
            )

            state = json.loads(state_path.read_text())
            dead_record = state.get("sessions", {}).get(dead_session_id)
            if (
                dead_record is None
                or dead_record.get("agentLifecycle") != "needsInput"
            ):
                raise RuntimeError(
                    "The abandoned owner did not establish the stale needs-input "
                    f"precondition:\nrecord={dead_record!r}\nstate={state!r}"
                )

            # Stores written before process-generation capture have only the
            # numeric PID. The dead owner must not become permanent merely
            # because its legacy record cannot prove relative start ordering.
            dead_record.pop("pidStartSeconds", None)
            dead_record.pop("pidStartMicroseconds", None)
            state_path.write_text(json.dumps(state))

        with live_process_pid() as replacement_pid:
            replacement_env = hook_environment(
                server,
                workspace_id,
                surface_id,
                state_path,
            )
            replacement_env["CMUX_CLAUDE_PID"] = str(replacement_pid)
            replacement_env["CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"] = "0"
            replacement_env.pop("CMUX_SOCKET_CAPABILITY", None)
            prompt_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "prompt-submit",
                {
                    "session_id": replacement_session_id,
                    "turn_id": "replacement-turn",
                    "cwd": "/tmp",
                },
                replacement_env,
            )
            prompt_commands = server.commands[prompt_start:]
            if not has_command_with(
                prompt_commands,
                "set_status claude_code Running "
                "--icon=bolt.fill --color=#4C8DFF "
                f"--tab={workspace_id}",
                f"--panel={surface_id}",
                f"--pid={replacement_pid}",
            ):
                raise RuntimeError(
                    "A new prompt did not atomically replace the dead needs-input "
                    "owner with a PID-owned Running status:\n"
                    f"commands={prompt_commands!r}"
                )
            if not has_command_with(
                prompt_commands,
                f"clear_notifications --tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "A new prompt did not clear the dead owner's waiting "
                    f"notification:\ncommands={prompt_commands!r}"
                )

            state = json.loads(state_path.read_text())
            replacement_record = state.get("sessions", {}).get(
                replacement_session_id
            )
            surface_owner = state.get("activeSessionsBySurface", {}).get(
                surface_id
            )
            if (
                replacement_record is None
                or replacement_record.get("agentLifecycle") != "running"
                or replacement_record.get("runtimeStatus") != "running"
                or surface_owner is None
                or surface_owner.get("sessionId") != replacement_session_id
            ):
                raise RuntimeError(
                    "The new prompt did not establish replacement ownership:\n"
                    f"record={replacement_record!r}\nstate={state!r}"
                )

            stop_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "stop",
                {
                    "session_id": replacement_session_id,
                    "turn_id": "replacement-turn",
                    "cwd": "/tmp",
                    "last_assistant_message": "replacement completed",
                    "background_tasks": [],
                    "session_crons": [],
                },
                replacement_env,
            )
            stop_commands = server.commands[stop_start:]
            if not has_command_with(
                stop_commands,
                "set_status claude_code Idle "
                "--icon=pause.circle.fill --color=#8E8E93 "
                f"--tab={workspace_id}",
                f"--panel={surface_id}",
            ):
                raise RuntimeError(
                    "The replacement turn did not transition from Running to "
                    f"Idle:\ncommands={stop_commands!r}"
                )


def verify_background_work_drain_reaches_idle(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"background-drain-{uuid.uuid4().hex}"
    with HookSocketServer(
        workspace_id=workspace_id,
        surface_id=surface_id,
    ) as server:
        state_path = Path(server.root.name) / "background-drain-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)
        env["CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"] = "0"
        env.pop("CMUX_SOCKET_CAPABILITY", None)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": session_id,
                "turn_id": "background-turn",
                "cwd": "/tmp",
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": session_id,
                "turn_id": "background-turn",
                "cwd": "/tmp",
                "last_assistant_message": "waiting for background work",
                "background_tasks": [{"id": "task-1", "status": "running"}],
                "session_crons": [],
            },
            env,
        )
        state = json.loads(state_path.read_text())
        running_record = state.get("sessions", {}).get(session_id)
        if (
            running_record is None
            or running_record.get("agentLifecycle") != "running"
            or running_record.get("runtimeStatus") != "running"
            or running_record.get("hadPendingBackgroundWorkAtStop") is not True
        ):
            raise RuntimeError(
                "A Stop with live background work did not remain Running:\n"
                f"record={running_record!r}\nstate={state!r}"
            )

        drained_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": session_id,
                "turn_id": "background-turn",
                "cwd": "/tmp",
                "last_assistant_message": "background work completed",
                "background_tasks": [],
                "session_crons": [],
            },
            env,
        )
        drained_commands = server.commands[drained_start:]
        if not has_command_with(
            drained_commands,
            "set_status claude_code Idle "
            "--icon=pause.circle.fill --color=#8E8E93 "
            f"--tab={workspace_id}",
            f"--panel={surface_id}",
            f"--pid={os.getpid()}",
        ):
            raise RuntimeError(
                "The first Stop proving background work drained did not publish "
                f"Idle:\ncommands={drained_commands!r}"
            )

        state = json.loads(state_path.read_text())
        drained_record = state.get("sessions", {}).get(session_id)
        if (
            drained_record is None
            or drained_record.get("agentLifecycle") != "idle"
            or drained_record.get("runtimeStatus") != "idle"
            or drained_record.get("hadPendingBackgroundWorkAtStop") is not False
        ):
            raise RuntimeError(
                "A drained background task left a sticky Running outcome:\n"
                f"record={drained_record!r}\nstate={state!r}"
            )


def verify_notification_outcomes_do_not_invent_waiting_state(
    cli_path: str,
) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"notification-outcomes-{uuid.uuid4().hex}"
    with HookSocketServer(
        workspace_id=workspace_id,
        surface_id=surface_id,
    ) as server:
        state_path = Path(server.root.name) / "notification-outcomes-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)
        env["CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"] = "0"
        env.pop("CMUX_SOCKET_CAPABILITY", None)

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": session_id,
                "turn_id": "completed-turn",
                "cwd": "/tmp",
            },
            env,
        )
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "session_id": session_id,
                "turn_id": "completed-turn",
                "cwd": "/tmp",
                "last_assistant_message": "completed normally",
                "background_tasks": [],
                "session_crons": [],
            },
            env,
        )

        reminder_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "notification",
            {
                "session_id": session_id,
                "turn_id": "completed-turn",
                "notification_type": "idle_prompt",
                "message": "Claude is waiting for your input",
                "cwd": "/tmp",
            },
            env,
        )
        reminder_commands = server.commands[reminder_start:]
        if has_command_with(
            reminder_commands,
            "set_agent_lifecycle claude_code needsInput",
            f"--tab={workspace_id}",
        ) or has_command_with(
            reminder_commands,
            "set_status claude_code Needs input",
            f"--tab={workspace_id}",
        ):
            raise RuntimeError(
                "A non-blocking idle reminder invented a Needs input state:\n"
                f"commands={reminder_commands!r}"
            )
        if not has_command_with(
            reminder_commands,
            '"method":"feed.push"',
            '"_cmux_agent_lifecycle":"idle"',
        ):
            raise RuntimeError(
                "An idle reminder did not publish the accepted Idle lifecycle "
                f"to Feed:\ncommands={reminder_commands!r}"
            )

        state = json.loads(state_path.read_text())
        idle_record = state.get("sessions", {}).get(session_id)
        if (
            idle_record is None
            or idle_record.get("agentLifecycle") != "idle"
            or idle_record.get("runtimeStatus") != "idle"
        ):
            raise RuntimeError(
                "An idle reminder overwrote the terminal Idle outcome:\n"
                f"record={idle_record!r}\nstate={state!r}"
            )

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": session_id,
                "turn_id": "failed-turn",
                "cwd": "/tmp",
            },
            env,
        )
        error_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "notification",
            {
                "session_id": session_id,
                "turn_id": "failed-turn",
                "notification_type": "api_error",
                "message": "Credit balance is too low",
                "cwd": "/tmp",
            },
            env,
        )
        error_commands = server.commands[error_start:]
        if not has_command_with(
            error_commands,
            "set_status claude_code Claude Code error "
            "--icon=exclamationmark.triangle.fill --color=#FF453A "
            f"--priority=100 --tab={workspace_id}",
            f"--panel={surface_id}",
            f"--pid={os.getpid()}",
        ):
            raise RuntimeError(
                "An API error notification did not publish Error:\n"
                f"commands={error_commands!r}"
            )
        if has_command_with(
            error_commands,
            "set_status claude_code Needs input",
            f"--tab={workspace_id}",
        ):
            raise RuntimeError(
                "An API error notification was mislabeled Needs input:\n"
                f"commands={error_commands!r}"
            )

        state = json.loads(state_path.read_text())
        error_record = state.get("sessions", {}).get(session_id)
        if (
            error_record is None
            or error_record.get("agentLifecycle") != "needsInput"
            or error_record.get("runtimeStatus") != "error"
            or error_record.get("lastNotificationStatus") != "error"
            or error_record.get("lastBody") != "Credit balance is too low"
        ):
            raise RuntimeError(
                "An API error notification did not persist a terminal Error "
                f"outcome:\nrecord={error_record!r}\nstate={state!r}"
            )


def verify_authoritative_terminal_event_upgrades_legacy_active_owner(
    cli_path: str,
    hook_event_name: str,
) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"legacy-active-{hook_event_name.lower()}-{uuid.uuid4().hex}"
    with HookSocketServer(
        workspace_id=workspace_id,
        surface_id=surface_id,
    ) as server:
        state_path = (
            Path(server.root.name)
            / f"legacy-active-{hook_event_name.lower()}-state.json"
        )
        with live_process_pid() as live_pid:
            env = hook_environment(
                server,
                workspace_id,
                surface_id,
                state_path,
            )
            env["CMUX_CLAUDE_PID"] = str(live_pid)

            run_claude_hook(
                cli_path,
                server.socket_path,
                "prompt-submit",
                {
                    "session_id": session_id,
                    "turn_id": "legacy-active-turn",
                    "cwd": "/tmp",
                },
                env,
            )
            state = json.loads(state_path.read_text())
            record = state.get("sessions", {}).get(session_id)
            if (
                record is None
                or record.get("pid") != live_pid
                or record.get("pidStartSeconds") is None
                or record.get("pidStartMicroseconds") is None
            ):
                raise RuntimeError(
                    "The active owner did not establish a process generation "
                    f"before the legacy-store simulation:\nrecord={record!r}"
                )

            # Older stores can identify the active owner only by numeric PID.
            # An authoritative hook from that same live process must upgrade the
            # record instead of leaving Running as an inescapable state.
            record.pop("pidStartSeconds")
            record.pop("pidStartMicroseconds")
            state_path.write_text(json.dumps(state))

            stop_payload: dict[str, object] = {
                "hook_event_name": hook_event_name,
                "session_id": session_id,
                "turn_id": "legacy-active-turn",
                "cwd": "/tmp",
                "last_assistant_message": "legacy active turn ended",
                "background_tasks": [],
                "session_crons": [],
            }
            if hook_event_name == "StopFailure":
                stop_payload["error"] = "Credit balance is too low"

            terminal_start = len(server.commands)
            run_claude_hook(
                cli_path,
                server.socket_path,
                "stop",
                stop_payload,
                env,
            )
            terminal_commands = server.commands[terminal_start:]

            if hook_event_name == "StopFailure":
                expected_status = (
                    "set_status claude_code Claude Code error "
                    "--icon=exclamationmark.triangle.fill --color=#FF453A "
                    f"--priority=100 --tab={workspace_id}"
                )
                expected_lifecycle = "needsInput"
                expected_runtime_status = "error"
            else:
                expected_status = (
                    "set_status claude_code Idle "
                    "--icon=pause.circle.fill --color=#8E8E93 "
                    f"--tab={workspace_id}"
                )
                expected_lifecycle = "idle"
                expected_runtime_status = "idle"

            if not has_command_with(
                terminal_commands,
                expected_status,
                f"--panel={surface_id}",
                f"--pid={live_pid}",
            ):
                raise RuntimeError(
                    f"An authoritative {hook_event_name} from a legacy PID-only "
                    "active owner did not publish its terminal status:\n"
                    f"commands={terminal_commands!r}"
                )

            upgraded_state = json.loads(state_path.read_text())
            upgraded_record = upgraded_state.get("sessions", {}).get(session_id)
            if (
                upgraded_record is None
                or upgraded_record.get("pid") != live_pid
                or upgraded_record.get("pidStartSeconds") is None
                or upgraded_record.get("pidStartMicroseconds") is None
                or upgraded_record.get("agentLifecycle") != expected_lifecycle
                or upgraded_record.get("runtimeStatus") != expected_runtime_status
            ):
                raise RuntimeError(
                    f"An authoritative {hook_event_name} did not upgrade and "
                    "finish its legacy PID-only active owner:\n"
                    f"record={upgraded_record!r}\nstate={upgraded_state!r}"
                )


def verify_stop_failure_marks_terminal_error(cli_path: str) -> None:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"stop-failure-{uuid.uuid4().hex}"
    with HookSocketServer(
        workspace_id=workspace_id,
        surface_id=surface_id,
    ) as server:
        state_path = Path(server.root.name) / "stop-failure-state.json"
        env = hook_environment(server, workspace_id, surface_id, state_path)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": session_id,
                "turn_id": "failed-turn",
                "cwd": "/tmp",
            },
            env,
        )

        failure_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "stop",
            {
                "hook_event_name": "StopFailure",
                "session_id": session_id,
                "turn_id": "failed-turn",
                "cwd": "/tmp",
                "error": "Credit balance is too low",
                "background_tasks": [],
                "session_crons": [],
            },
            env,
        )
        failure_commands = server.commands[failure_start:]
        if not has_command_with(
            failure_commands,
            "set_status claude_code Claude Code error "
            "--icon=exclamationmark.triangle.fill --color=#FF453A --priority=100 "
            f"--tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "StopFailure did not publish a terminal error status:\n"
                f"commands={failure_commands!r}"
            )

        state = json.loads(state_path.read_text())
        record = state.get("sessions", {}).get(session_id)
        if (
            record is None
            or record.get("agentLifecycle") != "needsInput"
            or record.get("runtimeStatus") != "error"
            or record.get("lastNotificationStatus") != "error"
            or record.get("lastBody") != "Credit balance is too low"
        ):
            raise RuntimeError(
                "StopFailure did not persist a terminal error outcome:\n"
                f"record={record!r}\nstate={state!r}"
            )

        recovery_start = len(server.commands)
        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": session_id,
                "turn_id": "recovery-turn",
                "cwd": "/tmp",
            },
            env,
        )
        recovery_commands = server.commands[recovery_start:]
        if not has_command_with(
            recovery_commands,
            "set_status claude_code Running "
            "--icon=bolt.fill --color=#4C8DFF "
            f"--tab={workspace_id}",
            f"--panel={surface_id}",
        ):
            raise RuntimeError(
                "The next prompt did not replace Error with Running:\n"
                f"commands={recovery_commands!r}"
            )

        recovered_state = json.loads(state_path.read_text())
        recovered_record = recovered_state.get("sessions", {}).get(session_id)
        if (
            recovered_record is None
            or recovered_record.get("agentLifecycle") != "running"
            or recovered_record.get("runtimeStatus") != "running"
            or recovered_record.get("lastNotificationStatus") is not None
        ):
            raise RuntimeError(
                "The next prompt did not clear the persisted error outcome:\n"
                f"record={recovered_record!r}\nstate={recovered_state!r}"
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
        clear_pid_env = env.copy()

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

        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-end",
            {
                "session_id": old_session_id,
                "reason": "clear",
                "cwd": "/tmp",
            },
            old_pid_env,
        )
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

        if has_command(late_old_start_commands, "set_agent_pid claude_code "):
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
        verify_stop_first_clear_transfers_background_work(cli_path)
        verify_unrelated_turn_event_preserves_pending_clear_handoff(
            cli_path,
            "prompt-submit",
        )
        verify_unrelated_turn_event_preserves_pending_clear_handoff(
            cli_path,
            "stop",
        )
        verify_unrelated_turn_event_preserves_pending_clear_handoff(
            cli_path,
            "notification",
        )
        verify_unrelated_turn_event_preserves_pending_clear_handoff(
            cli_path,
            "pre-tool-use",
        )
        verify_unrelated_turn_event_preserves_pending_clear_handoff(
            cli_path,
            "push-notification",
        )
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
        verify_clear_handoff_outlives_creator_budget_across_readers(cli_path)
        verify_repeated_clear_end_does_not_retire_replacement(cli_path)
        verify_guessed_clear_end_uses_stored_surface(cli_path)
        verify_authoritative_resume_supersedes_clear_tombstone(cli_path)
        verify_unproven_process_cannot_consume_clear_handoff(cli_path)
        verify_vacant_surface_accepts_authoritative_resume(cli_path)
        verify_inactive_session_resume_requires_newer_generation(cli_path)
        verify_older_generation_resume_is_rejected(cli_path)
        verify_new_generation_resumes_same_session(cli_path)
        verify_new_generation_resume_clears_stale_background_work(cli_path)
        verify_new_generation_resume_discards_source_handoff(cli_path)
        verify_late_resume_cannot_replace_clear_successor(cli_path)
        verify_session_end_requires_current_process_generation(cli_path)
        verify_resume_checks_displaced_and_inactive_target_generations(cli_path)
        verify_only_prompt_submit_replaces_stopped_owner(cli_path)
        verify_clear_end_without_work_creates_one_shot_tombstone(cli_path)
        verify_clear_start_requires_session_end_transfer(cli_path)
        verify_non_turn_session_start_cannot_replace_stopped_owner(cli_path)
        verify_metadata_session_start_preserves_authority(cli_path)
        verify_legacy_session_end_claim_requires_live_authoritative_identity(
            cli_path
        )
        verify_retired_clear_source_cannot_reclaim_stopped_successor(cli_path)
        verify_new_prompt_replaces_dead_needs_input_owner(cli_path)
        verify_background_work_drain_reaches_idle(cli_path)
        verify_notification_outcomes_do_not_invent_waiting_state(cli_path)
        verify_authoritative_terminal_event_upgrades_legacy_active_owner(
            cli_path,
            "Stop",
        )
        verify_authoritative_terminal_event_upgrades_legacy_active_owner(
            cli_path,
            "StopFailure",
        )
        verify_stop_failure_marks_terminal_error(cli_path)
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    print("PASS: Claude /clear lifecycle boundaries remain idle, current, and failure-safe")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
