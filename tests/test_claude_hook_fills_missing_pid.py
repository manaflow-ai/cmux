#!/usr/bin/env python3
"""Regression for #34433: a Claude session record gets its pid from any hook event.

SessionStart was the only event that wrote the pid. When it never reached cmux,
the first event to arrive (a PreToolUse, Stop or Notification) created the
record without one, and a later UserPromptSubmit only wrote it for a session
with no record at all. The record then stayed pid-less for the whole session,
so `cmux sessions list` and custom sidebars showed a live session as one whose
process was gone. Every hook carries the agent's pid in CMUX_CLAUDE_PID, so the
first event that has it fills it in. A pid already recorded is kept.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import tempfile
import uuid
from pathlib import Path

from fake_socket_env import cli_environment
from test_claude_hook_reports_session_cwd import HookSocketServer, resolve_cmux_cli, run_claude_hook


def detached_process() -> int:
    """A live pid whose only ancestor is launchd.

    The hook walks the agent's ancestors looking for a parent agent, and a test
    run from inside an agent session would otherwise be treated as nested.
    """
    started = subprocess.run(
        ["/bin/sh", "-c", "/bin/sleep 300 >/dev/null 2>&1 & echo $!"],
        capture_output=True, text=True, check=True,
    )
    return int(started.stdout.strip())


def payload_for(subcommand: str, session_id: str, cwd: str) -> dict[str, object]:
    payload: dict[str, object] = {"session_id": session_id, "cwd": cwd}
    if subcommand == "pre-tool-use":
        payload.update({"tool_name": "Bash", "tool_input": {"command": "ls"}})
    elif subcommand == "prompt-submit":
        payload.update({"turn_id": "turn-1", "prompt": "hello"})
    elif subcommand == "notification":
        # Only a prompt that waits on the person writes the session record.
        payload.update({"message": "Claude needs your permission to use Bash", "notification_type": "permission_prompt"})
    elif subcommand == "session-start":
        payload.update({"source": "startup"})
    return payload


def recorded_pid(state_path: Path, session_id: str) -> object:
    if not state_path.exists():
        return "no state file"
    state = json.loads(state_path.read_text(encoding="utf-8"))
    record = state.get("sessions", {}).get(session_id)
    if record is None:
        return "no record"
    return record.get("pid")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    agent_pid = detached_process()
    other_pid = detached_process()
    try:
        return run(cli_path, agent_pid, other_pid)
    finally:
        for pid in (agent_pid, other_pid):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


def run(cli_path: str, agent_pid: int, other_pid: int) -> int:
    failures: list[str] = []
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()

    with tempfile.TemporaryDirectory(prefix="cmux-claude-pid-") as root_name:
        root = Path(root_name).resolve()
        with HookSocketServer(root_name, workspace_id, surface_id) as server:
            base_env = cli_environment(server.socket_path, home=root / "home")
            # Hermetic: a cmux or Claude session running this test exports its
            # own launch capture and agent pid.
            for key in list(base_env):
                if key.startswith(("CMUX_AGENT_", "CMUX_CLAUDE_", "CLAUDE")):
                    del base_env[key]
            base_env["CMUX_WORKSPACE_ID"] = workspace_id
            base_env["CMUX_SURFACE_ID"] = surface_id
            base_env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
            base_env["CMUX_AGENT_LAUNCH_KIND"] = "claude"

            def run_case(
                label: str,
                steps: list[tuple[str, int | None]],
                expected: int | None,
                extra_env: dict[str, str] | None = None,
            ) -> None:
                state_path = root / f"{label.replace(' ', '-')}.json"
                session_id = f"pid-{uuid.uuid4().hex}"
                for subcommand, pid in steps:
                    env = dict(base_env)
                    env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
                    if pid is not None:
                        env["CMUX_CLAUDE_PID"] = str(pid)
                    env.update(extra_env or {})
                    run_claude_hook(cli_path, server.socket_path, subcommand, payload_for(subcommand, session_id, str(root)), env)
                pid = recorded_pid(state_path, session_id)
                if pid != expected and not (expected is None and pid == "no record"):
                    failures.append(f"{label}: expected pid {expected}, got {pid!r}")

            for first in ("pre-tool-use", "stop", "notification"):
                run_case(f"{first} without SessionStart", [(first, agent_pid)], agent_pid)
            run_case(
                "prompt-submit after a pid-less record",
                [("pre-tool-use", None), ("prompt-submit", agent_pid)],
                agent_pid,
            )
            run_case(
                "stop after a pid-less record",
                [("pre-tool-use", None), ("stop", agent_pid)],
                agent_pid,
            )
            # A relayed event's pid belongs to the remote host, never this Mac.
            run_case(
                "a relayed event leaves the pid empty",
                [("pre-tool-use", None), ("stop", agent_pid)],
                None,
                extra_env={"CMUX_AGENT_HOOK_RELAY_ORIGIN": "1"},
            )
            run_case(
                "a recorded pid is kept",
                [("session-start", agent_pid), ("pre-tool-use", other_pid), ("stop", other_pid)],
                agent_pid,
            )

    if failures:
        print("FAIL: Claude hook records stay without a pid when SessionStart is missed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: the first Claude hook event with an agent pid fills a missing pid and keeps a recorded one")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
