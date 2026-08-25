#!/usr/bin/env python3
"""Behavior checks for Simulator CLI normalization and request routing."""

from __future__ import annotations

import json
import os
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Any

from claude_teams_test_utils import resolve_cmux_cli


class RecordingState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._requests: list[dict[str, Any]] = []

    def record(self, request: dict[str, Any]) -> None:
        with self._lock:
            self._requests.append(request)

    def count(self) -> int:
        with self._lock:
            return len(self._requests)

    def requests_since(self, index: int) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._requests[index:])


class FakeCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(line.decode("utf-8"))
            self.server.state.record(request)  # type: ignore[attr-defined]
            method = request.get("method")
            params = request.get("params") or {}
            result: dict[str, Any]
            if method == "simulator.permissions.read":
                result = {"permissions": {}}
            elif method in {"simulator.ui.status", "simulator.ui.set"}:
                result = {
                    "settings": {
                        "show-borders": "on",
                        str(params.get("option") or "appearance"): str(
                            params.get("value") or "light"
                        ),
                    }
                }
            elif method == "simulator.accessibility":
                result = {"roots": [], "truncated": False}
            elif method == "simulator.foreground":
                result = {
                    "application": {
                        "name": "Settings",
                        "bundle_id": "com.apple.Preferences",
                        "pid": 42,
                        "executable": "/Applications/Settings",
                        "bundle_path": "/Applications/Settings.app",
                    }
                }
            elif method in {"simulator.context", "simulator.prepare_screenshot"}:
                result = {
                    "simulator_id": "SIMULATOR-1",
                    "device_name": "iPhone Fixture",
                }
            else:
                result = {}
            response = {"ok": True, "result": result, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class FakeCmuxUnixServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, socket_path: str, state: RecordingState) -> None:
        self.state = state
        super().__init__(socket_path, FakeCmuxHandler)


def run_cli(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    arguments: list[str],
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    for key in [
        "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID",
        "CMUX_SOCKET_CAPABILITY", "CMUX_SOCKET_PASSWORD",
    ]:
        env.pop(key, None)
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_SOCKET"] = str(socket_path)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    env["HOME"] = str(fake_home)
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), "simulator", *arguments],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=10,
    )


def run_ios_cli(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    arguments: list[str],
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    for key in [
        "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID",
        "CMUX_SOCKET_CAPABILITY", "CMUX_SOCKET_PASSWORD",
    ]:
        env.pop(key, None)
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_SOCKET"] = str(socket_path)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    env["HOME"] = str(fake_home)
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), "ios", *arguments],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=10,
    )


def assert_request(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: RecordingState,
    arguments: list[str],
    method: str,
    expected_params: dict[str, Any],
) -> subprocess.CompletedProcess[str]:
    start = state.count()
    proc = run_cli(cli_path, socket_path, fake_home, arguments)
    if proc.returncode != 0:
        raise AssertionError(
            f"simulator {' '.join(arguments)} failed\n"
            f"stdout={proc.stdout!r}\nstderr={proc.stderr!r}"
        )
    requests = state.requests_since(start)
    if len(requests) != 1:
        raise AssertionError(
            f"simulator {' '.join(arguments)} sent {len(requests)} requests: {requests!r}"
        )
    request = requests[0]
    if request.get("method") != method:
        raise AssertionError(
            f"simulator {' '.join(arguments)} used {request.get('method')!r}, expected {method!r}"
        )
    params = request.get("params") or {}
    for key, expected in expected_params.items():
        if params.get(key) != expected:
            raise AssertionError(
                f"simulator {' '.join(arguments)} param {key!r} was "
                f"{params.get(key)!r}, expected {expected!r}"
            )
    return proc


def assert_invalid(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: RecordingState,
    arguments: list[str],
) -> None:
    start = state.count()
    proc = run_cli(cli_path, socket_path, fake_home, arguments)
    if proc.returncode == 0:
        raise AssertionError(f"simulator {' '.join(arguments)} unexpectedly succeeded")
    requests = state.requests_since(start)
    if requests:
        raise AssertionError(
            f"invalid simulator command sent socket requests: {requests!r}"
        )


def check_basic_actions(
    cli_path: str, socket_path: Path, fake_home: Path, state: RecordingState
) -> None:
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["button", "Home"], "simulator.button", {"button": "home"},
    )
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["button", "SideButton"], "simulator.button", {"button": "sideButton"},
    )
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["rotate", "Landscape-Left"], "simulator.rotate",
        {"orientation": "Landscape_Left"},
    )
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["ca", "Blended", "on"], "simulator.core_animation",
        {"diagnostic": "blended", "enabled": True},
    )


