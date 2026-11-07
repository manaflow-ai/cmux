#!/usr/bin/env python3
"""A headless `claude -p` started inside a Claude session leaves the parent's session alone (#23401).

Review tools and skills run `claude -p` from the interactive session's Bash tool.
The child goes through cmux-claude-wrapper, which marks it headless
(`CMUX_CLAUDE_HEADLESS=1`), but its hooks still reached cmux for the same
surface: its SessionStart took the surface over, and every later Stop of the
parent was journaled `superseded-stale`, so the parent never notified again.

This runs the real `cmux claude-hook` commands against a fake socket with a real
process tree: a parent whose argv[0] is `claude`, and a child `claude` under it.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_claude_hook_clear_running_status as hooks  # noqa: E402


def stored_sessions(state_path: Path) -> dict[str, object]:
    sessions = json.loads(state_path.read_text()).get("sessions")
    return sessions if isinstance(sessions, dict) else {}


def spawn_claude_tree(root: Path) -> tuple[int, int]:
    """A `claude` process with a `claude` child, as a Bash tool call that runs `claude -p` gives.

    The tree is detached from this test's own processes (its top is reparented to
    launchd), so a test runner that itself runs under an agent does not make the
    parent look nested.
    """
    parent_file, child_file = root / "parent.pid", root / "child.pid"
    inner = f"exec -a claude /bin/sleep 60 & echo \\$! > '{child_file}'; wait"
    subprocess.run(
        ["/bin/bash", "-c", f"(exec -a claude /bin/bash -c \"{inner}\") </dev/null >/dev/null 2>&1 & echo $! > '{parent_file}'"],
        check=True,
    )
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not (child_file.exists() and child_file.read_text().strip()):
        time.sleep(0.02)
    return int(parent_file.read_text()), int(child_file.read_text())


def queued_session_id(command: str) -> str | None:
    """The session id of an `agent.hook.enqueue` request, if `command` is one."""
    if not command.startswith("{"):
        return None
    try:
        request = json.loads(command)
        if request.get("method") != "agent.hook.enqueue":
            return None
        return json.loads(request["params"]["payload"]).get("session_id")
    except (KeyError, TypeError, ValueError):
        return None


def run_queued_sessions(cli: str, socket_path: str, env: dict[str, str], root: Path) -> str:
    """Runs the wrapper's queued hooks for a parent session, a headless child under it,
    and a headless run with no session above it, each from inside its own `claude`."""
    def enqueue(session_id: str) -> str:
        lines = []
        for name, payload in [
            ("session-start", {"session_id": session_id, "source": "startup"}),
            ("prompt-submit", {"session_id": session_id, "turn_id": "queued-turn"}),
            ("stop", {"session_id": session_id, "turn_id": "queued-turn", "last_assistant_message": "done"}),
        ]:
            payload_file = root / f"{session_id}-{name}.json"
            payload_file.write_text(json.dumps(dict(payload, cwd="/tmp")))
            lines.append(
                f"'{cli}' --socket '{socket_path}' hooks enqueue claude {name} "
                f"< '{payload_file}' >> '{root / (session_id + '.out')}' 2>&1"
            )
        return "\n".join(lines)

    child_script = root / "child.sh"
    child_script.write_text("set -e\nexport CMUX_CLAUDE_HEADLESS=1\n" + enqueue("child") + "\n")
    parent_script = root / "parent.sh"
    parent_script.write_text(
        "set -e\nexport CMUX_CLAUDE_HEADLESS=0\n" + enqueue("parent")
        + f"\n(exec -a claude /bin/bash '{child_script}')\n"
    )
    lone_script = root / "lone.sh"
    lone_script.write_text("set -e\nexport CMUX_CLAUDE_HEADLESS=1\n" + enqueue("lone") + "\n")
    tree_env = {key: value for key, value in env.items() if key != "CMUX_CLAUDE_PID"}
    for script in (parent_script, lone_script):
        done = root / (script.stem + ".done")
        # Detached from this test's processes, so its top is reparented to launchd.
        # The `claude` process is an inner subshell, so the outer one is left to mark
        # the script done; an `exec` there would replace it before the `touch`. A
        # failed hook stops the script (`set -e`) and leaves no marker.
        subprocess.run(
            ["/bin/bash", "-c", f"( (exec -a claude /bin/bash '{script}') && touch '{done}' ) </dev/null >/dev/null 2>&1 &"],
            env=tree_env, check=True,
        )
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not done.exists():
            time.sleep(0.05)
        if not done.exists():
            raise RuntimeError(f"{script.name} failed or did not finish within 60 seconds")
    return " ".join(
        f"{name}: {(root / (name + '.out')).read_text().strip()!r}"
        for name in ("parent", "child", "lone") if (root / (name + ".out")).exists()
    )


def main() -> int:
    cli = hooks.resolve_cmux_cli()
    failures: list[str] = []
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    tree_root = Path(tempfile.mkdtemp(prefix="cmux-headless-child-"))
    parent_pid, child_pid = spawn_claude_tree(tree_root)
    lone = subprocess.Popen(["/bin/sleep", "60"])
    try:
        with hooks.HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
            state_path = Path(server.root.name) / "claude-hook-state.json"
            env = hooks.cli_environment(server.socket_path)
            env.update(
                CMUX_WORKSPACE_ID=workspace_id,
                CMUX_SURFACE_ID=surface_id,
                CMUX_CLAUDE_HOOK_STATE_PATH=str(state_path),
                CMUX_CLI_SENTRY_DISABLED="1",
                CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
            )
            parent_env = dict(env, CMUX_CLAUDE_PID=str(parent_pid), CMUX_CLAUDE_HEADLESS="0")
            child_env = dict(env, CMUX_CLAUDE_PID=str(child_pid), CMUX_CLAUDE_HEADLESS="1")

            def hook(name: str, payload: dict[str, object], hook_env: dict[str, str]) -> list[str]:
                start = len(server.commands)
                hooks.run_claude_hook(cli, server.socket_path, name, dict(payload, cwd="/tmp"), hook_env)
                return server.commands[start:]

            hook("session-start", {"session_id": "parent", "source": "startup"}, parent_env)
            hook("prompt-submit", {"session_id": "parent", "turn_id": "turn-1"}, parent_env)
            # The parent's Bash tool runs `claude -p ...`: the child's whole lifecycle.
            hook("session-start", {"session_id": "child", "source": "startup"}, child_env)
            hook("prompt-submit", {"session_id": "child", "turn_id": "child-turn"}, child_env)
            child_stop = hook(
                "stop", {"session_id": "child", "turn_id": "child-turn", "last_assistant_message": "PONG"}, child_env
            )

            if "child" in stored_sessions(state_path):
                failures.append(f"the headless child was recorded as a session: {stored_sessions(state_path)!r}")
            if any(f"--panel={surface_id}" in command and "set_status claude_code" in command for command in child_stop):
                failures.append(f"the headless child's Stop changed the parent's status: {child_stop!r}")

            parent_stop = hook(
                "stop", {"session_id": "parent", "turn_id": "turn-1", "last_assistant_message": "OK"}, parent_env
            )
            if any("superseded-stale" in command for command in parent_stop):
                failures.append("the parent's Stop was decided stale after the headless child ran")
            if not any("set_status claude_code" in command and f"--tab={workspace_id}" in command for command in parent_stop):
                failures.append(f"the parent's Stop did not update its status: {parent_stop!r}")

            # A headless run with no Claude session above it is still tracked as before.
            lone_env = dict(env, CMUX_CLAUDE_PID=str(lone.pid), CMUX_CLAUDE_HEADLESS="1")
            hook("session-start", {"session_id": "lone", "source": "startup"}, lone_env)
            if "lone" not in stored_sessions(state_path):
                failures.append("a headless run outside any Claude session was no longer recorded")

            # The wrapper's hooks go through the app's queue (`cmux hooks enqueue`), which
            # replays them later without the headless flag or a live process to walk, so
            # the child's events must not be queued at all. Each hook runs inside a
            # `claude` process tree here, as it does under Claude Code, because the queue
            # names the agent from the hook's own ancestors.
            queued = run_queued_sessions(cli, server.socket_path, env, tree_root)
            for session_id, expected in [("parent", 3), ("child", 0), ("lone", 3)]:
                count = sum(
                    1 for command in server.commands
                    if queued_session_id(command) == session_id
                )
                if count != expected:
                    failures.append(f"{session_id}: {count} hooks queued, expected {expected}; {queued}")
    finally:
        for pid in (child_pid, parent_pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        lone.kill()
        subprocess.run(["/bin/rm", "-rf", str(tree_root)], check=False)

    if failures:
        print("FAIL: a headless claude -p child must not take over its parent's session")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS: a headless claude -p child leaves the parent's session and notifications alone")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
