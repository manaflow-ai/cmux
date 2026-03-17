#!/usr/bin/env python3
"""Docker integration: verify cmux CLI commands work over SSH via reverse socket forwarding."""

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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
# Keep the fixture's extra HTTP server below 1024 so there are no eligible
# (>1023) ports to auto-forward. This guards the "connecting forever" regression.
REMOTE_HTTP_PORT = int(os.environ.get("CMUX_SSH_TEST_REMOTE_HTTP_PORT", "81"))


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
    # Ensure --socket is what drives the relay path during tests.
    env.pop("CMUX_SOCKET_PATH", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    proc = _run([cli, "--socket", SOCKET_PATH, "--json", "--id-format", "both", *args], env=env)
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
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=5",
            "-p", str(host_port),
            "-i", str(key_path),
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


def _wait_for_remote_ready(client, workspace_id: str, timeout: float = 45.0) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        daemon = remote.get("daemon") or {}
        state = str(remote.get("state") or "")
        daemon_state = str(daemon.get("state") or "")
        if state == "connected" and daemon_state == "ready":
            return last_status
        time.sleep(0.5)
    raise cmuxError(f"Remote daemon did not become ready: {last_status}")


def _assert_remote_ping(host: str, host_port: int, key_path: Path, remote_socket_addr: str, *, label: str) -> None:
    ping_result = _ssh_run(
        host, host_port, key_path,
        f"CMUX_SOCKET_PATH={remote_socket_addr} $HOME/.cmux/bin/cmux ping",
        check=False,
    )
    _must(
        ping_result.returncode == 0 and "pong" in ping_result.stdout.lower(),
        f"{label} cmux ping failed: rc={ping_result.returncode} stdout={ping_result.stdout!r} stderr={ping_result.stderr!r}",
    )


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-cli-relay-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-cli-relay-{secrets.token_hex(4)}"
    workspace_id = ""
    workspace_id_2 = ""

    try:
        # Generate SSH key pair
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = (key_path.with_suffix(".pub")).read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        # Build and start Docker container
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

        with cmux(SOCKET_PATH) as client:
            # Create SSH workspace (this sets up the reverse socket forward)
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name", "docker-cli-relay",
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
            remote_relay_port = payload.get("remote_relay_port")
            _must(remote_relay_port is not None, f"cmux ssh output missing remote_relay_port: {payload}")
            remote_relay_port = int(remote_relay_port)
            _must(1 <= remote_relay_port <= 65535, f"remote_relay_port should be a valid TCP port: {remote_relay_port}")
            remote_socket_addr = f"127.0.0.1:{remote_relay_port}"
            startup_cmd = str(payload.get("ssh_startup_command") or "")
            _must(
                'PATH="$HOME/.cmux/bin:$PATH"' in startup_cmd,
                f"ssh startup command should prepend ~/.cmux/bin for remote cmux CLI: {startup_cmd!r}",
            )
            _must(
                f"CMUX_SOCKET_PATH={remote_socket_addr}" in startup_cmd,
                f"ssh startup command should pin CMUX_SOCKET_PATH to workspace relay: {startup_cmd!r}",
            )
            workspace_window_id = payload.get("window_id")
            current_params = {"window_id": workspace_window_id} if isinstance(workspace_window_id, str) and workspace_window_id else {}
            current = client._call("workspace.current", current_params) or {}
            current_workspace_id = str(current.get("workspace_id") or "")
            _must(
                current_workspace_id == workspace_id,
                f"cmux ssh should focus created workspace: current={current_workspace_id!r} created={workspace_id!r}",
            )

            # Wait for daemon to be ready
            first_status = _wait_for_remote_ready(client, workspace_id)
            first_remote = first_status.get("remote") or {}
            # Regression: should transition to connected even with no eligible
            # (>1023, non-ephemeral) remote ports.
            _must(
                not (first_remote.get("detected_ports") or []),
                f"expected no eligible detected ports in fixture: {first_status}",
            )
            _must(
                not (first_remote.get("forwarded_ports") or []),
                f"expected no forwarded ports when none are eligible: {first_status}",
            )

            # Verify remote cmux wrapper + relay-specific daemon mapping were installed.
            wrapper_check = None
            wrapper_deadline = time.time() + 10.0
            while time.time() < wrapper_deadline:
                wrapper_check = _ssh_run(
                    host, host_ssh_port, key_path,
                    f"test -x \"$HOME/.cmux/bin/cmux\" && test -f \"$HOME/.cmux/bin/cmux\" && "
                    f"map=\"$HOME/.cmux/relay/{remote_relay_port}.daemon_path\" && "
                    "daemon=\"$(cat \"$map\" 2>/dev/null || true)\" && "
                    "test -n \"$daemon\" && test -x \"$daemon\" && echo wrapper-ok",
                    check=False,
                )
                if "wrapper-ok" in (wrapper_check.stdout or ""):
                    break
                time.sleep(0.4)
            _must(
                wrapper_check is not None and "wrapper-ok" in (wrapper_check.stdout or ""),
                f"Expected remote cmux wrapper+relay mapping to exist: {wrapper_check.stdout if wrapper_check else ''} {wrapper_check.stderr if wrapper_check else ''}",
            )

            # Start a second SSH workspace to the same destination and verify both
            # relays remain healthy (regression: same-host workspaces killed each other).
            payload_2 = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name", "docker-cli-relay-2",
                    "--port", str(host_ssh_port),
                    "--identity", str(key_path),
                    "--ssh-option", "UserKnownHostsFile=/dev/null",
                    "--ssh-option", "StrictHostKeyChecking=no",
                ],
            )
            workspace_id_2 = str(payload_2.get("workspace_id") or "")
            workspace_ref_2 = str(payload_2.get("workspace_ref") or "")
            if not workspace_id_2 and workspace_ref_2.startswith("workspace:"):
                listed_2 = client._call("workspace.list", {}) or {}
                for row in listed_2.get("workspaces") or []:
                    if str(row.get("ref") or "") == workspace_ref_2:
                        workspace_id_2 = str(row.get("id") or "")
                        break
            _must(bool(workspace_id_2), f"second cmux ssh output missing workspace_id: {payload_2}")

            remote_relay_port_2 = payload_2.get("remote_relay_port")
            _must(remote_relay_port_2 is not None, f"second cmux ssh output missing remote_relay_port: {payload_2}")
            remote_relay_port_2 = int(remote_relay_port_2)
            _must(1 <= remote_relay_port_2 <= 65535, f"second remote_relay_port should be a valid TCP port: {remote_relay_port_2}")
            _must(
                remote_relay_port_2 != remote_relay_port,
                f"relay ports should differ per workspace: {remote_relay_port_2} vs {remote_relay_port}",
            )
            remote_socket_addr_2 = f"127.0.0.1:{remote_relay_port_2}"
            startup_cmd_2 = str(payload_2.get("ssh_startup_command") or "")
            _must(
                f"CMUX_SOCKET_PATH={remote_socket_addr_2}" in startup_cmd_2,
                f"second ssh startup command should pin CMUX_SOCKET_PATH to second relay: {startup_cmd_2!r}",
            )
            _ = _wait_for_remote_ready(client, workspace_id_2)

            stability_deadline = time.time() + 8.0
            while time.time() < stability_deadline:
                _assert_remote_ping(host, host_ssh_port, key_path, remote_socket_addr, label="first relay")
                _assert_remote_ping(host, host_ssh_port, key_path, remote_socket_addr_2, label="second relay")
                time.sleep(0.5)

            # Test 1: cmux ping (v1)
            _assert_remote_ping(host, host_ssh_port, key_path, remote_socket_addr, label="cmux")

            # Test 2: cmux list-workspaces --json (v2)
            list_ws_result = _ssh_run(
                host, host_ssh_port, key_path,
                f"CMUX_SOCKET_PATH={remote_socket_addr} $HOME/.cmux/bin/cmux --json list-workspaces",
                check=False,
            )
            _must(
                list_ws_result.returncode == 0,
                f"cmux list-workspaces failed: rc={list_ws_result.returncode} stderr={list_ws_result.stderr!r}",
            )
            try:
                ws_data = json.loads(list_ws_result.stdout.strip())
                _must(isinstance(ws_data, dict), f"list-workspaces should return JSON object: {list_ws_result.stdout!r}")
            except json.JSONDecodeError:
                raise cmuxError(f"list-workspaces returned invalid JSON: {list_ws_result.stdout!r}")

            # Test 3: cmux new-window (v1)
            new_win_result = _ssh_run(
                host, host_ssh_port, key_path,
                f"CMUX_SOCKET_PATH={remote_socket_addr} $HOME/.cmux/bin/cmux new-window",
                check=False,
            )
            _must(
                new_win_result.returncode == 0,
                f"cmux new-window failed: rc={new_win_result.returncode} stderr={new_win_result.stderr!r}",
            )

            # Test 4: cmux rpc system.capabilities (v2 passthrough)
            rpc_result = _ssh_run(
                host, host_ssh_port, key_path,
                f"CMUX_SOCKET_PATH={remote_socket_addr} $HOME/.cmux/bin/cmux rpc system.capabilities",
                check=False,
            )
            _must(
                rpc_result.returncode == 0,
                f"cmux rpc system.capabilities failed: rc={rpc_result.returncode} stderr={rpc_result.stderr!r}",
            )
            try:
                caps_data = json.loads(rpc_result.stdout.strip())
                _must(isinstance(caps_data, dict), f"rpc capabilities should return JSON: {rpc_result.stdout!r}")
            except json.JSONDecodeError:
                raise cmuxError(f"rpc system.capabilities returned invalid JSON: {rpc_result.stdout!r}")

            # Cleanup
            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
            workspace_id = ""
            if workspace_id_2:
                try:
                    client.close_workspace(workspace_id_2)
                except Exception:
                    pass
                workspace_id_2 = ""

        print("PASS: cmux CLI commands relay correctly over SSH reverse socket forwarding")
        return 0

    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass
        if workspace_id_2:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id_2)
            except Exception:
                pass

        _run(["docker", "rm", "-f", container_name], check=False)
        _run(["docker", "rmi", "-f", image_tag], check=False)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
