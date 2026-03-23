#!/usr/bin/env python3
"""Regression: interactive `cmux ssh` shells must resolve `cmux` to the relay wrapper."""

from __future__ import annotations

import glob
import json
import os
import re
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
SSH_HOST = os.environ.get("CMUX_SSH_TEST_HOST", "").strip()


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


def _run_cli_json(cli: str, args: list[str]) -> dict:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    import subprocess

    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, "--json", *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    if proc.returncode != 0:
        raise cmuxError(f"CLI failed ({' '.join(args)}): {(proc.stdout + proc.stderr).strip()}")
    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})")


def _workspace_id_from_payload(client: cmux, payload: dict) -> str:
    workspace_id = str(payload.get("workspace_id") or "")
    if workspace_id:
        return workspace_id
    workspace_ref = str(payload.get("workspace_ref") or "")
    if workspace_ref.startswith("workspace:"):
        rows = (client._call("workspace.list", {}) or {}).get("workspaces") or []
        for row in rows:
            if str(row.get("ref") or "") == workspace_ref:
                return str(row.get("id") or "")
    return ""


def _wait_remote_ready(client: cmux, workspace_id: str, timeout: float = 25.0) -> None:
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


def _wait_surface_id(client: cmux, workspace_id: str, timeout: float = 10.0) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        surfaces = client.list_surfaces(workspace_id)
        if surfaces:
            return str(surfaces[0][1])
        time.sleep(0.1)
    raise cmuxError(f"No terminal surface appeared for workspace {workspace_id}")


def _wait_text(client: cmux, surface_id: str, token: str, timeout: float = 12.0) -> str:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        last = client.read_terminal_text(surface_id)
        if token in last:
            return last
        time.sleep(0.15)
    raise cmuxError(f"Timed out waiting for {token!r} in surface {surface_id}: {last[-1200:]!r}")


def _wait_shell_ready(client: cmux, surface_id: str, timeout: float = 20.0) -> None:
    token = f"__CMUX_SHELL_READY_{secrets.token_hex(6)}__"
    client.send_surface(surface_id, f"printf '{token}'; echo")
    client.send_key_surface(surface_id, "enter")
    _wait_text(client, surface_id, token, timeout=timeout)


def _assert_no_login_profile_noise(text: str) -> None:
    _must(
        "/Users/cmux/.profile:" not in text,
        f"interactive ssh shell should not source ~/.profile via the bootstrap wrapper: {text[-1200:]!r}",
    )
    _must(
        "No such file or directory" not in text,
        f"interactive ssh shell still emitted startup file noise: {text[-1200:]!r}",
    )


def _run_remote_shell_command(client: cmux, surface_id: str, command: str, timeout: float = 12.0) -> tuple[int, str, str]:
    token = f"__CMUX_REMOTE_CMD_{secrets.token_hex(6)}__"
    start_marker = f"{token}:START"
    status_marker = f"{token}:STATUS"
    end_marker = f"{token}:END"
    client.send_surface(
        surface_id,
        (
            f"printf '{start_marker}'; echo; "
            f"{command}; "
            "__cmux_status=$?; "
            f"printf '{status_marker}:%s' \"$__cmux_status\"; echo; "
            f"printf '{end_marker}'; echo"
        ),
    )
    client.send_key_surface(surface_id, "enter")
    deadline = time.time() + timeout
    text = ""
    while time.time() < deadline:
        text = client.read_terminal_text(surface_id)
        if (
            text.count(start_marker) >= 2
            and text.count(status_marker) >= 2
            and text.count(end_marker) >= 2
        ):
            break
        time.sleep(0.15)
    pattern = re.compile(
        re.escape(start_marker) + r"\n(.*?)" + re.escape(status_marker) + r":(\d+)\n" + re.escape(end_marker),
        re.S,
    )
    matches = pattern.findall(text)
    if not matches:
        raise cmuxError(f"Missing command result token for {command!r}: {text[-1200:]!r}")
    output, status_raw = matches[-1]
    return int(status_raw), output, text


