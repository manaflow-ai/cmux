#!/usr/bin/env python3
"""
Regression test: opening the command palette must move focus away from terminal.

Why: if terminal remains first responder under the palette, typing goes into the shell
instead of the palette search field.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _focused_surface_id(client: cmux) -> str:
    surfaces = client.list_surfaces()
    for _, sid, focused in surfaces:
        if focused:
            return sid
    raise cmuxError(f"No focused surface in list_surfaces: {surfaces}")


def _palette_visible(client: cmux, window_id: str) -> bool:
    res = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(res.get("visible"))


def _wait_until(predicate, timeout_s: float = 3.0, interval_s: float = 0.05, message: str = "timeout") -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def main() -> int:
    token = "CMUX_PALETTE_FOCUS_PROBE_9412"
    restore_token = "CMUX_PALETTE_RESTORE_PROBE_7731"

    with cmux(SOCKET_PATH) as client:
        client.new_workspace()
        client.activate_app()
        time.sleep(0.2)

        window_id = client.current_window()
        panel_id = _focused_surface_id(client)
        _wait_until(
            lambda: client.is_terminal_focused(panel_id),
            timeout_s=5.0,
            message=f"terminal never became focused for panel {panel_id}",
        )

        pre_text = client.read_terminal_text(panel_id)

        # Open palette via debug method and assert terminal focus drops.
        client._call("debug.command_palette.toggle", {"window_id": window_id})
        _wait_until(
            lambda: _palette_visible(client, window_id),
            timeout_s=3.0,
            message="command palette did not open",
        )

        # Typing now should target palette input, not the terminal.
        client.simulate_type(token)
        time.sleep(0.15)
        post_text = client.read_terminal_text(panel_id)

        if token in post_text and token not in pre_text:
            raise cmuxError("typed probe text leaked into terminal while palette is open")

        # Close palette and ensure focus returns to previously-focused terminal.
        client._call("debug.command_palette.toggle", {"window_id": window_id})
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            timeout_s=3.0,
            message="command palette did not close",
        )

        client.simulate_type(restore_token)
        time.sleep(0.15)
        restore_text = client.read_terminal_text(panel_id)
        if restore_token not in restore_text:
            raise cmuxError("terminal did not receive typing after closing command palette")

    print("PASS: command palette steals and restores terminal focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
