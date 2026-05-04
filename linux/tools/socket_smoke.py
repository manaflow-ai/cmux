#!/usr/bin/env python3
from __future__ import annotations

import argparse
import http.server
import json
import os
import secrets
import shlex
import socket
import socketserver
import sys
import tempfile
import threading
import time
import uuid
from collections.abc import Mapping
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT_DIR / "linux" / "lib"))

from cmux_linux.capabilities import (  # noqa: E402
    REQUIRED_FAILURE_CODES,
    REQUIRED_SUBSYSTEMS,
    validate_subsystem_capabilities,
)
from cmux_linux.browser import BACKEND_LIMITED_BROWSER_METHODS  # noqa: E402
from cmux_linux.remote import compute_relay_auth_mac  # noqa: E402
from cmux_linux.terminal import LINUX_TERMINAL_BACKEND  # noqa: E402

BROWSER_SMOKE_HTML = """<!doctype html>
<html>
<head><title>cmux browser smoke</title></head>
<body>
  <button id="btn">Click</button>
  <label for="field">Field</label>
  <input id="field" placeholder="Smoke field">
  <iframe id="child" srcdoc="<html><body><button id='inner'>Inner</button></body></html>"></iframe>
  <script>window.addEventListener('click',()=>fetch('/ok'));</script>
</body>
</html>
"""

REQUIRED_PACKAGE_FORMATS = ("tarball", "deb", "appimage", "rpm", "flatpak")
REMOTE_SSH_RELAY_ID = "cmux-ci-relay"
REMOTE_SSH_CONNECT_TIMEOUT_SECONDS = 10.0


class BrowserSmokeHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/ok":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(BROWSER_SMOKE_HTML.encode("utf-8"))

    def log_message(self, _format: str, *_args: Any) -> None:
        return


def start_browser_smoke_server() -> tuple[socketserver.ThreadingTCPServer, threading.Thread, str]:
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), BrowserSmokeHandler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    return server, thread, f"http://{host}:{port}/"


def default_socket_path() -> Path:
    explicit = os.environ.get("CMUX_SOCKET_PATH") or os.environ.get("CMUX_SOCKET")
    if explicit:
        return Path(explicit)

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    base_dir = Path(runtime_dir) / "cmux" if runtime_dir else Path(tempfile.gettempdir()) / "cmux"
    return base_dir / "cmux.sock"


