from __future__ import annotations

import re
from typing import Any

MACOS_WORKSPACE_ACTIONS = (
    "pin",
    "unpin",
    "rename",
    "clear_name",
    "set_description",
    "clear_description",
    "move_up",
    "move_down",
    "move_top",
    "close_others",
    "close_above",
    "close_below",
    "mark_read",
    "mark_unread",
    "set_color",
    "clear_color",
)

LINUX_WORKSPACE_ACTION_ALIASES = (
    "select",
    "focus",
    "create",
    "new",
    "close",
    "reorder",
    "next",
    "previous",
    "prev",
    "last",
    "equalize_splits",
    "equalize",
)

SUPPORTED_WORKSPACE_ACTIONS = MACOS_WORKSPACE_ACTIONS + LINUX_WORKSPACE_ACTION_ALIASES

WORKSPACE_COLOR_NAMES = {
    "red": "#C0392B",
    "crimson": "#922B21",
    "orange": "#A04000",
    "amber": "#7D6608",
    "olive": "#4A5C18",
    "green": "#196F3D",
    "teal": "#006B6B",
    "aqua": "#0E6B8C",
    "blue": "#1565C0",
    "navy": "#1A5276",
    "indigo": "#283593",
    "purple": "#6A1B9A",
    "magenta": "#AD1457",
    "rose": "#880E4F",
    "brown": "#7B3F00",
    "charcoal": "#3E4B5E",
}

HEX_COLOR_PATTERN = re.compile(r"^#?([0-9a-fA-F]{6})$")


def normalize_workspace_action(value: Any) -> str:
    return str(value or "").strip().replace("-", "_").lower()


def normalize_workspace_description(value: Any) -> str | None:
    if value is None:
        return None
    normalized = str(value).replace("\r\n", "\n").replace("\r", "\n").strip()
    return normalized or None


def normalize_workspace_color(value: Any) -> str | None:
    if value is None:
        return None
    raw = str(value).strip()
    if not raw:
        return None
    named_color = WORKSPACE_COLOR_NAMES.get(raw.casefold())
    if named_color:
        return named_color
    match = HEX_COLOR_PATTERN.match(raw)
    if not match:
        return None
    return f"#{match.group(1).upper()}"
