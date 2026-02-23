#!/usr/bin/env python3
"""
Regression test: backspace on empty rename input returns to command list.

Coverage:
- First backspace clears selected rename text.
- Second backspace on empty rename input navigates back to command list mode.
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


def _palette_results(client, window_id):
    return client.command_palette_results(window_id, limit=20)


def _rename_selection(client, window_id):
    return client._call("debug.command_palette.rename_input.selection", {"window_id": window_id}) or {}


def _int_or(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return int(default)


def _open_rename_input(client, window_id):
    client.activate_app()
    client.focus_window(window_id)
    time.sleep(0.1)

    if _palette_visible(client, window_id):
        client._call("debug.command_palette.toggle", {"window_id": window_id})
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            message="command palette failed to close before setup",
        )

    client.open_command_palette_rename_tab_input(window_id=window_id)
    _wait_until(
        lambda: _palette_visible(client, window_id),
        message="command palette failed to open",
    )
    _wait_until(
        lambda: str(_palette_results(client, window_id).get("mode") or "") == "rename_input",
        message="command palette did not enter rename input mode",
    )


def main():
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)
        window_id = client.current_window()

        original_select_all = client.command_palette_rename_select_all()

        try:
            client.set_command_palette_rename_select_all(True)
            _open_rename_input(client, window_id)

            _wait_until(
                lambda: bool(_rename_selection(client, window_id).get("focused")),
                message="rename input did not focus",
            )

            selection = _rename_selection(client, window_id)
            text_length = _int_or(selection.get("text_length"), 0)
            selection_location = _int_or(selection.get("selection_location"), -1)
            selection_length = _int_or(selection.get("selection_length"), -1)
            if not (
                text_length > 0
                and selection_location in (-1, 0)
                and selection_length == text_length
            ):
                raise cmuxError(
                    "rename input was not select-all on open: "
                    f"text_length={text_length} selection=({selection_location}, {selection_length})"
                )

            client._call(
                "debug.command_palette.rename_input.delete_backward",
                {"window_id": window_id},
            )

            first_backspace_cleared = False
            last_selection = {}
            for _ in range(40):
                last_selection = _rename_selection(client, window_id)
                if _int_or(last_selection.get("text_length"), -1) == 0:
                    first_backspace_cleared = True
                    break
                time.sleep(0.05)
            if not first_backspace_cleared:
                raise cmuxError(
                    "first backspace did not clear rename input: "
                    f"selection={last_selection} results={_palette_results(client, window_id)}"
                )
            after_first = _palette_results(client, window_id)
            if str(after_first.get("mode") or "") != "rename_input":
                raise cmuxError(f"palette exited rename mode too early after first backspace: {after_first}")

            client._call(
                "debug.command_palette.rename_input.delete_backward",
                {"window_id": window_id},
            )

            _wait_until(
                lambda: str(_palette_results(client, window_id).get("mode") or "") == "commands",
                message="second backspace on empty input did not return to commands mode",
            )

            if not _palette_visible(client, window_id):
                raise cmuxError("palette closed unexpectedly instead of navigating back to command list")

        finally:
            try:
                client.set_command_palette_rename_select_all(original_select_all)
            except Exception:
                pass

            if _palette_visible(client, window_id):
                client._call("debug.command_palette.toggle", {"window_id": window_id})
                _wait_until(
                    lambda: not _palette_visible(client, window_id),
                    message="command palette failed to close during cleanup",
                )

    print("PASS: backspace on empty rename input navigates back to command list")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
