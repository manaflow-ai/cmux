from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_SHORTCUTS = {
    "newSurface": "cmd+t",
    "openBrowser": "cmd+shift+l",
    "splitRight": "cmd+d",
    "splitDown": "cmd+shift+d",
    "closeTab": "cmd+w",
    "nextSurface": "ctrl+tab",
    "previousSurface": "ctrl+shift+tab",
    "nextSidebarTab": "cmd+ctrl+]",
    "previousSidebarTab": "cmd+ctrl+[",
    "focusBrowserAddressBar": "cmd+l",
    "browserBack": "cmd+[",
    "browserForward": "cmd+]",
    "browserReload": "cmd+r",
    "commandPalette": "cmd+shift+p",
    "openSettings": "cmd+,",
}
SHORTCUT_SETTING_KEYS = ("keyboardShortcuts", "shortcuts")
SHORTCUT_MODIFIER_ORDER = ("cmd", "ctrl", "alt", "shift")
SHORTCUT_ACTION_ALIASES = {
    "newtab": "newSurface",
    "newterminal": "newSurface",
    "openbrowser": "openBrowser",
    "splitright": "splitRight",
    "splithorizontally": "splitRight",
    "splitdown": "splitDown",
    "splitvertically": "splitDown",
    "closetab": "closeTab",
    "closepane": "closeTab",
    "nexttab": "nextSurface",
    "previoustab": "previousSurface",
    "prevtab": "previousSurface",
    "nextsurfacetab": "nextSurface",
    "previoussurfacetab": "previousSurface",
    "focusaddressbar": "focusBrowserAddressBar",
    "browserfocusaddressbar": "focusBrowserAddressBar",
    "reloadbrowser": "browserReload",
    "commandpalette": "commandPalette",
    "opensettings": "openSettings",
    "settingsopen": "openSettings",
    "openpreferences": "openSettings",
    "preferences": "openSettings",
}
KEY_NAME_ALIASES = {
    "bracketleft": "[",
    "braceleft": "[",
    "bracketright": "]",
    "braceright": "]",
    "slash": "/",
    "backslash": "\\",
    "minus": "-",
    "equal": "=",
    "plus": "=",
    "period": ".",
    "comma": ",",
    "semicolon": ";",
    "apostrophe": "'",
    "quoteleft": "`",
    "grave": "`",
    "space": "space",
    "return": "enter",
    "kp_enter": "enter",
    "escape": "esc",
    "iso_left_tab": "tab",
}


@dataclass(frozen=True)
class ShortcutBinding:
    action: str
    token: str
    display: str

    def to_json(self) -> dict[str, str]:
        return {"action": self.action, "shortcut": self.display, "token": self.token}


def default_settings_path() -> Path:
    explicit = os.environ.get("CMUX_SETTINGS_PATH")
    if explicit:
        return Path(explicit).expanduser()

    config_home = os.environ.get("XDG_CONFIG_HOME")
    base_dir = Path(config_home).expanduser() if config_home else Path.home() / ".config"
    return base_dir / "cmux" / "settings.json"


def load_settings(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            loaded = json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, json.JSONDecodeError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def build_shortcut_bindings(settings: dict[str, Any]) -> dict[str, ShortcutBinding]:
    configured = _shortcut_config_from_settings(settings)
    merged = {**DEFAULT_SHORTCUTS, **configured}
    for index in range(1, 10):
        merged.setdefault(f"selectSurface{index}", f"cmd+{index}")
        merged.setdefault(f"selectWorkspace{index}", f"cmd+ctrl+{index}")
    bindings = {}
    for action, shortcut in merged.items():
        canonical_action = normalize_shortcut_action(action)
        token = shortcut_token_from_text(str(shortcut))
        if not canonical_action or not token:
            continue
        bindings[canonical_action] = ShortcutBinding(canonical_action, token, str(shortcut))
    return bindings


def shortcut_token_from_text(value: str) -> str:
    parts = [part.strip().lower() for part in value.replace(" ", "").split("+") if part.strip()]
    if not parts:
        return ""
    modifiers = {_normalize_shortcut_modifier(part) for part in parts[:-1]}
    modifiers.discard("")
    key = normalize_key_name(parts[-1])
    if not key:
        return ""
    ordered = [modifier for modifier in SHORTCUT_MODIFIER_ORDER if modifier in modifiers]
    return "+".join([*ordered, key])


def normalize_key_name(value: str) -> str:
    key = value.strip().lower()
    if len(key) == 1:
        return key
    return KEY_NAME_ALIASES.get(key, key)


def normalize_shortcut_action(action: Any) -> str:
    raw = str(action or "").replace("-", "").replace("_", "").replace(".", "").lower()
    return SHORTCUT_ACTION_ALIASES.get(raw, str(action or ""))


def _shortcut_config_from_settings(settings: dict[str, Any]) -> dict[str, str]:
    for key in SHORTCUT_SETTING_KEYS:
        value = settings.get(key)
        if isinstance(value, dict):
            return _shortcut_config_from_mapping(value)
    return {}


def _shortcut_config_from_mapping(value: dict[str, Any]) -> dict[str, str]:
    shortcuts = {}
    for action, shortcut in value.items():
        if isinstance(shortcut, str):
            shortcuts[str(action)] = shortcut
        elif isinstance(shortcut, dict):
            nested = shortcut.get("shortcut") or shortcut.get("key") or shortcut.get("binding")
            if isinstance(nested, str):
                shortcuts[str(action)] = nested
    return shortcuts


def _normalize_shortcut_modifier(value: str) -> str:
    modifier = value.strip().lower()
    if modifier in {"cmd", "command", "meta", "super", "win", "windows"}:
        return "cmd"
    if modifier in {"control", "ctrl", "ctl"}:
        return "ctrl"
    if modifier in {"option", "opt", "alt", "mod1"}:
        return "alt"
    if modifier == "shift":
        return "shift"
    return ""
