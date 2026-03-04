#!/usr/bin/env python3
"""
E2E regression test for Codex hook session mapping.

Validates:
1) session-start records session_id -> workspace/surface mapping on disk
2) completion notifications route to the mapped surface and avoid false Error
3) approval notifications route to the mapped surface
4) stop consumes mapping and emits a completion summary
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


def run_codex_hook(
    cli_path: str,
    socket_path: str,
    subcommand: str,
    payload: dict,
    env: dict[str, str],
) -> str:
    proc = subprocess.run(
        [cli_path, "--socket", socket_path, "codex-hook", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"cmux codex-hook {subcommand} failed:\n"
            f"exit={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )
    return proc.stdout.strip()


def wait_for_notification_count(client: cmux, minimum: int, timeout: float = 4.0) -> list[dict]:
    start = time.time()
    items: list[dict] = []
    while time.time() - start < timeout:
        items = client.list_notifications()
        if len(items) >= minimum:
            return items
        time.sleep(0.05)
    return items


def latest_notification_with_subtitle(items: list[dict], subtitle: str) -> dict | None:
    for item in items:
        if item.get("subtitle") == subtitle:
            return item
    return None


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        return fail(str(exc))

    state_path = Path(tempfile.gettempdir()) / f"cmux_codex_hook_state_{os.getpid()}.json"
    lock_path = Path(str(state_path) + ".lock")
    try:
        if state_path.exists():
            state_path.unlink()
        if lock_path.exists():
            lock_path.unlink()
    except OSError:
        pass

    project_dir = Path(tempfile.gettempdir()) / f"cmux_codex_map_project_{os.getpid()}"
    project_dir.mkdir(parents=True, exist_ok=True)
    session_id = f"codex-{uuid.uuid4().hex}"
    complete_message = "No open test failures remain. The QA failures I hit were fixed and re-verified."

    try:
        with cmux() as client:
            client.set_app_focus(False)
            client.clear_notifications()

            workspace_id = client.new_workspace()
            surfaces = client.list_surfaces(workspace_id)
            if not surfaces:
                return fail("Expected at least one surface in new workspace")

            focused = next((s for s in surfaces if s[2]), surfaces[0])
            surface_id = focused[1]

            hook_env = os.environ.copy()
            hook_env["CMUX_SOCKET_PATH"] = client.socket_path
            hook_env["CMUX_WORKSPACE_ID"] = workspace_id
            hook_env["CMUX_SURFACE_ID"] = surface_id
            hook_env["CMUX_CODEX_HOOK_STATE_PATH"] = str(state_path)
            hook_env["CMUX_CODEX_SESSION_ID"] = session_id

            run_codex_hook(
                cli_path,
                client.socket_path,
                "session-start",
                {
                    "session_id": session_id,
                    "cwd": str(project_dir),
                },
                hook_env,
            )

            if not state_path.exists():
                return fail(f"Expected state file at {state_path}")

            with state_path.open("r", encoding="utf-8") as f:
                state_data = json.load(f)
            session_row = (state_data.get("sessions") or {}).get(session_id)
            if not session_row:
                return fail("Expected mapped session row after session-start")
            if session_row.get("workspaceId") != workspace_id:
                return fail("Mapped workspaceId did not match active workspace")
            if session_row.get("surfaceId") != surface_id:
                return fail("Mapped surfaceId did not match active surface")

            run_codex_hook(
                cli_path,
                client.socket_path,
                "notification",
                {
                    "event": "agent-turn-complete",
                    "session_id": session_id,
                    "last-assistant-message": complete_message,
                },
                hook_env,
            )

            items = wait_for_notification_count(client, minimum=1)
            if not items:
                return fail("Expected at least one notification after codex-hook notification")

            if latest_notification_with_subtitle(items, "Error") is not None:
                return fail("Unexpected Error subtitle for a negated-failure completion message")

            completion_notification = latest_notification_with_subtitle(items, "Completed")
            if completion_notification is None:
                return fail("Expected a Completed subtitle notification for agent-turn-complete")
            if completion_notification.get("surface_id") != surface_id:
                return fail("Expected completion notification to route to mapped surface")
            if "No open test failures remain" not in completion_notification.get("body", ""):
                return fail("Expected completion body to include the Codex assistant message")

            run_codex_hook(
                cli_path,
                client.socket_path,
                "approval",
                {
                    "event": "approval-requested",
                    "session_id": session_id,
                    "message": "Approval requested: run npm test",
                },
                hook_env,
            )

            items = wait_for_notification_count(client, minimum=2)
            approval_notification = latest_notification_with_subtitle(items, "Approval")
            if approval_notification is None:
                return fail("Expected an Approval subtitle notification")
            if approval_notification.get("surface_id") != surface_id:
                return fail("Expected approval notification to route to mapped surface")

            run_codex_hook(
                cli_path,
                client.socket_path,
                "prompt-submit",
                {
                    "session_id": session_id,
                },
                hook_env,
            )

            run_codex_hook(
                cli_path,
                client.socket_path,
                "stop",
                {
                    "session_id": session_id,
                },
                hook_env,
            )

            items = wait_for_notification_count(client, minimum=3)
            stop_notification = next(
                (
                    item
                    for item in items
                    if item.get("subtitle") == "Completed" and "Codex session completed" in item.get("body", "")
                ),
                None,
            )
            if stop_notification is None:
                return fail("Expected stop notification body to include Codex session completed summary")
            if stop_notification.get("surface_id") != surface_id:
                return fail("Expected stop notification to target mapped surface")

            with state_path.open("r", encoding="utf-8") as f:
                post_stop_state = json.load(f)
            if session_id in (post_stop_state.get("sessions") or {}):
                return fail("Expected session mapping to be consumed on stop")

            print("PASS: Codex hook session mapping + completion/approval classification")
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
