#!/usr/bin/env python3
"""Checks generated shell-completion scripts without a running cmux socket."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import uuid


SHELL_PARSE_COMMANDS = {
    "bash": ["bash", "-n"],
    "zsh": ["zsh", "-n"],
    "fish": ["fish", "--no-execute"],
}

# Representative tokens that must survive generation: a top-level leaf
# command, a nested subcommand family, and an option shared across commands.
# A script that parses but omits all of these has silently dropped commands.
REQUIRED_TOKENS = ["list-workspaces", "browser", "--json"]


def resolve_cmux_cli() -> str:
    cli = os.environ.get("CMUX_CLI_BIN")
    if not cli or not os.access(cli, os.X_OK):
        raise RuntimeError("set CMUX_CLI_BIN to the built cmux binary")
    return cli


def run_completion(cli: str, shell: str) -> tuple[subprocess.CompletedProcess[str], str]:
    env = dict(os.environ)
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_SOCKET",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
    ]:
        env.pop(key, None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    with tempfile.TemporaryDirectory(prefix="cmux-completion-no-socket-") as tmpdir:
        socket_path = os.path.join(tmpdir, f"socket-{uuid.uuid4().hex}.sock")
        env["CMUX_SOCKET_PATH"] = socket_path
        proc = subprocess.run(
            [cli, "completion", shell],
            text=True,
            capture_output=True,
            check=False,
            timeout=5.0,
            env=env,
        )

    return proc, socket_path


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
            completion, socket_path = run_completion(cli, shell)
        except subprocess.TimeoutExpired:
            failures.append(f"cmux completion {shell}: timed out")
            continue

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

        parsed_count += 1

    if failures:
        print("FAIL: completion script checks failed")
        print("\n\n".join(failures))
        return 1

    print(f"PASS: {parsed_count} completion scripts generated and parsed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
