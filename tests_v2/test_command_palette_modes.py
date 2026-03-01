#!/usr/bin/env python3
"""
Regression test: VSCode-like command palette modes.

Validates:
- Cmd+Shift+P opens commands mode (leading '>' semantics).
- Cmd+P opens workspace/tab switcher mode.
- Repeating Cmd+Shift+P or Cmd+P toggles visibility (open/close).
- Switcher search can jump to another workspace by pressing Enter.
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


def _wait_for_palette_input_caret_at_end(
    client: cmux,
    window_id: str,
    expected_text_length: int,
    message: str,
    timeout_s: float = 1.2,
) -> None:
    def _matches() -> bool:
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


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        timeout_s=3.0,
        message=f"palette visibility did not become {visible}",
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

        ws_a = client.new_workspace(window_id=window_id)
        client.select_workspace(ws_a)
        client.rename_workspace("alpha-workspace", workspace=ws_a)

        ws_b = client.new_workspace(window_id=window_id)
        client.select_workspace(ws_b)
        client.rename_workspace("bravo-workspace", workspace=ws_b)

        client.select_workspace(ws_a)
        _wait_until(
            lambda: client.current_workspace() == ws_a,
            message="failed to select workspace alpha before switcher jump",
        )

        _set_palette_visible(client, window_id, False)

        # Cmd+P: switcher mode.
        client.simulate_shortcut("cmd+p")
        _wait_until(
            lambda: _palette_visible(client, window_id),
            message="cmd+p did not open command palette",
        )
        _wait_until(
            lambda: str(_palette_results(client, window_id).get("mode") or "") == "switcher",
            message="cmd+p did not open switcher mode",
        )

        time.sleep(0.2)
        client.simulate_type("bravo")
        _wait_until(
            lambda: "bravo" in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="switcher query did not include bravo",
        )
        switched_rows = (_palette_results(client, window_id, limit=12).get("results") or [])
        if not switched_rows:
            raise cmuxError("switcher returned no rows for workspace query")
        top_id = str((switched_rows[0] or {}).get("command_id") or "")
        if not top_id.startswith("switcher."):
            raise cmuxError(f"expected switcher row on top for cmd+p query, got: {switched_rows[0]}")

        client.simulate_shortcut("enter")
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            message="palette did not close after selecting switcher row",
        )
        _wait_until(
            lambda: client.current_workspace() == ws_b,
            message="Enter on switcher result did not move to target workspace",
        )

        # Cmd+Shift+P: commands mode.
        client.simulate_shortcut("cmd+shift+p")
        _wait_until(
            lambda: _palette_visible(client, window_id),
            message="cmd+shift+p did not open command palette",
        )
        _wait_until(
            lambda: str(_palette_results(client, window_id).get("mode") or "") == "commands",
            message="cmd+shift+p did not open commands mode",
        )
        _wait_for_palette_input_caret_at_end(
            client,
            window_id,
            expected_text_length=1,
            message="cmd+shift+p should prefill '>' with caret at end (not selected)",
        )

        command_rows = (_palette_results(client, window_id, limit=8).get("results") or [])
        if not command_rows:
            raise cmuxError("commands mode returned no rows")
        top_command_id = str((command_rows[0] or {}).get("command_id") or "")
        if not top_command_id.startswith("palette."):
            raise cmuxError(f"expected command row in commands mode, got: {command_rows[0]}")

        # Repeating either shortcut should toggle visibility.
        client.simulate_shortcut("cmd+shift+p")
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            message="second cmd+shift+p did not close the command palette",
        )

        client.simulate_shortcut("cmd+p")
        _wait_until(
            lambda: _palette_visible(client, window_id)
            and str(_palette_results(client, window_id).get("mode") or "") == "switcher",
            message="cmd+p did not reopen switcher mode after toggle-close",
        )
        client.simulate_shortcut("cmd+p")
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            message="second cmd+p did not close the command palette",
        )

    print("PASS: command palette cmd+p/cmd+shift+p open correct modes and toggle on repeat")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
