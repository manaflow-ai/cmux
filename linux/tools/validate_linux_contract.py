#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT_DIR / "linux" / "lib"))

from cmux_linux.capabilities import (  # noqa: E402
    REQUIRED_FAILURE_CODES,
    build_subsystem_capabilities,
    packaging_formats,
    validate_subsystem_capabilities,
)
from cmux_linux.auth import (  # noqa: E402
    auth_bridge_candidates,
    build_auth_bridge_invocation,
    build_local_auth_status_payload,
    bundled_auth_bridge_path,
    find_auth_bridge_binary,
    normalize_auth_bridge_result,
)
from cmux_linux.browser import (  # noqa: E402
    BACKEND_LIMITED_BROWSER_METHODS,
    browser_backend_limit,
)
from cmux_linux.socket_security import bind_private_unix_socket  # noqa: E402
from cmux_linux.feedback import (  # noqa: E402
    build_feedback_upload_request,
    feedback_endpoint_url,
)
from cmux_linux.feed import (  # noqa: E402
    expire_feed_item,
    feed_decision_stdout,
    feed_event_from_params,
    feed_exit_plan_decision,
    feed_item_from_event,
    feed_permission_decision,
    feed_push_response,
    feed_question_decision,
    feed_reply_response,
    feed_status_for_kind,
    feed_timed_out_response,
    feed_wait_timeout,
    resolve_feed_item,
)
from cmux_linux.legacy_v1 import (  # noqa: E402
    format_legacy_v1_response,
    parse_legacy_v1_command,
)
from cmux_linux.remote import (  # noqa: E402
    active_terminal_sessions,
    build_remote_bootstrap_invocation,
    build_remote_bootstrap_script,
    build_remote_lifecycle_plan,
    build_relay_metadata,
    build_reverse_forward_argv,
    build_remote_stdio_probe_invocation,
    compute_relay_auth_mac,
    effective_ssh_options,
    relay_auth_file_payload,
    relay_auth_challenge,
    remote_foreground_auth_transition,
    remote_proxy_runtime_status,
    ssh_option_keys,
    validate_relay_id,
    validate_ssh_destination,
    verify_relay_auth_response,
)
from cmux_linux.terminal import (  # noqa: E402
    LINUX_TERMINAL_BACKEND,
    build_debug_terminal_item,
    linux_port_scanner_capability,
    linux_terminal_renderer_capability,
)
from cmux_linux.workspace import (  # noqa: E402
    MACOS_WORKSPACE_ACTIONS,
    normalize_workspace_action,
    normalize_workspace_color,
    normalize_workspace_description,
)
from package_manifest import build_manifest, validate_manifest  # noqa: E402
from validate_package import (  # noqa: E402
    remote_daemon_probe_error,
    resolve_root_path,
    select_flatpak_ref,
    swift_cli_validation_error,
)
from socket_smoke import remote_ssh_smoke_config_from_env  # noqa: E402


