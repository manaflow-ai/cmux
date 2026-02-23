#!/usr/bin/env python3
"""
Regression test: browser-focused workspace handoff must not use timeout fallback.

Issue #349:
- Switching to a workspace whose focused panel is a browser could complete handoff
  via the 150ms timeout path, causing visible delay/flash artifacts.
- Expected behavior is immediate handoff, matching non-delayed paths.
"""

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _debug_log_path() -> Path:
    marker = Path("/tmp/cmux-last-debug-log-path")
    if marker.exists():
        try:
            candidate = marker.read_text(encoding="utf-8").strip()
            if candidate:
                return Path(candidate)
        except OSError:
            pass
    return Path("/tmp/cmux-debug.log")


def _read_log_tail(log_path: Path, offset: int) -> str:
    try:
        with log_path.open("r", encoding="utf-8", errors="replace") as handle:
            handle.seek(offset)
            return handle.read()
    except FileNotFoundError:
        return ""


def _timestamp_ms(line: str) -> float | None:
    match = re.match(r"^(\d{2}):(\d{2}):(\d{2})\.(\d{3})", line)
    if not match:
        return None
    hour, minute, second, millis = (int(part) for part in match.groups())
    return (((hour * 60) + minute) * 60 + second) * 1000 + millis


def _extract_target_handoffs(log_text: str, target_workspace_id: str) -> list[tuple[str | None, float | None]]:
    target_short = target_workspace_id[:5]
    handoffs: list[tuple[str | None, float | None]] = []
    waiting_for_completion = False
    start_ts_ms: float | None = None

    for line in log_text.splitlines():
        if "ws.handoff.start" in line:
            if waiting_for_completion:
                handoffs.append((None, None))
            waiting_for_completion = f"new={target_short}" in line
            start_ts_ms = _timestamp_ms(line) if waiting_for_completion else None
            continue

        if waiting_for_completion and "ws.handoff.complete" in line:
            match = re.search(r"reason=([a-z_]+)", line)
            reason = match.group(1) if match else ""
            end_ts_ms = _timestamp_ms(line)
            dt_ms: float | None = None
            if start_ts_ms is not None and end_ts_ms is not None:
                dt_ms = end_ts_ms - start_ts_ms
                if dt_ms < 0:
                    dt_ms += 24 * 60 * 60 * 1000
            handoffs.append((reason, dt_ms))
            waiting_for_completion = False
            start_ts_ms = None

    if waiting_for_completion:
        handoffs.append((None, None))

    return handoffs


def _safe_close_workspace(client: cmux, workspace_id: str) -> None:
    try:
        client.close_workspace(workspace_id)
    except cmuxError:
        pass


def _safe_close_surface(client: cmux, surface: str) -> None:
    try:
        client.close_surface(surface)
    except cmuxError:
        pass


def test_browser_workspace_handoff_avoids_timeout(client: cmux) -> None:
    """
    Switch away from and back to a browser-focused workspace, then verify those
    handoffs do not use timeout fallback and complete quickly.
    """
    log_path = _debug_log_path()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    if not log_path.exists():
        log_path.touch()

    ws_a = client.new_workspace()
    time.sleep(0.3)
    ws_b = client.new_workspace()
    time.sleep(0.3)

    try:
        browser_panel_id = client.new_surface(panel_type="browser", url="about:blank")
        time.sleep(0.7)

        # Remove extra surfaces so switching back cannot complete via terminal focus callbacks.
        for _, surface_id, _ in client.list_surfaces():
            if surface_id != browser_panel_id:
                _safe_close_surface(client, surface_id)
                time.sleep(0.2)

        # Ensure workspace focus state is pinned to the browser panel (not just AppKit first responder).
        client.focus_surface(browser_panel_id)
        time.sleep(0.2)
        client.focus_webview(browser_panel_id)
        time.sleep(0.35)
        if not client.is_webview_focused(browser_panel_id):
            raise cmuxError("Expected browser panel to be focused before switch")

        # Capture only the handoff lines for this specific switch cycle.
        start_offset = log_path.stat().st_size if log_path.exists() else 0

        for _ in range(2):
            client.select_workspace(ws_a)
            time.sleep(0.35)
            client.select_workspace(ws_b)
            time.sleep(0.45)

        deadline = time.time() + 4.0
        raw_tail = ""
        handoffs: list[tuple[str | None, float | None]] = []

        while time.time() < deadline:
            raw_tail = _read_log_tail(log_path, start_offset)
            parsed = _extract_target_handoffs(raw_tail, ws_b)
            handoffs = [entry for entry in parsed if entry[0] is not None]
            if handoffs:
                break
            time.sleep(0.1)

        if not handoffs:
            raise cmuxError(
                "No ws.handoff.complete observed for browser-target workspace switch"
            )

        timeout_handoffs = [entry for entry in handoffs if entry[0] == "timeout"]
        slow_handoffs = [
            entry
            for entry in handoffs
            if entry[1] is not None and entry[1] > 120.0
        ]
        if timeout_handoffs or slow_handoffs:
            handoff_lines = "\n".join(
                line for line in raw_tail.splitlines() if "ws.handoff." in line
            )
            raise cmuxError(
                "Browser-target workspace handoff regressed: "
                f"handoffs={handoffs} timeout={timeout_handoffs} slow={slow_handoffs}\n"
                f"{handoff_lines}"
            )
    finally:
        _safe_close_workspace(client, ws_b)
        time.sleep(0.2)
        _safe_close_workspace(client, ws_a)
        time.sleep(0.2)


def main() -> int:
    print("=" * 60)
    print("Browser Workspace Handoff Regression (v2)")
    print("=" * 60)

    with cmux() as client:
        client.activate_app()
        time.sleep(0.2)
        test_browser_workspace_handoff_avoids_timeout(client)

    print("PASS: browser-focused workspace handoff avoids timeout fallback")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
