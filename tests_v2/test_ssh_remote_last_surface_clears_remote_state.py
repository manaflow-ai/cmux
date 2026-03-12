#!/usr/bin/env python3
"""Regression: closing the last SSH surface should clear remote workspace state."""

from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
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


def _wait_for(pred, timeout_s: float = 8.0, step_s: float = 0.1) -> None:
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


def _remote_session_count(client: cmux, workspace_id: str) -> int:
    row = _workspace_row(client, workspace_id)
    remote = row.get("remote") or {}
    return int(remote.get("active_terminal_sessions") or 0)


def _run_surface_probe(client: cmux, surface_id: str, command: str, token_prefix: str, timeout_s: float = 12.0) -> str:
    token = f"__CMUX_{token_prefix}_{int(time.time() * 1000)}__"
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
            return matches[-1]
        time.sleep(0.15)
    raise cmuxError(f"Timed out waiting for probe {token!r}: {last[-1200:]!r}")


def _open_ssh_workspace(client: cmux, cli: str, *, name: str) -> str:
    before_workspace_ids = {wid for _index, wid, _title, _focused in client.list_workspaces()}

    ssh_args = ["ssh", SSH_HOST, "--name", name]
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
    _wait_remote_ready(client, workspace_id)
    client.select_workspace(workspace_id)
    _wait_for(lambda: client.current_workspace() == workspace_id, timeout_s=8.0)
    return workspace_id


def main() -> int:
    if not SSH_HOST:
        print("SKIP: set CMUX_SSH_TEST_HOST to run ssh last-surface remote state regression")
        return 0

    cli = _find_cli_binary()
    workspace_id = ""

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = _open_ssh_workspace(
                client,
                cli,
                name=f"ssh-last-surface-{int(time.time())}",
            )

            row = _workspace_row(client, workspace_id)
            remote = row.get("remote") or {}
            _must(bool(remote.get("enabled")) is True, f"workspace should start as remote-enabled: {row}")
            _must(int(remote.get("active_terminal_sessions") or 0) == 1, f"workspace should start with one active ssh terminal session: {row}")

            surfaces = client.list_surfaces(workspace_id)
            _must(len(surfaces) == 1, f"expected one initial ssh surface, got {surfaces}")

            split_surface_id = client.new_split("right")
            _wait_for(lambda: len(client.list_surfaces(workspace_id)) == 2, timeout_s=10.0, step_s=0.1)
            _wait_for(lambda: _remote_session_count(client, workspace_id) == 2, timeout_s=10.0, step_s=0.1)

            client.send_surface(split_surface_id, "exit")
            client.send_key_surface(split_surface_id, "enter")
            _wait_for(lambda: _remote_session_count(client, workspace_id) == 1, timeout_s=15.0, step_s=0.15)

            row_after_first_exit = _workspace_row(client, workspace_id)
            remote_after_first_exit = row_after_first_exit.get("remote") or {}
            _must(bool(remote_after_first_exit.get("enabled")) is True, f"workspace should stay remote while one ssh terminal remains: {row_after_first_exit}")

            remaining_surface_id = next(
                surface_id
                for _index, surface_id, _focused in client.list_surfaces(workspace_id)
                if surface_id != split_surface_id
            )
            client.send_surface(remaining_surface_id, "exit")
            client.send_key_surface(remaining_surface_id, "enter")

            def _remote_cleared() -> bool:
                row_now = _workspace_row(client, workspace_id)
                remote_now = row_now.get("remote") or {}
                if bool(remote_now.get("enabled")):
                    return False
                surfaces_now = client.list_surfaces(workspace_id)
                return len(surfaces_now) == 2

            _wait_for(_remote_cleared, timeout_s=15.0, step_s=0.15)

            final_row = _workspace_row(client, workspace_id)
            final_remote = final_row.get("remote") or {}
            _must(bool(final_remote.get("enabled")) is False, f"workspace remote metadata should clear after last ssh surface closes: {final_row}")
            _must(str(final_remote.get("state") or "") == "disconnected", f"workspace should end disconnected after remote metadata clears: {final_row}")
            _must(int(final_remote.get("active_terminal_sessions") or 0) == 0, f"workspace should report zero active ssh terminal sessions after last ssh surface closes: {final_row}")

            local_surface_ids = [surface_id for _index, surface_id, _focused in client.list_surfaces(workspace_id)]
            _must(len(local_surface_ids) == 2, f"expected both panes to remain as local terminals after ssh exits, got {local_surface_ids}")
            for idx, surface_id in enumerate(local_surface_ids):
                socket_output = _run_surface_probe(
                    client,
                    surface_id,
                    r'''printf '%s' "${CMUX_SOCKET_PATH:-}"''',
                    f"SSH_LAST_SURFACE_SOCKET_{idx}",
                ).strip()
                _must(
                    not socket_output.startswith("127.0.0.1:"),
                    f"surface {surface_id} should be local after clearing remote state, got CMUX_SOCKET_PATH={socket_output!r}",
                )
    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client._call("workspace.close", {"workspace_id": workspace_id})
            except Exception:
                pass

    print("PASS: exiting all ssh panes clears remote workspace state while fallback local panes remain local")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
