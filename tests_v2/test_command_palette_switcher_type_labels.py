#!/usr/bin/env python3
"""
Regression test: cmd+p switcher rows expose right-side type labels.

Expected trailing labels:
- switcher.workspace.* => Workspace
- switcher.surface.* => Surface
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


def _palette_results(client: cmux, window_id: str, limit: int = 20) -> dict:
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
        token = f"switchertype{int(time.time() * 1000)}"
        client.rename_workspace(token, workspace=workspace_id)
        _ = client.new_split("right")
        time.sleep(0.3)

        _open_switcher(client, window_id)
        client.simulate_type(token)
        _wait_until(
            lambda: token in str(_palette_results(client, window_id, limit=60).get("query") or "").strip().lower(),
            message="switcher query did not update to workspace token",
        )

        rows = (_palette_results(client, window_id, limit=60).get("results") or [])
        if not rows:
            raise cmuxError("switcher returned no rows for token query")

        workspace_rows = [
            row for row in rows
            if str((row or {}).get("command_id") or "").startswith("switcher.workspace.")
        ]
        surface_rows = [
            row for row in rows
            if str((row or {}).get("command_id") or "").startswith("switcher.surface.")
        ]

        if not workspace_rows:
            raise cmuxError(f"expected workspace rows for switcher query: rows={rows}")
        if not surface_rows:
            raise cmuxError(f"expected surface rows for switcher query: rows={rows}")

        bad_workspace = [row for row in workspace_rows if str((row or {}).get("trailing_label") or "") != "Workspace"]
        if bad_workspace:
            raise cmuxError(f"workspace rows missing 'Workspace' trailing label: {bad_workspace}")

        bad_surface = [row for row in surface_rows if str((row or {}).get("trailing_label") or "") != "Surface"]
        if bad_surface:
            raise cmuxError(f"surface rows missing 'Surface' trailing label: {bad_surface}")

        _set_palette_visible(client, window_id, False)
        client.close_workspace(workspace_id)

    print("PASS: cmd+p switcher rows report Workspace/Surface trailing labels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
