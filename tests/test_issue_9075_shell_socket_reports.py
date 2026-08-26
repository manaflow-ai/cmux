#!/usr/bin/env python3
"""Behavior regressions for capability-authenticated shell-integration reports."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
CAPABILITY = "issue-9075-test-capability"
PAYLOAD = (
    'report_pwd "/tmp/issue-9075" '
    "--tab=11111111-1111-1111-1111-111111111111 "
    "--panel=22222222-2222-2222-2222-222222222222"
)
EXPECTED_WIRE_LINE = f"_cmux_capability_v1 {CAPABILITY} {PAYLOAD}"


class UnixLineListener:
    def __init__(self, path: Path) -> None:
        self._path = path
        self._line: Optional[str] = None
        self._error: Optional[Exception] = None
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        if not self._ready.wait(timeout=2):
            raise RuntimeError("unix listener did not become ready")

    def _serve(self) -> None:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(self._path))
                server.listen(1)
                server.settimeout(4)
                self._ready.set()
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(2)
                    received = bytearray()
                    while b"\n" not in received:
                        chunk = connection.recv(4096)
                        if not chunk:
                            break
                        received.extend(chunk)
                    self._line = received.partition(b"\n")[0].decode(
                        "utf-8", errors="replace"
                    )
                    connection.sendall(b"OK\n")
        except Exception as error:
            self._error = error
            self._ready.set()

    def wait_for_line(self) -> str:
        self._thread.join(timeout=6)
        if self._thread.is_alive():
            raise RuntimeError("timed out waiting for shell-integration socket send")
        if self._error is not None:
            raise RuntimeError(
                f"shell-integration socket listener failed: {self._error}"
            ) from self._error
        if self._line is None:
            raise RuntimeError("shell integration connected without sending a line")
        return self._line


def shell_cases() -> list[tuple[str, Path, list[str]]]:
    cases = [
        (
            "bash",
            ROOT / "Resources/shell-integration/cmux-bash-integration.bash",
            ["/bin/bash", "--noprofile", "--norc", "-c"],
        ),
        (
            "zsh",
            ROOT / "Resources/shell-integration/cmux-zsh-integration.zsh",
            ["/bin/zsh", "-f", "-c"],
        ),
    ]
    fish_executable = shutil.which("fish")
    fish = (
        Path(fish_executable)
        if fish_executable is not None and os.access(fish_executable, os.X_OK)
        else None
    )
    if fish is not None:
        cases.append(
            (
                "fish",
                ROOT / "Resources/shell-integration/fish/config.fish",
                [str(fish), "-c"],
            )
        )
    elif os.environ.get("GITHUB_ACTIONS") == "true":
        raise RuntimeError("fish is required for the issue #9075 CI regression")
    return cases


def base_environment(
    integration: Path,
    directory: Path,
    socket_path: Optional[Path] = None,
) -> dict[str, str]:
    environment = {
        "CMUX_FISH_USER_CONFIG_ALREADY_LOADED": "1",
        "CMUX_NO_GIT_WATCH": "1",
        "CMUX_NO_PR_WATCH": "1",
        "CMUX_SHELL_INTEGRATION": "1",
        "CMUX_SOCKET_CAPABILITY": CAPABILITY,
        "CMUX_TEST_INTEGRATION": str(integration),
        "CMUX_TEST_PAYLOAD": PAYLOAD,
        "HOME": str(directory),
        "PATH": "/usr/bin:/bin",
        "TERM": "xterm-256color",
    }
    if socket_path is not None:
        environment["CMUX_SOCKET_PATH"] = str(socket_path)
    return environment


def send_command() -> str:
    return (
        'source "$CMUX_TEST_INTEGRATION"; '
        '_cmux_send_bg "$CMUX_TEST_PAYLOAD"'
    )


def tmux_publish_command(shell_name: str) -> str:
    if shell_name == "fish":
        return """
source "$CMUX_TEST_INTEGRATION"
function tmux
    string join ' ' -- $argv >> "$CMUX_TEST_TMUX_LOG"
end
_cmux_tmux_publish_cmux_environment
"""
    return """
source "$CMUX_TEST_INTEGRATION"
tmux() { printf '%s\n' "$*" >> "$CMUX_TEST_TMUX_LOG"; }
_cmux_tmux_publish_cmux_environment
"""


def run_shell(
    argv_prefix: list[str],
    command: str,
    environment: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv_prefix + [command],
        env=environment,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"{argv_prefix[0]} exited {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def assert_background_send_is_capability_authenticated(
    shell_name: str,
    integration: Path,
    argv_prefix: list[str],
    directory: Path,
    path_prefix: Optional[Path] = None,
) -> None:
    socket_variant = "shadowed-path" if path_prefix is not None else "direct"
    socket_path = directory / f"{shell_name}-{socket_variant}.sock"
    listener = UnixLineListener(socket_path)
    environment = base_environment(integration, directory, socket_path)
    if path_prefix is not None:
        environment["PATH"] = f"{path_prefix}:/usr/bin:/bin"
    run_shell(argv_prefix, send_command(), environment)
    line = listener.wait_for_line()
    if line != EXPECTED_WIRE_LINE:
        raise AssertionError(
            f"{shell_name} sent an unauthenticated socket line:\n"
            f"expected: {EXPECTED_WIRE_LINE!r}\nactual:   {line!r}"
        )


def assert_tmux_does_not_publish_capability(
    shell_name: str,
    integration: Path,
    argv_prefix: list[str],
    directory: Path,
) -> None:
    log_path = directory / f"{shell_name}-tmux.log"
    environment = base_environment(integration, directory)
    environment["CMUX_TEST_TMUX_LOG"] = str(log_path)
    run_shell(argv_prefix, tmux_publish_command(shell_name), environment)
    output = log_path.read_text(encoding="utf-8")
    forbidden = "set-environment -g CMUX_SOCKET_CAPABILITY "
    if forbidden in output:
        raise AssertionError(
            f"{shell_name} published the socket capability to tmux:\n{output}"
        )
    expected = "set-environment -g CMUX_SHELL_INTEGRATION 1"
    if expected not in output:
        raise AssertionError(
            f"{shell_name} did not publish ordinary cmux state to tmux:\n{output}"
        )


def main() -> int:
    if not os.path.exists("/usr/bin/nc"):
        print("SKIP: macOS /usr/bin/nc is required")
        return 0

    with tempfile.TemporaryDirectory(prefix="cmux-9075-", dir="/tmp") as temp:
        directory = Path(temp)
        cases = shell_cases()
        for shell_name, integration, argv_prefix in cases:
            assert_background_send_is_capability_authenticated(
                shell_name,
                integration,
                argv_prefix,
                directory,
            )
            assert_tmux_does_not_publish_capability(
                shell_name,
                integration,
                argv_prefix,
                directory,
            )

        shadow_directory = directory / "shadow"
        shadow_directory.mkdir()
        shadow_nc = shadow_directory / "nc"
        shadow_nc.write_text("#!/bin/sh\nexit 91\n", encoding="utf-8")
        shadow_nc.chmod(0o755)
        for shell_name, integration, argv_prefix in cases:
            assert_background_send_is_capability_authenticated(
                shell_name,
                integration,
                argv_prefix,
                directory,
                path_prefix=shadow_directory,
            )

    tested_shells = ", ".join(case[0] for case in shell_cases())
    print(
        "PASS: detached shell reports present the inherited socket capability "
        f"without publishing it through tmux ({tested_shells})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
