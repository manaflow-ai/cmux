#!/usr/bin/env python3
"""Docker integration: remote SSH port discovery + local forwarding via `cmux ssh`."""

from __future__ import annotations

import glob
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
REMOTE_HTTP_PORT = int(os.environ.get("CMUX_SSH_TEST_REMOTE_HTTP_PORT", "43173"))
MAX_REMOTE_DAEMON_SIZE_BYTES = int(os.environ.get("CMUX_SSH_TEST_MAX_DAEMON_SIZE_BYTES", "15000000"))


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


def _parse_host_port(docker_port_output: str) -> int:
    # docker port output form: "127.0.0.1:49154\n" or ":::\d+".
    text = docker_port_output.strip()
    if not text:
        raise cmuxError("docker port output was empty")
    last = text.split(":")[-1]
    return int(last)


def _http_get(url: str, timeout: float = 2.0) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:  # nosec B310 - loopback URL in test only
        return resp.read().decode("utf-8", errors="replace")


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


def _remote_binary_size_bytes(host: str, host_port: int, key_path: Path, remote_path: str) -> int:
    script = f"""
set -eu
p={_shell_single_quote(remote_path)}
case "$p" in
  /*) full="$p" ;;
  *) full="$HOME/$p" ;;
esac
test -x "$full"
wc -c < "$full"
"""
    proc = _ssh_run(host, host_port, key_path, script, check=True)
    text = proc.stdout.strip().splitlines()[-1].strip()
    return int(text)


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-docker-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-test-{secrets.token_hex(4)}"
    workspace_id = ""

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
            "-e", f"REMOTE_HTTP_PORT={REMOTE_HTTP_PORT}",
            "-p", "127.0.0.1::22",
            image_tag,
        ])

        port_info = _run(["docker", "port", container_name, "22/tcp"]).stdout
        host_ssh_port = _parse_host_port(port_info)
        host = "root@127.0.0.1"
        _wait_for_ssh(host, host_ssh_port, key_path)

        fresh_check = _ssh_run(
            host,
            host_ssh_port,
            key_path,
            "test ! -e \"$HOME/.cmux/bin/cmuxd-remote\" && echo fresh",
            check=True,
        )
        _must("fresh" in fresh_check.stdout, "Fresh container should not have preinstalled cmuxd-remote")

        with cmux(SOCKET_PATH) as client:
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name", "docker-ssh-forward",
                    "--port", str(host_ssh_port),
                    "--identity", str(key_path),
                    "--ssh-option", "UserKnownHostsFile=/dev/null",
                    "--ssh-option", "StrictHostKeyChecking=no",
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

            deadline = time.time() + 30.0
            last_status = {}
            while time.time() < deadline:
                last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
                remote = last_status.get("remote") or {}
                forwarded = set(int(x) for x in (remote.get("forwarded_ports") or []) if str(x).isdigit())
                state = str(remote.get("state") or "")
                if REMOTE_HTTP_PORT in forwarded and state == "connected":
                    break
                time.sleep(0.5)
            else:
                raise cmuxError(f"Remote port forwarding did not converge: {last_status}")

            daemon = ((last_status.get("remote") or {}).get("daemon") or {})
            _must(str(daemon.get("state") or "") == "ready", f"daemon should be ready in connected state: {last_status}")
            capabilities = daemon.get("capabilities") or []
            _must("session.basic" in capabilities, f"daemon hello capabilities missing session.basic: {daemon}")
            remote_path = str(daemon.get("remote_path") or "").strip()
            _must(bool(remote_path), f"daemon ready state should include remote_path: {daemon}")

            binary_size_bytes = _remote_binary_size_bytes(host, host_ssh_port, key_path, remote_path)
            _must(binary_size_bytes > 0, f"uploaded daemon binary should be non-empty: {binary_size_bytes}")
            _must(
                binary_size_bytes <= MAX_REMOTE_DAEMON_SIZE_BYTES,
                f"uploaded daemon binary too large: {binary_size_bytes} bytes > {MAX_REMOTE_DAEMON_SIZE_BYTES}",
            )

            body = ""
            deadline_http = time.time() + 15.0
            while time.time() < deadline_http:
                try:
                    body = _http_get(f"http://127.0.0.1:{REMOTE_HTTP_PORT}/")
                except Exception:
                    time.sleep(0.5)
                    continue
                if "cmux-ssh-forward-ok" in body:
                    break
                time.sleep(0.3)

            _must("cmux-ssh-forward-ok" in body, f"Forwarded HTTP endpoint returned unexpected body: {body[:120]!r}")

            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
            workspace_id = ""

        print(
            "PASS: docker SSH remote port is auto-detected and reachable through local forwarding; "
            f"uploaded cmuxd-remote size={binary_size_bytes} bytes"
        )
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
