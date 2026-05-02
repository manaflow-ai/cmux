from __future__ import annotations

import argparse
import base64
import gettext
import html
import json
import os
import queue
import secrets
import signal
import socket
import stat
import subprocess
import tempfile
import threading
import time
import urllib.request
import uuid
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Callable

try:
    import gi
except ModuleNotFoundError:
    print(
        "cmux Linux requires PyGObject and GTK/VTE bindings.\n"
        "On Ubuntu/Debian, install them with:\n"
        "  sudo apt install python3 python3-gi gir1.2-gtk-4.0 gir1.2-vte-3.91\n"
        "or the GTK3 fallback packages:\n"
        "  sudo apt install python3 python3-gi gir1.2-gtk-3.0 gir1.2-vte-2.91",
        file=os.sys.stderr,
    )
    raise SystemExit(1)

GTK_MAJOR = 4
try:
    gi.require_version("Vte", "3.91")
    gi.require_version("Gtk", "4.0")
except (ImportError, ValueError):
    try:
        gi.require_version("Gtk", "3.0")
        gi.require_version("Vte", "2.91")
        GTK_MAJOR = 3
    except (ImportError, ValueError):
        print(
            "cmux Linux requires GTK/VTE introspection bindings.\n"
            "On Ubuntu/Debian, install them with:\n"
            "  sudo apt install python3 python3-gi gir1.2-gtk-4.0 gir1.2-vte-3.91\n"
            "or the GTK3 fallback packages:\n"
            "  sudo apt install python3 python3-gi gir1.2-gtk-3.0 gir1.2-vte-2.91",
            file=os.sys.stderr,
        )
        raise SystemExit(1)

from gi.repository import Gio, GLib, Gtk, Vte  # noqa: E402
from .browser import browser_backend_limit  # noqa: E402
from .shortcuts import (  # noqa: E402
    KEY_NAME_ALIASES,
    SHORTCUT_MODIFIER_ORDER,
    build_shortcut_bindings,
    default_settings_path,
    load_settings,
    normalize_key_name,
    shortcut_token_from_text,
)
from .socket_security import (  # noqa: E402
    bind_private_unix_socket,
    ensure_private_socket_directory,
)
from .capabilities import (  # noqa: E402
    REQUIRED_FAILURE_CODES,
    build_subsystem_capabilities,
)
from .auth import (  # noqa: E402
    build_auth_bridge_invocation,
    build_local_auth_status_payload,
    find_auth_bridge_binary,
    normalize_auth_bridge_result,
)
from .feedback import build_feedback_upload_request, feedback_endpoint_url  # noqa: E402
from .feed import (  # noqa: E402
    expire_feed_item,
    feed_event_from_params,
    feed_exit_plan_decision,
    feed_item_from_event,
    feed_kind,
    feed_permission_decision,
    feed_public_item,
    feed_push_response,
    feed_question_decision,
    feed_reply_response,
    feed_request_id,
    feed_timed_out_response,
    feed_wait_timeout,
    resolve_feed_item,
)
from .legacy_v1 import format_legacy_v1_response, parse_legacy_v1_command  # noqa: E402
from .remote import (  # noqa: E402
    active_terminal_sessions,
    build_remote_bootstrap_invocation,
    build_relay_metadata,
    build_remote_lifecycle_plan,
    build_reverse_forward_argv,
    build_remote_stdio_probe_invocation,
    effective_ssh_options,
    relay_auth_challenge,
    remote_foreground_auth_transition,
    remote_proxy_runtime_status,
    verify_relay_auth_response,
)
from .terminal import (  # noqa: E402
    LINUX_TERMINAL_BACKEND,
    build_debug_terminal_item,
    linux_port_scanner_capability,
    linux_terminal_renderer_capability,
)
from .workspace import (  # noqa: E402
    MACOS_WORKSPACE_ACTIONS,
    normalize_workspace_action,
    normalize_workspace_color,
    normalize_workspace_description,
)

Gdk: Any | None = None
try:
    from gi.repository import Gdk as GdkModule  # noqa: E402

    Gdk = GdkModule
except (ImportError, ValueError):
    Gdk = None

WEBKIT_AVAILABLE = False
WEBKIT_VERSION = ""
WebKit: Any | None = None
try:
    if GTK_MAJOR >= 4:
        gi.require_version("WebKit", "6.0")
        from gi.repository import WebKit as WebKitModule  # noqa: E402

        WebKit = WebKitModule
        WEBKIT_VERSION = "6.0"
    else:
        try:
            gi.require_version("WebKit2", "4.1")
            WEBKIT_VERSION = "4.1"
        except (ImportError, ValueError):
            gi.require_version("WebKit2", "4.0")
            WEBKIT_VERSION = "4.0"
        from gi.repository import WebKit2 as WebKitModule  # noqa: E402

        WebKit = WebKitModule
    WEBKIT_AVAILABLE = True
except (ImportError, ValueError):
    WebKit = None

APP_ID = "com.cmuxterm.cmux"
APP_NAME = "cmux Linux"
DEFAULT_WIDTH = 1180
DEFAULT_HEIGHT = 760
SIDEBAR_WIDTH = 260
SOCKET_BACKLOG = 16
CLIENT_TIMEOUT_SECONDS = 0.5
DEFAULT_BROWSER_URL = "https://www.google.com"
DEFAULT_BROWSER_TIMEOUT_MS = 5000
BROWSER_TOOLBAR_SPACING = 6
BROWSER_TOOLBAR_MARGIN = 6
BROWSER_EMPTY_URL_PREFIXES = ("data:",)
LINUX_STATE_SCHEMA_VERSION = 1
MAX_PERSISTED_FEED_ITEMS = 250
MAX_PERSISTED_FEEDBACK_SUBMISSIONS = 100
MAX_PERSISTED_REMOTE_EVENTS = 100
CMUX_TERMINAL_BACKGROUND = "#10202a"
CMUX_TERMINAL_FOREGROUND = "#eef7fb"
CMUX_TERMINAL_CURSOR = "#8cc8ff"
CMUX_TERMINAL_SELECTION = "#315e73"
CMUX_TERMINAL_PALETTE = (
    "#10202a",
    "#c74c67",
    "#159b86",
    "#c88a31",
    "#2477d6",
    "#9a72d0",
    "#20bba2",
    "#d8eef5",
    "#315e73",
    "#e15f7b",
    "#20bba2",
    "#e6a043",
    "#3490f4",
    "#b28be8",
    "#4ed7c5",
    "#f0fcff",
)
CMUX_LINUX_CSS = """
@define-color cmux_chrome_bg #10202a;
@define-color cmux_sidebar_bg #0b151c;
@define-color cmux_omnibar_bg #142832;
@define-color cmux_button_hover rgba(255, 255, 255, 0.08);
@define-color cmux_button_active rgba(255, 255, 255, 0.12);
@define-color cmux_selection rgba(63, 99, 139, 0.72);
@define-color cmux_separator rgba(255, 255, 255, 0.12);
@define-color cmux_text #ffffff;
@define-color cmux_secondary_text rgba(255, 255, 255, 0.72);
@define-color cmux_disabled_text rgba(255, 255, 255, 0.38);
@define-color cmux_accent #0a84ff;

window.cmux-window,
.cmux-root,
.cmux-stack {
  background: @cmux_chrome_bg;
  color: @cmux_text;
}

headerbar.cmux-header {
  background: @cmux_chrome_bg;
  color: @cmux_text;
  border-bottom: 1px solid @cmux_separator;
  box-shadow: none;
}

button.cmux-icon-button {
  min-width: 26px;
  min-height: 26px;
  padding: 0;
  border-radius: 7px;
  border: 1px solid transparent;
  background: transparent;
  color: @cmux_secondary_text;
  box-shadow: none;
}

button.cmux-icon-button:hover {
  background: @cmux_button_hover;
  color: @cmux_text;
}

button.cmux-icon-button:active {
  background: @cmux_button_active;
  color: @cmux_text;
}

button.cmux-icon-button:disabled {
  background: transparent;
  color: @cmux_disabled_text;
}

button.cmux-close-button:hover {
  background: rgba(255, 69, 58, 0.18);
  color: #ffb4ad;
}

list.cmux-sidebar,
.cmux-sidebar {
  background: @cmux_sidebar_bg;
  color: @cmux_text;
  border-right: 1px solid @cmux_separator;
}

list.cmux-sidebar row {
  margin: 2px 6px;
  border-radius: 7px;
  color: @cmux_secondary_text;
}

list.cmux-sidebar row:hover {
  background: @cmux_button_hover;
  color: @cmux_text;
}

list.cmux-sidebar row:selected {
  background: @cmux_selection;
  color: @cmux_text;
}

list.cmux-sidebar row.cmux-flash {
  background: rgba(10, 132, 255, 0.28);
  color: @cmux_text;
  border: 1px solid @cmux_accent;
}

label.cmux-sidebar-title {
  color: inherit;
}

box.cmux-browser {
  background: @cmux_chrome_bg;
  color: @cmux_text;
}

box.cmux-browser-toolbar {
  background: @cmux_chrome_bg;
  border-bottom: 1px solid @cmux_separator;
}

button.cmux-browser-button {
  min-width: 26px;
  min-height: 26px;
}

entry.cmux-browser-address {
  min-height: 26px;
  padding: 4px 8px;
  border-radius: 10px;
  border: 1px solid transparent;
  background: @cmux_omnibar_bg;
  color: @cmux_text;
  box-shadow: none;
}

entry.cmux-browser-address:focus {
  border-color: @cmux_accent;
  box-shadow: none;
}

entry.cmux-browser-address text {
  background: transparent;
  color: @cmux_text;
}

box.cmux-placeholder {
  background: @cmux_chrome_bg;
  color: @cmux_secondary_text;
}

paned.cmux-splitter > separator {
  background: @cmux_separator;
}
""".strip()
FALLBACK_SCREENSHOT_PNG_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFUlEQVR42mNk+M9Qz0AEYBxVSF+FAP8ADwMByNf1WQAAAABJRU5ErkJggg=="
)
LINUX_WINDOW_ID = "linux-main-window"
DEFAULT_NOTIFICATION_TITLE = "Notification"

SUPPORTED_METHODS = (
    "system.ping",
    "system.identify",
    "system.capabilities",
    "system.tree",
    "auth.login",
    "auth.status",
    "auth.begin_sign_in",
    "auth.sign_out",
    "settings.open",
    "app.focus_override.set",
    "app.simulate_active",
    "window.list",
    "window.current",
    "window.focus",
    "window.create",
    "window.close",
    "workspace.list",
    "workspace.current",
    "workspace.select",
    "workspace.create",
    "workspace.close",
    "workspace.reorder",
    "workspace.rename",
    "workspace.action",
    "workspace.next",
    "workspace.previous",
    "workspace.last",
    "workspace.equalize_splits",
    "workspace.move_to_window",
    "workspace.remote.configure",
    "workspace.remote.foreground_auth_ready",
    "workspace.remote.reconnect",
    "workspace.remote.disconnect",
    "workspace.remote.status",
    "workspace.remote.terminal_session_end",
    "session.restore_previous",
    "surface.list",
    "surface.current",
    "surface.focus",
    "surface.select",
    "surface.create",
    "surface.close",
    "surface.move",
    "surface.reorder",
    "surface.drag_to_split",
    "surface.refresh",
    "surface.health",
    "surface.trigger_flash",
    "surface.split",
    "surface.action",
    "surface.send_text",
    "surface.send_key",
    "surface.report_tty",
    "surface.ports_kick",
    "surface.read_text",
    "surface.clear_history",
    "tab.action",
    "pane.list",
    "pane.focus",
    "pane.surfaces",
    "pane.create",
    "pane.resize",
    "pane.swap",
    "pane.break",
    "pane.join",
    "pane.last",
    "pane.close",
    "pane.sendText",
    "browser.open",
    "browser.open_split",
    "browser.navigate",
    "browser.back",
    "browser.forward",
    "browser.reload",
    "browser.url.get",
    "browser.focus_webview",
    "browser.is_webview_focused",
    "browser.snapshot",
    "browser.eval",
    "browser.wait",
    "browser.click",
    "browser.dblclick",
    "browser.hover",
    "browser.focus",
    "browser.type",
    "browser.fill",
    "browser.press",
    "browser.keydown",
    "browser.keyup",
    "browser.check",
    "browser.uncheck",
    "browser.select",
    "browser.scroll",
    "browser.scroll_into_view",
    "browser.screenshot",
    "browser.get.text",
    "browser.get.html",
    "browser.get.value",
    "browser.get.attr",
    "browser.get.title",
    "browser.get.count",
    "browser.get.box",
    "browser.get.styles",
    "browser.is.visible",
    "browser.is.enabled",
    "browser.is.checked",
    "browser.find.role",
    "browser.find.text",
    "browser.find.label",
    "browser.find.placeholder",
    "browser.find.alt",
    "browser.find.title",
    "browser.find.testid",
    "browser.find.first",
    "browser.find.last",
    "browser.find.nth",
    "browser.frame.select",
    "browser.frame.main",
    "browser.dialog.accept",
    "browser.dialog.dismiss",
    "browser.download.wait",
    "browser.cookies.get",
    "browser.cookies.set",
    "browser.cookies.clear",
    "browser.storage.get",
    "browser.storage.set",
    "browser.storage.clear",
    "browser.tab.new",
    "browser.tab.list",
    "browser.tab.switch",
    "browser.tab.close",
    "browser.console.list",
    "browser.console.clear",
    "browser.errors.list",
    "browser.highlight",
    "browser.state.save",
    "browser.state.load",
    "browser.addinitscript",
    "browser.addscript",
    "browser.addstyle",
    "browser.viewport.set",
    "browser.geolocation.set",
    "browser.offline.set",
    "browser.trace.start",
    "browser.trace.stop",
    "browser.network.route",
    "browser.network.unroute",
    "browser.network.requests",
    "browser.screencast.start",
    "browser.screencast.stop",
    "browser.input_mouse",
    "browser.input_keyboard",
    "browser.input_touch",
    "markdown.open",
    "notification.create",
    "notification.list",
    "notification.create_for_surface",
    "notification.create_for_target",
    "notification.clear",
    "debug.terminals",
    "feedback.open",
    "feedback.submit",
    "feed.push",
    "feed.permission.reply",
    "feed.question.reply",
    "feed.exit_plan.reply",
    "feed.jump",
    "feed.list",
)

UNSUPPORTED_METHODS = ()

FEATURE_FLAGS = (
    "terminal",
    "surface-tabs",
    "split-tabs",
    "pane-split",
    "browser-panel",
    "browser-chrome",
    "shortcut-settings",
    "keyboard-shortcuts",
    "window-api",
    "notification-store",
    "surface-telemetry",
    "browser-automation-mvp",
    "markdown-preview",
    "app-focus-override",
    "auth-local-mvp",
    "feed-store",
    "feedback-local-store",
    "remote-workspace-status-mvp",
    "session-restore-mvp",
    "persistent-linux-runtime-state",
    "session-restore-snapshot",
)

LEGACY_ALIASES = {
    "browser.open": "browser.open_split",
    "pane.sendText": "surface.send_text",
    "surface.select": "surface.focus",
}

KEY_SEQUENCES = {
    "enter": "\r",
    "return": "\r",
    "tab": "\t",
    "escape": "\x1b",
    "esc": "\x1b",
    "backspace": "\x7f",
    "delete": "\x1b[3~",
    "left": "\x1b[D",
    "arrowleft": "\x1b[D",
    "right": "\x1b[C",
    "arrowright": "\x1b[C",
    "up": "\x1b[A",
    "arrowup": "\x1b[A",
    "down": "\x1b[B",
    "arrowdown": "\x1b[B",
    "home": "\x1b[H",
    "end": "\x1b[F",
    "pageup": "\x1b[5~",
    "pagedown": "\x1b[6~",
}

_ = gettext.translation("cmux", fallback=True).gettext


class _ResizeCandidateFound(Exception):
    def __init__(self, paned: Gtk.Paned, pane_in_first_child: bool) -> None:
        super().__init__()
        self.paned = paned
        self.pane_in_first_child = pane_in_first_child


@dataclass(frozen=True)
class PaneSnapshot:
    id: str
    surface_id: str
    kind: str
    title: str
    cwd: str | None = None
    url: str | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "ref": f"pane:{self.id}",
            "pane_id": self.id,
            "pane_ref": f"pane:{self.id}",
            "surfaceId": self.surface_id,
            "surface_id": self.surface_id,
            "surface_ref": f"surface:{self.surface_id}",
            "kind": self.kind,
            "title": self.title,
            "cwd": self.cwd,
            "url": self.url,
        }


@dataclass(frozen=True)
class SurfaceSnapshot:
    id: str
    title: str
    cwd: str
    pane_ids: list[str]
    current_pane_id: str | None

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "ref": f"surface:{self.id}",
            "surface_id": self.id,
            "surface_ref": f"surface:{self.id}",
            "tab_ref": f"tab:{self.id}",
            "title": self.title,
            "cwd": self.cwd,
            "paneIds": self.pane_ids,
            "pane_ids": self.pane_ids,
            "currentPaneId": self.current_pane_id,
            "current_pane_id": self.current_pane_id,
            "pane_id": self.current_pane_id,
        }


@dataclass
class Pane:
    id: str
    surface_id: str
    kind: str
    title: str
    widget: Gtk.Widget
    cwd: str | None = None
    url: str | None = None
    browser_refs: dict[str, str] = field(default_factory=dict)
    init_scripts: list[str] = field(default_factory=list)
    browser_web_view: Gtk.Widget | None = None
    browser_back_button: Gtk.Button | None = None
    browser_forward_button: Gtk.Button | None = None
    browser_reload_button: Gtk.Button | None = None
    browser_close_button: Gtk.Button | None = None
    browser_address_entry: Gtk.Entry | None = None
    browser_is_loading: bool = False
    browser_frame_selector: str | None = None
    browser_viewport: dict[str, int] | None = None
    browser_geolocation: dict[str, float] | None = None
    browser_offline: bool = False
    browser_trace_active: bool = False
    browser_trace_started_at: float | None = None
    browser_network_routes: list[dict[str, Any]] = field(default_factory=list)
    browser_screencast_active: bool = False
    browser_dialog_policy: dict[str, Any] | None = None

    def snapshot(self) -> PaneSnapshot:
        return PaneSnapshot(
            id=self.id,
            surface_id=self.surface_id,
            kind=self.kind,
            title=self.title,
            cwd=self.cwd,
            url=self.url,
        )


@dataclass
class Surface:
    id: str
    title: str
    cwd: str
    root_widget: Gtk.Widget
    panes: dict[str, Pane] = field(default_factory=dict)
    current_pane_id: str | None = None
    previous_pane_id: str | None = None

    def snapshot(self) -> SurfaceSnapshot:
        return SurfaceSnapshot(
            id=self.id,
            title=self.title,
            cwd=self.cwd,
            pane_ids=list(self.panes.keys()),
            current_pane_id=self.current_pane_id,
        )


@dataclass
class Workspace:
    id: str
    name: str
    surfaces: dict[str, Surface] = field(default_factory=dict)
    current_surface_id: str | None = None
    description: str | None = None
    custom_color: str | None = None
    is_pinned: bool = False
    remote_configuration: dict[str, Any] | None = None
    remote_state: str = "local"
    remote_foreground_auth_ready_at: float | None = None
    remote_terminal_session_ends: list[dict[str, Any]] = field(default_factory=list)

    def snapshot(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "ref": f"workspace:{self.id}",
            "workspace_id": self.id,
            "workspace_ref": f"workspace:{self.id}",
            "name": self.name,
            "title": self.name,
            "description": self.description,
            "customDescription": self.description,
            "custom_description": self.description,
            "color": self.custom_color,
            "customColor": self.custom_color,
            "custom_color": self.custom_color,
            "pinned": self.is_pinned,
            "isPinned": self.is_pinned,
            "is_pinned": self.is_pinned,
            "surfaceIds": list(self.surfaces.keys()),
            "surface_ids": list(self.surfaces.keys()),
            "currentSurfaceId": self.current_surface_id,
            "current_surface_id": self.current_surface_id,
        }


@dataclass(frozen=True)
class LinuxNotification:
    id: str
    workspace_id: str | None
    surface_id: str | None
    title: str
    subtitle: str
    body: str
    created_at: float
    target: dict[str, Any] = field(default_factory=dict)
    is_read: bool = False

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "notification_id": self.id,
            "workspace_id": self.workspace_id,
            "workspace_ref": f"workspace:{self.workspace_id}" if self.workspace_id else None,
            "surface_id": self.surface_id,
            "surface_ref": f"surface:{self.surface_id}" if self.surface_id else None,
            "title": self.title,
            "subtitle": self.subtitle,
            "body": self.body,
            "created_at": self.created_at,
            "target": dict(self.target),
            "is_read": self.is_read,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="cmux-linux")
    parser.add_argument("--socket", dest="socket_path", default=None)
    parser.add_argument("--cwd", dest="cwd", default=os.getcwd())
    parser.add_argument("--command", dest="command", default=None)
    return parser.parse_args()


def default_socket_path() -> Path:
    explicit = os.environ.get("CMUX_SOCKET_PATH")
    if explicit:
        return Path(explicit)

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    base_dir = Path(runtime_dir) / "cmux" if runtime_dir else Path(tempfile.gettempdir()) / "cmux"
    return base_dir / "cmux.sock"


def default_state_path() -> Path:
    explicit = os.environ.get("CMUX_LINUX_STATE_PATH")
    if explicit:
        return Path(explicit).expanduser()

    state_home = os.environ.get("XDG_STATE_HOME")
    base_dir = Path(state_home).expanduser() if state_home else Path.home() / ".local" / "state"
    return base_dir / "cmux" / "linux-state.json"


def bundled_remote_daemon_path() -> Path:
    return (Path(__file__).resolve().parents[2] / "bin" / "cmuxd-remote").resolve()


def repo_remote_daemon_path() -> Path:
    return (Path(__file__).resolve().parents[3] / "daemon" / "remote" / "cmuxd-remote").resolve()


def remote_daemon_candidates() -> list[Path]:
    explicit = os.environ.get("CMUX_LINUX_REMOTE_DAEMON_BINARY") or os.environ.get("CMUX_REMOTE_DAEMON_BINARY")
    candidates = [Path(explicit).expanduser()] if explicit else []
    return [*candidates, bundled_remote_daemon_path(), repo_remote_daemon_path()]


def find_remote_daemon_binary() -> Path | None:
    for candidate in remote_daemon_candidates():
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    return None


def remote_daemon_probe(path: Path) -> dict[str, Any]:
    request = (
        json.dumps({"id": "hello", "method": "hello", "params": {}}, separators=(",", ":"))
        + "\n"
        + json.dumps({"id": "ping", "method": "ping", "params": {}}, separators=(",", ":"))
        + "\n"
    )
    try:
        completed = subprocess.run(
            [str(path), "serve", "--stdio"],
            input=request.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "detail": str(error)}

    responses: list[dict[str, Any]] = []
    for line in completed.stdout.decode("utf-8", errors="replace").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            responses.append(value)

    hello = next((item for item in responses if item.get("id") == "hello"), {})
    ping = next((item for item in responses if item.get("id") == "ping"), {})
    hello_result = hello.get("result") if isinstance(hello.get("result"), dict) else {}
    ping_result = ping.get("result") if isinstance(ping.get("result"), dict) else {}
    return {
        "ok": completed.returncode == 0 and hello.get("ok") is True and ping.get("ok") is True,
        "hello": hello.get("ok") is True,
        "ping": ping.get("ok") is True and ping_result.get("pong") is True,
        "version": hello_result.get("version"),
        "capabilities": hello_result.get("capabilities") if isinstance(hello_result.get("capabilities"), list) else [],
        "exit_code": completed.returncode,
    }


def validate_ssh_destination(destination: str) -> None:
    if destination.startswith("-") or any(character.isspace() for character in destination):
        raise ValueError(_("Invalid SSH destination."))
    forbidden = set(";|&`$<>")
    if any(character in forbidden for character in destination):
        raise ValueError(_("Invalid SSH destination."))


def has_graphical_session() -> bool:
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY") or os.environ.get("MIR_SOCKET"))


def application_flags() -> Gio.ApplicationFlags:
    flags = Gio.ApplicationFlags(0)
    if os.environ.get("CMUX_LINUX_NON_UNIQUE") == "1":
        flags |= Gio.ApplicationFlags.NON_UNIQUE
    return flags


def response_line(request_id: Any, ok: bool, payload: dict[str, Any]) -> bytes:
    key = "result" if ok else "error"
    envelope = {"id": request_id, "ok": ok, key: payload}
    return (json.dumps(envelope, separators=(",", ":")) + "\n").encode("utf-8")


