#!/usr/bin/env python3
"""
E2E regression test for Droid hook session mapping.

Validates:
1) session-start records session_id -> workspace/surface mapping on disk
2) notification targets the mapped surface and stores last context
3) stop emits a completion notification with project and last-message context
4) session-end consumes the saved session mapping without clearing the completion notification
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from claude_teams_test_utils import resolve_cmux_cli
from cmux import cmux, cmuxError


def run_droid_hook(
    cli_path: str,
    socket_path: str,
    subcommand: str,
    payload: dict,
    env: dict[str, str],
) -> str:
    proc = subprocess.run(
        [cli_path, "--socket", socket_path, "droid-hook", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"cmux droid-hook {subcommand} failed:\n"
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


def wait_for_workspace_surface(
    client: cmux,
    workspace_id: str,
    timeout: float = 4.0,
) -> str | None:
    start = time.time()
    while time.time() - start < timeout:
        try:
            client.select_workspace(workspace_id)
            surfaces = client.list_surfaces(workspace_id)
        except cmuxError:
            time.sleep(0.05)
            continue
        if surfaces:
            focused = next((surface for surface in surfaces if surface[2]), surfaces[0])
            return focused[1]
        time.sleep(0.05)
    return None


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        return fail(str(exc))

    state_path = Path(tempfile.gettempdir()) / f"cmux_droid_hook_state_{os.getpid()}.json"
    lock_path = Path(str(state_path) + ".lock")
    try:
        if state_path.exists():
            state_path.unlink()
        if lock_path.exists():
            lock_path.unlink()
    except OSError:
        pass

    project_dir = Path(tempfile.gettempdir()) / f"cmux_droid_map_project_{os.getpid()}"
    project_dir.mkdir(parents=True, exist_ok=True)
    session_id = f"droid-{uuid.uuid4().hex}"
    last_message = "Please approve deploy migration"

    try:
        with cmux() as client:
            client.set_app_focus(False)
            client.clear_notifications()

            workspace_id = client.new_workspace()
            surface_id = wait_for_workspace_surface(client, workspace_id)
            if not surface_id:
                return fail("Expected at least one surface in new workspace")

            hook_env = os.environ.copy()
            hook_env["CMUX_SOCKET_PATH"] = client.socket_path
            hook_env["CMUX_WORKSPACE_ID"] = workspace_id
            hook_env["CMUX_SURFACE_ID"] = surface_id
            hook_env["CMUX_DROID_HOOK_STATE_PATH"] = str(state_path)

            run_droid_hook(
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

            with state_path.open("r", encoding="utf-8") as handle:
                state_data = json.load(handle)
            session_row = (state_data.get("sessions") or {}).get(session_id)
            if not session_row:
                return fail("Expected mapped session row after session-start")
            if session_row.get("workspaceId") != workspace_id:
                return fail("Mapped workspaceId did not match active workspace")
            if session_row.get("surfaceId") != surface_id:
                return fail("Mapped surfaceId did not match active surface")

            run_droid_hook(
                cli_path,
                client.socket_path,
                "notification",
                {
                    "session_id": session_id,
                    "message": last_message,
                    "type": "permission",
                    "cwd": str(project_dir),
                },
                hook_env,
            )

            items = wait_for_notification_count(client, minimum=1)
            if not items:
                return fail("Expected at least one notification after droid-hook notification")
            permission_notification = latest_notification_with_subtitle(items, "Permission")
            if permission_notification is None:
                return fail("Expected a Permission subtitle notification")
            if permission_notification.get("surface_id") != surface_id:
                return fail("Expected notification to route to mapped surface")
            if last_message not in permission_notification.get("body", ""):
                return fail("Expected notification body to include the Droid message")

            run_droid_hook(
                cli_path,
                client.socket_path,
                "stop",
                {
                    "session_id": session_id,
                    "cwd": str(project_dir),
                },
                hook_env,
            )

            items = wait_for_notification_count(client, minimum=2)
            completed_notification = latest_notification_with_subtitle(items, "Completed")
            if completed_notification is None:
                return fail("Expected a Completed subtitle notification on stop")
            body = completed_notification.get("body", "")
            if project_dir.name not in body:
                return fail("Expected stop notification body to include project directory name")
            if "Last:" not in body:
                return fail("Expected stop notification body to include last activity summary")
            if "approve deploy migration" not in body.lower():
                return fail("Expected stop notification body to include last Droid message context")
            if completed_notification.get("surface_id") != surface_id:
                return fail("Expected stop notification to target mapped surface")

            with state_path.open("r", encoding="utf-8") as handle:
                post_stop_state = json.load(handle)
            if session_id not in (post_stop_state.get("sessions") or {}):
                return fail("Expected session mapping to remain until session-end")

            run_droid_hook(
                cli_path,
                client.socket_path,
                "session-end",
                {
                    "session_id": session_id,
                },
                hook_env,
            )

            with state_path.open("r", encoding="utf-8") as handle:
                post_end_state = json.load(handle)
            if session_id in (post_end_state.get("sessions") or {}):
                return fail("Expected session mapping to be consumed on session-end")
            items = client.list_notifications()
            completed_after_end = latest_notification_with_subtitle(items, "Completed")
            if completed_after_end is None:
                return fail("Expected completion notification to remain after session-end")

            print("PASS: Droid hook session mapping, notification routing, and teardown cleanup")
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
