from __future__ import annotations

import shlex
from typing import Any


LEGACY_V1_METHODS = {
    "ping": "system.ping",
    "list_windows": "window.list",
    "current_window": "window.current",
    "new_window": "window.create",
    "focus_window": "window.focus",
    "close_window": "window.close",
}


def parse_legacy_v1_command(line: str) -> tuple[str, dict[str, Any]] | None:
    try:
        parts = shlex.split(line.strip())
    except ValueError:
        return None
    if not parts:
        return None

    command = parts[0].lower()
    method = LEGACY_V1_METHODS.get(command)
    if method is None:
        return None

    params: dict[str, Any] = {}
    if command in {"focus_window", "close_window"} and len(parts) > 1:
        window = parts[1]
        key = "window_ref" if window.startswith("window:") else "window_id"
        params[key] = window
    return method, params


def format_legacy_v1_response(command: str, ok: bool, payload: dict[str, Any]) -> str:
    if not ok:
        message = str(payload.get("message") or payload.get("code") or "Command failed.")
        return f"ERROR: {message}"

    normalized = command.strip().split(maxsplit=1)[0].lower() if command.strip() else ""
    if normalized == "ping":
        return "PONG"
    if normalized == "list_windows":
        return _format_window_list(payload)
    if normalized == "current_window":
        return _window_id(payload) or "ERROR: No active window"
    if normalized == "new_window":
        return f"OK {_window_id(payload)}".rstrip()
    if normalized in {"focus_window", "close_window"}:
        return "OK"
    return "OK"


def _format_window_list(payload: dict[str, Any]) -> str:
    windows = payload.get("windows")
    if not isinstance(windows, list) or not windows:
        return "No windows"

    lines: list[str] = []
    for fallback_index, item in enumerate(windows):
        if not isinstance(item, dict):
            continue
        index = item.get("index", fallback_index)
        window_id = _window_id(item)
        if not window_id:
            continue
        selected = "*" if bool(item.get("is_current") or item.get("key") is True) else " "
        selected_workspace = item.get("selected_workspace_id") or "none"
        workspace_count = item.get("workspace_count", 0)
        lines.append(
            f"{selected} {index}: {window_id} "
            f"selected_workspace={selected_workspace} workspaces={workspace_count}"
        )
    return "\n".join(lines) if lines else "No windows"


def _window_id(payload: dict[str, Any]) -> str | None:
    value = payload.get("window_id") or payload.get("id")
    if isinstance(value, str) and value:
        return value
    window = payload.get("window")
    if isinstance(window, dict):
        nested = window.get("window_id") or window.get("id")
        if isinstance(nested, str) and nested:
            return nested
    return None
