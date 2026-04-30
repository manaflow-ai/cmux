from __future__ import annotations

from typing import Any


LINUX_TERMINAL_BACKEND = "vte"
UNSUPPORTED_ON_LINUX_BACKEND = "unsupported_on_linux_backend"
GHOSTTYKIT_PORT_SCANNER_DETAIL = "ghosttykit_port_scanner_unsupported_on_linux_backend"


def linux_terminal_renderer_capability() -> dict[str, Any]:
    return {
        "available": True,
        "backend": LINUX_TERMINAL_BACKEND,
        "mode": LINUX_TERMINAL_BACKEND,
        "detail": "vte_renderer_with_ghosttykit_unsupported_on_linux_backend",
        "ghostty": {
            "available": False,
            "reason": UNSUPPORTED_ON_LINUX_BACKEND,
            "detail": UNSUPPORTED_ON_LINUX_BACKEND,
        },
    }


def linux_port_scanner_capability() -> dict[str, Any]:
    return {
        "backend": LINUX_TERMINAL_BACKEND,
        "available": False,
        "mode": "unsupported",
        "reason": UNSUPPORTED_ON_LINUX_BACKEND,
        "detail": GHOSTTYKIT_PORT_SCANNER_DETAIL,
        "ports": [],
        "listening_ports": [],
        "detected_ports": [],
        "forwarded_ports": [],
        "conflicted_ports": [],
    }


def build_debug_terminal_item(
    *,
    window_id: str,
    window_ref: str,
    workspace_id: str,
    workspace_ref: str,
    workspace_index: int,
    workspace_title: str,
    surface_id: str,
    surface_ref: str,
    surface_index: int,
    surface_title: str,
    pane_id: str,
    pane_ref: str,
    pane_index: int,
    pane_title: str,
    current_directory: str | None,
    focused: bool,
    tty_name: str | None,
    pty_available: bool,
    item_index: int | None = None,
) -> dict[str, Any]:
    title = pane_title or surface_title
    return {
        "index": item_index if item_index is not None else surface_index,
        "mapped": True,
        "tree_visible": True,
        "window_id": window_id,
        "window_ref": window_ref,
        "window_index": 0,
        "workspace_id": workspace_id,
        "workspace_ref": workspace_ref,
        "workspace_index": workspace_index,
        "workspace_title": workspace_title,
        "workspace_selected": focused,
        "surface_id": surface_id,
        "surface_ref": surface_ref,
        "surface_index": surface_index,
        "surface_index_in_pane": surface_index,
        "surface_title": surface_title,
        "surface_focused": focused,
        "surface_selected_in_pane": focused,
        "surface_pinned": False,
        "pane_id": pane_id,
        "pane_ref": pane_ref,
        "pane_index": pane_index,
        "window_visible": True,
        "window_key": focused,
        "window_main": focused,
        "window_occluded": False,
        "window_number": None,
        "window_title": workspace_title,
        "window_class": "Gtk.ApplicationWindow",
        "window_delegate_class": None,
        "window_controller_class": None,
        "window_level": 0,
        "title": title,
        "hosted_view_class": "Vte.Terminal",
        "hosted_view_in_window": True,
        "hosted_view_has_superview": True,
        "hosted_view_hidden": False,
        "hosted_view_hidden_or_ancestor_hidden": False,
        "hosted_view_visible_in_ui": True,
        "terminal_object_ptr": "nil",
        "ghostty_surface_ptr": "nil",
        "cwd": current_directory,
        "current_directory": current_directory,
        "focused": focused,
        "tty": tty_name,
        "tty_name": tty_name,
        "pty_available": pty_available,
        "listening_ports": [],
        "detected_ports": [],
        "forwarded_ports": [],
        "conflicted_ports": [],
        "runtime_surface_ready": pty_available,
        "renderer": linux_terminal_renderer_capability(),
        "scanner": linux_port_scanner_capability(),
    }
