#!/usr/bin/env python3
"""Docker integration: local proxy bind conflict surfaces proxy_unavailable."""

from __future__ import annotations

import glob
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
DOCKER_SSH_HOST = os.environ.get("CMUX_SSH_TEST_DOCKER_HOST", "127.0.0.1")
DOCKER_PUBLISH_ADDR = os.environ.get("CMUX_SSH_TEST_DOCKER_BIND_ADDR", "127.0.0.1")


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


def _docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    probe = _run(["docker", "info"], check=False)
    return probe.returncode == 0


def _parse_host_port(docker_port_output: str) -> int:
    text = docker_port_output.strip()
    if not text:
        raise cmuxError("docker port output was empty")
    last = text.split(":")[-1]
    return int(last)


def _shell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _ssh_run(host: str, host_port: int, key_path: Path, script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return _run(
        [
            "ssh",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "ConnectTimeout=5",
            "-p",
            str(host_port),
            "-i",
            str(key_path),
            host,
            f"sh -lc {_shell_single_quote(script)}",
        ],
        check=check,
    )


def _wait_for_ssh(host: str, host_port: int, key_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        probe = _ssh_run(host, host_port, key_path, "echo ready", check=False)
        if probe.returncode == 0 and "ready" in probe.stdout:
            return
        time.sleep(0.5)
    raise cmuxError("Timed out waiting for SSH server in docker fixture to become ready")


def _find_free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _wait_for_proxy_conflict_status(client: cmux, workspace_id: str, expected_local_proxy_port: int, timeout: float = 30.0) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        proxy = remote.get("proxy") or {}
        daemon = remote.get("daemon") or {}
        if str(remote.get("state") or "") == "error" and str(proxy.get("state") or "") == "error":
            detail = str(remote.get("detail") or "")
            _must(
                proxy.get("error_code") == "proxy_unavailable",
                f"proxy error should be proxy_unavailable under bind conflict: {last_status}",
            )
            _must(
                int(remote.get("local_proxy_port") or 0) == expected_local_proxy_port,
                f"remote status should retain configured local_proxy_port under bind conflict: {last_status}",
            )
            _must(
                (
                    "Failed to start local daemon proxy" in detail
                    or "Local proxy listener failed" in detail
                ),
                f"remote detail should surface local proxy bind failure: {last_status}",
            )
            _must(
                "Address already in use" in detail,
                f"remote detail should preserve bind-conflict root cause: {last_status}",
            )
            _must(
                str(daemon.get("state") or "") == "ready",
                f"daemon should remain ready for local-only bind conflicts: {last_status}",
            )
            return last_status
        time.sleep(0.5)

    raise cmuxError(f"Remote did not reach structured proxy_unavailable status for bind conflict: {last_status}")


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    _ = _find_cli_binary()  # enforce same test prerequisites as other SSH remote suites
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-proxy-conflict-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-proxy-conflict-{secrets.token_hex(4)}"
    workspace_id = ""
    conflict_listener: socket.socket | None = None

    try:
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = (key_path.with_suffix(".pub")).read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        _run(["docker", "build", "-t", image_tag, str(fixture_dir)])
        _run([
            "docker", "run", "-d", "--rm",
            "--name", container_name,
            "-e", f"AUTHORIZED_KEY={pubkey}",
            "-p", f"{DOCKER_PUBLISH_ADDR}::22",
            image_tag,
        ])

        port_info = _run(["docker", "port", container_name, "22/tcp"]).stdout
        host_ssh_port = _parse_host_port(port_info)
        host = f"root@{DOCKER_SSH_HOST}"
        _wait_for_ssh(host, host_ssh_port, key_path)

        conflict_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        conflict_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        conflict_listener.bind(("127.0.0.1", 0))
        conflict_port = int(conflict_listener.getsockname()[1])
        conflict_listener.listen(1)

        with cmux(SOCKET_PATH) as client:
            created = client._call("workspace.create", {"initial_command": "echo ssh-proxy-conflict"})
            workspace_id = str((created or {}).get("workspace_id") or "")
            _must(bool(workspace_id), f"workspace.create did not return workspace_id: {created}")

            configured = client._call("workspace.remote.configure", {
                "workspace_id": workspace_id,
                "destination": host,
                "port": host_ssh_port,
                "identity_file": str(key_path),
                "ssh_options": ["UserKnownHostsFile=/dev/null", "StrictHostKeyChecking=no"],
                "auto_connect": True,
                "local_proxy_port": conflict_port,
            })
            _must(bool(configured), "workspace.remote.configure returned empty response")

            _ = _wait_for_proxy_conflict_status(
                client,
                workspace_id,
                expected_local_proxy_port=conflict_port,
                timeout=30.0,
            )

            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
            workspace_id = ""

        print("PASS: local proxy bind conflict surfaces structured proxy_unavailable without degrading daemon readiness")
        return 0

    finally:
        if conflict_listener is not None:
            try:
                conflict_listener.close()
            except Exception:
                pass

        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

        _run(["docker", "rm", "-f", container_name], check=False)
        _run(["docker", "rmi", "-f", image_tag], check=False)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
