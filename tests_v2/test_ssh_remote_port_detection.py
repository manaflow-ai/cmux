#!/usr/bin/env python3
"""Docker integration: remote SSH workspaces detect listening ports from the live shell."""

from __future__ import annotations

import glob
import json
import os
import pty
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


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
DOCKER_SSH_HOST = os.environ.get("CMUX_SSH_TEST_DOCKER_HOST", "127.0.0.1")
DOCKER_PUBLISH_ADDR = os.environ.get("CMUX_SSH_TEST_DOCKER_BIND_ADDR", "127.0.0.1")
REMOTE_HTTP_PORT = int(os.environ.get("CMUX_SSH_TEST_REMOTE_HTTP_PORT", "8000"))
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
OSC_ESCAPE_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


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
    env.pop("CMUX_SOCKET_PATH", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    proc = _run([cli, "--socket", SOCKET_PATH, "--json", *args], env=env)
    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})") from exc


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


def _wait_remote_ready(client: cmux, workspace_id: str, timeout: float = 45.0) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        daemon = remote.get("daemon") or {}
        if str(remote.get("state") or "") == "connected" and str(daemon.get("state") or "") == "ready":
            return last_status
        time.sleep(0.5)
    raise cmuxError(f"Remote did not reach connected+ready state: {last_status}")


def _is_terminal_surface_not_found(exc: Exception) -> bool:
    return "terminal surface not found" in str(exc).lower()


def _clean_text(raw: str) -> str:
    text = OSC_ESCAPE_RE.sub("", raw)
    text = ANSI_ESCAPE_RE.sub("", text)
    return text.replace("\r", "")


