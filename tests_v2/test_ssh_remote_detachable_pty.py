#!/usr/bin/env python3
"""Integration: cmux ssh PTY sessions survive local surface detach and reattach."""

from __future__ import annotations

import glob
import json
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
SSH_HOST = os.environ.get("CMUX_SSH_TEST_HOST", "").strip()
SSH_PORT = os.environ.get("CMUX_SSH_TEST_PORT", "").strip()
SSH_IDENTITY = os.environ.get("CMUX_SSH_TEST_IDENTITY", "").strip()
SSH_OPTIONS_RAW = os.environ.get("CMUX_SSH_TEST_OPTIONS", "").strip()


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _run(cmd: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, check=False)
    if check and proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"Command failed ({' '.join(cmd)}): {merged}")
    return proc


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli_json(cli: str, args: list[str]) -> dict:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    proc = _run([cli, "--socket", SOCKET_PATH, "--json", *args], env=env)
    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})")


def _wait_for(pred, timeout_s: float = 10.0, step_s: float = 0.15) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _wait_remote_ready(client: cmux, workspace_id: str, timeout_s: float = 45.0) -> None:
    deadline = time.time() + timeout_s
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        daemon = remote.get("daemon") or {}
        if str(remote.get("state") or "") == "connected" and str(daemon.get("state") or "") == "ready":
            return
        time.sleep(0.25)
    raise cmuxError(f"Remote did not become ready for {workspace_id}: {last_status}")


def _resolve_workspace_id(client: cmux, payload: dict, *, before_workspace_ids: set[str]) -> str:
    workspace_id = str(payload.get("workspace_id") or "")
    if workspace_id:
        return workspace_id

    workspace_ref = str(payload.get("workspace_ref") or "")
    if workspace_ref.startswith("workspace:"):
        listed = client._call("workspace.list", {}) or {}
        for row in listed.get("workspaces") or []:
            if str(row.get("ref") or "") == workspace_ref:
                resolved = str(row.get("id") or "")
                if resolved:
                    return resolved

    current = {wid for _index, wid, _title, _focused in client.list_workspaces()}
    new_ids = sorted(current - before_workspace_ids)
    if len(new_ids) == 1:
        return new_ids[0]

    raise cmuxError(f"Unable to resolve workspace_id from payload: {payload}")


def _workspace_row(client: cmux, workspace_id: str) -> dict:
    rows = (client._call("workspace.list", {}) or {}).get("workspaces") or []
    for row in rows:
        if str(row.get("id") or "") == workspace_id:
            return row
    raise cmuxError(f"workspace.list missing {workspace_id}: {rows}")


def _run_surface_probe(client: cmux, surface_id: str, command: str, token_prefix: str, timeout_s: float = 18.0) -> str:
    token = f"__CMUX_{token_prefix}_{secrets.token_hex(6)}__"
    client.send_surface(
        surface_id,
        (
            f"printf '{token}:START'; echo; "
            f"{command}; "
            f"printf '{token}:END'; echo"
        ),
    )
    client.send_key_surface(surface_id, "enter")
    deadline = time.time() + timeout_s
    last = ""
    pattern = re.compile(re.escape(token) + r":START\n(.*?)" + re.escape(token) + r":END", re.S)
    while time.time() < deadline:
        last = client.read_terminal_text(surface_id)
        matches = pattern.findall(last)
        if matches:
            return matches[-1].replace("\r", "").strip()
        time.sleep(0.15)
    raise cmuxError(f"Timed out waiting for probe {token!r}: {last[-1200:]!r}")


def _open_ssh_workspace(client: cmux, cli: str) -> tuple[str, str, str, str]:
    before_workspace_ids = {wid for _index, wid, _title, _focused in client.list_workspaces()}

    ssh_args = ["ssh", SSH_HOST, "--name", f"ssh-detachable-pty-{int(time.time())}"]
    if SSH_PORT:
        ssh_args.extend(["--port", SSH_PORT])
    if SSH_IDENTITY:
        ssh_args.extend(["--identity", SSH_IDENTITY])
    if SSH_OPTIONS_RAW:
        for option in SSH_OPTIONS_RAW.split(","):
            trimmed = option.strip()
            if trimmed:
                ssh_args.extend(["--ssh-option", trimmed])

    payload = _run_cli_json(cli, ssh_args)
    workspace_id = _resolve_workspace_id(client, payload, before_workspace_ids=before_workspace_ids)
    session_id = str(payload.get("ssh_pty_session_id") or "")
    persistent_slot = str(payload.get("persistent_daemon_slot") or "")
    _must(session_id.startswith("ssh-"), f"cmux ssh did not create a persistent PTY session: {payload}")
    _must(persistent_slot.startswith("ssh-"), f"cmux ssh did not create a persistent daemon slot: {payload}")

    surface_id = str(payload.get("surface_id") or "")
    if not surface_id:
        surfaces = client.list_surfaces(workspace_id)
        _must(len(surfaces) == 1, f"expected one initial ssh surface, got {surfaces}")
        surface_id = surfaces[0][1]

    _wait_remote_ready(client, workspace_id)
    client.select_workspace(workspace_id)
    _wait_for(lambda: client.current_workspace() == workspace_id, timeout_s=8.0)
    return workspace_id, surface_id, session_id, persistent_slot


