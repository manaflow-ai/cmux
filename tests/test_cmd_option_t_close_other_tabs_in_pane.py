#!/usr/bin/env python3
"""
Regression test: Cmd+Option+T closes all other tabs in the focused pane
after an explicit confirmation.

Run this against an app launched with CMUX_SOCKET_MODE=allowAll.
"""

import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_until(predicate, timeout_s: float = 5.0, interval_s: float = 0.05) -> bool:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def _pane_state(client: cmux) -> list[dict]:
    rows: list[dict] = []
    for index, panel_id, title, selected in client.list_pane_surfaces():
        rows.append(
            {
                "index": index,
                "panel_id": panel_id,
                "title": title,
                "selected": selected,
            }
        )
    return rows


def _send_shortcut_via_system_events(key: str, modifiers: str) -> None:
    script = f'tell application "System Events" to keystroke "{key}" using {{{modifiers}}}'
    try:
        subprocess.run(["osascript", "-e", script], check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        raise cmuxError(
            "Failed to send keyboard shortcut via System Events. "
            f"Ensure macOS Accessibility automation is enabled. stderr={stderr}"
        ) from exc


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        if not client.ping():
            raise cmuxError(
                f"Socket ping failed on {SOCKET_PATH}. "
                "Launch Debug app with CMUX_SOCKET_MODE=allowAll for this test."
            )

        workspace_id = client.new_workspace()
        try:
            client.select_workspace(workspace_id)
            time.sleep(0.25)
            client.activate_app()
            time.sleep(0.15)

            # Create two additional tabs in the current focused pane.
            client.new_surface()
            client.new_surface()
            time.sleep(0.25)

            before = _pane_state(client)
            if len(before) < 3:
                raise cmuxError(f"Expected >=3 tabs before shortcut, got {before}")

            selected_rows = [row for row in before if row["selected"]]
            if len(selected_rows) != 1:
                raise cmuxError(f"Expected exactly one selected tab before shortcut, got {before}")
            selected_panel_id = selected_rows[0]["panel_id"]

            expected_to_close = [row for row in before if row["panel_id"] != selected_panel_id]
            if len(expected_to_close) < 2:
                raise cmuxError(
                    f"Expected at least two non-selected tabs before shortcut, got {before}"
                )

            # Trigger shortcut via real OS key event; this should open the confirmation dialog.
            _send_shortcut_via_system_events("t", "command down, option down")
            time.sleep(0.25)
            after_trigger = _pane_state(client)
            if len(after_trigger) != len(before):
                raise cmuxError(
                    "Cmd+Option+T should require confirmation before closing.\n"
                    f"before={before}\n"
                    f"after_trigger={after_trigger}"
                )

            # Confirm the dialog with Cmd+D (wired to click the destructive "Close" button).
            _send_shortcut_via_system_events("d", "command down")
            closed = _wait_until(lambda: len(_pane_state(client)) == 1, timeout_s=5.0, interval_s=0.05)
            if not closed:
                raise cmuxError(
                    "Timed out waiting for tabs to close after confirming Cmd+Option+T.\n"
                    f"before={before}\n"
                    f"after_trigger={after_trigger}\n"
                    f"after_confirm={_pane_state(client)}"
                )

            after_confirm = _pane_state(client)
            if len(after_confirm) != 1:
                raise cmuxError(
                    f"Expected one remaining tab after confirmation, got {after_confirm}"
                )
            remaining = after_confirm[0]
            if remaining["panel_id"] != selected_panel_id:
                raise cmuxError(
                    "Expected selected tab to remain after closing others.\n"
                    f"expected_selected={selected_panel_id}\n"
                    f"remaining={remaining}\n"
                    f"before={before}"
                )

            print("PASS: Cmd+Option+T closed all other tabs in focused pane.")
            print(f"workspace={workspace_id}")
            print(f"selected_panel={selected_panel_id}")
            return 0
        finally:
            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
