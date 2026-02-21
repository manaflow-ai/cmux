#!/usr/bin/env python3
"""Docker integration: remote SSH reconnect after host restart."""

from __future__ import annotations

import glob
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
REMOTE_HTTP_PORT = int(os.environ.get("CMUX_SSH_TEST_REMOTE_HTTP_PORT", "43174"))


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


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


def _run(cmd: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, check=False)
    if check and proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"Command failed ({' '.join(cmd)}): {merged}")
    return proc


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


def _docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    probe = _run(["docker", "info"], check=False)
    return probe.returncode == 0


def _http_get(url: str, timeout: float = 2.0) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:  # nosec B310 - test loopback endpoint only
        return resp.read().decode("utf-8", errors="replace")


def _find_free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _start_container(image_tag: str, container_name: str, pubkey: str, host_ssh_port: int) -> None:
    for _ in range(20):
        proc = _run(
            [
                "docker",
                "run",
                "-d",
                "--rm",
                "--name",
                container_name,
                "-e",
                f"AUTHORIZED_KEY={pubkey}",
                "-e",
                f"REMOTE_HTTP_PORT={REMOTE_HTTP_PORT}",
                "-p",
                f"127.0.0.1:{host_ssh_port}:22",
                image_tag,
            ],
            check=False,
        )
        if proc.returncode == 0:
            return
        time.sleep(0.5)
    merged = f"{proc.stdout}\n{proc.stderr}".strip()
    raise cmuxError(f"Failed to start ssh test container on fixed port {host_ssh_port}: {merged}")


def _wait_remote_connected(client: cmux, workspace_id: str, timeout: float) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        forwarded = set(int(x) for x in (remote.get("forwarded_ports") or []) if str(x).isdigit())
        if str(remote.get("state") or "") == "connected" and REMOTE_HTTP_PORT in forwarded:
            return last_status
        time.sleep(0.5)
    raise cmuxError(f"Remote did not reach connected+forwarded state: {last_status}")


def _wait_remote_degraded(client: cmux, workspace_id: str, timeout: float) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        state = str(remote.get("state") or "")
        if state in {"error", "connecting", "disconnected"}:
            return last_status
        time.sleep(0.5)
    raise cmuxError(f"Remote did not enter reconnecting/degraded state: {last_status}")


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-reconnect-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-reconnect-{secrets.token_hex(4)}"
    host_ssh_port = _find_free_loopback_port()
    workspace_id = ""
    container_running = False

    try:
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = (key_path.with_suffix(".pub")).read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        _run(["docker", "build", "-t", image_tag, str(fixture_dir)])
        _start_container(image_tag, container_name, pubkey, host_ssh_port)
        container_running = True

        with cmux(SOCKET_PATH) as client:
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    "root@127.0.0.1",
                    "--name",
                    "docker-ssh-reconnect",
                    "--port",
                    str(host_ssh_port),
                    "--identity",
                    str(key_path),
                    "--ssh-option",
                    "UserKnownHostsFile=/dev/null",
                    "--ssh-option",
                    "StrictHostKeyChecking=no",
                ],
            )
            workspace_id = str(payload.get("workspace_id") or "")
            workspace_ref = str(payload.get("workspace_ref") or "")
            if not workspace_id and workspace_ref.startswith("workspace:"):
                listed = client._call("workspace.list", {}) or {}
                for row in listed.get("workspaces") or []:
                    if str(row.get("ref") or "") == workspace_ref:
                        workspace_id = str(row.get("id") or "")
                        break
            _must(bool(workspace_id), f"cmux ssh output missing workspace_id: {payload}")

            first_status = _wait_remote_connected(client, workspace_id, timeout=45.0)
            first_daemon = ((first_status.get("remote") or {}).get("daemon") or {})
            _must(str(first_daemon.get("state") or "") == "ready", f"daemon should be ready after first connect: {first_status}")

            first_body = ""
            first_deadline_http = time.time() + 15.0
            while time.time() < first_deadline_http:
                try:
                    first_body = _http_get(f"http://127.0.0.1:{REMOTE_HTTP_PORT}/")
                except Exception:
                    time.sleep(0.5)
                    continue
                if "cmux-ssh-forward-ok" in first_body:
                    break
                time.sleep(0.3)
            _must("cmux-ssh-forward-ok" in first_body, f"Forwarded HTTP endpoint failed before reconnect: {first_body[:120]!r}")

            _run(["docker", "rm", "-f", container_name], check=False)
            container_running = False
            _wait_remote_degraded(client, workspace_id, timeout=20.0)

            _start_container(image_tag, container_name, pubkey, host_ssh_port)
            container_running = True

            second_status = _wait_remote_connected(client, workspace_id, timeout=60.0)
            second_daemon = ((second_status.get("remote") or {}).get("daemon") or {})
            _must(str(second_daemon.get("state") or "") == "ready", f"daemon should be ready after reconnect: {second_status}")

            second_body = ""
            deadline_http = time.time() + 15.0
            while time.time() < deadline_http:
                try:
                    second_body = _http_get(f"http://127.0.0.1:{REMOTE_HTTP_PORT}/")
                except Exception:
                    time.sleep(0.5)
                    continue
                if "cmux-ssh-forward-ok" in second_body:
                    break
                time.sleep(0.3)
            _must("cmux-ssh-forward-ok" in second_body, f"Forwarded HTTP endpoint failed after reconnect: {second_body[:120]!r}")

            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
            workspace_id = ""

        print("PASS: docker SSH remote reconnects and re-establishes forwarded ports")
        return 0

    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

        if container_running:
            _run(["docker", "rm", "-f", container_name], check=False)
        _run(["docker", "rmi", "-f", image_tag], check=False)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