def main() -> int:
    if not SSH_HOST:
        print("SKIP: set CMUX_SSH_TEST_HOST to run interactive ssh cmux command regression")
        return 0

    cli = _find_cli_binary()
    workspace_ids: list[str] = []
    try:
        with cmux(SOCKET_PATH) as client:
            payload = _run_cli_json(cli, ["ssh", SSH_HOST])
            workspace_id = _workspace_id_from_payload(client, payload)
            _must(bool(workspace_id), f"cmux ssh output missing workspace_id: {payload}")
            workspace_ids.append(workspace_id)

            _wait_remote_ready(client, workspace_id)
            surface_id = _wait_surface_id(client, workspace_id)
            initial_text = client.read_terminal_text(surface_id)
            _assert_no_login_profile_noise(initial_text)
            _wait_shell_ready(client, surface_id)
            shell_ready_text = client.read_terminal_text(surface_id)
            _assert_no_login_profile_noise(shell_ready_text)

            which_status, which_output, which_text = _run_remote_shell_command(client, surface_id, "command -v cmux")
            _must(which_status == 0, f"`command -v cmux` failed: output={which_output!r} tail={which_text[-1200:]!r}")
            _must(
                "/.cmux/bin/cmux" in which_output,
                f"interactive ssh shell should resolve cmux to relay wrapper, got {which_output!r}",
            )

            ping_status, ping_output, ping_text = _run_remote_shell_command(client, surface_id, "cmux ping")
            _must(ping_status == 0, f"`cmux ping` failed in interactive shell: output={ping_output!r} tail={ping_text[-1200:]!r}")
            _must("pong" in ping_output.lower(), f"`cmux ping` should return pong, got {ping_output!r}")
            _must(
                "Socket not found at 127.0.0.1:" not in ping_text,
                f"interactive ssh shell still routed cmux to a unix-socket-only binary: {ping_text[-1200:]!r}",
            )
            _must(
                "waiting for relay on 127.0.0.1:" not in ping_text and "failed to connect to 127.0.0.1:" not in ping_text,
                f"`cmux ping` hit a dead ssh relay instead of the local app socket: {ping_text[-1200:]!r}",
            )

            notify_status, notify_output, notify_text = _run_remote_shell_command(
                client,
                surface_id,
                "cmux notify --body interactive-ssh-regression",
            )
            _must(
                notify_status == 0,
                f"`cmux notify` failed in interactive shell: output={notify_output!r} tail={notify_text[-1200:]!r}",
            )
            _must(
                "Socket not found at 127.0.0.1:" not in notify_text,
                f"`cmux notify` still failed via wrong cmux binary: {notify_text[-1200:]!r}",
            )
            _must(
                "waiting for relay on 127.0.0.1:" not in notify_text and "failed to connect to 127.0.0.1:" not in notify_text,
                f"`cmux notify` still failed because the ssh relay listener was not running: {notify_text[-1200:]!r}",
            )

            shell_status, shell_output, shell_text = _run_remote_shell_command(
                client,
                surface_id,
                r'''printf 'TERM=%s\n' "${TERM:-}"; printf 'TERM_PROGRAM=%s\n' "${TERM_PROGRAM:-}"; printf 'TERM_PROGRAM_VERSION=%s\n' "${TERM_PROGRAM_VERSION:-}"; printf 'GHOSTTY_SHELL_FEATURES=%s\n' "${GHOSTTY_SHELL_FEATURES:-}"; bindkey "^A"; bindkey "^K"; bindkey "^[^?"; bindkey "^[b"; bindkey "^[f"''',
            )
            _must(shell_status == 0, f"ssh shell env/bindkey probe failed: output={shell_output!r} tail={shell_text[-1200:]!r}")
            _must("TERM=xterm-ghostty" in shell_output, f"ssh shell lost TERM=xterm-ghostty: {shell_output!r}")
            _must("TERM_PROGRAM=ghostty" in shell_output, f"ssh shell lost TERM_PROGRAM=ghostty: {shell_output!r}")
            _must("GHOSTTY_SHELL_FEATURES=" in shell_output, f"ssh shell lost GHOSTTY_SHELL_FEATURES: {shell_output!r}")
            _must("ssh-env" in shell_output, f"ssh shell missing ssh-env feature: {shell_output!r}")
            _must("ssh-terminfo" in shell_output, f"ssh shell missing ssh-terminfo feature: {shell_output!r}")
            _must('"^A" beginning-of-line' in shell_output, f"Ctrl-A binding regressed in ssh shell: {shell_output!r}")
            _must('"^K" kill-line' in shell_output, f"Ctrl-K binding regressed in ssh shell: {shell_output!r}")
            _must('"^[^?" backward-kill-word' in shell_output, f"Opt-Backspace binding regressed in ssh shell: {shell_output!r}")
            _must('"^[b" backward-word' in shell_output, f"Opt-Left binding regressed in ssh shell: {shell_output!r}")
            _must('"^[f" forward-word' in shell_output, f"Opt-Right binding regressed in ssh shell: {shell_output!r}")
    finally:
        if workspace_ids:
            try:
                with cmux(SOCKET_PATH) as client:
                    for workspace_id in workspace_ids:
                        try:
                            client._call("workspace.close", {"workspace_id": workspace_id})
                        except Exception:
                            pass
            except Exception:
                pass

    print("PASS: interactive ssh shell resolves cmux to relay wrapper and remote cmux commands succeed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