def normalize_params(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def terminal_title(command: str | None, cwd: str) -> str:
    if command:
        return command.splitlines()[0][:48]
    return Path(cwd).name or _("Terminal")


def normalize_url(value: str) -> str:
    url = value.strip() or DEFAULT_BROWSER_URL
    scheme = url.split(":", 1)[0] if ":" in url else ""
    if scheme and all(char.isalnum() or char in "+-." for char in scheme):
        return url
    if "://" in url:
        return url
    return f"https://{url}"


def browser_display_url(value: str | None) -> str:
    url = str(value or "").strip()
    lowered = url.lower()
    if not url or lowered == "about:blank" or any(lowered.startswith(prefix) for prefix in BROWSER_EMPTY_URL_PREFIXES):
        return ""
    return url


def browser_display_title(title: str | None, url: str | None) -> str:
    clean_title = browser_display_url(title)
    if clean_title:
        return clean_title
    clean_url = browser_display_url(url)
    return clean_url or _("New Tab")


def markdown_preview_url(path: Path) -> str:
    content = path.read_text(encoding="utf-8", errors="replace")
    body = render_markdown_preview(content)
    document = f"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>{html.escape(path.name)}</title>
<style>
body {{ color: #202124; font: 16px/1.55 system-ui, sans-serif; margin: 40px auto; max-width: 880px; padding: 0 24px; }}
pre, code {{ background: #f5f7f9; border-radius: 6px; font-family: ui-monospace, SFMono-Regular, monospace; }}
pre {{ overflow: auto; padding: 14px; }}
code {{ padding: 2px 4px; }}
blockquote {{ border-left: 4px solid #c7ced8; color: #4d5968; margin-left: 0; padding-left: 16px; }}
a {{ color: #0b57d0; }}
</style>
</head>
<body>{body}</body>
</html>"""
    encoded = base64.b64encode(document.encode("utf-8")).decode("ascii")
    return f"data:text/html;base64,{encoded}"


def render_markdown_preview(content: str) -> str:
    rendered: list[str] = []
    paragraph: list[str] = []
    code_lines: list[str] = []
    in_code = False

    def flush_paragraph() -> None:
        if paragraph:
            rendered.append(f"<p>{' '.join(paragraph)}</p>")
            paragraph.clear()

    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            if in_code:
                rendered.append(f"<pre><code>{html.escape(chr(10).join(code_lines))}</code></pre>")
                code_lines.clear()
                in_code = False
            else:
                flush_paragraph()
                in_code = True
            continue
        if in_code:
            code_lines.append(line)
            continue
        if not stripped:
            flush_paragraph()
            continue
        if stripped.startswith("#"):
            flush_paragraph()
            level = min(len(stripped) - len(stripped.lstrip("#")), 6)
            rendered.append(f"<h{level}>{html.escape(stripped[level:].strip())}</h{level}>")
            continue
        if stripped.startswith("- ") or stripped.startswith("* "):
            flush_paragraph()
            rendered.append(f"<ul><li>{html.escape(stripped[2:].strip())}</li></ul>")
            continue
        if stripped.startswith(">"):
            flush_paragraph()
            rendered.append(f"<blockquote>{html.escape(stripped[1:].strip())}</blockquote>")
            continue
        paragraph.append(html.escape(stripped))
    flush_paragraph()
    if in_code or code_lines:
        rendered.append(f"<pre><code>{html.escape(chr(10).join(code_lines))}</code></pre>")
    return "\n".join(rendered) or "<p></p>"


def parse_ref(value: Any, *kinds: str) -> str:
    raw = str(value or "")
    for kind in kinds:
        for marker in (f"{kind}:", f"{kind}-", f"@{kind}:"):
            if raw.startswith(marker):
                return raw[len(marker) :]
    return raw


def js_literal(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False)


class UnsupportedMethodError(RuntimeError):
    def __init__(self, method: str, detail: str) -> None:
        super().__init__(detail)
        self.method = method


class BackendUnavailableError(RuntimeError):
    pass


class TransportError(RuntimeError):
    pass


class RemoteRelayServer:
    def __init__(
        self,
        *,
        workspace_id: str,
        relay_id: str,
        relay_token: str,
        local_port: int,
        socket_path: Path,
    ) -> None:
        self.workspace_id = workspace_id
        self.relay_id = relay_id
        self.relay_token = relay_token
        self.local_port = local_port
        self.socket_path = socket_path
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._serve, name=f"cmux-relay-{workspace_id}", daemon=True)
        self.server_socket: socket.socket | None = None
        self.lock = threading.Lock()
        self.started_at: float | None = None
        self.last_connection_at: float | None = None
        self.last_auth_success_at: float | None = None
        self.last_auth_failure_at: float | None = None
        self.connection_count = 0
        self.auth_success_count = 0
        self.auth_failure_count = 0
        self.last_error: str | None = None

    def start(self) -> None:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", self.local_port))
        server.listen(SOCKET_BACKLOG)
        server.settimeout(CLIENT_TIMEOUT_SECONDS)
        self.server_socket = server
        self.started_at = time.time()
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.server_socket:
            self.server_socket.close()
        if self.thread.is_alive():
            self.thread.join(timeout=1)

    def status(self) -> dict[str, Any]:
        with self.lock:
            return {
                "listening": self.server_socket is not None and not self.stop_event.is_set(),
                "host": "127.0.0.1",
                "port": self.local_port,
                "socket_path": str(self.socket_path),
                "started_at": self.started_at,
                "connection_count": self.connection_count,
                "auth_success_count": self.auth_success_count,
                "auth_failure_count": self.auth_failure_count,
                "last_connection_at": self.last_connection_at,
                "last_auth_success_at": self.last_auth_success_at,
                "last_auth_failure_at": self.last_auth_failure_at,
                "last_error": self.last_error,
            }

    def _serve(self) -> None:
        server = self.server_socket
        if server is None:
            return
        while not self.stop_event.is_set():
            try:
                client, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._handle_client, args=(client,), daemon=True).start()

    def _handle_client(self, client: socket.socket) -> None:
        with client:
            try:
                if not self._authenticate(client):
                    return
                self._proxy_to_local_socket(client)
            except OSError as error:
                self._record_error(str(error))

    def _authenticate(self, client: socket.socket) -> bool:
        nonce = secrets.token_hex(16)
        challenge = relay_auth_challenge(relay_id=self.relay_id, nonce=nonce)
        client.settimeout(5)
        client.sendall((json.dumps(challenge, separators=(",", ":")) + "\n").encode("utf-8"))
        reader = client.makefile("rb")
        raw_line = reader.readline(8192)
        try:
            response = json.loads(raw_line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            response = {}
        ok = isinstance(response, dict) and verify_relay_auth_response(
            relay_id=self.relay_id,
            relay_token=self.relay_token,
            nonce=nonce,
            response=response,
        )
        client.sendall((json.dumps({"ok": ok}, separators=(",", ":")) + "\n").encode("utf-8"))
        now = time.time()
        with self.lock:
            self.connection_count += 1
            self.last_connection_at = now
            if ok:
                self.auth_success_count += 1
                self.last_auth_success_at = now
            else:
                self.auth_failure_count += 1
                self.last_auth_failure_at = now
        client.settimeout(None)
        return ok

    def _proxy_to_local_socket(self, client: socket.socket) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as upstream:
            upstream.connect(str(self.socket_path))
            threads = [
                threading.Thread(target=self._copy_stream, args=(client, upstream), daemon=True),
                threading.Thread(target=self._copy_stream, args=(upstream, client), daemon=True),
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()

    def _copy_stream(self, source: socket.socket, target: socket.socket) -> None:
        try:
            while not self.stop_event.is_set():
                data = source.recv(65536)
                if not data:
                    break
                target.sendall(data)
        except OSError as error:
            self._record_error(str(error))
        try:
            target.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def _record_error(self, message: str) -> None:
        with self.lock:
            self.last_error = message


class SocketServer:
    def __init__(self, path: Path, window: "CMUXLinuxWindow") -> None:
        self.path = path
        self.window = window
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._serve, name="cmux-linux-socket", daemon=True)
        self.server_socket: socket.socket | None = None

    def start(self) -> None:
        ensure_private_socket_directory(self.path)
        self._remove_stale_socket()
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.server_socket:
            self.server_socket.close()
        self._remove_stale_socket()

    def _remove_stale_socket(self) -> None:
        try:
            mode = self.path.stat().st_mode
        except FileNotFoundError:
            return
        if stat.S_ISSOCK(mode):
            self.path.unlink()

    def _serve(self) -> None:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                self.server_socket = server
                bind_private_unix_socket(server, self.path)
                server.listen(SOCKET_BACKLOG)
                server.settimeout(CLIENT_TIMEOUT_SECONDS)
                while not self.stop_event.is_set():
                    self._accept_next(server)
        except OSError as error:
            GLib.idle_add(self.window.show_socket_error, str(error))

    def _accept_next(self, server: socket.socket) -> None:
        try:
            client, _ = server.accept()
        except socket.timeout:
            return
        except OSError:
            return
        threading.Thread(target=self._handle_client, args=(client,), daemon=True).start()

    def _handle_client(self, client: socket.socket) -> None:
        with client:
            reader = client.makefile("rb")
            for raw_line in reader:
                client.sendall(self._handle_raw_line(raw_line))

    def _handle_raw_line(self, raw_line: bytes) -> bytes:
        stripped = raw_line.lstrip()
        if stripped.startswith(b"{"):
            request_id, ok, payload = self._handle_line(raw_line)
            return response_line(request_id, ok, payload)

        try:
            command_text = raw_line.decode("utf-8").strip()
        except UnicodeDecodeError:
            return b"ERROR: Invalid command encoding\n"

        parsed = parse_legacy_v1_command(command_text)
        if parsed is None:
            return b"ERROR: Unknown command\n"

        method, params = parsed
        _request_id, ok, payload = self._dispatch(None, method, params)
        response = format_legacy_v1_response(command_text, ok, payload)
        return (response.rstrip("\n") + "\n").encode("utf-8")

    def _handle_line(self, raw_line: bytes) -> tuple[Any, bool, dict[str, Any]]:
        try:
            command = json.loads(raw_line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None, False, {"code": "invalid_json", "message": _("Command must be JSON.")}

        if not isinstance(command, dict):
            return None, False, {"code": "invalid_command", "message": _("Command must be an object.")}

        request_id = command.get("id")
        method = command.get("method")
        params = normalize_params(command.get("params"))
        if not isinstance(method, str):
            return request_id, False, {"code": "missing_method", "message": _("Missing method.")}
        return self._dispatch(request_id, method, params)

    def _dispatch(self, request_id: Any, method: str, params: dict[str, Any]) -> tuple[Any, bool, dict[str, Any]]:
        handlers: dict[str, Callable[[], dict[str, Any]]] = {
            "system.ping": lambda: {"message": "pong", "platform": "linux"},
            "system.identify": lambda: self._on_main(self.window.identify),
            "system.capabilities": lambda: self._on_main(self.window.capabilities),
            "system.tree": lambda: self._on_main(lambda: self.window.system_tree_from_params(params)),
            "auth.login": lambda: self._on_main(lambda: self.window.auth_login_from_params(params)),
            "auth.status": lambda: self._on_main(lambda: self.window.auth_status_from_params(params)),
            "auth.begin_sign_in": lambda: self._on_main(lambda: self.window.auth_begin_sign_in_from_params(params)),
            "auth.sign_out": lambda: self._on_main(lambda: self.window.auth_sign_out_from_params(params)),
            "settings.open": lambda: self._on_main(lambda: self.window.open_settings_from_params(params)),
            "window.list": lambda: self._on_main(self.window.list_windows),
            "window.current": lambda: self._on_main(self.window.current_window_snapshot),
            "window.focus": lambda: self._on_main(lambda: self.window.focus_window_from_params(params)),
            "window.create": lambda: self._on_main(lambda: self.window.create_window_from_params(params)),
            "window.close": lambda: self._on_main(lambda: self.window.close_window_from_params(params)),
            "app.focus_override.set": lambda: self._on_main(lambda: self.window.set_app_focus_override_from_params(params)),
            "app.simulate_active": lambda: self._on_main(self.window.simulate_app_active),
            "markdown.open": lambda: self._on_main(lambda: self.window.open_markdown_from_params(params)),
            "workspace.list": lambda: self._on_main(self.window.list_workspaces),
            "workspace.current": lambda: self._on_main(self.window.current_workspace_snapshot),
            "workspace.select": lambda: self._on_main(lambda: self.window.select_workspace_from_params(params)),
            "workspace.create": lambda: self._on_main(lambda: self.window.create_workspace_from_params(params)),
            "workspace.move_to_window": lambda: self._on_main(lambda: self.window.move_workspace_to_window_from_params(params)),
            "workspace.close": lambda: self._on_main(lambda: self.window.close_workspace_from_params(params)),
            "workspace.reorder": lambda: self._on_main(lambda: self.window.reorder_workspace_from_params(params)),
            "workspace.rename": lambda: self._on_main(lambda: self.window.rename_workspace_from_params(params)),
            "workspace.action": lambda: self._on_main(lambda: self.window.workspace_action_from_params(params)),
            "workspace.next": lambda: self._on_main(lambda: self.window.select_relative_workspace(1)),
            "workspace.previous": lambda: self._on_main(lambda: self.window.select_relative_workspace(-1)),
            "workspace.last": lambda: self._on_main(self.window.select_last_workspace),
            "workspace.equalize_splits": lambda: self._on_main(lambda: self.window.equalize_workspace_splits_from_params(params)),
            "workspace.remote.configure": lambda: self._on_main(
                lambda: self.window.configure_remote_workspace_from_params(params)
            ),
            "workspace.remote.foreground_auth_ready": lambda: self._on_main(
                lambda: self.window.remote_foreground_auth_ready_from_params(params)
            ),
            "workspace.remote.reconnect": lambda: self._on_main(
                lambda: self.window.reconnect_remote_workspace_from_params(params)
            ),
            "workspace.remote.disconnect": lambda: self._on_main(
                lambda: self.window.disconnect_remote_workspace_from_params(params)
            ),
            "workspace.remote.status": lambda: self._on_main(
                lambda: self.window.remote_workspace_status_from_params(params)
            ),
            "workspace.remote.terminal_session_end": lambda: self._on_main(
                lambda: self.window.remote_terminal_session_end_from_params(params)
            ),
            "session.restore_previous": lambda: self._on_main(
                lambda: self.window.restore_previous_session_from_params(params)
            ),
            "surface.list": lambda: self._on_main(lambda: self.window.list_surfaces(params)),
            "surface.current": lambda: self._on_main(lambda: self.window.current_surface_snapshot(params)),
            "surface.focus": lambda: self._on_main(lambda: self.window.focus_surface_from_params(params)),
            "surface.select": lambda: self._on_main(lambda: self.window.select_surface_from_params(params)),
            "surface.create": lambda: self._on_main(lambda: self.window.create_surface_from_params(params)),
            "surface.close": lambda: self._on_main(lambda: self.window.close_surface_from_params(params)),
            "surface.move": lambda: self._on_main(lambda: self.window.move_surface_from_params(params)),
            "surface.reorder": lambda: self._on_main(lambda: self.window.reorder_surface_from_params(params)),
            "surface.drag_to_split": lambda: self._on_main(lambda: self.window.drag_surface_to_split_from_params(params)),
            "surface.refresh": lambda: self._on_main(lambda: self.window.refresh_surfaces_from_params(params)),
            "surface.health": lambda: self._on_main(lambda: self.window.surface_health_from_params(params)),
            "surface.trigger_flash": lambda: self._on_main(lambda: self.window.trigger_surface_flash_from_params(params)),
            "surface.split": lambda: self._on_main(lambda: self.window.split_surface_from_params(params)),
            "surface.action": lambda: self._on_main(lambda: self.window.surface_action_from_params(params)),
            "surface.send_text": lambda: self._on_main(lambda: self.window.send_text_to_surface_from_params(params)),
            "surface.send_key": lambda: self._on_main(lambda: self.window.send_key_to_surface_from_params(params)),
            "surface.report_tty": lambda: self._on_main(lambda: self.window.report_tty_from_params(params)),
            "surface.ports_kick": lambda: self._on_main(lambda: self.window.ports_kick_from_params(params)),
            "surface.read_text": lambda: self._on_main(lambda: self.window.read_text_from_surface_params(params)),
            "surface.clear_history": lambda: self._on_main(
                lambda: self.window.clear_history_from_surface_params(params)
            ),
            "tab.action": lambda: self._on_main(lambda: self.window.tab_action_from_params(params)),
            "pane.list": lambda: self._on_main(lambda: self.window.list_panes(params)),
            "pane.focus": lambda: self._on_main(lambda: self.window.focus_pane_from_params(params)),
            "pane.surfaces": lambda: self._on_main(lambda: self.window.pane_surfaces_from_params(params)),
            "pane.create": lambda: self._on_main(lambda: self.window.create_pane_from_params(params)),
            "pane.resize": lambda: self._on_main(lambda: self.window.resize_pane_from_params(params)),
            "pane.swap": lambda: self._on_main(lambda: self.window.swap_pane_from_params(params)),
            "pane.break": lambda: self._on_main(lambda: self.window.break_pane_from_params(params)),
            "pane.join": lambda: self._on_main(lambda: self.window.join_pane_from_params(params)),
            "pane.last": lambda: self._on_main(lambda: self.window.select_last_pane_from_params(params)),
            "pane.close": lambda: self._on_main(lambda: self.window.close_pane_from_params(params)),
            "pane.sendText": lambda: self._on_main(lambda: self.window.send_text_to_pane_from_params(params)),
            "browser.open": lambda: self._on_main(lambda: self.window.open_browser_from_params(params)),
            "browser.open_split": lambda: self._on_main(lambda: self.window.open_browser_split_from_params(params)),
            "browser.navigate": lambda: self._on_main(lambda: self.window.navigate_browser_from_params(params)),
            "browser.back": lambda: self._on_main(lambda: self.window.go_back_browser_from_params(params)),
            "browser.forward": lambda: self._on_main(lambda: self.window.go_forward_browser_from_params(params)),
            "browser.reload": lambda: self._on_main(lambda: self.window.reload_browser_from_params(params)),
            "browser.url.get": lambda: self._on_main(lambda: self.window.get_browser_url_from_params(params)),
            "browser.focus_webview": lambda: self._on_main(lambda: self.window.focus_browser_from_params(params)),
            "browser.is_webview_focused": lambda: self._on_main(lambda: self.window.is_browser_focused_from_params(params)),
            "browser.snapshot": lambda: self._on_main(lambda: self.window.snapshot_browser_from_params(params)),
            "browser.eval": lambda: self._on_main(lambda: self.window.eval_browser_from_params(params)),
            "browser.wait": lambda: self._on_main(lambda: self.window.wait_browser_from_params(params)),
            "browser.click": lambda: self._on_main(lambda: self.window.click_browser_from_params(params)),
            "browser.dblclick": lambda: self._on_main(lambda: self.window.dblclick_browser_from_params(params)),
            "browser.hover": lambda: self._on_main(lambda: self.window.hover_browser_from_params(params)),
            "browser.focus": lambda: self._on_main(lambda: self.window.focus_browser_element_from_params(params)),
            "browser.type": lambda: self._on_main(lambda: self.window.type_browser_from_params(params)),
            "browser.fill": lambda: self._on_main(lambda: self.window.fill_browser_from_params(params)),
            "browser.press": lambda: self._on_main(lambda: self.window.key_browser_from_params(params, "press")),
            "browser.keydown": lambda: self._on_main(lambda: self.window.key_browser_from_params(params, "keydown")),
            "browser.keyup": lambda: self._on_main(lambda: self.window.key_browser_from_params(params, "keyup")),
            "browser.check": lambda: self._on_main(lambda: self.window.check_browser_from_params(params, True)),
            "browser.uncheck": lambda: self._on_main(lambda: self.window.check_browser_from_params(params, False)),
            "browser.select": lambda: self._on_main(lambda: self.window.select_browser_from_params(params)),
            "browser.scroll": lambda: self._on_main(lambda: self.window.scroll_browser_from_params(params)),
            "browser.scroll_into_view": lambda: self._on_main(lambda: self.window.scroll_into_view_browser_from_params(params)),
            "browser.screenshot": lambda: self._on_main(lambda: self.window.screenshot_browser_from_params(params)),
            "browser.get.text": lambda: self._on_main(lambda: self.window.get_browser_text_from_params(params)),
            "browser.get.html": lambda: self._on_main(lambda: self.window.get_browser_html_from_params(params)),
            "browser.get.value": lambda: self._on_main(lambda: self.window.get_browser_value_from_params(params)),
            "browser.get.attr": lambda: self._on_main(lambda: self.window.get_browser_attr_from_params(params)),
            "browser.get.title": lambda: self._on_main(lambda: self.window.get_browser_title_from_params(params)),
            "browser.get.count": lambda: self._on_main(lambda: self.window.get_browser_count_from_params(params)),
            "browser.get.box": lambda: self._on_main(lambda: self.window.get_browser_box_from_params(params)),
            "browser.get.styles": lambda: self._on_main(lambda: self.window.get_browser_styles_from_params(params)),
            "browser.is.visible": lambda: self._on_main(lambda: self.window.is_browser_visible_from_params(params)),
            "browser.is.enabled": lambda: self._on_main(lambda: self.window.is_browser_enabled_from_params(params)),
            "browser.is.checked": lambda: self._on_main(lambda: self.window.is_browser_checked_from_params(params)),
            "browser.find.role": lambda: self._on_main(lambda: self.window.find_browser_role_from_params(params)),
            "browser.find.text": lambda: self._on_main(lambda: self.window.find_browser_text_from_params(params)),
            "browser.find.label": lambda: self._on_main(lambda: self.window.find_browser_label_from_params(params)),
            "browser.find.placeholder": lambda: self._on_main(lambda: self.window.find_browser_placeholder_from_params(params)),
            "browser.find.alt": lambda: self._on_main(lambda: self.window.find_browser_attr_match_from_params(params, "alt")),
            "browser.find.title": lambda: self._on_main(lambda: self.window.find_browser_attr_match_from_params(params, "title")),
            "browser.find.testid": lambda: self._on_main(lambda: self.window.find_browser_attr_match_from_params(params, "data-testid", "testid")),
            "browser.find.first": lambda: self._on_main(lambda: self.window.find_browser_index_from_params(params, "first")),
            "browser.find.last": lambda: self._on_main(lambda: self.window.find_browser_index_from_params(params, "last")),
            "browser.find.nth": lambda: self._on_main(lambda: self.window.find_browser_index_from_params(params, "nth")),
            "browser.frame.select": lambda: self._on_main(lambda: self.window.select_browser_frame_from_params(params)),
            "browser.frame.main": lambda: self._on_main(lambda: self.window.main_browser_frame_from_params(params)),
            "browser.dialog.accept": lambda: self._on_main(lambda: self.window.set_browser_dialog_policy_from_params(params, True)),
            "browser.dialog.dismiss": lambda: self._on_main(lambda: self.window.set_browser_dialog_policy_from_params(params, False)),
            "browser.download.wait": lambda: self._on_main(lambda: self.window.wait_browser_download_from_params(params)),
            "browser.cookies.get": lambda: self._on_main(lambda: self.window.get_browser_cookies_from_params(params)),
            "browser.cookies.set": lambda: self._on_main(lambda: self.window.set_browser_cookie_from_params(params)),
            "browser.cookies.clear": lambda: self._on_main(lambda: self.window.clear_browser_cookies_from_params(params)),
            "browser.storage.get": lambda: self._on_main(lambda: self.window.get_browser_storage_from_params(params)),
            "browser.storage.set": lambda: self._on_main(lambda: self.window.set_browser_storage_from_params(params)),
            "browser.storage.clear": lambda: self._on_main(lambda: self.window.clear_browser_storage_from_params(params)),
            "browser.tab.new": lambda: self._on_main(lambda: self.window.new_browser_tab_from_params(params)),
            "browser.tab.list": lambda: self._on_main(lambda: self.window.list_browser_tabs_from_params(params)),
            "browser.tab.switch": lambda: self._on_main(lambda: self.window.switch_browser_tab_from_params(params)),
            "browser.tab.close": lambda: self._on_main(lambda: self.window.close_browser_tab_from_params(params)),
            "browser.console.list": lambda: self._on_main(lambda: self.window.list_browser_console_from_params(params)),
            "browser.console.clear": lambda: self._on_main(lambda: self.window.clear_browser_console_from_params(params)),
            "browser.errors.list": lambda: self._on_main(lambda: self.window.list_browser_errors_from_params(params)),
            "browser.highlight": lambda: self._on_main(lambda: self.window.highlight_browser_from_params(params)),
            "browser.state.save": lambda: self._on_main(lambda: self.window.save_browser_state_from_params(params)),
            "browser.state.load": lambda: self._on_main(lambda: self.window.load_browser_state_from_params(params)),
            "browser.addinitscript": lambda: self._on_main(lambda: self.window.add_init_script_browser_from_params(params)),
            "browser.addscript": lambda: self._on_main(lambda: self.window.add_script_browser_from_params(params)),
            "browser.addstyle": lambda: self._on_main(lambda: self.window.add_style_browser_from_params(params)),
            "browser.viewport.set": lambda: self._on_main(lambda: self.window.set_browser_viewport_from_params(params)),
            "browser.geolocation.set": lambda: self._on_main(lambda: self.window.set_browser_geolocation_from_params(params)),
            "browser.offline.set": lambda: self._on_main(lambda: self.window.set_browser_offline_from_params(params)),
            "browser.trace.start": lambda: self._on_main(lambda: self.window.start_browser_trace_from_params(params)),
            "browser.trace.stop": lambda: self._on_main(lambda: self.window.stop_browser_trace_from_params(params)),
            "browser.network.route": lambda: self._on_main(lambda: self.window.route_browser_network_from_params(params)),
            "browser.network.unroute": lambda: self._on_main(lambda: self.window.unroute_browser_network_from_params(params)),
            "browser.network.requests": lambda: self._on_main(lambda: self.window.list_browser_network_requests_from_params(params)),
            "browser.screencast.start": lambda: self._on_main(lambda: self.window.start_browser_screencast_from_params(params)),
            "browser.screencast.stop": lambda: self._on_main(lambda: self.window.stop_browser_screencast_from_params(params)),
            "browser.input_mouse": lambda: self._on_main(lambda: self.window.input_browser_mouse_from_params(params)),
            "browser.input_keyboard": lambda: self._on_main(lambda: self.window.input_browser_keyboard_from_params(params)),
            "browser.input_touch": lambda: self._on_main(lambda: self.window.input_browser_touch_from_params(params)),
            "notification.create": lambda: self._on_main(lambda: self.window.create_notification(params)),
            "notification.list": lambda: self._on_main(lambda: self.window.list_notifications(params)),
            "notification.create_for_surface": lambda: self._on_main(
                lambda: self.window.create_notification_for_surface(params)
            ),
            "notification.create_for_target": lambda: self._on_main(
                lambda: self.window.create_notification_for_target(params)
            ),
            "notification.clear": lambda: self._on_main(lambda: self.window.clear_notifications(params)),
            "debug.terminals": lambda: self._on_main(lambda: self.window.debug_terminals_from_params(params)),
            "feedback.open": lambda: self._on_main(lambda: self.window.open_feedback_from_params(params)),
            "feedback.submit": lambda: self._on_main(lambda: self.window.submit_feedback_from_params(params)),
            "feed.push": lambda: self._feed_push(params),
            "feed.permission.reply": lambda: self._on_main(lambda: self.window.reply_feed_permission_from_params(params)),
            "feed.question.reply": lambda: self._on_main(lambda: self.window.reply_feed_question_from_params(params)),
            "feed.exit_plan.reply": lambda: self._on_main(lambda: self.window.reply_feed_exit_plan_from_params(params)),
            "feed.jump": lambda: self._on_main(lambda: self.window.jump_feed_from_params(params)),
            "feed.list": lambda: self._on_main(lambda: self.window.list_feed_from_params(params)),
        }
        for unsupported_method in UNSUPPORTED_METHODS:
            handlers.setdefault(
                unsupported_method,
                lambda method=unsupported_method: self._on_main(lambda: self.window.unsupported_method(method)),
            )

        handler = handlers.get(method)
        if handler is None:
            return request_id, False, {"code": "unknown_method", "message": method}
        try:
            return request_id, True, handler()
        except UnsupportedMethodError as error:
            return request_id, False, {"code": "not_supported", "method": error.method, "message": str(error)}
        except ValueError as error:
            return request_id, False, {"code": "invalid_params", "message": str(error)}
        except BackendUnavailableError as error:
            return request_id, False, {"code": "backend_unavailable", "message": str(error)}
        except TransportError as error:
            return request_id, False, {"code": "transport_error", "message": str(error)}
        except Exception as error:  # noqa: BLE001
            return request_id, False, {"code": "handler_error", "message": str(error)}

    def _on_main(self, callback: Callable[[], dict[str, Any]]) -> dict[str, Any]:
        result_queue: queue.Queue[tuple[bool, dict[str, Any] | Exception]] = queue.Queue(maxsize=1)

        def run_callback() -> bool:
            try:
                result_queue.put((True, callback()))
            except Exception as error:  # noqa: BLE001
                result_queue.put((False, error))
            return False

        GLib.idle_add(run_callback)
        succeeded, result = result_queue.get()
        if succeeded and isinstance(result, dict):
            return result
        if isinstance(result, Exception):
            raise result
        raise RuntimeError(_("Command failed."))

    def _feed_push(self, params: dict[str, Any]) -> dict[str, Any]:
        wait_timeout = feed_wait_timeout(params)
        event = feed_event_from_params(params)
        request_id = feed_request_id(event)
        immediate = self._on_main(lambda: self.window.push_feed_from_params(params))
        item_id = immediate.get("item_id")
        if (
            wait_timeout <= 0
            or not request_id
            or immediate.get("status") != "acknowledged"
            or not isinstance(item_id, str)
            or not item_id
        ):
            return immediate
        decision = self.window.wait_for_feed_reply(request_id, wait_timeout)
        if decision is not None:
            return feed_push_response(
                {"id": item_id},
                wait_timeout_seconds=wait_timeout,
                decision=decision,
            )
        self._on_main(lambda: self.window.expire_feed_request(request_id))
        return feed_timed_out_response(item_id)


class CMUXLinuxWindow:
    def __init__(
        self,
        application: Gtk.Application,
        cwd: str,
        command: str | None,
        *,
        window_id: str = LINUX_WINDOW_ID,
        primary_window: "CMUXLinuxWindow | None" = None,
        window_registry: list["CMUXLinuxWindow"] | None = None,
        owns_runtime_state: bool = True,
        local_socket_path: Path | None = None,
    ) -> None:
        self.application = application
        self.window_id = window_id
        self._primary_window = primary_window or self
        self._window_registry = window_registry if window_registry is not None else []
        self._owns_runtime_state = owns_runtime_state
        self._closed = False
        self.workspaces: dict[str, Workspace] = {}
        self.current_workspace_id: str | None = None
        self.previous_workspace_id: str | None = None
        self.notifications: list[LinuxNotification] = []
        self.surface_tty_names: dict[str, str] = {}
        self.last_ports_kick: dict[str, dict[str, Any]] = {}
        self.focus_override: bool | None = None
        self.simulated_active_at: float | None = None
        self.auth_signed_in = False
        self.auth_signed_in_at: float | None = None
        self.auth_backend_last_error: str | None = None
        self.feedback_opened_at: float | None = None
        self.feedback_submissions: list[dict[str, Any]] = []
        self.feed_items: list[dict[str, Any]] = []
        self.feed_replies: dict[str, dict[str, Any]] = {}
        self.feed_reply_condition = threading.Condition()
        self.remote_proxy_processes: dict[str, subprocess.Popen] = {}
        self.remote_proxy_heartbeats: dict[str, dict[str, Any]] = {}
        self.remote_relay_servers: dict[str, RemoteRelayServer] = {}
        self.remote_relay_tokens: dict[str, str] = {}
        self.local_socket_path = local_socket_path or default_socket_path()
        self.previous_session_restore_attempted_at: float | None = None
        self.state_path = default_state_path()
        self.saved_session_snapshot: dict[str, Any] | None = None
        self._suspend_state_save = True
        if self._owns_runtime_state:
            self._load_runtime_state()
        self.settings_path = default_settings_path()
        self.settings = load_settings(self.settings_path)
        self.shortcuts = build_shortcut_bindings(self.settings)
        self.css_provider = self._install_theme_css()
        self.stack = Gtk.Stack()
        self.sidebar = Gtk.ListBox()
        self._shortcut_controller: Any | None = None
        self._sidebar_selection_handler_id: int | None = None
        self._refreshing_sidebar = False
        self._add_css_class(self.stack, "cmux-stack")
        self._add_css_class(self.sidebar, "cmux-sidebar")
        self.window = self._build_window()
        self.create_workspace(_("Default"), cwd, command)
        self._register_window()
        self._suspend_state_save = False

    def present(self) -> None:
        if GTK_MAJOR < 4:
            self.window.show_all()
        self.window.present()
        self._mark_current_window()

    def show_without_focus(self) -> None:
        if GTK_MAJOR < 4:
            self.window.show_all()
            return
        if hasattr(self.window, "show"):
            self.window.show()

    def _register_window(self) -> None:
        if self not in self._window_registry:
            self._window_registry.append(self)
        if not hasattr(self._primary_window, "_current_window_id"):
            self._primary_window._current_window_id = self.window_id

    def _mark_current_window(self) -> None:
        self._primary_window._current_window_id = self.window_id

    def _active_windows(self) -> list["CMUXLinuxWindow"]:
        return [window for window in self._window_registry if not window._closed]

    def _window_for_id(self, window_id: str | None) -> "CMUXLinuxWindow":
        windows = self._active_windows()
        if window_id:
            for window in windows:
                if window.window_id == window_id:
                    return window
            raise ValueError(_("Window not found."))
        current_id = getattr(self._primary_window, "_current_window_id", self.window_id)
        for window in windows:
            if window.window_id == current_id:
                return window
        return windows[0] if windows else self._primary_window

    def _window_from_params(self, params: dict[str, Any]) -> "CMUXLinuxWindow":
        window_id = parse_ref(
            params.get("windowId") or params.get("window_id") or params.get("window_ref") or params.get("id"),
            "window",
        )
        return self._window_for_id(window_id or None)

    def _window_for_workspace_id(self, workspace_id: str) -> "CMUXLinuxWindow":
        for window in self._active_windows():
            if workspace_id in window.workspaces:
                return window
        raise ValueError(_("Workspace not found."))

    def _on_window_destroyed(self, *_args: Any) -> None:
        if self._closed:
            return
        self._stop_all_remote_proxy_processes()
        self._closed = True
        self._window_registry[:] = [window for window in self._window_registry if window is not self]
        active = self._active_windows()
        if active:
            self._primary_window._current_window_id = active[0].window_id
            return
        self.application.quit()

    def _install_theme_css(self) -> Gtk.CssProvider | None:
        provider = Gtk.CssProvider()
        try:
            provider.load_from_data(CMUX_LINUX_CSS.encode("utf-8"))
        except TypeError:
            provider.load_from_data(CMUX_LINUX_CSS)

        if Gdk is None:
            return provider
        if GTK_MAJOR >= 4:
            display = Gdk.Display.get_default()
            if display is not None:
                Gtk.StyleContext.add_provider_for_display(
                    display,
                    provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
                )
            return provider

        screen = Gdk.Screen.get_default() if hasattr(Gdk, "Screen") else None
        if screen is not None:
            Gtk.StyleContext.add_provider_for_screen(
                screen,
                provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
            )
        return provider

    def _add_css_class(self, widget: Gtk.Widget, class_name: str) -> None:
        if hasattr(widget, "add_css_class"):
            widget.add_css_class(class_name)
            return
        context = widget.get_style_context()
        if context is not None:
            context.add_class(class_name)

    def _remove_css_class(self, widget: Gtk.Widget, class_name: str) -> None:
        if hasattr(widget, "remove_css_class"):
            widget.remove_css_class(class_name)
            return
        context = widget.get_style_context()
        if context is not None:
            context.remove_class(class_name)

    def _rgba(self, color: str) -> Any | None:
        if Gdk is None:
            return None
        rgba = Gdk.RGBA()
        return rgba if rgba.parse(color) else None

    def _icon_theme_has_icon(self, icon_name: str) -> bool:
        if GTK_MAJOR >= 4:
            if Gdk is None:
                return False
            display = Gdk.Display.get_default()
            if display is None:
                return False
            theme = Gtk.IconTheme.get_for_display(display)
            return bool(theme.has_icon(icon_name))

        theme = Gtk.IconTheme.get_default()
        return bool(theme is not None and theme.has_icon(icon_name))

    def _resolve_icon_name(self, icon_names: str | tuple[str, ...]) -> str | None:
        candidates = (icon_names,) if isinstance(icon_names, str) else icon_names
        for icon_name in candidates:
            if self._icon_theme_has_icon(icon_name):
                return icon_name
        return candidates[0] if candidates else None

    def _build_window(self) -> Gtk.ApplicationWindow:
        window = Gtk.ApplicationWindow(application=self.application)
        self._add_css_class(window, "cmux-window")
        window.set_title(APP_NAME)
        window.set_default_size(DEFAULT_WIDTH, DEFAULT_HEIGHT)
        window.connect("destroy", self._on_window_destroyed)
        window.set_titlebar(self._build_header())
        content = self._build_content()
        if GTK_MAJOR >= 4:
            window.set_child(content)
        else:
            window.add(content)
        self._install_shortcut_controller(window)
        return window

    def _install_shortcut_controller(self, window: Gtk.ApplicationWindow) -> None:
        if Gdk is None:
            return
        if GTK_MAJOR >= 4:
            controller = Gtk.EventControllerKey()
            controller.connect("key-pressed", self._on_shortcut_key_pressed)
            window.add_controller(controller)
            self._shortcut_controller = controller
            return
        window.connect("key-press-event", self._on_shortcut_key_press_event)

    def _on_shortcut_key_pressed(self, _controller: Any, keyval: int, _keycode: int, state: Any) -> bool:
        return self._handle_shortcut_key_event(keyval, state)

    def _on_shortcut_key_press_event(self, _widget: Any, event: Any) -> bool:
        return self._handle_shortcut_key_event(event.keyval, event.state)

    def _handle_shortcut_key_event(self, keyval: int, state: Any) -> bool:
        token = self._shortcut_token_from_event(keyval, state)
        if not token:
            return False
        for binding in self.shortcuts.values():
            if binding.token == token:
                return self._run_shortcut_action(binding.action, token)
        return False

    def _shortcut_token_from_event(self, keyval: int, state: Any) -> str:
        key = self._key_name_from_keyval(keyval)
        if not key:
            return ""
        modifiers = self._shortcut_modifiers_from_state(state)
        if not modifiers:
            return ""
        ordered = [modifier for modifier in SHORTCUT_MODIFIER_ORDER if modifier in modifiers]
        return "+".join([*ordered, key])

    def _shortcut_modifiers_from_state(self, state: Any) -> set[str]:
        modifiers: set[str] = set()
        state_value = int(state)
        masks = getattr(Gdk, "ModifierType", None) if Gdk is not None else None
        if masks is None:
            return modifiers
        if state_value & int(masks.CONTROL_MASK):
            modifiers.add("ctrl")
        if state_value & int(masks.SHIFT_MASK):
            modifiers.add("shift")
        if state_value & int(masks.MOD1_MASK):
            modifiers.add("alt")
        for mask_name in ("META_MASK", "SUPER_MASK", "HYPER_MASK", "MOD4_MASK"):
            mask = getattr(masks, mask_name, None)
            if mask is not None and state_value & int(mask):
                modifiers.add("cmd")
        return modifiers

    def _key_name_from_keyval(self, keyval: int) -> str:
        if Gdk is None:
            return ""
        key_name = Gdk.keyval_name(keyval) or ""
        normalized = normalize_key_name(key_name)
        if len(normalized) == 1 or normalized in KEY_NAME_ALIASES.values():
            return normalized
        unicode_value = Gdk.keyval_to_unicode(keyval) if hasattr(Gdk, "keyval_to_unicode") else 0
        if unicode_value:
            character = chr(unicode_value)
            if character and character.strip():
                return normalize_key_name(character)
        return normalized

    def _run_shortcut_action(self, action: str, token: str) -> bool:
        if action.startswith("selectSurface"):
            return self._select_numbered_surface(token)
        if action.startswith("selectWorkspace"):
            return self._select_numbered_workspace(token)
        handlers: dict[str, Callable[[], Any]] = {
            "newSurface": lambda: self.create_surface(),
            "openBrowser": lambda: self.open_browser_from_params({}),
            "splitRight": lambda: self.split_surface_from_params({"orientation": "horizontal"}),
            "splitDown": lambda: self.split_surface_from_params({"orientation": "vertical"}),
            "closeTab": lambda: self.close_pane_from_params({}),
            "nextSurface": lambda: self._select_relative_surface(1),
            "previousSurface": lambda: self._select_relative_surface(-1),
            "nextSidebarTab": lambda: self._select_relative_surface(1),
            "previousSidebarTab": lambda: self._select_relative_surface(-1),
            "focusBrowserAddressBar": self._focus_current_browser_address,
            "browserBack": lambda: self.go_back_browser_from_params({}),
            "browserForward": lambda: self.go_forward_browser_from_params({}),
            "browserReload": lambda: self.reload_browser_from_params({}),
            "commandPalette": self._show_command_palette,
            "openSettings": lambda: self.open_settings_from_params({}),
        }
        handler = handlers.get(action)
        if handler is None:
            return False
        try:
            handler()
        except Exception:  # noqa: BLE001
            return False
        return True

    def _build_header(self) -> Gtk.HeaderBar:
        header = Gtk.HeaderBar()
        self._add_css_class(header, "cmux-header")
        self._pack_header_button(header, "tab-new-symbolic", _("New terminal"), lambda: self.create_surface())
        self._pack_header_button(
            header,
            ("view-split-left-right-symbolic", "view-dual-symbolic", "view-grid-symbolic"),
            _("Split horizontally"),
            lambda: self.split_surface_from_params({"orientation": "horizontal"}),
            fallback_label="||",
        )
        self._pack_header_button(
            header,
            ("view-split-top-bottom-symbolic", "view-grid-symbolic", "view-dual-symbolic"),
            _("Split vertically"),
            lambda: self.split_surface_from_params({"orientation": "vertical"}),
            fallback_label="=",
        )
        self._pack_header_button(header, "web-browser-symbolic", _("Open browser"), self.open_browser_from_params)
        self._pack_header_button(
            header,
            ("window-close-symbolic", "window-close"),
            _("Close pane"),
            lambda: self.close_pane_from_params({}),
            fallback_label="x",
            pack_end=True,
            css_classes=("cmux-close-button",),
        )
        return header

    def _pack_header_button(
        self,
        header: Gtk.HeaderBar,
        icon_names: str | tuple[str, ...],
        tooltip: str,
        callback: Callable[[], Any],
        fallback_label: str | None = None,
        pack_end: bool = False,
        css_classes: tuple[str, ...] = (),
    ) -> None:
        button = self._build_icon_button(icon_names, tooltip, fallback_label)
        self._add_css_class(button, "cmux-icon-button")
        self._add_css_class(button, "cmux-header-button")
        for css_class in css_classes:
            self._add_css_class(button, css_class)
        button.set_tooltip_text(tooltip)
        button.connect("clicked", lambda *_: callback())
        if pack_end and hasattr(header, "pack_end"):
            header.pack_end(button)
        else:
            header.pack_start(button)

    def _build_content(self) -> Gtk.Paned:
        self.sidebar.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self._sidebar_selection_handler_id = self.sidebar.connect("row-selected", self._on_sidebar_row_selected)
        self.sidebar.set_size_request(SIDEBAR_WIDTH, -1)

        paned = self._build_paned(Gtk.Orientation.HORIZONTAL, self.sidebar, self.stack)
        self._add_css_class(paned, "cmux-root")
        paned.set_position(SIDEBAR_WIDTH)
        return paned

    def identify(self) -> dict[str, Any]:
        browser_backend = f"webkit{WEBKIT_VERSION}" if WEBKIT_AVAILABLE else "unavailable"
        workspace = self._current_workspace()
        surface = self._current_surface()
        return {
            "app": "cmux",
            "platform": "linux",
            "backend": f"gtk{GTK_MAJOR}-vte",
            "browserBackend": browser_backend,
            "focused": {
                "workspace_id": workspace.id,
                "workspace_ref": f"workspace:{workspace.id}",
                "surface_id": surface.id,
                "surface_ref": f"surface:{surface.id}",
                "pane_id": surface.current_pane_id,
                "pane_ref": f"pane:{surface.current_pane_id}" if surface.current_pane_id else None,
            },
        }

    def capabilities(self) -> dict[str, Any]:
        unsupported = set(UNSUPPORTED_METHODS)
        remote_daemon = self._remote_daemon_installation_payload()
        auth_bridge = find_auth_bridge_binary()
        subsystems = build_subsystem_capabilities(
            auth_bridge_available=auth_bridge is not None,
            auth_detail=self._auth_backend_detail(auth_bridge),
            feedback_endpoint_configured=feedback_endpoint_url() is not None,
            remote_daemon=remote_daemon,
            browser_available=WEBKIT_AVAILABLE,
            browser_backend=f"webkit{WEBKIT_VERSION}" if WEBKIT_AVAILABLE else None,
            window_count=len(self._active_windows()),
            terminal_backend="vte",
        )
        return {
            "platform": "linux",
            "terminalBackend": "vte",
            "browserBackend": f"webkit{WEBKIT_VERSION}" if WEBKIT_AVAILABLE else None,
            "methods": list(SUPPORTED_METHODS),
            "unsupportedMethods": list(UNSUPPORTED_METHODS),
            "methodStatus": {
                method: "unsupported" if method in unsupported else "supported"
                for method in SUPPORTED_METHODS
            },
            "legacyAliases": dict(LEGACY_ALIASES),
            "distribution": "tarball",
            "features": list(FEATURE_FLAGS),
            "settings": {
                "path": str(self.settings_path),
                "loaded": bool(self.settings),
                "editable": True,
                "targets": ["general", "keyboardShortcuts"],
                "shortcuts": [binding.to_json() for binding in self.shortcuts.values()],
            },
            "state": {
                "path": str(self.state_path),
                "loaded": self.saved_session_snapshot is not None,
                "schemaVersion": LINUX_STATE_SCHEMA_VERSION,
                "restorable": self.saved_session_snapshot is not None,
            },
            "failureCodes": list(REQUIRED_FAILURE_CODES),
            "subsystems": subsystems,
            **subsystems,
            "remoteDaemon": remote_daemon,
            "limitations": [
                "macOS AppKit and Sparkle update features are not available on Linux.",
                "Advanced browser automation uses WebKitGTK and JavaScript emulation where native hooks are unavailable.",
                "Browser network route interception is recorded as route metadata on Linux and marked with backend limits.",
                "Auth uses the shared auth bridge when configured and falls back to Linux-local runtime state.",
                "Remote workspace APIs start SSH bootstrap/probe/proxy lifecycle when auto_connect is enabled.",
            ],
        }

    def system_tree_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace_id = parse_ref(
            params.get("workspaceId") or params.get("workspace_id") or params.get("workspace_ref"),
            "workspace",
        )
        windows = []
        for index, window in enumerate(self._active_windows()):
            window_workspaces = [
                window._tree_workspace_node(workspace, workspace_index)
                for workspace_index, workspace in enumerate(window.workspaces.values())
                if not workspace_id or workspace.id == workspace_id
            ]
            if window_workspaces:
                windows.append({**window._window_payload(index), "workspaces": window_workspaces})
        if workspace_id and not windows:
            raise ValueError(_("Workspace not found."))
        return {
            "active": self._focused_context_payload(),
            "caller": params.get("caller"),
            "windows": windows,
        }

    def list_windows(self) -> dict[str, Any]:
        return {
            "windows": [
                window._window_payload(index)
                for index, window in enumerate(self._active_windows())
            ]
        }

    def current_window_snapshot(self) -> dict[str, Any]:
        window = self._window_for_id(None)
        payload = window._window_payload(self._active_windows().index(window))
        return {**payload, "window": payload, "focused": window._focused_context_payload()}

    def focus_window_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        window = self._window_from_params(params)
        window.window.present()
        window._mark_current_window()
        surface = window._current_surface()
        pane = surface.panes.get(surface.current_pane_id or "")
        if pane is not None and hasattr(pane.widget, "grab_focus"):
            pane.widget.grab_focus()
        return {**window._window_payload(self._active_windows().index(window)), "focused": True}

    def create_window_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        cwd = str(params.get("cwd") or self._current_surface().cwd or Path.cwd())
        command = params.get("command")
        if command is not None and not isinstance(command, str):
            raise ValueError(_("command must be a string."))
        window = CMUXLinuxWindow(
            self.application,
            cwd,
            command,
            window_id=f"linux-window-{uuid.uuid4().hex[:12]}",
            primary_window=self._primary_window,
            window_registry=self._window_registry,
            owns_runtime_state=False,
            local_socket_path=self.local_socket_path,
        )
        window.show_without_focus()
        payload = window._window_payload(self._active_windows().index(window))
        return {**payload, "created": True, "reused": False, "focus_side_effect": False}

    def close_window_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        window = self._window_from_params(params)
        payload = window._window_payload(self._active_windows().index(window))
        last_window = len(self._active_windows()) <= 1
        window._stop_all_remote_proxy_processes()
        window._closed = True
        self._window_registry[:] = [item for item in self._window_registry if item is not window]
        if hasattr(window.window, "close"):
            window.window.close()
        elif hasattr(window.window, "destroy"):
            window.window.destroy()
        if last_window:
            GLib.idle_add(self.application.quit)
            return {**payload, "accepted": True, "closed": True, "app_quit": True}
        remaining = self._active_windows()
        if remaining:
            self._primary_window._current_window_id = remaining[0].window_id
        return {**payload, "accepted": True, "closed": True, "app_quit": False}

    def set_app_focus_override_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        if "state" in params:
            state = str(params.get("state") or "").lower()
            if state == "active":
                self.focus_override = True
            elif state == "inactive":
                self.focus_override = False
            elif state in {"clear", "none"}:
                self.focus_override = None
            else:
                raise ValueError(_("Invalid state (active|inactive|clear)."))
        elif "focused" in params:
            focused = params.get("focused")
            self.focus_override = focused if isinstance(focused, bool) else None
        else:
            raise ValueError(_("Missing state or focused."))
        return {"override": self.focus_override, "active": self._app_is_active()}

    def simulate_app_active(self) -> dict[str, Any]:
        self.simulated_active_at = time.time()
        return {"active": True, "simulated": True, "simulated_at": self.simulated_active_at}

    def _window_payload(self, index: int) -> dict[str, Any]:
        workspace = self._current_workspace()
        surface = self._current_surface()
        current_id = getattr(self._primary_window, "_current_window_id", self.window_id)
        is_current = self.window_id == current_id
        visible = self._window_visible()
        workspace_ids = list(self.workspaces.keys())
        return {
            "id": self.window_id,
            "ref": self._window_ref(),
            "window_id": self.window_id,
            "window_ref": self._window_ref(),
            "index": index,
            "key": self.window_id,
            "visible": visible,
            "visibility_state": "visible" if visible else "hidden",
            "is_current": is_current,
            "focus_state": "current" if is_current else "background",
            "last_window_policy": "quit_app",
            "active": self._app_is_active(),
            "workspace_count": len(self.workspaces),
            "workspace_ids": workspace_ids,
            "workspace_refs": [f"workspace:{workspace_id}" for workspace_id in workspace_ids],
            "current_workspace_id": workspace.id,
            "current_workspace_ref": f"workspace:{workspace.id}",
            "selected_workspace_id": workspace.id,
            "selected_workspace_ref": f"workspace:{workspace.id}",
            "focused_surface_id": surface.id,
            "focused_surface_ref": f"surface:{surface.id}",
            "focused_pane_id": surface.current_pane_id,
            "focused_pane_ref": f"pane:{surface.current_pane_id}" if surface.current_pane_id else None,
        }

    def _window_ref(self) -> str:
        return f"window:{self.window_id}"

    def _window_visible(self) -> bool:
        if hasattr(self.window, "is_visible"):
            return bool(self.window.is_visible())
        if hasattr(self.window, "get_visible"):
            return bool(self.window.get_visible())
        return True

    def _app_is_active(self) -> bool:
        if self.focus_override is not None:
            return self.focus_override
        if self.simulated_active_at is not None and time.time() - self.simulated_active_at < 5:
            return True
        if hasattr(self.window, "is_active"):
            return bool(self.window.is_active())
        return self._window_visible()

    def _require_current_window(self, params: dict[str, Any]) -> None:
        window_id = parse_ref(
            params.get("windowId") or params.get("window_id") or params.get("window_ref") or params.get("id"),
            "window",
        )
        if window_id and window_id != self.window_id:
            raise ValueError(_("Window not found."))

    def _focused_context_payload(self) -> dict[str, Any]:
        workspace = self._current_workspace()
        surface = self._current_surface()
        return {
            "window_id": self.window_id,
            "window_ref": self._window_ref(),
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "pane_id": surface.current_pane_id,
            "pane_ref": f"pane:{surface.current_pane_id}" if surface.current_pane_id else None,
        }

    def _tree_workspace_node(self, workspace: Workspace, index: int) -> dict[str, Any]:
        return {
            "id": workspace.id,
            "ref": f"workspace:{workspace.id}",
            "index": index,
            "title": workspace.name,
            "description": None,
            "selected": workspace.id == self.current_workspace_id,
            "pinned": False,
            "panes": self._tree_pane_nodes(workspace),
        }

    def _tree_pane_nodes(self, workspace: Workspace) -> list[dict[str, Any]]:
        nodes: list[dict[str, Any]] = []
        for surface_index, surface in enumerate(workspace.surfaces.values()):
            for pane_index, pane in enumerate(surface.panes.values()):
                nodes.append(self._tree_pane_node(workspace, surface, pane, surface_index, pane_index))
        return nodes

    def _tree_pane_node(
        self,
        workspace: Workspace,
        surface: Surface,
        pane: Pane,
        surface_index: int,
        pane_index: int,
    ) -> dict[str, Any]:
        surface_item = self._tree_surface_item(workspace, surface, pane, surface_index)
        return {
            "id": pane.id,
            "ref": f"pane:{pane.id}",
            "index": pane_index,
            "focused": surface.current_pane_id == pane.id and workspace.id == self.current_workspace_id,
            "surface_ids": [surface.id],
            "surface_refs": [f"surface:{surface.id}"],
            "selected_surface_id": surface.id,
            "selected_surface_ref": f"surface:{surface.id}",
            "surface_count": 1,
            "surfaces": [surface_item],
        }

    def _tree_surface_item(
        self,
        workspace: Workspace,
        surface: Surface,
        pane: Pane,
        surface_index: int,
    ) -> dict[str, Any]:
        selected = surface.id == workspace.current_surface_id
        focused = selected and workspace.id == self.current_workspace_id and pane.id == surface.current_pane_id
        return {
            "id": surface.id,
            "ref": f"surface:{surface.id}",
            "index": surface_index,
            "type": pane.kind,
            "title": pane.title or surface.title,
            "focused": focused,
            "selected": selected,
            "selected_in_pane": True,
            "pane_id": pane.id,
            "pane_ref": f"pane:{pane.id}",
            "index_in_pane": 0,
            "tty": self.surface_tty_names.get(surface.id),
            "url": pane.url,
        }

    def open_settings_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        target = self._settings_target(params.get("target"))
        self._show_settings_dialog(target)
        return {"opened": True, "target": target, "path": str(self.settings_path)}

    def create_workspace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        name = str(params.get("name") or _("Workspace"))
        cwd = str(params.get("cwd") or os.getcwd())
        command = params.get("command")
        select = bool(params.get("select") or params.get("focus") or params.get("activate"))
        color = normalize_workspace_color(params.get("color") or params.get("custom_color") or params.get("customColor"))
        if any(key in params for key in ("color", "custom_color", "customColor")) and color is None:
            raise ValueError(_("Invalid workspace color."))
        workspace = self.create_workspace(
            name,
            cwd,
            str(command) if command else None,
            select=select,
            description=normalize_workspace_description(
                params.get("description") or params.get("custom_description") or params.get("customDescription")
            ),
            custom_color=color,
            is_pinned=bool(params.get("pinned") or params.get("is_pinned") or params.get("isPinned")),
        )
        return workspace.snapshot()

    def create_workspace(
        self,
        name: str,
        cwd: str,
        command: str | None = None,
        select: bool = True,
        description: str | None = None,
        custom_color: str | None = None,
        is_pinned: bool = False,
    ) -> Workspace:
        workspace = Workspace(
            id=str(uuid.uuid4()),
            name=name,
            description=description,
            custom_color=custom_color,
            is_pinned=is_pinned,
        )
        self.workspaces = {**self.workspaces, workspace.id: workspace}
        if workspace.is_pinned:
            self._reorder_workspace_for_pinned_state(workspace)
        self.create_surface(cwd=cwd, command=command, workspace_id=workspace.id, select=select)
        if select or self.current_workspace_id is None:
            self._set_current_workspace_id(workspace.id)
        self._save_runtime_state()
        return workspace

    def create_surface_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        cwd = str(params.get("cwd") or os.getcwd())
        command = params.get("command")
        workspace_id = parse_ref(params.get("workspace_id") or params.get("workspaceId") or params.get("workspace_ref"), "workspace")
        select = not any(key in params for key in ("select", "focus", "activate")) or bool(
            params.get("select") or params.get("focus") or params.get("activate")
        )
        surface = self.create_surface(
            cwd=cwd,
            command=str(command) if command else None,
            workspace_id=workspace_id or None,
            select=select,
        )
        return surface.snapshot().to_json()

    def create_surface(
        self,
        cwd: str | None = None,
        command: str | None = None,
        workspace_id: str | None = None,
        select: bool = True,
    ) -> Surface:
        workspace = self._workspace_from_id(workspace_id) if workspace_id else self._current_workspace()
        surface_id = str(uuid.uuid4())
        surface_cwd = cwd or os.getcwd()
        pane = self._build_terminal_pane(surface_id, surface_cwd, command)
        surface = Surface(
            id=surface_id,
            title=terminal_title(command, surface_cwd),
            cwd=surface_cwd,
            root_widget=pane.widget,
            panes={pane.id: pane},
            current_pane_id=pane.id,
        )
        workspace.surfaces = {**workspace.surfaces, surface.id: surface}
        self.stack.add_titled(surface.root_widget, surface.id, surface.title)
        if workspace.current_surface_id is None:
            workspace.current_surface_id = surface.id
        if select:
            self._set_current_workspace_id(workspace.id)
            workspace.current_surface_id = surface.id
            self.stack.set_visible_child_name(surface.id)
            self.refresh_sidebar()
        self._save_runtime_state()
        return surface

    def split_surface_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        kind = str(params.get("kind") or params.get("type") or "terminal")
        if kind in {"browser", "web", "url"}:
            return self.open_browser_from_params(params)

        surface = self._current_surface()
        cwd = str(params.get("cwd") or surface.cwd or os.getcwd())
        command = params.get("command")
        pane = self._build_terminal_pane(surface.id, cwd, str(command) if command else None)
        return self._split_surface(surface, pane, params)

    def open_browser_from_params(self, params: dict[str, Any] | None = None) -> dict[str, Any]:
        safe_params = params or {}
        surface = self._current_surface()
        url = normalize_url(str(safe_params.get("url") or DEFAULT_BROWSER_URL))
        pane = self._build_browser_pane(surface.id, url)
        return self._split_surface(surface, pane, safe_params)

    def open_browser_split_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        result = self.open_browser_from_params(params)
        surface = result.get("surface") or {}
        pane = result.get("pane") or {}
        return {
            **result,
            "surface_id": surface.get("id"),
            "surface_ref": f"surface:{surface.get('id')}" if surface.get("id") else None,
            "pane_id": pane.get("id"),
            "pane_ref": f"pane:{pane.get('id')}" if pane.get("id") else None,
            "url": pane.get("url"),
        }

    def open_markdown_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        raw_path = str(params.get("path") or "").strip()
        if not raw_path:
            raise ValueError(_("Missing 'path' parameter."))
        path = Path(raw_path).expanduser()
        if not path.is_absolute():
            path = Path(os.getcwd()) / path
        path = path.resolve()
        if not path.exists():
            raise ValueError(_("File not found."))
        if not path.is_file():
            raise ValueError(_("Path is not a file."))
        if not os.access(path, os.R_OK):
            raise PermissionError(_("File not readable."))

        source_surface = self._surface_from_params(params)
        source_workspace = self._workspace_for_surface(source_surface.id)
        source_pane_id = source_surface.current_pane_id
        pane = self._build_browser_pane(source_surface.id, markdown_preview_url(path))
        pane.title = path.name
        result = self._split_surface(source_surface, pane, params)
        surface = result.get("surface") or {}
        target_pane = result.get("pane") or {}
        return {
            **result,
            "workspace_id": source_workspace.id,
            "workspace_ref": f"workspace:{source_workspace.id}",
            "surface_id": surface.get("id"),
            "surface_ref": f"surface:{surface.get('id')}" if surface.get("id") else None,
            "pane_id": target_pane.get("id"),
            "pane_ref": f"pane:{target_pane.get('id')}" if target_pane.get("id") else None,
            "source_surface_id": source_surface.id,
            "source_surface_ref": f"surface:{source_surface.id}",
            "source_pane_id": source_pane_id,
            "source_pane_ref": f"pane:{source_pane_id}" if source_pane_id else None,
            "target_pane_id": target_pane.get("id"),
            "target_pane_ref": f"pane:{target_pane.get('id')}" if target_pane.get("id") else None,
            "path": str(path),
        }

    def _split_surface(self, surface: Surface, pane: Pane, params: dict[str, Any]) -> dict[str, Any]:
        orientation = self._orientation_from_params(params)
        old_root = surface.root_widget
        self._remove_stack_child(old_root)
        new_root = self._build_paned(orientation, old_root, pane.widget)
        surface.root_widget = new_root
        surface.panes = {**surface.panes, pane.id: pane}
        self._set_current_pane_id(surface, pane.id)
        workspace = self._workspace_for_surface(surface.id)
        self._set_current_workspace_id(workspace.id)
        workspace.current_surface_id = surface.id
        self.stack.add_titled(surface.root_widget, surface.id, surface.title)
        self.stack.set_visible_child_name(surface.id)
        if GTK_MAJOR < 4:
            surface.root_widget.show_all()
        self.refresh_sidebar()
        self._save_runtime_state()
        return {"surface": surface.snapshot().to_json(), "pane": pane.snapshot().to_json()}

    def _orientation_from_params(self, params: dict[str, Any]) -> Gtk.Orientation:
        value = str(params.get("orientation") or params.get("direction") or "horizontal").lower()
        if value in {"vertical", "top", "bottom", "up", "down"}:
            return Gtk.Orientation.VERTICAL
        return Gtk.Orientation.HORIZONTAL

    def _workspace_payload(self, workspace: Workspace) -> dict[str, Any]:
        workspace_ids = list(self.workspaces.keys())
        index = workspace_ids.index(workspace.id) if workspace.id in workspace_ids else None
        snapshot = workspace.snapshot()
        return {
            **snapshot,
            "index": index,
            "selected": workspace.id == self.current_workspace_id,
            "remote": self._remote_status_payload(workspace),
        }

    def list_workspaces(self) -> dict[str, Any]:
        return {"workspaces": [self._workspace_payload(workspace) for workspace in self.workspaces.values()]}

    def current_workspace_snapshot(self) -> dict[str, Any]:
        snapshot = self._workspace_payload(self._current_workspace())
        return {**snapshot, "workspace": snapshot}

    def move_workspace_to_window_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        safe_params = params or {}
        workspace_id = parse_ref(
            safe_params.get("workspaceId")
            or safe_params.get("workspace_id")
            or safe_params.get("workspace_ref")
            or safe_params.get("id"),
            "workspace",
        )
        source_window = self._window_for_workspace_id(workspace_id) if workspace_id else self._window_for_id(None)
        workspace = source_window._workspace_from_command_params(safe_params, allow_index=True)
        target_window_id = parse_ref(
            safe_params.get("target_window_id")
            or safe_params.get("targetWindowId")
            or safe_params.get("target_window_ref")
            or safe_params.get("window_id")
            or safe_params.get("windowId")
            or safe_params.get("window_ref"),
            "window",
        )
        target_window = self._window_for_id(target_window_id or None)
        source_index = self._active_windows().index(source_window)
        target_index = self._active_windows().index(target_window)
        if source_window is target_window:
            snapshot = source_window._workspace_payload(workspace)
            return {
                "accepted": True,
                "moved": False,
                "reason": "already_in_window",
                "source_window": source_window._window_payload(source_index),
                "target_window": target_window._window_payload(target_index),
                "window": target_window._window_payload(target_index),
                "workspace": snapshot,
                "workspace_id": workspace.id,
                "workspace_ref": f"workspace:{workspace.id}",
                "focus_side_effect": False,
            }
        source_workspace_ids = list(source_window.workspaces.keys())
        moved_index = source_workspace_ids.index(workspace.id)
        source_was_current = workspace.id == source_window.current_workspace_id
        for surface in workspace.surfaces.values():
            source_window._remove_stack_child(surface.root_widget)
            target_window.stack.add_titled(surface.root_widget, surface.id, surface.title)
            if GTK_MAJOR < 4:
                surface.root_widget.show_all()
        source_window.workspaces = {
            key: value for key, value in source_window.workspaces.items() if key != workspace.id
        }
        target_window.workspaces = {**target_window.workspaces, workspace.id: workspace}
        if source_window.previous_workspace_id == workspace.id:
            source_window.previous_workspace_id = None
        if target_window.previous_workspace_id == workspace.id:
            target_window.previous_workspace_id = None
        if source_was_current or source_window.current_workspace_id not in source_window.workspaces:
            source_window._current_workspace_after_close(moved_index, source_was_current)
        else:
            source_window.refresh_sidebar()
            source_window._save_runtime_state()
        should_select_target = bool(
            safe_params.get("select") or safe_params.get("focus") or safe_params.get("activate")
        )
        if target_window.current_workspace_id is None or should_select_target:
            target_window._set_current_workspace_id(workspace.id)
            if workspace.current_surface_id:
                target_window.stack.set_visible_child_name(workspace.current_surface_id)
        target_window.refresh_sidebar()
        target_window._save_runtime_state()
        snapshot = target_window._workspace_payload(workspace)
        return {
            "accepted": True,
            "moved": True,
            "reason": "moved_to_window",
            "source_window": source_window._window_payload(source_index),
            "target_window": target_window._window_payload(target_index),
            "window": target_window._window_payload(target_index),
            "workspace": snapshot,
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "focus_side_effect": False,
        }

    def select_workspace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_command_params(params, allow_index=True)
        snapshot = self._select_workspace(workspace)
        return {**snapshot, "workspace": snapshot}

    def close_workspace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_command_params(params or {}, allow_index=True)
        workspace_ids = list(self.workspaces.keys())
        closed_index = workspace_ids.index(workspace.id)
        was_current = workspace.id == self.current_workspace_id
        if len(workspace_ids) <= 1:
            current = self._workspace_payload(workspace)
            return {
                "accepted": True,
                "closed": False,
                "workspace_id": workspace.id,
                "workspace_ref": f"workspace:{workspace.id}",
                "currentWorkspace": current,
                "current_workspace": current,
            }
        for surface in workspace.surfaces.values():
            self._remove_stack_child(surface.root_widget)
        self.workspaces = {key: value for key, value in self.workspaces.items() if key != workspace.id}
        if self.previous_workspace_id == workspace.id:
            self.previous_workspace_id = None
        current = self._current_workspace_after_close(closed_index, was_current)
        self.refresh_sidebar()
        self._save_runtime_state()
        return {
            "accepted": True,
            "closed": True,
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "currentWorkspace": current,
            "current_workspace": current,
        }

    def reorder_workspace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_command_params(params or {}, allow_index=False)
        ordered = [item for item in self.workspaces.items() if item[0] != workspace.id]
        target_index = self._workspace_reorder_index(params or {}, ordered)
        target_index = max(0, min(target_index, len(ordered)))
        ordered.insert(target_index, (workspace.id, workspace))
        self.workspaces = dict(ordered)
        self.refresh_sidebar()
        self._save_runtime_state()
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "index": target_index,
        }

    def select_relative_workspace(self, offset: int) -> dict[str, Any]:
        workspace_ids = list(self.workspaces.keys())
        if not workspace_ids:
            raise ValueError(_("Workspace not found."))
        current_id = self.current_workspace_id or workspace_ids[0]
        current_index = workspace_ids.index(current_id) if current_id in workspace_ids else 0
        workspace = self.workspaces[workspace_ids[(current_index + offset) % len(workspace_ids)]]
        snapshot = self._select_workspace(workspace)
        return {**snapshot, "workspace": snapshot}

    def select_last_workspace(self) -> dict[str, Any]:
        if self.previous_workspace_id is None or self.previous_workspace_id not in self.workspaces:
            raise ValueError(_("No previous workspace in history."))
        workspace = self.workspaces[self.previous_workspace_id]
        snapshot = self._select_workspace(workspace)
        return {**snapshot, "workspace": snapshot}

    def equalize_workspace_splits_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        safe_params = params or {}
        workspace = self._workspace_from_command_params(safe_params, allow_index=True)
        equalized = False
        for surface in workspace.surfaces.values():
            equalized = self._equalize_split_widget(surface.root_widget, safe_params.get("orientation")) or equalized
        return {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "equalized": equalized,
        }

    def rename_workspace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        name = str(params.get("name") or params.get("title") or "").strip()
        if not name:
            raise ValueError(_("Missing workspace name."))
        workspace.name = name
        self._save_runtime_state()
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "name": workspace.name,
            "title": workspace.name,
        }

    def clear_workspace_name_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        workspace.name = _("Workspace")
        self.refresh_sidebar()
        self._save_runtime_state()
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "name": workspace.name,
            "title": workspace.name,
        }

    def set_workspace_pinned_from_params(self, params: dict[str, Any], pinned: bool) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        workspace.is_pinned = pinned
        self._reorder_workspace_for_pinned_state(workspace)
        self.refresh_sidebar()
        self._save_runtime_state()
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "pinned": workspace.is_pinned,
            "is_pinned": workspace.is_pinned,
        }

    def set_workspace_description_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        description = normalize_workspace_description(params.get("description") or params.get("customDescription"))
        if description is None:
            raise ValueError(_("Missing workspace description."))
        workspace.description = description
        self._save_runtime_state()
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "description": workspace.description,
            "custom_description": workspace.description,
        }

    def clear_workspace_description_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        workspace.description = None
        self._save_runtime_state()
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "description": None,
            "custom_description": None,
        }

    def set_workspace_color_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        color = normalize_workspace_color(params.get("color") or params.get("customColor") or params.get("custom_color"))
        if color is None:
            raise ValueError(_("Invalid workspace color."))
        workspace.custom_color = color
        self._save_runtime_state()
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "color": workspace.custom_color,
            "custom_color": workspace.custom_color,
        }

    def clear_workspace_color_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        workspace.custom_color = None
        self._save_runtime_state()
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "color": None,
            "custom_color": None,
        }

    def move_workspace_from_action(self, params: dict[str, Any], action: str) -> dict[str, Any]:
        workspace = self._workspace_from_command_params(params or {}, allow_index=True)
        workspace_ids = list(self.workspaces.keys())
        current_index = workspace_ids.index(workspace.id)
        if action == "move_top":
            target_index = 0
        elif action == "move_up":
            target_index = max(0, current_index - 1)
        else:
            target_index = min(len(workspace_ids) - 1, current_index + 1)
        if target_index == current_index:
            return {
                "workspace": self._workspace_payload(workspace),
                "workspace_id": workspace.id,
                "workspace_ref": f"workspace:{workspace.id}",
                "index": current_index,
                "moved": False,
            }
        result = self.reorder_workspace_from_params({"workspace_id": workspace.id, "index": target_index})
        return {**result, "moved": True}

    def close_workspaces_from_action(self, params: dict[str, Any], action: str) -> dict[str, Any]:
        workspace = self._workspace_from_command_params(params or {}, allow_index=True)
        workspace_items = list(self.workspaces.items())
        workspace_index = [key for key, _item in workspace_items].index(workspace.id)
        if action == "close_others":
            candidates = [item for item in workspace_items if item[0] != workspace.id and not item[1].is_pinned]
        elif action == "close_above":
            candidates = [item for item in workspace_items[:workspace_index] if not item[1].is_pinned]
        else:
            candidates = [item for item in workspace_items[workspace_index + 1 :] if not item[1].is_pinned]
        closed_ids = {key for key, _item in candidates}
        for _key, candidate in candidates:
            for surface in candidate.surfaces.values():
                self._remove_stack_child(surface.root_widget)
        self.workspaces = {key: value for key, value in self.workspaces.items() if key not in closed_ids}
        if self.current_workspace_id in closed_ids:
            self._set_current_workspace_id(workspace.id)
            if workspace.current_surface_id:
                self.stack.set_visible_child_name(workspace.current_surface_id)
        if self.previous_workspace_id in closed_ids:
            self.previous_workspace_id = None
        self.refresh_sidebar()
        self._save_runtime_state()
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "closed": len(candidates),
            "closed_workspace_ids": sorted(closed_ids),
        }

    def mark_workspace_notifications_from_params(self, params: dict[str, Any], read: bool) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        changed = 0
        notifications: list[LinuxNotification] = []
        for notification in self.notifications:
            if notification.workspace_id == workspace.id and notification.is_read != read:
                notifications.append(replace(notification, is_read=read))
                changed += 1
            else:
                notifications.append(notification)
        self.notifications = notifications
        return {
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "marked_read": read,
            "updated": changed,
        }

    def workspace_action_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        action = normalize_workspace_action(params.get("action"))
        if action == "rename":
            return self.rename_workspace_from_params(params)
        if action == "clear_name":
            return self.clear_workspace_name_from_params(params)
        if action in {"pin", "unpin"}:
            return self.set_workspace_pinned_from_params(params, action == "pin")
        if action == "set_description":
            return self.set_workspace_description_from_params(params)
        if action == "clear_description":
            return self.clear_workspace_description_from_params(params)
        if action == "set_color":
            return self.set_workspace_color_from_params(params)
        if action == "clear_color":
            return self.clear_workspace_color_from_params(params)
        if action in {"move_up", "move_down", "move_top"}:
            return self.move_workspace_from_action(params, action)
        if action in {"close_others", "close_above", "close_below"}:
            return self.close_workspaces_from_action(params, action)
        if action in {"mark_read", "mark_unread"}:
            return self.mark_workspace_notifications_from_params(params, action == "mark_read")
        if action in {"select", "focus"}:
            return self.select_workspace_from_params(params)
        if action in {"create", "new"}:
            return self.create_workspace_from_params(params)
        if action == "close":
            return self.close_workspace_from_params(params)
        if action == "reorder":
            return self.reorder_workspace_from_params(params)
        if action == "next":
            return self.select_relative_workspace(1)
        if action in {"previous", "prev"}:
            return self.select_relative_workspace(-1)
        if action == "last":
            return self.select_last_workspace()
        if action in {"equalize_splits", "equalize"}:
            return self.equalize_workspace_splits_from_params(params)
        raise ValueError(
            _("Unsupported workspace action.") + f" supported_actions={','.join(MACOS_WORKSPACE_ACTIONS)}"
        )

    def list_surfaces(self, params: dict[str, Any] | None = None) -> dict[str, Any]:
        workspace = self._workspace_from_params(params or {})
        surfaces = []
        for surface in workspace.surfaces.values():
            snapshot = surface.snapshot().to_json()
            surfaces.append({**snapshot, "focused": surface.id == workspace.current_surface_id})
        return {"surfaces": surfaces}

    def current_surface_snapshot(self, params: dict[str, Any] | None = None) -> dict[str, Any]:
        workspace = self._workspace_from_params(params or {})
        surface = self._surface_for_workspace(workspace)
        snapshot = surface.snapshot().to_json()
        return {**snapshot, "surface": snapshot}

    def select_surface_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref") or params.get("id"),
            "surface",
        )
        workspace = self._workspace_for_surface(surface_id)
        surface = workspace.surfaces[surface_id]
        self._set_current_workspace_id(workspace.id)
        self.select_surface(surface.id)
        self.refresh_sidebar()
        return {"surface": surface.snapshot().to_json()}

    def focus_surface_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self.select_surface_from_params(params)

    def close_surface_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref") or params.get("id"),
            "surface",
        )
        surface_id = surface_id or self._current_surface().id
        workspace = self._workspace_for_surface(surface_id)
        surface = workspace.surfaces[surface_id]
        was_current_workspace = workspace.id == self.current_workspace_id
        was_current_surface = workspace.current_surface_id == surface_id
        self._remove_stack_child(surface.root_widget)
        workspace.surfaces = {key: value for key, value in workspace.surfaces.items() if key != surface_id}
        if was_current_surface:
            workspace.current_surface_id = next(iter(workspace.surfaces), None)
        if workspace.current_surface_id is None:
            current_surface = self.create_surface(workspace_id=workspace.id, select=was_current_workspace)
        else:
            current_surface = workspace.surfaces[workspace.current_surface_id]
            if was_current_workspace:
                self.stack.set_visible_child_name(current_surface.id)
        if was_current_workspace:
            self._set_current_workspace_id(workspace.id)
        self.refresh_sidebar()
        self._save_runtime_state()
        return {"closedSurfaceId": surface_id, "currentSurface": current_surface.snapshot().to_json()}

    def reorder_surface_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface = self._surface_from_params(params or {})
        workspace = self._workspace_for_surface(surface.id)
        ordered = [item for item in workspace.surfaces.items() if item[0] != surface.id]
        target_index = self._surface_reorder_index(params or {}, ordered, require_target=True)
        target_index = max(0, min(target_index, len(ordered)))
        ordered.insert(target_index, (surface.id, surface))
        workspace.surfaces = dict(ordered)
        self.refresh_sidebar()
        self._save_runtime_state()
        return self._surface_command_payload(workspace, surface, target_index)

    def move_surface_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        safe_params = params or {}
        if safe_params.get("window_id") or safe_params.get("windowId") or safe_params.get("window_ref"):
            raise ValueError(_("window_id is not supported on Linux."))
        surface = self._surface_from_any_workspace(safe_params)
        source_workspace = self._workspace_for_surface(surface.id)
        pane_id = parse_ref(safe_params.get("paneId") or safe_params.get("pane_id") or safe_params.get("pane_ref"), "pane")
        if pane_id:
            target_surface, _target_pane = self._pane_from_param_keys(safe_params, ("paneId", "pane_id", "pane_ref"))
            direction = self._surface_split_direction(safe_params)
            focus = self._bool_param(safe_params, "focus", False)
            return self._move_single_surface_to_split(surface, target_surface, direction, focus)

        workspace_id = parse_ref(
            safe_params.get("workspaceId") or safe_params.get("workspace_id") or safe_params.get("workspace_ref"),
            "workspace",
        )
        destination_workspace = self._workspace_from_id(workspace_id or source_workspace.id)
        focus = self._bool_param(safe_params, "focus", False)
        has_reorder_target = self._has_surface_reorder_target(safe_params)
        if destination_workspace.id == source_workspace.id:
            if not has_reorder_target:
                index = list(source_workspace.surfaces.keys()).index(surface.id)
                return self._surface_command_payload(source_workspace, surface, index)
            return self.reorder_surface_from_params({**safe_params, "surface_id": surface.id})

        source_was_current_workspace = source_workspace.id == self.current_workspace_id
        source_workspace.surfaces = {
            key: value for key, value in source_workspace.surfaces.items() if key != surface.id
        }
        if source_workspace.current_surface_id == surface.id:
            source_workspace.current_surface_id = next(iter(source_workspace.surfaces), None)
        destination_items = [item for item in destination_workspace.surfaces.items() if item[0] != surface.id]
        target_index = self._surface_reorder_index(safe_params, destination_items, require_target=False)
        target_index = max(0, min(target_index, len(destination_items)))
        destination_items.insert(target_index, (surface.id, surface))
        destination_workspace.surfaces = dict(destination_items)
        if destination_workspace.current_surface_id is None or focus:
            destination_workspace.current_surface_id = surface.id
        self._ensure_workspace_surface(source_workspace)
        if focus:
            self._set_current_workspace_id(destination_workspace.id)
            destination_workspace.current_surface_id = surface.id
            self.stack.set_visible_child_name(surface.id)
        elif source_was_current_workspace and source_workspace.current_surface_id:
            self.stack.set_visible_child_name(source_workspace.current_surface_id)
        self.refresh_sidebar()
        return {
            **self._surface_command_payload(destination_workspace, surface, target_index),
            "source_workspace_id": source_workspace.id,
            "source_workspace_ref": f"workspace:{source_workspace.id}",
        }

    def drag_surface_to_split_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        safe_params = params or {}
        source_surface = self._surface_from_any_workspace(safe_params)
        target_surface_id = parse_ref(
            safe_params.get("targetSurfaceId") or safe_params.get("target_surface_id") or safe_params.get("target_surface_ref"),
            "surface",
        )
        target_pane_id = parse_ref(
            safe_params.get("targetPaneId") or safe_params.get("target_pane_id") or safe_params.get("target_pane_ref"),
            "pane",
        )
        if target_surface_id:
            target_surface = self._workspace_for_surface(target_surface_id).surfaces[target_surface_id]
        elif target_pane_id:
            target_surface, _target_pane = self._pane_from_param_keys(
                safe_params,
                ("targetPaneId", "target_pane_id", "target_pane_ref"),
            )
        else:
            target_surface = self._current_surface()
        direction = self._surface_split_direction(safe_params)
        focus = self._bool_param(safe_params, "focus", False)
        return self._move_single_surface_to_split(source_surface, target_surface, direction, focus)

    def refresh_surfaces_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params or {})
        refreshed = 0
        for surface in workspace.surfaces.values():
            if hasattr(surface.root_widget, "queue_draw"):
                surface.root_widget.queue_draw()
            for pane in surface.panes.values():
                if hasattr(pane.widget, "queue_draw"):
                    pane.widget.queue_draw()
                if pane.kind == "terminal":
                    refreshed += 1
        return {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "refreshed": refreshed,
        }

    def surface_health_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params or {})
        surfaces = []
        for index, surface in enumerate(workspace.surfaces.values()):
            surfaces.append(
                {
                    "index": index,
                    "id": surface.id,
                    "ref": f"surface:{surface.id}",
                    "surface_id": surface.id,
                    "surface_ref": f"surface:{surface.id}",
                    "type": self._surface_type(surface),
                    "in_window": self._widget_in_window(surface.root_widget),
                    "focused": surface.id == workspace.current_surface_id,
                    "pane_count": len(surface.panes),
                }
            )
        return {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "surfaces": surfaces,
        }

    def trigger_surface_flash_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface = self._surface_from_params(params or {})
        workspace = self._workspace_for_surface(surface.id)
        self._flash_widget(surface.root_widget)
        row = self._sidebar_row_for_surface(surface.id)
        if row is not None:
            self._flash_widget(row)
        return {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "flashed": True,
        }

    def report_tty_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params or {})
        surface = self._surface_for_workspace(workspace)
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref") or params.get("id"),
            "surface",
        )
        if surface_id:
            surface = workspace.surfaces.get(surface_id) or self._workspace_for_surface(surface_id).surfaces[surface_id]
            if surface.id not in workspace.surfaces:
                raise ValueError(_("Surface not found."))
        tty_name = str(params.get("tty_name") or params.get("ttyName") or params.get("tty") or "").strip()
        if not tty_name:
            raise ValueError(_("Missing tty_name."))
        self.surface_tty_names = {**self.surface_tty_names, surface.id: tty_name}
        return {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "tty_name": tty_name,
            "tty": tty_name,
        }

    def ports_kick_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params or {})
        surface = self._surface_for_workspace(workspace)
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref") or params.get("id"),
            "surface",
        )
        if surface_id:
            surface = workspace.surfaces.get(surface_id) or self._workspace_for_surface(surface_id).surfaces[surface_id]
            if surface.id not in workspace.surfaces:
                raise ValueError(_("Surface not found."))
        reason = str(params.get("reason") or "command").strip().lower()
        if reason not in {"command", "refresh"}:
            raise ValueError(_("reason must be command or refresh."))
        payload = {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "reason": reason,
            "kicked": True,
            "ports": [],
            "listening_ports": [],
            "detected_ports": [],
            "forwarded_ports": [],
            "conflicted_ports": [],
            "pending": False,
            "backend": LINUX_TERMINAL_BACKEND,
            "tty": self.surface_tty_names.get(surface.id),
            "tty_name": self.surface_tty_names.get(surface.id),
            "scanner": linux_port_scanner_capability(),
        }
        self.last_ports_kick = {**self.last_ports_kick, surface.id: payload}
        return payload

    def list_panes(self, params: dict[str, Any] | None = None) -> dict[str, Any]:
        surface = self._surface_from_params(params or {})
        panes = []
        for index, pane in enumerate(surface.panes.values()):
            snapshot = pane.snapshot().to_json()
            panes.append(
                {
                    **snapshot,
                    "index": index,
                    "focused": pane.id == surface.current_pane_id,
                    "surface_ids": [surface.id],
                    "surface_refs": [f"surface:{surface.id}"],
                    "selected_surface_id": surface.id,
                    "selected_surface_ref": f"surface:{surface.id}",
                    "surface_count": 1,
                }
            )
        workspace = self._workspace_for_surface(surface.id)
        return {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "panes": panes,
        }

    def focus_pane_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._pane_from_params(params)
        workspace = self._workspace_for_surface(surface.id)
        self._set_current_workspace_id(workspace.id)
        self.select_surface(surface.id)
        self._set_current_pane_id(surface, pane.id)
        focus_target = self._browser_web_view(pane) if pane.kind == "browser" else pane.widget
        if focus_target is not None and hasattr(focus_target, "grab_focus"):
            focus_target.grab_focus()
        return {"surface": surface.snapshot().to_json(), "pane": pane.snapshot().to_json()}

    def pane_surfaces_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._pane_from_params(params)
        workspace = self._workspace_for_surface(surface.id)
        surface_payload = surface.snapshot().to_json()
        return {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "pane_id": pane.id,
            "pane_ref": f"pane:{pane.id}",
            "surfaces": [
                {
                    **surface_payload,
                    "index": 0,
                    "type": pane.kind,
                    "selected": workspace.current_surface_id == surface.id,
                }
            ],
        }

    def create_pane_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        result = self.split_surface_from_params(params)
        surface_payload = result.get("surface") or {}
        pane_payload = result.get("pane") or {}
        surface_id = str(surface_payload.get("id") or surface_payload.get("surface_id") or "")
        workspace = self._workspace_for_surface(surface_id) if surface_id else self._current_workspace()
        return {
            **result,
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "surface_id": surface_payload.get("id"),
            "surface_ref": f"surface:{surface_payload.get('id')}" if surface_payload.get("id") else None,
            "pane_id": pane_payload.get("id"),
            "pane_ref": f"pane:{pane_payload.get('id')}" if pane_payload.get("id") else None,
            "type": pane_payload.get("kind"),
        }

    def resize_pane_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        direction = str(params.get("direction") or "").lower()
        amount = self._int_param(params, "amount")
        if amount is None:
            amount = self._int_param(params, "delta")
        amount = amount if amount is not None else 1
        if direction not in {"left", "right", "up", "down"} or amount <= 0:
            raise ValueError(_("direction must be left, right, up, or down and amount must be > 0."))
        surface, pane = self._pane_from_params(params)
        paned, pane_in_first_child = self._resize_candidate(surface, pane, direction)
        span = self._paned_span(paned)
        old_position = paned.get_position() if hasattr(paned, "get_position") else span // 2
        if old_position <= 0:
            old_position = span // 2
        sign = 1 if direction in {"right", "down"} else -1
        new_position = max(1, min(span - 1, old_position + (sign * amount)))
        paned.set_position(new_position)
        workspace = self._workspace_for_surface(surface.id)
        return {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "pane_id": pane.id,
            "pane_ref": f"pane:{pane.id}",
            "direction": direction,
            "amount": amount,
            "old_divider_position": old_position,
            "new_divider_position": new_position,
            "pane_in_first_child": pane_in_first_child,
        }

    def swap_pane_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        source_surface, source_pane = self._pane_from_params(params)
        target_surface, target_pane = self._pane_from_param_keys(
            params,
            ("targetPaneId", "target_pane_id", "target_pane_ref"),
        )
        if source_pane.id == target_pane.id:
            raise ValueError(_("pane_id and target_pane_id must be different."))
        source_workspace = self._workspace_for_surface(source_surface.id)
        target_workspace = self._workspace_for_surface(target_surface.id)
        if source_workspace.id != target_workspace.id:
            raise ValueError(_("Panes must be in the same workspace."))

        if source_surface.id == target_surface.id:
            self._swap_panes_within_surface(source_surface, source_pane.id, target_pane.id)
        else:
            self._swap_panes_between_surfaces(source_surface, source_pane, target_surface, target_pane)

        if self._bool_param(params, "focus", False):
            return self.focus_pane_from_params({"pane_id": target_pane.id})
        return {
            "workspace_id": source_workspace.id,
            "workspace_ref": f"workspace:{source_workspace.id}",
            "pane_id": source_pane.id,
            "pane_ref": f"pane:{source_pane.id}",
            "target_pane_id": target_pane.id,
            "target_pane_ref": f"pane:{target_pane.id}",
            "source_surface_id": source_surface.id,
            "source_surface_ref": f"surface:{source_surface.id}",
            "target_surface_id": target_surface.id,
            "target_surface_ref": f"surface:{target_surface.id}",
        }

    def break_pane_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        source_surface, pane = self._pane_from_params(params)
        source_workspace = self._workspace_for_surface(source_surface.id)
        destination_workspace = Workspace(
            id=str(uuid.uuid4()),
            name=str(params.get("name") or pane.title or _("Workspace")),
        )
        self.workspaces = {**self.workspaces, destination_workspace.id: destination_workspace}

        if len(source_surface.panes) <= 1:
            destination_surface = self._move_surface_to_workspace(source_surface, destination_workspace)
        else:
            destination_surface = self._move_pane_to_new_surface(source_surface, pane, destination_workspace)

        focus = self._bool_param(params, "focus", False)
        if focus:
            self._set_current_workspace_id(destination_workspace.id)
            destination_workspace.current_surface_id = destination_surface.id
            self.stack.set_visible_child_name(destination_surface.id)
        self._ensure_workspace_surface(source_workspace)
        self.refresh_sidebar()
        return {
            "workspace_id": destination_workspace.id,
            "workspace_ref": f"workspace:{destination_workspace.id}",
            "pane_id": pane.id,
            "pane_ref": f"pane:{pane.id}",
            "surface_id": destination_surface.id,
            "surface_ref": f"surface:{destination_surface.id}",
            "workspace": self._workspace_payload(destination_workspace),
            "surface": destination_surface.snapshot().to_json(),
            "pane": pane.snapshot().to_json(),
        }

    def join_pane_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        target_surface, target_pane = self._pane_from_param_keys(
            params,
            ("targetPaneId", "target_pane_id", "target_pane_ref"),
        )
        source_surface, source_pane = self._source_pane_for_join(params)
        if source_pane.id == target_pane.id:
            return {
                "accepted": True,
                "surface_id": target_surface.id,
                "pane_id": target_pane.id,
                "target_pane_id": target_pane.id,
            }
        if source_surface.id == target_surface.id:
            return {
                "accepted": True,
                "surface_id": target_surface.id,
                "pane_id": source_pane.id,
                "target_pane_id": target_pane.id,
            }

        source_workspace = self._workspace_for_surface(source_surface.id)
        target_workspace = self._workspace_for_surface(target_surface.id)
        moved_pane = self._detach_pane_for_move(source_surface, source_pane)
        moved_pane.surface_id = target_surface.id
        old_root = target_surface.root_widget
        target_was_visible = self._visible_surface_id() == target_surface.id
        self._remove_stack_child(old_root)
        target_surface.root_widget = self._build_paned(self._orientation_from_params(params), old_root, moved_pane.widget)
        target_surface.panes = {**target_surface.panes, moved_pane.id: moved_pane}
        self.stack.add_titled(target_surface.root_widget, target_surface.id, target_surface.title)
        if GTK_MAJOR < 4:
            target_surface.root_widget.show_all()
        if target_was_visible:
            self.stack.set_visible_child_name(target_surface.id)
        self._ensure_workspace_surface(source_workspace)
        if self._bool_param(params, "focus", False):
            self._set_current_workspace_id(target_workspace.id)
            target_workspace.current_surface_id = target_surface.id
            self._set_current_pane_id(target_surface, moved_pane.id)
            self.stack.set_visible_child_name(target_surface.id)
        self.refresh_sidebar()
        return {
            "accepted": True,
            "workspace_id": target_workspace.id,
            "workspace_ref": f"workspace:{target_workspace.id}",
            "source_workspace_id": source_workspace.id,
            "surface_id": target_surface.id,
            "surface_ref": f"surface:{target_surface.id}",
            "pane_id": moved_pane.id,
            "pane_ref": f"pane:{moved_pane.id}",
            "target_pane_id": target_pane.id,
            "target_pane_ref": f"pane:{target_pane.id}",
        }

    def select_last_pane_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface = self._surface_from_params(params)
        target_id = surface.previous_pane_id
        if not target_id or target_id not in surface.panes:
            target_id = next((pane_id for pane_id in surface.panes if pane_id != surface.current_pane_id), None)
        if not target_id:
            raise ValueError(_("No alternate pane available."))
        return self.focus_pane_from_params({"pane_id": target_id})

    def close_pane_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._pane_from_params(params)
        if len(surface.panes) <= 1:
            result = self.close_surface_from_params({"surfaceId": surface.id})
            return {"closedPaneId": pane.id, **result}
        self._detach_widget(pane.widget)
        surface.panes = {key: value for key, value in surface.panes.items() if key != pane.id}
        if surface.previous_pane_id == pane.id:
            surface.previous_pane_id = None
        next_pane_id = surface.current_pane_id if surface.current_pane_id in surface.panes else next(reversed(surface.panes), "")
        self._set_current_pane_id(surface, next_pane_id)
        self._rebuild_surface_root(surface)
        self.refresh_sidebar()
        self._save_runtime_state()
        return {"closedPaneId": pane.id, "surface": surface.snapshot().to_json()}

    def send_text_to_pane_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._pane_from_params(params)
        text = str(params.get("text") or params.get("input") or params.get("value") or "")
        if pane.kind != "terminal" or not hasattr(pane.widget, "feed_child"):
            raise ValueError(_("Pane is not a terminal."))
        try:
            pane.widget.feed_child(text.encode("utf-8"))
        except TypeError:
            pane.widget.feed_child(text, -1)
        return {"accepted": True, "pane": pane.snapshot().to_json()}

    def send_text_to_surface_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface = self._surface_from_params(params)
        pane = self._terminal_pane_for_surface(surface)
        result = self.send_text_to_pane_from_params({**params, "paneId": pane.id})
        return {**result, "surface_id": surface.id, "pane_id": pane.id}

    def send_key_to_surface_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        text = self._key_text_from_params(params)
        if not text:
            raise ValueError(_("Missing key."))
        result = self.send_text_to_surface_from_params({**params, "text": text})
        return {**result, "key": params.get("key") or params.get("text")}

    def read_text_from_surface_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface = self._surface_from_params(params)
        pane = self._terminal_pane_for_surface(surface)
        text = self._read_terminal_text(pane)
        return {
            "text": text,
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "pane_id": pane.id,
            "pane_ref": f"pane:{pane.id}",
        }

    def clear_history_from_surface_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface = self._surface_from_params(params)
        pane = self._terminal_pane_for_surface(surface)
        self._clear_terminal_history(pane)
        return {
            "accepted": True,
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "pane_id": pane.id,
            "pane_ref": f"pane:{pane.id}",
        }

    def surface_action_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface = self._surface_from_params(params)
        action = str(params.get("action") or "").replace("-", "_").lower()
        if action == "rename":
            title = str(params.get("title") or params.get("name") or "").strip()
            if not title:
                raise ValueError(_("Missing title."))
            return self._rename_surface(surface, title)
        if action in {"focus", "select"}:
            return self.focus_surface_from_params({"surface_id": surface.id})
        if action in {"pin", "mark_unread", "mark_read", "clear_name", "unpin"}:
            return self._surface_action_status(surface, action)
        raise ValueError(_("Unsupported surface action."))

    def tab_action_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface = self._surface_from_tab_params(params)
        payload = self.surface_action_from_params({**params, "surface_id": surface.id})
        return {**payload, "tab_ref": f"tab:{surface.id}"}

    def navigate_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        url_value = params.get("url") or params.get("uri")
        if not url_value:
            raise ValueError(_("Missing url."))
        url = normalize_url(str(url_value))
        surface, pane = self._browser_pane_from_params(params)
        if pane is None:
            pane = self._build_browser_pane(surface.id, url)
            result = self._split_surface(surface, pane, params)
            return {
                **result,
                "surface_id": surface.id,
                "surface_ref": f"surface:{surface.id}",
                "pane_id": pane.id,
                "pane_ref": f"pane:{pane.id}",
                "url": url,
            }
        pane.title = url
        pane.url = url
        self._sync_browser_chrome(pane)
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "load_uri"):
            web_view.load_uri(url)
        self.focus_pane_from_params({"paneId": pane.id})
        return {
            "surface": surface.snapshot().to_json(),
            "pane": pane.snapshot().to_json(),
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "pane_id": pane.id,
            "pane_ref": f"pane:{pane.id}",
            "url": url,
        }

    def get_browser_url_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        live_url = pane.url or ""
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "get_uri"):
            live_url = str(web_view.get_uri() or live_url)
            pane.url = live_url
            self._sync_browser_chrome(pane)
        return {"surface_id": surface.id, "pane_id": pane.id, "url": live_url}

    def go_back_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "go_back"):
            web_view.go_back()
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def go_forward_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "go_forward"):
            web_view.go_forward()
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def reload_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "reload"):
            web_view.reload()
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def focus_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        self.focus_pane_from_params({"paneId": pane.id})
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def is_browser_focused_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        web_view = self._browser_web_view(pane)
        focused = bool(web_view.has_focus()) if web_view is not None and hasattr(web_view, "has_focus") else False
        return {"focused": focused, "surface_id": surface.id, "pane_id": pane.id}

    def eval_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        script = str(params.get("script") or params.get("expression") or "")
        if not script:
            raise ValueError(_("Missing script."))
        payload = self._run_browser_payload(
            pane,
            f"""(() => {{
                try {{
                    const value = (0, eval)({js_literal(script)});
                    return {{ ok: true, value: value === undefined ? null : value }};
                }} catch (error) {{
                    return {{ ok: false, error: String(error && error.message ? error.message : error) }};
                }}
            }})()""",
        )
        return {"value": payload.get("value"), "surface_id": surface.id, "pane_id": pane.id}

    def wait_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        timeout_ms = int(params.get("timeout_ms") or params.get("timeoutMs") or DEFAULT_BROWSER_TIMEOUT_MS)
        deadline = time.monotonic() + max(1, timeout_ms) / 1000.0
        while time.monotonic() <= deadline:
            if self._browser_wait_condition(pane, params):
                return {"ok": True, "surface_id": surface.id, "pane_id": pane.id}
            time.sleep(0.05)
        raise TimeoutError(_("timeout waiting for browser condition"))

    def click_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        payload = self._element_action(
            pane,
            params,
            "el.click(); return { clicked: true };",
        )
        return {"accepted": True, "value": payload.get("clicked"), "surface_id": surface.id, "pane_id": pane.id}

    def dblclick_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        self._element_action(
            pane,
            params,
            "el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); return { dblclicked: true };",
        )
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def hover_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        self._element_action(
            pane,
            params,
            """
            el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true }));
            el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true, cancelable: true }));
            return { hovered: true };
            """,
        )
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def focus_browser_element_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        self._element_action(pane, params, "if (el.focus) { el.focus(); } return { focused: document.activeElement === el };")
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def type_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        text = str(params.get("text") or params.get("value") or "")
        payload = self._element_action(
            pane,
            params,
            f"""
            const text = {js_literal(text)};
            if ('value' in el) {{
                el.value = String(el.value || '') + text;
                el.dispatchEvent(new Event('input', {{ bubbles: true }}));
                el.dispatchEvent(new Event('change', {{ bubbles: true }}));
                return {{ value: el.value }};
            }}
            el.textContent = String(el.textContent || '') + text;
            return {{ value: el.textContent }};
            """,
        )
        return {"value": payload.get("value"), "surface_id": surface.id, "pane_id": pane.id}

    def fill_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        text = str(params.get("text") if params.get("text") is not None else params.get("value") or "")
        payload = self._element_action(
            pane,
            params,
            f"""
            const text = {js_literal(text)};
            if ('value' in el) {{
                el.value = text;
                el.dispatchEvent(new Event('input', {{ bubbles: true }}));
                el.dispatchEvent(new Event('change', {{ bubbles: true }}));
                return {{ value: el.value }};
            }}
            el.textContent = text;
            return {{ value: el.textContent }};
            """,
        )
        result = {"value": payload.get("value"), "surface_id": surface.id, "pane_id": pane.id}
        if params.get("snapshot_after") or params.get("snapshotAfter"):
            result["post_action_snapshot"] = self.snapshot_browser_from_params(params).get("snapshot")
        return result

    def key_browser_from_params(self, params: dict[str, Any], mode: str) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        key = str(params.get("key") or params.get("text") or "")
        root_expr = self._browser_root_expression(pane)
        payload = self._run_browser_payload(
            pane,
            f"""(() => {{
                const key = {js_literal(key)};
                const root = {root_expr};
                const target = root.activeElement || root.body || root.documentElement;
                const fire = (type) => target.dispatchEvent(new KeyboardEvent(type, {{ key, bubbles: true, cancelable: true }}));
                if ({js_literal(mode)} === 'press') {{
                    fire('keydown'); fire('keypress'); fire('keyup');
                }} else {{
                    fire({js_literal(mode)});
                }}
                return {{ ok: true, key }};
            }})()""",
        )
        return {"accepted": True, "value": payload.get("key"), "surface_id": surface.id, "pane_id": pane.id}

    def check_browser_from_params(self, params: dict[str, Any], checked: bool) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        payload = self._element_action(
            pane,
            params,
            f"""
            if (!('checked' in el)) {{ throw new Error('Element is not checkable'); }}
            el.checked = {str(checked).lower()};
            el.dispatchEvent(new Event('input', {{ bubbles: true }}));
            el.dispatchEvent(new Event('change', {{ bubbles: true }}));
            return {{ value: !!el.checked }};
            """,
        )
        return {"value": payload.get("value"), "surface_id": surface.id, "pane_id": pane.id}

    def select_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        value = str(params.get("value") or "")
        payload = self._element_action(
            pane,
            params,
            f"""
            el.value = {js_literal(value)};
            el.dispatchEvent(new Event('input', {{ bubbles: true }}));
            el.dispatchEvent(new Event('change', {{ bubbles: true }}));
            return {{ value: el.value }};
            """,
        )
        return {"value": payload.get("value"), "surface_id": surface.id, "pane_id": pane.id}

    def scroll_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        dx = float(params.get("dx") or 0)
        dy = float(params.get("dy") or 0)
        selector = self._selector_from_params(pane, params, required=False)
        root_expr = self._browser_root_expression(pane)
        target_expr = "window" if not selector else f"{root_expr}.querySelector({js_literal(selector)})"
        self._run_browser_payload(
            pane,
            f"""(() => {{
                const target = {target_expr};
                if (!target) {{ return {{ ok: false, error: 'Element not found' }}; }}
                target.scrollBy({dx}, {dy});
                return {{ ok: true }};
            }})()""",
        )
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def scroll_into_view_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        self._element_action(pane, params, "el.scrollIntoView({ block: 'center', inline: 'center' }); return { scrolled: true };")
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def get_browser_text_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._element_value_from_params(params, "(el.innerText || el.textContent || '')")

    def get_browser_html_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._element_value_from_params(params, "el.outerHTML || ''")

    def get_browser_value_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._element_value_from_params(params, "('value' in el ? el.value : (el.textContent || ''))")

    def get_browser_attr_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        attr = str(params.get("attr") or params.get("name") or "")
        if not attr:
            raise ValueError(_("Missing attr."))
        return self._element_value_from_params(params, f"el.getAttribute({js_literal(attr)})")

    def get_browser_title_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        title = ""
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "get_title"):
            title = str(web_view.get_title() or "")
        if not title:
            payload = self._run_browser_payload(pane, "(() => ({ ok: true, value: document.title || '' }))()")
            title = str(payload.get("value") or "")
        if title:
            pane.title = title
            self._sync_browser_chrome(pane)
        return {"title": title, "value": title, "surface_id": surface.id, "pane_id": pane.id}

    def get_browser_count_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        selector = self._selector_from_params(pane, params)
        root_expr = self._browser_root_expression(pane)
        payload = self._run_browser_payload(
            pane,
            f"(() => {{ const root = {root_expr}; return {{ ok: true, count: root.querySelectorAll({js_literal(selector)}).length }}; }})()",
        )
        return {"count": payload.get("count"), "surface_id": surface.id, "pane_id": pane.id}

    def get_browser_box_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._element_value_from_params(
            params,
            "(() => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; })()",
        )

    def get_browser_styles_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        prop = params.get("property")
        expression = (
            f"getComputedStyle(el).getPropertyValue({js_literal(str(prop))})"
            if prop
            else "Object.fromEntries(Array.from(getComputedStyle(el)).map((key) => [key, getComputedStyle(el).getPropertyValue(key)]))"
        )
        return self._element_value_from_params(params, expression)

    def is_browser_visible_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._element_value_from_params(
            params,
            "!!(el.offsetWidth || el.offsetHeight || el.getClientRects().length)",
        )

    def is_browser_enabled_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._element_value_from_params(params, "!el.disabled")

    def is_browser_checked_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._element_value_from_params(params, "!!el.checked")

    def snapshot_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        root_expr = self._browser_root_expression(pane)
        payload = self._run_browser_payload(
            pane,
            """(() => {
                const root = __CMUX_ROOT__;
                const cssPath = (el) => {
                    if (el.id) { return `#${CSS.escape(el.id)}`; }
                    const parts = [];
                    while (el && el.nodeType === Node.ELEMENT_NODE && el !== root.body) {
                        let part = el.tagName.toLowerCase();
                        const parent = el.parentElement;
                        if (parent) {
                            const same = Array.from(parent.children).filter((child) => child.tagName === el.tagName);
                            if (same.length > 1) { part += `:nth-of-type(${same.indexOf(el) + 1})`; }
                        }
                        parts.unshift(part);
                        el = parent;
                    }
                    return parts.length ? `body > ${parts.join(' > ')}` : 'body';
                };
                const refs = {};
                const rows = [`title: ${root.title || document.title || ''}`];
                Array.from(root.querySelectorAll('body, body *')).slice(0, 250).forEach((el, idx) => {
                    const ref = `e${idx + 1}`;
                    const text = (el.innerText || el.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 180);
                    const selector = cssPath(el);
                    refs[ref] = { selector, tag: el.tagName.toLowerCase(), id: el.id || null, text };
                    if (text || el.id) { rows.push(`${ref} ${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ''} ${text}`.trim()); }
                });
                return { ok: true, snapshot: rows.join('\\n'), refs };
            })()""".replace("__CMUX_ROOT__", root_expr),
        )
        refs = payload.get("refs") if isinstance(payload.get("refs"), dict) else {}
        pane.browser_refs = {
            f"@{key}": str(value.get("selector"))
            for key, value in refs.items()
            if isinstance(value, dict) and value.get("selector")
        }
        return {
            "snapshot": payload.get("snapshot") or "",
            "refs": refs,
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def screenshot_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        png_bytes = self._capture_widget_png(self._browser_web_view(pane) or pane.widget)
        encoded = base64.b64encode(png_bytes).decode("ascii") if png_bytes else FALLBACK_SCREENSHOT_PNG_BASE64
        return {"png_base64": encoded, "surface_id": surface.id, "pane_id": pane.id}

    def find_browser_role_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        role = str(params.get("role") or "")
        name = str(params.get("name") or "")
        selector = (
            f"[role={role}],button,input[type=button],input[type=submit],input[type=reset]"
            if role == "button"
            else f"[role={role}]"
        )
        return self._find_browser_element(params, selector, name)

    def find_browser_text_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        text = str(params.get("text") or "")
        return self._find_browser_element(params, "body *", text)

    def find_browser_label_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        label = str(params.get("label") or "")
        root_expr = self._browser_root_expression(pane)
        payload = self._run_browser_payload(
            pane,
            f"""(() => {{
                const root = {root_expr};
                const wanted = {js_literal(label)}.toLowerCase();
                const labels = Array.from(root.querySelectorAll('label'));
                const label = labels.find((row) => (row.innerText || row.textContent || '').toLowerCase().includes(wanted));
                if (!label) {{ return {{ ok: false, error: 'Element not found' }}; }}
                const target = label.htmlFor ? root.getElementById(label.htmlFor) : label.querySelector('input,textarea,select,button');
                if (!target) {{ return {{ ok: false, error: 'Element not found' }}; }}
                return {{ ok: true, selector: target.id ? `#${{CSS.escape(target.id)}}` : null }};
            }})()""",
        )
        return self._register_browser_ref(surface, pane, str(payload.get("selector") or ""))

    def find_browser_placeholder_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self.find_browser_attr_match_from_params(params, "placeholder", "placeholder")

    def find_browser_attr_match_from_params(
        self,
        params: dict[str, Any],
        attr: str,
        value_key: str | None = None,
    ) -> dict[str, Any]:
        value = str(params.get(value_key or attr) or "")
        return self._find_browser_element(params, f"[{attr}]", value, attr)

    def find_browser_index_from_params(self, params: dict[str, Any], mode: str) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        selector = self._selector_from_params(pane, params)
        index = int(params.get("index") or 0)
        js_index = "nodes.length - 1" if mode == "last" else str(index if mode == "nth" else 0)
        root_expr = self._browser_root_expression(pane)
        payload = self._run_browser_payload(
            pane,
            f"""(() => {{
                const root = {root_expr};
                const nodes = Array.from(root.querySelectorAll({js_literal(selector)}));
                const el = nodes[{js_index}];
                if (!el) {{ return {{ ok: false, error: 'Element not found' }}; }}
                return {{ ok: true, selector: el.id ? `#${{CSS.escape(el.id)}}` : {js_literal(selector)} }};
            }})()""",
        )
        return self._register_browser_ref(surface, pane, str(payload.get("selector") or selector))

    def wait_browser_download_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        path = Path(str(params.get("path") or ""))
        timeout_ms = int(params.get("timeout_ms") or DEFAULT_BROWSER_TIMEOUT_MS)
        deadline = time.monotonic() + max(1, timeout_ms) / 1000.0
        while time.monotonic() <= deadline:
            if path.exists():
                return {"downloaded": True, "path": str(path)}
            time.sleep(0.05)
        raise TimeoutError(_("timeout waiting for download"))

    def get_browser_cookies_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        name = str(params.get("name") or "")
        payload = self._run_browser_payload(
            pane,
            """(() => ({
                ok: true,
                cookies: document.cookie.split(';').map((item) => item.trim()).filter(Boolean).map((item) => {
                    const idx = item.indexOf('=');
                    return { name: idx >= 0 ? item.slice(0, idx) : item, value: idx >= 0 ? decodeURIComponent(item.slice(idx + 1)) : '' };
                })
            }))()""",
        )
        cookies = payload.get("cookies") if isinstance(payload.get("cookies"), list) else []
        if name:
            cookies = [cookie for cookie in cookies if isinstance(cookie, dict) and cookie.get("name") == name]
        return {"cookies": cookies}

    def set_browser_cookie_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        name = str(params.get("name") or "")
        value = str(params.get("value") or "")
        if not name:
            raise ValueError(_("Missing cookie name."))
        self._run_browser_payload(
            pane,
            f"(() => {{ document.cookie = `${{encodeURIComponent({js_literal(name)})}}=${{encodeURIComponent({js_literal(value)})}}; path=/`; return {{ ok: true }}; }})()",
        )
        return {"accepted": True}

    def clear_browser_cookies_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        name = str(params.get("name") or "")
        script = (
            f"document.cookie = `${{encodeURIComponent({js_literal(name)})}}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/`;"
            if name
            else "document.cookie.split(';').forEach((item) => { document.cookie = item.split('=')[0].trim() + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/'; });"
        )
        self._run_browser_payload(pane, f"(() => {{ {script} return {{ ok: true }}; }})()")
        return {"accepted": True}

    def get_browser_storage_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        storage = "sessionStorage" if str(params.get("type") or "local").lower().startswith("session") else "localStorage"
        key = str(params.get("key") or "")
        payload = self._run_browser_payload(pane, f"(() => ({{ ok: true, value: {storage}.getItem({js_literal(key)}) }}))()")
        return {"value": payload.get("value")}

    def set_browser_storage_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        storage = "sessionStorage" if str(params.get("type") or "local").lower().startswith("session") else "localStorage"
        key = str(params.get("key") or "")
        value = "" if params.get("value") is None else str(params.get("value"))
        self._run_browser_payload(
            pane,
            f"(() => {{ {storage}.setItem({js_literal(key)}, {js_literal(value)}); return {{ ok: true }}; }})()",
        )
        return {"accepted": True}

    def clear_browser_storage_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        storage = "sessionStorage" if str(params.get("type") or "local").lower().startswith("session") else "localStorage"
        key = str(params.get("key") or "")
        script = f"{storage}.removeItem({js_literal(key)});" if key else f"{storage}.clear();"
        self._run_browser_payload(pane, f"(() => {{ {script} return {{ ok: true }}; }})()")
        return {"accepted": True}

    def new_browser_tab_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._current_workspace()
        url = normalize_url(str(params.get("url") or DEFAULT_BROWSER_URL))
        surface_id = str(uuid.uuid4())
        pane = self._build_browser_pane(surface_id, url)
        surface = Surface(
            id=surface_id,
            title=url,
            cwd=os.getcwd(),
            root_widget=pane.widget,
            panes={pane.id: pane},
            current_pane_id=pane.id,
        )
        workspace.surfaces = {**workspace.surfaces, surface.id: surface}
        workspace.current_surface_id = surface.id
        self.stack.add_titled(surface.root_widget, surface.id, surface.title)
        self.select_surface(surface.id)
        self.refresh_sidebar()
        return {
            "surface": surface.snapshot().to_json(),
            "pane": pane.snapshot().to_json(),
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "pane_id": pane.id,
            "pane_ref": f"pane:{pane.id}",
        }

    def list_browser_tabs_from_params(self, _params: dict[str, Any]) -> dict[str, Any]:
        tabs = []
        for workspace in self.workspaces.values():
            for surface in workspace.surfaces.values():
                if any(pane.kind == "browser" for pane in surface.panes.values()):
                    tabs.append({"id": surface.id, "surface_id": surface.id, "title": surface.title})
        return {"tabs": tabs}

    def switch_browser_tab_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        target = parse_ref(params.get("target_surface_id") or params.get("targetSurfaceId") or params.get("surface_id"), "surface")
        return self.select_surface_from_params({"surface_id": target})

    def close_browser_tab_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        target = parse_ref(params.get("target_surface_id") or params.get("targetSurfaceId") or params.get("surface_id"), "surface")
        pane_id = parse_ref(params.get("paneId") or params.get("pane_id") or params.get("pane_ref") or params.get("id"), "pane")
        if pane_id:
            return self.close_pane_from_params({"pane_id": pane_id})
        if target:
            return self.close_surface_from_params({"surface_id": target})
        surface, pane = self._require_browser_pane(params)
        if len(surface.panes) > 1:
            return self.close_pane_from_params({"pane_id": pane.id})
        return self.close_surface_from_params({"surface_id": surface.id})

    def list_browser_console_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        self._bootstrap_browser_pane(pane)
        payload = self._run_browser_payload(pane, "(() => ({ ok: true, entries: window.__cmuxConsole || [] }))()")
        entries = payload.get("entries") if isinstance(payload.get("entries"), list) else []
        return {"entries": entries, "count": len(entries)}

    def clear_browser_console_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        self._run_browser_payload(pane, "(() => { window.__cmuxConsole = []; window.__cmuxErrors = []; return { ok: true }; })()")
        return {"accepted": True}

    def list_browser_errors_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        self._bootstrap_browser_pane(pane)
        payload = self._run_browser_payload(pane, "(() => ({ ok: true, entries: window.__cmuxErrors || [] }))()")
        entries = payload.get("entries") if isinstance(payload.get("entries"), list) else []
        return {"entries": entries, "count": len(entries)}

    def highlight_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        self._element_action(
            pane,
            params,
            "el.dataset.cmuxPreviousOutline = el.style.outline || ''; el.style.outline = '2px solid #ffcc00'; return { highlighted: true };",
        )
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def save_browser_state_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        path = Path(str(params.get("path") or ""))
        if not path:
            raise ValueError(_("Missing path."))
        payload = self._run_browser_payload(
            pane,
            """(() => {
                const dump = (storage) => Object.fromEntries(Array.from({ length: storage.length }, (_, idx) => {
                    const key = storage.key(idx);
                    return [key, storage.getItem(key)];
                }));
                return { ok: true, value: { local: dump(localStorage), session: dump(sessionStorage) } };
            })()""",
        )
        path.write_text(json.dumps(payload.get("value") or {}, ensure_ascii=False), encoding="utf-8")
        return {"saved": True, "path": str(path)}

    def load_browser_state_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        path = Path(str(params.get("path") or ""))
        state = json.loads(path.read_text(encoding="utf-8"))
        self._run_browser_payload(
            pane,
            f"""(() => {{
                const state = {js_literal(state)};
                for (const [key, value] of Object.entries(state.local || {{}})) {{ localStorage.setItem(key, value); }}
                for (const [key, value] of Object.entries(state.session || {{}})) {{ sessionStorage.setItem(key, value); }}
                return {{ ok: true }};
            }})()""",
        )
        return {"loaded": True, "path": str(path)}

    def add_init_script_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        _surface, pane = self._require_browser_pane(params)
        script = str(params.get("script") or "")
        if not script:
            raise ValueError(_("Missing script."))
        pane.init_scripts = [*pane.init_scripts, script]
        self._bootstrap_browser_pane(pane)
        return {"accepted": True}

    def add_script_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self.eval_browser_from_params(params)

    def add_style_browser_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        css = str(params.get("css") or params.get("style") or "")
        if not css:
            raise ValueError(_("Missing css."))
        self._run_browser_payload(
            pane,
            f"""(() => {{
                const style = document.createElement('style');
                style.textContent = {js_literal(css)};
                document.head.appendChild(style);
                return {{ ok: true }};
            }})()""",
        )
        return {"accepted": True, "surface_id": surface.id, "pane_id": pane.id}

    def main_browser_frame_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        pane.browser_frame_selector = None
        return {"accepted": True, "frame": {"main": True, "selector": None}, "surface_id": surface.id, "pane_id": pane.id}

    def select_browser_frame_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        selector = str(params.get("selector") or params.get("frame_selector") or params.get("frameSelector") or "iframe")
        payload = self._run_browser_payload(
            pane,
            f"""(() => {{
                const frame = document.querySelector({js_literal(selector)});
                if (!frame || !frame.contentDocument) {{ return {{ ok: false, error: 'Frame not found' }}; }}
                return {{ ok: true, title: frame.contentDocument.title || '', url: frame.src || frame.contentWindow.location.href || '' }};
            }})()""",
        )
        pane.browser_frame_selector = selector
        return {
            "accepted": True,
            "frame": {"main": False, "selector": selector, "title": payload.get("title"), "url": payload.get("url")},
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def set_browser_dialog_policy_from_params(self, params: dict[str, Any], accept: bool) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        prompt_text = str(params.get("promptText") or params.get("prompt_text") or params.get("text") or "")
        pane.browser_dialog_policy = {"accept": accept, "prompt_text": prompt_text}
        self._install_browser_script(pane, self._dialog_policy_script(accept, prompt_text))
        return {"accepted": True, "policy": pane.browser_dialog_policy, "surface_id": surface.id, "pane_id": pane.id}

    def set_browser_viewport_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        viewport = params.get("viewport") if isinstance(params.get("viewport"), dict) else {}
        width = int(params.get("width") or viewport.get("width") or 0)
        height = int(params.get("height") or viewport.get("height") or 0)
        if width <= 0 or height <= 0:
            raise ValueError(_("Invalid viewport size."))
        pane.browser_viewport = {"width": width, "height": height}
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "set_size_request"):
            web_view.set_size_request(width, height)
        return {"accepted": True, "viewport": pane.browser_viewport, "surface_id": surface.id, "pane_id": pane.id}

    def set_browser_geolocation_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        raw_latitude = params.get("latitude") if params.get("latitude") is not None else params.get("lat")
        raw_longitude = params.get("longitude") if params.get("longitude") is not None else params.get("lon")
        if raw_latitude is None or raw_longitude is None:
            raise ValueError(_("Missing geolocation coordinates."))
        latitude = float(raw_latitude)
        longitude = float(raw_longitude)
        accuracy = float(params.get("accuracy") or 0)
        pane.browser_geolocation = {"latitude": latitude, "longitude": longitude, "accuracy": accuracy}
        self._install_browser_script(pane, self._geolocation_script(latitude, longitude, accuracy))
        return {"accepted": True, "geolocation": pane.browser_geolocation, "emulated": True, "surface_id": surface.id, "pane_id": pane.id}

    def set_browser_offline_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        offline = bool(params.get("offline") if "offline" in params else params.get("enabled", True))
        pane.browser_offline = offline
        self._install_browser_script(pane, self._offline_script(offline))
        return {"accepted": True, "offline": offline, "emulated": True, "surface_id": surface.id, "pane_id": pane.id}

    def start_browser_trace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        pane.browser_trace_active = True
        pane.browser_trace_started_at = time.time()
        self._install_browser_script(pane, self._trace_script())
        return {
            "accepted": True,
            "trace": {"active": True, "started_at": pane.browser_trace_started_at},
            "backend_limit": browser_backend_limit("browser.trace.start"),
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def stop_browser_trace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        payload = self._browser_trace_payload(pane)
        pane.browser_trace_active = False
        return {
            "accepted": True,
            "trace": {"active": False, **payload},
            "backend_limit": browser_backend_limit("browser.trace.stop"),
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def route_browser_network_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        pattern = str(params.get("pattern") or params.get("url") or params.get("glob") or "*")
        route = {"pattern": pattern, "created_at": time.time(), "intercepted": False}
        pane.browser_network_routes = [*pane.browser_network_routes, route]
        return {
            "accepted": True,
            "route": route,
            "routes": pane.browser_network_routes,
            "backend_limit": browser_backend_limit("browser.network.route"),
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def unroute_browser_network_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        pattern = str(params.get("pattern") or params.get("url") or params.get("glob") or "")
        pane.browser_network_routes = [] if not pattern else [route for route in pane.browser_network_routes if route.get("pattern") != pattern]
        return {
            "accepted": True,
            "routes": pane.browser_network_routes,
            "backend_limit": browser_backend_limit("browser.network.unroute"),
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def list_browser_network_requests_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        payload = self._run_browser_payload(pane, self._network_requests_expression())
        requests = payload.get("requests") if isinstance(payload.get("requests"), list) else []
        return {
            "requests": requests,
            "routes": pane.browser_network_routes,
            "backend_limit": browser_backend_limit("browser.network.requests"),
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def start_browser_screencast_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        pane.browser_screencast_active = True
        frame = self.screenshot_browser_from_params(params)
        return {
            "accepted": True,
            "active": True,
            "frame": frame,
            "backend_limit": browser_backend_limit("browser.screencast.start"),
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def stop_browser_screencast_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        pane.browser_screencast_active = False
        return {
            "accepted": True,
            "active": False,
            "backend_limit": browser_backend_limit("browser.screencast.stop"),
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def input_browser_keyboard_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        event_type = str(params.get("type") or params.get("event") or "press").lower()
        mode = event_type if event_type in {"keydown", "keyup", "press"} else "press"
        return {
            **self.key_browser_from_params(params, mode),
            "backend_limit": browser_backend_limit("browser.input_keyboard"),
        }

    def input_browser_mouse_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        payload = self._run_browser_payload(pane, self._pointer_event_expression(params, touch=False))
        return {
            "accepted": True,
            "event": payload.get("event"),
            "backend_limit": browser_backend_limit("browser.input_mouse"),
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def input_browser_touch_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        payload = self._run_browser_payload(pane, self._pointer_event_expression(params, touch=True))
        return {
            "accepted": True,
            "event": payload.get("event"),
            "emulated": True,
            "backend_limit": browser_backend_limit("browser.input_touch"),
            "surface_id": surface.id,
            "pane_id": pane.id,
        }

    def unsupported_browser_method(self, method: str) -> dict[str, Any]:
        raise UnsupportedMethodError(method, f"{method} is not available in the Linux WebKitGTK backend yet")

    def _key_text_from_params(self, params: dict[str, Any]) -> str:
        raw_text = params.get("text")
        if isinstance(raw_text, str) and raw_text:
            return raw_text
        key = str(params.get("key") or "").strip()
        if not key:
            return ""
        raw_modifiers = params.get("modifiers") or params.get("mods") or []
        modifier_values = [raw_modifiers] if isinstance(raw_modifiers, str) else raw_modifiers
        modifiers = {
            str(value).lower()
            for value in modifier_values
            if isinstance(value, str)
        }
        lowered = key.lower()
        if "ctrl" in modifiers or "control" in modifiers:
            return self._control_key_sequence(lowered)
        if len(key) == 1:
            return key
        return KEY_SEQUENCES.get(lowered, "")

    def _control_key_sequence(self, lowered: str) -> str:
        if len(lowered) == 1 and "a" <= lowered <= "z":
            return chr(ord(lowered) - ord("a") + 1)
        control_keys = {
            "space": "\x00",
            "[": "\x1b",
            "]": "\x1d",
            "\\": "\x1c",
        }
        return control_keys.get(lowered, KEY_SEQUENCES.get(lowered, ""))

    def _read_terminal_text(self, pane: Pane) -> str:
        if pane.kind != "terminal":
            raise ValueError(_("Pane is not a terminal."))
        terminal = pane.widget
        fallback_text = ""
        text_format = getattr(getattr(Vte, "Format", object), "TEXT", None)
        if text_format is not None and hasattr(terminal, "get_text_format"):
            value = terminal.get_text_format(text_format)
            text = str((value[0] if isinstance(value, tuple) else value) or "")
            if text:
                return text
            fallback_text = text
        if text_format is not None and hasattr(terminal, "get_text_range_format"):
            row_count = int(terminal.get_row_count()) if hasattr(terminal, "get_row_count") else 5000
            column_count = int(terminal.get_column_count()) if hasattr(terminal, "get_column_count") else 500
            value = terminal.get_text_range_format(text_format, 0, 0, row_count, column_count)
            text = str((value[0] if isinstance(value, tuple) else value) or "")
            if text:
                return text
            fallback_text = text
        for callback_args in ((lambda *_: True, None), (lambda *_: True,), ()):
            try:
                value = terminal.get_text(*callback_args)
            except (AttributeError, TypeError):
                continue
            if isinstance(value, tuple):
                text = str(value[0] or "")
            else:
                text = str(value or "")
            if text:
                return text
            fallback_text = text
        if hasattr(terminal, "get_text_range"):
            row_count = int(terminal.get_row_count()) if hasattr(terminal, "get_row_count") else 5000
            column_count = int(terminal.get_column_count()) if hasattr(terminal, "get_column_count") else 500
            range_args = (
                (0, 0, row_count, column_count, lambda *_: True, None),
                (0, 0, row_count, column_count, lambda *_: True),
                (0, 0, row_count, column_count),
            )
            for callback_args in range_args:
                try:
                    value = terminal.get_text_range(*callback_args)
                except TypeError:
                    continue
                text = str((value[0] if isinstance(value, tuple) else value) or "")
                if text:
                    return text
                fallback_text = text
        return fallback_text

    def _clear_terminal_history(self, pane: Pane) -> None:
        if pane.kind != "terminal":
            raise ValueError(_("Pane is not a terminal."))
        terminal = pane.widget
        reset = getattr(terminal, "reset", None)
        if callable(reset):
            try:
                reset(False, True)
            except TypeError:
                reset(True, True)
            return
        raise ValueError(_("Terminal history cannot be cleared."))

    def _rename_surface(self, surface: Surface, title: str) -> dict[str, Any]:
        surface.title = title
        self._set_stack_title(surface)
        self.refresh_sidebar()
        snapshot = surface.snapshot().to_json()
        return {
            **snapshot,
            "action": "rename",
            "title": title,
            "workspace_id": self._workspace_for_surface(surface.id).id,
        }

    def _browser_root_expression(self, pane: Pane) -> str:
        if not pane.browser_frame_selector:
            return "document"
        selector = js_literal(pane.browser_frame_selector)
        return f"((() => {{ const frame = document.querySelector({selector}); return frame && frame.contentDocument ? frame.contentDocument : document; }})())"

    def _install_browser_script(self, pane: Pane, body: str) -> None:
        pane.init_scripts = [*pane.init_scripts, f"(() => {{ {body} }})()"]
        self._run_browser_js(pane, f"(() => {{ {body} return true; }})()", timeout_ms=1000)

    def _dialog_policy_script(self, accept: bool, prompt_text: str) -> str:
        decision = "true" if accept else "false"
        prompt_value = js_literal(prompt_text)
        return f"""
            window.__cmuxDialogs = window.__cmuxDialogs || [];
            window.alert = (message) => {{ window.__cmuxDialogs.push({{ type: 'alert', message: String(message || '') }}); }};
            window.confirm = (message) => {{ window.__cmuxDialogs.push({{ type: 'confirm', message: String(message || '') }}); return {decision}; }};
            window.prompt = (message, value) => {{
                window.__cmuxDialogs.push({{ type: 'prompt', message: String(message || ''), defaultValue: String(value || '') }});
                return {decision} ? {prompt_value} : null;
            }};
        """

    def _geolocation_script(self, latitude: float, longitude: float, accuracy: float) -> str:
        return f"""
            const position = {{
                coords: {{
                    latitude: {latitude}, longitude: {longitude}, accuracy: {accuracy},
                    altitude: null, altitudeAccuracy: null, heading: null, speed: null
                }},
                timestamp: Date.now()
            }};
            navigator.geolocation = navigator.geolocation || {{}};
            navigator.geolocation.getCurrentPosition = (success) => setTimeout(() => success(position), 0);
            navigator.geolocation.watchPosition = (success) => {{ setTimeout(() => success(position), 0); return 1; }};
            navigator.geolocation.clearWatch = () => undefined;
        """

    def _offline_script(self, offline: bool) -> str:
        online = "false" if offline else "true"
        event_name = "offline" if offline else "online"
        return f"""
            Object.defineProperty(Navigator.prototype, 'onLine', {{ configurable: true, get: () => {online} }});
            window.dispatchEvent(new Event({js_literal(event_name)}));
        """

    def _trace_script(self) -> str:
        return """
            window.__cmuxTrace = window.__cmuxTrace || [];
            if (!window.__cmuxTraceInstalled) {
                window.__cmuxTraceInstalled = true;
                window.addEventListener('error', (event) => window.__cmuxTrace.push({
                    type: 'error', message: String(event.message || ''), time: performance.now()
                }));
                window.addEventListener('load', () => window.__cmuxTrace.push({ type: 'load', time: performance.now() }));
            }
        """

    def _browser_trace_payload(self, pane: Pane) -> dict[str, Any]:
        payload = self._run_browser_payload(
            pane,
            """(() => ({
                ok: true,
                events: window.__cmuxTrace || [],
                performance: performance.getEntries().slice(-250).map((entry) => ({
                    name: entry.name, entryType: entry.entryType, startTime: entry.startTime, duration: entry.duration
                }))
            }))()""",
        )
        return {
            "started_at": pane.browser_trace_started_at,
            "events": payload.get("events") if isinstance(payload.get("events"), list) else [],
            "performance": payload.get("performance") if isinstance(payload.get("performance"), list) else [],
        }

    def _network_requests_expression(self) -> str:
        return """(() => ({
            ok: true,
            requests: performance.getEntriesByType('resource').map((entry) => ({
                url: entry.name, name: entry.name, initiatorType: entry.initiatorType,
                startTime: entry.startTime, duration: entry.duration,
                transferSize: entry.transferSize || 0, encodedBodySize: entry.encodedBodySize || 0
            }))
        }))()"""

    def _pointer_event_expression(self, params: dict[str, Any], touch: bool) -> str:
        selector = str(params.get("selector") or "")
        event_type = str(params.get("type") or params.get("event") or ("touchstart" if touch else "click"))
        x = float(params.get("x") or params.get("clientX") or 0)
        y = float(params.get("y") or params.get("clientY") or 0)
        return f"""(() => {{
            const selector = {js_literal(selector)};
            const type = {js_literal(event_type)};
            let x = {x};
            let y = {y};
            const el = selector ? document.querySelector(selector) : document.elementFromPoint(x, y);
            if (!el) {{ return {{ ok: false, error: 'Element not found' }}; }}
            if (selector) {{
                const rect = el.getBoundingClientRect();
                x = rect.left + rect.width / 2;
                y = rect.top + rect.height / 2;
            }}
            const eventInit = {{ bubbles: true, cancelable: true, clientX: x, clientY: y }};
            el.dispatchEvent(new MouseEvent(type.replace('touch', 'mouse'), eventInit));
            return {{ ok: true, event: {{ type, x, y, selector: selector || null }} }};
        }})()"""

    def _surface_action_status(self, surface: Surface, action: str) -> dict[str, Any]:
        snapshot = surface.snapshot().to_json()
        return {
            **snapshot,
            "action": action,
            "pinned": action == "pin",
            "unread": action == "mark_unread",
            "workspace_id": self._workspace_for_surface(surface.id).id,
        }

    def _browser_wait_condition(self, pane: Pane, params: dict[str, Any]) -> bool:
        root_expr = self._browser_root_expression(pane)
        if params.get("selector"):
            selector = self._selector_from_params(pane, params)
            payload = self._run_browser_payload(
                pane,
                f"(() => {{ const root = {root_expr}; return {{ ok: true, value: !!root.querySelector({js_literal(selector)}) }}; }})()",
                timeout_ms=1000,
            )
            return bool(payload.get("value"))
        if params.get("function"):
            expression = str(params.get("function") or "")
            payload = self._run_browser_payload(
                pane,
                f"(() => {{ try {{ return {{ ok: true, value: !!((0, eval)({js_literal(expression)})) }}; }} catch (_error) {{ return {{ ok: true, value: false }}; }} }})()",
                timeout_ms=1000,
            )
            return bool(payload.get("value"))
        if params.get("text_contains"):
            text = str(params.get("text_contains") or "")
            payload = self._run_browser_payload(
                pane,
                f"(() => {{ const root = {root_expr}; return {{ ok: true, value: (root.body ? (root.body.innerText || root.body.textContent || '') : '').includes({js_literal(text)}) }}; }})()",
                timeout_ms=1000,
            )
            return bool(payload.get("value"))
        if params.get("load_state"):
            state = str(params.get("load_state") or "").lower()
            payload = self._run_browser_payload(pane, "(() => ({ ok: true, value: document.readyState }))()", timeout_ms=1000)
            ready = str(payload.get("value") or "").lower()
            return ready == state or (state in {"load", "loaded"} and ready == "complete")
        if params.get("url_contains"):
            url = str(params.get("url_contains") or "")
            web_view = self._browser_web_view(pane)
            live_url = (
                str(web_view.get_uri() or pane.url or "")
                if web_view is not None and hasattr(web_view, "get_uri")
                else str(pane.url or "")
            )
            return url in live_url
        return True

    def _element_value_from_params(self, params: dict[str, Any], expression: str) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        payload = self._element_action(pane, params, f"return {{ value: {expression} }};")
        return {"value": payload.get("value"), "surface_id": surface.id, "pane_id": pane.id}

    def _element_action(self, pane: Pane, params: dict[str, Any], body: str) -> dict[str, Any]:
        selector = self._selector_from_params(pane, params)
        root_expr = self._browser_root_expression(pane)
        return self._run_browser_payload(
            pane,
            f"""(() => {{
                const root = {root_expr};
                const el = root.querySelector({js_literal(selector)});
                if (!el) {{ return {{ ok: false, error: 'Element not found' }}; }}
                try {{
                    const result = (() => {{ {body} }})();
                    return {{ ok: true, ...(result || {{}}) }};
                }} catch (error) {{
                    return {{ ok: false, error: String(error && error.message ? error.message : error) }};
                }}
            }})()""",
        )

    def _find_browser_element(
        self,
        params: dict[str, Any],
        selector: str,
        text: str = "",
        attr: str | None = None,
    ) -> dict[str, Any]:
        surface, pane = self._require_browser_pane(params)
        root_expr = self._browser_root_expression(pane)
        payload = self._run_browser_payload(
            pane,
            f"""(() => {{
                const root = {root_expr};
                const wanted = {js_literal(text)}.toLowerCase();
                const attr = {js_literal(attr)};
                const cssPath = (el) => el.id ? `#${{CSS.escape(el.id)}}` : {js_literal(selector)};
                const nodes = Array.from(root.querySelectorAll({js_literal(selector)}));
                const el = nodes.find((node) => {{
                    const source = attr ? (node.getAttribute(attr) || '') : (node.getAttribute('aria-label') || node.value || node.innerText || node.textContent || '');
                    return !wanted || String(source).toLowerCase().includes(wanted);
                }});
                if (!el) {{ return {{ ok: false, error: 'Element not found' }}; }}
                return {{ ok: true, selector: cssPath(el) }};
            }})()""",
        )
        return self._register_browser_ref(surface, pane, str(payload.get("selector") or selector))

    def _register_browser_ref(self, surface: Surface, pane: Pane, selector: str) -> dict[str, Any]:
        if not selector:
            raise ValueError(_("Element not found."))
        ref = f"@e{len(pane.browser_refs) + 1}"
        pane.browser_refs = {**pane.browser_refs, ref: selector}
        return {"element_ref": ref, "selector": selector, "surface_id": surface.id, "pane_id": pane.id}

    def _selector_from_params(self, pane: Pane, params: dict[str, Any], required: bool = True) -> str:
        raw = str(params.get("selector") or params.get("element_ref") or params.get("ref") or "")
        if raw in pane.browser_refs:
            return pane.browser_refs[raw]
        if raw.startswith("@e") and raw not in pane.browser_refs:
            raise ValueError(_("Element reference not found."))
        if not raw and required:
            raise ValueError(_("Missing selector."))
        return raw

    def _bootstrap_browser_pane(self, pane: Pane) -> bool:
        if pane.kind != "browser" or not WEBKIT_AVAILABLE:
            return False
        bootstrap = """
            (() => {
                if (!window.__cmuxConsole) { window.__cmuxConsole = []; }
                if (!window.__cmuxErrors) { window.__cmuxErrors = []; }
                if (!window.__cmuxConsoleInstalled) {
                    window.__cmuxConsoleInstalled = true;
                    const originalLog = console.log.bind(console);
                    const originalError = console.error.bind(console);
                    console.log = (...args) => { window.__cmuxConsole.push({ level: 'log', text: args.map(String).join(' ') }); originalLog(...args); };
                    console.error = (...args) => { window.__cmuxConsole.push({ level: 'error', text: args.map(String).join(' ') }); window.__cmuxErrors.push({ text: args.map(String).join(' ') }); originalError(...args); };
                    window.addEventListener('error', (event) => window.__cmuxErrors.push({ text: String(event.message || event.error || '') }));
                }
                return true;
            })()
        """
        try:
            self._run_browser_js(pane, bootstrap, timeout_ms=1000)
            for script in pane.init_scripts:
                self._run_browser_js(pane, script, timeout_ms=1000)
        except Exception:  # noqa: BLE001
            return False
        return False

    def _run_browser_payload(
        self,
        pane: Pane,
        expression: str,
        timeout_ms: int = DEFAULT_BROWSER_TIMEOUT_MS,
    ) -> dict[str, Any]:
        raw = self._run_browser_js(pane, f"JSON.stringify({expression})", timeout_ms=timeout_ms)
        payload = json.loads(raw) if isinstance(raw, str) and raw else raw
        if not isinstance(payload, dict):
            raise ValueError(_("Browser command returned invalid payload."))
        if not payload.get("ok", False):
            raise ValueError(str(payload.get("error") or _("Browser command failed.")))
        return payload

    def _run_browser_js(self, pane: Pane, script: str, timeout_ms: int = DEFAULT_BROWSER_TIMEOUT_MS) -> Any:
        if pane.kind != "browser" or not WEBKIT_AVAILABLE or WebKit is None:
            raise ValueError(_("Browser scripting requires WebKitGTK."))
        web_view = self._browser_web_view(pane)
        if web_view is None:
            raise ValueError(_("Browser scripting is unavailable."))
        if not hasattr(web_view, "run_javascript") and not hasattr(web_view, "evaluate_javascript"):
            raise ValueError(_("Browser scripting is unavailable."))

        result_box: dict[str, Any] = {}
        loop = GLib.MainLoop()
        timed_out = {"value": False}

        def finish(widget: Any, async_result: Any, _user_data: Any = None) -> None:
            try:
                if hasattr(widget, "evaluate_javascript_finish"):
                    js_value = widget.evaluate_javascript_finish(async_result)
                else:
                    js_result = widget.run_javascript_finish(async_result)
                    js_value = js_result.get_js_value()
                result_box["value"] = self._jsc_value_to_python(js_value)
            except Exception as error:  # noqa: BLE001
                result_box["error"] = error
            finally:
                loop.quit()

        def timeout() -> bool:
            timed_out["value"] = True
            loop.quit()
            return False

        timeout_id = GLib.timeout_add(max(1, int(timeout_ms)), timeout)
        try:
            if hasattr(web_view, "evaluate_javascript"):
                web_view.evaluate_javascript(script, len(script), None, None, None, finish, None)
            else:
                web_view.run_javascript(script, None, finish, None)
            loop.run()
        finally:
            try:
                GLib.source_remove(timeout_id)
            except Exception:  # noqa: BLE001
                pass

        if timed_out["value"]:
            raise TimeoutError(_("Browser JavaScript timed out."))
        if "error" in result_box:
            raise result_box["error"]
        return result_box.get("value")

    def _jsc_value_to_python(self, value: Any) -> Any:
        if value is None:
            return None
        if hasattr(value, "get_js_value"):
            value = value.get_js_value()
        try:
            if value.is_null() or value.is_undefined():
                return None
            if value.is_boolean():
                return bool(value.to_boolean())
            if value.is_number():
                return value.to_double()
            if value.is_string():
                return value.to_string()
            if value.is_object() or value.is_array():
                return json.loads(value.to_json(0))
        except Exception:  # noqa: BLE001
            return str(value)
        return str(value)

    def _capture_widget_png(self, widget: Gtk.Widget) -> bytes | None:
        if GTK_MAJOR < 4 and Gdk is not None and hasattr(widget, "get_window"):
            window = widget.get_window()
            allocation = widget.get_allocation()
            if window is None or allocation.width <= 0 or allocation.height <= 0:
                return None
            pixbuf = Gdk.pixbuf_get_from_window(window, allocation.x, allocation.y, allocation.width, allocation.height)
            if pixbuf is None:
                return None
            success, data = pixbuf.save_to_bufferv("png", [], [])
            return bytes(data) if success else None
        return None

    def create_notification(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace, surface = self._notification_context(params)
        return self._create_notification(params, workspace, surface, {})

    def create_notification_for_surface(self, params: dict[str, Any]) -> dict[str, Any]:
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref") or params.get("id"),
            "surface",
        )
        if not surface_id:
            raise ValueError(_("Missing surface_id."))
        workspace = self._workspace_from_params(params)
        surface = workspace.surfaces.get(surface_id)
        if surface is None:
            if any(key in params for key in ("workspaceId", "workspace_id", "workspace_ref")):
                raise ValueError(_("Surface not found."))
            workspace = self._workspace_for_surface(surface_id)
            surface = workspace.surfaces[surface_id]
        return self._create_notification(params, workspace, surface, {"surface_id": surface.id})

    def create_notification_for_target(self, params: dict[str, Any]) -> dict[str, Any]:
        if not any(key in params for key in ("workspaceId", "workspace_id", "workspace_ref")):
            raise ValueError(_("Missing workspace_id."))
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref") or params.get("id"),
            "surface",
        )
        if not surface_id:
            raise ValueError(_("Missing surface_id."))
        workspace = self._workspace_from_params(params)
        surface = workspace.surfaces.get(surface_id)
        if surface is None:
            raise ValueError(_("Surface not found."))
        return self._create_notification(
            params,
            workspace,
            surface,
            {"workspace_id": workspace.id, "surface_id": surface.id},
        )

    def list_notifications(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace_id = parse_ref(params.get("workspaceId") or params.get("workspace_id") or params.get("workspace_ref"), "workspace")
        surface_id = parse_ref(params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref"), "surface")
        notifications = [
            notification.to_json()
            for notification in self.notifications
            if (not workspace_id or notification.workspace_id == workspace_id)
            and (not surface_id or notification.surface_id == surface_id)
        ]
        return {"notifications": notifications}

    def clear_notifications(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace_id = parse_ref(params.get("workspaceId") or params.get("workspace_id") or params.get("workspace_ref"), "workspace")
        surface_id = parse_ref(params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref"), "surface")
        retained = [
            notification
            for notification in self.notifications
            if (workspace_id and notification.workspace_id != workspace_id)
            or (surface_id and notification.surface_id != surface_id)
        ]
        cleared = len(self.notifications) - len(retained)
        self.notifications = retained
        return {"cleared": cleared, "notifications": [notification.to_json() for notification in self.notifications]}

    def debug_terminals_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace_id = parse_ref(params.get("workspaceId") or params.get("workspace_id") or params.get("workspace_ref"), "workspace")
        workspaces = [
            workspace
            for workspace in self.workspaces.values()
            if not workspace_id or workspace.id == workspace_id
        ]
        if workspace_id and not workspaces:
            raise ValueError(_("Workspace not found."))
        terminals = []
        for workspace in workspaces:
            terminals.extend(self._debug_terminal_items(workspace))
        return {
            "backend": LINUX_TERMINAL_BACKEND,
            "window_id": self.window_id,
            "window_ref": self._window_ref(),
            "terminal_count": len(terminals),
            "renderer": linux_terminal_renderer_capability(),
            "scanner": linux_port_scanner_capability(),
            "terminals": terminals,
        }

    def save_runtime_state(self) -> None:
        self._save_runtime_state()

    def _load_runtime_state(self) -> None:
        try:
            with self.state_path.open("r", encoding="utf-8") as handle:
                state = json.load(handle)
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return
        if not isinstance(state, dict):
            return

        auth = state.get("auth") if isinstance(state.get("auth"), dict) else {}
        self.auth_signed_in = bool(auth.get("signed_in"))
        self.auth_signed_in_at = self._optional_float(auth.get("signed_in_at"))

        feedback = state.get("feedback") if isinstance(state.get("feedback"), dict) else {}
        self.feedback_opened_at = self._optional_float(feedback.get("opened_at"))
        self.feedback_submissions = self._bounded_dict_list(
            feedback.get("submissions"),
            MAX_PERSISTED_FEEDBACK_SUBMISSIONS,
        )

        feed = state.get("feed") if isinstance(state.get("feed"), dict) else {}
        self.feed_items = self._bounded_dict_list(feed.get("items"), MAX_PERSISTED_FEED_ITEMS)
        self.feed_replies = self._string_dict_mapping(feed.get("replies"))

        session = state.get("session")
        if isinstance(session, dict) and isinstance(session.get("workspaces"), list):
            self.saved_session_snapshot = dict(session)

    def _save_runtime_state(self) -> None:
        if self._suspend_state_save or not self._owns_runtime_state:
            return
        payload = self._runtime_state_payload()
        try:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            temporary_path = self.state_path.with_name(f".{self.state_path.name}.tmp")
            with temporary_path.open("w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2, sort_keys=True)
                handle.write("\n")
            try:
                os.chmod(temporary_path, stat.S_IRUSR | stat.S_IWUSR)
            except OSError:
                pass
            os.replace(temporary_path, self.state_path)
            self.saved_session_snapshot = payload["session"]
        except OSError:
            return

    def _runtime_state_payload(self) -> dict[str, Any]:
        return {
            "schema_version": LINUX_STATE_SCHEMA_VERSION,
            "saved_at": time.time(),
            "auth": {
                "signed_in": self.auth_signed_in,
                "signed_in_at": self.auth_signed_in_at,
            },
            "feedback": {
                "opened_at": self.feedback_opened_at,
                "submissions": self.feedback_submissions[-MAX_PERSISTED_FEEDBACK_SUBMISSIONS:],
            },
            "feed": {
                "items": self.feed_items[-MAX_PERSISTED_FEED_ITEMS:],
                "replies": dict(self.feed_replies),
            },
            "session": self._session_snapshot(),
        }

    def _session_snapshot(self) -> dict[str, Any]:
        return {
            "saved_at": time.time(),
            "current_workspace_id": self.current_workspace_id,
            "previous_workspace_id": self.previous_workspace_id,
            "workspaces": [self._workspace_session_snapshot(workspace) for workspace in self.workspaces.values()],
        }

    def _workspace_session_snapshot(self, workspace: Workspace) -> dict[str, Any]:
        return {
            "id": workspace.id,
            "name": workspace.name,
            "description": workspace.description,
            "custom_description": workspace.description,
            "color": workspace.custom_color,
            "custom_color": workspace.custom_color,
            "is_pinned": workspace.is_pinned,
            "pinned": workspace.is_pinned,
            "current_surface_id": workspace.current_surface_id,
            "remote_configuration": self._copy_json_object(workspace.remote_configuration),
            "remote_state": workspace.remote_state,
            "remote_foreground_auth_ready_at": workspace.remote_foreground_auth_ready_at,
            "remote_terminal_session_ends": [
                dict(item) for item in workspace.remote_terminal_session_ends[-MAX_PERSISTED_REMOTE_EVENTS:]
            ],
            "surfaces": [self._surface_session_snapshot(surface) for surface in workspace.surfaces.values()],
        }

    def _surface_session_snapshot(self, surface: Surface) -> dict[str, Any]:
        return {
            "id": surface.id,
            "title": surface.title,
            "cwd": surface.cwd,
            "current_pane_id": surface.current_pane_id,
            "previous_pane_id": surface.previous_pane_id,
            "panes": [self._pane_session_snapshot(pane) for pane in surface.panes.values()],
        }

    def _pane_session_snapshot(self, pane: Pane) -> dict[str, Any]:
        return {
            "id": pane.id,
            "kind": pane.kind,
            "title": pane.title,
            "cwd": pane.cwd,
            "url": pane.url,
            "browser_frame_selector": pane.browser_frame_selector,
            "browser_viewport": self._copy_json_object(pane.browser_viewport),
            "browser_geolocation": self._copy_json_object(pane.browser_geolocation),
            "browser_offline": pane.browser_offline,
            "browser_dialog_policy": self._copy_json_object(pane.browser_dialog_policy),
        }

    def _copy_json_object(self, value: Any) -> dict[str, Any] | None:
        if not isinstance(value, dict):
            return None
        return json.loads(json.dumps(value))

    def _bounded_dict_list(self, value: Any, limit: int) -> list[dict[str, Any]]:
        if not isinstance(value, list):
            return []
        items = [dict(item) for item in value if isinstance(item, dict)]
        return items[-limit:]

    def _string_dict_mapping(self, value: Any) -> dict[str, dict[str, Any]]:
        if not isinstance(value, dict):
            return {}
        return {
            str(key): dict(item)
            for key, item in value.items()
            if isinstance(key, str) and isinstance(item, dict)
        }

    def _optional_float(self, value: Any) -> float | None:
        if value is None:
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    def _restore_session_snapshot(self, snapshot: dict[str, Any]) -> int:
        workspaces = [item for item in snapshot.get("workspaces", []) if isinstance(item, dict)]
        if not workspaces:
            return 0
        previous_suspend = self._suspend_state_save
        self._suspend_state_save = True
        try:
            for workspace in self.workspaces.values():
                for surface in workspace.surfaces.values():
                    self._remove_stack_child(surface.root_widget)
            self.workspaces = {}
            for workspace_data in workspaces:
                workspace = self._restore_workspace_snapshot(workspace_data)
                self.workspaces = {**self.workspaces, workspace.id: workspace}
            current_id = str(snapshot.get("current_workspace_id") or "")
            if current_id not in self.workspaces:
                current_id = next(iter(self.workspaces), "")
            if not current_id:
                self.create_workspace(_("Default"), os.getcwd())
                current_id = self.current_workspace_id or ""
            self.current_workspace_id = current_id
            previous_id = str(snapshot.get("previous_workspace_id") or "")
            self.previous_workspace_id = previous_id if previous_id in self.workspaces else None
            current_workspace = self._current_workspace()
            if current_workspace.current_surface_id:
                self.stack.set_visible_child_name(current_workspace.current_surface_id)
            self.refresh_sidebar()
            return len(self.workspaces)
        finally:
            self._suspend_state_save = previous_suspend

    def _restore_workspace_snapshot(self, data: dict[str, Any]) -> Workspace:
        workspace_id = self._snapshot_id(data.get("id"))
        workspace = Workspace(
            id=workspace_id,
            name=str(data.get("name") or _("Workspace")),
            description=normalize_workspace_description(
                data.get("description") or data.get("custom_description") or data.get("customDescription")
            ),
            custom_color=normalize_workspace_color(data.get("color") or data.get("custom_color") or data.get("customColor")),
            is_pinned=bool(data.get("is_pinned") or data.get("pinned") or data.get("isPinned")),
            remote_configuration=self._copy_json_object(data.get("remote_configuration")),
            remote_state=str(data.get("remote_state") or "local"),
            remote_foreground_auth_ready_at=self._optional_float(data.get("remote_foreground_auth_ready_at")),
            remote_terminal_session_ends=self._bounded_dict_list(
                data.get("remote_terminal_session_ends"),
                MAX_PERSISTED_REMOTE_EVENTS,
            ),
        )
        for surface_data in data.get("surfaces", []):
            if not isinstance(surface_data, dict):
                continue
            surface = self._restore_surface_snapshot(surface_data)
            workspace.surfaces = {**workspace.surfaces, surface.id: surface}
        if not workspace.surfaces:
            surface = self._restore_surface_snapshot({"cwd": os.getcwd(), "panes": [{"kind": "terminal"}]})
            workspace.surfaces = {surface.id: surface}
        current_surface_id = self._snapshot_id(data.get("current_surface_id"), allow_empty=True)
        workspace.current_surface_id = current_surface_id if current_surface_id in workspace.surfaces else next(iter(workspace.surfaces))
        return workspace

    def _restore_surface_snapshot(self, data: dict[str, Any]) -> Surface:
        surface_id = self._snapshot_id(data.get("id"))
        panes = [
            self._restore_pane_snapshot(surface_id, item, str(data.get("cwd") or os.getcwd()))
            for item in data.get("panes", [])
            if isinstance(item, dict)
        ]
        if not panes:
            panes = [self._restore_pane_snapshot(surface_id, {"kind": "terminal"}, str(data.get("cwd") or os.getcwd()))]
        root = panes[0].widget
        for pane in panes[1:]:
            root = self._build_paned(Gtk.Orientation.HORIZONTAL, root, pane.widget)
        surface = Surface(
            id=surface_id,
            title=str(data.get("title") or panes[0].title),
            cwd=str(data.get("cwd") or panes[0].cwd or os.getcwd()),
            root_widget=root,
            panes={pane.id: pane for pane in panes},
            current_pane_id=None,
            previous_pane_id=None,
        )
        current_pane_id = self._snapshot_id(data.get("current_pane_id"), allow_empty=True)
        previous_pane_id = self._snapshot_id(data.get("previous_pane_id"), allow_empty=True)
        surface.current_pane_id = current_pane_id if current_pane_id in surface.panes else panes[0].id
        surface.previous_pane_id = previous_pane_id if previous_pane_id in surface.panes else None
        self.stack.add_titled(surface.root_widget, surface.id, surface.title)
        if GTK_MAJOR < 4:
            surface.root_widget.show_all()
        return surface

    def _restore_pane_snapshot(self, surface_id: str, data: dict[str, Any], fallback_cwd: str) -> Pane:
        kind = str(data.get("kind") or "terminal")
        if kind == "browser" and WEBKIT_AVAILABLE:
            pane = self._build_browser_pane(surface_id, normalize_url(str(data.get("url") or DEFAULT_BROWSER_URL)))
        else:
            pane = self._build_terminal_pane(surface_id, str(data.get("cwd") or fallback_cwd), None)
            kind = "terminal"
        pane.id = self._snapshot_id(data.get("id"))
        pane.kind = kind
        pane.title = str(data.get("title") or pane.title)
        pane.cwd = str(data.get("cwd") or fallback_cwd) if kind == "terminal" else None
        pane.url = str(data.get("url") or pane.url or "") or None
        pane.browser_frame_selector = data.get("browser_frame_selector") if isinstance(data.get("browser_frame_selector"), str) else None
        pane.browser_viewport = self._copy_json_object(data.get("browser_viewport"))
        pane.browser_geolocation = self._copy_json_object(data.get("browser_geolocation"))
        pane.browser_offline = bool(data.get("browser_offline"))
        pane.browser_dialog_policy = self._copy_json_object(data.get("browser_dialog_policy"))
        return pane

    def _snapshot_id(self, value: Any, allow_empty: bool = False) -> str:
        if isinstance(value, str) and value:
            return value
        return "" if allow_empty else str(uuid.uuid4())

    def _auth_backend_detail(self, bridge: Path | None) -> str:
        if bridge is not None:
            return "auth_bridge_available"
        if self.auth_backend_last_error:
            return f"local_fallback:{self.auth_backend_last_error}"
        return "auth_bridge_unconfigured"

    def _call_auth_bridge(self, method: str, params: dict[str, Any]) -> dict[str, Any] | None:
        bridge = find_auth_bridge_binary()
        if bridge is None:
            return None
        invocation = build_auth_bridge_invocation(bridge, method, params)
        try:
            completed = subprocess.run(
                invocation["command"],
                input=invocation["stdin"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=15,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            self.auth_backend_last_error = str(error)
            return None
        if completed.returncode != 0:
            self.auth_backend_last_error = completed.stderr.decode("utf-8", errors="replace").strip()
            return None
        try:
            value = json.loads(completed.stdout.decode("utf-8"))
        except json.JSONDecodeError as error:
            self.auth_backend_last_error = str(error)
            return None
        try:
            result = normalize_auth_bridge_result(value)
        except ValueError as error:
            self.auth_backend_last_error = str(error)
            return None
        self.auth_backend_last_error = None
        return result

    def auth_login_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        bridge_result = self._call_auth_bridge("auth.login", params)
        if bridge_result is not None:
            signed_in = bool(bridge_result.get("signed_in") or bridge_result.get("authenticated"))
            self.auth_signed_in = signed_in
            self.auth_signed_in_at = time.time() if signed_in else None
            self._save_runtime_state()
            return bridge_result
        self.auth_signed_in = True
        self.auth_signed_in_at = time.time()
        self._save_runtime_state()
        return self._auth_status_payload(timed_out=False)

    def auth_status_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        bridge_result = self._call_auth_bridge("auth.status", params)
        if bridge_result is not None:
            signed_in = bool(bridge_result.get("signed_in") or bridge_result.get("authenticated"))
            self.auth_signed_in = signed_in
            self.auth_signed_in_at = time.time() if signed_in and not self.auth_signed_in_at else self.auth_signed_in_at
            self._save_runtime_state()
            return bridge_result
        return self._auth_status_payload(timed_out=False)

    def auth_begin_sign_in_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        timeout = params.get("timeout_seconds", 300)
        try:
            timeout_seconds = float(timeout)
        except (TypeError, ValueError):
            raise ValueError(_("auth.begin_sign_in timeout_seconds must be numeric."))
        if timeout_seconds < 0:
            raise ValueError(_("auth.begin_sign_in timeout_seconds must be non-negative."))
        bridge_result = self._call_auth_bridge("auth.begin_sign_in", params)
        if bridge_result is not None:
            signed_in = bool(bridge_result.get("signed_in") or bridge_result.get("authenticated"))
            self.auth_signed_in = signed_in
            self.auth_signed_in_at = time.time() if signed_in else None
            self._save_runtime_state()
            return bridge_result
        self.auth_signed_in = True
        self.auth_signed_in_at = time.time()
        self._save_runtime_state()
        return self._auth_status_payload(timed_out=False)

    def auth_sign_out_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        bridge_result = self._call_auth_bridge("auth.sign_out", params)
        if bridge_result is not None:
            self.auth_signed_in = False
            self.auth_signed_in_at = None
            self._save_runtime_state()
            return bridge_result
        self.auth_signed_in = False
        self.auth_signed_in_at = None
        self._save_runtime_state()
        return self._auth_status_payload(timed_out=False)

    def configure_remote_workspace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        destination = str(params.get("destination") or "").strip()
        if not destination:
            raise ValueError(_("Missing destination."))
        validate_ssh_destination(destination)
        daemon = self._remote_daemon_installation_payload()
        if bool(params.get("auto_connect", True)) and not daemon.get("available"):
            raise BackendUnavailableError(_("Remote daemon is not available."))
        port = self._optional_port(params, "port")
        local_proxy_port = self._optional_port(params, "local_proxy_port")
        relay_port = self._optional_port(params, "relay_port")
        relay_id = str(params.get("relay_id") or "").strip()
        relay_token = str(params.get("relay_token") or "").strip()
        relay_metadata = None
        if relay_port is not None:
            if not relay_id:
                raise ValueError(_("relay_id is required when relay_port is set."))
            if len(relay_token) != 64 or any(char not in "0123456789abcdef" for char in relay_token):
                raise ValueError(_("relay_token must be 64 lowercase hex characters when relay_port is set."))
            relay_metadata = build_relay_metadata(
                relay_port=relay_port,
                relay_id=relay_id,
                relay_token=relay_token,
                daemon_path=str(daemon.get("path") or "") or None,
            )
        ssh_options = params.get("ssh_options") or []
        if not isinstance(ssh_options, list) or not all(isinstance(item, str) for item in ssh_options):
            raise ValueError(_("ssh_options must be an array of strings."))
        identity_file = str(params.get("identity_file") or "").strip() or None
        auto_connect = bool(params.get("auto_connect", True))
        effective_local_proxy_port = local_proxy_port if local_proxy_port is not None else relay_port
        lifecycle = build_remote_lifecycle_plan(
            destination=destination,
            port=port,
            identity_file=identity_file,
            ssh_options=list(ssh_options),
            local_proxy_port=effective_local_proxy_port,
            relay=relay_metadata,
            daemon_path=str(daemon.get("path") or "") or None,
            auto_connect=auto_connect,
        )
        workspace.remote_configuration = {
            "destination": destination,
            "port": port,
            "identity_file": identity_file,
            "ssh_options": list(ssh_options),
            "local_proxy_port": local_proxy_port,
            "effective_local_proxy_port": effective_local_proxy_port,
            "relay_port": relay_port,
            "relay_id": relay_id or None,
            "has_relay_token": bool(relay_token),
            "relay": relay_metadata,
            "local_socket_path": str(params.get("local_socket_path") or "").strip() or None,
            "terminal_startup_command": str(params.get("terminal_startup_command") or "").strip() or None,
            "has_foreground_auth_token": bool(str(params.get("foreground_auth_token") or "").strip()),
            "auto_connect": auto_connect,
            "daemon_path": daemon.get("path"),
            "daemon_probe": daemon.get("probe"),
            "daemon_ready": bool(daemon.get("available") and (daemon.get("probe") or {}).get("ok") is True),
            "lifecycle": lifecycle,
            "configured_at": time.time(),
        }
        if relay_token:
            self.remote_relay_tokens[workspace.id] = relay_token
        else:
            self.remote_relay_tokens.pop(workspace.id, None)
        workspace.remote_state = "configured"
        if auto_connect:
            try:
                self._start_remote_proxy_process(workspace)
            except TransportError:
                self._save_runtime_state()
                raise
        self._save_runtime_state()
        return self._remote_workspace_response(workspace)

    def remote_foreground_auth_ready_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        ready_at = time.time()
        workspace.remote_foreground_auth_ready_at = ready_at
        if workspace.remote_configuration is not None:
            process = self.remote_proxy_processes.get(workspace.id)
            transition = remote_foreground_auth_transition(
                configuration=workspace.remote_configuration,
                has_token=bool(str(params.get("foreground_auth_token") or "").strip()),
                ready_at=ready_at,
                proxy_running=process is not None and process.poll() is None,
            )
            next_configuration = transition.get("configuration")
            if isinstance(next_configuration, dict):
                workspace.remote_configuration = next_configuration
            if bool(transition.get("should_connect")):
                workspace.remote_state = "configured"
                try:
                    self._start_remote_proxy_process(workspace)
                except TransportError:
                    self._save_runtime_state()
                    raise
        self._save_runtime_state()
        return self._remote_workspace_response(workspace)

    def reconnect_remote_workspace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        if workspace.remote_configuration is None:
            raise ValueError(_("Remote workspace is not configured."))
        workspace.remote_configuration = {
            **workspace.remote_configuration,
            "lifecycle": self._remote_lifecycle_with_state(
                workspace.remote_configuration.get("lifecycle"),
                "reconnect_requested",
                "planned",
            ),
            "last_reconnect_requested_at": time.time(),
        }
        workspace.remote_state = "configured"
        if bool(workspace.remote_configuration.get("auto_connect")):
            try:
                self._start_remote_proxy_process(workspace)
            except TransportError:
                self._save_runtime_state()
                raise
        self._save_runtime_state()
        return self._remote_workspace_response(workspace)

    def disconnect_remote_workspace_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workspace = self._workspace_from_params(params)
        self._stop_remote_proxy_process(workspace.id)
        self.remote_relay_tokens.pop(workspace.id, None)
        if bool(params.get("clear")):
            workspace.remote_configuration = None
            workspace.remote_state = "local"
            workspace.remote_foreground_auth_ready_at = None
            workspace.remote_terminal_session_ends = []
        elif workspace.remote_configuration is not None:
            workspace.remote_configuration = {
                **workspace.remote_configuration,
                "lifecycle": self._remote_lifecycle_with_state(
                    workspace.remote_configuration.get("lifecycle"),
                    "disconnected",
                    "stopped",
                ),
                "disconnected_at": time.time(),
            }
            workspace.remote_state = "disconnected"
        self._save_runtime_state()
        return self._remote_workspace_response(workspace)

    def remote_workspace_status_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._remote_workspace_response(self._workspace_from_params(params))

    def remote_terminal_session_end_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        if not any(key in params for key in ("workspaceId", "workspace_id", "workspace_ref")):
            raise ValueError(_("Missing workspace_id."))
        workspace = self._workspace_from_params(params)
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref"),
            "surface",
        )
        if not surface_id or surface_id not in workspace.surfaces:
            raise ValueError(_("Missing or invalid surface_id."))
        surface = workspace.surfaces[surface_id]
        pane_id = parse_ref(
            params.get("paneId") or params.get("pane_id") or params.get("pane_ref"),
            "pane",
        )
        if pane_id and pane_id not in surface.panes:
            raise ValueError(_("Invalid pane_id."))
        relay_port = self._required_port(params, "relay_port")
        event = {
            "surface_id": surface_id,
            "surface_ref": f"surface:{surface_id}",
            "relay_port": relay_port,
            "ended_at": time.time(),
        }
        if pane_id:
            event = {
                **event,
                "pane_id": pane_id,
                "pane_ref": f"pane:{pane_id}",
            }
        workspace.remote_terminal_session_ends = [*workspace.remote_terminal_session_ends, event]
        self._save_runtime_state()
        result = {
            **self._remote_workspace_response(workspace),
            "surface_id": surface_id,
            "surface_ref": f"surface:{surface_id}",
            "relay_port": relay_port,
        }
        if pane_id:
            return {**result, "pane_id": pane_id, "pane_ref": f"pane:{pane_id}"}
        return result

    def _run_remote_bootstrap_and_probe(
        self,
        workspace: Workspace,
        config: dict[str, Any],
        relay: dict[str, Any] | None,
    ) -> dict[str, Any]:
        relay_token = self.remote_relay_tokens.get(workspace.id)
        if relay is not None and not relay_token:
            raise TransportError(_("Remote relay token is not available. Configure the workspace again."))
        daemon_path = str(config.get("daemon_path") or "") or None
        common = {
            "destination": str(config.get("destination") or ""),
            "port": config.get("port"),
            "identity_file": config.get("identity_file"),
            "ssh_options": list(config.get("ssh_options") or []),
        }
        bootstrap_invocation = build_remote_bootstrap_invocation(
            **common,
            relay=relay,
            relay_token=relay_token,
            daemon_path=daemon_path,
        )
        try:
            bootstrap_completed = subprocess.run(
                bootstrap_invocation["command"],
                input=bootstrap_invocation["stdin"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=15,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise TransportError(str(error)) from error
        if bootstrap_completed.returncode != 0:
            detail = bootstrap_completed.stderr.decode("utf-8", errors="replace").strip()
            raise TransportError(detail or _("Remote bootstrap failed."))

        probe_invocation = build_remote_stdio_probe_invocation(**common, daemon_path=daemon_path)
        try:
            probe_completed = subprocess.run(
                probe_invocation["command"],
                input=probe_invocation["stdin"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise TransportError(str(error)) from error
        probe = self._remote_stdio_probe_result(probe_completed)
        if probe.get("ok") is not True:
            raise TransportError(str(probe.get("detail") or _("Remote daemon stdio probe failed.")))
        completed_at = time.time()
        lifecycle = config.get("lifecycle") if isinstance(config.get("lifecycle"), dict) else {}
        bootstrap = lifecycle.get("bootstrap") if isinstance(lifecycle.get("bootstrap"), dict) else {}
        daemon = lifecycle.get("daemon") if isinstance(lifecycle.get("daemon"), dict) else {}
        workspace.remote_configuration = {
            **config,
            "daemon_ready": True,
            "remote_stdio_probe": probe,
            "last_bootstrap_completed_at": completed_at,
            "lifecycle": {
                **lifecycle,
                "state": "bootstrapped",
                "bootstrap": {**bootstrap, "state": "completed", "completed_at": completed_at},
                "daemon": {**daemon, "state": "ready", "probe": probe},
            },
        }
        return probe

    def _remote_stdio_probe_result(self, completed: subprocess.CompletedProcess[bytes]) -> dict[str, Any]:
        responses: list[dict[str, Any]] = []
        for line in completed.stdout.decode("utf-8", errors="replace").splitlines():
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                responses = [*responses, value]
        hello = next((item for item in responses if item.get("id") == "hello"), {})
        ping = next((item for item in responses if item.get("id") == "ping"), {})
        hello_result = hello.get("result") if isinstance(hello.get("result"), dict) else {}
        ping_result = ping.get("result") if isinstance(ping.get("result"), dict) else {}
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        return {
            "ok": completed.returncode == 0 and hello.get("ok") is True and ping.get("ok") is True,
            "hello": hello.get("ok") is True,
            "ping": ping.get("ok") is True and ping_result.get("pong") is True,
            "version": hello_result.get("version"),
            "capabilities": hello_result.get("capabilities") if isinstance(hello_result.get("capabilities"), list) else [],
            "exit_code": completed.returncode,
            "detail": stderr or None,
        }

    def _start_remote_proxy_process(self, workspace: Workspace) -> None:
        config = workspace.remote_configuration
        if not isinstance(config, dict) or not bool(config.get("auto_connect")):
            return
        relay = config.get("relay") if isinstance(config.get("relay"), dict) else None
        relay_port = relay.get("relay_port") if relay else None
        local_proxy_port = config.get("effective_local_proxy_port")
        self._stop_remote_proxy_process(workspace.id)
        try:
            self._run_remote_bootstrap_and_probe(workspace, config, relay)
            config = workspace.remote_configuration if isinstance(workspace.remote_configuration, dict) else config
        except TransportError as error:
            failed_at = time.time()
            workspace.remote_state = "disconnected"
            workspace.remote_configuration = {
                **config,
                "lifecycle": self._remote_lifecycle_with_state(config.get("lifecycle"), "failed", "failed"),
                "last_connect_error": str(error),
                "last_connect_failed_at": failed_at,
            }
            raise
        if relay is None or relay_port is None or local_proxy_port is None:
            workspace.remote_configuration = {
                **config,
                "lifecycle": self._remote_lifecycle_with_state(config.get("lifecycle"), "configured", "disabled"),
            }
            return
        try:
            relay_server = self._start_remote_relay_server(workspace, config, relay, int(local_proxy_port))
            argv = build_reverse_forward_argv(
                destination=str(config.get("destination") or ""),
                port=config.get("port"),
                identity_file=config.get("identity_file"),
                ssh_options=effective_ssh_options(list(config.get("ssh_options") or [])),
                relay_port=int(relay_port),
                local_proxy_port=int(local_proxy_port),
            )
            process = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except (OSError, ValueError, TransportError) as error:
            self._stop_remote_relay_server(workspace.id)
            failed_at = time.time()
            workspace.remote_state = "disconnected"
            workspace.remote_configuration = {
                **config,
                "lifecycle": self._remote_lifecycle_with_state(config.get("lifecycle"), "failed", "failed"),
                "last_connect_error": str(error),
                "last_connect_failed_at": failed_at,
            }
            if isinstance(error, TransportError):
                raise
            raise TransportError(str(error)) from error
        started_at = time.time()
        self.remote_proxy_processes[workspace.id] = process
        self.remote_proxy_heartbeats[workspace.id] = {"count": 1, "last_seen_at": started_at}
        workspace.remote_state = "connecting"
        workspace.remote_configuration = {
            **config,
            "lifecycle": self._remote_lifecycle_with_state(config.get("lifecycle"), "connecting", "running"),
            "last_connect_started_at": started_at,
            "proxy_pid": process.pid,
            "relay_server": relay_server.status(),
        }

    def _start_remote_relay_server(
        self,
        workspace: Workspace,
        config: dict[str, Any],
        relay: dict[str, Any],
        local_proxy_port: int,
    ) -> RemoteRelayServer:
        relay_token = self.remote_relay_tokens.get(workspace.id)
        relay_id = str(relay.get("relay_id") or "")
        if not relay_token or not relay_id:
            raise TransportError(_("Remote relay credentials are not available. Configure the workspace again."))
        self._stop_remote_relay_server(workspace.id)
        socket_path = Path(str(config.get("local_socket_path") or self.local_socket_path))
        relay_server = RemoteRelayServer(
            workspace_id=workspace.id,
            relay_id=relay_id,
            relay_token=relay_token,
            local_port=local_proxy_port,
            socket_path=socket_path,
        )
        try:
            relay_server.start()
        except OSError as error:
            raise TransportError(str(error)) from error
        self.remote_relay_servers[workspace.id] = relay_server
        return relay_server

    def _stop_remote_relay_server(self, workspace_id: str) -> None:
        relay_server = self.remote_relay_servers.pop(workspace_id, None)
        if relay_server is not None:
            relay_server.stop()

    def _stop_remote_proxy_process(self, workspace_id: str) -> None:
        self._stop_remote_relay_server(workspace_id)
        process = self.remote_proxy_processes.pop(workspace_id, None)
        self.remote_proxy_heartbeats.pop(workspace_id, None)
        if process is None or process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1)

    def _stop_all_remote_proxy_processes(self) -> None:
        for workspace_id in list(self.remote_proxy_processes):
            self._stop_remote_proxy_process(workspace_id)

    def _remote_proxy_runtime(self, workspace: Workspace, relay_configured: bool) -> dict[str, Any]:
        process = self.remote_proxy_processes.get(workspace.id)
        now = time.time()
        heartbeat = self.remote_proxy_heartbeats.get(workspace.id)
        if process is not None and process.poll() is None:
            previous_count = int((heartbeat or {}).get("count") or 0)
            heartbeat = {"count": previous_count + 1, "last_seen_at": now}
            self.remote_proxy_heartbeats[workspace.id] = heartbeat
            workspace.remote_state = "connected"
            if isinstance(workspace.remote_configuration, dict):
                workspace.remote_configuration = {
                    **workspace.remote_configuration,
                    "lifecycle": self._remote_lifecycle_with_state(
                        workspace.remote_configuration.get("lifecycle"),
                        "connected",
                        "running",
                    ),
                    "proxy_pid": process.pid,
                }
        process_pid = process.pid if process is not None else None
        process_returncode = process.poll() if process is not None else None
        return remote_proxy_runtime_status(
            relay_configured=relay_configured,
            process_pid=process_pid,
            process_returncode=process_returncode,
            workspace_state=workspace.remote_state,
            heartbeat=heartbeat,
            now=now,
        )

    def restore_previous_session_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        self.previous_session_restore_attempted_at = time.time()
        snapshot = self.saved_session_snapshot
        if isinstance(snapshot, dict) and snapshot.get("workspaces"):
            restored_count = self._restore_session_snapshot(snapshot)
            self._save_runtime_state()
            workspace = self._current_workspace()
            return {
                "restored": True,
                "available": True,
                "restored_workspace_count": restored_count,
                "workspace": self._workspace_payload(workspace),
                "workspace_id": workspace.id,
                "workspace_ref": f"workspace:{workspace.id}",
                "state_path": str(self.state_path),
            }
        workspace = self._current_workspace()
        self._save_runtime_state()
        return {
            "restored": False,
            "available": False,
            "reason": "no_persisted_session_snapshot",
            "workspace": self._workspace_payload(workspace),
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "state_path": str(self.state_path),
        }

    def open_feedback_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        self.feedback_opened_at = time.time()
        self._save_runtime_state()
        return {
            "opened": True,
            "platform": "linux",
            "native_ui": False,
            "opened_at": self.feedback_opened_at,
        }

    def _upload_feedback_submission(self, submission: dict[str, Any]) -> dict[str, Any] | None:
        endpoint = feedback_endpoint_url()
        if endpoint is None:
            return None
        image_paths = submission.get("image_paths") if isinstance(submission.get("image_paths"), list) else []
        request = build_feedback_upload_request(endpoint, submission, image_paths)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                body = response.read(1024 * 1024)
                if response.status < 200 or response.status >= 300:
                    raise TransportError(f"feedback upload returned HTTP {response.status}")
        except OSError as error:
            raise TransportError(str(error)) from error
        try:
            value = json.loads(body.decode("utf-8")) if body else {}
        except json.JSONDecodeError:
            value = {}
        return value if isinstance(value, dict) else {}

    def submit_feedback_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        email = params.get("email")
        body = params.get("body") if "body" in params else params.get("message")
        if not isinstance(email, str) or not email.strip():
            raise ValueError(_("Missing email."))
        if "@" not in email or email.startswith("@") or email.endswith("@"):
            raise ValueError(_("Invalid email."))
        if not isinstance(body, str) or not body.strip():
            raise ValueError(_("Missing body."))
        if len(body) > 20_000:
            raise ValueError(_("Feedback body is too long."))
        image_paths = params.get("image_paths") or []
        if not isinstance(image_paths, list) or not all(isinstance(path, str) for path in image_paths):
            raise ValueError(_("image_paths must be an array of paths."))
        missing_paths = [path for path in image_paths if not Path(path).is_file()]
        if missing_paths:
            raise ValueError(_("Feedback image path not found."))
        submission = {
            "id": str(uuid.uuid4()),
            "email": email.strip(),
            "body": body,
            "image_paths": list(image_paths),
            "submitted_at": time.time(),
            "platform": "linux",
            "transport": "pending",
        }
        transport_error = None
        upload_response = None
        try:
            upload_response = self._upload_feedback_submission(submission)
        except TransportError as error:
            transport_error = str(error)
        if transport_error is not None:
            queued = True
            transport = "local_queue"
            status = "queued"
            detail = "transport_error"
        elif upload_response is None:
            queued = True
            transport = "local_queue"
            status = "queued"
            detail = "feedback_endpoint_unconfigured"
        else:
            queued = False
            transport = "http_upload"
            status = "submitted"
            detail = "uploaded"
        submission = {
            **submission,
            "transport": transport,
            "status": status,
            "queued": queued,
            "detail": detail,
            "transport_error": transport_error,
            "upload_response": upload_response,
        }
        self.feedback_submissions = [*self.feedback_submissions, submission]
        self._save_runtime_state()
        return {
            "submitted": not queued,
            "queued": queued,
            "status": status,
            "transport": transport,
            "detail": detail,
            "error_code": "transport_error" if transport_error else None,
            "attachment_count": len(image_paths),
            "submission_id": submission["id"],
            "stored": True,
        }

    def push_feed_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        wait_timeout = self._feed_wait_timeout(params)
        event = self._feed_event_from_params(params)
        item = self._feed_item_from_event(event)
        request_id = item.get("request_id")
        existing_reply = self.feed_replies.get(request_id or "")
        if existing_reply is not None:
            item = resolve_feed_item(item, dict(existing_reply))
        self.feed_items = [*self.feed_items, item]
        self._save_runtime_state()
        return feed_push_response(
            item,
            wait_timeout_seconds=wait_timeout,
            decision=dict(existing_reply) if existing_reply is not None else None,
        )

    def reply_feed_permission_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        request_id = self._required_string(params, "request_id", "feed.permission.reply requires request_id")
        mode = self._required_string(params, "mode", "feed.permission.reply requires mode")
        decision = feed_permission_decision(mode)
        self._record_feed_reply(request_id, decision)
        self._save_runtime_state()
        return self._feed_reply_response(decision)

    def reply_feed_question_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        request_id = self._required_string(params, "request_id", "feed.question.reply requires request_id")
        selections = params.get("selections")
        decision = feed_question_decision(selections)
        self._record_feed_reply(request_id, decision)
        self._save_runtime_state()
        return self._feed_reply_response(decision)

    def reply_feed_exit_plan_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        request_id = self._required_string(params, "request_id", "feed.exit_plan.reply requires request_id")
        mode = self._required_string(params, "mode", "feed.exit_plan.reply requires mode")
        decision = feed_exit_plan_decision(mode, params.get("feedback"))
        self._record_feed_reply(request_id, decision)
        self._save_runtime_state()
        return self._feed_reply_response(decision)

    def jump_feed_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        workstream_id = self._required_string(params, "workstream_id", "feed.jump requires workstream_id")
        matched = any(item.get("workstream_id") == workstream_id for item in self.feed_items)
        return {"workstream_id": workstream_id, "matched": matched}

    def list_feed_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        pending_only = bool(params.get("pending_only"))
        items = [
            self._feed_public_item(item)
            for item in self.feed_items
            if not pending_only or item.get("status") == "pending"
        ]
        return {"items": items}

    def wait_for_feed_reply(self, request_id: str, timeout_seconds: float) -> dict[str, Any] | None:
        deadline = time.monotonic() + timeout_seconds
        with self.feed_reply_condition:
            while True:
                decision = self.feed_replies.get(request_id)
                if decision is not None:
                    return dict(decision)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self.feed_reply_condition.wait(timeout=remaining)

    def expire_feed_request(self, request_id: str) -> dict[str, Any]:
        expired_at = time.time()
        next_items = []
        expired = False
        for item in self.feed_items:
            if item.get("request_id") == request_id and item.get("status") == "pending":
                next_items.append(expire_feed_item(item, expired_at=expired_at))
                expired = True
            else:
                next_items.append(item)
        self.feed_items = next_items
        if expired:
            self._save_runtime_state()
        return {"expired": expired}

    def unsupported_method(self, method: str) -> dict[str, Any]:
        raise UnsupportedMethodError(method, f"{method} is not supported on Linux")

    def _auth_status_payload(self, timed_out: bool) -> dict[str, Any]:
        return build_local_auth_status_payload(
            signed_in=self.auth_signed_in,
            signed_in_at=self.auth_signed_in_at,
            timed_out=timed_out,
            detail=self._auth_backend_detail(None),
        )

    def _remote_workspace_response(self, workspace: Workspace) -> dict[str, Any]:
        return {
            "window_id": self.window_id,
            "window_ref": self._window_ref(),
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "remote": self._remote_status_payload(workspace),
        }

    def _remote_status_payload(self, workspace: Workspace) -> dict[str, Any]:
        config = workspace.remote_configuration
        daemon = self._remote_daemon_installation_payload()
        relay = config.get("relay") if isinstance(config, dict) and isinstance(config.get("relay"), dict) else None
        lifecycle = config.get("lifecycle") if isinstance(config, dict) and isinstance(config.get("lifecycle"), dict) else None
        runtime = self._remote_proxy_runtime(workspace, relay is not None)
        relay_server = self.remote_relay_servers.get(workspace.id)
        relay_server_status = relay_server.status() if relay_server is not None else None
        relay_state = runtime["proxy"]["state"] if relay is not None else "disabled"
        connected = bool(runtime["connected"])
        detail = None
        if config is not None:
            if connected:
                detail = f"{daemon.get('detail')}:ssh_proxy_running"
            elif runtime["proxy"].get("error_code"):
                detail = str(runtime["proxy"]["error_code"])
            else:
                detail = (
                    f"{daemon.get('detail')}:ssh_proxy_lifecycle_planned_on_linux"
                    if daemon["available"]
                    else "remote_daemon_not_available_on_linux"
                )
        forwarded_ports = []
        if relay is not None:
            forwarded_ports = [
                {
                    "remote_port": relay.get("relay_port"),
                    "local_host": "127.0.0.1",
                    "socket_addr": relay.get("socket_addr"),
                    "socket_addr_path": relay.get("remote_socket_addr_path"),
                    "auth_path": relay.get("relay_auth_path"),
                    "daemon_path_path": relay.get("relay_daemon_path_path"),
                    "relay_id": relay.get("relay_id"),
                    "state": relay_state,
                    "relay_server": relay_server_status,
                }
            ]
        active_sessions = active_terminal_sessions(
            workspace.surfaces.values(),
            workspace.remote_terminal_session_ends,
        )
        proxy_host = relay.get("reverse_forward", {}).get("host") if relay else None
        proxy_port = relay.get("relay_port") if relay else None
        proxy_url = f"socks5://{proxy_host}:{proxy_port}" if proxy_host and proxy_port else None
        return {
            "enabled": config is not None,
            "available": bool(daemon["available"]),
            "platform": "linux",
            "state": workspace.remote_state if config is not None else "local",
            "connected": connected,
            "active_terminal_sessions": active_sessions["count"],
            "active_terminal_session_details": active_sessions["sessions"],
            "daemon": {
                **daemon,
                "state": runtime["daemon"]["state"] if daemon["available"] else "unavailable",
                "pid": runtime["daemon"].get("pid") if daemon["available"] else None,
                "returncode": runtime["daemon"].get("returncode") if daemon["available"] else None,
            },
            "detected_ports": [],
            "forwarded_ports": forwarded_ports,
            "conflicted_ports": [],
            "detail": detail,
            "heartbeat": runtime["heartbeat"],
            "lifecycle": lifecycle,
            "proxy": {
                "state": relay_state,
                "host": proxy_host,
                "port": proxy_port,
                "schemes": ["socks5", "http_connect"],
                "url": proxy_url,
                "error_code": runtime["proxy"].get("error_code"),
                "relay_server": relay_server_status,
                "relay": relay,
                "lifecycle": lifecycle.get("proxy") if lifecycle else None,
            },
            "destination": config.get("destination") if config else None,
            "port": config.get("port") if config else None,
            "has_identity_file": bool(config and config.get("identity_file")),
            "has_ssh_options": bool(config and config.get("ssh_options")),
            "local_proxy_port": config.get("local_proxy_port") if config else None,
            "relay_port": config.get("relay_port") if config else None,
            "relay_id": config.get("relay_id") if config else None,
            "has_relay_token": bool(config and config.get("has_relay_token")),
            "has_foreground_auth_token": bool(config and config.get("has_foreground_auth_token")),
            "daemon_ready": bool(config and config.get("daemon_ready")),
            "relay": relay,
            "bootstrap": lifecycle.get("bootstrap") if lifecycle else None,
            "foreground_auth_ready": workspace.remote_foreground_auth_ready_at is not None,
            "foreground_auth_ready_at": workspace.remote_foreground_auth_ready_at,
            "foreground_auth": {
                "ready": workspace.remote_foreground_auth_ready_at is not None,
                "ready_at": workspace.remote_foreground_auth_ready_at,
                "has_token": bool(config and config.get("has_foreground_auth_token")),
            },
            "terminal_session_ends": [dict(item) for item in workspace.remote_terminal_session_ends],
            "configuration": self._remote_public_configuration(config),
        }

    def _remote_daemon_installation_payload(self) -> dict[str, Any]:
        path = find_remote_daemon_binary()
        if path is None:
            return {
                "available": False,
                "state": "missing",
                "path": None,
                "bundled": False,
                "pid": None,
                "detail": "remote_daemon_not_available_on_linux",
            }
        probe = remote_daemon_probe(path)
        detail = (
            "remote_daemon_hello_ping_ok"
            if probe.get("ok") is True
            else "remote_daemon_probe_failed"
        )
        return {
            "available": True,
            "state": "installed",
            "path": str(path),
            "bundled": path == bundled_remote_daemon_path(),
            "pid": None,
            "detail": detail,
            "probe": probe,
            "version": probe.get("version"),
            "capabilities": probe.get("capabilities") or [],
        }

    def _remote_public_configuration(self, config: dict[str, Any] | None) -> dict[str, Any] | None:
        if config is None:
            return None
        return {
            "destination": config.get("destination"),
            "port": config.get("port"),
            "has_identity_file": bool(config.get("identity_file")),
            "ssh_options": list(config.get("ssh_options") or []),
            "local_proxy_port": config.get("local_proxy_port"),
            "relay_port": config.get("relay_port"),
            "relay_id": config.get("relay_id"),
            "has_relay_token": bool(config.get("has_relay_token")),
            "relay": config.get("relay") if isinstance(config.get("relay"), dict) else None,
            "local_socket_path": config.get("local_socket_path"),
            "terminal_startup_command": config.get("terminal_startup_command"),
            "has_foreground_auth_token": bool(config.get("has_foreground_auth_token")),
            "daemon_path": config.get("daemon_path"),
            "daemon_ready": bool(config.get("daemon_ready")),
            "auto_connect": bool(config.get("auto_connect")),
            "effective_local_proxy_port": config.get("effective_local_proxy_port"),
            "last_reconnect_requested_at": config.get("last_reconnect_requested_at"),
            "last_connect_started_at": config.get("last_connect_started_at"),
            "last_connect_failed_at": config.get("last_connect_failed_at"),
            "last_connect_error": config.get("last_connect_error"),
            "disconnected_at": config.get("disconnected_at"),
            "foreground_auth_ready_at": config.get("foreground_auth_ready_at"),
            "proxy_pid": config.get("proxy_pid"),
            "lifecycle": self._copy_json_object(config.get("lifecycle")),
            "configured_at": config.get("configured_at"),
        }

    def _remote_lifecycle_with_state(
        self,
        lifecycle: Any,
        state: str,
        proxy_state: str | None = None,
    ) -> dict[str, Any] | None:
        if not isinstance(lifecycle, dict):
            return None
        proxy = lifecycle.get("proxy") if isinstance(lifecycle.get("proxy"), dict) else {}
        next_proxy = {**proxy, "state": proxy_state} if proxy_state is not None else proxy
        return {
            **lifecycle,
            "state": state,
            "proxy": next_proxy,
            "updated_at": time.time(),
        }

    def _optional_port(self, params: dict[str, Any], key: str) -> int | None:
        if key not in params or params.get(key) is None:
            return None
        return self._required_port(params, key)

    def _required_port(self, params: dict[str, Any], key: str) -> int:
        try:
            port = int(params.get(key))
        except (TypeError, ValueError):
            raise ValueError(_(f"{key} must be 1-65535."))
        if port < 1 or port > 65_535:
            raise ValueError(_(f"{key} must be 1-65535."))
        return port

    def _feed_wait_timeout(self, params: dict[str, Any]) -> float:
        try:
            return feed_wait_timeout(params)
        except ValueError as error:
            raise ValueError(_(str(error)))

    def _feed_event_from_params(self, params: dict[str, Any]) -> dict[str, Any]:
        try:
            return feed_event_from_params(params)
        except ValueError as error:
            raise ValueError(_(str(error)))

    def _feed_item_from_event(self, event: dict[str, Any]) -> dict[str, Any]:
        return feed_item_from_event(event)

    def _feed_kind(self, event: dict[str, Any]) -> str:
        return feed_kind(event)

    def _feed_request_id(self, event: dict[str, Any]) -> str | None:
        return feed_request_id(event)

    def _record_feed_reply(self, request_id: str, decision: dict[str, Any]) -> None:
        resolved_at = time.time()
        with self.feed_reply_condition:
            self.feed_replies = {**self.feed_replies, request_id: dict(decision)}
            self.feed_items = [
                (
                    resolve_feed_item(item, decision, resolved_at=resolved_at)
                    if item.get("request_id") == request_id
                    else item
                )
                for item in self.feed_items
            ]
            self.feed_reply_condition.notify_all()

    def _feed_reply_response(self, decision: dict[str, Any]) -> dict[str, Any]:
        return feed_reply_response(decision)

    def _feed_public_item(self, item: dict[str, Any]) -> dict[str, Any]:
        return feed_public_item(item)

    def _required_string(self, params: dict[str, Any], key: str, message: str) -> str:
        value = params.get(key)
        if not isinstance(value, str) or not value:
            raise ValueError(_(message))
        return value

    def _create_notification(
        self,
        params: dict[str, Any],
        workspace: Workspace | None,
        surface: Surface | None,
        target: dict[str, Any],
    ) -> dict[str, Any]:
        title = str(params.get("title") or DEFAULT_NOTIFICATION_TITLE)
        subtitle = str(params.get("subtitle") or "")
        body = str(params.get("body") or "")
        notification_record = LinuxNotification(
            id=str(uuid.uuid4()),
            workspace_id=workspace.id if workspace else None,
            surface_id=surface.id if surface else None,
            title=title,
            subtitle=subtitle,
            body=body,
            created_at=time.time(),
            target=target,
        )
        self.notifications = [*self.notifications, notification_record]
        notification = Gio.Notification.new(title)
        notification_body = "\n".join([item for item in (subtitle, body) if item])
        if notification_body:
            notification.set_body(notification_body)
        self.application.send_notification(notification_record.id, notification)
        payload = notification_record.to_json()
        return {"accepted": True, "notification_id": notification_record.id, "notification": payload, **payload}

    def _notification_context(self, params: dict[str, Any]) -> tuple[Workspace | None, Surface | None]:
        workspace = self._workspace_from_params(params) if params else self._current_workspace()
        surface_id = parse_ref(params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref"), "surface")
        if not surface_id:
            return workspace, workspace.surfaces.get(workspace.current_surface_id or "")
        surface = workspace.surfaces.get(surface_id)
        if surface is None:
            if any(key in params for key in ("workspaceId", "workspace_id", "workspace_ref")):
                raise ValueError(_("Surface not found."))
            workspace = self._workspace_for_surface(surface_id)
            surface = workspace.surfaces[surface_id]
        return workspace, surface

    def _debug_terminal_items(self, workspace: Workspace) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        workspace_index = list(self.workspaces.values()).index(workspace)
        for surface_index, surface in enumerate(workspace.surfaces.values()):
            for pane_index, pane in enumerate(surface.panes.values()):
                if pane.kind != "terminal":
                    continue
                items.append(
                    build_debug_terminal_item(
                        window_id=self.window_id,
                        window_ref=self._window_ref(),
                        workspace_id=workspace.id,
                        workspace_ref=f"workspace:{workspace.id}",
                        workspace_index=workspace_index,
                        workspace_title=workspace.name,
                        surface_id=surface.id,
                        surface_ref=f"surface:{surface.id}",
                        surface_index=surface_index,
                        surface_title=surface.title,
                        pane_id=pane.id,
                        pane_ref=f"pane:{pane.id}",
                        pane_index=pane_index,
                        pane_title=pane.title,
                        current_directory=pane.cwd,
                        focused=surface.current_pane_id == pane.id,
                        tty_name=self.surface_tty_names.get(surface.id),
                        pty_available=bool(hasattr(pane.widget, "get_pty")),
                        item_index=len(items),
                    )
                )
        return items

    def show_socket_error(self, message: str) -> bool:
        if hasattr(Gtk, "AlertDialog"):
            dialog = Gtk.AlertDialog(message=_("Socket server failed"), detail=message)
            dialog.show(self.window)
            return False

        dialog = Gtk.MessageDialog(
            transient_for=self.window,
            modal=True,
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.CLOSE,
            text=_("Socket server failed"),
        )
        dialog.format_secondary_text(message)
        dialog.connect("response", lambda dialog, *_: dialog.destroy())
        dialog.show()
        return False

    def refresh_sidebar(self) -> None:
        workspace = self._current_workspace()
        selected_row: Gtk.ListBoxRow | None = None
        handler_id = self._sidebar_selection_handler_id
        if handler_id is not None:
            self.sidebar.handler_block(handler_id)
        self._refreshing_sidebar = True
        try:
            if GTK_MAJOR >= 4:
                while child := self.sidebar.get_first_child():
                    self.sidebar.remove(child)
            else:
                for child in self.sidebar.get_children():
                    self.sidebar.remove(child)
            for surface in workspace.surfaces.values():
                row = Gtk.ListBoxRow()
                self._add_css_class(row, "cmux-sidebar-row")
                row.surface_id = surface.id  # type: ignore[attr-defined]
                label = Gtk.Label(label=surface.title, xalign=0.0)
                self._add_css_class(label, "cmux-sidebar-title")
                label.set_margin_top(8)
                label.set_margin_bottom(8)
                label.set_margin_start(12)
                label.set_margin_end(12)
                if GTK_MAJOR >= 4:
                    row.set_child(label)
                    self.sidebar.append(row)
                else:
                    row.add(label)
                    self.sidebar.add(row)
                if surface.id == workspace.current_surface_id:
                    selected_row = row
            if selected_row is not None:
                self.sidebar.select_row(selected_row)
            elif hasattr(self.sidebar, "unselect_all"):
                self.sidebar.unselect_all()
        finally:
            self._refreshing_sidebar = False
            if handler_id is not None:
                self.sidebar.handler_unblock(handler_id)
        if GTK_MAJOR < 4:
            self.sidebar.show_all()

    def select_surface(self, surface_id: str) -> None:
        workspace = self._current_workspace()
        if surface_id not in workspace.surfaces:
            return
        workspace.current_surface_id = surface_id
        self.stack.set_visible_child_name(surface_id)

    def _select_relative_surface(self, offset: int) -> None:
        workspace = self._current_workspace()
        surface_ids = list(workspace.surfaces.keys())
        if not surface_ids:
            return
        current_id = workspace.current_surface_id or surface_ids[0]
        current_index = surface_ids.index(current_id) if current_id in surface_ids else 0
        self.select_surface(surface_ids[(current_index + offset) % len(surface_ids)])
        self.refresh_sidebar()

    def _select_numbered_surface(self, token: str) -> bool:
        index = self._shortcut_number(token)
        if index is None:
            return False
        surface_ids = list(self._current_workspace().surfaces.keys())
        if index >= len(surface_ids):
            return False
        self.select_surface(surface_ids[index])
        self.refresh_sidebar()
        return True

    def _select_numbered_workspace(self, token: str) -> bool:
        index = self._shortcut_number(token)
        workspace_ids = list(self.workspaces.keys())
        if index is None or index >= len(workspace_ids):
            return False
        self.select_workspace_from_params({"workspace_id": workspace_ids[index]})
        return True

    def _shortcut_number(self, token: str) -> int | None:
        key = token.rsplit("+", 1)[-1]
        return int(key) - 1 if key.isdigit() and key != "0" else None

    def _focus_current_browser_address(self) -> None:
        _surface, pane = self._require_browser_pane({})
        if pane.browser_address_entry is not None:
            pane.browser_address_entry.grab_focus()

    def _show_command_palette(self) -> None:
        dialog = Gtk.Dialog(title=_("Command Palette"), transient_for=self.window, modal=True)
        content = dialog.get_content_area()
        content.set_spacing(6)
        for label, action in self._command_palette_actions():
            button = Gtk.Button(label=label)
            button.connect("clicked", lambda _button, callback=action, popup=dialog: self._run_palette_action(callback, popup))
            self._box_append(content, button, expand=False)
        dialog.set_default_size(320, -1)
        if GTK_MAJOR >= 4:
            dialog.present()
        else:
            dialog.show_all()

    def _command_palette_actions(self) -> tuple[tuple[str, Callable[[], Any]], ...]:
        return (
            (_("New Terminal"), lambda: self.create_surface()),
            (_("Open Browser"), lambda: self.open_browser_from_params({})),
            (_("Split Horizontally"), lambda: self.split_surface_from_params({"orientation": "horizontal"})),
            (_("Split Vertically"), lambda: self.split_surface_from_params({"orientation": "vertical"})),
            (_("Close Pane"), lambda: self.close_pane_from_params({})),
            (_("Settings"), lambda: self.open_settings_from_params({})),
            (_("Keyboard Shortcuts"), lambda: self.open_settings_from_params({"target": "keyboardShortcuts"})),
        )

    def _run_palette_action(self, action: Callable[[], Any], dialog: Gtk.Dialog) -> None:
        dialog.close()
        action()

    def _settings_target(self, target: Any) -> str:
        raw = str(target or "general").strip()
        normalized = raw.replace("-", "").replace("_", "").lower()
        if normalized in {"", "general"}:
            return "general"
        if normalized in {"keyboardshortcuts", "keyboard", "shortcuts"}:
            return "keyboardShortcuts"
        raise ValueError(_("Unknown settings target."))

    def _show_settings_dialog(self, target: str) -> None:
        title = _("Keyboard Shortcuts") if target == "keyboardShortcuts" else _("Settings")
        dialog = Gtk.Dialog(title=title, transient_for=self.window, modal=False)
        content = dialog.get_content_area()
        content.set_spacing(12)
        content.set_margin_top(12)
        content.set_margin_bottom(12)
        content.set_margin_start(12)
        content.set_margin_end(12)

        status_label = Gtk.Label(label="", xalign=0.0)
        status_label.set_hexpand(True)
        self._box_append(content, self._build_settings_path_row(status_label), expand=False)
        self._box_append(content, self._build_shortcut_editor(status_label), expand=True)
        self._box_append(content, status_label, expand=False)

        dialog.set_default_size(520, 520)
        if GTK_MAJOR >= 4:
            dialog.present()
        else:
            dialog.show_all()

    def _build_settings_path_row(self, status_label: Gtk.Label) -> Gtk.Widget:
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        label = Gtk.Label(label=_("Settings file"), xalign=0.0)
        entry = Gtk.Entry()
        entry.set_hexpand(True)
        entry.set_editable(False)
        entry.set_text(str(self.settings_path))
        reload_button = Gtk.Button(label=_("Reload"))
        reload_button.connect("clicked", lambda *_: self._reload_settings_from_disk(status_label))
        self._box_append(row, label, expand=False)
        self._box_append(row, entry, expand=True)
        self._box_append(row, reload_button, expand=False)
        return row

    def _build_shortcut_editor(self, status_label: Gtk.Label) -> Gtk.Widget:
        container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        heading = Gtk.Label(label=_("Keyboard Shortcuts"), xalign=0.0)
        self._box_append(container, heading, expand=False)

        entries: dict[str, Gtk.Entry] = {}
        grid = Gtk.Grid()
        grid.set_column_spacing(12)
        grid.set_row_spacing(6)
        for row_index, binding in enumerate(sorted(self.shortcuts.values(), key=lambda item: item.action)):
            action_label = Gtk.Label(label=binding.action, xalign=0.0)
            entry = Gtk.Entry()
            entry.set_hexpand(True)
            entry.set_text(binding.display)
            entries[binding.action] = entry
            grid.attach(action_label, 0, row_index, 1, 1)
            grid.attach(entry, 1, row_index, 1, 1)

        scroller = Gtk.ScrolledWindow()
        scroller.set_hexpand(True)
        scroller.set_vexpand(True)
        if hasattr(scroller, "set_min_content_height"):
            scroller.set_min_content_height(280)
        if GTK_MAJOR >= 4:
            scroller.set_child(grid)
        else:
            scroller.add(grid)
        self._box_append(container, scroller, expand=True)

        save_button = Gtk.Button(label=_("Save Shortcuts"))
        save_button.connect("clicked", lambda *_: self._save_shortcut_entries(entries, status_label))
        self._box_append(container, save_button, expand=False)
        return container

    def _save_shortcut_entries(self, entries: dict[str, Gtk.Entry], status_label: Gtk.Label) -> None:
        shortcuts: dict[str, str] = {}
        invalid_actions: list[str] = []
        for action, entry in entries.items():
            value = entry.get_text().strip()
            if not value or not shortcut_token_from_text(value):
                invalid_actions.append(action)
            else:
                shortcuts[action] = value
        if invalid_actions:
            status_label.set_text(_("Invalid shortcut: ") + ", ".join(invalid_actions))
            return

        try:
            settings = dict(self.settings) if isinstance(self.settings, dict) else {}
            settings["keyboardShortcuts"] = shortcuts
            self.settings_path.parent.mkdir(parents=True, exist_ok=True)
            with self.settings_path.open("w", encoding="utf-8") as handle:
                json.dump(settings, handle, indent=2, sort_keys=True)
                handle.write("\n")
            self.settings = load_settings(self.settings_path)
            self.shortcuts = build_shortcut_bindings(self.settings)
            status_label.set_text(_("Saved."))
        except OSError as error:
            status_label.set_text(_("Failed to save settings: ") + str(error))

    def _reload_settings_from_disk(self, status_label: Gtk.Label) -> None:
        self.settings = load_settings(self.settings_path)
        self.shortcuts = build_shortcut_bindings(self.settings)
        status_label.set_text(_("Reloaded. Reopen Settings to refresh shortcuts."))

    def _build_terminal_pane(self, surface_id: str, cwd: str, command: str | None) -> Pane:
        title = terminal_title(command, cwd)
        pane = Pane(
            id=str(uuid.uuid4()),
            surface_id=surface_id,
            kind="terminal",
            title=title,
            cwd=cwd,
            widget=self._build_terminal(cwd, command),
        )
        self._track_pane_focus(pane)
        return pane

    def _build_browser_pane(self, surface_id: str, url: str) -> Pane:
        widget, web_view, back_button, forward_button, reload_button, close_button, address_entry = self._build_browser(url)
        pane = Pane(
            id=str(uuid.uuid4()),
            surface_id=surface_id,
            kind="browser",
            title=url,
            url=url,
            widget=widget,
            browser_web_view=web_view,
            browser_back_button=back_button,
            browser_forward_button=forward_button,
            browser_reload_button=reload_button,
            browser_close_button=close_button,
            browser_address_entry=address_entry,
        )
        self._connect_browser_chrome(pane)
        self._sync_browser_chrome(pane)
        self._track_pane_focus(pane)
        return pane

    def _build_terminal(self, cwd: str, command: str | None) -> Vte.Terminal:
        terminal = Vte.Terminal()
        terminal.set_hexpand(True)
        terminal.set_vexpand(True)
        self._configure_terminal_colors(terminal)
        argv = self._spawn_argv(command)
        try:
            terminal.spawn_async(
                Vte.PtyFlags.DEFAULT,
                cwd,
                argv,
                [],
                GLib.SpawnFlags(0),
                None,
                None,
                -1,
                None,
                None,
                None,
            )
        except TypeError:
            terminal.spawn_async(Vte.PtyFlags.DEFAULT, cwd, argv, [], 0, None, None, -1, None, None, None)
        except Exception as error:  # noqa: BLE001
            terminal.feed((_("Failed to start shell: ") + str(error) + "\r\n").encode("utf-8"))
        return terminal

    def _configure_terminal_colors(self, terminal: Vte.Terminal) -> None:
        background = self._rgba(CMUX_TERMINAL_BACKGROUND)
        foreground = self._rgba(CMUX_TERMINAL_FOREGROUND)
        cursor = self._rgba(CMUX_TERMINAL_CURSOR)
        selection = self._rgba(CMUX_TERMINAL_SELECTION)
        palette = [self._rgba(color) for color in CMUX_TERMINAL_PALETTE]

        if foreground is not None and background is not None and None not in palette and hasattr(terminal, "set_colors"):
            terminal.set_colors(foreground, background, palette)
        if foreground is not None and hasattr(terminal, "set_color_foreground"):
            terminal.set_color_foreground(foreground)
        if background is not None and hasattr(terminal, "set_color_background"):
            terminal.set_color_background(background)
        if cursor is not None and hasattr(terminal, "set_color_cursor"):
            terminal.set_color_cursor(cursor)
        if selection is not None and hasattr(terminal, "set_color_highlight"):
            terminal.set_color_highlight(selection)

    def _build_browser(
        self,
        url: str,
    ) -> tuple[Gtk.Widget, Gtk.Widget | None, Gtk.Button, Gtk.Button, Gtk.Button, Gtk.Button, Gtk.Entry]:
        container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self._add_css_class(container, "cmux-browser")
        container.set_hexpand(True)
        container.set_vexpand(True)

        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=BROWSER_TOOLBAR_SPACING)
        self._add_css_class(toolbar, "cmux-browser-toolbar")
        toolbar.set_margin_top(BROWSER_TOOLBAR_MARGIN)
        toolbar.set_margin_bottom(BROWSER_TOOLBAR_MARGIN)
        toolbar.set_margin_start(BROWSER_TOOLBAR_MARGIN)
        toolbar.set_margin_end(BROWSER_TOOLBAR_MARGIN)

        back_button = self._build_icon_button("go-previous-symbolic", _("Back"))
        forward_button = self._build_icon_button("go-next-symbolic", _("Forward"))
        reload_button = self._build_icon_button("view-refresh-symbolic", _("Reload"))
        close_button = self._build_icon_button(("window-close-symbolic", "window-close"), _("Close pane"), "x")
        self._add_css_class(close_button, "cmux-close-button")
        address_entry = Gtk.Entry()
        self._add_css_class(address_entry, "cmux-browser-address")
        address_entry.set_hexpand(True)
        address_entry.set_text(browser_display_url(url))
        address_entry.set_tooltip_text(_("Address"))

        for child in (back_button, forward_button, reload_button, close_button):
            self._add_css_class(child, "cmux-browser-button")
        for child in (back_button, forward_button, reload_button):
            self._box_append(toolbar, child, expand=False)
        self._box_append(toolbar, address_entry, expand=True)
        self._box_append(toolbar, close_button, expand=False)
        self._box_append(container, toolbar, expand=False)

        if WEBKIT_AVAILABLE and WebKit is not None:
            web_view = WebKit.WebView()
            web_view.load_uri(url)
            web_view.set_hexpand(True)
            web_view.set_vexpand(True)
            self._box_append(container, web_view, expand=True)
            return container, web_view, back_button, forward_button, reload_button, close_button, address_entry

        placeholder = self._build_placeholder(
            _("Browser support requires WebKitGTK."),
            _("Install gir1.2-webkitgtk-6.0, gir1.2-webkit2-4.1, or gir1.2-webkit2-4.0 for your distribution."),
        )
        self._box_append(container, placeholder, expand=True)
        return container, None, back_button, forward_button, reload_button, close_button, address_entry

    def _build_icon_button(
        self,
        icon_names: str | tuple[str, ...],
        tooltip: str,
        fallback_label: str | None = None,
    ) -> Gtk.Button:
        icon_name = self._resolve_icon_name(icon_names)
        if icon_name is not None and self._icon_theme_has_icon(icon_name):
            if GTK_MAJOR >= 4:
                button = Gtk.Button.new_from_icon_name(icon_name)
            else:
                button = Gtk.Button.new_from_icon_name(icon_name, Gtk.IconSize.BUTTON)
        elif fallback_label is not None:
            button = Gtk.Button.new_with_label(fallback_label)
        else:
            button = Gtk.Button()
        self._add_css_class(button, "cmux-icon-button")
        button.set_tooltip_text(tooltip)
        return button

    def _box_append(self, box: Gtk.Box, child: Gtk.Widget, expand: bool) -> None:
        if GTK_MAJOR >= 4:
            box.append(child)
            if expand:
                child.set_vexpand(True)
            return
        box.pack_start(child, expand, expand, 0)

    def _connect_browser_chrome(self, pane: Pane) -> None:
        web_view = self._browser_web_view(pane)
        self._connect_browser_toolbar_actions(pane, web_view)
        if web_view is None:
            return
        web_view.connect("load-changed", lambda _view, event: self._on_browser_load_changed(pane, event))
        web_view.connect("notify::uri", lambda *_: self._sync_browser_chrome(pane))
        web_view.connect("notify::title", lambda *_: self._sync_browser_chrome(pane))
        web_view.connect("notify::can-go-back", lambda *_: self._sync_browser_chrome(pane))
        web_view.connect("notify::can-go-forward", lambda *_: self._sync_browser_chrome(pane))
        web_view.connect("notify::is-loading", lambda *_: self._sync_browser_chrome(pane))

    def _connect_browser_toolbar_actions(self, pane: Pane, web_view: Gtk.Widget | None) -> None:
        if pane.browser_back_button is not None:
            pane.browser_back_button.connect("clicked", lambda *_: self._browser_go_back(pane))
        if pane.browser_forward_button is not None:
            pane.browser_forward_button.connect("clicked", lambda *_: self._browser_go_forward(pane))
        if pane.browser_reload_button is not None:
            pane.browser_reload_button.connect("clicked", lambda *_: self._browser_reload_or_stop(pane))
        if pane.browser_close_button is not None:
            pane.browser_close_button.connect("clicked", lambda *_: self.close_pane_from_params({"pane_id": pane.id}))
        if pane.browser_address_entry is not None:
            pane.browser_address_entry.connect("activate", lambda entry: self._browser_load_entry_url(pane, entry))
        if web_view is None:
            for button in (pane.browser_back_button, pane.browser_forward_button, pane.browser_reload_button):
                if button is not None:
                    button.set_sensitive(False)
            if pane.browser_address_entry is not None:
                pane.browser_address_entry.set_sensitive(False)

    def _track_pane_focus(self, pane: Pane) -> None:
        widgets = [pane.widget]
        if pane.browser_web_view is not None:
            widgets.append(pane.browser_web_view)
        if pane.browser_address_entry is not None:
            widgets.append(pane.browser_address_entry)
        for widget in widgets:
            if not hasattr(widget, "connect"):
                continue
            widget.connect("notify::has-focus", lambda focused_widget, _param, pane_id=pane.id: self._mark_pane_current_if_focused(pane_id, focused_widget))
            if GTK_MAJOR < 4:
                widget.connect("focus-in-event", lambda _widget, _event, pane_id=pane.id: self._mark_pane_current(pane_id) or False)

    def _mark_pane_current_if_focused(self, pane_id: str, widget: Gtk.Widget) -> None:
        if hasattr(widget, "has_focus") and widget.has_focus():
            self._mark_pane_current(pane_id)

    def _mark_pane_current(self, pane_id: str) -> None:
        for workspace in self.workspaces.values():
            for surface in workspace.surfaces.values():
                if pane_id in surface.panes:
                    visible_surface_id = self._visible_surface_id()
                    if visible_surface_id is not None and visible_surface_id != surface.id:
                        return
                    self._set_current_workspace_id(workspace.id)
                    workspace.current_surface_id = surface.id
                    self._set_current_pane_id(surface, pane_id)
                    return

    def _visible_surface_id(self) -> str | None:
        if hasattr(self.stack, "get_visible_child_name"):
            return self.stack.get_visible_child_name()
        if hasattr(self.stack, "get_visible_child"):
            visible_child = self.stack.get_visible_child()
            for workspace in self.workspaces.values():
                for surface in workspace.surfaces.values():
                    if visible_child is surface.root_widget:
                        return surface.id
        return None

    def _on_browser_load_changed(self, pane: Pane, event: Any) -> bool:
        finished = WebKit is not None and event == getattr(getattr(WebKit, "LoadEvent", object), "FINISHED", None)
        pane.browser_is_loading = not finished
        self._sync_browser_chrome(pane)
        if finished:
            GLib.idle_add(lambda: self._bootstrap_browser_pane(pane))
        return False

    def _browser_load_entry_url(self, pane: Pane, entry: Gtk.Entry) -> None:
        url = normalize_url(entry.get_text())
        pane.title = url
        pane.url = url
        self._sync_browser_chrome(pane)
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "load_uri"):
            web_view.load_uri(url)

    def _browser_go_back(self, pane: Pane) -> None:
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "go_back"):
            web_view.go_back()

    def _browser_go_forward(self, pane: Pane) -> None:
        web_view = self._browser_web_view(pane)
        if web_view is not None and hasattr(web_view, "go_forward"):
            web_view.go_forward()

    def _browser_reload_or_stop(self, pane: Pane) -> None:
        web_view = self._browser_web_view(pane)
        if web_view is None:
            return
        if pane.browser_is_loading and hasattr(web_view, "stop_loading"):
            web_view.stop_loading()
            self._sync_browser_chrome(pane)
            return
        if hasattr(web_view, "reload"):
            web_view.reload()

    def _sync_browser_chrome(self, pane: Pane) -> None:
        web_view = self._browser_web_view(pane)
        live_url = self._browser_live_url(pane, web_view)
        live_title = browser_display_title(self._browser_live_title(web_view), live_url or pane.url or pane.title)
        if live_url:
            pane.url = live_url
        if live_title:
            pane.title = live_title
        self._sync_browser_toolbar_state(pane, web_view, live_url)

    def _sync_browser_toolbar_state(self, pane: Pane, web_view: Gtk.Widget | None, live_url: str) -> None:
        loading = self._browser_is_loading(pane, web_view)
        pane.browser_is_loading = loading
        display_url = browser_display_url(live_url)
        if pane.browser_address_entry is not None and pane.browser_address_entry.get_text() != display_url:
            pane.browser_address_entry.set_text(display_url)
        if pane.browser_back_button is not None:
            pane.browser_back_button.set_sensitive(
                bool(web_view is not None and self._browser_can_go(web_view, "get_can_go_back"))
            )
        if pane.browser_forward_button is not None:
            pane.browser_forward_button.set_sensitive(
                bool(web_view is not None and self._browser_can_go(web_view, "get_can_go_forward"))
            )
        if pane.browser_reload_button is not None:
            pane.browser_reload_button.set_sensitive(web_view is not None)
            reload_icon = "process-stop-symbolic" if loading else "view-refresh-symbolic"
            self._set_button_icon(pane.browser_reload_button, reload_icon)
            pane.browser_reload_button.set_tooltip_text(_("Stop") if loading else _("Reload"))

    def _browser_web_view(self, pane: Pane) -> Gtk.Widget | None:
        if pane.browser_web_view is not None:
            return pane.browser_web_view
        return self._find_browser_web_view(pane.widget)

    def _find_browser_web_view(self, widget: Gtk.Widget) -> Gtk.Widget | None:
        if self._looks_like_web_view(widget):
            return widget
        if GTK_MAJOR >= 4 and hasattr(widget, "get_first_child"):
            child = widget.get_first_child()
            while child is not None:
                match = self._find_browser_web_view(child)
                if match is not None:
                    return match
                child = child.get_next_sibling() if hasattr(child, "get_next_sibling") else None
        if GTK_MAJOR < 4 and hasattr(widget, "get_children"):
            for child in widget.get_children():
                match = self._find_browser_web_view(child)
                if match is not None:
                    return match
        return None

    def _looks_like_web_view(self, widget: Gtk.Widget) -> bool:
        has_script_api = hasattr(widget, "run_javascript") or hasattr(widget, "evaluate_javascript")
        return hasattr(widget, "load_uri") and has_script_api

    def _browser_live_url(self, pane: Pane, web_view: Gtk.Widget | None) -> str:
        if web_view is not None and hasattr(web_view, "get_uri"):
            return str(web_view.get_uri() or pane.url or "")
        return str(pane.url or "")

    def _browser_live_title(self, web_view: Gtk.Widget | None) -> str:
        if web_view is not None and hasattr(web_view, "get_title"):
            return str(web_view.get_title() or "")
        return ""

    def _browser_is_loading(self, pane: Pane, web_view: Gtk.Widget | None) -> bool:
        if web_view is not None and hasattr(web_view, "get_is_loading"):
            return bool(web_view.get_is_loading())
        return pane.browser_is_loading

    def _browser_can_go(self, web_view: Gtk.Widget, method: str) -> bool:
        callback = getattr(web_view, method, None)
        return bool(callback()) if callable(callback) else False

    def _set_button_icon(self, button: Gtk.Button, icon_name: str) -> None:
        if hasattr(button, "set_icon_name"):
            button.set_icon_name(icon_name)
            return
        image = (
            Gtk.Image.new_from_icon_name(icon_name)
            if GTK_MAJOR >= 4
            else Gtk.Image.new_from_icon_name(icon_name, Gtk.IconSize.BUTTON)
        )
        if GTK_MAJOR >= 4 and hasattr(button, "set_child"):
            button.set_child(image)
            return
        if hasattr(button, "set_image"):
            button.set_image(image)

    def _build_placeholder(self, title: str, detail: str) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self._add_css_class(box, "cmux-placeholder")
        box.set_margin_top(24)
        box.set_margin_bottom(24)
        box.set_margin_start(24)
        box.set_margin_end(24)
        heading = Gtk.Label(label=title, xalign=0.0)
        detail_label = Gtk.Label(label=detail, xalign=0.0)
        for label in (heading, detail_label):
            if hasattr(label, "set_wrap"):
                label.set_wrap(True)
            else:
                label.set_line_wrap(True)
        if GTK_MAJOR >= 4:
            box.append(heading)
            box.append(detail_label)
        else:
            box.pack_start(heading, False, False, 0)
            box.pack_start(detail_label, False, False, 0)
        return box

    def _build_paned(self, orientation: Gtk.Orientation, first: Gtk.Widget, second: Gtk.Widget) -> Gtk.Paned:
        if GTK_MAJOR >= 4:
            paned = Gtk.Paned(orientation=orientation)
            paned.set_start_child(first)
            paned.set_end_child(second)
        else:
            paned = Gtk.Paned.new(orientation)
            paned.pack1(first, resize=True, shrink=False)
            paned.pack2(second, resize=True, shrink=False)
        self._add_css_class(paned, "cmux-splitter")
        paned.set_position(DEFAULT_WIDTH // 2)
        return paned

    def _remove_stack_child(self, widget: Gtk.Widget) -> None:
        try:
            self.stack.remove(widget)
        except Exception:  # noqa: BLE001
            return

    def _set_stack_title(self, surface: Surface) -> None:
        if GTK_MAJOR >= 4 and hasattr(self.stack, "get_page"):
            page = self.stack.get_page(surface.root_widget)
            if page is not None and hasattr(page, "set_title"):
                page.set_title(surface.title)
                return
        if hasattr(self.stack, "child_set_property"):
            try:
                self.stack.child_set_property(surface.root_widget, "title", surface.title)
            except Exception:  # noqa: BLE001
                return

    def _detach_widget(self, widget: Gtk.Widget) -> None:
        parent = widget.get_parent()
        if parent is None:
            return
        if GTK_MAJOR >= 4 and hasattr(parent, "get_start_child"):
            if parent.get_start_child() is widget:
                parent.set_start_child(None)
                return
            if parent.get_end_child() is widget:
                parent.set_end_child(None)
                return
        if hasattr(parent, "remove"):
            parent.remove(widget)

    def _rebuild_surface_root(self, surface: Surface) -> None:
        panes = list(surface.panes.values())
        if not panes:
            return
        was_visible = self._visible_surface_id() == surface.id
        self._remove_stack_child(surface.root_widget)
        for pane in panes:
            self._detach_widget(pane.widget)
        root = panes[0].widget
        for pane in panes[1:]:
            root = self._build_paned(Gtk.Orientation.HORIZONTAL, root, pane.widget)
        surface.root_widget = root
        self.stack.add_titled(surface.root_widget, surface.id, surface.title)
        if was_visible:
            self.stack.set_visible_child_name(surface.id)
        if GTK_MAJOR < 4:
            surface.root_widget.show_all()

    def _set_current_pane_id(self, surface: Surface, pane_id: str) -> None:
        if pane_id not in surface.panes:
            raise ValueError(_("Pane not found."))
        current_id = surface.current_pane_id
        if current_id and current_id != pane_id and current_id in surface.panes:
            surface.previous_pane_id = current_id
        surface.current_pane_id = pane_id

    def _bool_param(self, params: dict[str, Any], key: str, default: bool) -> bool:
        if key not in params:
            return default
        value = params.get(key)
        if isinstance(value, bool):
            return value
        if isinstance(value, (int, float)):
            return bool(value)
        return str(value).strip().lower() in {"1", "true", "yes", "on"}

    def _pane_from_param_keys(self, params: dict[str, Any], keys: tuple[str, ...]) -> tuple[Surface, Pane]:
        pane_id = None
        for key in keys:
            pane_id = parse_ref(params.get(key), "pane")
            if pane_id:
                break
        if not pane_id:
            raise ValueError(_("Pane not found."))
        return self._pane_from_params({"pane_id": pane_id})

    def _resize_candidate(self, surface: Surface, pane: Pane, direction: str) -> tuple[Gtk.Paned, bool]:
        orientation = Gtk.Orientation.HORIZONTAL if direction in {"left", "right"} else Gtk.Orientation.VERTICAL
        requires_first_child = direction in {"right", "down"}
        fallback: tuple[Gtk.Paned, bool] | None = None

        def visit(widget: Gtk.Widget) -> bool:
            nonlocal fallback
            if widget is pane.widget:
                return True
            first, second = self._paned_children(widget)
            if first is None and second is None:
                return False
            first_contains = visit(first) if first is not None else False
            second_contains = visit(second) if second is not None else False
            contains = first_contains or second_contains
            if contains and isinstance(widget, Gtk.Paned) and widget.get_orientation() == orientation:
                pane_in_first = first_contains
                if fallback is None:
                    fallback = (widget, pane_in_first)
                if pane_in_first == requires_first_child:
                    raise _ResizeCandidateFound(widget, pane_in_first)
            return contains

        try:
            visit(surface.root_widget)
        except _ResizeCandidateFound as found:
            return found.paned, found.pane_in_first_child
        if fallback is None:
            raise ValueError(_("No split ancestor for pane."))
        return fallback

    def _paned_span(self, paned: Gtk.Paned) -> int:
        if paned.get_orientation() == Gtk.Orientation.VERTICAL:
            span = paned.get_allocated_height() if hasattr(paned, "get_allocated_height") else DEFAULT_HEIGHT
            return max(2, int(span or DEFAULT_HEIGHT))
        span = paned.get_allocated_width() if hasattr(paned, "get_allocated_width") else DEFAULT_WIDTH
        return max(2, int(span or DEFAULT_WIDTH))

    def _swap_panes_within_surface(self, surface: Surface, source_id: str, target_id: str) -> None:
        items = list(surface.panes.items())
        source_index = next((index for index, item in enumerate(items) if item[0] == source_id), None)
        target_index = next((index for index, item in enumerate(items) if item[0] == target_id), None)
        if source_index is None or target_index is None:
            raise ValueError(_("Pane not found."))
        swapped = list(items)
        swapped[source_index], swapped[target_index] = swapped[target_index], swapped[source_index]
        surface.panes = dict(swapped)
        self._rebuild_surface_root(surface)

    def _swap_panes_between_surfaces(
        self,
        source_surface: Surface,
        source_pane: Pane,
        target_surface: Surface,
        target_pane: Pane,
    ) -> None:
        source_pane.surface_id = target_surface.id
        target_pane.surface_id = source_surface.id
        source_surface.panes = {
            key: (target_pane if key == source_pane.id else value)
            for key, value in source_surface.panes.items()
        }
        source_surface.panes = {
            (target_pane.id if key == source_pane.id else key): value
            for key, value in source_surface.panes.items()
        }
        target_surface.panes = {
            key: (source_pane if key == target_pane.id else value)
            for key, value in target_surface.panes.items()
        }
        target_surface.panes = {
            (source_pane.id if key == target_pane.id else key): value
            for key, value in target_surface.panes.items()
        }
        if source_surface.current_pane_id == source_pane.id:
            source_surface.current_pane_id = target_pane.id
        if source_surface.previous_pane_id == source_pane.id:
            source_surface.previous_pane_id = target_pane.id
        if target_surface.current_pane_id == target_pane.id:
            target_surface.current_pane_id = source_pane.id
        if target_surface.previous_pane_id == target_pane.id:
            target_surface.previous_pane_id = source_pane.id
        self._rebuild_surface_root(source_surface)
        self._rebuild_surface_root(target_surface)

    def _move_surface_to_workspace(self, surface: Surface, destination_workspace: Workspace) -> Surface:
        source_workspace = self._workspace_for_surface(surface.id)
        source_workspace.surfaces = {
            key: value for key, value in source_workspace.surfaces.items() if key != surface.id
        }
        if source_workspace.current_surface_id == surface.id:
            source_workspace.current_surface_id = next(iter(source_workspace.surfaces), None)
        destination_workspace.surfaces = {surface.id: surface}
        destination_workspace.current_surface_id = surface.id
        return surface

    def _move_pane_to_new_surface(
        self,
        source_surface: Surface,
        pane: Pane,
        destination_workspace: Workspace,
    ) -> Surface:
        moved_pane = self._detach_pane_for_move(source_surface, pane)
        surface_id = str(uuid.uuid4())
        moved_pane.surface_id = surface_id
        destination_surface = Surface(
            id=surface_id,
            title=moved_pane.title,
            cwd=moved_pane.cwd or source_surface.cwd,
            root_widget=moved_pane.widget,
            panes={moved_pane.id: moved_pane},
            current_pane_id=moved_pane.id,
        )
        destination_workspace.surfaces = {surface_id: destination_surface}
        destination_workspace.current_surface_id = surface_id
        self.stack.add_titled(destination_surface.root_widget, destination_surface.id, destination_surface.title)
        if GTK_MAJOR < 4:
            destination_surface.root_widget.show_all()
        return destination_surface

    def _move_single_surface_to_split(
        self,
        source_surface: Surface,
        target_surface: Surface,
        direction: str,
        focus: bool,
    ) -> dict[str, Any]:
        if source_surface.id == target_surface.id:
            raise ValueError(_("Source and target surfaces must be different."))
        if len(source_surface.panes) != 1:
            raise ValueError(_("Only single-pane surfaces can be dragged to split on Linux."))
        source_workspace = self._workspace_for_surface(source_surface.id)
        target_workspace = self._workspace_for_surface(target_surface.id)
        if source_workspace.id != target_workspace.id:
            raise ValueError(_("Surfaces must be in the same workspace."))

        moved_pane = next(iter(source_surface.panes.values()))
        source_was_current = source_workspace.current_surface_id == source_surface.id
        target_was_visible = self._visible_surface_id() == target_surface.id
        self._remove_stack_child(source_surface.root_widget)
        source_workspace.surfaces = {
            key: value for key, value in source_workspace.surfaces.items() if key != source_surface.id
        }
        if source_was_current:
            source_workspace.current_surface_id = target_surface.id

        old_root = target_surface.root_widget
        self._remove_stack_child(old_root)
        self._detach_widget(moved_pane.widget)
        self._detach_widget(old_root)
        moved_pane.surface_id = target_surface.id
        orientation = Gtk.Orientation.HORIZONTAL if direction in {"left", "right"} else Gtk.Orientation.VERTICAL
        if direction in {"left", "up"}:
            target_surface.root_widget = self._build_paned(orientation, moved_pane.widget, old_root)
        else:
            target_surface.root_widget = self._build_paned(orientation, old_root, moved_pane.widget)
        target_surface.panes = {**target_surface.panes, moved_pane.id: moved_pane}
        self.stack.add_titled(target_surface.root_widget, target_surface.id, target_surface.title)
        if GTK_MAJOR < 4:
            target_surface.root_widget.show_all()
        if focus or source_was_current:
            source_workspace.current_surface_id = target_surface.id
            self.stack.set_visible_child_name(target_surface.id)
        elif target_was_visible:
            self.stack.set_visible_child_name(target_surface.id)
        if focus:
            self._set_current_workspace_id(target_workspace.id)
            self._set_current_pane_id(target_surface, moved_pane.id)
        self.refresh_sidebar()
        target_index = list(target_workspace.surfaces.keys()).index(target_surface.id)
        return {
            **self._surface_command_payload(target_workspace, target_surface, target_index),
            "source_surface_id": source_surface.id,
            "source_surface_ref": f"surface:{source_surface.id}",
            "pane_id": moved_pane.id,
            "pane_ref": f"pane:{moved_pane.id}",
            "direction": direction,
        }

    def _detach_pane_for_move(self, surface: Surface, pane: Pane) -> Pane:
        workspace = self._workspace_for_surface(surface.id)
        if len(surface.panes) <= 1:
            self._remove_stack_child(surface.root_widget)
            workspace.surfaces = {key: value for key, value in workspace.surfaces.items() if key != surface.id}
            if workspace.current_surface_id == surface.id:
                workspace.current_surface_id = next(iter(workspace.surfaces), None)
            return pane

        self._detach_widget(pane.widget)
        surface.panes = {key: value for key, value in surface.panes.items() if key != pane.id}
        if surface.previous_pane_id == pane.id:
            surface.previous_pane_id = None
        next_pane_id = surface.current_pane_id if surface.current_pane_id in surface.panes else next(reversed(surface.panes), "")
        self._set_current_pane_id(surface, next_pane_id)
        self._rebuild_surface_root(surface)
        return pane

    def _source_pane_for_join(self, params: dict[str, Any]) -> tuple[Surface, Pane]:
        pane_id = parse_ref(params.get("paneId") or params.get("pane_id") or params.get("pane_ref"), "pane")
        if pane_id:
            return self._pane_from_params({"pane_id": pane_id})
        surface_id = parse_ref(params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref"), "surface")
        if surface_id:
            surface = self._surface_from_params({"surface_id": surface_id})
            pane = surface.panes.get(surface.current_pane_id or "")
            if pane is None:
                raise ValueError(_("Pane not found."))
            return surface, pane
        return self._pane_from_params(params)

    def _ensure_workspace_surface(self, workspace: Workspace) -> None:
        if workspace.surfaces:
            if workspace.current_surface_id not in workspace.surfaces:
                workspace.current_surface_id = next(iter(workspace.surfaces), None)
            if workspace.id == self.current_workspace_id and workspace.current_surface_id:
                self.stack.set_visible_child_name(workspace.current_surface_id)
            return
        self.create_surface(workspace_id=workspace.id, select=workspace.id == self.current_workspace_id)

    def _set_current_workspace_id(self, workspace_id: str) -> None:
        if workspace_id not in self.workspaces:
            raise ValueError(_("Workspace not found."))
        current_id = self.current_workspace_id
        if current_id and current_id != workspace_id and current_id in self.workspaces:
            self.previous_workspace_id = current_id
        self.current_workspace_id = workspace_id

    def _select_workspace(self, workspace: Workspace) -> dict[str, Any]:
        self._set_current_workspace_id(workspace.id)
        if workspace.current_surface_id:
            self.stack.set_visible_child_name(workspace.current_surface_id)
        self.refresh_sidebar()
        self._save_runtime_state()
        return self._workspace_payload(workspace)

    def _reorder_workspace_for_pinned_state(self, workspace: Workspace) -> None:
        if workspace.id not in self.workspaces:
            return
        ordered = [(key, item) for key, item in self.workspaces.items() if key != workspace.id]
        target_index = sum(1 for _key, item in ordered if item.is_pinned)
        ordered.insert(target_index, (workspace.id, workspace))
        self.workspaces = dict(ordered)

    def _current_workspace_after_close(self, closed_index: int, was_current: bool) -> dict[str, Any]:
        workspace_ids = list(self.workspaces.keys())
        if not workspace_ids:
            return self._workspace_payload(self.create_workspace(_("Default"), os.getcwd()))
        if was_current or self.current_workspace_id not in self.workspaces:
            next_index = min(closed_index, len(workspace_ids) - 1)
            return self._select_workspace(self.workspaces[workspace_ids[next_index]])
        return self._workspace_payload(self._current_workspace())

    def _workspace_from_command_params(self, params: dict[str, Any], allow_index: bool) -> Workspace:
        workspace_id = parse_ref(
            params.get("workspaceId") or params.get("workspace_id") or params.get("workspace_ref") or params.get("id"),
            "workspace",
        )
        if workspace_id:
            return self._workspace_from_id(workspace_id)
        if allow_index:
            index = self._int_param(params, "index")
            if index is not None:
                workspace_ids = list(self.workspaces.keys())
                if 0 <= index < len(workspace_ids):
                    return self.workspaces[workspace_ids[index]]
                raise ValueError(_("Workspace not found."))
        return self._current_workspace()

    def _workspace_reorder_index(self, params: dict[str, Any], ordered: list[tuple[str, Workspace]]) -> int:
        has_index = "index" in params
        before_id = parse_ref(params.get("beforeWorkspaceId") or params.get("before_workspace_id"), "workspace")
        after_id = parse_ref(params.get("afterWorkspaceId") or params.get("after_workspace_id"), "workspace")
        if sum(1 for item in (has_index, before_id, after_id) if item) != 1:
            raise ValueError(_("Specify exactly one workspace reorder target."))
        if has_index:
            index = self._int_param(params, "index")
            if index is None:
                raise ValueError(_("Invalid workspace index."))
            return index
        workspace_ids = [key for key, _workspace in ordered]
        if before_id in workspace_ids:
            return workspace_ids.index(before_id)
        if after_id in workspace_ids:
            return workspace_ids.index(after_id) + 1
        raise ValueError(_("Workspace not found."))

    def _has_surface_reorder_target(self, params: dict[str, Any]) -> bool:
        return any(
            key in params
            for key in (
                "index",
                "beforeSurfaceId",
                "before_surface_id",
                "before_surface_ref",
                "afterSurfaceId",
                "after_surface_id",
                "after_surface_ref",
            )
        )

    def _surface_reorder_index(
        self,
        params: dict[str, Any],
        ordered: list[tuple[str, Surface]],
        require_target: bool,
    ) -> int:
        has_index = "index" in params
        before_id = parse_ref(
            params.get("beforeSurfaceId") or params.get("before_surface_id") or params.get("before_surface_ref"),
            "surface",
        )
        after_id = parse_ref(
            params.get("afterSurfaceId") or params.get("after_surface_id") or params.get("after_surface_ref"),
            "surface",
        )
        target_count = sum(1 for item in (has_index, before_id, after_id) if item)
        if target_count == 0 and not require_target:
            return len(ordered)
        if target_count != 1:
            raise ValueError(_("Specify exactly one surface reorder target."))
        if has_index:
            index = self._int_param(params, "index")
            if index is None:
                raise ValueError(_("Invalid surface index."))
            return index
        surface_ids = [key for key, _surface in ordered]
        if before_id in surface_ids:
            return surface_ids.index(before_id)
        if after_id in surface_ids:
            return surface_ids.index(after_id) + 1
        raise ValueError(_("Surface not found."))

    def _int_param(self, params: dict[str, Any], key: str) -> int | None:
        if key not in params:
            return None
        try:
            return int(params[key])
        except (TypeError, ValueError):
            return None

    def _equalize_split_widget(self, widget: Gtk.Widget, orientation: Any = None) -> bool:
        first, second = self._paned_children(widget)
        equalized = False
        if first is not None:
            equalized = self._equalize_split_widget(first, orientation) or equalized
        if second is not None:
            equalized = self._equalize_split_widget(second, orientation) or equalized
        if not isinstance(widget, Gtk.Paned) or not self._paned_orientation_matches(widget, orientation):
            return equalized
        width = widget.get_allocated_width() if hasattr(widget, "get_allocated_width") else DEFAULT_WIDTH
        height = widget.get_allocated_height() if hasattr(widget, "get_allocated_height") else DEFAULT_HEIGHT
        span = height if widget.get_orientation() == Gtk.Orientation.VERTICAL else width
        widget.set_position(max(1, span // 2))
        return True

    def _paned_children(self, widget: Gtk.Widget) -> tuple[Gtk.Widget | None, Gtk.Widget | None]:
        if not isinstance(widget, Gtk.Paned):
            return None, None
        if GTK_MAJOR >= 4 and hasattr(widget, "get_start_child"):
            return widget.get_start_child(), widget.get_end_child()
        first = widget.get_child1() if hasattr(widget, "get_child1") else None
        second = widget.get_child2() if hasattr(widget, "get_child2") else None
        return first, second

    def _paned_orientation_matches(self, widget: Gtk.Paned, orientation: Any = None) -> bool:
        value = str(orientation or "").replace("-", "_").lower()
        if not value:
            return True
        if value in {"horizontal", "x", "columns", "left_right"}:
            return widget.get_orientation() == Gtk.Orientation.HORIZONTAL
        if value in {"vertical", "y", "rows", "top_bottom"}:
            return widget.get_orientation() == Gtk.Orientation.VERTICAL
        raise ValueError(_("Invalid split orientation."))

    def _workspace_for_surface(self, surface_id: str) -> Workspace:
        for workspace in self.workspaces.values():
            if surface_id in workspace.surfaces:
                return workspace
        raise ValueError(_("Surface not found."))

    def _workspace_from_id(self, workspace_id: str | None) -> Workspace:
        if not workspace_id:
            return self._current_workspace()
        workspace = self.workspaces.get(workspace_id)
        if workspace is None:
            raise ValueError(_("Workspace not found."))
        return workspace

    def _workspace_from_params(self, params: dict[str, Any]) -> Workspace:
        workspace_id = parse_ref(
            params.get("workspaceId") or params.get("workspace_id") or params.get("workspace_ref"),
            "workspace",
        )
        return self._workspace_from_id(workspace_id or None)

    def _surface_for_workspace(self, workspace: Workspace) -> Surface:
        if workspace.current_surface_id is None:
            return self.create_surface(workspace_id=workspace.id, select=workspace.id == self.current_workspace_id)
        surface = workspace.surfaces.get(workspace.current_surface_id)
        if surface is None:
            raise ValueError(_("Surface not found."))
        return surface

    def _surface_from_params(self, params: dict[str, Any]) -> Surface:
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref") or params.get("id"),
            "surface",
        )
        has_workspace = any(key in params for key in ("workspaceId", "workspace_id", "workspace_ref"))
        workspace = self._workspace_from_params(params)
        if not surface_id:
            return self._surface_for_workspace(workspace)
        if surface_id not in workspace.surfaces:
            if has_workspace:
                raise ValueError(_("Surface not found."))
            workspace = self._workspace_for_surface(surface_id)
        return workspace.surfaces[surface_id]

    def _surface_from_any_workspace(self, params: dict[str, Any]) -> Surface:
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref") or params.get("id"),
            "surface",
        )
        if not surface_id:
            return self._current_surface()
        return self._workspace_for_surface(surface_id).surfaces[surface_id]

    def _surface_command_payload(self, workspace: Workspace, surface: Surface, index: int) -> dict[str, Any]:
        pane = surface.panes.get(surface.current_pane_id or "") or next(iter(surface.panes.values()), None)
        payload: dict[str, Any] = {
            "workspace_id": workspace.id,
            "workspace_ref": f"workspace:{workspace.id}",
            "surface_id": surface.id,
            "surface_ref": f"surface:{surface.id}",
            "index": index,
            "surface": surface.snapshot().to_json(),
        }
        if pane is not None:
            payload = {
                **payload,
                "pane_id": pane.id,
                "pane_ref": f"pane:{pane.id}",
                "current_pane_id": pane.id,
                "current_pane_ref": f"pane:{pane.id}",
            }
        return payload

    def _surface_split_direction(self, params: dict[str, Any]) -> str:
        direction = str(params.get("direction") or "right").replace("-", "_").lower()
        if direction not in {"left", "right", "up", "down"}:
            raise ValueError(_("direction must be left, right, up, or down."))
        return direction

    def _surface_type(self, surface: Surface) -> str:
        kinds = {pane.kind for pane in surface.panes.values()}
        if len(kinds) == 1:
            return next(iter(kinds))
        return "mixed"

    def _widget_in_window(self, widget: Gtk.Widget) -> bool:
        if GTK_MAJOR >= 4 and hasattr(widget, "get_root"):
            return widget.get_root() is not None
        if hasattr(widget, "get_toplevel"):
            top_level = widget.get_toplevel()
            return bool(top_level is not None and getattr(top_level, "is_toplevel", lambda: True)())
        if hasattr(widget, "get_window"):
            return widget.get_window() is not None
        return False

    def _sidebar_row_for_surface(self, surface_id: str) -> Gtk.ListBoxRow | None:
        if GTK_MAJOR >= 4 and hasattr(self.sidebar, "get_first_child"):
            child = self.sidebar.get_first_child()
            while child is not None:
                if getattr(child, "surface_id", None) == surface_id and isinstance(child, Gtk.ListBoxRow):
                    return child
                child = child.get_next_sibling() if hasattr(child, "get_next_sibling") else None
            return None
        if hasattr(self.sidebar, "get_children"):
            for child in self.sidebar.get_children():
                if getattr(child, "surface_id", None) == surface_id and isinstance(child, Gtk.ListBoxRow):
                    return child
        return None

    def _flash_widget(self, widget: Gtk.Widget) -> None:
        self._add_css_class(widget, "cmux-flash")

        def remove_flash() -> bool:
            self._remove_css_class(widget, "cmux-flash")
            return False

        GLib.timeout_add(650, remove_flash)

    def _surface_from_tab_params(self, params: dict[str, Any]) -> Surface:
        tab_id = parse_ref(params.get("tabId") or params.get("tab_id") or params.get("tab_ref"), "tab")
        surface_id = parse_ref(
            params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref") or tab_id,
            "surface",
            "tab",
        )
        if surface_id:
            workspace_id = parse_ref(params.get("workspaceId") or params.get("workspace_id") or params.get("workspace_ref"), "workspace")
            if workspace_id:
                workspace = self._workspace_from_id(workspace_id)
                surface = workspace.surfaces.get(surface_id)
                if surface is None:
                    raise ValueError(_("Surface not found."))
                return surface
            return self._workspace_for_surface(surface_id).surfaces[surface_id]
        return self._surface_from_params(params)

    def _terminal_pane_for_surface(self, surface: Surface) -> Pane:
        current = surface.panes.get(surface.current_pane_id or "")
        if current is not None and current.kind == "terminal":
            return current
        for pane in surface.panes.values():
            if pane.kind == "terminal":
                return pane
        raise ValueError(_("Surface has no terminal pane."))

    def _pane_from_params(self, params: dict[str, Any]) -> tuple[Surface, Pane]:
        pane_id = parse_ref(params.get("paneId") or params.get("pane_id") or params.get("pane_ref") or params.get("id"), "pane")
        if not pane_id:
            surface = self._surface_from_params(params)
            pane_id = surface.current_pane_id or ""
            pane = surface.panes.get(pane_id)
            if pane is None:
                raise ValueError(_("Pane not found."))
            return surface, pane
        for workspace in self.workspaces.values():
            for surface in workspace.surfaces.values():
                pane = surface.panes.get(pane_id)
                if pane is not None:
                    return surface, pane
        raise ValueError(_("Pane not found."))

    def _browser_pane_from_params(self, params: dict[str, Any]) -> tuple[Surface, Pane | None]:
        surface_id = parse_ref(params.get("surfaceId") or params.get("surface_id") or params.get("surface_ref"), "surface")
        if surface_id:
            surface = self._surface_from_params(params)
            for pane in surface.panes.values():
                if pane.kind == "browser":
                    return surface, pane
            return surface, None
        try:
            surface, pane = self._pane_from_params(params)
            if pane.kind == "browser":
                return surface, pane
        except ValueError:
            pass
        surface = self._current_surface()
        current_pane = surface.panes.get(surface.current_pane_id or "")
        if current_pane and current_pane.kind == "browser":
            return surface, current_pane
        for pane in surface.panes.values():
            if pane.kind == "browser":
                return surface, pane
        return surface, None

    def _require_browser_pane(self, params: dict[str, Any]) -> tuple[Surface, Pane]:
        surface, pane = self._browser_pane_from_params(params)
        if pane is None:
            raise ValueError(_("Browser pane not found."))
        return surface, pane

    def _spawn_argv(self, command: str | None) -> list[str]:
        shell = os.environ.get("SHELL") or "/bin/sh"
        return [shell, "-lc", command] if command else [shell]

    def _on_sidebar_row_selected(self, _listbox: Gtk.ListBox, row: Gtk.ListBoxRow | None) -> None:
        if self._refreshing_sidebar:
            return
        if row is None:
            return
        surface_id = getattr(row, "surface_id", None)
        if isinstance(surface_id, str):
            self.select_surface(surface_id)

    def _current_workspace(self) -> Workspace:
        if self.current_workspace_id is None:
            return self.create_workspace(_("Default"), os.getcwd())
        return self.workspaces[self.current_workspace_id]

    def _current_surface(self) -> Surface:
        workspace = self._current_workspace()
        if workspace.current_surface_id is None:
            return self.create_surface()
        return workspace.surfaces[workspace.current_surface_id]


class CMUXLinuxApplication(Gtk.Application):
    def __init__(self, cwd: str, command: str | None, socket_path: Path) -> None:
        super().__init__(application_id=APP_ID, flags=application_flags())
        self.cwd = cwd
        self.command = command
        self.socket_path = socket_path
        self.main_window: CMUXLinuxWindow | None = None
        self.socket_server: SocketServer | None = None

    def do_activate(self) -> None:
        if self.main_window is None:
            self.main_window = CMUXLinuxWindow(self, self.cwd, self.command, local_socket_path=self.socket_path)
            self.socket_server = SocketServer(self.socket_path, self.main_window)
            self.socket_server.start()
        self.main_window.present()

    def do_shutdown(self) -> None:
        if self.main_window:
            self.main_window.save_runtime_state()
        if self.socket_server:
            self.socket_server.stop()
        Gtk.Application.do_shutdown(self)


def main() -> int:
    args = parse_args()
    if not has_graphical_session():
        print(
            "cmux Linux requires a graphical desktop session. Set DISPLAY or WAYLAND_DISPLAY before launching.",
            file=os.sys.stderr,
        )
        return 2
    socket_path = Path(args.socket_path) if args.socket_path else default_socket_path()
    application = CMUXLinuxApplication(args.cwd, args.command, socket_path)
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    return application.run([])
