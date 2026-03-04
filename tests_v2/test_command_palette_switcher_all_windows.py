#!/usr/bin/env python3
"""
Regression test: cmd+p switcher should include workspaces from every window.

Why: switcher rows were sourced from the current window's TabManager only, so
Cmd+P could not jump to workspaces/tabs owned by other windows.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_until(predicate, timeout_s: float = 6.0, interval_s: float = 0.05, message: str = "timeout") -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _palette_visible(client: cmux, window_id: str) -> bool:
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _palette_results(client: cmux, window_id: str, limit: int = 20) -> dict:
    return client.command_palette_results(window_id=window_id, limit=limit)


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        message=f"palette visibility in {window_id} did not become {visible}",
    )


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)

        window_a = client.current_window()
        for row in client.list_windows():
            other_id = str(row.get("id") or "")
            if other_id and other_id != window_a:
                client.close_window(other_id)
        time.sleep(0.2)

        client.focus_window(window_a)
        client.activate_app()
        time.sleep(0.2)

        window_b = client.new_window()
        time.sleep(0.25)

        token_suffix = f"{int(time.time() * 1000)}"
        token_a = f"cmdp-window-a-{token_suffix}"
        token_b = f"cmdp-window-b-{token_suffix}"

        workspace_a = client.new_workspace(window_id=window_a)
        client.rename_workspace(token_a, workspace=workspace_a)

        workspace_b = client.new_workspace(window_id=window_b)
        client.rename_workspace(token_b, workspace=workspace_b)
        time.sleep(0.25)

        client.focus_window(window_a)
        client.activate_app()
        time.sleep(0.2)
        _set_palette_visible(client, window_a, False)
        _set_palette_visible(client, window_b, False)

        client.simulate_shortcut("cmd+p")
        _wait_until(
            lambda: _palette_visible(client, window_a),
            message="cmd+p did not open palette in window A",
        )
        _wait_until(
            lambda: str(_palette_results(client, window_a).get("mode") or "") == "switcher",
            message="cmd+p did not open switcher mode in window A",
        )

        client.simulate_type(token_b)
        _wait_until(
            lambda: token_b in str(_palette_results(client, window_a).get("query") or "").strip().lower(),
            message="switcher query did not update with window B token",
        )

        result_rows = (_palette_results(client, window_a, limit=64).get("results") or [])
        target_workspace_command = f"switcher.workspace.{workspace_b.lower()}"
        if not any(str((row or {}).get("command_id") or "") == target_workspace_command for row in result_rows):
            raise cmuxError(
                f"cmd+p switcher in window A did not include workspace from window B "
                f"(expected {target_workspace_command}); rows={result_rows[:8]}"
            )

        client.simulate_shortcut("enter")
        _wait_until(
            lambda: not _palette_visible(client, window_a),
            message="palette did not close after selecting cross-window switcher row",
        )
        _wait_until(
            lambda: client.current_workspace().lower() == workspace_b.lower(),
            message="Enter on cross-window switcher row did not move to window B workspace",
        )
        _wait_until(
            lambda: client.current_window().lower() == window_b.lower(),
            message="Enter on cross-window switcher row did not focus window B",
        )

    print("PASS: cmd+p switcher includes and navigates to workspaces from other windows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
