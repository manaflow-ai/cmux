#!/usr/bin/env python3
"""
Regression test: command-palette search updates rows and executed action in sync.

Why: if query replacement doesn't fully refresh the result list, the top row text
can lag behind the action executed on Enter.
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


def _set_palette_visible(client, window_id, visible):
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        message=f"command palette did not become visible={visible}",
    )


def _palette_results(client, window_id, limit=10):
    return client.command_palette_results(window_id=window_id, limit=limit)


def _palette_input_selection(client, window_id):
    # Shared field-editor probe used by other command palette regressions.
    return client._call("debug.command_palette.rename_input.selection", {"window_id": window_id}) or {}


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

        _set_palette_visible(client, window_id, False)
        _set_palette_visible(client, window_id, True)
        _wait_until(
            lambda: bool(_palette_input_selection(client, window_id).get("focused")),
            message="palette search input did not focus",
        )

        client.simulate_shortcut("cmd+a")
        client.simulate_type(">open")
        _wait_until(
            lambda: "open" in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="palette query did not become 'open'",
        )

        before = _palette_results(client, window_id, limit=8)
        before_rows = before.get("results") or []
        if not before_rows:
            raise cmuxError(f"no results for 'open': {before}")
        if str(before_rows[0].get("command_id") or "") != "palette.terminalOpenDirectory":
            raise cmuxError(f"unexpected top command for 'open': {before_rows[0]}")

        client.simulate_shortcut("cmd+a")
        client.simulate_type(">rename")
        _wait_until(
            lambda: "rename" in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="palette query did not become 'rename' after replacement",
        )
        after = _palette_results(client, window_id, limit=8)
        after_rows = after.get("results") or []
        if not after_rows:
            raise cmuxError(f"no results for 'rename' after replacement: {after}")
        top_after = str(after_rows[0].get("command_id") or "")
        if top_after not in {"palette.renameWorkspace", "palette.renameTab"}:
            raise cmuxError(f"top result did not update to rename command after replacement: {after_rows[0]}")

        client.simulate_shortcut("enter")
        _wait_until(
            lambda: bool(_palette_input_selection(client, window_id).get("focused")),
            message="Enter did not trigger renamed top command input",
        )

        _set_palette_visible(client, window_id, False)

    print("PASS: command-palette search replacement keeps row text/action in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
