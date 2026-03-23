#!/usr/bin/env python3
"""Regression: new tabs and splits from an ssh terminal must stay on the remote shell."""

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


def _focused_surface_id(client: cmux) -> str:
    ident = client.identify()
    focused = ident.get("focused") or {}
    surface_id = str(focused.get("surface_id") or "")
    if not surface_id:
        raise cmuxError(f"Missing focused surface in identify payload: {ident}")
    return surface_id


def _run_remote_shell_probe(client: cmux, surface_id: str, probe_label: str) -> str:
    token = f"__CMUX_REMOTE_SOCKET_{probe_label}_{secrets.token_hex(4)}__"
    client.send_surface(
        surface_id,
        (
            f"__cmux_socket_path=\"${{CMUX_SOCKET_PATH:-}}\"; "
            f"printf '{token}:%s:__CMUX_REMOTE_SOCKET_END__\\n' \"$__cmux_socket_path\"\n"
        ),
    )
    deadline = time.time() + 15.0
    last = ""
    pattern = re.compile(re.escape(token) + r":(.*?):__CMUX_REMOTE_SOCKET_END__")
    while time.time() < deadline:
        last = client.read_terminal_text(surface_id)
        matches = pattern.findall(last)
        if matches:
            for candidate in reversed(matches):
                cleaned = candidate.strip()
                if cleaned and cleaned != "%s":
                    return cleaned
        time.sleep(0.15)
    raise cmuxError(f"Timed out waiting for socket token {token!r}: {last[-1200:]!r}")


def _assert_remote_socket_path(client: cmux, surface_id: str, shortcut_name: str) -> None:
    socket_path = _run_remote_shell_probe(client, surface_id, shortcut_name)
    _must(
        socket_path.startswith("127.0.0.1:"),
        f"{shortcut_name} should keep the new terminal on the ssh relay, got CMUX_SOCKET_PATH={socket_path!r}",
    )


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


def _assert_shortcut_creates_remote_terminal(
    client: cmux,
    workspace_id: str,
    shortcut: str,
    shortcut_name: str,
    *,
    expect_new_pane: bool,
) -> None:
    before_surfaces = {sid for _index, sid, _focused in client.list_surfaces(workspace_id)}
    before_pane_count = len(client.list_panes())

    client.activate_app()
    client.simulate_app_active()
    client.simulate_shortcut(shortcut)

    _wait_for(
        lambda: len({sid for _index, sid, _focused in client.list_surfaces(workspace_id)} - before_surfaces) == 1,
        timeout_s=12.0,
    )

    if expect_new_pane:
        _wait_for(lambda: len(client.list_panes()) >= before_pane_count + 1, timeout_s=12.0)

    after_surfaces = {sid for _index, sid, _focused in client.list_surfaces(workspace_id)}
    new_surface_ids = sorted(after_surfaces - before_surfaces)
    _must(len(new_surface_ids) == 1, f"{shortcut_name} should create exactly one new surface: {new_surface_ids}")

    focused_surface_id = _focused_surface_id(client)
    _must(
        focused_surface_id == new_surface_ids[0],
        f"{shortcut_name} should focus the new terminal surface: focused={focused_surface_id!r} new={new_surface_ids[0]!r}",
    )
    _assert_remote_socket_path(client, focused_surface_id, shortcut_name)


def main() -> int:
    if not SSH_HOST:
        print("SKIP: set CMUX_SSH_TEST_HOST to run ssh shortcut inheritance regression")
        return 0

    cli = _find_cli_binary()
    workspace_ids: list[str] = []

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = _open_ssh_workspace(
                client,
                cli,
                name=f"ssh-shortcut-cmdt-{secrets.token_hex(4)}",
            )
            workspace_ids.append(workspace_id)
            _assert_shortcut_creates_remote_terminal(
                client,
                workspace_id,
                "cmd+t",
                "cmd+t",
                expect_new_pane=False,
            )

            workspace_id = _open_ssh_workspace(
                client,
                cli,
                name=f"ssh-shortcut-cmdd-{secrets.token_hex(4)}",
            )
            workspace_ids.append(workspace_id)
            _assert_shortcut_creates_remote_terminal(
                client,
                workspace_id,
                "cmd+d",
                "cmd+d",
                expect_new_pane=True,
            )

            workspace_id = _open_ssh_workspace(
                client,
                cli,
                name=f"ssh-shortcut-cmdshiftd-{secrets.token_hex(4)}",
            )
            workspace_ids.append(workspace_id)
            _assert_shortcut_creates_remote_terminal(
                client,
                workspace_id,
                "cmd+shift+d",
                "cmd+shift+d",
                expect_new_pane=True,
            )
    finally:
        if workspace_ids:
            try:
                with cmux(SOCKET_PATH) as client:
                    for workspace_id in workspace_ids:
                        try:
                            client._call("workspace.close", {"workspace_id": workspace_id})
                        except Exception:
                            pass
            except Exception:
                pass

    print("PASS: cmd+t/cmd+d/cmd+shift+d keep ssh terminals on the remote relay")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
