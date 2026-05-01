#!/usr/bin/env python3
"""
Executable contract check for Swift ArgumentParser shell completions.

This exercises the real completion entry points on the built CLI binary. It
does not inspect Swift source.
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import tempfile
import uuid
from pathlib import Path


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates = [path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def no_socket_env() -> tuple[dict[str, str], str]:
    env = dict(os.environ)
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
    ]:
        env.pop(key, None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    no_socket = os.path.join(tempfile.gettempdir(), f"cmux-completion-{uuid.uuid4().hex}.sock")
    env["CMUX_SOCKET_PATH"] = no_socket
    env["CMUX_SOCKET"] = no_socket
    return env, no_socket


def run_cli(cli_path: str, args: list[str], timeout: float = 10.0) -> subprocess.CompletedProcess[str]:
    env, no_socket = no_socket_env()
    proc = subprocess.run(  # noqa: S603
        [cli_path, *args],
        text=True,
        capture_output=True,
        check=False,
        timeout=timeout,
        env=env,
    )
    merged = f"{proc.stdout}\n{proc.stderr}"
    if no_socket in merged:
        raise RuntimeError(f"completion command unexpectedly touched forced socket path {no_socket!r}")
    return proc


def load_inventory(cli_path: str) -> list[str]:
    proc = run_cli(cli_path, ["__argument-parser-inventory", "--verify", "--json"], timeout=20.0)
    if proc.returncode != 0:
        raise RuntimeError(
            "inventory command failed\n"
            f"stdout={proc.stdout!r}\nstderr={proc.stderr!r}"
        )
    payload = json.loads(proc.stdout)
    forms = payload.get("forms")
    if not isinstance(forms, list) or not forms:
        raise RuntimeError("inventory command returned no forms")
    return [str(form) for form in forms]


def raw_completion_candidates(
    cli_path: str,
    command_line: list[str],
    current_word_index: int,
    cursor_index: int,
) -> set[str]:
    proc = run_cli(
        cli_path,
        [
            "---completion",
            "--",
            "positional@0",
            str(current_word_index),
            str(cursor_index),
            *command_line,
        ],
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "completion callback failed for "
            f"command_line={command_line!r} current_word_index={current_word_index} cursor_index={cursor_index}\n"
            f"stdout={proc.stdout!r}\nstderr={proc.stderr!r}"
        )
    return {line.strip() for line in proc.stdout.splitlines() if line.strip()}


def completion_candidates(cli_path: str, completed_tokens: list[str], prefix: str = "") -> set[str]:
    command_line = ["cmux", *completed_tokens]
    if prefix:
        command_line.append(prefix)
    return raw_completion_candidates(
        cli_path,
        command_line,
        len(command_line) - 1,
        len(prefix),
    )


def assert_script(cli_path: str, shell: str) -> None:
    proc = run_cli(cli_path, ["--generate-completion-script", shell])
    if proc.returncode != 0:
        raise RuntimeError(
            f"{shell} completion script generation failed\n"
            f"stdout={proc.stdout!r}\nstderr={proc.stderr!r}"
        )
    script = proc.stdout
    required = {
        "zsh": ["#compdef cmux", "---completion", "--socket", "--json", "--id-format"],
        "bash": ["#!/bin/bash", "---completion", "--socket", "--json", "--id-format"],
        "fish": ["complete", "---completion", "-l 'socket'", "-l 'json'", "-l 'id-format'"],
    }[shell]
    for needle in required:
        if needle not in script:
            raise RuntimeError(f"{shell} completion script missing {needle!r}")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
        forms = load_inventory(cli_path)

        for shell in ["zsh", "bash", "fish"]:
            assert_script(cli_path, shell)

        failures: list[str] = []
        middle_prefixed = raw_completion_candidates(
            cli_path,
            ["cmux", "browser", "s", "tab", "new"],
            2,
            1,
        )
        if "screenshot" not in middle_prefixed:
            failures.append(
                "middle-of-line completion for 'cmux browser s tab new' did not ignore trailing tokens; "
                f"got {sorted(middle_prefixed)!r}"
            )

        middle_empty = raw_completion_candidates(
            cli_path,
            ["cmux", "browser", "tab", "new"],
            2,
            0,
        )
        if "tab" not in middle_empty:
            failures.append(
                "empty middle-of-line completion for 'cmux browser tab new' did not suggest browser subcommands; "
                f"got {sorted(middle_empty)!r}"
            )

        for form in forms:
            tokens = form.split()
            for index, expected in enumerate(tokens):
                completed = tokens[:index]
                candidates = completion_candidates(cli_path, completed)
                if expected not in candidates:
                    failures.append(
                        f"{form}: completing after {completed!r} did not include {expected!r}; "
                        f"got {sorted(candidates)!r}"
                    )
                    continue

                prefix = expected[: min(3, len(expected))]
                if prefix and prefix != expected:
                    prefixed = completion_candidates(cli_path, completed, prefix)
                    if expected not in prefixed:
                        failures.append(
                            f"{form}: completing prefix {prefix!r} after {completed!r} "
                            f"did not include {expected!r}; got {sorted(prefixed)!r}"
                        )

        if failures:
            print("FAIL: CLI shell completion coverage failed")
            for failure in failures:
                print("")
                print(failure)
            return 1

        print(f"PASS: CLI shell completion covers {len(forms)} command forms for zsh, bash, and fish")
        return 0
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
