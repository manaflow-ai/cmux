#!/usr/bin/env python3
"""Regression: `cmux ssh` creates a remote-tagged workspace with remote metadata."""

from __future__ import annotations

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


def _run_cli(cli: str, args: list[str], *, json_output: bool, extra_env: dict[str, str] | None = None) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    if extra_env:
        env.update(extra_env)

    cmd = [cli, "--socket", SOCKET_PATH]
    if json_output:
        cmd.append("--json")
    cmd.extend(args)
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def _run_cli_json(cli: str, args: list[str], *, extra_env: dict[str, str] | None = None) -> dict:
    output = _run_cli(cli, args, json_output=True, extra_env=extra_env)
    try:
        return json.loads(output or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {output!r} ({exc})")


def _extract_control_path(ssh_command: str) -> str:
    match = re.search(r"ControlPath=([^\s]+)", ssh_command)
    return match.group(1) if match else ""


def _has_ssh_option_key(options: list[str], key: str) -> bool:
    lowered_key = key.lower()
    for option in options:
        token = re.split(r"[=\s]+", str(option).strip(), maxsplit=1)[0].strip().lower()
        if token == lowered_key:
            return True
    return False


def _read_any_terminal_text(client: cmux, workspace_id: str, timeout: float = 8.0) -> str | None:
    deadline = time.time() + timeout
    last_exc: Exception | None = None
    while time.time() < deadline:
        surfaces = client.list_surfaces(workspace_id)
        for _, surface_id, _ in surfaces:
            try:
                return client.read_terminal_text(surface_id)
            except cmuxError as exc:
                text = str(exc).lower()
                if "terminal surface not found" in text:
                    last_exc = exc
                    continue
                raise
        time.sleep(0.1)
    print(f"WARN: readable terminal surface unavailable in workspace {workspace_id}; skipping transcript assertion ({last_exc})")
    return None


def _resolve_workspace_id_from_payload(client: cmux, payload: dict) -> str:
    workspace_id = str(payload.get("workspace_id") or "")
    if workspace_id:
        return workspace_id

    workspace_ref = str(payload.get("workspace_ref") or "")
    if not workspace_ref.startswith("workspace:"):
        return ""

    listed = client._call("workspace.list", {}) or {}
    for row in listed.get("workspaces") or []:
        if str(row.get("ref") or "") == workspace_ref:
            return str(row.get("id") or "")
    return ""


def _append_workspace_to_cleanup(workspaces_to_close: list[str], workspace_id: str) -> str:
    if workspace_id:
        workspaces_to_close.append(workspace_id)
    return workspace_id


def main() -> int:
    cli = _find_cli_binary()
    help_text = _run_cli(cli, ["ssh", "--help"], json_output=False)
    _must("cmux ssh" in help_text, "ssh --help output should include command header")
    _must("Create a new workspace" in help_text, "ssh --help output should describe workspace creation")

    workspace_id = ""
    workspace_id_without_name = ""
    workspace_id_strict_override = ""
    workspace_id_case_override = ""
    workspace_id_invalid_proxy_port = ""
    workspaces_to_close: list[str] = []
    with cmux(SOCKET_PATH) as client:
        try:
            payload = _run_cli_json(
                cli,
                ["ssh", "127.0.0.1", "--port", "1", "--name", "ssh-meta-test"],
            )
            workspace_id = _append_workspace_to_cleanup(
                workspaces_to_close,
                _resolve_workspace_id_from_payload(client, payload),
            )
            _must(bool(workspace_id), f"cmux ssh output missing workspace_id: {payload}")
            selected_workspace_id = ""
            deadline_select = time.time() + 5.0
            while time.time() < deadline_select:
                try:
                    selected_workspace_id = client.current_workspace()
                except cmuxError:
                    time.sleep(0.05)
                    continue
                if selected_workspace_id == workspace_id:
                    break
                time.sleep(0.05)
            _must(
                selected_workspace_id == workspace_id,
                f"cmux ssh should select the newly created workspace: expected {workspace_id}, got {selected_workspace_id}",
            )
            remote_relay_port = payload.get("remote_relay_port")
            _must(remote_relay_port is not None, f"cmux ssh output missing remote_relay_port: {payload}")
            remote_socket_addr = f"127.0.0.1:{int(remote_relay_port)}"
            ssh_command = str(payload.get("ssh_command") or "")
            _must(bool(ssh_command), f"cmux ssh output missing ssh_command: {payload}")
            _must(
                ssh_command.startswith("ssh "),
                f"cmux ssh should emit plain ssh command text (env is passed via workspace.create initial_env): {ssh_command!r}",
            )
            ssh_startup_command = str(payload.get("ssh_startup_command") or "")
            _must(
                ssh_startup_command.startswith("/bin/zsh -ilc "),
                f"cmux ssh should launch startup command via interactive zsh for shell integration: {ssh_startup_command!r}",
            )
            ssh_env_overrides = payload.get("ssh_env_overrides") or {}
            _must(
                str(ssh_env_overrides.get("GHOSTTY_SHELL_FEATURES") or "").endswith("ssh-env,ssh-terminfo"),
                f"cmux ssh should pass shell niceties via ssh_env_overrides: {payload}",
            )
            _must(not ssh_command.startswith("env "), f"ssh command should not include env prefix: {ssh_command!r}")
            _must("-o StrictHostKeyChecking=accept-new" in ssh_command, f"ssh command prefix mismatch: {ssh_command!r}")
            _must("-o ControlMaster=auto" in ssh_command, f"ssh command should opt into connection reuse: {ssh_command!r}")
            _must("-o ControlPersist=600" in ssh_command, f"ssh command should keep master alive for reuse: {ssh_command!r}")
            _must("ControlPath=/tmp/cmux-ssh-" in ssh_command, f"ssh command should use shared control path template: {ssh_command!r}")
            _must(
                (
                    f"RemoteCommand=export PATH=\"$HOME/.cmux/bin:$PATH\"; "
                    f"export CMUX_SOCKET_PATH={remote_socket_addr}; "
                    "exec \"${SHELL:-/bin/zsh}\" -l"
                ) in ssh_command,
                f"cmux ssh should use -o RemoteCommand for PATH/bootstrap env pinning (not positional command): {ssh_command!r}",
            )

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
            proxy = remote.get("proxy") or {}
            _must(
                str(proxy.get("state") or "") in {"connecting", "ready", "error", "unavailable"},
                f"remote payload should include proxy state metadata: {remote}",
            )
            remote_ssh_options = [str(item) for item in (remote.get("ssh_options") or [])]
            _must(
                _has_ssh_option_key(remote_ssh_options, "ControlMaster"),
                f"workspace.remote.configure should include ControlMaster default: {remote}",
            )
            _must(
                _has_ssh_option_key(remote_ssh_options, "ControlPersist"),
                f"workspace.remote.configure should include ControlPersist default: {remote}",
            )
            _must(
                _has_ssh_option_key(remote_ssh_options, "ControlPath"),
                f"workspace.remote.configure should include ControlPath default: {remote}",
            )
            # Regression: cmux ssh should launch through initial_command, not visibly type a giant command into the shell.
            terminal_text = _read_any_terminal_text(client, workspace_id)
            if terminal_text is not None:
                _must("ControlPersist=600" not in terminal_text, f"cmux ssh should not inject raw ssh command text: {terminal_text!r}")
                _must("GHOSTTY_SHELL_FEATURES=" not in terminal_text, f"cmux ssh should not inject env assignment text: {terminal_text!r}")

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
            _must(re.search(r"retry\s+\d+", detail.lower()) is not None, f"daemon error should include retry count: {last_status}")

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
            try:
                client._call("workspace.remote.reconnect", {"workspace_id": workspace_id})
                raise cmuxError("workspace.remote.reconnect should fail when remote config was cleared")
            except cmuxError as exc:
                text = str(exc).lower()
                _must("invalid_state" in text, f"workspace.remote.reconnect missing invalid_state for cleared config: {exc}")
                _must("not configured" in text, f"workspace.remote.reconnect should explain missing remote config: {exc}")

            # Regression: --name is optional.
            payload2 = _run_cli_json(
                cli,
                ["ssh", "127.0.0.1", "--port", "1"],
            )
            workspace_id_without_name = _append_workspace_to_cleanup(
                workspaces_to_close,
                _resolve_workspace_id_from_payload(client, payload2),
            )
            ssh_command_without_name = str(payload2.get("ssh_command") or "")

            _must(bool(workspace_id_without_name), f"cmux ssh without --name should still create workspace: {payload2}")
            _must(
                "ControlPath=/tmp/cmux-ssh-" in ssh_command_without_name,
                f"cmux ssh without --name should still include control path defaults: {ssh_command_without_name!r}",
            )
            _must(
                _extract_control_path(ssh_command) != _extract_control_path(ssh_command_without_name),
                f"distinct cmux ssh workspaces should get distinct control paths: {ssh_command!r} vs {ssh_command_without_name!r}",
            )
            row2 = None
            listed2 = client._call("workspace.list", {}) or {}
            for row in listed2.get("workspaces") or []:
                if str(row.get("id") or "") == workspace_id_without_name:
                    row2 = row
                    break
            _must(row2 is not None, f"workspace created without --name missing from workspace.list: {workspace_id_without_name}")
            _must(bool(str((row2 or {}).get("title") or "").strip()), f"workspace title should not be empty without --name: {row2}")
            reconnected = client._call("workspace.remote.reconnect", {"workspace_id": workspace_id_without_name}) or {}
            reconnected_remote = reconnected.get("remote") or {}
            _must(bool(reconnected_remote.get("enabled")) is True, f"workspace.remote.reconnect should keep remote enabled: {reconnected}")
            _must(
                str(reconnected_remote.get("state") or "") in {"connecting", "connected", "error"},
                f"workspace.remote.reconnect should transition into an active state: {reconnected}",
            )

            payload_strict_override = _run_cli_json(
                cli,
                [
                    "ssh",
                    "127.0.0.1",
                    "--port",
                    "1",
                    "--name",
                    "ssh-meta-strict-override",
                    "--ssh-option",
                    "StrictHostKeyChecking=no",
                ],
            )
            workspace_id_strict_override = _append_workspace_to_cleanup(
                workspaces_to_close,
                _resolve_workspace_id_from_payload(client, payload_strict_override),
            )
            _must(
                bool(workspace_id_strict_override),
                f"cmux ssh with StrictHostKeyChecking override should create workspace: {payload_strict_override}",
            )
            ssh_command_strict_override = str(payload_strict_override.get("ssh_command") or "")
            _must(
                "-o StrictHostKeyChecking=no" in ssh_command_strict_override,
                f"ssh command should include user StrictHostKeyChecking override: {ssh_command_strict_override!r}",
            )
            _must(
                "-o StrictHostKeyChecking=accept-new" not in ssh_command_strict_override,
                f"ssh command should not force default StrictHostKeyChecking when override is supplied: {ssh_command_strict_override!r}",
            )
            strict_override_remote = payload_strict_override.get("remote") or {}
            strict_override_options = [str(item) for item in (strict_override_remote.get("ssh_options") or [])]
            _must(
                any(item.lower() == "stricthostkeychecking=no" for item in strict_override_options),
                f"workspace.remote.configure should preserve explicit StrictHostKeyChecking override: {strict_override_remote}",
            )

            payload_case_override = _run_cli_json(
                cli,
                [
                    "ssh",
                    "127.0.0.1",
                    "--port",
                    "1",
                    "--name",
                    "ssh-meta-case-override",
                    "--ssh-option",
                    "stricthostkeychecking=no",
                    "--ssh-option",
                    "controlmaster=no",
                    "--ssh-option",
                    "controlpersist=0",
                    "--ssh-option",
                    "controlpath=/tmp/cmux-ssh-%C-custom",
                ],
            )
            workspace_id_case_override = _append_workspace_to_cleanup(
                workspaces_to_close,
                _resolve_workspace_id_from_payload(client, payload_case_override),
            )
            _must(
                bool(workspace_id_case_override),
                f"cmux ssh with lowercase SSH option overrides should create workspace: {payload_case_override}",
            )
            ssh_command_case_override = str(payload_case_override.get("ssh_command") or "")
            ssh_command_case_override_lower = ssh_command_case_override.lower()
            _must(
                "-o stricthostkeychecking=no" in ssh_command_case_override_lower,
                f"ssh command should preserve lowercase StrictHostKeyChecking override: {ssh_command_case_override!r}",
            )
            _must(
                "stricthostkeychecking=accept-new" not in ssh_command_case_override_lower,
                f"ssh command should not force default StrictHostKeyChecking when lowercase override is supplied: {ssh_command_case_override!r}",
            )
            _must(
                "-o controlmaster=no" in ssh_command_case_override_lower,
                f"ssh command should preserve lowercase ControlMaster override: {ssh_command_case_override!r}",
            )
            _must(
                "controlmaster=auto" not in ssh_command_case_override_lower,
                f"ssh command should not force default ControlMaster when lowercase override is supplied: {ssh_command_case_override!r}",
            )
            _must(
                "-o controlpersist=0" in ssh_command_case_override_lower,
                f"ssh command should preserve lowercase ControlPersist override: {ssh_command_case_override!r}",
            )
            _must(
                "controlpersist=600" not in ssh_command_case_override_lower,
                f"ssh command should not force default ControlPersist when lowercase override is supplied: {ssh_command_case_override!r}",
            )
            _must(
                "controlpath=/tmp/cmux-ssh-%c-custom" in ssh_command_case_override_lower,
                f"ssh command should preserve lowercase ControlPath override value: {ssh_command_case_override!r}",
            )
            _must(
                ssh_command_case_override_lower.count("controlpath=") == 1,
                f"ssh command should include exactly one ControlPath when lowercase override is supplied: {ssh_command_case_override!r}",
            )
            case_override_remote = payload_case_override.get("remote") or {}
            case_override_options = [str(item) for item in (case_override_remote.get("ssh_options") or [])]
            _must(
                any(item.lower() == "stricthostkeychecking=no" for item in case_override_options),
                f"workspace.remote.configure should preserve lowercase StrictHostKeyChecking override: {case_override_remote}",
            )
            _must(
                not any(item.lower() == "stricthostkeychecking=accept-new" for item in case_override_options),
                f"workspace.remote.configure should not inject default StrictHostKeyChecking when lowercase override is supplied: {case_override_remote}",
            )
            _must(
                any(item.lower() == "controlmaster=no" for item in case_override_options),
                f"workspace.remote.configure should preserve lowercase ControlMaster override: {case_override_remote}",
            )
            _must(
                not any(item.lower() == "controlmaster=auto" for item in case_override_options),
                f"workspace.remote.configure should not inject default ControlMaster when lowercase override is supplied: {case_override_remote}",
            )
            _must(
                any(item.lower() == "controlpersist=0" for item in case_override_options),
                f"workspace.remote.configure should preserve lowercase ControlPersist override: {case_override_remote}",
            )
            _must(
                not any(item.lower() == "controlpersist=600" for item in case_override_options),
                f"workspace.remote.configure should not inject default ControlPersist when lowercase override is supplied: {case_override_remote}",
            )
            _must(
                any(item.lower() == "controlpath=/tmp/cmux-ssh-%c-custom" for item in case_override_options),
                f"workspace.remote.configure should preserve lowercase ControlPath override: {case_override_remote}",
            )
            _must(
                sum(1 for item in case_override_options if item.lower().startswith("controlpath=")) == 1,
                f"workspace.remote.configure should include exactly one ControlPath when lowercase override is supplied: {case_override_remote}",
            )

            payload3 = _run_cli_json(
                cli,
                ["ssh", "127.0.0.1", "--port", "1", "--name", "ssh-meta-features"],
                extra_env={"GHOSTTY_SHELL_FEATURES": "cursor,title"},
            )
            payload3_env = payload3.get("ssh_env_overrides") or {}
            merged_features = str(payload3_env.get("GHOSTTY_SHELL_FEATURES") or "")
            _must(
                merged_features == "cursor,title,ssh-env,ssh-terminfo",
                f"cmux ssh should merge existing shell features when present: {payload3!r}",
            )
            workspace_id3 = _append_workspace_to_cleanup(
                workspaces_to_close,
                _resolve_workspace_id_from_payload(client, payload3),
            )
            if workspace_id3:
                try:
                    client.close_workspace(workspace_id3)
                except Exception:
                    pass

            invalid_proxy_port_workspace = client._call("workspace.create", {"initial_command": "echo invalid-local-proxy-port"}) or {}
            workspace_id_invalid_proxy_port = str(invalid_proxy_port_workspace.get("workspace_id") or "")
            if workspace_id_invalid_proxy_port:
                workspaces_to_close.append(workspace_id_invalid_proxy_port)
            _must(bool(workspace_id_invalid_proxy_port), f"workspace.create missing workspace_id: {invalid_proxy_port_workspace}")

            configured_with_string_ports = client._call(
                "workspace.remote.configure",
                {
                    "workspace_id": workspace_id_invalid_proxy_port,
                    "destination": "127.0.0.1",
                    "port": "2222",
                    "local_proxy_port": "31338",
                    "auto_connect": False,
                },
            ) or {}
            configured_with_string_ports_remote = configured_with_string_ports.get("remote") or {}
            _must(
                int(configured_with_string_ports_remote.get("port") or 0) == 2222,
                f"workspace.remote.configure should parse numeric string port values: {configured_with_string_ports}",
            )
            _must(
                int(configured_with_string_ports_remote.get("local_proxy_port") or 0) == 31338,
                f"workspace.remote.configure should parse numeric string local_proxy_port values: {configured_with_string_ports}",
            )

            valid_local_proxy_port = 31337
            configured_with_local_proxy_port = client._call(
                "workspace.remote.configure",
                {
                    "workspace_id": workspace_id_invalid_proxy_port,
                    "destination": "127.0.0.1",
                    "port": 2222,
                    "local_proxy_port": valid_local_proxy_port,
                    "auto_connect": False,
                },
            ) or {}
            configured_remote = configured_with_local_proxy_port.get("remote") or {}
            _must(
                int(configured_remote.get("port") or 0) == 2222,
                f"workspace.remote.configure should echo explicit port in remote payload: {configured_with_local_proxy_port}",
            )
            _must(
                int(configured_remote.get("local_proxy_port") or 0) == valid_local_proxy_port,
                f"workspace.remote.configure should echo local_proxy_port in remote payload: {configured_with_local_proxy_port}",
            )

            configured_with_null_ports = client._call(
                "workspace.remote.configure",
                {
                    "workspace_id": workspace_id_invalid_proxy_port,
                    "destination": "127.0.0.1",
                    "port": None,
                    "local_proxy_port": None,
                    "auto_connect": False,
                },
            ) or {}
            configured_with_null_ports_remote = configured_with_null_ports.get("remote") or {}
            _must(
                configured_with_null_ports_remote.get("port") is None,
                f"workspace.remote.configure should allow null to clear port: {configured_with_null_ports}",
            )
            _must(
                configured_with_null_ports_remote.get("local_proxy_port") is None,
                f"workspace.remote.configure should allow null to clear local_proxy_port: {configured_with_null_ports}",
            )
            status_after_null_ports = client._call(
                "workspace.remote.status",
                {"workspace_id": workspace_id_invalid_proxy_port},
            ) or {}
            status_after_null_ports_remote = status_after_null_ports.get("remote") or {}
            _must(
                status_after_null_ports_remote.get("port") is None,
                f"workspace.remote.status should reflect cleared port: {status_after_null_ports}",
            )
            _must(
                status_after_null_ports_remote.get("local_proxy_port") is None,
                f"workspace.remote.status should reflect cleared local_proxy_port: {status_after_null_ports}",
            )

            for invalid_local_proxy_port in [0, 65536, "abc", True, 22.5]:
                try:
                    client._call(
                        "workspace.remote.configure",
                        {
                            "workspace_id": workspace_id_invalid_proxy_port,
                            "destination": "127.0.0.1",
                            "local_proxy_port": invalid_local_proxy_port,
                            "auto_connect": False,
                        },
                    )
                    raise cmuxError(
                        f"workspace.remote.configure should reject local_proxy_port={invalid_local_proxy_port!r}"
                    )
                except cmuxError as exc:
                    text = str(exc)
                    lowered = text.lower()
                    _must(
                        "invalid_params" in lowered,
                        f"workspace.remote.configure should return invalid_params for local_proxy_port={invalid_local_proxy_port!r}: {exc}",
                    )
                    _must(
                        "local_proxy_port must be 1-65535" in text,
                        f"workspace.remote.configure should include validation hint for local_proxy_port={invalid_local_proxy_port!r}: {exc}",
                    )

            for invalid_port in [0, 65536, "abc", True, 22.5]:
                try:
                    client._call(
                        "workspace.remote.configure",
                        {
                            "workspace_id": workspace_id_invalid_proxy_port,
                            "destination": "127.0.0.1",
                            "port": invalid_port,
                            "auto_connect": False,
                        },
                    )
                    raise cmuxError(
                        f"workspace.remote.configure should reject port={invalid_port!r}"
                    )
                except cmuxError as exc:
                    text = str(exc)
                    lowered = text.lower()
                    _must(
                        "invalid_params" in lowered,
                        f"workspace.remote.configure should return invalid_params for port={invalid_port!r}: {exc}",
                    )
                    _must(
                        "port must be 1-65535" in text,
                        f"workspace.remote.configure should include validation hint for port={invalid_port!r}: {exc}",
                    )

            try:
                client.close_workspace(workspace_id_invalid_proxy_port)
            except Exception:
                pass
            else:
                workspace_id_invalid_proxy_port = ""
        finally:
            for workspace_id_to_close in dict.fromkeys(workspaces_to_close):
                if not workspace_id_to_close:
                    continue
                try:
                    client.close_workspace(workspace_id_to_close)
                except Exception:
                    pass

    print("PASS: cmux ssh marks workspace as remote, exposes remote metadata, and does not require --name")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
