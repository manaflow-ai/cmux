#!/usr/bin/env python3
"""
Regression: exec-string zsh wrapper must not overwrite a user-selected HISTFILE.

The wrapper keeps ZDOTDIR pointed at Resources/shell-integration until its own
.zshrc runs for `zsh -i -c`. That means /etc/zshrc may derive HISTFILE from the
wrapper directory first. The wrapper is allowed to repair that wrapper-derived
default, but it must not clobber an explicit HISTFILE chosen by the user's real
.zshenv, .zprofile, or .zshrc.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


def main() -> int:
    """Run an exec-string shell and ensure a user-set HISTFILE survives startup."""
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "Resources" / "shell-integration"
    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing wrapper .zshenv at {wrapper_dir}")
        return 0

    base = Path("/tmp") / f"cmux_histfile_exec_string_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        home = base / "home"
        orig = base / "orig"
        home.mkdir(parents=True, exist_ok=True)
        orig.mkdir(parents=True, exist_ok=True)

        custom_histfile = base / "custom-history" / "zsh-history"
        custom_histfile.parent.mkdir(parents=True, exist_ok=True)

        (orig / ".zshenv").write_text("", encoding="utf-8")
        (orig / ".zshrc").write_text(
            f'export HISTFILE="{custom_histfile}"\n',
            encoding="utf-8",
        )

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["ZDOTDIR"] = str(wrapper_dir)
        env["CMUX_ZSH_ZDOTDIR"] = str(orig)
        env["CMUX_SHELL_INTEGRATION"] = "0"

        result = subprocess.run(
            ["zsh", "-d", "-i", "-c", 'print -r -- "$HISTFILE"'],
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
            print("FAIL: no HISTFILE output captured from exec-string shell")
            return 1

        seen = lines[-1]
        expected = str(custom_histfile)
        if seen != expected:
            print(f"FAIL: HISTFILE={seen!r}, expected {expected!r}")
            return 1

        print("PASS: exec-string wrapper preserves user-selected HISTFILE")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
