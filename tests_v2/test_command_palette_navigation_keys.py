#!/usr/bin/env python3
"""
Regression test: command palette list navigation keys.

Validates:
- Down: ArrowDown, Ctrl+N, Ctrl+J
- Up: ArrowUp, Ctrl+P, Ctrl+K
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_until(
    predicate,
    timeout_s: float = 4.0,
    interval_s: float = 0.05,
    message: str = "timeout",
) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _palette_visible(client: cmux, window_id: str) -> bool:
    res = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(res.get("visible"))


def _palette_selected_index(client: cmux, window_id: str) -> int:
    res = client._call("debug.command_palette.selection", {"window_id": window_id}) or {}
    return int(res.get("selected_index") or 0)


def _has_focused_surface(client: cmux) -> bool:
    try:
        return any(bool(row[2]) for row in client.list_surfaces())
    except Exception:
        return False


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        message=f"palette visibility did not become {visible}",
    )


def _open_palette_with_query(client: cmux, window_id: str, query: str) -> None:
    _set_palette_visible(client, window_id, False)
    _set_palette_visible(client, window_id, True)
    client.simulate_type(query)
    _wait_until(
        lambda: _palette_selected_index(client, window_id) == 0,
        message="palette selected index did not reset to zero",
    )


def _assert_move(client: cmux, window_id: str, combo: str, start_index: int, expected_index: int) -> None:
    _open_palette_with_query(client, window_id, "new")
    for _ in range(start_index):
        client.simulate_shortcut("down")
    _wait_until(
        lambda: _palette_selected_index(client, window_id) == start_index,
        message=f"failed to seed start index {start_index}",
    )

    client.simulate_shortcut(combo)
    _wait_until(
        lambda: _palette_visible(client, window_id)
        and _palette_selected_index(client, window_id) == expected_index,
        message=f"{combo} did not move selection from {start_index} to {expected_index}",
    )


def _assert_can_navigate_past_ten_results(client: cmux, window_id: str) -> None:
    _open_palette_with_query(client, window_id, "")

    for _ in range(12):
        client.simulate_shortcut("down")

    _wait_until(
        lambda: _palette_visible(client, window_id)
        and _palette_selected_index(client, window_id) >= 10,
        message="selection did not move past index 9 (results may be capped)",
    )


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)
        client.new_workspace()
        time.sleep(0.2)

        window_id = client.current_window()
        # Isolate this test to one window so stale palettes in other windows
        # cannot steal navigation notifications.
        for row in client.list_windows():
            other_id = str(row.get("id") or "")
            if other_id and other_id != window_id:
                client.close_window(other_id)
        time.sleep(0.2)

        client.focus_window(window_id)
        client.activate_app()
        time.sleep(0.2)
        _wait_until(
            lambda: _has_focused_surface(client),
            timeout_s=5.0,
            message="no focused surface available for command palette context",
        )

        for combo in ("down", "ctrl+n", "ctrl+j"):
            _assert_move(client, window_id, combo, start_index=0, expected_index=1)

        for combo in ("up", "ctrl+p", "ctrl+k"):
            _assert_move(client, window_id, combo, start_index=1, expected_index=0)

        _assert_can_navigate_past_ten_results(client, window_id)

        _set_palette_visible(client, window_id, False)

    print("PASS: command palette navigation keys and uncapped result navigation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
