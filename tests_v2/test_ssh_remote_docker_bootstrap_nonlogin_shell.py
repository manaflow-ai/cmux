#!/usr/bin/env python3
"""Docker integration: remote daemon bootstrap must not depend on login-shell startup files."""

from __future__ import annotations

import os
import secrets
import shutil
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
    return int(text.split(":")[-1])


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


def _wait_for_remote_connected(client: cmux, workspace_id: str, timeout: float = 45.0) -> dict:
    deadline = time.time() + timeout
    last_status: dict = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        daemon = remote.get("daemon") or {}
        proxy = remote.get("proxy") or {}
        if (
            str(remote.get("state") or "") == "connected"
            and str(daemon.get("state") or "") == "ready"
            and str(proxy.get("state") or "") == "ready"
        ):
            return last_status
        time.sleep(0.5)
    raise cmuxError(f"Remote did not converge to connected/ready under slow login profile: {last_status}")


def _heartbeat_count(status: dict) -> int:
    remote = status.get("remote") or {}
    heartbeat = remote.get("heartbeat") or {}
    raw = heartbeat.get("count")
    try:
        return int(raw or 0)
    except Exception:  # noqa: BLE001
        return 0


def _wait_for_heartbeat_advance(client: cmux, workspace_id: str, minimum_count: int, timeout: float = 20.0) -> dict:
    deadline = time.time() + timeout
    last_status: dict = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        if _heartbeat_count(last_status) >= minimum_count:
            return last_status
        time.sleep(0.5)
    raise cmuxError(
        f"Remote heartbeat did not advance to >= {minimum_count} within {timeout:.1f}s: {last_status}"
    )


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-bootstrap-nonlogin-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-bootstrap-nonlogin-{secrets.token_hex(4)}"
    workspace_id = ""

    try:
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = (key_path.with_suffix(".pub")).read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        _run(["docker", "build", "-t", image_tag, str(fixture_dir)])
        _run(
            [
                "docker",
                "run",
                "-d",
                "--rm",
                "--name",
                container_name,
                "-e",
                f"AUTHORIZED_KEY={pubkey}",
                "-p",
                f"{DOCKER_PUBLISH_ADDR}::22",
                image_tag,
            ]
        )

        port_info = _run(["docker", "port", container_name, "22/tcp"]).stdout
        host_ssh_port = _parse_host_port(port_info)
        host = f"root@{DOCKER_SSH_HOST}"
        _wait_for_ssh(host, host_ssh_port, key_path)

        # Regression fixture: a slow login profile that should not block non-interactive daemon bootstrap.
        _ssh_run(
            host,
            host_ssh_port,
            key_path,
            """
cat > "$HOME/.profile" <<'EOF'
sleep 15
echo profile-sourced >&2
EOF
chmod 0644 "$HOME/.profile"
""",
            check=True,
        )

        with cmux(SOCKET_PATH) as client:
            created = client._call("workspace.create", {"initial_command": "echo ssh-bootstrap-nonlogin"})
            workspace_id = str((created or {}).get("workspace_id") or "")
            _must(bool(workspace_id), f"workspace.create did not return workspace_id: {created}")

            configured = client._call(
                "workspace.remote.configure",
                {
                    "workspace_id": workspace_id,
                    "destination": host,
                    "port": host_ssh_port,
                    "identity_file": str(key_path),
                    "ssh_options": ["UserKnownHostsFile=/dev/null", "StrictHostKeyChecking=no"],
                    "auto_connect": True,
                },
            )
            _must(bool(configured), "workspace.remote.configure returned empty response")

            status = _wait_for_remote_connected(client, workspace_id, timeout=45.0)
            remote = status.get("remote") or {}
            detail = str(remote.get("detail") or "").lower()
            _must("timed out" not in detail, f"remote detail should not report bootstrap timeout: {status}")

            baseline_heartbeat = _heartbeat_count(status)
            status = _wait_for_heartbeat_advance(
                client,
                workspace_id,
                minimum_count=max(1, baseline_heartbeat + 1),
                timeout=15.0,
            )

            opened = client._call("browser.open_split", {"workspace_id": workspace_id}) or {}
            browser_surface_id = str(opened.get("surface_id") or "")
            _must(bool(browser_surface_id), f"browser.open_split returned no surface_id: {opened}")

            after_open_heartbeat = _heartbeat_count(status)
            status_after_blank_tab = _wait_for_heartbeat_advance(
                client,
                workspace_id,
                minimum_count=after_open_heartbeat + 2,
                timeout=20.0,
            )
            remote_after_blank_tab = status_after_blank_tab.get("remote") or {}
            _must(
                str(remote_after_blank_tab.get("state") or "") == "connected",
                f"remote should remain connected after blank browser open: {status_after_blank_tab}",
            )
            heartbeat_payload = remote_after_blank_tab.get("heartbeat") or {}
            _must(
                heartbeat_payload.get("last_seen_at") is not None,
                f"remote heartbeat should expose last_seen_at after bootstrap: {status_after_blank_tab}",
            )

            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
            workspace_id = ""

        print("PASS: remote daemon bootstrap remains healthy even when ~/.profile is slow")
        return 0
    finally:
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
