#!/usr/bin/env python3
"""
Regression test: command-palette search typing should not reset selection.

Why: if focus-lock logic repeatedly re-focuses the text field, typing behaves
like Cmd+A is being spammed and each character replaces the previous query.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_until(predicate, timeout_s=4.0, interval_s=0.04, message="timeout"):
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _palette_visible(client, window_id):
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _palette_input_selection(client, window_id):
    # Uses the shared field-editor probe; works for search and rename modes.
    return client._call("debug.command_palette.rename_input.selection", {"window_id": window_id}) or {}


def _wait_for_input_state(client, window_id, expected_text_length, message, timeout_s=0.8):
    def _matches():
        selection = _palette_input_selection(client, window_id)
        if not selection.get("focused"):
            return False
        text_length = int(selection.get("text_length") or 0)
        selection_location = int(selection.get("selection_location") or 0)
        selection_length = int(selection.get("selection_length") or 0)
        return (
            text_length == expected_text_length
            and selection_location == expected_text_length
            and selection_length == 0
        )

    _wait_until(_matches, timeout_s=timeout_s, message=message)


def _close_palette_if_open(client, window_id):
    if _palette_visible(client, window_id):
        client._call("debug.command_palette.toggle", {"window_id": window_id})
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            message="command palette failed to close",
        )


def _open_palette(client, window_id):
    _close_palette_if_open(client, window_id)
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id),
        message="command palette failed to open",
    )
    _wait_for_input_state(
        client,
        window_id,
        expected_text_length=0,
        message="search input did not focus with empty query",
    )


def main():
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)

        window_id = client.current_window()

        # Keep a single active window for deterministic first-responder behavior.
        for row in client.list_windows():
            other_id = str(row.get("id") or "")
            if other_id and other_id != window_id:
                client.close_window(other_id)
        time.sleep(0.2)
        client.focus_window(window_id)
        client.activate_app()
        time.sleep(0.2)

        probe = "typingstability"
        cycles = 4
        for cycle in range(cycles):
            _open_palette(client, window_id)
            for idx, ch in enumerate(probe, start=1):
                client.simulate_type(ch)
                _wait_for_input_state(
                    client,
                    window_id,
                    expected_text_length=idx,
                    timeout_s=0.7,
                    message=(
                        f"search typing did not accumulate at cycle {cycle + 1}/{cycles}, "
                        f"char {idx}/{len(probe)}"
                    ),
                )
            _close_palette_if_open(client, window_id)

    print("PASS: command-palette search typing accumulates text without select-all churn")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
