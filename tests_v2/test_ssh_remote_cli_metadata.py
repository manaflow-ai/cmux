#!/usr/bin/env python3
"""Regression: `cmux ssh` creates a remote-tagged workspace with remote metadata."""

import glob
import json
import os
import re
import subprocess
import sys
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


def _run_cli(cli: str, args: list[str], *, json_output: bool) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH]
    if json_output:
        cmd.append("--json")
    cmd.extend(args)
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def _run_cli_json(cli: str, args: list[str]) -> dict:
    output = _run_cli(cli, args, json_output=True)
    try:
        return json.loads(output or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {output!r} ({exc})")


def _extract_control_path(ssh_command: str) -> str:
    match = re.search(r"ControlPath=([^\s]+)", ssh_command)
    return match.group(1) if match else ""


def main() -> int:
    cli = _find_cli_binary()
    help_text = _run_cli(cli, ["ssh", "--help"], json_output=False)
    _must("cmux ssh" in help_text, "ssh --help output should include command header")
    _must("Create a new workspace" in help_text, "ssh --help output should describe workspace creation")

    workspace_id = ""
    workspace_id_without_name = ""
    with cmux(SOCKET_PATH) as client:
        try:
            payload = _run_cli_json(
                cli,
                ["ssh", "127.0.0.1", "--port", "1", "--name", "ssh-meta-test"],
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
            ssh_command = str(payload.get("ssh_command") or "")
            _must(bool(ssh_command), f"cmux ssh output missing ssh_command: {payload}")
            _must(
                "GHOSTTY_SHELL_FEATURES=${GHOSTTY_SHELL_FEATURES:+$GHOSTTY_SHELL_FEATURES,}ssh-env,ssh-terminfo" in ssh_command,
                f"cmux ssh should scope ssh niceties to this command: {ssh_command!r}",
            )
            _must("ssh -o StrictHostKeyChecking=accept-new" in ssh_command, f"ssh command prefix mismatch: {ssh_command!r}")
            _must("-o ControlMaster=auto" in ssh_command, f"ssh command should opt into connection reuse: {ssh_command!r}")
            _must("-o ControlPersist=600" in ssh_command, f"ssh command should keep master alive for reuse: {ssh_command!r}")
            _must("ControlPath=/tmp/cmux-ssh-" in ssh_command, f"ssh command should use shared control path template: {ssh_command!r}")

            listed_row = None
            deadline = time.time() + 8.0
            while time.time() < deadline:
                listed = client._call("workspace.list", {}) or {}
                for row in listed.get("workspaces") or []:
                    if str(row.get("id") or "") == workspace_id:
                        listed_row = row
                        break
                if listed_row is not None:
                    break
                time.sleep(0.1)

            _must(listed_row is not None, f"workspace.list did not include {workspace_id}")
            remote = listed_row.get("remote") or {}
            _must(bool(remote.get("enabled")) is True, f"workspace should be marked remote-enabled: {listed_row}")
            _must(str(remote.get("destination") or "") == "127.0.0.1", f"remote destination mismatch: {remote}")
            _must(str(listed_row.get("title") or "") == "ssh-meta-test", f"workspace title mismatch: {listed_row}")
            _must(
                str(remote.get("state") or "") in {"connecting", "connected", "error", "disconnected"},
                f"unexpected remote state: {remote}",
            )

            status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
            status_remote = status.get("remote") or {}
            _must(bool(status_remote.get("enabled")) is True, f"workspace.remote.status should report enabled remote: {status}")
            daemon = status_remote.get("daemon") or {}
            _must(
                str(daemon.get("state") or "") in {"unavailable", "bootstrapping", "ready", "error"},
                f"workspace.remote.status should include daemon state metadata: {status_remote}",
            )
            # Fail-fast regression: unreachable SSH target should surface bootstrap error explicitly.
            deadline_daemon = time.time() + 12.0
            last_status = status
            while time.time() < deadline_daemon:
                last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
                last_remote = last_status.get("remote") or {}
                last_daemon = last_remote.get("daemon") or {}
                if str(last_daemon.get("state") or "") == "error":
                    break
                time.sleep(0.2)
            else:
                raise cmuxError(f"unreachable host should drive daemon state to error: {last_status}")

            last_remote = last_status.get("remote") or {}
            last_daemon = last_remote.get("daemon") or {}
            detail = str(last_daemon.get("detail") or "")
            _must("bootstrap failed" in detail.lower(), f"daemon error should mention bootstrap failure: {last_status}")

            # Lifecycle regression: disconnect with clear should reset remote/daemon metadata.
            disconnected = client._call(
                "workspace.remote.disconnect",
                {"workspace_id": workspace_id, "clear": True},
            ) or {}
            disconnected_remote = disconnected.get("remote") or {}
            disconnected_daemon = disconnected_remote.get("daemon") or {}
            _must(bool(disconnected_remote.get("enabled")) is False, f"remote config should be cleared: {disconnected}")
            _must(str(disconnected_remote.get("state") or "") == "disconnected", f"remote state should be disconnected: {disconnected}")
            _must(str(disconnected_daemon.get("state") or "") == "unavailable", f"daemon state should reset to unavailable: {disconnected}")

            # Regression: --name is optional.
            payload2 = _run_cli_json(
                cli,
                ["ssh", "127.0.0.1", "--port", "1"],
            )
            workspace_id_without_name = str(payload2.get("workspace_id") or "")
            ssh_command_without_name = str(payload2.get("ssh_command") or "")
            workspace_ref_without_name = str(payload2.get("workspace_ref") or "")
            if not workspace_id_without_name and workspace_ref_without_name.startswith("workspace:"):
                listed2 = client._call("workspace.list", {}) or {}
                for row in listed2.get("workspaces") or []:
                    if str(row.get("ref") or "") == workspace_ref_without_name:
                        workspace_id_without_name = str(row.get("id") or "")
                        break

            _must(bool(workspace_id_without_name), f"cmux ssh without --name should still create workspace: {payload2}")
            _must(
                "ControlPath=/tmp/cmux-ssh-" in ssh_command_without_name,
                f"cmux ssh without --name should still include shared control path: {ssh_command_without_name!r}",
            )
            _must(
                _extract_control_path(ssh_command) == _extract_control_path(ssh_command_without_name),
                f"identical hosts should resolve to same control path template: {ssh_command!r} vs {ssh_command_without_name!r}",
            )
            row2 = None
            listed2 = client._call("workspace.list", {}) or {}
            for row in listed2.get("workspaces") or []:
                if str(row.get("id") or "") == workspace_id_without_name:
                    row2 = row
                    break
            _must(row2 is not None, f"workspace created without --name missing from workspace.list: {workspace_id_without_name}")
            _must(bool(str((row2 or {}).get("title") or "").strip()), f"workspace title should not be empty without --name: {row2}")
        finally:
            if workspace_id:
                try:
                    client.close_workspace(workspace_id)
                except Exception:
                    pass
            if workspace_id_without_name:
                try:
                    client.close_workspace(workspace_id_without_name)
                except Exception:
                    pass

    print("PASS: cmux ssh marks workspace as remote, exposes remote metadata, and does not require --name")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
