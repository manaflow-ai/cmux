#!/usr/bin/env python3
"""
Regression: user zsh startup files must run at top level, not inside helper
functions that localize plain `typeset` declarations.

When the cmux wrapper sources the real .zshenv/.zprofile/.zshrc inside a shell
function, `typeset -x NAME=value` becomes function-local in zsh and disappears
after the helper returns. Vanilla zsh sources these files at top level, so the
typed globals must still be visible to later startup files and the final
interactive command.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    """Ensure plain `typeset -x` assignments survive login exec-string startup."""
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "Resources" / "shell-integration"
    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing wrapper .zshenv at {wrapper_dir}")
        return 0
    zsh_path = shutil.which("zsh")
    if zsh_path is None:
        print("SKIP: zsh not installed")
        return 0

    base = Path(tempfile.mkdtemp(prefix=f"cmux_zdotfile_typeset_scope_{os.getpid()}_"))
    try:
        home = base / "home"
        orig = base / "orig"
        home.mkdir(parents=True, exist_ok=True)
        orig.mkdir(parents=True, exist_ok=True)

        (orig / ".zshenv").write_text(
            'typeset -x CMUX_TYPED_FROM_ZSHENV="env-scope"\n',
            encoding="utf-8",
        )
        (orig / ".zprofile").write_text(
            'typeset -x CMUX_TYPED_FROM_ZPROFILE="profile-scope"\n',
            encoding="utf-8",
        )
        (orig / ".zshrc").write_text(
            'typeset -x CMUX_TYPED_FROM_ZSHRC="rc-scope"\n',
            encoding="utf-8",
        )

        env = dict(os.environ)
        for key in (
            "GHOSTTY_ZSH_ZDOTDIR",
            "GHOSTTY_RESOURCES_DIR",
            "CMUX_SHELL_INTEGRATION_DIR",
            "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION",
        ):
            env.pop(key, None)
        env["HOME"] = str(home)
        env["ZDOTDIR"] = str(wrapper_dir)
        env["CMUX_ZSH_ZDOTDIR"] = str(orig)
        env["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "0"
        env["CMUX_SHELL_INTEGRATION"] = "0"

        result = subprocess.run(
            [
                zsh_path,
                "-d",
                "-l",
                "-i",
                "-c",
                'print -r -- "${CMUX_TYPED_FROM_ZSHENV-unset}|${CMUX_TYPED_FROM_ZPROFILE-unset}|${CMUX_TYPED_FROM_ZSHRC-unset}"',
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=8,
        )
        if result.returncode != 0:
            print(f"FAIL: zsh exited non-zero rc={result.returncode}")
            if result.stderr.strip():
                print(result.stderr.strip())
            return 1

        lines = [line.strip() for line in (result.stdout or "").splitlines() if line.strip()]
        if not lines:
            print("FAIL: no startup-scope output captured from login exec-string shell")
            return 1

        seen = lines[-1]
        expected = "env-scope|profile-scope|rc-scope"
        if seen != expected:
            print(f"FAIL: typed startup globals={seen!r}, expected {expected!r}")
            return 1

        print("PASS: typed globals from .zshenv/.zprofile/.zshrc survive wrapper startup")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
