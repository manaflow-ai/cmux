#!/usr/bin/env python3
"""Regression: cmux shell hooks reset Ghostty cursor without forcing bar mode."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHELL_DIR = ROOT / "Resources" / "shell-integration"
CURSOR_RESET = "\x1b[0 q"


def _run(argv: list[str], script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [*argv, script],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _assert_bash_cursor_reset() -> None:
    script_path = SHELL_DIR / "cmux-bash-integration.bash"
    enabled = _run(
        ["bash", "--noprofile", "--norc", "-c"],
        f'source "{script_path}"; CMUX_GHOSTTY_CURSOR_RESET=1; _cmux_reset_ghostty_cursor_if_needed',
    )
    _must(enabled.returncode == 0, f"bash reset helper failed: {enabled.stderr!r}")
    _must(enabled.stdout == CURSOR_RESET, f"bash reset helper emitted {enabled.stdout!r}")

    disabled = _run(
        ["bash", "--noprofile", "--norc", "-c"],
        f'source "{script_path}"; CMUX_GHOSTTY_CURSOR_RESET=0; _cmux_reset_ghostty_cursor_if_needed',
    )
    _must(disabled.returncode == 0, f"bash disabled helper failed: {disabled.stderr!r}")
    _must(disabled.stdout == "", f"bash disabled helper emitted {disabled.stdout!r}")

    prompt = _run(
        ["bash", "--noprofile", "--norc", "-c"],
        (
            f'source "{script_path}"; '
            "CMUX_GHOSTTY_CURSOR_RESET=1; "
            "CMUX_TAB_ID=; "
            "_cmux_preexec_command 'echo ok'; "
            "_cmux_prompt_command"
        ),
    )
    _must(prompt.returncode == 0, f"bash prompt hooks failed: {prompt.stderr!r}")
    _must(
        prompt.stdout.count(CURSOR_RESET) >= 2,
        f"bash preexec/prompt hooks did not reset cursor twice: {prompt.stdout!r}",
    )


def _assert_zsh_cursor_reset() -> None:
    if shutil.which("zsh") is None:
        print("SKIP: zsh is not installed")
        return

    script_path = SHELL_DIR / "cmux-zsh-integration.zsh"
    enabled = _run(
        ["zsh", "-f", "-c"],
        f'source "{script_path}"; CMUX_GHOSTTY_CURSOR_RESET=1; _cmux_reset_ghostty_cursor_if_needed',
    )
    _must(enabled.returncode == 0, f"zsh reset helper failed: {enabled.stderr!r}")
    _must(enabled.stdout == CURSOR_RESET, f"zsh reset helper emitted {enabled.stdout!r}")

    disabled = _run(
        ["zsh", "-f", "-c"],
        f'source "{script_path}"; CMUX_GHOSTTY_CURSOR_RESET=0; _cmux_reset_ghostty_cursor_if_needed',
    )
    _must(disabled.returncode == 0, f"zsh disabled helper failed: {disabled.stderr!r}")
    _must(disabled.stdout == "", f"zsh disabled helper emitted {disabled.stdout!r}")

    prompt = _run(
        ["zsh", "-f", "-c"],
        (
            f'source "{script_path}"; '
            "CMUX_GHOSTTY_CURSOR_RESET=1; "
            "CMUX_TAB_ID=; "
            "_cmux_preexec 'echo ok'; "
            "_cmux_precmd"
        ),
    )
    _must(prompt.returncode == 0, f"zsh prompt hooks failed: {prompt.stderr!r}")
    _must(
        prompt.stdout.count(CURSOR_RESET) >= 2,
        f"zsh preexec/precmd hooks did not reset cursor twice: {prompt.stdout!r}",
    )


def main() -> int:
    _assert_bash_cursor_reset()
    _assert_zsh_cursor_reset()
    print("PASS: shell integration cursor reset honors CMUX_GHOSTTY_CURSOR_RESET")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
