#!/usr/bin/env python3
"""Docker integration: prove cmux ssh applies Ghostty ssh-env/ssh-terminfo niceties."""

from __future__ import annotations

import glob
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


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


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


def _wait_remote_connected(client: cmux, workspace_id: str, timeout: float) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        daemon = remote.get("daemon") or {}
        if str(remote.get("state") or "") == "connected" and str(daemon.get("state") or "") == "ready":
            return last_status
        time.sleep(0.4)
    raise cmuxError(f"Remote did not reach connected+ready state: {last_status}")


def _read_probe_value(client: cmux, surface_id: str, command: str, timeout: float = 20.0) -> str:
    token = f"__CMUX_PROBE_{secrets.token_hex(6)}__"
    client.send_surface(surface_id, f"{command}; printf '{token}%s\\n' $?\\n")

    pattern = re.compile(re.escape(token) + r"([^\r\n]*)")
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = client.read_terminal_text(surface_id)
        matches = pattern.findall(text)
        for raw in reversed(matches):
            value = raw.strip()
            if value and value != "%s" and "$(" not in value and "printf" not in value:
                return value
        time.sleep(0.2)

    raise cmuxError(f"Timed out waiting for probe token for command: {command}")


def _read_probe_payload(client: cmux, surface_id: str, payload_command: str, timeout: float = 20.0) -> str:
    token = f"__CMUX_PAYLOAD_{secrets.token_hex(6)}__"
    client.send_surface(surface_id, f"printf '{token}%s\\n' \"$({payload_command})\"\\n")

    pattern = re.compile(re.escape(token) + r"([^\r\n]*)")
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = client.read_terminal_text(surface_id)
        matches = pattern.findall(text)
        for raw in reversed(matches):
            value = raw.strip()
            if value and value != "%s" and "$(" not in value and "printf" not in value:
                return value
        time.sleep(0.2)

    raise cmuxError(f"Timed out waiting for payload token for command: {payload_command}")


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0
    if shutil.which("infocmp") is None:
        print("SKIP: local infocmp is not available (required for ssh-terminfo)")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-shell-integration-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-shell-{secrets.token_hex(4)}"
    workspace_id = ""

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
            "127.0.0.1::22",
            image_tag,
        ])

        port_info = _run(["docker", "port", container_name, "22/tcp"]).stdout
        host_ssh_port = _parse_host_port(port_info)
        host = "root@127.0.0.1"
        if shutil.which("ghostty") is not None:
            _run(["ghostty", "+ssh-cache", f"--remove={host}"], check=False)
        _wait_for_ssh(host, host_ssh_port, key_path)

        pre = _ssh_run(host, host_ssh_port, key_path, "if infocmp xterm-ghostty >/dev/null 2>&1; then echo present; else echo missing; fi")
        _must("missing" in pre.stdout, f"Fresh container should not have xterm-ghostty terminfo preinstalled: {pre.stdout!r}")

        with cmux(SOCKET_PATH) as client:
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name",
                    "docker-ssh-shell-integration",
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

            _wait_remote_connected(client, workspace_id, timeout=45.0)

            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"workspace should have at least one surface: {workspace_id}")
            surface_id = surfaces[0][1]

            term_value = _read_probe_payload(client, surface_id, "printf '%s' \"$TERM\"")
            terminfo_state = _read_probe_value(client, surface_id, "infocmp xterm-ghostty >/dev/null 2>&1")
            _must(terminfo_state in {"0", "1"}, f"unexpected terminfo probe exit status: {terminfo_state!r}")
            if terminfo_state == "0":
                _must(
                    term_value == "xterm-ghostty",
                    f"when terminfo install succeeds, TERM should remain xterm-ghostty (got {term_value!r})",
                )
            else:
                _must(
                    term_value == "xterm-256color",
                    f"when terminfo is unavailable, ssh-env fallback should use TERM=xterm-256color (got {term_value!r})",
                )

            colorterm_value = _read_probe_payload(client, surface_id, "printf '%s' \"${COLORTERM:-}\"")
            _must(
                colorterm_value == "truecolor",
                f"ssh-env should propagate COLORTERM=truecolor, got: {colorterm_value!r}",
            )

            term_program = _read_probe_payload(client, surface_id, "printf '%s' \"${TERM_PROGRAM:-}\"")
            _must(
                term_program == "ghostty",
                f"ssh-env should propagate TERM_PROGRAM=ghostty when AcceptEnv allows it, got: {term_program!r}",
            )

            term_program_version = _read_probe_payload(client, surface_id, "printf '%s' \"${TERM_PROGRAM_VERSION:-}\"")
            _must(bool(term_program_version), "ssh-env should propagate non-empty TERM_PROGRAM_VERSION")

            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
            workspace_id = ""

        print(
            "PASS: cmux ssh enables Ghostty shell integration niceties "
            f"(TERM={term_value}, COLORTERM={colorterm_value}, TERM_PROGRAM={term_program})"
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
