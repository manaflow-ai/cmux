#!/usr/bin/env python3
"""
Regression test: mobile.workspace.list must include workspaces from EVERY open
Mac window, not just the key/front window.

Why: the iOS data-plane RPC `mobile.workspace.list` resolved a single window's
TabManager (the key window) and returned only that window's workspaces, so the
phone could never see workspaces that lived in other Mac windows.

Coverage:
- Two windows, each with a uniquely-named workspace. An unscoped
  `mobile.workspace.list` returns both windows' workspaces.
- `is_selected` is set for exactly one workspace: the selected workspace of the
  frontmost/key window. No multi-selection.
- Routing is unaffected: a `mobile.workspace.list` scoped to a workspace that
  lives in the NON-key window still resolves that workspace via its owning
  window, proving create/input/select resource resolution still works for
  non-key-window workspaces.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _mobile_workspaces(client: cmux, params=None) -> list:
    res = client._call("mobile.workspace.list", params or {}) or {}
    return list(res.get("workspaces") or [])


def _find(workspaces: list, workspace_id: str) -> dict:
    for ws in workspaces:
        if str(ws.get("id") or "").lower() == workspace_id.lower():
            return ws
    return {}


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)

        # Collapse to a single known window first.
        window_a = client.current_window()
        for row in client.list_windows():
            other_id = str(row.get("id") or "")
            if other_id and other_id != window_a:
                client.close_window(other_id)
        time.sleep(0.2)

        client.focus_window(window_a)
        client.activate_app()
        time.sleep(0.2)

        # Open a second window.
        window_b = client.new_window()
        time.sleep(0.25)

        token = f"{int(time.time() * 1000)}"
        title_a = f"mobile-list-a-{token}"
        title_b = f"mobile-list-b-{token}"

        workspace_a = client.new_workspace(window_id=window_a)
        client.rename_workspace(title_a, workspace=workspace_a)

        workspace_b = client.new_workspace(window_id=window_b)
        client.rename_workspace(title_b, workspace=workspace_b)
        time.sleep(0.25)

        # Make window A the key/front window so its selected workspace is the
        # one expected to carry is_selected. Select workspace_a explicitly.
        client.focus_window(window_a)
        client.activate_app()
        client.select_workspace(workspace_a)
        time.sleep(0.25)

        # --- Assertion 1: both windows' workspaces appear in one list. ---
        workspaces = _mobile_workspaces(client)
        ids = {str(ws.get("id") or "").lower() for ws in workspaces}
        if workspace_a.lower() not in ids:
            raise cmuxError(
                f"mobile.workspace.list missing window-A workspace {workspace_a}; "
                f"got {sorted(ids)}"
            )
        if workspace_b.lower() not in ids:
            raise cmuxError(
                f"mobile.workspace.list missing window-B (non-key) workspace "
                f"{workspace_b}; got {sorted(ids)}. This is the bug: the phone "
                f"only saw the key window's workspaces."
            )

        # --- Assertion 2: exactly one is_selected, and it is window A's. ---
        selected = [
            str(ws.get("id") or "").lower()
            for ws in workspaces
            if bool(ws.get("is_selected"))
        ]
        if selected != [workspace_a.lower()]:
            raise cmuxError(
                f"expected exactly window-A workspace {workspace_a} to be "
                f"is_selected; got selected={selected}"
            )

        # --- Assertion 3: routing to the NON-key window's workspace works. ---
        # A scoped list naming workspace_b (which lives in window B, not the key
        # window) must still resolve and return that workspace, proving resource
        # resolution for non-key-window workspaces is intact.
        scoped = _mobile_workspaces(client, {"workspace_id": workspace_b})
        scoped_b = _find(scoped, workspace_b)
        if not scoped_b:
            raise cmuxError(
                f"scoped mobile.workspace.list(workspace_id={workspace_b}) did "
                f"not resolve the non-key-window workspace; got {scoped}"
            )
        # Scoped to a single workspace, the result should be exactly that one.
        if len(scoped) != 1:
            raise cmuxError(
                f"scoped mobile.workspace.list(workspace_id={workspace_b}) "
                f"should return exactly one workspace; got {len(scoped)}: {scoped}"
            )

    print(
        "PASS: mobile.workspace.list includes workspaces from all windows, "
        "marks only the key window's selection, and still routes scoped "
        "non-key-window requests"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