def _session_list(cli: str, workspace_id: str) -> list[dict]:
    payload = _run_cli_json(cli, ["ssh-session-list", "--workspace", workspace_id])
    return list(payload.get("sessions") or [])


def _session_row(cli: str, workspace_id: str, session_id: str) -> dict | None:
    for row in _session_list(cli, workspace_id):
        if str(row.get("session_id") or "") == session_id:
            return row
    return None


def main() -> int:
    if not SSH_HOST:
        print("SKIP: set CMUX_SSH_TEST_HOST to run ssh detachable PTY regression")
        return 0

    cli = _find_cli_binary()
    workspace_id = ""
    session_id = ""

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id, surface_id, session_id, persistent_slot = _open_ssh_workspace(client, cli)

            marker = f"detachable_{secrets.token_hex(6)}"
            first_probe = _run_surface_probe(
                client,
                surface_id,
                f"export CMUX_DETACH_MARK={marker}; printf 'pid=%s marker=%s socket=%s' \"$$\" \"$CMUX_DETACH_MARK\" \"$CMUX_SOCKET_PATH\"",
                "SSH_DETACH_FIRST",
            )
            match = re.search(r"pid=([0-9]+) marker=(\S+) socket=(\S+)", first_probe)
            _must(match is not None, f"initial shell probe did not return expected fields: {first_probe!r}")
            original_pid, original_marker, original_socket = match.groups()
            _must(original_marker == marker, f"remote marker was not exported: {first_probe!r}")
            _must(original_socket.startswith("127.0.0.1:"), f"remote shell should use relay socket, got {original_socket!r}")

            browser_surface = client.new_surface(panel_type="browser", url="about:blank")
            _must(browser_surface, "failed to create browser surface guard")
            client.close_surface(surface_id)

            def detached_session_is_listed() -> bool:
                row = _session_row(cli, workspace_id, session_id)
                if row is None:
                    return False
                attachments = row.get("attachments") or []
                return len(attachments) == 0

            _wait_for(detached_session_is_listed, timeout_s=20.0, step_s=0.25)
            row_after_detach = _session_row(cli, workspace_id, session_id)
            _must(row_after_detach is not None, f"detached session {session_id} disappeared")
            _must(
                int(row_after_detach.get("scrollback_bytes") or 0) > 0,
                f"detached session should keep bounded scrollback metadata: {row_after_detach}",
            )

            attach_payload = _run_cli_json(
                cli,
                ["ssh-session-attach", "--workspace", workspace_id, "--session-id", session_id],
            )
            reattached_surface = str(attach_payload.get("surface_id") or "")
            _must(reattached_surface, f"ssh-session-attach output missing surface_id: {attach_payload}")

            second_probe = _run_surface_probe(
                client,
                reattached_surface,
                "printf 'pid=%s marker=%s socket=%s' \"$$\" \"$CMUX_DETACH_MARK\" \"$CMUX_SOCKET_PATH\"",
                "SSH_DETACH_SECOND",
            )
            rematch = re.search(r"pid=([0-9]+) marker=(\S+) socket=(\S+)", second_probe)
            _must(rematch is not None, f"reattached shell probe did not return expected fields: {second_probe!r}")
            reattached_pid, reattached_marker, reattached_socket = rematch.groups()
            _must(reattached_pid == original_pid, f"reattach should preserve shell pid {original_pid}, got {reattached_pid}")
            _must(reattached_marker == marker, f"reattach should preserve remote shell env marker, got {second_probe!r}")
            _must(reattached_socket == original_socket, f"reattach should preserve relay socket {original_socket}, got {reattached_socket}")

            final_row = _workspace_row(client, workspace_id)
            final_remote = final_row.get("remote") or {}
            _must(
                str(final_remote.get("persistent_daemon_slot") or "") == persistent_slot,
                f"workspace status should expose persistent daemon slot {persistent_slot}: {final_row}",
            )
    finally:
        if workspace_id:
            try:
                if session_id:
                    _run_cli_json(cli, ["ssh-session-cleanup", "--workspace", workspace_id, "--session-id", session_id])
            except Exception:
                pass
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client._call("workspace.close", {"workspace_id": workspace_id})
            except Exception:
                pass

    print("PASS: cmux ssh PTY survives local detach and reattaches to the same remote shell")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
