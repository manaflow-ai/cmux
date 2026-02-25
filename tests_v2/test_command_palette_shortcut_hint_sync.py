#!/usr/bin/env python3
"""
Regression test: command-palette shortcut hints stay in sync with editable shortcuts.

Validates:
- New Window / Close Window / Rename Tab commands are present in command mode.
- Their displayed shortcut hints reflect the current KeyboardShortcutSettings values.
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


def _palette_visible(client: cmux, window_id: str) -> bool:
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        message=f"command palette did not become visible={visible}",
    )


def _palette_results(client: cmux, window_id: str, limit=12) -> dict:
    return client.command_palette_results(window_id=window_id, limit=limit)


def _open_palette_and_rows(client: cmux, window_id: str, limit: int = 80) -> list:
    _set_palette_visible(client, window_id, False)
    _set_palette_visible(client, window_id, True)
    payload = _palette_results(client, window_id, limit=limit)
    rows = payload.get("results") or []
    if not rows:
        raise cmuxError(f"command palette returned no rows: {payload}")
    return rows


def _assert_shortcut_hint(rows: list, command_id: str, expected_hint: str) -> None:
    row = next((row for row in rows if str((row or {}).get("command_id") or "") == command_id), None)
    if row is None:
        raise cmuxError(f"missing command palette row for {command_id!r}; rows={rows}")
    shortcut_hint = str((row or {}).get("shortcut_hint") or "")
    if shortcut_hint != expected_hint:
        raise cmuxError(
            f"unexpected shortcut hint for {command_id}: expected {expected_hint!r}, got {shortcut_hint!r} row={row}"
        )


def main() -> int:
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

        shortcut_names = ["new_window", "close_window", "rename_tab"]
        try:
            rows = _open_palette_and_rows(client, window_id)
            _assert_shortcut_hint(rows, "palette.newWindow", "⇧⌘N")
            _assert_shortcut_hint(rows, "palette.closeWindow", "⌃⌘W")
            _assert_shortcut_hint(rows, "palette.renameTab", "⌘R")

            client.set_shortcut("new_window", "cmd+opt+n")
            client.set_shortcut("close_window", "cmd+opt+w")
            client.set_shortcut("rename_tab", "cmd+ctrl+r")

            rows = _open_palette_and_rows(client, window_id)
            _assert_shortcut_hint(rows, "palette.newWindow", "⌥⌘N")
            _assert_shortcut_hint(rows, "palette.closeWindow", "⌥⌘W")
            _assert_shortcut_hint(rows, "palette.renameTab", "⌃⌘R")
        finally:
            for name in shortcut_names:
                try:
                    client.set_shortcut(name, "clear")
                except cmuxError:
                    pass
            _set_palette_visible(client, window_id, False)

    print("PASS: command-palette shortcut hints track editable shortcuts for new/close/rename window-tab actions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
