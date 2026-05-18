#!/usr/bin/env python3
"""
Regression: restore-session should reopen the previous workspace graph and
relaunch resumable Codex sessions after a blank relaunch overwrites the primary
session snapshot.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import socket
import subprocess
import tempfile
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


def _snapshot_path(bundle_id: str, suffix: str = "") -> Path:
    safe_bundle = re.sub(r"[^A-Za-z0-9._-]", "_", bundle_id)
    return Path.home() / "Library/Application Support/cmux" / f"session-{safe_bundle}{suffix}.json"


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


def _launch(app_path: Path, socket_path: Path, env_overrides: dict[str, str] | None = None) -> None:
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass

    command = ["open", "-na", str(app_path)]
    full_env = dict(env_overrides or {})
    full_env["CMUX_SOCKET_PATH"] = str(socket_path)
    full_env["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
    for key, value in full_env.items():
        command.extend(["--env", f"{key}={value}"])
    subprocess.run(command, check=True)
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


def _wait_for_condition(timeout: float, predicate) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.25)
    return False


def _write_fake_codex(fake_bin_dir: Path) -> None:
    fake_bin_dir.mkdir(parents=True, exist_ok=True)
    fake_codex = fake_bin_dir / "codex"
    fake_codex.write_text(
        "#!/bin/sh\n"
        "printf 'CMUX_FAKE_CODEX_RESUME:%s\\n' \"$*\"\n",
        encoding="utf-8",
    )
    fake_codex.chmod(0o755)


def _write_hook_state(path: Path, session_id: str, workspace_id: str, surface_id: str, cwd: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "sessions": {
            session_id: {
                "sessionId": session_id,
                "workspaceId": workspace_id,
                "surfaceId": surface_id,
                "cwd": cwd,
                "updatedAt": time.time(),
            }
        },
    }
    path.write_text(json.dumps(payload), encoding="utf-8")


def main() -> int:
    app_path_str = os.environ.get("CMUX_APP_PATH", "").strip()
    if not app_path_str:
        print("SKIP: set CMUX_APP_PATH to a built cmux DEV .app path")
        return 0
    app_path = Path(app_path_str)
    if not app_path.exists():
        print(f"SKIP: CMUX_APP_PATH does not exist: {app_path}")
        return 0

    cli_path = app_path / "Contents" / "Resources" / "bin" / "cmux"
    if not cli_path.exists():
        print(f"SKIP: bundled cmux CLI not found at {cli_path}")
        return 0

    bundle_id = _bundle_id(app_path)
    socket_path = Path(f"/tmp/cmux-restore-session-codex-{bundle_id.replace('.', '-')}.sock")
    snapshot = _snapshot_path(bundle_id)
    previous_snapshot = _snapshot_path(bundle_id, suffix="-previous")

    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-restore-session-codex-") as td:
        fake_bin_dir = Path(td) / "bin"
        hook_state_dir = Path(td) / "hook-state"
        hook_state = hook_state_dir / "codex-hook-sessions.json"
        _write_fake_codex(fake_bin_dir)
        launch_path = f"{fake_bin_dir}:{os.environ.get('PATH', '')}"
        launch_env = {
            "PATH": launch_path,
            "CMUX_AGENT_HOOK_STATE_DIR": str(hook_state_dir),
        }

        _kill_existing(app_path)
        snapshot.unlink(missing_ok=True)
        previous_snapshot.unlink(missing_ok=True)

        try:
            _launch(app_path, socket_path, env_overrides=launch_env)
            client = _connect(socket_path)
            try:
                original_workspace_id = client.current_workspace()
                surfaces = client.list_surfaces()
                if not surfaces:
                    failures.append("expected at least one surface in the initial workspace")
                else:
                    surface_id = surfaces[0][1]
                    _write_hook_state(
                        hook_state,
                        session_id="codex-session-restore-2923",
                        workspace_id=original_workspace_id,
                        surface_id=surface_id,
                        cwd=os.getcwd(),
                    )

                client.new_workspace()
                time.sleep(0.4)
                client.select_workspace(original_workspace_id)
                time.sleep(0.4)
            finally:
                client.close()
            _quit(bundle_id, socket_path)
            hook_state.unlink(missing_ok=True)

            _launch(
                app_path,
                socket_path,
                env_overrides={
                    **launch_env,
                    "CMUX_DISABLE_SESSION_RESTORE": "1",
                },
            )
            client = _connect(socket_path)
            try:
                blank_workspaces = client.list_workspaces()
                if len(blank_workspaces) != 1:
                    failures.append(
                        f"expected blank relaunch to start with 1 workspace, got {len(blank_workspaces)}"
                    )

                time.sleep(9.5)

                restore_env = dict(os.environ)
                restore_env["CMUX_SOCKET_PATH"] = str(socket_path)
                restore_env["CMUX_AGENT_HOOK_STATE_DIR"] = str(hook_state_dir)
                restore_proc = subprocess.run(
                    [str(cli_path), "restore-session"],
                    capture_output=True,
                    text=True,
                    env=restore_env,
                )
                if restore_proc.returncode != 0:
                    failures.append(
                        "restore-session failed:\n"
                        f"stdout:\n{restore_proc.stdout}\n"
                        f"stderr:\n{restore_proc.stderr}"
                    )
                elif restore_proc.stdout.strip() != "OK":
                    failures.append(f"unexpected restore-session stdout: {restore_proc.stdout!r}")

                def restored() -> bool:
                    workspaces = client.list_workspaces()
                    if len(workspaces) < 2:
                        return False
                    client.select_workspace(0)
                    return "CMUX_FAKE_CODEX_RESUME:resume codex-session-restore-2923" in _read_scrollback(client)

                if not _wait_for_condition(12.0, restored):
                    client.select_workspace(0)
                    scrollback_tail = "\n".join(_read_scrollback(client).splitlines()[-20:])
                    failures.append(
                        "restore-session did not relaunch the saved Codex session; "
                        f"workspace_count={len(client.list_workspaces())} tail:\n{scrollback_tail}"
                    )
            finally:
                client.close()
            _quit(bundle_id, socket_path)
        finally:
            _kill_existing(app_path)
            socket_path.unlink(missing_ok=True)
            snapshot.unlink(missing_ok=True)
            previous_snapshot.unlink(missing_ok=True)
            hook_state.unlink(missing_ok=True)

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: restore-session reopens saved workspaces and resumes codex")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
