#!/usr/bin/env python3
"""
Regression test: switcher should prioritize matching surfaces over workspace rows.

Why: workspace rows used to index metadata from all surfaces, so a path-token query
could rank the workspace row above the actual surface row (because of stable rank
tie-breaks), making Enter jump to workspace instead of the intended surface.
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
        client.rename_workspace("workspace-no-token", workspace=workspace_id)
        time.sleep(0.2)

        right_surface_id = client.new_split("right")
        time.sleep(0.2)

        payload = client._call("surface.list", {"workspace_id": workspace_id}) or {}
        rows = payload.get("surfaces") or []
        if len(rows) < 2:
            raise cmuxError(f"expected at least two surfaces after split: {payload}")

        left_surface_id = ""
        for row in rows:
            sid = str(row.get("id") or "")
            if sid and sid != right_surface_id:
                left_surface_id = sid
                break
        if not left_surface_id:
            raise cmuxError(f"failed to resolve left surface id: {payload}")

        token = f"cmdp-switcher-target-{int(time.time() * 1000)}"
        target_dir = f"/tmp/{token}"

        client.send_surface(left_surface_id, "cd /tmp\n")
        client.send_surface(
            right_surface_id,
            f"mkdir -p {target_dir} && cd {target_dir}\n",
        )
        client.focus_surface(left_surface_id)
        time.sleep(0.8)

        _open_switcher(client, window_id)
        client.simulate_type(token)
        _wait_until(
            lambda: token in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="switcher query did not update to target token",
        )

        def _has_surface_match() -> bool:
            result_rows = (_palette_results(client, window_id, limit=24).get("results") or [])
            return any(str((row or {}).get("command_id") or "").startswith("switcher.surface.") for row in result_rows)

        _wait_until(
            _has_surface_match,
            timeout_s=8.0,
            message="switcher results never produced a matching surface row for token query",
        )

        result_rows = (_palette_results(client, window_id, limit=24).get("results") or [])
        if not result_rows:
            raise cmuxError("switcher returned no rows for token query")

        top_id = str((result_rows[0] or {}).get("command_id") or "")
        if not top_id.startswith("switcher.surface."):
            raise cmuxError(f"expected a surface row on top for token query, got top={top_id!r} rows={result_rows}")

        workspace_matches = [
            str((row or {}).get("command_id") or "")
            for row in result_rows
            if str((row or {}).get("command_id") or "").startswith("switcher.workspace.")
        ]
        if workspace_matches:
            raise cmuxError(
                f"workspace row should not match a non-focused surface path token; workspace matches={workspace_matches} rows={result_rows}"
            )

        _set_palette_visible(client, window_id, False)
        client.close_workspace(workspace_id)

    print("PASS: switcher ranks matching surface rows ahead of workspace rows for path-token queries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
