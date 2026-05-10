#!/usr/bin/env python3
"""Regression: image drops into cmux ssh terminals upload to the remote host."""

from __future__ import annotations

import base64
import glob
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
DEFAULT_CMD_TIMEOUT = float(os.environ.get("CMUX_TEST_CMD_TIMEOUT", "60"))
SLOW_CMD_TIMEOUT = float(os.environ.get("CMUX_TEST_SLOW_CMD_TIMEOUT", "300"))


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _run(
    cmd: list[str],
    *,
    check: bool = True,
    timeout: float | None = DEFAULT_CMD_TIMEOUT,
) -> subprocess.CompletedProcess[str]:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise cmuxError(f"Command timed out after {timeout}s ({' '.join(cmd)})") from exc
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
    candidates = [path for path in candidates if os.path.isfile(path) and os.access(path, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda path: os.path.getmtime(path), reverse=True)
    return candidates[0]


def _docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    return _run(["docker", "info"], check=False).returncode == 0


def _shell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _ssh_run(
    host: str,
    host_port: int,
    key_path: Path,
    script: str,
    *,
    check: bool = True,
    timeout: float | None = DEFAULT_CMD_TIMEOUT,
) -> subprocess.CompletedProcess[str]:
    return _run(
        [
            "ssh",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=5",
            "-p", str(host_port),
            "-i", str(key_path),
            host,
            f"sh -lc {_shell_single_quote(script)}",
        ],
        check=check,
        timeout=timeout,
    )


def _wait_for_ssh(host: str, host_port: int, key_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        probe = _ssh_run(host, host_port, key_path, "echo ready", check=False, timeout=10)
        if probe.returncode == 0 and "ready" in probe.stdout:
            return
        time.sleep(0.4)
    raise cmuxError("Timed out waiting for SSH server in docker fixture")


def _wait_remote_ready(client: cmux, workspace_id: str, timeout: float = 45.0) -> None:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        daemon = remote.get("daemon") or {}
        if str(remote.get("state") or "") == "connected" and str(daemon.get("state") or "") == "ready":
            return
        time.sleep(0.25)
    raise cmuxError(f"Remote did not become ready for {workspace_id}: {last_status}")


def _run_cli_json(
    cli: str,
    args: list[str],
    *,
    timeout: float | None = DEFAULT_CMD_TIMEOUT,
) -> dict:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    try:
        proc = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "--json", "--id-format", "both", *args],
            capture_output=True,
            text=True,
            env=env,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise cmuxError(f"cmux {' '.join(args)} timed out after {timeout}s") from exc
    if proc.returncode != 0:
        raise cmuxError(f"cmux {' '.join(args)} failed: {(proc.stdout + proc.stderr).strip()}")
    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})") from exc


def _resolve_workspace_id(client: cmux, payload: dict) -> str:
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

    raise cmuxError(f"Unable to resolve workspace_id from payload: {payload}")


def _focused_surface_id(client: cmux) -> str:
    ident = client.identify()
    surface_id = str((ident.get("focused") or {}).get("surface_id") or "")
    _must(bool(surface_id), f"Missing focused surface in identify payload: {ident}")
    return surface_id


def _wait_for_remote_drop_path(client: cmux, surface_id: str, timeout: float = 20.0) -> str:
    pattern = re.compile(r"/tmp/cmux-drop-[0-9a-f-]+\.png")
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        last = client.read_terminal_text(surface_id)
        match = pattern.search(last)
        if match:
            return match.group(0)
        time.sleep(0.25)
    raise cmuxError(f"Timed out waiting for remote drop path in terminal text: {last[-1000:]!r}")


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-image-drop-"))
    image_tag = f"cmux-ssh-image-drop:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-image-drop-{secrets.token_hex(4)}"
    workspace_id = ""

    try:
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = key_path.with_suffix(".pub").read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        _run(["docker", "build", "-t", image_tag, str(fixture_dir)], timeout=SLOW_CMD_TIMEOUT)
        _run([
            "docker", "run", "-d", "--rm",
            "--name", container_name,
            "-e", f"AUTHORIZED_KEY={pubkey}",
            "-p", "127.0.0.1::22",
            image_tag,
        ])

        host_ssh_port = int(_run(["docker", "port", container_name, "22/tcp"]).stdout.strip().split(":")[-1])
        host = "root@127.0.0.1"
        _wait_for_ssh(host, host_ssh_port, key_path)

        with cmux(SOCKET_PATH) as client:
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name", f"ssh-image-drop-{secrets.token_hex(4)}",
                    "--port", str(host_ssh_port),
                    "--identity", str(key_path),
                    "--ssh-option", "UserKnownHostsFile=/dev/null",
                    "--ssh-option", "StrictHostKeyChecking=no",
                ],
                timeout=90,
            )
            workspace_id = _resolve_workspace_id(client, payload)
            _wait_remote_ready(client, workspace_id)
            client.select_workspace(workspace_id)

            image_path = temp_dir / "dragged-image.png"
            image_path.write_bytes(base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lS2cWQAAAABJRU5ErkJggg=="
            ))
            local_sha = hashlib.sha256(image_path.read_bytes()).hexdigest()

            surface_id = _focused_surface_id(client)
            client.simulate_terminal_file_drop(surface_id, [str(image_path)], route="text_destination")
            remote_path = _wait_for_remote_drop_path(client, surface_id)

        remote_sha = _ssh_run(
            host,
            host_ssh_port,
            key_path,
            f"sha256sum {_shell_single_quote(remote_path)}",
        ).stdout.split()[0]
        _must(
            remote_sha == local_sha,
            f"Uploaded file hash mismatch local={local_sha} remote={remote_sha} path={remote_path}",
        )
        print(f"PASS: ssh image drop uploaded {remote_path}")
        return 0
    finally:
        if workspace_id:
            _run([cli, "--socket", SOCKET_PATH, "close-workspace", "--workspace", workspace_id], check=False)
        _run(["docker", "rm", "-f", container_name], check=False)
        _run(["docker", "rmi", "-f", image_tag], check=False)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
