#!/usr/bin/env python3
"""
Regression coverage for foreground-command reports emitted by shell integrations.

The socket protocol is newline-delimited, so shell integrations must escape
embedded command newlines before batching report_shell_state with
report_foreground_command in one payload.
"""

from __future__ import annotations

import os
import shlex
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


def _run_shell_report(
    *,
    shell: str,
    shell_args: list[str],
    integration_script: Path,
    socket_path: Path,
    payload_path: Path,
) -> str:
    script = "\n".join(
        [
            f"source {shlex.quote(str(integration_script))}",
            f"_cmux_send_bg() {{ printf '%s' \"$1\" > {shlex.quote(str(payload_path))}; }}",
            f"export CMUX_SOCKET_PATH={shlex.quote(str(socket_path))}",
            "export CMUX_TAB_ID=tab-test",
            "export CMUX_PANEL_ID=panel-test",
            "cmd=$'ssh example.com\\nprintf \"quoted\"\\rtrue'",
            "_cmux_report_command_start \"$cmd\"",
        ]
    )
    subprocess.run(
        [shell, *shell_args, script],
        check=True,
        capture_output=True,
        env={**os.environ, "CMUX_NO_GIT_WATCH": "1"},
        text=True,
        timeout=10,
    )
    return payload_path.read_text(encoding="utf-8")


def _assert_escaped_foreground_command_payload(payload: str) -> None:
    lines = payload.split("\n")
    expected_state_prefix = "report_shell_state running --tab=tab-test --panel=panel-test --seq="
    expected_command_prefix = (
        'report_foreground_command "ssh example.com\\nprintf \\\"quoted\\\"\\rtrue" '
        "--tab=tab-test --panel=panel-test --seq="
    )
    if len(lines) != 2 or not lines[0].startswith(expected_state_prefix):
        raise AssertionError(
            "foreground command report was not safely newline-framed.\n\n"
            f"Observed payload repr:\n{payload!r}"
        )
    seq = lines[0][len(expected_state_prefix):]
    if not seq or not seq.isdigit():
        raise AssertionError(
            "foreground command report did not include a numeric shell sequence.\n\n"
            f"Observed payload repr:\n{payload!r}"
        )
    expected_command_line = expected_command_prefix + seq
    if lines != [expected_state_prefix + seq, expected_command_line]:
        raise AssertionError(
            "foreground command report was not safely newline-framed.\n\n"
            f"Expected second line:\n{expected_command_line}\n\n"
            f"Observed payload repr:\n{payload!r}"
        )


def _run_bash_now_without_epochseconds(integration_script: Path) -> tuple[int, int]:
    script = "\n".join(
        [
            "unset EPOCHSECONDS",
            "SECONDS=11",
            f"source {shlex.quote(str(integration_script))}",
            'printf "%s:%s\\n" "$(_cmux_now)" "$SECONDS"',
        ]
    )
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-c", script],
        check=True,
        capture_output=True,
        env={**os.environ, "CMUX_NO_GIT_WATCH": "1"},
        text=True,
        timeout=10,
    )
    now_text, seconds_text = result.stdout.strip().split(":", maxsplit=1)
    return int(now_text), int(seconds_text)


def test_shell_foreground_command_reports_escape_newlines() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    shell_dir = repo_root / "Resources" / "shell-integration"

    shells: list[tuple[str, list[str], Path]] = [
        ("bash", ["--noprofile", "--norc", "-c"], shell_dir / "cmux-bash-integration.bash"),
    ]
    zsh = shutil.which("zsh")
    if zsh is not None:
        shells.append((zsh, ["-f", "-c"], shell_dir / "cmux-zsh-integration.zsh"))

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        socket_path = tmp_path / "cmux.sock"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.bind(str(socket_path))
            sock.listen(1)
            for shell, shell_args, integration_script in shells:
                payload_path = tmp_path / f"{Path(shell).name}.payload"
                payload = _run_shell_report(
                    shell=shell,
                    shell_args=shell_args,
                    integration_script=integration_script,
                    socket_path=socket_path,
                    payload_path=payload_path,
                )
                _assert_escaped_foreground_command_payload(payload)
        finally:
            sock.close()


def test_bash_now_uses_seconds_without_epochseconds() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    integration_script = repo_root / "Resources" / "shell-integration" / "cmux-bash-integration.bash"

    now, seconds = _run_bash_now_without_epochseconds(integration_script)
    if not seconds - 1 <= now <= seconds + 1:
        raise AssertionError(
            "_cmux_now should use shell-relative SECONDS when EPOCHSECONDS is unavailable.\n\n"
            f"Observed _cmux_now={now}, SECONDS={seconds}"
        )


if __name__ == "__main__":
    test_shell_foreground_command_reports_escape_newlines()
    test_bash_now_uses_seconds_without_epochseconds()
    print("PASS: shell foreground command reports escape protocol newlines")
