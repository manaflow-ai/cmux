#!/usr/bin/env python3
"""
Regression test: command-palette rename input keeps select-all on interaction.

Coverage:
- With select-all setting enabled, rename input selects all existing text
  immediately and stays selected after interaction.
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


def _rename_input_selection(client, window_id):
    return client._call("debug.command_palette.rename_input.selection", {"window_id": window_id}) or {}


def _rename_select_all_setting(client):
    payload = client._call("debug.command_palette.rename_input.select_all", {}) or {}
    return bool(payload.get("enabled"))


def _set_rename_select_all_setting(client, enabled):
    payload = client._call(
        "debug.command_palette.rename_input.select_all",
        {"enabled": bool(enabled)},
    ) or {}
    return bool(payload.get("enabled"))


def _wait_for_rename_selection(
    client,
    window_id,
    expect_select_all,
    message,
    timeout_s=0.6,
):
    def _matches():
        selection = _rename_input_selection(client, window_id)
        if not selection.get("focused"):
            return False
        text_length = int(selection.get("text_length") or 0)
        selection_location = int(selection.get("selection_location") or 0)
        selection_length = int(selection.get("selection_length") or 0)
        if expect_select_all:
            return text_length > 0 and selection_location == 0 and selection_length == text_length
        return selection_location == text_length and selection_length == 0

    _wait_until(_matches, timeout_s=timeout_s, message=message)


def _exercise_rename_selection_setting(
    client,
    window_id,
    expect_select_all,
    cycles,
    label,
):
    for cycle in range(cycles):
        _open_rename_tab_input(client, window_id)
        _wait_for_rename_selection(
            client,
            window_id,
            expect_select_all=expect_select_all,
            timeout_s=0.4,
            message=(
                f"{label}: rename input not ready with expected selection "
                f"on open (cycle {cycle + 1}/{cycles})"
            ),
        )
        client._call("debug.command_palette.rename_input.interact", {"window_id": window_id})
        _wait_for_rename_selection(
            client,
            window_id,
            expect_select_all=expect_select_all,
            timeout_s=0.6,
            message=(
                f"{label}: rename input selection changed after interaction "
                f"(cycle {cycle + 1}/{cycles})"
            ),
        )

        if _palette_visible(client, window_id):
            client._call("debug.command_palette.toggle", {"window_id": window_id})
            _wait_until(
                lambda: not _palette_visible(client, window_id),
                message=f"{label}: command palette failed to close (cycle {cycle + 1}/{cycles})",
            )


def _open_rename_tab_input(client, window_id):
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
        message="command palette failed to open rename-tab input",
    )


def main():
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)

        original_select_all = _rename_select_all_setting(client)

        workspace_id = client.new_workspace()
        client.select_workspace(workspace_id)
        client.rename_workspace("SeedName", workspace_id)
        time.sleep(0.25)
        window_id = client.current_window()

        try:
            stress_cycles = 8

            # ON: immediate select-all and interaction-preserved select-all.
            _set_rename_select_all_setting(client, True)
            _exercise_rename_selection_setting(
                client,
                window_id,
                expect_select_all=True,
                cycles=stress_cycles,
                label="select-all enabled",
            )

            # OFF: immediate caret-at-end and interaction-preserved caret-at-end.
            _set_rename_select_all_setting(client, False)
            _exercise_rename_selection_setting(
                client,
                window_id,
                expect_select_all=False,
                cycles=stress_cycles,
                label="select-all disabled",
            )

        finally:
            try:
                _set_rename_select_all_setting(client, original_select_all)
            except Exception:
                pass
            if _palette_visible(client, window_id):
                client._call("debug.command_palette.toggle", {"window_id": window_id})
                _wait_until(
                    lambda: not _palette_visible(client, window_id),
                    message="command palette failed to close during cleanup",
                )

    print("PASS: command-palette rename input obeys select-all setting (on/off)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
