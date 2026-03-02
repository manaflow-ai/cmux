#!/usr/bin/env python3
"""Regression: moving a browser surface into an SSH workspace must rebind remote proxy state."""

from __future__ import annotations

import glob
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux.sock")
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


def _wait_remote_ready(client: cmux, workspace_id: str, timeout_s: float = 60.0) -> dict:
    deadline = time.time() + timeout_s
    last = {}
    while time.time() < deadline:
        last = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last.get("remote") or {}
        daemon = remote.get("daemon") or {}
        proxy = remote.get("proxy") or {}
        if (
            str(remote.get("state") or "") == "connected"
            and str(daemon.get("state") or "") == "ready"
            and str(proxy.get("state") or "") == "ready"
        ):
            return last
        time.sleep(0.25)
    raise cmuxError(f"Remote did not reach connected+ready+proxy-ready state: {last}")


def _surface_scrollback_text(client: cmux, workspace_id: str, surface_id: str) -> str:
    payload = client._call(
        "surface.read_text",
        {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
    ) or {}
    return str(payload.get("text") or "")


def _wait_surface_contains(client: cmux, workspace_id: str, surface_id: str, token: str, timeout_s: float = 20.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if token in _surface_scrollback_text(client, workspace_id, surface_id):
            return
        time.sleep(0.2)
    raise cmuxError(f"Timed out waiting for remote terminal token: {token}")


def _browser_body_text(client: cmux, surface_id: str) -> str:
    payload = client._call(
        "browser.eval",
        {
            "surface_id": surface_id,
            "script": "document.body ? (document.body.innerText || '') : ''",
        },
    ) or {}
    return str(payload.get("value") or "")


def _wait_browser_contains(client: cmux, surface_id: str, token: str, timeout_s: float = 20.0) -> None:
    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        try:
            last_text = _browser_body_text(client, surface_id)
        except cmuxError:
            time.sleep(0.2)
            continue
        if token in last_text:
            return
        time.sleep(0.2)
    raise cmuxError(f"Timed out waiting for browser content token {token!r}; last body sample={last_text[:240]!r}")


def _assert_browser_does_not_contain(client: cmux, surface_id: str, token: str, sample_window_s: float = 6.0) -> str:
    deadline = time.time() + sample_window_s
    last_text = ""
    while time.time() < deadline:
        try:
            last_text = _browser_body_text(client, surface_id)
        except cmuxError:
            time.sleep(0.2)
            continue
        if token in last_text:
            raise cmuxError(
                f"browser unexpectedly loaded remote marker before SSH proxy rebind; token={token!r} body={last_text[:240]!r}"
            )
        time.sleep(0.2)
    return last_text


def main() -> int:
    if not SSH_HOST:
        print("SKIP: set CMUX_SSH_TEST_HOST to run remote browser move/proxy regression")
        return 0

    cli = _find_cli_binary()
    remote_workspace_id = ""
    remote_surface_id = ""

    stamp = secrets.token_hex(4)
    marker_file = f"CMUX_REMOTE_PROXY_MOVE_{stamp}.txt"
    marker_body = f"CMUX_REMOTE_PROXY_BODY_{stamp}"
    ready_token = f"CMUX_HTTP_READY_{stamp}"
    default_web_port = 20000 + (os.getpid() % 5000)
    ssh_web_port = int(os.environ.get("CMUX_SSH_TEST_WEB_PORT", str(default_web_port)))
    url = f"http://localhost:{ssh_web_port}/{marker_file}"

    try:
        with cmux(SOCKET_PATH) as client:
            before_workspace_ids = {wid for _index, wid, _title, _focused in client.list_workspaces()}

            browser_surface_id = client.open_browser("about:blank")
            _must(bool(browser_surface_id), "browser.open_split returned no surface")

            ssh_args = ["ssh", SSH_HOST, "--name", f"ssh-browser-move-proxy-{stamp}"]
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
            remote_workspace_id = _resolve_workspace_id(client, payload, before_workspace_ids=before_workspace_ids)
            remote_status = _wait_remote_ready(client, remote_workspace_id, timeout_s=65.0)
            remote_payload = remote_status.get("remote") or {}
            forwarded_ports = remote_payload.get("forwarded_ports") or []
            _must(
                forwarded_ports == [],
                f"remote workspace should rely on proxy endpoint, not explicit forwarded ports: {forwarded_ports!r}",
            )

            surfaces = client.list_surfaces(remote_workspace_id)
            _must(bool(surfaces), f"remote workspace should have at least one surface: {remote_workspace_id}")
            remote_surface_id = str(surfaces[0][1])

            server_script = (
                f"printf '%s\\n' {marker_body} > /tmp/{marker_file}; "
                f"python3 -m http.server {ssh_web_port} --directory /tmp >/tmp/cmux-remote-browser-proxy-{stamp}.log 2>&1 & "
                "for _ in $(seq 1 30); do "
                f"  if curl -fsS http://localhost:{ssh_web_port}/{marker_file} | grep -q {marker_body}; then "
                f"    echo {ready_token}; "
                "    break; "
                "  fi; "
                "  sleep 0.2; "
                "done"
            )
            client._call(
                "surface.send_text",
                {"workspace_id": remote_workspace_id, "surface_id": remote_surface_id, "text": server_script},
            )
            client._call(
                "surface.send_key",
                {"workspace_id": remote_workspace_id, "surface_id": remote_surface_id, "key": "enter"},
            )
            _wait_surface_contains(client, remote_workspace_id, remote_surface_id, ready_token, timeout_s=12.0)

            browser_surface_id = str(client._resolve_surface_id(browser_surface_id))
            client._call("browser.navigate", {"surface_id": browser_surface_id, "url": url})
            local_body = _assert_browser_does_not_contain(client, browser_surface_id, marker_body, sample_window_s=5.0)
            _must(
                marker_body not in local_body,
                f"browser should not reach remote localhost before moving into ssh workspace: {local_body[:240]!r}",
            )

            client.move_surface(browser_surface_id, workspace=remote_workspace_id, focus=True)

            def _browser_in_remote_workspace() -> bool:
                for _idx, sid, _focused in client.list_surfaces(remote_workspace_id):
                    if str(sid) == browser_surface_id:
                        return True
                return False

            _wait_for(_browser_in_remote_workspace, timeout_s=10.0, step_s=0.15)

            client._call("browser.navigate", {"surface_id": browser_surface_id, "url": url})
            _wait_browser_contains(client, browser_surface_id, marker_body, timeout_s=20.0)

            body = _browser_body_text(client, browser_surface_id)
            _must(marker_body in body, f"browser did not load remote localhost content over SSH proxy: {body[:240]!r}")
            _must("Can't reach this page" not in body, f"browser rendered local error page instead of remote content: {body[:240]!r}")

            print(
                "PASS: browser proxy stays scoped to SSH workspace surfaces, uses proxy endpoint without explicit forwarded ports, "
                "and reaches remote localhost after move"
            )
            return 0
    finally:
        if remote_surface_id and remote_workspace_id:
            try:
                cleanup = f"pkill -f 'python3 -m http.server {ssh_web_port}' >/dev/null 2>&1 || true"
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client._call(
                        "surface.send_text",
                        {"workspace_id": remote_workspace_id, "surface_id": remote_surface_id, "text": cleanup},
                    )
                    cleanup_client._call(
                        "surface.send_key",
                        {"workspace_id": remote_workspace_id, "surface_id": remote_surface_id, "key": "enter"},
                    )
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    raise SystemExit(main())