def main() -> int:
    remote_daemon = {
        "available": True,
        "state": "installed",
        "path": "/tmp/cmuxd-remote",
        "bundled": True,
        "detail": "remote_daemon_lifecycle_not_started_on_linux",
        "probe": {"hello": True, "ping": True},
        "capabilities": ["session.basic", "proxy.stream"],
    }
    capabilities = build_subsystem_capabilities(
        auth_bridge_available=False,
        auth_detail="auth_bridge_unconfigured",
        feedback_endpoint_configured=False,
        remote_daemon=remote_daemon,
        browser_available=True,
        browser_backend="webkit4.1",
        window_count=1,
        terminal_backend="vte",
    )
    errors = validate_subsystem_capabilities(capabilities)
    terminal_capability = capabilities.get("terminal") or {}
    if not isinstance(terminal_capability.get("renderer"), dict):
        errors.append("terminal capability must expose renderer metadata")
    if not isinstance(terminal_capability.get("scanner"), dict):
        errors.append("terminal capability must expose scanner metadata")
    packaging_capability = capabilities.get("packaging") or {}
    if packaging_capability.get("mode") != "artifact":
        errors.append("packaging capability must expose artifact mode")
    formats = packaging_formats()
    if formats.get("tarball", {}).get("available") is not True:
        errors.append("tarball packaging must be available")
    if formats.get("tarball", {}).get("manifest") != "share/cmux/package-manifest.json":
        errors.append("tarball packaging must expose package manifest path")
    deb = formats.get("deb", {})
    if deb.get("available") is not True or deb.get("mode") != "artifact":
        errors.append("deb packaging must be available as a validator-backed artifact")
    if deb.get("validator") != "linux/tools/validate_package.py":
        errors.append("deb packaging must use the package validator")
    expected_packaging_scripts = {
        "appimage": "linux/package-appimage.sh",
        "rpm": "linux/package-rpm.sh",
        "flatpak": "linux/package-flatpak.sh",
    }
    for name, script in expected_packaging_scripts.items():
        format_payload = formats.get(name, {})
        if format_payload.get("available") is not True or format_payload.get("mode") != "artifact":
            errors.append(f"{name} packaging must be available as a validator-backed artifact")
        if format_payload.get("backend") != script:
            errors.append(f"{name} packaging must use {script}")
        if format_payload.get("validator") != "linux/tools/validate_package.py":
            errors.append(f"{name} packaging must use the package validator")
    manifest_errors = validate_manifest(
        build_manifest(remote_daemon_included=True, swift_cli_included=True),
        require_remote_daemon=True,
        require_swift_cli=True,
    )
    if manifest_errors:
        errors.append("package manifest contract invalid: " + "; ".join(manifest_errors))
    packaging_capability = capabilities.get("packaging") or {}
    if packaging_capability.get("manifest") != "share/cmux/package-manifest.json":
        errors.append("packaging capability must expose package manifest path")
    if resolve_root_path(Path("/tmp/cmux-root"), Path("/usr/bin/cmux"), Path("usr")) != Path(
        "/tmp/cmux-root/usr/bin/cmux"
    ):
        errors.append("package validator must resolve /usr install roots")
    if resolve_root_path(Path("/tmp/cmux-flatpak"), Path("/usr/bin/cmux"), Path("")) != Path(
        "/tmp/cmux-flatpak/bin/cmux"
    ):
        errors.append("package validator must resolve Flatpak /app file roots")
    with tempfile.TemporaryDirectory(prefix="cmux-socket-contract-") as temp:
        socket_path = Path(temp) / "cmux.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            bind_private_unix_socket(server, socket_path)
            socket_mode = socket_path.stat().st_mode & 0o777
            if socket_mode != 0o600:
                errors.append(f"Linux socket file mode must be 0600, got {socket_mode:o}")
    if (
        swift_cli_validation_error(b"#!/usr/bin/env python3\nprint('fallback')\n", "bin/cmux")
        != "bin/cmux must be the Swift CLI binary with auth-bridge support, not the fallback script"
    ):
        errors.append("package validator must reject fallback script cmux when Swift CLI is required")
    if swift_cli_validation_error(b"not a binary\n", "bin/cmux") != (
        "bin/cmux must be an ELF Swift CLI binary with auth-bridge support"
    ):
        errors.append("package validator must reject non-ELF cmux when Swift CLI is required")
    if swift_cli_validation_error(b"\x7fELFcmux-auth-bridge", "bin/cmux") is not None:
        errors.append("package validator must accept ELF Swift CLI payloads")
    with tempfile.TemporaryDirectory(prefix="cmux-remote-daemon-probe-contract-") as temp:
        probe_script = Path(temp) / "cmuxd-remote"
        probe_script.write_text(
            """#!/usr/bin/env python3
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    if request.get("method") == "hello":
        print(json.dumps({"id": request.get("id"), "ok": True, "result": {"capabilities": ["proxy.stream.push"]}}))
    elif request.get("method") == "ping":
        print(json.dumps({"id": request.get("id"), "ok": True, "result": {"pong": True}}))
""",
            encoding="utf-8",
        )
        probe_script.chmod(0o755)
        if remote_daemon_probe_error(probe_script) is not None:
            errors.append("package validator must accept packaged remote daemon hello/ping probe")
        broken_probe_script = Path(temp) / "cmuxd-remote-broken"
        broken_probe_script.write_text(
            """#!/usr/bin/env python3
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps({"id": request.get("id"), "ok": False, "error": {"code": "broken"}}))
""",
            encoding="utf-8",
        )
        broken_probe_script.chmod(0o755)
        if remote_daemon_probe_error(broken_probe_script) is None:
            errors.append("package validator must reject broken remote daemon probe responses")
    flatpak_refs = "\n".join(
        [
            "runtime/org.gnome.Platform/x86_64/46",
            "app/org.example.Other/x86_64/stable",
            "app/com.cmuxterm.cmux/x86_64/stable",
        ]
    )
    if select_flatpak_ref(flatpak_refs) != "app/com.cmuxterm.cmux/x86_64/stable":
        errors.append("Flatpak validator must prefer the cmux app ref")
    try:
        select_flatpak_ref("runtime/org.gnome.Platform/x86_64/46\n")
        errors.append("Flatpak validator must reject bundles without an app ref")
    except SystemExit:
        pass
    windows_capability = capabilities.get("windows") or {}
    if windows_capability.get("last_window_policy") != "quit_app":
        errors.append("windows capability must expose last window quit policy")
    for action in (
        "pin",
        "unpin",
        "set_description",
        "clear_description",
        "set_color",
        "clear_color",
        "move_top",
        "close_others",
        "close_above",
        "close_below",
        "mark_read",
        "mark_unread",
    ):
        if action not in MACOS_WORKSPACE_ACTIONS:
            errors.append(f"Linux workspace action contract missing macOS action: {action}")
    if normalize_workspace_action("set-description") != "set_description":
        errors.append("workspace action normalization must accept hyphenated CLI names")
    if normalize_workspace_description("  first\r\nsecond  ") != "first\nsecond":
        errors.append("workspace descriptions must trim and normalize line endings")
    if normalize_workspace_description(" \n\t ") is not None:
        errors.append("blank workspace descriptions must normalize to None")
    if normalize_workspace_color("amber") is None:
        errors.append("workspace color normalization must accept named palette colors")
    if normalize_workspace_color("c0392b") != "#C0392B":
        errors.append("workspace color normalization must accept bare hex colors")
    if normalize_workspace_color("not-a-color") is not None:
        errors.append("workspace color normalization must reject invalid colors")
    for code in ("invalid_params", "not_supported", "backend_unavailable", "transport_error"):
        if code not in REQUIRED_FAILURE_CODES:
            errors.append(f"missing failure code: {code}")
    auth_invocation = build_auth_bridge_invocation(
        "/opt/cmux/bin/cmux",
        "auth.login",
        {"email": "user@example.com", "password": "secret-password"},
    )
    auth_command = auth_invocation["command"]
    auth_stdin = auth_invocation["stdin"]
    if auth_command != ["/opt/cmux/bin/cmux", "auth-bridge"]:
        errors.append("cmux auth bridge invocation must use the auth-bridge subcommand")
    if any("secret-password" in part for part in auth_command):
        errors.append("auth bridge invocation must not pass secrets through argv")
    if b"secret-password" not in auth_stdin:
        errors.append("auth bridge invocation must pass params through stdin JSON")
    normalized_auth = normalize_auth_bridge_result(
        {
            "result": {
                "authenticated": True,
                "signed_in": True,
                "user": {"id": "user_1", "primaryEmail": "user@example.com"},
                "teams": [{"id": "team_1", "name": "Team"}],
                "selected_team_id": "team_1",
            }
        }
    )
    if normalized_auth.get("backend") != "cmux_auth_core_bridge" or normalized_auth.get("mode") != "bridge":
        errors.append("auth bridge result must expose cmux_auth_core_bridge bridge mode")
    if normalized_auth.get("user", {}).get("id") != "user_1":
        errors.append("auth bridge result must preserve user payload")
    for field in ("required", "is_restoring_session", "is_loading", "timed_out", "teams", "selected_team_id"):
        if field not in normalized_auth:
            errors.append(f"auth bridge result missing shared status field: {field}")
    local_auth = build_local_auth_status_payload(
        signed_in=False,
        signed_in_at=None,
        timed_out=False,
        detail="auth_bridge_unconfigured",
    )
    if local_auth.get("backend") != "linux_local_state" or local_auth.get("mode") != "local_fallback":
        errors.append("local auth status must expose linux_local_state local_fallback mode")
    if local_auth.get("user") is not None or local_auth.get("teams") != []:
        errors.append("local auth fallback must expose empty user/team state")
    feed_event = feed_event_from_params(
        {
            "event": {
                "session_id": "feed-session",
                "hook_event_name": "PermissionRequest",
                "_source": "cmux-contract",
                "_opencode_request_id": "feed-request",
                "cwd": "/tmp/cmux-feed",
                "tool_name": "Bash",
            },
            "wait_timeout_seconds": 120,
        }
    )
    if feed_wait_timeout({"wait_timeout_seconds": 120}) != 120:
        errors.append("feed.push must accept a 120 second soft wait timeout")
    feed_item = feed_item_from_event(feed_event, now=1_700_000_000, item_id="feed-item")
    if feed_item.get("kind") != "permissionRequest":
        errors.append("PermissionRequest must map to WorkstreamKind.permissionRequest")
    if feed_item.get("status") != "pending":
        errors.append("actionable feed items must start pending")
    if feed_item.get("created_at") != "2023-11-14T22:13:20Z":
        errors.append("feed items must expose macOS-style ISO8601 timestamps")
    if feed_item.get("request_id") != "feed-request":
        errors.append("feed items must preserve request_id correlation")
    if feed_item.get("title") != "Bash":
        errors.append("feed items must use tool_name as the fallback title")
    telemetry = feed_item_from_event(
        {
            "session_id": "feed-session",
            "hook_event_name": "PreToolUse",
            "_source": "cmux-contract",
        },
        now=1_700_000_000,
        item_id="feed-telemetry",
    )
    if telemetry.get("kind") != "toolUse" or telemetry.get("status") != "telemetry":
        errors.append("PreToolUse must map to WorkstreamKind.toolUse telemetry")
    if feed_status_for_kind("exitPlan") != "pending":
        errors.append("exitPlan feed kind must be actionable")
    permission_decision = feed_permission_decision("once")
    if permission_decision != {"kind": "permission", "mode": "once"}:
        errors.append("permission reply decision shape must match macOS")
    question_decision = feed_question_decision(["yes"])
    if question_decision != {"kind": "question", "selections": ["yes"]}:
        errors.append("question reply decision shape must match macOS")
    exit_decision = feed_exit_plan_decision("manual", "needs tests")
    if exit_decision != {"kind": "exit_plan", "mode": "manual", "feedback": "needs tests"}:
        errors.append("exit plan reply decision shape must include non-empty feedback")
    stdout = feed_decision_stdout(exit_decision)
    if json.loads(stdout).get("decision") != exit_decision:
        errors.append("feed stdout decision JSON must round-trip the decision")
    reply = feed_reply_response(exit_decision)
    if reply.get("delivered") is not True or reply.get("stdout_decision_json") != stdout:
        errors.append("feed reply response must expose delivered and stdout decision JSON")
    resolved_item = resolve_feed_item(feed_item, permission_decision, resolved_at=1_700_000_030)
    if resolved_item.get("status") != "resolved" or resolved_item.get("resolved_at") != "2023-11-14T22:13:50Z":
        errors.append("resolved feed item must expose resolved status and ISO8601 resolved_at")
    resolved_push = feed_push_response(resolved_item, wait_timeout_seconds=0, decision=permission_decision)
    if resolved_push.get("status") != "resolved" or resolved_push.get("stdout_decision_json") is None:
        errors.append("feed.push resolved response must include decision stdout JSON")
    expired_item = expire_feed_item(feed_item, expired_at=1_700_000_060)
    if expired_item.get("status") != "expired" or expired_item.get("resolved_at") != "2023-11-14T22:14:20Z":
        errors.append("timed out feed items must expose expired status and ISO8601 resolved_at")
    timed_out_push = feed_timed_out_response("feed-item")
    if timed_out_push != {"status": "timed_out", "item_id": "feed-item"}:
        errors.append("feed.push timed out response must expose stable item_id")
    ping_command = parse_legacy_v1_command("ping")
    if ping_command != ("system.ping", {}):
        errors.append("legacy v1 ping must map to system.ping")
    focus_command = parse_legacy_v1_command("focus_window window:linux-window-1")
    if focus_command != ("window.focus", {"window_ref": "window:linux-window-1"}):
        errors.append("legacy v1 focus_window must preserve window refs")
    close_command = parse_legacy_v1_command("close_window linux-window-1")
    if close_command != ("window.close", {"window_id": "linux-window-1"}):
        errors.append("legacy v1 close_window must preserve raw window ids")
    if parse_legacy_v1_command("unsupported_command") is not None:
        errors.append("legacy v1 parser must reject unsupported commands")
    current_text = format_legacy_v1_response(
        "current_window",
        True,
        {"window_id": "linux-window-1", "window_ref": "window:linux-window-1"},
    )
    if current_text != "linux-window-1":
        errors.append("legacy v1 current_window must return the raw window id")
    list_text = format_legacy_v1_response(
        "list_windows",
        True,
        {
            "windows": [
                {
                    "index": 0,
                    "window_id": "linux-window-1",
                    "is_current": True,
                    "selected_workspace_id": "workspace-1",
                    "workspace_count": 2,
                }
            ]
        },
    )
    if list_text != "* 0: linux-window-1 selected_workspace=workspace-1 workspaces=2":
        errors.append("legacy v1 list_windows must match macOS CLI text shape")
    error_text = format_legacy_v1_response(
        "focus_window",
        False,
        {"code": "invalid_params", "message": "Window not found."},
    )
    if not error_text.startswith("ERROR: "):
        errors.append("legacy v1 errors must preserve the Swift CLI ERROR contract")
    previous_linux_auth_bridge = os.environ.pop("CMUX_LINUX_AUTH_BRIDGE", None)
    previous_auth_bridge = os.environ.pop("CMUX_AUTH_BRIDGE", None)
    try:
        if bundled_auth_bridge_path() not in auth_bridge_candidates():
            errors.append("bundled cmux CLI must be an auth bridge candidate")
        if find_auth_bridge_binary() == bundled_auth_bridge_path():
            errors.append("fallback Python cmux wrapper must not be selected as an auth bridge")
        with tempfile.TemporaryDirectory() as temp_dir:
            bridge_path = Path(temp_dir) / "bridge"
            bridge_path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            bridge_path.chmod(0o755)
            os.environ["CMUX_LINUX_AUTH_BRIDGE"] = str(bridge_path)
            if find_auth_bridge_binary() != bridge_path.resolve():
                errors.append("explicit auth bridge path must be accepted")
    finally:
        if previous_linux_auth_bridge is not None:
            os.environ["CMUX_LINUX_AUTH_BRIDGE"] = previous_linux_auth_bridge
        else:
            os.environ.pop("CMUX_LINUX_AUTH_BRIDGE", None)
        if previous_auth_bridge is not None:
            os.environ["CMUX_AUTH_BRIDGE"] = previous_auth_bridge
        else:
            os.environ.pop("CMUX_AUTH_BRIDGE", None)
    endpoint = feedback_endpoint_url({"CMUX_FEEDBACK_API_URL": "https://feedback.example/upload"})
    if endpoint != "https://feedback.example/upload":
        errors.append("Linux feedback must honor the macOS CMUX_FEEDBACK_API_URL endpoint override")
    invalid_endpoint = feedback_endpoint_url({"CMUX_FEEDBACK_API_URL": "file:///tmp/feedback"})
    if invalid_endpoint is not None:
        errors.append("Linux feedback must reject non-HTTP upload endpoints")
    request = build_feedback_upload_request(
        "https://feedback.example/upload",
        {
            "id": "feedback-ci",
            "email": "user@example.com",
            "body": "Linux feedback",
            "submitted_at": 1_700_000_000,
            "platform": "linux",
        },
        [],
        boundary="cmux-contract-boundary",
    )
    content_type = request.get_header("Content-type") or request.get_header("Content-Type")
    request_body = request.data.decode("utf-8") if isinstance(request.data, bytes) else ""
    if content_type != "multipart/form-data; boundary=cmux-contract-boundary":
        errors.append("Linux feedback upload must use multipart/form-data")
    for field in ("email", "message", "platform", "submissionId"):
        if f'name="{field}"' not in request_body:
            errors.append(f"Linux feedback upload multipart body missing field: {field}")
    if "application/json" in content_type or request_body.strip().startswith("{"):
        errors.append("Linux feedback upload must not use the old JSON-only transport")
    with tempfile.TemporaryDirectory(prefix="cmux-feedback-contract-") as temp:
        injected_file = Path(temp) / "shot\r\nX-Cmux-Injected: yes.png"
        injected_file.write_bytes(b"png")
        injected_request = build_feedback_upload_request(
            "https://feedback.example/upload",
            {"id": "feedback-ci", "body": "Linux feedback"},
            [str(injected_file)],
            boundary="cmux-boundary",
        )
        injected_body = (injected_request.data or b"").decode("utf-8")
        if "\r\nX-Cmux-Injected:" in injected_body:
            errors.append("Linux feedback upload must strip CRLF from multipart filenames")
        if 'filename="shot__X-Cmux-Injected: yes.png"' not in injected_body:
            errors.append("Linux feedback upload must preserve sanitized attachment filenames")
    for method in (
        "browser.trace.start",
        "browser.network.route",
        "browser.screencast.start",
        "browser.input_mouse",
        "browser.input_keyboard",
        "browser.input_touch",
    ):
        if method not in BACKEND_LIMITED_BROWSER_METHODS:
            errors.append(f"missing backend-limited browser method: {method}")
        limit = browser_backend_limit(method)
        if limit.get("code") != "backend_limit":
            errors.append(f"{method} must expose backend_limit code")
        if limit.get("method") != method:
            errors.append(f"{method} backend limit must preserve method name")
        if limit.get("backend") != "webkitgtk":
            errors.append(f"{method} backend limit must identify WebKitGTK")
        if not limit.get("reason"):
            errors.append(f"{method} backend limit must include reason")
    for invalid_relay_id in ("", "relay\nid", "relay\rid", "relay id", "../relay", "relay=id"):
        try:
            validate_relay_id(invalid_relay_id)
            errors.append(f"relay_id validator must reject {invalid_relay_id!r}")
        except ValueError:
            pass
    for valid_relay_id in ("relay-ci", "relay_1.2:3"):
        try:
            validate_relay_id(valid_relay_id)
        except ValueError as error:
            errors.append(f"relay_id validator must accept {valid_relay_id!r}: {error}")
    relay = build_relay_metadata(
        relay_port=43210,
        relay_id="relay-ci",
        relay_token="a" * 64,
        daemon_path="/home/user/.cmux/bin/cmuxd-remote-current",
    )
    if relay.get("socket_addr") != "127.0.0.1:43210":
        errors.append("relay metadata must publish loopback socket address")
    if relay.get("remote_socket_addr_path") != "~/.cmux/socket_addr":
        errors.append("relay metadata must publish ~/.cmux/socket_addr")
    if relay.get("relay_auth_path") != "~/.cmux/relay/43210.auth":
        errors.append("relay metadata must publish per-port auth path")
    if relay.get("relay_daemon_path_path") != "~/.cmux/relay/43210.daemon_path":
        errors.append("relay metadata must publish per-port daemon path file")
    if relay.get("auth_file_mode") != "0600":
        errors.append("relay auth file mode must be 0600")
    if relay.get("hmac", {}).get("algorithm") != "HMAC-SHA256":
        errors.append("relay metadata must declare HMAC-SHA256")
    if "relay_token" in json.dumps(relay):
        errors.append("public relay metadata must not expose relay_token")
    auth_payload = relay_auth_file_payload(relay_id="relay-ci", relay_token="a" * 64)
    if auth_payload.get("relay_token") != "a" * 64:
        errors.append("auth file payload must contain the relay token for the remote side")
    auth_challenge = relay_auth_challenge(relay_id="relay-ci", nonce="nonce-ci")
    if auth_challenge.get("protocol") != "cmux-relay-auth" or auth_challenge.get("version") != 1:
        errors.append("relay auth challenge must match cmuxd-remote CLI protocol")
    mac = compute_relay_auth_mac(
        relay_id="relay-ci",
        relay_token="a" * 64,
        nonce="nonce-ci",
    )
    if not verify_relay_auth_response(
        relay_id="relay-ci",
        relay_token="a" * 64,
        nonce="nonce-ci",
        response={"relay_id": "relay-ci", "mac": mac},
    ):
        errors.append("relay auth verifier must accept the Go CLI HMAC response")
    if verify_relay_auth_response(
        relay_id="relay-ci",
        relay_token="a" * 64,
        nonce="nonce-ci",
        response={"relay_id": "relay-ci", "mac": "00" * 32},
    ):
        errors.append("relay auth verifier must reject invalid HMAC responses")
    bootstrap_script = build_remote_bootstrap_script(
        relay=relay,
        relay_token="a" * 64,
        daemon_path="/home/user/.cmux/bin/cmuxd-remote-current",
    )
    if "127.0.0.1:43210" not in bootstrap_script:
        errors.append("remote bootstrap script must write the relay socket address")
    if "relay-ci" not in bootstrap_script or "a" * 64 not in bootstrap_script:
        errors.append("remote bootstrap script must write the relay auth payload")
    if "chmod 0600" not in bootstrap_script:
        errors.append("remote bootstrap script must protect relay auth file permissions")
    bootstrap_invocation = build_remote_bootstrap_invocation(
        destination="user@example.com",
        port=2222,
        identity_file="/home/user/.ssh/id_ed25519",
        ssh_options=["-o", "StrictHostKeyChecking=no"],
        relay=relay,
        relay_token="a" * 64,
        daemon_path="/home/user/.cmux/bin/cmuxd-remote-current",
    )
    if "a" * 64 in json.dumps(bootstrap_invocation["command"]):
        errors.append("remote bootstrap invocation must not pass relay token through argv")
    if b"a" * 64 not in bootstrap_invocation["stdin"]:
        errors.append("remote bootstrap invocation must pass relay token through stdin script")
    stdio_probe = build_remote_stdio_probe_invocation(
        destination="user@example.com",
        port=2222,
        identity_file="/home/user/.ssh/id_ed25519",
        ssh_options=["-o", "StrictHostKeyChecking=no"],
        daemon_path="/home/user/.cmux/bin/cmuxd-remote-current",
    )
    if "serve --stdio" not in " ".join(stdio_probe["command"]):
        errors.append("remote stdio probe invocation must call cmuxd-remote serve --stdio")
    if b'"method":"hello"' not in stdio_probe["stdin"] or b'"method":"ping"' not in stdio_probe["stdin"]:
        errors.append("remote stdio probe invocation must send hello and ping requests")
    effective_options = effective_ssh_options(["-o", "StrictHostKeyChecking=no"])
    effective_keys = ssh_option_keys(effective_options)
    if effective_keys.count("StrictHostKeyChecking") != 1:
        errors.append("user SSH StrictHostKeyChecking option must prevent default injection")
    if "BatchMode" not in effective_keys or "ExitOnForwardFailure" not in effective_keys:
        errors.append("remote lifecycle SSH options must inject required safe defaults")
    reverse_forward = build_reverse_forward_argv(
        destination="user@example.com",
        port=2222,
        identity_file="/home/user/.ssh/id_ed25519",
        ssh_options=effective_options,
        relay_port=43210,
        local_proxy_port=32123,
    )
    if reverse_forward[-1] != "user@example.com" or "-R" not in reverse_forward:
        errors.append("reverse-forward SSH argv must keep destination last and include -R")
    if "127.0.0.1:43210:127.0.0.1:32123" not in reverse_forward:
        errors.append("reverse-forward SSH argv must publish relay_port to local_proxy_port")
    remote_ssh_smoke_config = remote_ssh_smoke_config_from_env(
        {
            "CMUX_REMOTE_SSH_DESTINATION": "runner@127.0.0.1",
            "CMUX_REMOTE_SSH_PORT": "2222",
            "CMUX_REMOTE_SSH_IDENTITY_FILE": "/tmp/cmux_ci_key",
            "CMUX_REMOTE_SSH_OPTIONS": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/cmux-known-hosts",
            "CMUX_REMOTE_SSH_RELAY_TOKEN": "c" * 64,
        },
        allocate_port=iter([32123, 43210]).__next__,
    )
    if remote_ssh_smoke_config is None:
        errors.append("remote SSH smoke config must be enabled when destination is provided")
    elif remote_ssh_smoke_config.get("params") != {
        "destination": "runner@127.0.0.1",
        "port": 2222,
        "identity_file": "/tmp/cmux_ci_key",
        "ssh_options": ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/tmp/cmux-known-hosts"],
        "local_proxy_port": 32123,
        "relay_port": 43210,
        "relay_id": "cmux-ci-relay",
        "relay_token": "c" * 64,
        "auto_connect": True,
    }:
        errors.append("remote SSH smoke config must produce auto-connect configure params with distinct relay ports")
    runtime_status = remote_proxy_runtime_status(
        relay_configured=True,
        process_pid=1234,
        process_returncode=None,
        workspace_state="connecting",
        heartbeat={"count": 2, "last_seen_at": 10.0},
        now=15.5,
    )
    if runtime_status.get("connected") is not True:
        errors.append("remote runtime status must mark a running proxy process connected")
    if runtime_status.get("daemon", {}).get("state") != "running":
        errors.append("remote runtime status must mark a running proxy process as daemon running")
    if runtime_status.get("proxy", {}).get("state") != "running":
        errors.append("remote runtime status must mark a running proxy process as proxy running")
    if runtime_status.get("heartbeat", {}).get("age_seconds") != 5.5:
        errors.append("remote runtime status must expose heartbeat age")
    lifecycle = build_remote_lifecycle_plan(
        destination="user@example.com",
        port=2222,
        identity_file="/home/user/.ssh/id_ed25519",
        ssh_options=["-o", "StrictHostKeyChecking=no"],
        local_proxy_port=32123,
        relay=relay,
        daemon_path="/home/user/.cmux/bin/cmuxd-remote-current",
        auto_connect=True,
    )
    lifecycle_json = json.dumps(lifecycle)
    if lifecycle.get("mode") != "auto" or lifecycle.get("state") != "planned":
        errors.append("remote lifecycle plan must expose auto/planned states")
    if lifecycle.get("daemon", {}).get("probe_methods") != ["hello", "ping"]:
        errors.append("remote lifecycle plan must probe daemon hello and ping")
    if lifecycle.get("proxy", {}).get("state") != "planned":
        errors.append("remote lifecycle plan must include a planned reverse-forward proxy")
    if "<identity_file>" not in lifecycle.get("ssh", {}).get("argv", []):
        errors.append("remote lifecycle plan must redact identity file paths in public argv")
    if "a" * 64 in lifecycle_json:
        errors.append("remote lifecycle plan must not expose relay token values")
    bootstrap_writes = lifecycle.get("bootstrap", {}).get("writes")
    if not isinstance(bootstrap_writes, list):
        errors.append("remote lifecycle plan must expose bootstrap writes")
    elif not any(item.get("path") == "~/.cmux/relay/43210.auth" and item.get("mode") == "0600" for item in bootstrap_writes):
        errors.append("remote lifecycle plan must include relay auth file with 0600 mode")
    auth_transition = remote_foreground_auth_transition(
        configuration={"auto_connect": True, "lifecycle": lifecycle},
        has_token=True,
        ready_at=42.0,
        proxy_running=False,
    )
    next_configuration = auth_transition.get("configuration")
    if auth_transition.get("should_connect") is not True:
        errors.append("foreground auth transition must request auto-connect when auth becomes ready")
    if not isinstance(next_configuration, dict):
        errors.append("foreground auth transition must return an updated configuration")
    elif next_configuration.get("lifecycle", {}).get("state") != "foreground_auth_ready":
        errors.append("foreground auth transition must mark lifecycle foreground_auth_ready")
    if next_configuration and next_configuration.get("has_foreground_auth_token") is not True:
        errors.append("foreground auth transition must preserve token presence without exposing token values")
    sessions = active_terminal_sessions(
        [
            {
                "id": "surface-1",
                "panes": [
                    {"id": "pane-1", "kind": "terminal", "title": "shell"},
                    {"id": "pane-2", "kind": "browser", "title": "browser"},
                ],
            },
            {
                "id": "surface-2",
                "panes": [
                    {"id": "pane-3", "kind": "terminal", "title": "ended-shell"},
                ],
            },
        ],
        [{"surface_id": "surface-2", "relay_port": 43210}],
    )
    if sessions.get("count") != 1:
        errors.append("active terminal session count must reflect terminal panes minus ended surfaces")
    details = sessions.get("sessions") if isinstance(sessions.get("sessions"), list) else []
    if not details or details[0].get("surface_id") != "surface-1" or details[0].get("pane_id") != "pane-1":
        errors.append("active terminal session details must include the active terminal pane")
    pane_scoped_sessions = active_terminal_sessions(
        [
            {
                "id": "surface-3",
                "panes": [
                    {"id": "pane-4", "kind": "terminal", "title": "left"},
                    {"id": "pane-5", "kind": "terminal", "title": "right"},
                ],
            }
        ],
        [{"surface_id": "surface-3", "pane_id": "pane-4", "relay_port": 43210}],
    )
    pane_scoped_details = (
        pane_scoped_sessions.get("sessions") if isinstance(pane_scoped_sessions.get("sessions"), list) else []
    )
    if pane_scoped_sessions.get("count") != 1 or pane_scoped_details[0].get("pane_id") != "pane-5":
        errors.append("active terminal sessions must treat pane_id-scoped end events without ending the whole surface")
    renderer = linux_terminal_renderer_capability()
    if renderer.get("backend") != LINUX_TERMINAL_BACKEND:
        errors.append("Linux terminal renderer must identify the VTE backend")
    if renderer.get("ghostty", {}).get("available") is not False:
        errors.append("Linux terminal renderer must mark Ghostty renderer unavailable")
    if renderer.get("ghostty", {}).get("reason") != "unsupported_on_linux_backend":
        errors.append("Linux terminal renderer must expose unsupported_on_linux_backend reason")
    scanner = linux_port_scanner_capability()
    if scanner.get("backend") != LINUX_TERMINAL_BACKEND:
        errors.append("Linux port scanner must identify the VTE backend")
    if scanner.get("available") is not False:
        errors.append("Linux port scanner must be unavailable until native scanner support exists")
    if scanner.get("reason") != "unsupported_on_linux_backend":
        errors.append("Linux port scanner must expose unsupported_on_linux_backend reason")
    if scanner.get("detected_ports") != [] or scanner.get("forwarded_ports") != [] or scanner.get("conflicted_ports") != []:
        errors.append("Linux port scanner capability must expose empty port arrays")
    terminal = build_debug_terminal_item(
        window_id="window-1",
        window_ref="window:window-1",
        workspace_id="workspace-1",
        workspace_ref="workspace:workspace-1",
        workspace_index=0,
        workspace_title="Workspace",
        surface_id="surface-1",
        surface_ref="surface:surface-1",
        surface_index=0,
        surface_title="shell",
        pane_id="pane-1",
        pane_ref="pane:pane-1",
        pane_index=0,
        pane_title="shell",
        current_directory="/home/user/project",
        focused=True,
        tty_name="/dev/pts/1",
        pty_available=True,
    )
    for field in (
        "index",
        "window_id",
        "window_ref",
        "workspace_id",
        "workspace_ref",
        "workspace_index",
        "workspace_selected",
        "surface_id",
        "surface_ref",
        "surface_index",
        "surface_index_in_pane",
        "surface_title",
        "surface_focused",
        "surface_selected_in_pane",
        "pane_id",
        "pane_ref",
        "pane_index",
        "window_visible",
        "window_key",
        "window_main",
        "window_occluded",
        "window_title",
        "window_class",
        "hosted_view_class",
        "hosted_view_visible_in_ui",
        "ghostty_surface_ptr",
        "terminal_object_ptr",
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
    ):
        if field not in terminal:
            errors.append(f"Linux debug terminal item missing field: {field}")
    if terminal.get("tty") != "/dev/pts/1" or terminal.get("tty_name") != "/dev/pts/1":
        errors.append("Linux debug terminal item must expose tty and tty_name")
    if terminal.get("current_directory") != "/home/user/project" or terminal.get("cwd") != "/home/user/project":
        errors.append("Linux debug terminal item must expose current_directory and cwd")
    if terminal.get("listening_ports") != []:
        errors.append("Linux debug terminal item must expose an empty listening_ports list")
    if terminal.get("detected_ports") != [] or terminal.get("forwarded_ports") != [] or terminal.get("conflicted_ports") != []:
        errors.append("Linux debug terminal item must expose empty port scanner arrays")
    if terminal.get("scanner", {}).get("reason") != "unsupported_on_linux_backend":
        errors.append("Linux debug terminal item must expose the Linux scanner limitation")
    for bad_destination in ("-oProxyCommand=bad", "host;rm -rf /", "host name", "host`cmd`"):
        try:
            validate_ssh_destination(bad_destination)
        except ValueError:
            continue
        errors.append(f"invalid SSH destination was accepted: {bad_destination}")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(json.dumps({"subsystems": sorted(capabilities), "failureCodes": list(REQUIRED_FAILURE_CODES)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
