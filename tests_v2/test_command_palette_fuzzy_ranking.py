#!/usr/bin/env python3
"""
Regression test: command palette fuzzy ranking for rename commands.

Validates:
- Typing `rename` is captured by the palette query.
- The top-ranked command is a rename command.
- Pressing Enter opens rename input (instead of running an unrelated command).
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
RENAME_COMMAND_IDS = {"palette.renameTab", "palette.renameWorkspace"}


def _wait_until(predicate, timeout_s=5.0, interval_s=0.05, message="timeout"):
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _palette_visible(client: cmux, window_id: str) -> bool:
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _rename_input_selection(client: cmux, window_id: str) -> dict:
    return client._call("debug.command_palette.rename_input.selection", {"window_id": window_id}) or {}


def _palette_results(client: cmux, window_id: str, limit: int = 10) -> dict:
    return client.command_palette_results(window_id=window_id, limit=limit)


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
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

        workspace_id = client.new_workspace(window_id=window_id)
        client.select_workspace(workspace_id)
        time.sleep(0.2)

        _set_palette_visible(client, window_id, False)
        _set_palette_visible(client, window_id, True)

        # Force command mode query regardless transient field-editor selection state.
        time.sleep(0.2)
        client.simulate_shortcut("cmd+a")
        client.simulate_type(">rename")
        _wait_until(
            lambda: "rename" in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="palette query did not update to 'rename'",
        )

        payload = _palette_results(client, window_id, limit=12)
        rows = payload.get("results") or []
        if not rows:
            raise cmuxError(f"palette returned no results for rename query: {payload}")

        top = rows[0] or {}
        top_id = str(top.get("command_id") or "")
        top_title = str(top.get("title") or "")
        if top_id not in RENAME_COMMAND_IDS:
            titles = [str(row.get("title") or "") for row in rows]
            raise cmuxError(
                f"unexpected top result for 'rename': id={top_id!r} title={top_title!r} results={titles}"
            )

        client.simulate_shortcut("cmd+a")
        client.simulate_type(">retab")
        _wait_until(
            lambda: "retab" in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="palette query did not update to 'retab'",
        )

        retab_payload = _palette_results(client, window_id, limit=12)
        retab_rows = retab_payload.get("results") or []
        if not retab_rows:
            raise cmuxError(f"palette returned no results for retab query: {retab_payload}")
        top_retabs = [str(row.get("command_id") or "") for row in retab_rows[:3]]
        if "palette.renameTab" not in top_retabs:
            raise cmuxError(
                f"'retab' did not rank Rename Tab near top: top3={top_retabs} rows={retab_rows}"
            )

        client.simulate_shortcut("enter")
        _wait_until(
            lambda: _palette_visible(client, window_id)
            and bool(_rename_input_selection(client, window_id).get("focused")),
            message="Enter did not open rename input for top rename result",
        )

        _set_palette_visible(client, window_id, False)

    print("PASS: command palette fuzzy ranking prioritizes rename commands")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