def send_command(socket_path: Path, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    request = {
        "id": str(uuid.uuid4()),
        "method": method,
        "params": params or {},
    }
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(str(socket_path))
        sock.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8"))
        return read_response(sock)


def send_legacy_command(socket_path: Path, command: str) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(str(socket_path))
        sock.sendall((command.rstrip("\n") + "\n").encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        chunks: list[bytes] = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    return b"".join(chunks).decode("utf-8").strip()


def read_response(sock: socket.socket) -> dict[str, Any]:
    chunks: list[bytes] = []
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        chunks.append(chunk)
        if b"\n" in chunk:
            break
    raw = b"".join(chunks).split(b"\n", 1)[0]
    if not raw:
        raise OSError("empty response")
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise OSError("invalid response")
    return value


def read_tcp_json_line(sock: socket.socket) -> dict[str, Any]:
    chunks: list[bytes] = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks = [*chunks, chunk]
        if b"\n" in chunk:
            break
    raw = b"".join(chunks).split(b"\n", 1)[0]
    if not raw:
        raise OSError("empty TCP relay response")
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise OSError("invalid TCP relay response")
    return value


def expect_ok(socket_path: Path, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    response = send_command(socket_path, method, params)
    if response.get("ok") is not True:
        raise AssertionError(f"{method} failed: {json.dumps(response, ensure_ascii=False)}")
    result = response.get("result")
    return result if isinstance(result, dict) else {}


def expect_not_supported(socket_path: Path, method: str) -> None:
    response = send_command(socket_path, method, {})
    error = response.get("error") if isinstance(response.get("error"), dict) else {}
    if response.get("ok") is not False or error.get("code") != "not_supported":
        raise AssertionError(f"{method} did not return not_supported: {json.dumps(response, ensure_ascii=False)}")


def validate_remote_daemon_payload(payload: Any, require_available: bool) -> None:
    if not isinstance(payload, dict):
        raise AssertionError("system.capabilities did not expose remoteDaemon")
    if not isinstance(payload.get("available"), bool):
        raise AssertionError("remoteDaemon.available was not boolean")
    if not isinstance(payload.get("bundled"), bool):
        raise AssertionError("remoteDaemon.bundled was not boolean")
    if require_available and payload.get("available") is not True:
        raise AssertionError(f"remote daemon was not available: {json.dumps(payload, ensure_ascii=False)}")
    if payload.get("available") is True and not isinstance(payload.get("path"), str):
        raise AssertionError("remoteDaemon.path was missing for an available daemon")


def validate_auth_payload(payload: dict[str, Any], *, expected_signed_in: bool | None = None) -> None:
    for field in (
        "signed_in",
        "authenticated",
        "required",
        "is_restoring_session",
        "is_loading",
        "timed_out",
        "user",
        "teams",
        "selected_team_id",
        "platform",
        "backend",
        "mode",
        "detail",
    ):
        if field not in payload:
            raise AssertionError(f"auth payload missing {field}")
    if payload.get("platform") != "linux":
        raise AssertionError("auth payload did not identify Linux")
    if payload.get("mode") not in {"bridge", "local_fallback"}:
        raise AssertionError("auth payload exposed an unexpected mode")
    if payload.get("mode") == "bridge" and payload.get("backend") != "cmux_auth_core_bridge":
        raise AssertionError("auth bridge payload did not identify cmux_auth_core_bridge")
    if payload.get("mode") == "local_fallback" and payload.get("backend") != "linux_local_state":
        raise AssertionError("auth fallback payload did not identify linux_local_state")
    if not isinstance(payload.get("teams"), list):
        raise AssertionError("auth payload did not expose teams as a list")
    if expected_signed_in is not None and payload.get("signed_in") is not expected_signed_in:
        raise AssertionError("auth payload signed_in did not match expected state")


def validate_capabilities_payload(payload: dict[str, Any]) -> None:
    errors = validate_subsystem_capabilities(payload.get("subsystems") if isinstance(payload.get("subsystems"), dict) else {})
    for subsystem in REQUIRED_SUBSYSTEMS:
        if not isinstance(payload.get(subsystem), dict):
            errors.append(f"top-level subsystem missing: {subsystem}")
    failure_codes = payload.get("failureCodes")
    if not isinstance(failure_codes, list):
        errors.append("failureCodes was not a list")
    else:
        for code in REQUIRED_FAILURE_CODES:
            if code not in failure_codes:
                errors.append(f"failureCodes missing {code}")
    if errors:
        raise AssertionError("; ".join(errors))
    validate_packaging_payload(payload.get("packaging"))


def validate_packaging_payload(payload: Any) -> None:
    if not isinstance(payload, dict):
        raise AssertionError("system.capabilities did not expose packaging")
    if payload.get("available") is not True:
        raise AssertionError("packaging capability was not available")
    if payload.get("backend") != "linux_package_validator" or payload.get("mode") != "artifact":
        raise AssertionError("packaging capability did not identify validator-backed artifacts")
    formats = payload.get("formats")
    if not isinstance(formats, dict):
        raise AssertionError("packaging capability did not expose formats")
    for package_format in REQUIRED_PACKAGE_FORMATS:
        status = formats.get(package_format)
        if not isinstance(status, dict):
            raise AssertionError(f"packaging format missing: {package_format}")
        if status.get("available") is not True:
            raise AssertionError(f"packaging format was not available: {package_format}")
        if status.get("mode") != "artifact":
            raise AssertionError(f"packaging format was not artifact-backed: {package_format}")
        if status.get("validator") != "linux/tools/validate_package.py":
            raise AssertionError(f"packaging format did not expose the package validator: {package_format}")


def validate_remote_relay_payload(payload: dict[str, Any], relay_port: int, relay_id: str) -> None:
    remote = payload.get("remote")
    if not isinstance(remote, dict):
        raise AssertionError("workspace.remote.configure did not expose remote status")
    if not isinstance(remote.get("active_terminal_sessions"), int):
        raise AssertionError("remote status did not expose active_terminal_sessions as an integer")
    if not isinstance(remote.get("active_terminal_session_details"), list):
        raise AssertionError("remote status did not expose active_terminal_session_details")
    relay = remote.get("relay")
    if not isinstance(relay, dict):
        raise AssertionError("remote status did not expose relay metadata")
    if relay.get("socket_addr") != f"127.0.0.1:{relay_port}":
        raise AssertionError("relay metadata exposed an unexpected socket address")
    if relay.get("remote_socket_addr_path") != "~/.cmux/socket_addr":
        raise AssertionError("relay metadata did not expose ~/.cmux/socket_addr")
    if relay.get("relay_auth_path") != f"~/.cmux/relay/{relay_port}.auth":
        raise AssertionError("relay metadata did not expose the auth file path")
    if relay.get("relay_daemon_path_path") != f"~/.cmux/relay/{relay_port}.daemon_path":
        raise AssertionError("relay metadata did not expose the daemon path file")
    if relay.get("auth_file_mode") != "0600":
        raise AssertionError("relay auth file mode must be 0600")
    if relay.get("relay_id") != relay_id:
        raise AssertionError("relay metadata did not preserve relay_id")
    if relay.get("hmac", {}).get("algorithm") != "HMAC-SHA256":
        raise AssertionError("relay metadata did not declare HMAC-SHA256")
    if "relay_token" in json.dumps(relay):
        raise AssertionError("relay metadata exposed relay_token")
    lifecycle = remote.get("lifecycle")
    if not isinstance(lifecycle, dict):
        raise AssertionError("remote status did not expose a lifecycle plan")
    if lifecycle.get("state") not in {"planned", "reconnect_requested", "disconnected"}:
        raise AssertionError("remote lifecycle exposed an unexpected state")
    bootstrap = remote.get("bootstrap")
    if not isinstance(bootstrap, dict):
        raise AssertionError("remote status did not expose bootstrap metadata")
    writes = bootstrap.get("writes")
    if not isinstance(writes, list):
        raise AssertionError("remote bootstrap did not expose planned writes")
    if not any(isinstance(item, dict) and item.get("path") == f"~/.cmux/relay/{relay_port}.auth" for item in writes):
        raise AssertionError("remote bootstrap did not include the relay auth file")
    proxy_lifecycle = remote.get("proxy", {}).get("lifecycle")
    if not isinstance(proxy_lifecycle, dict):
        raise AssertionError("remote proxy did not expose lifecycle metadata")
    if json.dumps(lifecycle).count("b" * 64) != 0:
        raise AssertionError("remote lifecycle exposed relay_token")


def validate_remote_foreground_auth_payload(payload: dict[str, Any], foreground_auth_token: str) -> None:
    remote = payload.get("remote")
    if not isinstance(remote, dict):
        raise AssertionError("workspace.remote.foreground_auth_ready did not expose remote status")
    foreground_auth = remote.get("foreground_auth")
    if not isinstance(foreground_auth, dict):
        raise AssertionError("remote status did not expose foreground_auth metadata")
    if foreground_auth.get("ready") is not True or remote.get("foreground_auth_ready") is not True:
        raise AssertionError("foreground auth ready did not mark the workspace ready")
    if foreground_auth.get("has_token") is not True or remote.get("has_foreground_auth_token") is not True:
        raise AssertionError("foreground auth ready did not preserve token presence")
    lifecycle = remote.get("lifecycle")
    if not isinstance(lifecycle, dict) or lifecycle.get("state") != "foreground_auth_ready":
        raise AssertionError("foreground auth ready did not update remote lifecycle state")
    configuration = remote.get("configuration")
    if not isinstance(configuration, dict) or not configuration.get("foreground_auth_ready_at"):
        raise AssertionError("foreground auth ready was not reflected in public configuration")
    if foreground_auth_token in json.dumps(remote):
        raise AssertionError("foreground auth ready exposed the auth token value")


def validate_remote_ssh_connected_payload(payload: dict[str, Any], relay_port: int, relay_id: str) -> None:
    remote = payload.get("remote")
    if not isinstance(remote, dict):
        raise AssertionError("remote SSH smoke did not expose remote status")
    if remote.get("connected") is not True:
        raise AssertionError(f"remote SSH proxy was not connected: {json.dumps(remote, ensure_ascii=False)}")
    if remote.get("daemon_ready") is not True:
        raise AssertionError("remote SSH bootstrap did not mark the daemon ready")
    if remote.get("relay_port") != relay_port or remote.get("relay_id") != relay_id:
        raise AssertionError("remote SSH status did not preserve relay identity")
    daemon = remote.get("daemon") if isinstance(remote.get("daemon"), dict) else {}
    if daemon.get("state") != "running":
        raise AssertionError("remote SSH runtime did not mark daemon state running")
    proxy = remote.get("proxy") if isinstance(remote.get("proxy"), dict) else {}
    if proxy.get("state") != "running":
        raise AssertionError("remote SSH proxy did not report running state")
    relay_server = proxy.get("relay_server") if isinstance(proxy.get("relay_server"), dict) else {}
    if relay_server.get("listening") is not True:
        raise AssertionError("remote SSH relay server was not listening locally")
    lifecycle = remote.get("lifecycle") if isinstance(remote.get("lifecycle"), dict) else {}
    daemon_lifecycle = lifecycle.get("daemon") if isinstance(lifecycle.get("daemon"), dict) else {}
    daemon_probe = daemon_lifecycle.get("probe") if isinstance(daemon_lifecycle.get("probe"), dict) else {}
    if daemon_probe.get("ok") is not True or daemon_probe.get("ping") is not True:
        raise AssertionError("remote SSH stdio hello/ping probe did not succeed")
    if "relay_token" in json.dumps(remote):
        raise AssertionError("remote SSH status exposed relay_token")


def validate_remote_ssh_disconnected_payload(payload: dict[str, Any]) -> None:
    remote = payload.get("remote")
    if not isinstance(remote, dict):
        raise AssertionError("remote disconnect did not expose remote status")
    if remote.get("connected") is not False:
        raise AssertionError("remote disconnect left the proxy connected")
    proxy = remote.get("proxy") if isinstance(remote.get("proxy"), dict) else {}
    if proxy.get("state") not in {"disconnected", "configured"}:
        raise AssertionError("remote disconnect did not stop the proxy")


def validate_browser_backend_limit(method: str, payload: dict[str, Any]) -> None:
    expected = BACKEND_LIMITED_BROWSER_METHODS.get(method)
    if expected is None:
        return
    limit = payload.get("backend_limit")
    if not isinstance(limit, dict):
        raise AssertionError(f"{method} did not expose backend_limit")
    if limit.get("code") != "backend_limit":
        raise AssertionError(f"{method} returned an unexpected backend limit code")
    if limit.get("method") != method:
        raise AssertionError(f"{method} backend_limit did not preserve method name")
    if limit.get("backend") != "webkitgtk":
        raise AssertionError(f"{method} backend_limit did not identify WebKitGTK")
    if limit.get("capability") != expected.get("capability"):
        raise AssertionError(f"{method} backend_limit exposed an unexpected capability")
    if not limit.get("reason"):
        raise AssertionError(f"{method} backend_limit did not include reason")


def validate_ports_kick_payload(payload: dict[str, Any]) -> None:
    scanner = payload.get("scanner")
    if not isinstance(scanner, dict):
        raise AssertionError("surface.ports_kick did not expose scanner metadata")
    if scanner.get("backend") != LINUX_TERMINAL_BACKEND:
        raise AssertionError("surface.ports_kick scanner did not identify VTE")
    if scanner.get("available") is not False:
        raise AssertionError("surface.ports_kick scanner must be unavailable on Linux VTE")
    if scanner.get("reason") != "unsupported_on_linux_backend":
        raise AssertionError("surface.ports_kick scanner did not expose the Linux backend limitation")
    for field in ("ports", "listening_ports", "detected_ports", "forwarded_ports", "conflicted_ports"):
        if not isinstance(payload.get(field), list):
            raise AssertionError(f"surface.ports_kick did not expose {field} as a list")
    if payload.get("pending") is not False:
        raise AssertionError("surface.ports_kick must expose pending=false on Linux VTE")


def validate_debug_terminal_payload(payload: dict[str, Any], surface_id: str, tty_name: str) -> None:
    if payload.get("backend") != LINUX_TERMINAL_BACKEND:
        raise AssertionError("debug.terminals did not identify VTE")
    if payload.get("renderer", {}).get("ghostty", {}).get("reason") != "unsupported_on_linux_backend":
        raise AssertionError("debug.terminals did not expose the Ghostty backend limitation")
    terminals = payload.get("terminals")
    if not isinstance(terminals, list):
        raise AssertionError("debug.terminals did not expose terminals as a list")
    matching = [item for item in terminals if isinstance(item, dict) and item.get("surface_id") == surface_id]
    if not matching:
        raise AssertionError("debug.terminals did not include the current surface")
    terminal = matching[0]
    for field in (
        "tty",
        "tty_name",
        "current_directory",
        "cwd",
        "listening_ports",
        "detected_ports",
        "forwarded_ports",
        "conflicted_ports",
        "runtime_surface_ready",
        "renderer",
        "scanner",
        "ghostty_surface_ptr",
        "terminal_object_ptr",
        "hosted_view_class",
    ):
        if field not in terminal:
            raise AssertionError(f"debug.terminals item missing {field}")
    if terminal.get("tty") != tty_name or terminal.get("tty_name") != tty_name:
        raise AssertionError("debug.terminals did not preserve the reported tty")
    if not isinstance(terminal.get("listening_ports"), list):
        raise AssertionError("debug.terminals did not expose listening_ports as a list")
    for field in ("detected_ports", "forwarded_ports", "conflicted_ports"):
        if terminal.get(field) != []:
            raise AssertionError(f"debug.terminals must expose empty {field} on Linux VTE")
    if terminal.get("scanner", {}).get("reason") != "unsupported_on_linux_backend":
        raise AssertionError("debug.terminals did not expose scanner limitation on the item")


def validate_window_payload(payload: dict[str, Any]) -> None:
    for field in (
        "window_id",
        "window_ref",
        "visible",
        "visibility_state",
        "focus_state",
        "is_current",
        "last_window_policy",
        "selected_workspace_id",
        "focused_surface_id",
        "focused_pane_id",
    ):
        if field not in payload:
            raise AssertionError(f"window payload missing {field}")
    if payload.get("last_window_policy") != "quit_app":
        raise AssertionError("window payload did not expose last window quit policy")
    if payload.get("visibility_state") not in {"visible", "hidden"}:
        raise AssertionError("window payload exposed an invalid visibility state")
    if payload.get("focus_state") not in {"current", "background"}:
        raise AssertionError("window payload exposed an invalid focus state")


def validate_feedback_submit_payload(payload: dict[str, Any], *, require_submitted: bool = False) -> None:
    if payload.get("stored") is not True:
        raise AssertionError("feedback.submit did not persist the submission")
    if not isinstance(payload.get("submission_id"), str) or not payload.get("submission_id"):
        raise AssertionError("feedback.submit did not expose submission_id")
    if not isinstance(payload.get("attachment_count"), int):
        raise AssertionError("feedback.submit did not expose attachment_count")
    status = payload.get("status")
    transport = payload.get("transport")
    detail = payload.get("detail")
    submitted = payload.get("submitted")
    queued = payload.get("queued")
    if require_submitted and status != "submitted":
        raise AssertionError(f"feedback.submit did not upload to the configured endpoint: {payload}")
    if status == "submitted":
        if submitted is not True or queued is not False:
            raise AssertionError("feedback.submit submitted status has inconsistent booleans")
        if transport != "http_upload" or detail != "uploaded":
            raise AssertionError("feedback.submit submitted status did not use http_upload")
    elif status == "queued":
        if submitted is not False or queued is not True:
            raise AssertionError("feedback.submit queued status has inconsistent booleans")
        if transport != "local_queue":
            raise AssertionError("feedback.submit queued status did not use local_queue")
        if detail not in {"feedback_endpoint_unconfigured", "transport_error"}:
            raise AssertionError("feedback.submit queued status exposed an unexpected detail")
        if detail == "transport_error" and payload.get("error_code") != "transport_error":
            raise AssertionError("feedback.submit transport_error detail did not expose error_code")
    else:
        raise AssertionError(f"feedback.submit exposed unexpected status: {status}")


def validate_feedback_upload_capture(marker: str) -> None:
    requests_file = os.environ.get("CMUX_FEEDBACK_REQUESTS_FILE")
    if not requests_file:
        raise AssertionError("CMUX_FEEDBACK_REQUESTS_FILE was not configured")
    path = Path(requests_file)
    for _ in range(20):
        if path.is_file() and path.stat().st_size > 0:
            break
        time.sleep(0.05)
    if not path.is_file() or path.stat().st_size == 0:
        raise AssertionError("feedback mock server did not record an upload")
    records = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    matched = any(
        isinstance(record, dict)
        and record.get("method") == "POST"
        and "multipart/form-data" in str(record.get("content_type") or "")
        and record.get("user_agent") == "cmux-linux"
        and marker in str(record.get("body_text") or "")
        for record in records
    )
    if not matched:
        raise AssertionError("feedback mock server did not receive the expected multipart upload")


def validate_feed_push_payload(payload: dict[str, Any]) -> str:
    status = payload.get("status")
    if status not in {"acknowledged", "resolved", "timed_out"}:
        raise AssertionError(f"feed.push exposed unexpected status: {status}")
    item_id = payload.get("item_id")
    if not isinstance(item_id, str) or not item_id:
        raise AssertionError("feed.push did not expose item_id")
    if status == "acknowledged" and not isinstance(payload.get("wait_timeout_seconds"), (int, float)):
        raise AssertionError("feed.push acknowledged payload did not expose wait_timeout_seconds")
    if status == "resolved":
        validate_feed_reply_payload(payload)
    return item_id


def validate_feed_reply_payload(payload: dict[str, Any]) -> None:
    decision = payload.get("decision")
    if not isinstance(decision, dict):
        raise AssertionError("feed reply did not expose decision")
    stdout = payload.get("stdout_decision_json") or payload.get("stdout")
    if not isinstance(stdout, str) or not stdout:
        raise AssertionError("feed reply did not expose stdout decision JSON")
    decoded = json.loads(stdout)
    if decoded.get("decision") != decision:
        raise AssertionError("feed reply stdout decision JSON did not match decision")


def validate_feed_list_payload(payload: dict[str, Any], item_id: str, request_id: str) -> None:
    items = payload.get("items")
    if not isinstance(items, list):
        raise AssertionError("feed.list did not expose items")
    matching = [item for item in items if isinstance(item, dict) and item.get("id") == item_id]
    if not matching:
        raise AssertionError("feed.list did not include the pushed feed item")
    item = matching[0]
    if item.get("kind") != "permissionRequest":
        raise AssertionError("feed.list item kind did not match WorkstreamKind.permissionRequest")
    if item.get("status") != "resolved":
        raise AssertionError("feed.list item was not resolved after feed.permission.reply")
    if item.get("request_id") != request_id:
        raise AssertionError("feed.list item did not preserve request_id")
    if not isinstance(item.get("created_at"), str) or "T" not in item["created_at"]:
        raise AssertionError("feed.list item did not expose an ISO8601 created_at")
    decision = item.get("decision")
    if not isinstance(decision, dict) or decision.get("kind") != "permission":
        raise AssertionError("feed.list resolved item did not expose the permission decision")


def find_free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def env_truthy(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def env_port(env: Mapping[str, str], key: str, default: int | None = None) -> int | None:
    raw = str(env.get(key) or "").strip()
    if not raw:
        return default
    try:
        port = int(raw)
    except ValueError as error:
        raise AssertionError(f"{key} must be a TCP port") from error
    if port < 1 or port > 65_535:
        raise AssertionError(f"{key} must be a TCP port")
    return port


def remote_ssh_smoke_config_from_env(
    env: Mapping[str, str] = os.environ,
    *,
    allocate_port: Any = find_free_tcp_port,
) -> dict[str, Any] | None:
    destination = str(env.get("CMUX_REMOTE_SSH_DESTINATION") or "").strip()
    if not destination and not env_truthy(env.get("CMUX_REMOTE_SSH_SMOKE")):
        return None
    if not destination:
        user = str(env.get("USER") or "runner").strip() or "runner"
        destination = f"{user}@127.0.0.1"
    local_proxy_port = env_port(env, "CMUX_REMOTE_SSH_LOCAL_PROXY_PORT") or int(allocate_port())
    relay_port = env_port(env, "CMUX_REMOTE_SSH_RELAY_PORT") or int(allocate_port())
    if relay_port == local_proxy_port:
        relay_port = int(allocate_port())
    relay_token = str(env.get("CMUX_REMOTE_SSH_RELAY_TOKEN") or "").strip() or secrets.token_hex(32)
    if len(relay_token) != 64 or any(char not in "0123456789abcdef" for char in relay_token):
        raise AssertionError("CMUX_REMOTE_SSH_RELAY_TOKEN must be 64 lowercase hex characters")
    ssh_options = shlex.split(str(env.get("CMUX_REMOTE_SSH_OPTIONS") or ""))
    params: dict[str, Any] = {
        "destination": destination,
        "port": env_port(env, "CMUX_REMOTE_SSH_PORT"),
        "ssh_options": ssh_options,
        "local_proxy_port": local_proxy_port,
        "relay_port": relay_port,
        "relay_id": str(env.get("CMUX_REMOTE_SSH_RELAY_ID") or REMOTE_SSH_RELAY_ID).strip() or REMOTE_SSH_RELAY_ID,
        "relay_token": relay_token,
        "auto_connect": True,
    }
    identity_file = str(env.get("CMUX_REMOTE_SSH_IDENTITY_FILE") or "").strip()
    if identity_file:
        params = {**params, "identity_file": identity_file}
    return {
        "params": params,
        "relay_token": relay_token,
        "relay_port": relay_port,
        "relay_id": params["relay_id"],
    }


def remote_relay_ping(relay_port: int, relay_id: str, relay_token: str) -> None:
    deadline = time.monotonic() + REMOTE_SSH_CONNECT_TIMEOUT_SECONDS
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", relay_port), timeout=1.0) as sock:
                challenge = read_tcp_json_line(sock)
                nonce = str(challenge.get("nonce") or "")
                if challenge.get("protocol") != "cmux-relay-auth" or challenge.get("relay_id") != relay_id:
                    raise AssertionError("remote relay challenge did not match the cmux protocol")
                mac = compute_relay_auth_mac(relay_id=relay_id, relay_token=relay_token, nonce=nonce)
                sock.sendall((json.dumps({"relay_id": relay_id, "mac": mac}, separators=(",", ":")) + "\n").encode("utf-8"))
                auth_result = read_tcp_json_line(sock)
                if auth_result.get("ok") is not True:
                    raise AssertionError("remote relay rejected the HMAC response")
                request = {"id": "remote-relay-ping", "method": "system.ping", "params": {}}
                sock.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8"))
                response = read_tcp_json_line(sock)
                if response.get("ok") is not True or response.get("id") != "remote-relay-ping":
                    raise AssertionError("remote relay did not proxy system.ping through the socket")
                return
        except (AssertionError, OSError, json.JSONDecodeError) as error:
            last_error = error
            time.sleep(0.2)
    raise AssertionError(f"remote relay ping failed: {last_error}") from last_error


def smoke_remote_ssh(socket_path: Path, config: dict[str, Any]) -> list[str]:
    workspace_id = current_workspace_id(socket_path)
    if not workspace_id:
        raise AssertionError("remote SSH smoke could not determine the current workspace")
    params = {**config["params"], "workspace_id": workspace_id}
    relay_port = int(config["relay_port"])
    relay_id = str(config["relay_id"])
    relay_token = str(config["relay_token"])
    try:
        configured = expect_ok(socket_path, "workspace.remote.configure", params)
        validate_remote_ssh_connected_payload(configured, relay_port, relay_id)
        remote_relay_ping(relay_port, relay_id, relay_token)
        status = expect_ok(socket_path, "workspace.remote.status", {"workspace_id": workspace_id})
        validate_remote_ssh_connected_payload(status, relay_port, relay_id)
        disconnected = expect_ok(socket_path, "workspace.remote.disconnect", {"workspace_id": workspace_id})
        validate_remote_ssh_disconnected_payload(disconnected)
        return [
            "workspace.remote.configure.ssh",
            "workspace.remote.relay.hmac_ping",
            "workspace.remote.status.ssh",
            "workspace.remote.disconnect.ssh",
        ]
    finally:
        try:
            expect_ok(socket_path, "workspace.remote.disconnect", {"workspace_id": workspace_id})
        except (AssertionError, OSError, json.JSONDecodeError):
            pass


def smoke_legacy_v1(socket_path: Path, initial_window_count: int) -> list[str]:
    if send_legacy_command(socket_path, "ping") != "PONG":
        raise AssertionError("legacy v1 ping did not return PONG")
    current = send_legacy_command(socket_path, "current_window")
    if not current or current.startswith("ERROR:"):
        raise AssertionError(f"legacy v1 current_window failed: {current}")
    listed = send_legacy_command(socket_path, "list_windows")
    if "selected_workspace=" not in listed or "workspaces=" not in listed:
        raise AssertionError("legacy v1 list_windows did not expose macOS CLI window fields")

    created = send_legacy_command(socket_path, "new_window")
    if not created.startswith("OK "):
        raise AssertionError(f"legacy v1 new_window failed: {created}")
    created_id = created.split(maxsplit=1)[1].strip()
    if not created_id:
        raise AssertionError("legacy v1 new_window did not return a window id")
    windows_after_create = expect_ok(socket_path, "window.list").get("windows", [])
    if len(windows_after_create) != initial_window_count + 1:
        raise AssertionError("legacy v1 new_window did not create an independent window")

    if send_legacy_command(socket_path, f"focus_window {created_id}") != "OK":
        raise AssertionError("legacy v1 focus_window did not return OK")
    focused = expect_ok(socket_path, "window.current")
    if focused.get("window_id") != created_id:
        raise AssertionError("legacy v1 focus_window did not update the current window")

    if send_legacy_command(socket_path, f"close_window {created_id}") != "OK":
        raise AssertionError("legacy v1 close_window did not return OK")
    windows_after_close = expect_ok(socket_path, "window.list").get("windows", [])
    if len(windows_after_close) != initial_window_count:
        raise AssertionError("legacy v1 close_window did not remove the created window")
    return [
        "legacy.v1.ping",
        "legacy.v1.current_window",
        "legacy.v1.list_windows",
        "legacy.v1.new_window",
        "legacy.v1.focus_window",
        "legacy.v1.close_window",
    ]


def smoke_core(socket_path: Path) -> list[str]:
    checked: list[str] = []
    for method in (
        "system.ping",
        "system.identify",
        "system.capabilities",
        "system.tree",
        "window.list",
        "window.current",
        "window.focus",
        "app.simulate_active",
        "workspace.move_to_window",
        "notification.list",
        "notification.clear",
        "debug.terminals",
    ):
        expect_ok(socket_path, method)
        checked.append(method)
    validate_auth_payload(expect_ok(socket_path, "auth.status"))
    checked.append("auth.status")
    validate_auth_payload(expect_ok(socket_path, "auth.login"), expected_signed_in=True)
    checked.append("auth.login")
    validate_auth_payload(expect_ok(socket_path, "auth.begin_sign_in"), expected_signed_in=True)
    checked.append("auth.begin_sign_in")
    validate_auth_payload(expect_ok(socket_path, "auth.sign_out"), expected_signed_in=False)
    checked.append("auth.sign_out")
    initial_windows = expect_ok(socket_path, "window.list").get("windows", [])
    for window in initial_windows:
        validate_window_payload(window)
    checked = [*checked, *smoke_legacy_v1(socket_path, len(initial_windows))]
    created_window = expect_ok(socket_path, "window.create")
    checked.append("window.create")
    validate_window_payload(created_window)
    created_id = created_window.get("window_id")
    windows_after_create = expect_ok(socket_path, "window.list").get("windows", [])
    if not isinstance(created_id, str) or len(windows_after_create) != len(initial_windows) + 1:
        raise AssertionError("window.create did not add an independent window")
    if created_window.get("focus_state") != "background" or created_window.get("is_current") is not False:
        raise AssertionError("window.create must not steal focus; use window.focus for focus intent")
    current_before_move = expect_ok(socket_path, "window.current").get("window_id")
    workspace_to_move = expect_ok(
        socket_path,
        "workspace.create",
        {"name": "Window Move Smoke", "cwd": "/tmp", "select": False},
    )
    checked.append("workspace.create")
    moved_workspace_id = workspace_to_move.get("workspace_id") or workspace_to_move.get("id")
    if not isinstance(moved_workspace_id, str) or not moved_workspace_id:
        raise AssertionError("workspace.create did not return a workspace id")
    move_result = expect_ok(
        socket_path,
        "workspace.move_to_window",
        {"workspace_id": moved_workspace_id, "window_id": created_id},
    )
    if move_result.get("moved") is not True or move_result.get("reason") != "moved_to_window":
        raise AssertionError(f"workspace.move_to_window did not move the workspace: {move_result}")
    if move_result.get("focus_side_effect") is not False:
        raise AssertionError("workspace.move_to_window must not report focus side effects")
    current_after_move = expect_ok(socket_path, "window.current").get("window_id")
    if current_after_move != current_before_move:
        raise AssertionError("workspace.move_to_window stole the current window focus")
    windows_after_move = expect_ok(socket_path, "window.list").get("windows", [])
    target_window = next(
        (window for window in windows_after_move if isinstance(window, dict) and window.get("window_id") == created_id),
        None,
    )
    source_window = next(
        (
            window
            for window in windows_after_move
            if isinstance(window, dict) and window.get("window_id") == current_before_move
        ),
        None,
    )
    if not isinstance(target_window, dict) or moved_workspace_id not in target_window.get("workspace_ids", []):
        raise AssertionError("workspace.move_to_window did not attach the workspace to the target window")
    if isinstance(source_window, dict) and moved_workspace_id in source_window.get("workspace_ids", []):
        raise AssertionError("workspace.move_to_window left the workspace attached to the source window")
    checked.append("workspace.move_to_window.real")
    close_result = expect_ok(socket_path, "window.close", {"window_id": created_id})
    checked.append("window.close")
    windows_after_close = expect_ok(socket_path, "window.list").get("windows", [])
    if close_result.get("closed") is not True or len(windows_after_close) != len(initial_windows):
        raise AssertionError("window.close did not remove the created window")
    expect_ok(socket_path, "app.focus_override.set", {"state": "active"})
    checked.append("app.focus_override.set")
    expect_ok(socket_path, "app.focus_override.set", {"state": "clear"})

    notification = expect_ok(socket_path, "notification.create", {"title": "cmux smoke", "body": "socket smoke"})
    checked.append("notification.create")
    workspace_id = current_workspace_id(socket_path)
    surface_id = current_surface_id(socket_path)
    pane_id = current_pane_id(socket_path)
    expect_ok(socket_path, "notification.create_for_surface", {"surface_id": surface_id, "title": "surface"})
    checked.append("notification.create_for_surface")
    expect_ok(
        socket_path,
        "notification.create_for_target",
        {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
            "target": {"kind": "surface", "workspace_id": workspace_id, "surface_id": surface_id},
            "title": "target",
        },
    )
    checked.append("notification.create_for_target")
    tty_name = "/dev/pts/cmux-smoke"
    expect_ok(socket_path, "surface.report_tty", {"surface_id": surface_id, "tty": tty_name})
    checked.append("surface.report_tty")
    validate_ports_kick_payload(expect_ok(socket_path, "surface.ports_kick", {"surface_id": surface_id}))
    checked.append("surface.ports_kick")
    validate_debug_terminal_payload(expect_ok(socket_path, "debug.terminals"), surface_id, tty_name)
    expect_ok(socket_path, "workspace.remote.status", {"workspace_id": workspace_id})
    checked.append("workspace.remote.status")
    relay_port = 31000
    relay_id = "cmux-smoke-relay"
    configured_remote = expect_ok(
        socket_path,
        "workspace.remote.configure",
        {
            "workspace_id": workspace_id,
            "destination": "localhost",
            "port": 22,
            "relay_port": relay_port,
            "relay_id": relay_id,
            "relay_token": "b" * 64,
            "auto_connect": False,
        },
    )
    validate_remote_relay_payload(configured_remote, relay_port, relay_id)
    checked.append("workspace.remote.configure")
    foreground_auth_token = "cmux-smoke-foreground-token"
    foreground_auth_remote = expect_ok(
        socket_path,
        "workspace.remote.foreground_auth_ready",
        {"workspace_id": workspace_id, "foreground_auth_token": foreground_auth_token},
    )
    validate_remote_foreground_auth_payload(foreground_auth_remote, foreground_auth_token)
    checked.append("workspace.remote.foreground_auth_ready")
    expect_ok(socket_path, "workspace.remote.reconnect", {"workspace_id": workspace_id})
    checked.append("workspace.remote.reconnect")
    expect_ok(
        socket_path,
        "workspace.remote.terminal_session_end",
        {"workspace_id": workspace_id, "surface_id": surface_id, "pane_id": pane_id, "relay_port": relay_port},
    )
    remote_after_end = expect_ok(socket_path, "workspace.remote.status", {"workspace_id": workspace_id}).get("remote")
    if not isinstance(remote_after_end, dict) or remote_after_end.get("active_terminal_sessions") != 0:
        raise AssertionError("remote terminal_session_end did not remove the ended terminal pane from active sessions")
    checked.append("workspace.remote.terminal_session_end")
    expect_ok(socket_path, "workspace.remote.disconnect", {"workspace_id": workspace_id})
    checked.append("workspace.remote.disconnect")
    expect_ok(socket_path, "session.restore_previous")
    checked.append("session.restore_previous")
    expect_ok(socket_path, "feedback.open")
    checked.append("feedback.open")
    feedback_body = "Linux socket smoke upload"
    require_feedback_upload = os.environ.get("CMUX_EXPECT_FEEDBACK_UPLOAD") == "1"
    validate_feedback_submit_payload(
        expect_ok(socket_path, "feedback.submit", {"email": "smoke@example.com", "body": feedback_body}),
        require_submitted=require_feedback_upload,
    )
    if require_feedback_upload:
        validate_feedback_upload_capture(feedback_body)
    checked.append("feedback.submit")
    request_id = f"cmux-smoke-{uuid.uuid4()}"
    feed_push = expect_ok(
        socket_path,
        "feed.push",
        {
            "event": {
                "session_id": "cmux-smoke-session",
                "hook_event_name": "PermissionRequest",
                "_source": "cmux-smoke",
                "_opencode_request_id": request_id,
                "cwd": str(Path.cwd()),
            },
            "wait_timeout_seconds": 0,
        },
    )
    feed_item_id = validate_feed_push_payload(feed_push)
    checked.append("feed.push")
    validate_feed_reply_payload(expect_ok(socket_path, "feed.permission.reply", {"request_id": request_id, "mode": "once"}))
    checked.append("feed.permission.reply")
    validate_feed_reply_payload(
        expect_ok(
            socket_path,
            "feed.question.reply",
            {"request_id": f"{request_id}-question", "selections": ["yes"]},
        )
    )
    checked.append("feed.question.reply")
    validate_feed_reply_payload(
        expect_ok(
            socket_path,
            "feed.exit_plan.reply",
            {"request_id": f"{request_id}-exit", "mode": "manual", "feedback": "ok"},
        )
    )
    checked.append("feed.exit_plan.reply")
    expect_ok(socket_path, "feed.jump", {"workstream_id": "cmux-smoke-session"})
    checked.append("feed.jump")
    validate_feed_list_payload(expect_ok(socket_path, "feed.list"), feed_item_id, request_id)
    checked.append("feed.list")
    if notification.get("notification_id"):
        expect_ok(socket_path, "notification.clear", {"notification_id": notification["notification_id"]})
    return checked


def smoke_browser(socket_path: Path) -> list[str]:
    server, thread, url = start_browser_smoke_server()
    try:
        opened = expect_ok(socket_path, "browser.open_split", {"url": url})
        pane_id = opened.get("pane_id") or (opened.get("pane") or {}).get("id")
        params = {"pane_id": pane_id} if pane_id else {}
        time.sleep(0.5)

        checks = [
            ("browser.viewport.set", {**params, "width": 900, "height": 700}),
            ("browser.geolocation.set", {**params, "latitude": 37.7749, "longitude": -122.4194, "accuracy": 10}),
            ("browser.offline.set", {**params, "offline": False}),
            ("browser.trace.start", params),
            ("browser.network.route", {**params, "pattern": "*"}),
            ("browser.network.requests", params),
            ("browser.screencast.start", params),
            ("browser.input_mouse", {**params, "selector": "#btn", "type": "click"}),
            ("browser.input_keyboard", {**params, "key": "A", "type": "press"}),
            ("browser.input_touch", {**params, "selector": "#btn", "type": "touchstart"}),
            ("browser.dialog.accept", params),
            ("browser.frame.select", {**params, "selector": "#child"}),
            ("browser.frame.main", params),
            ("browser.screencast.stop", params),
            ("browser.network.unroute", {**params, "pattern": "*"}),
            ("browser.trace.stop", params),
        ]
        checked = ["browser.open_split"]
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".md", delete=False) as handle:
            handle.write("# cmux smoke\n\nMarkdown preview")
            markdown_path = handle.name
        try:
            expect_ok(socket_path, "markdown.open", {"path": markdown_path, "direction": "down"})
            checked.append("markdown.open")
        finally:
            Path(markdown_path).unlink(missing_ok=True)
        for method, method_params in checks:
            result = expect_ok(socket_path, method, method_params)
            validate_browser_backend_limit(method, result)
            checked.append(method)

        expect_ok(socket_path, "browser.fill", {**params, "selector": "#field", "text": "cmux"})
        value = expect_ok(socket_path, "browser.get.value", {**params, "selector": "#field"}).get("value")
        if value != "cmux":
            raise AssertionError(f"browser.get.value returned {value!r}")
        checked.extend(["browser.fill", "browser.get.value"])

        expect_ok(socket_path, "browser.cookies.set", {**params, "name": "cmux_smoke", "value": "cookie"})
        cookies = expect_ok(socket_path, "browser.cookies.get", {**params, "name": "cmux_smoke"}).get("cookies")
        if not any(isinstance(cookie, dict) and cookie.get("value") == "cookie" for cookie in cookies or []):
            raise AssertionError("browser cookie round-trip failed")
        expect_ok(socket_path, "browser.cookies.clear", {**params, "name": "cmux_smoke"})
        checked.extend(["browser.cookies.set", "browser.cookies.get", "browser.cookies.clear"])

        expect_ok(socket_path, "browser.storage.set", {**params, "key": "cmux_smoke", "value": "storage"})
        storage_value = expect_ok(socket_path, "browser.storage.get", {**params, "key": "cmux_smoke"}).get("value")
        if storage_value != "storage":
            raise AssertionError(f"browser.storage.get returned {storage_value!r}")
        expect_ok(socket_path, "browser.storage.clear", {**params, "key": "cmux_smoke"})
        checked.extend(["browser.storage.set", "browser.storage.get", "browser.storage.clear"])

        screenshot = expect_ok(socket_path, "browser.screenshot", params).get("png_base64")
        if not isinstance(screenshot, str) or len(screenshot) < 20:
            raise AssertionError("browser.screenshot did not return PNG data")
        checked.append("browser.screenshot")

        expect_ok(socket_path, "browser.console.clear", params)
        eval_result = expect_ok(
            socket_path,
            "browser.eval",
            {**params, "script": "console.log('cmux-console-smoke'); console.error('cmux-error-smoke'); 'console-done'"},
        )
        if eval_result.get("value") != "console-done":
            raise AssertionError("browser.eval did not return the expected value")
        console_entries = expect_ok(socket_path, "browser.console.list", params).get("entries")
        error_entries = expect_ok(socket_path, "browser.errors.list", params).get("entries")
        if not any("cmux-console-smoke" in str(entry) for entry in console_entries or []):
            raise AssertionError("browser.console.list did not capture console.log")
        if not any("cmux-error-smoke" in str(entry) for entry in error_entries or []):
            raise AssertionError("browser.errors.list did not capture console.error")
        checked.extend(["browser.console.clear", "browser.eval", "browser.console.list", "browser.errors.list"])

        new_tab = expect_ok(socket_path, "browser.tab.new", {"url": url})
        tabs = expect_ok(socket_path, "browser.tab.list").get("tabs")
        new_pane_id = new_tab.get("pane_id") or (new_tab.get("pane") or {}).get("id")
        if not any(isinstance(tab, dict) and tab.get("surface_id") == new_tab.get("surface_id") for tab in tabs or []):
            raise AssertionError("browser.tab.list did not include the newly opened tab")
        expect_ok(socket_path, "browser.tab.close", {"pane_id": new_pane_id})
        checked.extend(["browser.tab.new", "browser.tab.list", "browser.tab.close"])
        return checked
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


def smoke_state(socket_path: Path) -> list[str]:
    marker = f"cmux-state-smoke-{uuid.uuid4()}"
    workspace_name = f"State Smoke {marker}"
    created = expect_ok(socket_path, "workspace.create", {"name": workspace_name, "cwd": "/tmp", "select": True})
    workspace = created.get("workspace") if isinstance(created.get("workspace"), dict) else created
    workspace_id = workspace.get("id") or created.get("workspace_id") or current_workspace_id(socket_path)
    if not workspace_id:
        raise AssertionError("workspace.create did not return a workspace id")
    description = f"State description\n{marker}"
    pinned = expect_ok(socket_path, "workspace.action", {"workspace_id": workspace_id, "action": "pin"})
    if pinned.get("pinned") is not True:
        raise AssertionError("workspace.action pin did not persist pinned state")
    described = expect_ok(
        socket_path,
        "workspace.action",
        {"workspace_id": workspace_id, "action": "set-description", "description": description},
    )
    if described.get("description") != description:
        raise AssertionError("workspace.action set-description did not return normalized description")
    colored = expect_ok(socket_path, "workspace.action", {"workspace_id": workspace_id, "action": "set-color", "color": "amber"})
    if colored.get("color") != "#7D6608":
        raise AssertionError("workspace.action set-color did not return normalized color")
    validate_auth_payload(expect_ok(socket_path, "auth.login"), expected_signed_in=True)
    expect_ok(
        socket_path,
        "workspace.remote.configure",
        {"workspace_id": workspace_id, "destination": "state-smoke.example", "port": 22, "auto_connect": False},
    )
    validate_feedback_submit_payload(
        expect_ok(socket_path, "feedback.submit", {"email": f"{marker}@example.com", "body": marker})
    )
    expect_ok(
        socket_path,
        "feed.push",
        {
            "event": {
                "session_id": marker,
                "hook_event_name": "PermissionRequest",
                "_source": "cmux-state-smoke",
                "_opencode_request_id": marker,
                "cwd": "/tmp",
            }
        },
    )
    capabilities = expect_ok(socket_path, "system.capabilities")
    state_info = capabilities.get("state")
    if not isinstance(state_info, dict) or not isinstance(state_info.get("path"), str):
        raise AssertionError("system.capabilities did not expose a state path")
    state_path = Path(state_info["path"])
    if not state_path.is_file():
        raise AssertionError(f"state file was not written: {state_path}")
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if state.get("schema_version") != 1:
        raise AssertionError(f"unexpected state schema_version: {state.get('schema_version')}")
    auth = state.get("auth") if isinstance(state.get("auth"), dict) else {}
    if auth.get("signed_in") is not True:
        raise AssertionError("auth.login was not persisted")
    feed = state.get("feed") if isinstance(state.get("feed"), dict) else {}
    feed_items = feed.get("items") if isinstance(feed.get("items"), list) else []
    if not any(isinstance(item, dict) and item.get("workstream_id") == marker for item in feed_items):
        raise AssertionError("feed.push was not persisted")
    feedback = state.get("feedback") if isinstance(state.get("feedback"), dict) else {}
    submissions = feedback.get("submissions") if isinstance(feedback.get("submissions"), list) else []
    if not any(isinstance(item, dict) and item.get("body") == marker for item in submissions):
        raise AssertionError("feedback.submit was not persisted")
    session = state.get("session") if isinstance(state.get("session"), dict) else {}
    workspaces = session.get("workspaces") if isinstance(session.get("workspaces"), list) else []
    matched_workspace = next(
        (item for item in workspaces if isinstance(item, dict) and item.get("id") == workspace_id),
        None,
    )
    if matched_workspace is None:
        raise AssertionError("workspace session snapshot was not persisted")
    remote = matched_workspace.get("remote_configuration")
    if not isinstance(remote, dict) or remote.get("destination") != "state-smoke.example":
        raise AssertionError("remote workspace configuration was not persisted")
    if matched_workspace.get("is_pinned") is not True:
        raise AssertionError("workspace pinned state was not persisted")
    if matched_workspace.get("description") != description:
        raise AssertionError("workspace description was not persisted")
    if matched_workspace.get("color") != "#7D6608":
        raise AssertionError("workspace color was not persisted")
    return [
        "state.auth",
        "state.feed",
        "state.feedback",
        "state.session",
        "state.remote_workspace",
        "state.workspace_metadata",
    ]


def current_surface_id(socket_path: Path) -> str | None:
    current = expect_ok(socket_path, "surface.current")
    return current.get("surface_id") or current.get("id")


def current_pane_id(socket_path: Path) -> str | None:
    current = expect_ok(socket_path, "surface.current")
    return current.get("pane_id") or current.get("current_pane_id") or current.get("currentPaneId")


def current_workspace_id(socket_path: Path) -> str | None:
    current = expect_ok(socket_path, "workspace.current")
    return current.get("workspace_id") or current.get("id")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a Linux cmux socket smoke check against a running tagged app.")
    parser.add_argument("--socket", dest="socket_path", default=None, help="Unix socket path")
    parser.add_argument("--browser", action="store_true", help="Include WebKitGTK browser automation checks.")
    parser.add_argument("--state", action="store_true", help="Validate Linux runtime state persistence.")
    parser.add_argument(
        "--require-remote-daemon",
        action="store_true",
        help="Require system.capabilities.remoteDaemon to report an executable daemon.",
    )
    parser.add_argument(
        "--remote-ssh",
        action="store_true",
        help="Exercise remote SSH bootstrap, stdio probe, reverse-forward relay, and HMAC socket proxy.",
    )
    parser.add_argument("--json", action="store_true", help="Print JSON summary.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    socket_path = Path(args.socket_path) if args.socket_path else default_socket_path()
    try:
        checked = smoke_core(socket_path)
        if args.browser:
            checked = [*checked, *smoke_browser(socket_path)]
        if args.state:
            checked = [*checked, *smoke_state(socket_path)]
        remote_ssh_config = remote_ssh_smoke_config_from_env()
        if args.remote_ssh:
            if remote_ssh_config is None:
                raise AssertionError("--remote-ssh requires CMUX_REMOTE_SSH_DESTINATION or CMUX_REMOTE_SSH_SMOKE=1")
            checked = [*checked, *smoke_remote_ssh(socket_path, remote_ssh_config)]
        capabilities = expect_ok(socket_path, "system.capabilities")
        validate_capabilities_payload(capabilities)
        validate_remote_daemon_payload(capabilities.get("remoteDaemon"), args.require_remote_daemon)
        checked.append("system.capabilities.remoteDaemon")
        checked.append("system.capabilities.subsystems")
    except (AssertionError, OSError, json.JSONDecodeError) as error:
        print(f"cmux linux socket smoke failed: {error}", file=sys.stderr)
        return 1

    summary = {"socket": str(socket_path), "checked": checked, "count": len(checked)}
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(f"cmux linux socket smoke passed ({len(checked)} checks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
