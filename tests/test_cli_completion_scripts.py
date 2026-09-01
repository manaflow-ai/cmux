#!/usr/bin/env python3
"""Checks generated shell-completion scripts without a running cmux socket."""

from __future__ import annotations

import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import uuid


SHELL_PARSE_COMMANDS = {
    "bash": ["bash", "-n"],
    "zsh": ["zsh", "-n"],
    "fish": ["fish", "--no-execute"],
}

# Representative token that must survive generation: a top-level leaf command.
# A script that parses but omits it has silently dropped commands. The shared
# `--json` option is checked separately because its spelling is shell-specific.
REQUIRED_TOKENS = ["list-workspaces"]


def has_shared_json_option(shell: str, script: str) -> bool:
    """Checks that the generated script offers the root `--json` option that
    every command inherits. bash and zsh emit the flag verbatim; fish names
    long options without their leading dashes.
    """
    if shell == "fish":
        return "-l 'json'" in script
    if shell in ("bash", "zsh"):
        return "--json" in script
    raise ValueError(f"unhandled shell: {shell}")


def has_structural_browser_command(shell: str, script: str) -> bool:
    """Checks that the generated script offers `browser` as its own top-level
    command candidate, not merely as a substring of `open-browser` or as a
    `--type browser` option value.
    """
    if shell == "zsh":
        # zsh's `_describe` candidates are emitted as 'name:abstract'.
        return "'browser:" in script
    if shell == "fish":
        # fish command candidates are emitted as `-fa 'name'`.
        return "-fa 'browser'" in script
    if shell == "bash":
        # bash lists all sibling command names as whitespace-separated words
        # inside a single `compgen -W '...'` string.
        return any(
            "browser" in match.group(1).split()
            for match in re.finditer(r"compgen -W '([^']*)'", script)
        )
    raise ValueError(f"unhandled shell: {shell}")


def resolve_cmux_cli() -> str:
    cli = os.environ.get("CMUX_CLI_BIN")
    if not cli or not os.access(cli, os.X_OK):
        raise RuntimeError("set CMUX_CLI_BIN to the built cmux binary")
    return cli


class SocketConnectionRecorder:
    """Ephemeral Unix socket that counts the connections it accepts.

    Completion scripts must be generated from the static command tree alone.
    Checking that the socket path never appears in the output is not enough:
    a regression can connect, fail to get useful candidates, and fall back
    silently. A real listener is the only way to observe the connection.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self.connections = 0
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)

    def __enter__(self) -> SocketConnectionRecorder:
        self._server.bind(self.path)
        self._server.listen(8)
        self._server.settimeout(0.05)
        self._thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self._stop.set()
        self._thread.join(timeout=2.0)
        self._server.close()

    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.connections += 1
            conn.close()


def run_completion(cli: str, shell: str) -> tuple[subprocess.CompletedProcess[str], str, int]:
    env = dict(os.environ)
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_SOCKET",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
        # Completion generation is a facade-only path. A legacy-parser override
        # inherited from CI or a developer shell would test the wrong parser.
        "CMUX_CLI_LEGACY_PARSER",
    ]:
        env.pop(key, None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    # A Unix socket path is capped near 104 bytes, so bind under a short
    # directory instead of the much longer platform temp directory.
    with tempfile.TemporaryDirectory(prefix="cmux-comp-", dir="/tmp") as tmpdir:
        socket_path = os.path.join(tmpdir, f"{uuid.uuid4().hex[:8]}.sock")
        env["CMUX_SOCKET_PATH"] = socket_path
        with SocketConnectionRecorder(socket_path) as recorder:
            proc = subprocess.run(
                [cli, "completion", shell],
                text=True,
                capture_output=True,
                check=False,
                timeout=5.0,
                env=env,
            )
        connections = recorder.connections

    return proc, socket_path, connections


def main() -> int:
    try:
        cli = resolve_cmux_cli()
    except RuntimeError as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []
    parsed_count = 0
    for shell, parse_command in SHELL_PARSE_COMMANDS.items():
        if shutil.which(shell) is None:
            print(f"SKIP: {shell} is not installed")
            continue

        try:
            completion, socket_path, socket_connections = run_completion(cli, shell)
        except subprocess.TimeoutExpired:
            failures.append(f"cmux completion {shell}: timed out")
            continue

        if socket_connections:
            failures.append(
                f"cmux completion {shell}: connected to the forced socket "
                f"{socket_path!r} {socket_connections} time(s); completion "
                f"generation must not consult a running cmux instance"
            )

        if completion.returncode != 0:
            failures.append(
                f"cmux completion {shell}: expected exit 0, got {completion.returncode}\n"
                f"stdout={completion.stdout!r}\nstderr={completion.stderr!r}"
            )
        if not completion.stdout:
            failures.append(f"cmux completion {shell}: expected non-empty stdout")
        if completion.stderr:
            failures.append(
                f"cmux completion {shell}: expected empty stderr, got {completion.stderr!r}"
            )

        output = f"{completion.stdout}{completion.stderr}"
        if socket_path in output:
            failures.append(
                f"cmux completion {shell}: consulted forced socket {socket_path!r}\n"
                f"stdout={completion.stdout!r}\nstderr={completion.stderr!r}"
            )

        if not completion.stdout:
            continue

        parser = subprocess.run(
            parse_command,
            input=completion.stdout,
            text=True,
            capture_output=True,
            check=False,
            timeout=5.0,
        )
        if parser.returncode != 0:
            failures.append(
                f"cmux completion {shell}: generated script did not parse\n"
                f"stdout={parser.stdout!r}\nstderr={parser.stderr!r}"
            )
            continue

        missing_tokens = [token for token in REQUIRED_TOKENS if token not in completion.stdout]
        if missing_tokens:
            failures.append(
                f"cmux completion {shell}: generated script is missing expected tokens {missing_tokens}"
            )
            continue

        if not has_shared_json_option(shell, completion.stdout):
            failures.append(
                f"cmux completion {shell}: generated script is missing the shared --json option"
            )
            continue

        if not has_structural_browser_command(shell, completion.stdout):
            failures.append(
                f"cmux completion {shell}: generated script is missing the 'browser' command candidate"
            )
            continue

        parsed_count += 1

    if failures:
        print("FAIL: completion script checks failed")
        print("\n\n".join(failures))
        return 1

    print(f"PASS: {parsed_count} completion scripts generated and parsed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
