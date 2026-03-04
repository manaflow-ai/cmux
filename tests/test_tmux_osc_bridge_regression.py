#!/usr/bin/env python3
"""
Regression checks for tmux OSC bridge wiring.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


def repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path.cwd()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    root = repo_root()
    cli_file = root / "CLI" / "cmux.swift"
    zsh_file = root / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"
    bash_file = root / "Resources" / "shell-integration" / "cmux-bash-integration.bash"

    failures: list[str] = []

    cli = cli_file.read_text(encoding="utf-8")
    zsh = zsh_file.read_text(encoding="utf-8")
    bash = bash_file.read_text(encoding="utf-8")

    expect('"tmux-osc-bridge"' in cli, "CLI missing tmux-osc-bridge command registration", failures)
    expect("Usage: cmux tmux-osc-bridge" in cli, "CLI missing tmux-osc-bridge help text", failures)
    expect("notification.create_for_target" in cli, "tmux bridge should forward via notification.create_for_target", failures)
    expect("bridgeShouldRestartForNotificationError" in cli, "tmux bridge should only restart on connectivity errors", failures)
    expect("notify_failed_stale_target" in cli, "tmux bridge should drop stale pane mappings on per-target notification errors", failures)
    expect("@cmux_socket_path" in cli, "tmux bridge should scope pane mappings to cmux socket path", failures)
    expect("stale_pid_unverified_skip_terminate" in cli, "ensure mode should avoid killing unverified reused PIDs", failures)
    expect("bridgeProcessMatchesRecord" in cli, "ensure mode should verify PID identity before reusing existing bridge process", failures)
    expect('path.hasSuffix(" (deleted)")' in cli, "bridge health checks should ignore deleted socket descriptors", failures)
    expect("path.contains(expectedSocketPath)" not in cli, "bridge health checks should not use substring matches for socket paths", failures)
    expect(
        "if byte == 0x5C { // \\\n                        state = .normal\n                        flushDCS" in cli,
        "DCS passthrough parser should reset state before flushDCS",
        failures,
    )
    expect(
        'split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)' in cli,
        "OSC 777 parser should preserve semicolons in body text",
        failures,
    )
    expect("parseExtendedOutputPayload" in cli and 'range(of: " : ")' in cli, "extended-output parsing should decode payload after ':' delimiter", failures)
    expect("@cmux_workspace_id" in zsh, "zsh integration must publish pane workspace mapping", failures)
    expect("@cmux_surface_id" in zsh, "zsh integration must publish pane surface mapping", failures)
    expect("@cmux_socket_path" in zsh, "zsh integration must publish pane socket mapping", failures)
    expect("set-option -gq @cmux_workspace_id" in zsh, "zsh integration should seed tmux global workspace mapping before attach", failures)
    expect("set-option -gq @cmux_surface_id" in zsh, "zsh integration should seed tmux global surface mapping before attach", failures)
    expect("tmux-osc-bridge" in zsh and "--tmux-socket" in zsh, "zsh integration must auto-start tmux bridge", failures)
    expect("\ntmux() {\n" in zsh and "_cmux_tmux_prepare_launch" in zsh, "zsh integration should wrap tmux command to initialize bridge context", failures)
    expect("@cmux_workspace_id" in bash, "bash integration must publish pane workspace mapping", failures)
    expect("@cmux_surface_id" in bash, "bash integration must publish pane surface mapping", failures)
    expect("@cmux_socket_path" in bash, "bash integration must publish pane socket mapping", failures)
    expect("set-option -gq @cmux_workspace_id" in bash, "bash integration should seed tmux global workspace mapping before attach", failures)
    expect("set-option -gq @cmux_surface_id" in bash, "bash integration should seed tmux global surface mapping before attach", failures)
    expect("tmux-osc-bridge" in bash and "--tmux-socket" in bash, "bash integration must auto-start tmux bridge", failures)
    expect("\ntmux() {\n" in bash and "_cmux_tmux_prepare_launch" in bash, "bash integration should wrap tmux command to initialize bridge context", failures)

    if failures:
        print("tmux osc bridge regression tests failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: tmux osc bridge wiring regressions are covered.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
