#!/usr/bin/env python3
"""
Regression test: switcher cache refreshes while palette is open.

Why: switcher entries are cached for performance, but workspace/surface metadata
can change while Cmd+P is already open (rename, title update, cwd/branch update).
Typing a query after such a change should search fresh entries, not stale cache.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_until(predicate, timeout_s: float = 6.0, interval_s: float = 0.05, message: str = "timeout") -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _palette_visible(client: cmux, window_id: str) -> bool:
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _palette_results(client: cmux, window_id: str, limit: int = 40) -> dict:
    return client.command_palette_results(window_id=window_id, limit=limit)


def _set_palette_visible(client: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(client, window_id) == visible:
        return
    client._call("debug.command_palette.toggle", {"window_id": window_id})
    _wait_until(
        lambda: _palette_visible(client, window_id) == visible,
        message=f"palette visibility did not become {visible}",
    )


def _open_switcher(client: cmux, window_id: str) -> None:
    _set_palette_visible(client, window_id, False)
    client.simulate_shortcut("cmd+p")
    _wait_until(
        lambda: _palette_visible(client, window_id),
        message="cmd+p did not open switcher",
    )
    _wait_until(
        lambda: str(_palette_results(client, window_id).get("mode") or "") == "switcher",
        message="cmd+p did not open switcher mode",
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
        client.rename_workspace("switcher-cache-seed", workspace=workspace_id)
        time.sleep(0.2)

        _open_switcher(client, window_id)

        token = f"cmdp-refresh-{int(time.time() * 1000)}"
        renamed_title = f"Email Template {token}"
        client.rename_workspace(renamed_title, workspace=workspace_id)
        time.sleep(0.2)

        client.simulate_shortcut("cmd+a")
        client.simulate_type(token)
        _wait_until(
            lambda: token in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="switcher query did not update to rename token",
        )

        rows = (_palette_results(client, window_id, limit=60).get("results") or [])
        if not rows:
            raise cmuxError(f"switcher returned no rows after workspace rename while open: token={token!r}")

        expected_workspace_command = f"switcher.workspace.{workspace_id.lower()}"
        matching_ids = [str((row or {}).get("command_id") or "") for row in rows]
        if expected_workspace_command not in matching_ids:
            raise cmuxError(
                "switcher did not refresh cached entries after workspace rename while open; "
                f"expected={expected_workspace_command!r} token={token!r} rows={rows}"
            )

        _set_palette_visible(client, window_id, False)
        client.close_workspace(workspace_id)

    print("PASS: switcher refreshes cached entries when workspace title changes while palette is open")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
