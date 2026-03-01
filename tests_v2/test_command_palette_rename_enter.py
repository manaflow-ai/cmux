#!/usr/bin/env python3
"""
Regression test: command-palette rename flow responds to Enter.

Coverage:
- Enter in rename input applies the new tab name and closes the palette.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_until(predicate, timeout_s=4.0, interval_s=0.05, message="timeout"):
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _palette_visible(client, window_id):
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _rename_input_selection(client, window_id):
    return client._call("debug.command_palette.rename_input.selection", {"window_id": window_id}) or {}


def _focused_pane_id(client):
    panes = client.list_panes()
    focused = [row for row in panes if bool(row[3])]
    if not focused:
        raise cmuxError(f"no focused pane: {panes}")
    return str(focused[0][1])


def _selected_surface_title(client, pane_id):
    rows = client.list_pane_surfaces(pane_id)
    selected = [row for row in rows if bool(row[3])]
    if not selected:
        raise cmuxError(f"no selected surface in pane {pane_id}: {rows}")
    return str(selected[0][2])


def main():
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)

        window_id = client.current_window()
        for row in client.list_windows():
            other_id = str(row.get("id") or "")
            if other_id and other_id != window_id:
                client.close_window(other_id)
        time.sleep(0.2)

        client.focus_window(window_id)
        client.activate_app()
        time.sleep(0.2)

        workspace_id = client.new_workspace(window_id=window_id)
        client.select_workspace(workspace_id)
        time.sleep(0.2)

        pane_id = _focused_pane_id(client)
        rename_to = f"rename-enter-{int(time.time())}"

        client.open_command_palette_rename_tab_input(window_id=window_id)
        _wait_until(
            lambda: _palette_visible(client, window_id),
            message="command palette did not open",
        )
        _wait_until(
            lambda: bool(_rename_input_selection(client, window_id).get("focused")),
            message="rename input did not focus",
        )

        client.simulate_type(rename_to)
        time.sleep(0.1)

        client.simulate_shortcut("enter")
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            message="Enter did not apply rename and close palette",
        )

        new_title = _selected_surface_title(client, pane_id)
        if new_title != rename_to:
            raise cmuxError(f"rename not applied: expected '{rename_to}', got '{new_title}'")

    print("PASS: command-palette rename flow accepts Enter in input")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
