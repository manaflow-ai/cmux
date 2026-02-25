#!/usr/bin/env python3
"""
Regression: unfocused restored workspaces must survive a second relaunch.

Repro for the historical bug:
1) Launch and save workspaces with marker scrollback.
2) Relaunch, do not focus the non-selected workspaces, then quit again.
3) Relaunch and verify marker scrollback still exists for every workspace.
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


def _wait_for_socket(socket_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _socket_reachable(socket_path):
            return
        time.sleep(0.2)
    raise RuntimeError(f"Socket did not become reachable: {socket_path}")


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


def _launch(app_path: Path, socket_path: Path) -> None:
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    subprocess.run(
        [
            "open",
            "-na",
            str(app_path),
            "--env",
            f"CMUX_SOCKET_PATH={socket_path}",
            "--env",
            "CMUX_ALLOW_SOCKET_OVERRIDE=1",
        ],
        check=True,
    )
    _wait_for_socket(socket_path)
    time.sleep(1.5)


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
    socket_path = Path(f"/tmp/cmux-session-restore-cycle-{bundle_id.replace('.', '-')}.sock")

    markers = [f"CMUX_RESTORE_EDGE_{i}" for i in range(3)]
    failures: list[str] = []

    _kill_existing(app_path)
    snapshot.unlink(missing_ok=True)

    try:
        # First launch: seed three workspaces with marker scrollback.
        _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            while len(client.list_workspaces()) < 3:
                client.new_workspace()
                time.sleep(0.3)

            for idx, marker in enumerate(markers):
                client.select_workspace(idx)
                time.sleep(0.4)
                client.send(f"echo {marker}\n")
                if not _wait_for_marker(client, marker, timeout=6.0):
                    failures.append(f"setup marker missing in workspace {idx}: {marker}")

            # Keep selected workspace deterministic.
            client.select_workspace(1)
            time.sleep(0.3)
        finally:
            client.close()
        _quit(bundle_id, socket_path)

        # Second launch: do not focus unfocused workspaces. Quit immediately.
        _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            restored = client.list_workspaces()
            if len(restored) < 3:
                failures.append(f"expected >=3 workspaces after first relaunch, got {len(restored)}")
            selected_indices = [idx for idx, _wid, _title, selected in restored if selected]
            if selected_indices != [1]:
                failures.append(f"expected selected workspace index [1], got {selected_indices}")
        finally:
            client.close()
        _quit(bundle_id, socket_path)

        # Third launch: every workspace should still contain its marker.
        _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            restored = client.list_workspaces()
            if len(restored) < 3:
                failures.append(f"expected >=3 workspaces after second relaunch, got {len(restored)}")

            for idx, marker in enumerate(markers):
                client.select_workspace(idx)
                if not _wait_for_marker(client, marker, timeout=8.0):
                    tail = "\n".join(_read_scrollback(client).splitlines()[-10:])
                    failures.append(
                        f"workspace {idx} missing marker {marker} after second relaunch; tail:\n{tail}"
                    )
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

    print("PASS: unfocused workspace scrollback survives repeated relaunch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
