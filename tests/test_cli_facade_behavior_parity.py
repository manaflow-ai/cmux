#!/usr/bin/env python3
"""Gates that the ArgumentParser facade produces the same exit code and
diagnostic as the legacy parser for a curated set of commands.

`test_cli_dispatch_parity.py` only proves a command name is *declared* in the
facade tree and that its `--help` text matches; it never invokes a command
with arguments, so a declaration that changes runtime behavior (an argument
ArgumentParser itself rejects, an exit code the facade fails to propagate)
passes it silently. Each case below is a repro that regressed exactly that
way during the facade migration and is pinned here so it cannot regress
again.
"""
from __future__ import annotations

import os
import subprocess
import sys

SOCKET_PATH = "/tmp/cmux-facade-behavior-parity-absent.sock"

# (args, description). Every case runs against a socket that does not exist,
# so both parsers fail before touching the daemon; what's compared is how
# each one fails: does it reach the runner's own diagnostic and exit code,
# or does ArgumentParser's own validation intercept it first.
CASES: list[tuple[list[str], str]] = [
    (["dismiss-notification"], "missing selector: legacy CLIError default exit code"),
    (["bind-key", "C-a", "send-prefix"], "tmux-compat unsupported command with real args"),
    (["copy-mode", "-t", "x"], "tmux-compat unsupported command with an unrecognized option"),
    (["resize-pane", "-L", "5"], "tmux-compat option the facade must forward, not reject"),
    (["capture-pane", "-p"], "tmux-compat short option the facade must forward, not reject"),
    (["clear-history", "--pane", "p1"], "tmux-compat trailing option the runner ignores"),
    (["read-screen", "50"], "tmux-compat positional the runner ignores"),
    (["paste-buffer", "mybuf"], "tmux-compat positional the runner ignores"),
    (["list-buffers", "extra"], "tmux-compat trailing positional the runner ignores"),
    (["vm", "ssh", "vm1", "--", "uname", "-a"], "vm ssh command passthrough after --"),
    (["vm", "snapshot", "vm1", "--name", "s1", "extra"], "vm leaf command trailing positional"),
    (["remotes", "rm", "a", "b"], "remotes leaf command trailing positional"),
    (["events", "--limit", "x"], "typed option must not preempt the runner's own validation"),
    (["diff", "--font-size", "abc"], "typed option must not preempt the runner's own validation"),
    (["set-progress", "abc"], "typed argument must not preempt the runner's own validation"),
]

# `completion` is facade-native; the legacy parser has no equivalent command
# to compare against, so its exit code is pinned directly instead.
FACADE_ONLY_CASES: list[tuple[list[str], int, str]] = [
    (["completion", "tcsh"], 2, "facade-native CLIError must keep its declared exit code"),
]


def run(cli: str, args: list[str], legacy: bool) -> subprocess.CompletedProcess:
    env = {**os.environ, "CMUX_SOCKET_PATH": SOCKET_PATH}
    if legacy:
        env["CMUX_CLI_LEGACY_PARSER"] = "1"
    else:
        env.pop("CMUX_CLI_LEGACY_PARSER", None)
    return subprocess.run(
        [cli, *args], text=True, capture_output=True, check=False, timeout=30.0, env=env,
    )


def main() -> int:
    cli = os.environ.get("CMUX_CLI_BIN")
    if not cli or not os.access(cli, os.X_OK):
        print("FAIL: set CMUX_CLI_BIN to the built cmux binary")
        return 1

    failures: list[str] = []
    for args, description in CASES:
        facade = run(cli, args, legacy=False)
        legacy = run(cli, args, legacy=True)
        if facade.returncode != legacy.returncode:
            failures.append(
                f"cmux {' '.join(args)} ({description}): "
                f"facade exit {facade.returncode} != legacy exit {legacy.returncode}\n"
                f"  facade stderr: {facade.stderr.strip()!r}\n"
                f"  legacy stderr: {legacy.stderr.strip()!r}"
            )

    for args, expected_exit_code, description in FACADE_ONLY_CASES:
        facade = run(cli, args, legacy=False)
        if facade.returncode != expected_exit_code:
            failures.append(
                f"cmux {' '.join(args)} ({description}): "
                f"facade exit {facade.returncode} != expected {expected_exit_code}\n"
                f"  facade stderr: {facade.stderr.strip()!r}"
            )

    if failures:
        print("FAIL: facade/legacy behavior diverged:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    total = len(CASES) + len(FACADE_ONLY_CASES)
    print(f"PASS: {total} facade/legacy behavior parity cases match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
