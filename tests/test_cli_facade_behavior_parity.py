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
import tempfile

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
    (["browser", "wait", "--timeout", "abc"], "browser wait --timeout must stay legacy-validated"),
    (["browser", "wait", "--timeout-ms", "abc"], "browser wait --timeout-ms must stay legacy-validated"),
    (["browser", "download", "wait", "--timeout", "abc"], "browser download --timeout must stay legacy-validated"),
    (["browser", "download", "wait", "--timeout-ms", "abc"], "browser download --timeout-ms must stay legacy-validated"),
    (["browser", "cookies", "set", "--expires", "abc"], "browser cookies --expires must stay legacy-validated"),
    # Every facade option the legacy parser reads as a number must be declared
    # `String?`. A numeric declaration makes ArgumentParser reject the value
    # before `run()` delegates, so the legacy parser never sees it and never
    # applies its own validation or its fallback default.
    (["events", "--after", "abc"], "events --after must stay legacy-validated"),
    (["events", "--timeout", "abc"], "events --timeout must stay legacy-validated"),
    (["list-log", "--limit", "abc"], "list-log --limit must stay legacy-validated"),
    (["memory", "--groups", "abc"], "memory --groups must stay legacy-validated"),
    (["ssh", "--port", "abc"], "ssh --port must stay legacy-validated"),
    (["mosh", "--port", "abc"], "mosh --port must stay legacy-validated"),
    (["ssh-tmux", "--port", "abc"], "ssh-tmux --port must stay legacy-validated"),
    (["mosh-tmux", "--port", "abc"], "mosh-tmux --port must stay legacy-validated"),
    (["simulate-sidebar-drag", "--duration-ms", "abc"], "simulate-sidebar-drag --duration-ms must stay legacy-validated"),
    (["simulate-sidebar-drag", "--steps", "abc"], "simulate-sidebar-drag --steps must stay legacy-validated"),
    (["reorder-workspace", "--index", "abc"], "reorder-workspace --index must stay legacy-validated"),
    (["capture-pane", "--lines", "abc"], "capture-pane --lines must stay legacy-validated"),
    (["read-screen", "--lines", "abc"], "read-screen --lines must stay legacy-validated"),
    # The legacy parser falls back to a default instead of failing on these
    # two, so a numeric declaration would turn a working command into an error.
    (["resize-pane", "--amount", "abc"], "resize-pane --amount must reach the legacy fallback of 1"),
    (["wait-for", "--timeout", "abc"], "wait-for --timeout must reach the legacy fallback of 30"),
]

# Value-taking global options accept both `--name value` and `--name=value`.
# The two spellings must resolve the same command with the same result: the
# legacy parser once recognized only the space form and mistook `--window=w:1`
# for the command name, while facade routing already skipped it as an option.
GLOBAL_OPTION_EQUALS_OPTIONS: list[tuple[str, str]] = [
    ("--socket", "{socket_path}"),
    ("--password", "hunter2"),
    ("--window", "w:1"),
    ("--id-format", "uuids"),
]
GLOBAL_OPTION_EQUALS_COMMAND = ["list-workspaces"]

# `completion` is facade-native; the legacy parser has no equivalent command
# to compare against, so its exit code is pinned directly instead.
FACADE_ONLY_CASES: list[tuple[list[str], int, str]] = [
    (["completion", "tcsh"], 2, "facade-native CLIError must keep its declared exit code"),
]

# Cases where facade/legacy stderr is known and expected to diverge even
# though the exit code matches. `dismiss-notification` validates its
# --id/--all-read selector in FacadeValidationError before ever touching the
# socket; the legacy runner connects to the socket first for every command in
# its dispatch group, so it reports the (absent) socket instead of the
# selector requirement. Fixing the legacy connect-then-validate ordering is a
# larger, separate change, so this divergence is pinned here rather than
# weakening the stderr check for every case.
KNOWN_STDERR_DIVERGENCES: set[tuple[str, ...]] = {
    ("dismiss-notification",),
}


def run(cli: str, args: list[str], legacy: bool, socket_path: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "CMUX_SOCKET_PATH": socket_path}
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
    with tempfile.TemporaryDirectory() as tmpdir:
        socket_path = os.path.join(tmpdir, "cmux-facade-behavior-parity-absent.sock")
        for args, description in CASES:
            facade = run(cli, args, legacy=False, socket_path=socket_path)
            legacy = run(cli, args, legacy=True, socket_path=socket_path)
            stderr_diverges = (
                facade.stderr != legacy.stderr
                and tuple(args) not in KNOWN_STDERR_DIVERGENCES
            )
            if facade.returncode != legacy.returncode or stderr_diverges:
                failures.append(
                    f"cmux {' '.join(args)} ({description}): "
                    f"facade exit {facade.returncode} != legacy exit {legacy.returncode}\n"
                    f"  facade stderr: {facade.stderr.strip()!r}\n"
                    f"  legacy stderr: {legacy.stderr.strip()!r}"
                )

        for option, raw_value in GLOBAL_OPTION_EQUALS_OPTIONS:
            value = raw_value.format(socket_path=socket_path)
            spaced_args = [option, value, *GLOBAL_OPTION_EQUALS_COMMAND]
            equals_args = [f"{option}={value}", *GLOBAL_OPTION_EQUALS_COMMAND]
            for legacy in (False, True):
                spaced = run(cli, spaced_args, legacy=legacy, socket_path=socket_path)
                equals = run(cli, equals_args, legacy=legacy, socket_path=socket_path)
                if spaced.returncode == equals.returncode and spaced.stderr == equals.stderr:
                    continue
                parser = "legacy" if legacy else "facade"
                failures.append(
                    f"cmux {option}={value} {' '.join(GLOBAL_OPTION_EQUALS_COMMAND)} ({parser} parser): "
                    f"exit {equals.returncode} != exit {spaced.returncode} for the spaced spelling\n"
                    f"  equals stderr: {equals.stderr.strip()!r}\n"
                    f"  spaced stderr: {spaced.stderr.strip()!r}"
                )

        for args, expected_exit_code, description in FACADE_ONLY_CASES:
            facade = run(cli, args, legacy=False, socket_path=socket_path)
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

    total = len(CASES) + len(FACADE_ONLY_CASES) + len(GLOBAL_OPTION_EQUALS_OPTIONS) * 2
    print(f"PASS: {total} facade/legacy behavior parity cases match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
