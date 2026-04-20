#!/usr/bin/env python3
"""
Regression test for issue #1027: sidebar "Needs input" indicator stays lit
after Claude goes idle.

Claude Code's Notification hook fires for two distinct scenarios:

    1. permission_prompt — Claude is blocked waiting for tool-use approval.
    2. idle_prompt        — fires ~60s after the prompt input has been idle.

Only (1) (and AskUserQuestion, which is surfaced via PreToolUse) should flip
the sidebar status to "Needs input". Before the fix, every Notification —
including idle_prompts that fire long after Stop already marked the session
Idle — overrode the status to "Needs input", producing the stuck indicator
reported in the bug.
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))

    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def run_claude_hook(
    cli_path: str,
    socket_path: str,
    subcommand: str,
    payload: dict,
    env: dict[str, str],
) -> str:
    proc = subprocess.run(
        [cli_path, "--socket", socket_path, "claude-hook", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"cmux claude-hook {subcommand} failed:\n"
            f"exit={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )
    return proc.stdout.strip()


def claude_code_status_value(client: cmux, workspace_id: str) -> str | None:
    """Return the current value of the `claude_code` sidebar status, or None."""
    response = client._send_command(f"list_status --tab={workspace_id}")
    if response.startswith("ERROR"):
        raise cmuxError(response)
    if response == "No status entries":
        return None
    for line in response.splitlines():
        key, _, rest = line.partition("=")
        if key != "claude_code":
            continue
        # rest looks like "Running priority=0" — the value may contain spaces,
        # but the appended metadata tokens are whitespace-separated key=value
        # pairs. Strip those off.
        tokens = rest.rsplit(" ", 1)
        if len(tokens) == 2 and "=" in tokens[1]:
            return tokens[0]
        return rest
    return None


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        return fail(str(exc))

    state_path = Path(tempfile.gettempdir()) / f"cmux_claude_hook_status_{os.getpid()}.json"
    lock_path = Path(str(state_path) + ".lock")
    try:
        if state_path.exists():
            state_path.unlink()
        if lock_path.exists():
            lock_path.unlink()
    except OSError:
        pass

    project_dir = Path(tempfile.gettempdir()) / f"cmux_claude_status_project_{os.getpid()}"
    project_dir.mkdir(parents=True, exist_ok=True)
    session_id = f"sess-{uuid.uuid4().hex}"

    try:
        with cmux() as client:
            client.set_app_focus(False)
            client.clear_notifications()

            workspace_id = client.new_workspace()
            surfaces = client.list_surfaces()
            if not surfaces:
                return fail("Expected at least one surface in new workspace")

            focused = next((s for s in surfaces if s[2]), surfaces[0])
            surface_id = focused[1]

            hook_env = os.environ.copy()
            hook_env["CMUX_SOCKET_PATH"] = client.socket_path
            hook_env["CMUX_WORKSPACE_ID"] = workspace_id
            hook_env["CMUX_SURFACE_ID"] = surface_id
            hook_env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)

            run_claude_hook(
                cli_path,
                client.socket_path,
                "session-start",
                {"session_id": session_id, "cwd": str(project_dir)},
                hook_env,
            )

            # Simulate a full turn: the user submits a prompt, Claude finishes,
            # Stop fires. Status should now be "Idle".
            run_claude_hook(
                cli_path,
                client.socket_path,
                "prompt-submit",
                {"session_id": session_id, "cwd": str(project_dir)},
                hook_env,
            )
            run_claude_hook(
                cli_path,
                client.socket_path,
                "stop",
                {"session_id": session_id},
                hook_env,
            )

            idle_status = claude_code_status_value(client, workspace_id)
            if idle_status != "Idle":
                return fail(f"Expected status 'Idle' after stop, got {idle_status!r}")

            # Claude Code's idle_prompt fires after 60s of inactivity, with a
            # generic message. This must NOT flip the sidebar to "Needs input"
            # because the agent is not actually blocked — Stop already ran.
            run_claude_hook(
                cli_path,
                client.socket_path,
                "notification",
                {
                    "session_id": session_id,
                    "message": "Claude is waiting for your input",
                },
                hook_env,
            )

            post_idle_status = claude_code_status_value(client, workspace_id)
            if post_idle_status == "Needs input":
                return fail(
                    "idle_prompt notification incorrectly overrode status to 'Needs input' "
                    "(expected status to stay 'Idle' — this is issue #1027)"
                )
            if post_idle_status != "Idle":
                return fail(
                    f"Expected status to stay 'Idle' after idle_prompt, got {post_idle_status!r}"
                )

            # A permission_prompt (tool-use approval) IS a real blocking event —
            # the status must flip to "Needs input".
            run_claude_hook(
                cli_path,
                client.socket_path,
                "notification",
                {
                    "session_id": session_id,
                    "message": "Claude needs your permission to use Bash",
                },
                hook_env,
            )

            permission_status = claude_code_status_value(client, workspace_id)
            if permission_status != "Needs input":
                return fail(
                    f"Expected status 'Needs input' after permission_prompt, "
                    f"got {permission_status!r}"
                )

            # AskUserQuestion goes through PreToolUse (not Notification). The
            # Notification hook that fires right after — even with an
            # idle-looking message — should still mark the agent as needing
            # input, because we tracked that a question is pending.
            run_claude_hook(
                cli_path,
                client.socket_path,
                "prompt-submit",
                {"session_id": session_id, "cwd": str(project_dir)},
                hook_env,
            )
            run_claude_hook(
                cli_path,
                client.socket_path,
                "pre-tool-use",
                {
                    "session_id": session_id,
                    "cwd": str(project_dir),
                    "tool_name": "AskUserQuestion",
                    "tool_input": {
                        "question": "Pick one",
                        "header": "Pick",
                        "multiSelect": False,
                        "options": [
                            {"label": "Yes", "description": "Yes"},
                            {"label": "No", "description": "No"},
                        ],
                    },
                },
                hook_env,
            )
            run_claude_hook(
                cli_path,
                client.socket_path,
                "notification",
                {
                    "session_id": session_id,
                    "message": "Claude is waiting for your input",
                },
                hook_env,
            )

            ask_question_status = claude_code_status_value(client, workspace_id)
            if ask_question_status != "Needs input":
                return fail(
                    f"Expected status 'Needs input' after AskUserQuestion + notification, "
                    f"got {ask_question_status!r}"
                )

            # And once the next turn starts (user submits a reply), the
            # pending-question flag must be cleared so the next idle_prompt
            # doesn't get treated as blocking.
            run_claude_hook(
                cli_path,
                client.socket_path,
                "prompt-submit",
                {"session_id": session_id, "cwd": str(project_dir)},
                hook_env,
            )
            run_claude_hook(
                cli_path,
                client.socket_path,
                "stop",
                {"session_id": session_id},
                hook_env,
            )
            run_claude_hook(
                cli_path,
                client.socket_path,
                "notification",
                {
                    "session_id": session_id,
                    "message": "Claude is waiting for your input",
                },
                hook_env,
            )
            cleared_status = claude_code_status_value(client, workspace_id)
            if cleared_status == "Needs input":
                return fail(
                    "Pending-question flag was not cleared after next Stop — "
                    "idle_prompt should no longer be treated as blocking"
                )

            print("PASS: Claude hook Notification status respects idle_prompt vs permission_prompt")
            return 0

    except (cmuxError, RuntimeError) as exc:
        return fail(str(exc))
    finally:
        try:
            if state_path.exists():
                state_path.unlink()
            if lock_path.exists():
                lock_path.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
