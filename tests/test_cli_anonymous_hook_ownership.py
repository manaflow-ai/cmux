#!/usr/bin/env python3
"""Behavior regressions for anonymous hook process-generation ownership."""

from __future__ import annotations

import base64
import json
import os
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
SURFACE_ID = "22222222-2222-4222-8222-222222222222"


class HookSocketState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._commands: list[str] = []

    def append(self, command: str) -> None:
        with self._lock:
            self._commands.append(command)

    def snapshot(self) -> list[str]:
        with self._lock:
            return list(self._commands)


class HookSocketHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            command = line.decode("utf-8", errors="replace").rstrip("\n")
            self.server.state.append(command)  # type: ignore[attr-defined]
            response = self._response(command)
            self.wfile.write((response + "\n").encode("utf-8"))
            self.wfile.flush()

    def _response(self, command: str) -> str:
        if not command.startswith("{"):
            return "OK"
        request = json.loads(command)
        method = request.get("method")
        result: dict[str, object] = {}
        if method == "agent.resolve_delivery_target":
            result = {
                "source": "pid",
                "workspace_id": WORKSPACE_ID,
                "surface_id": SURFACE_ID,
            }
        elif method == "surface.list":
            result = {
                "surfaces": [
                    {
                        "index": 0,
                        "id": SURFACE_ID,
                        "ref": "surface:1",
                        "focused": True,
                    }
                ]
            }
        elif method == "workspace.current":
            result = {"workspace_id": WORKSPACE_ID}
        elif method == "workspace.list":
            result = {
                "workspaces": [
                    {
                        "index": 0,
                        "id": WORKSPACE_ID,
                        "ref": "workspace:1",
                    }
                ]
            }
        elif method == "window.list":
            result = {"windows": []}
        elif method == "debug.terminals":
            result = {"terminals": []}
        elif method == "surface.resume.set":
            result = {"updated_at": 123.25}
        elif method == "surface.resume.clear":
            result = {"cleared": True}
        return json.dumps({"id": request.get("id"), "ok": True, "result": result})


class ThreadedUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    state: HookSocketState