def check_permissions(
    cli_path: str, socket_path: Path, fake_home: Path, state: RecordingState
) -> None:
    bundle_id = "com.example.App"
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["permissions", "grant", "photo", bundle_id, "--value=limited",
         "--surface", "surface:2"],
        "simulator.permissions.set",
        {
            "action": "grant", "service": "photos-limited",
            "bundle_id": bundle_id, "surface_id": "surface:2",
        },
    )
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["permissions", "grant", "location", bundle_id, "never"],
        "simulator.permissions.set",
        {"action": "revoke", "service": "location", "bundle_id": bundle_id},
    )
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["permissions", "reset", "all", bundle_id],
        "simulator.permissions.set",
        {"action": "reset", "service": "all", "bundle_id": bundle_id},
    )
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["permissions", "list", bundle_id],
        "simulator.permissions.read", {"bundle_id": bundle_id},
    )

    catalog = [
        ("calendar", "calendar"), ("contacts-limited", "contacts-limited"),
        ("contacts", "contacts"), ("location", "location"),
        ("photos-add", "photos-add"), ("photos", "photos"),
        ("photos-limited", "photos-limited"), ("media-library", "media-library"),
        ("microphone", "microphone"), ("motion", "motion"),
        ("reminders", "reminders"), ("siri", "siri"), ("camera", "camera"),
        ("notifications", "notifications"),
        ("notifications-critical", "notifications-critical"),
        ("speech", "speech"), ("faceid", "faceid"),
        ("user-tracking", "user-tracking"), ("homekit", "homekit"),
        ("push", "notifications"), ("notification", "notifications"),
        ("photo-library", "photos"), ("photo", "photos"),
        ("location-always", "location-always"),
        ("location-in-use", "location-inuse"), ("location-inuse", "location-inuse"),
        ("mic", "microphone"),
        ("critical-notifications", "notifications-critical"),
        ("face-id", "faceid"), ("home-kit", "homekit"),
    ]
    for permission, service in catalog:
        assert_request(
            cli_path, socket_path, fake_home, state,
            ["permissions", "grant", permission, bundle_id],
            "simulator.permissions.set",
            {"action": "grant", "service": service, "bundle_id": bundle_id},
        )

    assert_request(
        cli_path, socket_path, fake_home, state,
        ["permissions", "grant", "location-always", bundle_id, "never"],
        "simulator.permissions.set",
        {"action": "revoke", "service": "location", "bundle_id": bundle_id},
    )
    assert_invalid(
        cli_path, socket_path, fake_home, state,
        ["permissions", "grant", "camera", "bad id"],
    )
    assert_invalid(
        cli_path, socket_path, fake_home, state,
        ["permissions", "grant", "microphone", bundle_id, "limited"],
    )


def check_interface(
    cli_path: str, socket_path: Path, fake_home: Path, state: RecordingState
) -> None:
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["ui", "status"], "simulator.ui.status", {},
    )
    get_result = assert_request(
        cli_path, socket_path, fake_home, state,
        ["ui", "get", "button-shapes"], "simulator.ui.status", {},
    )
    if get_result.stdout.strip() != "on":
        raise AssertionError(
            f"button-shapes alias printed {get_result.stdout.strip()!r}, expected 'on'"
        )
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["ui", "color-filter", "protanopia"], "simulator.ui.set",
        {"option": "color-filter", "value": "red-green"},
    )
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["ui", "set", "voice-over", "enabled"], "simulator.ui.set",
        {"option": "voiceover", "value": "on"},
    )

    text_sizes = [
        "extra-small", "small", "medium", "large", "extra-large",
        "extra-extra-large", "extra-extra-extra-large", "accessibility-medium",
        "accessibility-large", "accessibility-extra-large",
        "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large",
        "increment", "decrement",
    ]
    for text_size in text_sizes:
        assert_request(
            cli_path, socket_path, fake_home, state,
            ["ui", "text-size", text_size], "simulator.ui.set",
            {"option": "text-size", "value": text_size},
        )

    assert_invalid(
        cli_path, socket_path, fake_home, state,
        ["ui", "appearance", "purple"],
    )


def check_inspection(
    cli_path: str, socket_path: Path, fake_home: Path, state: RecordingState
) -> None:
    assert_request(
        cli_path, socket_path, fake_home, state,
        ["accessibility", "--surface", "surface:2"],
        "simulator.accessibility", {"surface_id": "surface:2"},
    )
    foreground = assert_request(
        cli_path, socket_path, fake_home, state,
        ["foreground", "--surface", "surface:2"],
        "simulator.foreground", {"surface_id": "surface:2"},
    )
    if "com.apple.Preferences" not in foreground.stdout:
        raise AssertionError(
            f"foreground output omitted bundle identifier: {foreground.stdout!r}"
        )
    assert_invalid(
        cli_path, socket_path, fake_home, state,
        ["accessibility", "unexpected"],
    )


def check_ios_error_identity(
    cli_path: str, socket_path: Path, fake_home: Path, state: RecordingState
) -> None:
    start = state.count()
    proc = run_ios_cli(
        cli_path, socket_path, fake_home,
        ["screenshot", "--surface", "surface:1"],
    )
    if proc.returncode == 0:
        raise AssertionError("iOS screenshot without a surface reference unexpectedly succeeded")
    if "no surface reference" not in proc.stderr:
        raise AssertionError(
            f"iOS screenshot misidentified a missing surface reference: {proc.stderr!r}"
        )
    requests = state.requests_since(start)
    if len(requests) != 1 or requests[0].get("method") != "simulator.prepare_screenshot":
        raise AssertionError(f"unexpected iOS screenshot requests: {requests!r}")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
        with tempfile.TemporaryDirectory(prefix="cmux-sim-cli-", dir="/tmp") as root:
            root_path = Path(root)
            socket_path = root_path / "cmux.sock"
            fake_home = root_path / "home"
            fake_home.mkdir()
            state = RecordingState()
            server = FakeCmuxUnixServer(str(socket_path), state)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                check_basic_actions(cli_path, socket_path, fake_home, state)
                check_permissions(cli_path, socket_path, fake_home, state)
                check_interface(cli_path, socket_path, fake_home, state)
                check_inspection(cli_path, socket_path, fake_home, state)
                check_ios_error_identity(cli_path, socket_path, fake_home, state)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)
    except (AssertionError, json.JSONDecodeError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"FAIL: {exc}")
        return 1

    print("PASS: Simulator CLI contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
