#!/usr/bin/env python3
"""Regression: remote browser favicon fetches must use the SSH proxy path."""

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


def _resolve_workspace_id(client: cmux, payload: dict, *, before_workspace_ids: set[str]) -> str:
    workspace_id = str(payload.get("workspace_id") or "")
    if workspace_id:
        return workspace_id

    workspace_ref = str(payload.get("workspace_ref") or "")
    if workspace_ref.startswith("workspace:"):
        with cmux(SOCKET_PATH) as lookup_client:
            listed = lookup_client._call("workspace.list", {}) or {}
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


def _wait_remote_ready(client: cmux, workspace_id: str, timeout_s: float = 65.0) -> dict:
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
    raise cmuxError(f"Timed out waiting for terminal token: {token}")


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


def _browser_favicon_state(client: cmux, surface_id: str) -> dict:
    return dict(client._call("debug.browser.favicon", {"surface_id": surface_id}) or {})


def _wait_browser_favicon(client: cmux, surface_id: str, timeout_s: float = 20.0) -> dict:
    deadline = time.time() + timeout_s
    last = {}
    while time.time() < deadline:
        try:
            last = _browser_favicon_state(client, surface_id)
        except cmuxError:
            time.sleep(0.2)
            continue
        if bool(last.get("has_favicon")) and bool(str(last.get("png_base64") or "")):
            return last
        time.sleep(0.2)
    raise cmuxError(f"Timed out waiting for browser favicon state on {surface_id}: {last}")


def main() -> int:
    if not SSH_HOST:
        print("SKIP: set CMUX_SSH_TEST_HOST to run remote favicon proxy regression")
        return 0

    cli = _find_cli_binary()
    remote_workspace_id = ""
    remote_surface_id = ""
    server_script_path = ""
    server_log_path = ""
    hit_file_path = ""

    stamp = secrets.token_hex(4)
    page_token = f"CMUX_REMOTE_FAVICON_PAGE_{stamp}"
    server_ready_token = f"CMUX_REMOTE_FAVICON_READY_{stamp}"
    default_web_port = 23000 + (os.getpid() % 4000)
    ssh_web_port = int(os.environ.get("CMUX_SSH_TEST_WEB_PORT", str(default_web_port)))
    url = f"http://localhost:{ssh_web_port}/"
    png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9WewAAAABJRU5ErkJggg=="
    server_script_path = f"/tmp/cmux_remote_favicon_server_{stamp}.py"
    server_log_path = f"/tmp/cmux_remote_favicon_server_{stamp}.log"
    hit_file_path = f"/tmp/cmux_remote_favicon_hit_{stamp}"

    try:
        with cmux(SOCKET_PATH) as setup_client:
            before_workspace_ids = {wid for _index, wid, _title, _focused in setup_client.list_workspaces()}

        ssh_args = ["ssh", SSH_HOST, "--name", f"ssh-browser-favicon-{stamp}"]
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

        with cmux(SOCKET_PATH) as client:
            remote_workspace_id = _resolve_workspace_id(client, payload, before_workspace_ids=before_workspace_ids)
            _wait_remote_ready(client, remote_workspace_id, timeout_s=65.0)

            surfaces = client.list_surfaces(remote_workspace_id)
            _must(bool(surfaces), f"remote workspace should have at least one surface: {remote_workspace_id}")
            remote_surface_id = str(surfaces[0][1])

            server_script = f"""cat > {server_script_path} <<'PY'
import base64
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
HIT_FILE = sys.argv[2]
PAGE_TOKEN = sys.argv[3]
PNG = base64.b64decode(sys.argv[4].encode("ascii"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/favicon.ico"):
            with open(HIT_FILE, "w", encoding="utf-8") as f:
                f.write("hit\\n")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(PNG)))
            self.end_headers()
            self.wfile.write(PNG)
            return

        body = (
            "<!doctype html><html><head>"
            "<link rel=\\"icon\\" href=\\"/favicon.ico?via=cmux\\">"
            f"</head><body>{{PAGE_TOKEN}}</body></html>"
        ).replace("{{PAGE_TOKEN}}", PAGE_TOKEN)
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return

HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY
rm -f {hit_file_path} {server_log_path}
python3 {server_script_path} {ssh_web_port} {hit_file_path} {page_token} {png_base64} >{server_log_path} 2>&1 &
for _ in $(seq 1 30); do
  if curl -fsS http://localhost:{ssh_web_port}/ | grep -q {page_token}; then
    echo {server_ready_token}
    break
  fi
  sleep 0.2
done"""
            client._call(
                "surface.send_text",
                {"workspace_id": remote_workspace_id, "surface_id": remote_surface_id, "text": server_script},
            )
            client._call(
                "surface.send_key",
                {"workspace_id": remote_workspace_id, "surface_id": remote_surface_id, "key": "enter"},
            )
            _wait_surface_contains(client, remote_workspace_id, remote_surface_id, server_ready_token, timeout_s=12.0)

            browser_payload = client._call(
                "browser.open_split",
                {"workspace_id": remote_workspace_id, "url": url},
            ) or {}
            browser_surface_id = str(browser_payload.get("surface_id") or "")
            _must(browser_surface_id, f"browser.open_split returned no surface_id: {browser_payload}")

            _wait_browser_contains(client, browser_surface_id, page_token, timeout_s=20.0)

            favicon_state = _wait_browser_favicon(client, browser_surface_id, timeout_s=14.0)
            _must(bool(favicon_state.get("has_favicon")), f"browser favicon state never became ready: {favicon_state}")
            _must(bool(str(favicon_state.get('png_base64') or "")), f"browser favicon PNG payload missing: {favicon_state}")

            print("PASS: remote browser favicon state loads for remote localhost pages over the SSH proxy")
            return 0
    finally:
        if remote_surface_id and remote_workspace_id:
            try:
                cleanup = (
                    f"pkill -f {server_script_path} >/dev/null 2>&1 || true; "
                    f"rm -f {server_script_path} {server_log_path} {hit_file_path}"
                )
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