def run_kiro_hook(
    cli: str,
    socket_path: str,
    state_directory: Path,
    agent_pid: int,
    subcommand: str,
    event_name: str,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    for key in [
        "CMUX_SOCKET",
        "CMUX_SOCKET_CAPABILITY",
        "CMUX_SOCKET_PASSWORD",
        "CMUX_TAB_ID",
        "CMUX_PANEL_ID",
    ]:
        env.pop(key, None)
    env.update(
        {
            "HOME": str(state_directory),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": str(state_directory),
            "CMUX_SOCKET_PATH": socket_path,
            "CMUX_WORKSPACE_ID": WORKSPACE_ID,
            "CMUX_SURFACE_ID": SURFACE_ID,
            "CMUX_AGENT_HOOK_STATE_DIR": str(state_directory),
            "CMUX_KIRO_PID": str(agent_pid),
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS": "0",
            "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS": "0",
            "CMUX_AGENT_MANAGED_SUBAGENT": "0",
        }
    )
    return subprocess.run(
        [cli, "--socket", socket_path, "hooks", "kiro", subcommand],
        input=json.dumps(
            {
                "cwd": str(state_directory),
                "hook_event_name": event_name,
            }
        ),
        text=True,
        capture_output=True,
        check=False,
        env=env,
        timeout=8,
    )


def require_hook_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0 or result.stdout != "{}\n":
        raise AssertionError(
            f"{label} failed: exit={result.returncode} "
            f"stdout={result.stdout!r} stderr={result.stderr!r}"
        )


def mutate_stored_process_generation(store_path: Path) -> tuple[int, int]:
    state = json.loads(store_path.read_text(encoding="utf-8"))
    record = state["sessions"][SURFACE_ID]
    seconds = record.get("pidStartSeconds")
    microseconds = record.get("pidStartMicroseconds")
    if not isinstance(seconds, int) or not isinstance(microseconds, int):
        raise AssertionError(f"session-start did not persist a process generation: {record!r}")
    record["pidStartSeconds"] = seconds + 1
    store_path.write_text(json.dumps(state), encoding="utf-8")
    return seconds, microseconds


def visible_ownership_mutation(command: str) -> bool:
    return command.startswith(
        (
            "set_agent_pid ",
            "set_agent_lifecycle ",
            "clear_agent_pid ",
            "set_status ",
            "clear_status ",
            "clear_notifications ",
            "notify_target_async ",
        )
    ) or ('"method":"surface.resume.clear"' in command.replace(" ", ""))


def main() -> int:
    cli = resolve_cmux_cli()
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-anonymous-generation-") as tmp:
        state_directory = Path(tmp)
        socket_path = str(state_directory / "cmux.sock")
        state = HookSocketState()
        server = ThreadedUnixServer(socket_path, HookSocketHandler)
        server.state = state
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        agent = subprocess.Popen(["/bin/sleep", "30"])
        store_path = state_directory / "kiro-hook-sessions.json"
        try:
            start_offset = len(state.snapshot())
            require_hook_success(
                run_kiro_hook(
                    cli,
                    socket_path,
                    state_directory,
                    agent.pid,
                    "session-start",
                    "SessionStart",
                ),
                "anonymous session-start",
            )
            original_seconds, original_microseconds = mutate_stored_process_generation(store_path)
            start_commands = state.snapshot()[start_offset:]
            expected_start_tokens = (
                f"--expected-pid-start-seconds={original_seconds}",
                f"--expected-pid-start-microseconds={original_microseconds}",
            )
            if not any(
                command.startswith(f"set_agent_pid kiro.{SURFACE_ID} {agent.pid} ")
                and all(token in command for token in expected_start_tokens)
                for command in start_commands
            ):
                failures.append(
                    "anonymous session-start did not bind app ownership to its process generation: "
                    f"{start_commands!r}"
                )

            stale_prompt_offset = len(state.snapshot())
            require_hook_success(
                run_kiro_hook(
                    cli,
                    socket_path,
                    state_directory,
                    agent.pid,
                    "prompt-submit",
                    "UserPromptSubmit",
                ),
                "generation-mismatched prompt-submit",
            )
            stale_prompt_commands = state.snapshot()[stale_prompt_offset:]
            if any(visible_ownership_mutation(command) for command in stale_prompt_commands):
                failures.append(
                    "a generation-mismatched anonymous prompt mutated the replacement occupant: "
                    f"{stale_prompt_commands!r}"
                )

            mutate_stored_process_generation(store_path)
            stale_end_offset = len(state.snapshot())
            require_hook_success(
                run_kiro_hook(
                    cli,
                    socket_path,
                    state_directory,
                    agent.pid,
                    "session-end",
                    "SessionEnd",
                ),
                "generation-mismatched session-end",
            )
            stale_end_commands = state.snapshot()[stale_end_offset:]
            if any(visible_ownership_mutation(command) for command in stale_end_commands):
                failures.append(
                    "a generation-mismatched anonymous teardown cleared the replacement occupant: "
                    f"{stale_end_commands!r}"
                )

            require_hook_success(
                run_kiro_hook(
                    cli,
                    socket_path,
                    state_directory,
                    agent.pid,
                    "session-start",
                    "SessionStart",
                ),
                "replacement anonymous session-start",
            )
            record = json.loads(store_path.read_text(encoding="utf-8"))["sessions"][SURFACE_ID]
            expected_seconds = record.get("pidStartSeconds")
            expected_microseconds = record.get("pidStartMicroseconds")
            live_prompt_offset = len(state.snapshot())
            require_hook_success(
                run_kiro_hook(
                    cli,
                    socket_path,
                    state_directory,
                    agent.pid,
                    "prompt-submit",
                    "UserPromptSubmit",
                ),
                "generation-matched prompt-submit",
            )
            live_prompt_commands = state.snapshot()[live_prompt_offset:]
            if not any(
                command.startswith("set_agent_lifecycle kiro running ")
                and f"--expected-pid={agent.pid}" in command
                and f"--expected-pid-start-seconds={expected_seconds}" in command
                and f"--expected-pid-start-microseconds={expected_microseconds}" in command
                for command in live_prompt_commands
            ):
                failures.append(
                    "a generation-verified post-start hook cannot atomically reclaim missing app ownership: "
                    f"{live_prompt_commands!r}"
                )
            expected_guard_tokens = (
                "--expected-agent-key=",
                "--expected-agent-pid-key=",
                f"--expected-agent-pid={agent.pid}",
                f"--expected-agent-pid-start-seconds={expected_seconds}",
                f"--expected-agent-pid-start-microseconds={expected_microseconds}",
            )
            option_guarded_commands = [
                command
                for command in live_prompt_commands
                if command.startswith(("set_status ", "clear_notifications "))
            ]
            if not option_guarded_commands or any(
                not all(token in command for token in expected_guard_tokens)
                for command in option_guarded_commands
            ):
                failures.append(
                    "post-start visible mutations were not guarded by the same process generation: "
                    f"{option_guarded_commands!r}"
                )
            expected_notification_guard = "g=" + ":".join(
                (
                    "v1",
                    "p",
                    base64.b64encode(b"kiro").decode("ascii"),
                    base64.b64encode(f"kiro.{SURFACE_ID}".encode()).decode("ascii"),
                    str(agent.pid),
                    str(expected_seconds),
                    str(expected_microseconds),
                )
            )
            notification_commands = [
                command
                for command in live_prompt_commands
                if command.startswith("notify_target_async ")
            ]
            if any(expected_notification_guard not in command for command in notification_commands):
                failures.append(
                    "post-start notifications did not carry the structured process guard: "
                    f"{notification_commands!r}"
                )
        finally:
            agent.terminate()
            try:
                agent.wait(timeout=2)
            except subprocess.TimeoutExpired:
                agent.kill()
                agent.wait(timeout=2)
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: anonymous hooks pin, reject, and reclaim ownership by process generation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
