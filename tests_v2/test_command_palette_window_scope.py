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


def _palette_results(client: cmux, window_id: str, limit: int = 20) -> dict:
    return client.command_palette_results(window_id=window_id, limit=limit)


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        timeout_s=3.0,
        message=f"palette in {window_id} did not become {visible}",
    )


def _focus_window(client: cmux, window_id: str) -> None:
    client.focus_window(window_id)
    client.activate_app()
    _wait_until(
        lambda: client.current_window().lower() == window_id.lower(),
        timeout_s=3.0,
        message=f"failed to focus window {window_id}",
    )
    time.sleep(0.15)


def _assert_shortcut_window_scoped(client: cmux, shortcut: str, w1: str, w2: str) -> None:
    _set_palette_visible(client, w1, False)
    _set_palette_visible(client, w2, False)

    _focus_window(client, w1)
    client.simulate_shortcut(shortcut)
    _wait_until(
        lambda: _palette_visible(client, w1),
        timeout_s=3.0,
        message=f"{shortcut} did not open palette in window1",
    )
    if _palette_visible(client, w2):
        raise cmuxError(f"{shortcut} in window1 incorrectly opened palette in window2")

    _focus_window(client, w2)
    client.simulate_shortcut(shortcut)
    _wait_until(
        lambda: _palette_visible(client, w2),
        timeout_s=3.0,
        message=f"{shortcut} did not open palette in window2",
    )
    if not _palette_visible(client, w1):
        raise cmuxError(
            f"{shortcut} in window2 incorrectly toggled window1 palette off "
            "(cross-window routing regression)"
        )

    client.simulate_shortcut(shortcut)
    _wait_until(
        lambda: not _palette_visible(client, w2),
        timeout_s=3.0,
        message=f"second {shortcut} did not close palette in window2",
    )
    if not _palette_visible(client, w1):
        raise cmuxError(
            f"second {shortcut} in window2 incorrectly changed window1 palette visibility"
        )

    _focus_window(client, w1)
    client.simulate_shortcut(shortcut)
    _wait_until(
        lambda: not _palette_visible(client, w1),
        timeout_s=3.0,
        message=f"second {shortcut} did not close palette in window1",
    )


def _assert_cross_window_typing_after_mixed_shortcuts(client: cmux, w1: str, w2: str) -> None:
    _set_palette_visible(client, w1, False)
    _set_palette_visible(client, w2, False)

    _focus_window(client, w1)
    client.simulate_shortcut("cmd+shift+p")
    _wait_until(
        lambda: _palette_visible(client, w1),
        timeout_s=3.0,
        message="cmd+shift+p did not open palette in window1",
    )
    _wait_until(
        lambda: str(_palette_results(client, w1).get("mode") or "") == "commands",
        timeout_s=3.0,
        message="window1 palette did not enter commands mode",
    )
    window1_query_before = str(_palette_results(client, w1).get("query") or "")

    _focus_window(client, w2)
    client.simulate_shortcut("cmd+p")
    _wait_until(
        lambda: _palette_visible(client, w2),
        timeout_s=3.0,
        message="cmd+p did not open palette in window2",
    )
    _wait_until(
        lambda: str(_palette_results(client, w2).get("mode") or "") == "switcher",
        timeout_s=3.0,
        message="window2 palette did not enter switcher mode",
    )

    typed = ""
    for ch in "crosswindow":
        typed += ch
        client.simulate_type(ch)
        _wait_until(
            lambda expected=typed: str(_palette_results(client, w2).get("query") or "").lower() == expected,
            timeout_s=1.8,
            message=(
                "typing into window2 palette did not accumulate query text "
                f"(expected {typed!r})"
            ),
        )

        window1_query_now = str(_palette_results(client, w1).get("query") or "")
        if window1_query_now != window1_query_before:
            raise cmuxError(
                "typing in window2 changed window1 command-palette query "
                f"(before={window1_query_before!r}, now={window1_query_now!r})"
            )


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)
        w1 = client.current_window()
        w2 = client.new_window()
        time.sleep(0.25)

        _ = client.new_workspace(window_id=w1)
        _ = client.new_workspace(window_id=w2)
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

        # Reproduce keyboard-shortcut window-scoping path:
        # opening from window2 must not jump back and toggle window1.
        _assert_shortcut_window_scoped(client, "cmd+shift+p", w1, w2)
        _assert_shortcut_window_scoped(client, "cmd+p", w1, w2)
        _assert_cross_window_typing_after_mixed_shortcuts(client, w1, w2)

    print("PASS: command palette is scoped to active window")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
