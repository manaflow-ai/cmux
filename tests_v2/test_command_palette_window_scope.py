#!/usr/bin/env python3
"""
Regression test: command palette should open only in the active window.

Why: if command-palette toggle is broadcast to all windows, inactive windows can
end up with an open palette that steals focus once they become key.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_until(predicate, timeout_s: float = 5.0, interval_s: float = 0.05, message: str = "timeout") -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _palette_visible(client: cmux, window_id: str) -> bool:
    res = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(res.get("visible"))


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        timeout_s=3.0,
        message=f"palette in {window_id} did not become {visible}",
    )


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)
        w1 = client.current_window()
        w2 = client.new_window()
        time.sleep(0.25)

        ws1 = client.new_workspace(window_id=w1)
        ws2 = client.new_workspace(window_id=w2)
        time.sleep(0.25)
        _set_palette_visible(client, w1, False)
        _set_palette_visible(client, w2, False)

        # Open palette in window1 and verify window2 remains untouched.
        client._call("debug.command_palette.toggle", {"window_id": w1})
        _wait_until(
            lambda: _palette_visible(client, w1),
            timeout_s=3.0,
            message="window1 command palette did not open",
        )
        if _palette_visible(client, w2):
            raise cmuxError("window2 palette became visible when toggling window1")

        # Closing window1 palette should not affect window2.
        client._call("debug.command_palette.toggle", {"window_id": w1})
        _wait_until(
            lambda: not _palette_visible(client, w1),
            timeout_s=3.0,
            message="window1 command palette did not close",
        )

        # Mirror the same check in the other direction.
        client._call("debug.command_palette.toggle", {"window_id": w2})
        _wait_until(
            lambda: _palette_visible(client, w2),
            timeout_s=3.0,
            message="window2 command palette did not open",
        )
        if _palette_visible(client, w1):
            raise cmuxError("window1 palette became visible when toggling window2")
        client._call("debug.command_palette.toggle", {"window_id": w2})
        _wait_until(
            lambda: not _palette_visible(client, w2),
            timeout_s=3.0,
            message="window2 command palette did not close",
        )

    print("PASS: command palette is scoped to active window")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
