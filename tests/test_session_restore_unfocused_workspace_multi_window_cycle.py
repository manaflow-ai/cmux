#!/usr/bin/env python3
"""
Regression: unfocused workspace scrollback must persist across relaunchs in multi-window setups.
"""

from __future__ import annotations

import os
import plistlib
import re
import socket
import subprocess
import time
from pathlib import Path

from cmux import cmux


def _bundle_id(app_path: Path) -> str:
    info_path = app_path / "Contents" / "Info.plist"
    if not info_path.exists():
        raise RuntimeError(f"Missing Info.plist at {info_path}")
    with info_path.open("rb") as f:
        info = plistlib.load(f)
    bundle_id = str(info.get("CFBundleIdentifier", "")).strip()
    if not bundle_id:
        raise RuntimeError("Missing CFBundleIdentifier")
    return bundle_id


def _snapshot_path(bundle_id: str) -> Path:
    safe_bundle = re.sub(r"[^A-Za-z0-9._-]", "_", bundle_id)
    return Path.home() / "Library/Application Support/cmux" / f"session-{safe_bundle}.json"


def _sanitize_tag_slug(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", (raw or "").strip().lower())
    cleaned = re.sub(r"-+", "-", cleaned).strip("-")
    return cleaned or "agent"


def _socket_candidates(app_path: Path, preferred: Path) -> list[Path]:
    candidates = [preferred]
    app_name = app_path.stem
    prefix = "cmux DEV "
    if app_name.startswith(prefix):
        tag = app_name[len(prefix):]
        slug = _sanitize_tag_slug(tag)
        candidates.append(Path(f"/tmp/cmux-debug-{slug}.sock"))
    deduped: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(candidate)
    return deduped


def _socket_reachable(socket_path: Path) -> bool:
    if not socket_path.exists():
        return False
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(0.3)
        sock.connect(str(socket_path))
        sock.sendall(b"ping\n")
        data = sock.recv(1024)
        return b"PONG" in data
    except OSError:
        return False
    finally:
        sock.close()


def _wait_for_socket(candidates: list[Path], timeout: float = 20.0) -> Path:
    deadline = time.time() + timeout
    while time.time() < deadline:
        for candidate in candidates:
            if _socket_reachable(candidate):
                return candidate
        time.sleep(0.2)
    joined = ", ".join(str(path) for path in candidates)
    raise RuntimeError(f"Socket did not become reachable: {joined}")


def _wait_for_socket_closed(socket_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not _socket_reachable(socket_path):
            return
        time.sleep(0.2)
    raise RuntimeError(f"Socket still reachable after quit: {socket_path}")


def _kill_existing(app_path: Path) -> None:
    exe = app_path / "Contents" / "MacOS" / "cmux DEV"
    subprocess.run(["pkill", "-f", str(exe)], capture_output=True, text=True)
    time.sleep(1.0)


def _launch(app_path: Path, preferred_socket_path: Path) -> Path:
    try:
        preferred_socket_path.unlink()
    except FileNotFoundError:
        pass
    subprocess.run(
        [
            "open",
            "-na",
            str(app_path),
            "--env",
            f"CMUX_SOCKET_PATH={preferred_socket_path}",
            "--env",
            "CMUX_ALLOW_SOCKET_OVERRIDE=1",
        ],
        check=True,
    )
    resolved_socket_path = _wait_for_socket(_socket_candidates(app_path, preferred_socket_path))
    time.sleep(1.5)
    return resolved_socket_path


def _quit(bundle_id: str, socket_path: Path) -> None:
    subprocess.run(
        ["osascript", "-e", f'tell application id "{bundle_id}" to quit'],
        capture_output=True,
        text=True,
        check=True,
    )
    _wait_for_socket_closed(socket_path)
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    time.sleep(0.8)


def _connect(socket_path: Path) -> cmux:
    client = cmux(socket_path=str(socket_path))
    client.connect()
    if not client.ping():
        raise RuntimeError("ping failed")
    return client


def _read_scrollback(client: cmux) -> str:
    return client._send_command("read_screen --scrollback")


def _wait_for_marker(client: cmux, marker: str, timeout: float = 8.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if marker in _read_scrollback(client):
            return True
        time.sleep(0.25)
    return False


def _consume_visible_markers(client: cmux, remaining: set[str], timeout: float = 4.0) -> None:
    if not remaining:
        return
    deadline = time.time() + timeout
    while time.time() < deadline and remaining:
        text = _read_scrollback(client)
        matched = [marker for marker in remaining if marker in text]
        if matched:
            for marker in matched:
                remaining.discard(marker)
            if not remaining:
                return
        time.sleep(0.25)


def _ensure_workspaces(client: cmux, count: int) -> None:
    while len(client.list_workspaces()) < count:
        client.new_workspace()
        time.sleep(0.3)


def _list_windows(client: cmux) -> list[str]:
    response = client._send_command("list_windows")
    if response == "No windows":
        return []
    window_ids: list[str] = []
    for line in response.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.lstrip("* ").split(" ", 2)
        if len(parts) >= 2:
            window_ids.append(parts[1])
    return window_ids


def _new_window(client: cmux) -> str:
    response = client._send_command("new_window")
    if not response.startswith("OK "):
        raise RuntimeError(f"new_window failed: {response}")
    return response.split(" ", 1)[1].strip()


def _focus_window(client: cmux, window_id: str) -> None:
    response = client._send_command(f"focus_window {window_id}")
    if response != "OK":
        raise RuntimeError(f"focus_window failed for {window_id}: {response}")


def main() -> int:
    app_path_str = os.environ.get("CMUX_APP_PATH", "").strip()
    if not app_path_str:
        print("SKIP: set CMUX_APP_PATH to a built cmux DEV .app path")
        return 0
    app_path = Path(app_path_str)
    if not app_path.exists():
        print(f"SKIP: CMUX_APP_PATH does not exist: {app_path}")
        return 0

    bundle_id = _bundle_id(app_path)
    snapshot = _snapshot_path(bundle_id)
    # Keep the override path short enough for Darwin's Unix socket path limit.
    bundle_suffix = re.sub(r"[^A-Za-z0-9]", "", bundle_id)[-16:] or "bundle"
    socket_path = Path(f"/tmp/cmux-mw-restore-{bundle_suffix}.sock")

    markers = {
        "w1_ws0": "CMUX_MW_RESTORE_W1_WS0",
        "w1_ws1": "CMUX_MW_RESTORE_W1_WS1",
        "w2_ws0": "CMUX_MW_RESTORE_W2_WS0",
        "w2_ws1": "CMUX_MW_RESTORE_W2_WS1",
    }
    failures: list[str] = []

    _kill_existing(app_path)
    snapshot.unlink(missing_ok=True)

    try:
        # Launch 1: create 2 windows x 2 workspaces; write markers.
        socket_path = _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            # Window 1 setup.
            _ensure_workspaces(client, 2)
            client.select_workspace(0)
            client.send(f"echo {markers['w1_ws0']}\n")
            if not _wait_for_marker(client, markers["w1_ws0"]):
                failures.append("missing marker for window1 workspace0 during setup")
            client.select_workspace(1)
            client.send(f"echo {markers['w1_ws1']}\n")
            if not _wait_for_marker(client, markers["w1_ws1"]):
                failures.append("missing marker for window1 workspace1 during setup")
            client.select_workspace(0)  # leave workspace 1 unfocused in window 1

            # Window 2 setup.
            _new_window(client)
            time.sleep(0.5)
            _ensure_workspaces(client, 2)
            client.select_workspace(0)
            client.send(f"echo {markers['w2_ws0']}\n")
            if not _wait_for_marker(client, markers["w2_ws0"]):
                failures.append("missing marker for window2 workspace0 during setup")
            client.select_workspace(1)
            client.send(f"echo {markers['w2_ws1']}\n")
            if not _wait_for_marker(client, markers["w2_ws1"]):
                failures.append("missing marker for window2 workspace1 during setup")
            client.select_workspace(0)  # leave workspace 1 unfocused in window 2
        finally:
            client.close()
        _quit(bundle_id, socket_path)

        # Launch 2: immediate quit without focusing unfocused workspaces.
        socket_path = _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            window_ids = _list_windows(client)
            if len(window_ids) < 2:
                failures.append(f"expected >=2 windows after first relaunch, got {len(window_ids)}")
        finally:
            client.close()
        _quit(bundle_id, socket_path)

        # Launch 3: verify all markers still present across windows/workspaces.
        socket_path = _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            window_ids = _list_windows(client)
            if len(window_ids) < 2:
                failures.append(f"expected >=2 windows after second relaunch, got {len(window_ids)}")

            remaining = set(markers.values())
            for window_id in window_ids:
                _focus_window(client, window_id)
                time.sleep(0.3)
                workspace_count = len(client.list_workspaces())
                for idx in range(min(workspace_count, 2)):
                    client.select_workspace(idx)
                    _consume_visible_markers(client, remaining, timeout=6.0)
                    if not remaining:
                        break
                if not remaining:
                    break

            if remaining:
                failures.append(f"missing markers after second relaunch: {sorted(remaining)}")
        finally:
            client.close()
        _quit(bundle_id, socket_path)
    finally:
        _kill_existing(app_path)
        socket_path.unlink(missing_ok=True)
        snapshot.unlink(missing_ok=True)

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: multi-window unfocused workspaces survive repeated relaunch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
