#!/usr/bin/env python3
"""
Regression test: command palette focus must remain stable while a new workspace shell spawns.

Why: when a terminal steals first responder during workspace bootstrap, the command-palette
search field can re-focus with full selection, so the next keystroke replaces the whole query.
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
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _palette_results(client: cmux, window_id: str, limit: int = 20) -> dict:
    return client.command_palette_results(window_id=window_id, limit=limit)


def _palette_input_selection(client: cmux, window_id: str) -> dict:
    return client._call("debug.command_palette.rename_input.selection", {"window_id": window_id}) or {}


def _close_palette_if_open(client: cmux, window_id: str) -> None:
    if _palette_visible(client, window_id):
        client._call("debug.command_palette.toggle", {"window_id": window_id})
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            message="command palette failed to close",
        )


def _assert_caret_at_end(selection: dict, context: str) -> None:
    if not selection.get("focused"):
        raise cmuxError(f"{context}: palette input is not focused")
    text_length = int(selection.get("text_length") or 0)
    selection_location = int(selection.get("selection_location") or 0)
    selection_length = int(selection.get("selection_length") or 0)
    if selection_location != text_length or selection_length != 0:
        raise cmuxError(
            f"{context}: expected caret-at-end, got location={selection_location}, "
            f"length={selection_length}, text_length={text_length}"
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

        _close_palette_if_open(client, window_id)
        workspace_count_before = len(client.list_workspaces(window_id=window_id))

        client.simulate_shortcut("cmd+shift+p")
        _wait_until(
            lambda: _palette_visible(client, window_id),
            message="cmd+shift+p did not open command palette",
        )
        _wait_until(
            lambda: str(_palette_results(client, window_id).get("mode") or "") == "commands",
            message="palette did not open in commands mode",
        )

        selection = _palette_input_selection(client, window_id)
        _assert_caret_at_end(selection, "initial state")

        client.new_workspace(window_id=window_id)
        _wait_until(
            lambda: len(client.list_workspaces(window_id=window_id)) >= workspace_count_before + 1,
            message="workspace.create did not add a new workspace",
        )

        # Sample across shell bootstrap; focus and caret should stay stable.
        sample_deadline = time.time() + 2.0
        while time.time() < sample_deadline:
            selection = _palette_input_selection(client, window_id)
            _assert_caret_at_end(selection, "after workspace spawn")
            time.sleep(0.01)

        client.simulate_type("focuslock")
        _wait_until(
            lambda: str(_palette_results(client, window_id).get("mode") or "") == "commands",
            message="typing after workspace spawn switched palette out of commands mode",
        )
        _wait_until(
            lambda: "focuslock" in str(_palette_results(client, window_id).get("query") or "").lower(),
            message="typing after workspace spawn did not append into command query",
        )

    print("PASS: command palette keeps focus/caret during workspace shell spawn")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
