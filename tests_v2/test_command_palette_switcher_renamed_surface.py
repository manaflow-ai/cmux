#!/usr/bin/env python3
"""
Regression test: cmd+p switcher should search and navigate to renamed surfaces.
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


def _rename_surface(client: cmux, surface_id: str, title: str) -> None:
    client._call(
        "surface.action",
        {
            "surface_id": surface_id,
            "action": "rename",
            "title": title,
        },
    )


def _current_surface_id(client: cmux, workspace_id: str) -> str:
    payload = client._call("surface.current", {"workspace_id": workspace_id}) or {}
    return str(payload.get("surface_id") or "")


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

        token = f"renamed-surface-{int(time.time() * 1000)}"
        _rename_surface(client, right_surface_id, token)
        time.sleep(0.2)

        client.focus_surface(left_surface_id)
        time.sleep(0.2)

        _open_switcher(client, window_id)
        client.simulate_type(token)
        _wait_until(
            lambda: token in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="switcher query did not update to renamed surface token",
        )

        result_rows = (_palette_results(client, window_id, limit=24).get("results") or [])
        if not result_rows:
            raise cmuxError("switcher returned no rows for renamed surface query")

        top_row = result_rows[0] or {}
        top_id = str(top_row.get("command_id") or "")
        top_title = str(top_row.get("title") or "")
        if not top_id.startswith("switcher.surface."):
            raise cmuxError(
                f"expected renamed surface row on top, got top={top_id!r} rows={result_rows}"
            )
        if top_title != token:
            raise cmuxError(
                f"expected top surface row title to match renamed title {token!r}, got {top_title!r}"
            )

        client.simulate_shortcut("enter")
        _wait_until(
            lambda: not _palette_visible(client, window_id),
            message="palette did not close after selecting renamed surface row",
        )

        _wait_until(
            lambda: _current_surface_id(client, workspace_id).lower() == right_surface_id.lower(),
            message="Enter on renamed surface switcher row did not focus target surface",
        )

        client.close_workspace(workspace_id)

    print("PASS: cmd+p switcher searches and navigates renamed surfaces")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
