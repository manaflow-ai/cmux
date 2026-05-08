#!/usr/bin/env python3
"""
E2E tests for multi-window socket control (v2).

Goals:
- window handles are stable UUIDs
- workspace IDs can be moved across windows
- surface IDs remain stable when their workspace moves windows
"""

import os
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _focused_window_id(c: cmux) -> str:
    ident = c.identify()
    focused = ident.get("focused") or {}
    if isinstance(focused, dict):
        wid = focused.get("window_id")
        if wid:
            return str(wid)
    # Fallback in case identify.focused isn't populated yet.
    return c.current_window()


def _send_v1(command: str) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5.0)
        sock.connect(SOCKET_PATH)
        sock.sendall((command + "\n").encode("utf-8"))
        chunks: list[bytes] = []
        while True:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            chunks.append(chunk)
            sock.settimeout(0.1)
    return b"".join(chunks).decode("utf-8", errors="replace").strip()


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        windows0 = c.list_windows()
        if not windows0:
            raise cmuxError("Expected at least one window from window.list")

        w1 = _focused_window_id(c)

        w2 = c.new_window()
        time.sleep(0.2)

        windows1 = c.list_windows()
        ids1 = {str(w.get("id")) for w in windows1 if w.get("id")}
        if w1 not in ids1:
            raise cmuxError(f"Expected original window id in window.list (w1={w1}, ids={sorted(ids1)})")
        if w2 not in ids1:
            raise cmuxError(f"Expected new window id in window.list (w2={w2}, ids={sorted(ids1)})")

        # Create a workspace in w1, ensure it has at least 2 surfaces, then move it to w2.
        ws = c.new_workspace(window_id=w1)
        c.select_workspace(ws, window_id=w1)
        time.sleep(0.2)

        _ = c.new_split("right")
        time.sleep(0.5)

        before = c.list_surfaces(ws)
        before_ids = [sid for _, sid, _focused in before]
        if len(before_ids) < 2:
            raise cmuxError(f"Expected >=2 surfaces before move, got {len(before_ids)} ({before_ids})")

        c.move_workspace_to_window(ws, w2, focus=True)
        time.sleep(0.5)

        # Wait for reattachment after cross-window move.
        start = time.time()
        while time.time() - start < 6.0:
            health = c.surface_health(ws)
            if health and all(h.get("in_window") is True for h in health):
                break
            time.sleep(0.2)
        else:
            raise cmuxError(f"Expected all moved surfaces to be in_window=true (health={health})")

        # Ensure the moved workspace is now associated with destination window.
        w2_workspaces = c.list_workspaces(window_id=w2)
        w2_ids = {wid for _, wid, _title, _sel in w2_workspaces}
        if ws not in w2_ids:
            raise cmuxError("Expected moved workspace to be present in destination window")

        # Selecting by explicit workspace ID without a window_id should infer the
        # destination membership, not reattach the workspace to the first window.
        selected = c._call("workspace.select", {"workspace_id": ws}) or {}
        selected_window = str(selected.get("window_id") or selected.get("window_ref") or "")
        if selected_window != w2:
            raise cmuxError(f"Expected workspace.select to infer destination window {w2}, got {selected}")
        w1_after_inferred_select = c.list_workspaces(window_id=w1)
        w1_after_inferred_ids = {wid for _, wid, _title, _sel in w1_after_inferred_select}
        if ws in w1_after_inferred_ids:
            raise cmuxError("workspace.select without window_id reattached moved workspace to source window")

        legacy_select = _send_v1(f"select_workspace {ws}")
        if legacy_select != "OK":
            raise cmuxError(f"legacy select_workspace failed: {legacy_select!r}")
        w1_after_legacy_select = c.list_workspaces(window_id=w1)
        w1_after_legacy_ids = {wid for _, wid, _title, _sel in w1_after_legacy_select}
        if ws in w1_after_legacy_ids:
            raise cmuxError("legacy select_workspace reattached moved workspace to source window")

        surface_focus = c._call("surface.focus", {"surface_id": before_ids[0]}) or {}
        if str(surface_focus.get("workspace_id") or surface_focus.get("workspace_ref") or "") != ws:
            raise cmuxError(f"surface.focus did not target moved workspace {ws}: {surface_focus}")
        w1_after_surface_focus = c.list_workspaces(window_id=w1)
        w1_after_surface_ids = {wid for _, wid, _title, _sel in w1_after_surface_focus}
        if ws in w1_after_surface_ids:
            raise cmuxError("surface.focus reattached moved workspace to source window")

        panes = (c._call("pane.list", {"workspace_id": ws}) or {}).get("panes") or []
        pane_id = str(panes[0].get("id")) if panes else ""
        if not pane_id:
            raise cmuxError(f"pane.list returned no pane for moved workspace {ws}: {panes}")
        pane_focus = c._call("pane.focus", {"workspace_id": ws, "pane_id": pane_id}) or {}
        if str(pane_focus.get("workspace_id") or pane_focus.get("workspace_ref") or "") != ws:
            raise cmuxError(f"pane.focus did not target moved workspace {ws}: {pane_focus}")
        w1_after_pane_focus = c.list_workspaces(window_id=w1)
        w1_after_pane_ids = {wid for _, wid, _title, _sel in w1_after_pane_focus}
        if ws in w1_after_pane_ids:
            raise cmuxError("pane.focus reattached moved workspace to source window")

        pane_resize = c._call(
            "pane.resize",
            {"workspace_id": ws, "pane_id": pane_id, "direction": "right", "amount": 1},
        ) or {}
        if str(pane_resize.get("window_id") or pane_resize.get("window_ref") or "") != w2:
            raise cmuxError(f"pane.resize did not stay in destination window: {pane_resize}")
        w1_after_pane_resize = c.list_workspaces(window_id=w1)
        w1_after_pane_resize_ids = {wid for _, wid, _title, _sel in w1_after_pane_resize}
        if ws in w1_after_pane_resize_ids:
            raise cmuxError("pane.resize reattached moved workspace to source window")

        surface_move = c._call(
            "surface.move",
            {"workspace_id": ws, "surface_id": before_ids[-1], "pane_id": pane_id, "focus": True},
        ) or {}
        if str(surface_move.get("window_id") or surface_move.get("window_ref") or "") != w2:
            raise cmuxError(f"surface.move did not stay in destination window: {surface_move}")
        w1_after_surface_move = c.list_workspaces(window_id=w1)
        w1_after_surface_move_ids = {wid for _, wid, _title, _sel in w1_after_surface_move}
        if ws in w1_after_surface_move_ids:
            raise cmuxError("surface.move reattached moved workspace to source window")

        c._call("debug.notification.focus", {"workspace_id": ws})
        w1_after_notification_focus = c.list_workspaces(window_id=w1)
        w1_after_notification_ids = {wid for _, wid, _title, _sel in w1_after_notification_focus}
        if ws in w1_after_notification_ids:
            raise cmuxError("debug.notification.focus reattached moved workspace to source window")

        browser_open = c._call(
            "browser.open_split",
            {
                "workspace_id": ws,
                "url": "data:text/html,<title>WindowScopeOne</title><body>one</body>",
            },
        ) or {}
        browser_one = str(browser_open.get("surface_id") or "")
        if str(browser_open.get("window_id") or browser_open.get("window_ref") or "") != w2:
            raise cmuxError(
                f"browser.open_split did not stay in destination window: {browser_open}"
            )
        if not browser_one:
            raise cmuxError("browser.open_split returned no surface_id for moved workspace")
        browser_two_result = c._call(
            "browser.tab.new",
            {
                "surface_id": browser_one,
                "url": "data:text/html,<title>WindowScopeTwo</title><body>two</body>",
            },
        ) or {}
        browser_two = str(browser_two_result.get("surface_id") or "")
        if not browser_two or browser_two == browser_one:
            raise cmuxError(f"browser.tab.new returned invalid surface_id: {browser_two_result}")
        if str(browser_two_result.get("window_id") or browser_two_result.get("window_ref") or "") != w2:
            raise cmuxError(f"browser.tab.new did not stay in destination window: {browser_two_result}")
        w1_after_browser_new = c.list_workspaces(window_id=w1)
        w1_after_browser_new_ids = {wid for _, wid, _title, _sel in w1_after_browser_new}
        if ws in w1_after_browser_new_ids:
            raise cmuxError("browser.tab.new reattached moved workspace to source window")

        browser_list = c._call("browser.tab.list", {"surface_id": browser_two}) or {}
        if str(browser_list.get("window_id") or browser_list.get("window_ref") or "") != w2:
            raise cmuxError(f"browser.tab.list did not stay in destination window: {browser_list}")
        browser_list_workspace = str(
            browser_list.get("workspace_id") or browser_list.get("workspace_ref") or ""
        )
        if browser_list_workspace != ws:
            raise cmuxError(f"browser.tab.list returned wrong workspace: {browser_list}")
        listed_browser_ids = {
            str(tab.get("id") or tab.get("ref") or "")
            for tab in browser_list.get("tabs") or []
        }
        if browser_one not in listed_browser_ids or browser_two not in listed_browser_ids:
            raise cmuxError(f"browser.tab.list missed moved-workspace tabs: {browser_list}")
        w1_after_browser_list = c.list_workspaces(window_id=w1)
        w1_after_browser_list_ids = {wid for _, wid, _title, _sel in w1_after_browser_list}
        if ws in w1_after_browser_list_ids:
            raise cmuxError("browser.tab.list reattached moved workspace to source window")

        browser_switch = c._call(
            "browser.tab.switch",
            {"surface_id": browser_two, "target_surface_id": browser_one},
        ) or {}
        if str(browser_switch.get("window_id") or browser_switch.get("window_ref") or "") != w2:
            raise cmuxError(f"browser.tab.switch did not stay in destination window: {browser_switch}")
        browser_close = c._call(
            "browser.tab.close",
            {"surface_id": browser_one, "target_surface_id": browser_two},
        ) or {}
        if not browser_close.get("closed"):
            raise cmuxError(f"browser.tab.close did not report closed: {browser_close}")
        if str(browser_close.get("window_id") or browser_close.get("window_ref") or "") != w2:
            raise cmuxError(f"browser.tab.close did not stay in destination window: {browser_close}")
        w1_after_browser_close = c.list_workspaces(window_id=w1)
        w1_after_browser_close_ids = {wid for _, wid, _title, _sel in w1_after_browser_close}
        if ws in w1_after_browser_close_ids:
            raise cmuxError("browser.tab.close reattached moved workspace to source window")

        remote_configure = c._call(
            "workspace.remote.configure",
            {
                "workspace_id": ws,
                "destination": "window-scope.example.com",
                "auto_connect": False,
            },
        ) or {}
        if str(remote_configure.get("window_id") or remote_configure.get("window_ref") or "") != w2:
            raise cmuxError(f"workspace.remote.configure did not stay in destination window: {remote_configure}")
        remote_status = c._call("workspace.remote.status", {"workspace_id": ws}) or {}
        if str(remote_status.get("window_id") or remote_status.get("window_ref") or "") != w2:
            raise cmuxError(f"workspace.remote.status did not stay in destination window: {remote_status}")
        remote_disconnect = c._call("workspace.remote.disconnect", {"workspace_id": ws}) or {}
        if str(remote_disconnect.get("window_id") or remote_disconnect.get("window_ref") or "") != w2:
            raise cmuxError(f"workspace.remote.disconnect did not stay in destination window: {remote_disconnect}")
        w1_after_remote = c.list_workspaces(window_id=w1)
        w1_after_remote_ids = {wid for _, wid, _title, _sel in w1_after_remote}
        if ws in w1_after_remote_ids:
            raise cmuxError("workspace.remote.* reattached moved workspace to source window")

        alt_ws = c.new_workspace(window_id=w2)
        c.select_workspace(alt_ws, window_id=w2)
        c.select_workspace(ws, window_id=w2)
        last_workspace = c._call("workspace.last", {"window_id": w2}) or {}
        if str(last_workspace.get("window_id") or last_workspace.get("window_ref") or "") != w2:
            raise cmuxError(f"workspace.last did not stay in destination window: {last_workspace}")
        if str(last_workspace.get("workspace_id") or last_workspace.get("workspace_ref") or "") != alt_ws:
            raise cmuxError(f"workspace.last did not select destination window history: {last_workspace}")
        w1_after_workspace_last = c.list_workspaces(window_id=w1)
        w1_after_workspace_last_ids = {wid for _, wid, _title, _sel in w1_after_workspace_last}
        if ws in w1_after_workspace_last_ids or alt_ws in w1_after_workspace_last_ids:
            raise cmuxError("workspace.last reattached destination workspaces to source window")
        c.select_workspace(ws, window_id=w2)

        # Focus behavior can lag under VM/SSH app-activation conditions.
        # Ensure the workspace is at least selectable post-move.
        c.select_workspace(ws, window_id=w2)
        time.sleep(0.2)
        ident2 = c.identify()
        focused2 = ident2.get("focused") or {}
        if not isinstance(focused2, dict) or str(focused2.get("workspace_id")) != ws:
            raise cmuxError(f"Expected moved workspace to be selectable after move (focused={focused2})")

        after = c.list_surfaces(ws)
        after_ids = [sid for _, sid, _focused in after]
        if not set(before_ids).issubset(set(after_ids)):
            raise cmuxError(
                f"Expected moved surface IDs to remain stable after move (before={before_ids}, after={after_ids})"
            )

        # Source window should still have workspaces, but not this one.
        w1_workspaces = c.list_workspaces(window_id=w1)
        w1_ids = {wid for _, wid, _title, _sel in w1_workspaces}
        if ws in w1_ids:
            raise cmuxError("Expected moved workspace to no longer be present in source window")

    print("PASS: window list/create + workspace move preserves surface IDs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
