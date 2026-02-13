#!/usr/bin/env python3
"""
Regression: GhosttyKit already injects zsh shell integration by setting ZDOTDIR
to Ghostty's own integration directory (and optionally preserving a user-set
ZDOTDIR in GHOSTTY_ZSH_ZDOTDIR).

cmux also injects its own zsh integration by setting ZDOTDIR to
Resources/shell-integration. If cmux incorrectly treats Ghostty's injected
ZDOTDIR as the "user" ZDOTDIR, zsh history will be isolated to the integration
directory rather than the user's HOME/ZDOTDIR, breaking cross-terminal history
and therefore zsh-autosuggestions.

This test simulates that stacked injection scenario and asserts HISTFILE ends
up at $HOME/.zsh_history (not inside Ghostty's integration directory).
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


def _run_zsh_print_histfile(env: dict[str, str]) -> tuple[int, str]:
    # A PTY is not required for this regression: we only need /etc/zshrc to run
    # and set HISTFILE based on the restored ZDOTDIR/HOME.
    result = subprocess.run(
        ["zsh", "-ic", 'print -r -- "$HISTFILE"'],
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
    )
    return (result.returncode, (result.stdout or "") + (result.stderr or ""))


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    cmux_wrapper_dir = root / "Resources" / "shell-integration"
    ghostty_zsh_dir = root / "ghostty" / "src" / "shell-integration" / "zsh"

    if not (cmux_wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing cmux wrapper .zshenv at {cmux_wrapper_dir}")
        return 0
    if not (ghostty_zsh_dir / ".zshenv").exists():
        print(f"SKIP: missing Ghostty zsh .zshenv at {ghostty_zsh_dir}")
        return 0

    base = Path("/tmp") / f"cmux_histfile_ghostty_stack_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)
        home = base / "home"
        home.mkdir(parents=True, exist_ok=True)

        env = dict(os.environ)
        env["HOME"] = str(home)
        env.pop("HISTFILE", None)
        # Keep this test focused and deterministic: don't run Ghostty's heavy zsh
        # integration when executing under a PTY in CI/agent runs.
        env.pop("GHOSTTY_RESOURCES_DIR", None)
        env.pop("GHOSTTY_SHELL_FEATURES", None)
        env.pop("GHOSTTY_BIN_DIR", None)

        # Simulate the buggy situation: cmux stores Ghostty's injected ZDOTDIR
        # as the "original" ZDOTDIR, then sets ZDOTDIR to its own wrapper.
        env["CMUX_ORIGINAL_ZDOTDIR"] = str(ghostty_zsh_dir)
        env["ZDOTDIR"] = str(cmux_wrapper_dir)
        env["CMUX_SHELL_INTEGRATION"] = "0"

        rc, out = _run_zsh_print_histfile(env)
        if rc != 0:
            print(f"FAIL: zsh exited non-zero rc={rc}")
            return 1

        lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
        if not lines:
            print("FAIL: no output captured from zsh")
            return 1
        seen = lines[-1]
        expected = str(home / ".zsh_history")
        if seen != expected:
            print(f"FAIL: HISTFILE={seen!r}, expected {expected!r}")
            print(f"  cmux_wrapper_dir={cmux_wrapper_dir}")
            print(f"  ghostty_zsh_dir={ghostty_zsh_dir}")
            return 1

        print("PASS: HISTFILE resolves to user home history (not Ghostty integration dir)")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
