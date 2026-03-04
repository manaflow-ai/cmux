#!/usr/bin/env python3
"""
Test that claude-hook notification only sets "Needs input" for input-requiring
notification types (permission_prompt, idle_prompt, elicitation_dialog) and
preserves existing status for other types (e.g. auth_success).
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import sys
import time
import uuid

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


def get_status(client: cmux, tab_id: str, key: str = "claude_code") -> str | None:
    lines = client.list_meta(tab=tab_id).splitlines()
    for line in lines:
        if line.startswith(f"{key}="):
            parts = line.split("=", 1)
            if len(parts) == 2:
                val = parts[1]
                if " " in val:
                    val = val.split(" ")[0]
                return val
    return None


def wait_for_status(
    client: cmux, tab_id: str, expected: str | None, timeout: float = 4.0
) -> str | None:
    start = time.time()
    while time.time() - start < timeout:
        status = get_status(client, tab_id)
        if expected is None and status is None:
            return None
        if status == expected:
            return status
        time.sleep(0.1)
    return get_status(client, tab_id)


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        return fail(str(exc))

    try:
        with cmux() as client:
            client.set_app_focus(False)

            workspace_id = client.current_workspace()
            surfaces = client.list_surfaces()
            if not surfaces:
                return fail("Expected at least one surface")

            focused = next((s for s in surfaces if s[2]), surfaces[0])
            surface_id = focused[1]

            hook_env = os.environ.copy()
            hook_env["CMUX_SOCKET_PATH"] = client.socket_path
            hook_env["CMUX_WORKSPACE_ID"] = workspace_id
            hook_env["CMUX_SURFACE_ID"] = surface_id

            session_id = f"sess-{uuid.uuid4().hex}"

            # 1) Start session -> should set "Running"
            run_claude_hook(cli_path, client.socket_path, "session-start", {
                "session_id": session_id,
            }, hook_env)
            status = wait_for_status(client, workspace_id, "Running")
            if status != "Running":
                return fail(f"Expected 'Running' after session-start, got '{status}'")
            print("  [ok] session-start sets Running")

            # 2) Notification with permission_prompt -> should set "Needs input"
            run_claude_hook(cli_path, client.socket_path, "notification", {
                "session_id": session_id,
                "notification_type": "permission_prompt",
                "message": "Claude needs permission to use Bash",
            }, hook_env)
            status = wait_for_status(client, workspace_id, "Needs")
            if status != "Needs":
                return fail(f"Expected 'Needs' (input) after permission_prompt, got '{status}'")
            print("  [ok] permission_prompt sets Needs input")

            # 3) Reset to Running via prompt-submit
            run_claude_hook(cli_path, client.socket_path, "prompt-submit", {
                "session_id": session_id,
            }, hook_env)
            status = wait_for_status(client, workspace_id, "Running")
            if status != "Running":
                return fail(f"Expected 'Running' after prompt-submit, got '{status}'")
            print("  [ok] prompt-submit resets to Running")

            # 4) Notification with auth_success -> should NOT change status
            run_claude_hook(cli_path, client.socket_path, "notification", {
                "session_id": session_id,
                "notification_type": "auth_success",
                "message": "Authentication successful",
            }, hook_env)
            time.sleep(0.5)
            status = get_status(client, workspace_id)
            if status != "Running":
                return fail(f"Expected 'Running' preserved after auth_success, got '{status}'")
            print("  [ok] auth_success preserves Running status")

            # 5) Notification with idle_prompt -> should set "Needs input"
            run_claude_hook(cli_path, client.socket_path, "notification", {
                "session_id": session_id,
                "notification_type": "idle_prompt",
                "message": "Claude is waiting for your input",
            }, hook_env)
            status = wait_for_status(client, workspace_id, "Needs")
            if status != "Needs":
                return fail(f"Expected 'Needs' (input) after idle_prompt, got '{status}'")
            print("  [ok] idle_prompt sets Needs input")

            # 6) Reset and test elicitation_dialog
            run_claude_hook(cli_path, client.socket_path, "prompt-submit", {
                "session_id": session_id,
            }, hook_env)
            wait_for_status(client, workspace_id, "Running")

            run_claude_hook(cli_path, client.socket_path, "notification", {
                "session_id": session_id,
                "notification_type": "elicitation_dialog",
                "message": "Claude wants to ask you a question",
            }, hook_env)
            status = wait_for_status(client, workspace_id, "Needs")
            if status != "Needs":
                return fail(f"Expected 'Needs' (input) after elicitation_dialog, got '{status}'")
            print("  [ok] elicitation_dialog sets Needs input")

            # 7) Notification with NO notification_type -> should set "Needs input" (backward compat)
            run_claude_hook(cli_path, client.socket_path, "prompt-submit", {
                "session_id": session_id,
            }, hook_env)
            wait_for_status(client, workspace_id, "Running")

            run_claude_hook(cli_path, client.socket_path, "notification", {
                "session_id": session_id,
                "message": "Some notification without type",
            }, hook_env)
            status = wait_for_status(client, workspace_id, "Needs")
            if status != "Needs":
                return fail(f"Expected 'Needs' (input) for untyped notification (backward compat), got '{status}'")
            print("  [ok] untyped notification sets Needs input (backward compat)")

            # Cleanup
            run_claude_hook(cli_path, client.socket_path, "stop", {
                "session_id": session_id,
            }, hook_env)

        print("PASS: Claude hook notification_type filtering")
        return 0

    except (cmuxError, RuntimeError) as exc:
        return fail(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