def _wait_surface_contains(
    client: cmux,
    workspace_id: str,
    surface_id: str,
    token: str,
    *,
    timeout: float = 20.0,
) -> None:
    deadline = time.time() + timeout
    saw_missing_surface = False
    while time.time() < deadline:
        try:
            payload = client._call(
                "surface.read_text",
                {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
            ) or {}
            text = _clean_text(str(payload.get("text") or ""))
            if token in text:
                return
        except cmuxError as exc:
            if _is_terminal_surface_not_found(exc):
                saw_missing_surface = True
                time.sleep(0.2)
                continue
            raise
        time.sleep(0.2)

    if saw_missing_surface:
        raise cmuxError("terminal surface not found")
    raise cmuxError(f"Timed out waiting for terminal token: {token}")


def _workspace_row(client: cmux, workspace_id: str) -> dict:
    payload = client._call("workspace.list", {}) or {}
    for row in payload.get("workspaces") or []:
        if str(row.get("id") or "") == workspace_id:
            return row
    raise cmuxError(f"workspace {workspace_id} missing from workspace.list payload: {payload}")


def _debug_terminal_row(client: cmux, workspace_id: str, surface_id: str) -> dict:
    payload = client._call("debug.terminals", {}) or {}
    for row in payload.get("terminals") or []:
        if str(row.get("workspace_id") or "") == workspace_id and str(row.get("surface_id") or "") == surface_id:
            return row
    raise cmuxError(
        f"debug.terminals missing workspace={workspace_id!r} surface={surface_id!r}: {payload}"
    )


def _wait_surface_tty(client: cmux, workspace_id: str, surface_id: str, timeout: float = 20.0) -> str:
    deadline = time.time() + timeout
    last_row = {}
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            last_row = _debug_terminal_row(client, workspace_id, surface_id)
        except cmuxError as exc:
            last_error = exc
            time.sleep(0.2)
            continue
        tty_name = str(last_row.get("tty") or "").strip()
        if tty_name:
            return tty_name
        time.sleep(0.2)
    if last_error is not None:
        raise cmuxError(f"Timed out waiting for surface tty after terminal lookup retries: {last_error}")
    raise cmuxError(f"Timed out waiting for surface tty: {last_row}")


def _launch_startup_command_pty(startup_command: str, workspace_id: str, surface_id: str) -> tuple[subprocess.Popen[bytes], int]:
    _must(bool(startup_command.strip()), "cmux ssh output missing ssh_terminal_startup_command for PTY fallback")
    env = dict(os.environ)
    env.pop("CMUX_SOCKET_PATH", None)
    env["CMUX_WORKSPACE_ID"] = workspace_id
    env["CMUX_SURFACE_ID"] = surface_id
    env["CMUX_TAB_ID"] = workspace_id
    env["CMUX_PANEL_ID"] = surface_id

    master_fd, slave_fd = pty.openpty()
    try:
        proc = subprocess.Popen(
            ["/bin/sh", "-lc", startup_command],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=env,
            start_new_session=True,
        )
    except Exception:
        os.close(slave_fd)
        os.close(master_fd)
        raise
    os.close(slave_fd)
    return proc, master_fd


def _wait_for_remote_port(client: cmux, workspace_id: str, port: int, timeout: float = 15.0) -> tuple[dict, dict]:
    deadline = time.time() + timeout
    last_status = {}
    last_row = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        detected_ports = {
            int(value)
            for value in (remote.get("detected_ports") or [])
            if str(value).isdigit()
        }

        last_row = _workspace_row(client, workspace_id)
        listening_ports = {
            int(value)
            for value in (last_row.get("listening_ports") or [])
            if str(value).isdigit()
        }

        if port in detected_ports and port in listening_ports:
            return last_status, last_row
        time.sleep(0.4)

    raise cmuxError(
        "Remote listening port did not surface in remote status + workspace list: "
        f"status={last_status} workspace={last_row}"
    )


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-port-detection-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-port-detect-{secrets.token_hex(4)}"
    workspace_id = ""
    surface_id = ""
    pty_proc: subprocess.Popen[bytes] | None = None
    pty_master_fd: int | None = None

    try:
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = (key_path.with_suffix(".pub")).read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        _run(["docker", "build", "-t", image_tag, str(fixture_dir)])
        _run([
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
        ])

        port_info = _run(["docker", "port", container_name, "22/tcp"]).stdout
        host_ssh_port = _parse_host_port(port_info)
        host = f"root@{DOCKER_SSH_HOST}"
        _wait_for_ssh(host, host_ssh_port, key_path)

        with cmux(SOCKET_PATH) as client:
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name",
                    "docker-ssh-port-detection",
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

            ready_status = _wait_remote_ready(client, workspace_id)
            initial_remote = ready_status.get("remote") or {}
            initial_detected_ports = {
                int(value)
                for value in (initial_remote.get("detected_ports") or [])
                if str(value).isdigit()
            }
            listed = client._call("workspace.list", {}) or {}
            initial_row = next(
                (row for row in (listed.get("workspaces") or []) if str(row.get("id") or "") == workspace_id),
                {},
            )
            initial_listening_ports = {
                int(value)
                for value in (initial_row.get("listening_ports") or [])
                if str(value).isdigit()
            }
            _must(
                not initial_detected_ports,
                f"remote SSH workspace should not surface unrelated startup ports before the shell opens one: {ready_status}",
            )
            _must(
                not initial_listening_ports,
                f"workspace.list should not leak unrelated startup ports before the shell opens one: {initial_row}",
            )

            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"workspace should have at least one surface: {workspace_id}")
            surface_id = str(surfaces[0][1])
            startup_command = str(payload.get("ssh_terminal_startup_command") or "")

            server_started_via_surface = True
            try:
                client.send_surface(surface_id, f"python3 -m http.server {REMOTE_HTTP_PORT}\n")
                _wait_surface_contains(client, workspace_id, surface_id, f"port {REMOTE_HTTP_PORT}", timeout=20.0)
            except cmuxError as exc:
                if _is_terminal_surface_not_found(exc):
                    print("WARN: readable terminal surface unavailable; falling back to generated ssh startup command PTY")
                    server_started_via_surface = False
                else:
                    raise

            if not server_started_via_surface:
                pty_proc, pty_master_fd = _launch_startup_command_pty(startup_command, workspace_id, surface_id)
                _wait_surface_tty(client, workspace_id, surface_id, timeout=20.0)
                os.write(pty_master_fd, f"python3 -m http.server {REMOTE_HTTP_PORT}\n".encode("utf-8"))

            status, row = _wait_for_remote_port(client, workspace_id, REMOTE_HTTP_PORT, timeout=15.0)
            remote = status.get("remote") or {}
            detected_ports = {
                int(value)
                for value in (remote.get("detected_ports") or [])
                if str(value).isdigit()
            }
            listening_ports = {
                int(value)
                for value in (row.get("listening_ports") or [])
                if str(value).isdigit()
            }
            _must(
                REMOTE_HTTP_PORT in detected_ports,
                f"remote status should include detected port {REMOTE_HTTP_PORT}: {status}",
            )
            _must(
                REMOTE_HTTP_PORT in listening_ports,
                f"workspace.list should include listening port {REMOTE_HTTP_PORT}: {row}",
            )

            if surface_id:
                if pty_master_fd is not None:
                    os.write(pty_master_fd, b"\x03")
                else:
                    client.send_key_surface(surface_id, "ctrl-c")
            if workspace_id:
                try:
                    client.close_workspace(workspace_id)
                    workspace_id = ""
                except Exception:
                    pass

        print("PASS: remote SSH workspace surfaces listening ports from the live remote shell")
        return 0

    finally:
        if pty_master_fd is not None:
            try:
                os.close(pty_master_fd)
            except OSError:
                pass
        if pty_proc is not None:
            if pty_proc.poll() is None:
                pty_proc.terminate()
                try:
                    pty_proc.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    pty_proc.kill()

        if surface_id and workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.send_key_surface(surface_id, "ctrl-c")
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
