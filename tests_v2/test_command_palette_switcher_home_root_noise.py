#!/usr/bin/env python3
"""
Regression test: switcher workspace rows should not match home-root path noise.

Why: indexing canonical paths (`/Users/<name>/...`) made generic queries like
`use` or `users` match most switcher rows even when titles did not match.
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


def _home_root_query_token() -> str:
    parts = [part for part in Path.home().parts if part not in ("/", "")]
    token = parts[-2].lower() if len(parts) >= 2 else (parts[0].lower() if parts else "users")
    if len(token) < 4:
        return "users"
    return token


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
        token = f"switcher-noise-{int(time.time() * 1000)}"
        client.rename_workspace(token, workspace=workspace_id)
        time.sleep(0.2)

        _open_switcher(client, window_id)

        client.simulate_type(token)
        _wait_until(
            lambda: token in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="switcher query did not update to workspace token",
        )

        workspace_command_id = f"switcher.workspace.{workspace_id.lower()}"
        baseline_rows = (_palette_results(client, window_id, limit=80).get("results") or [])
        baseline_ids = [str((row or {}).get("command_id") or "") for row in baseline_rows]
        if workspace_command_id not in baseline_ids:
            raise cmuxError(
                "setup failed: workspace row missing for workspace-token query; "
                f"expected={workspace_command_id!r} rows={baseline_rows}"
            )

        noise_query = f"{_home_root_query_token()} {token}"
        client.simulate_shortcut("cmd+a")
        client.simulate_type(noise_query)
        _wait_until(
            lambda: noise_query in str(_palette_results(client, window_id).get("query") or "").strip().lower(),
            message="switcher query did not update to home-root-noise query",
        )

        rows = (_palette_results(client, window_id, limit=80).get("results") or [])
        matched_ids = [str((row or {}).get("command_id") or "") for row in rows]
        if workspace_command_id in matched_ids:
            raise cmuxError(
                "workspace row should not match home-root noise token combined with workspace token; "
                f"query={noise_query!r} unexpected={workspace_command_id!r} rows={rows}"
            )

        _set_palette_visible(client, window_id, False)
        client.close_workspace(workspace_id)

    print("PASS: switcher ignores home-root path noise for workspace search matching")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
