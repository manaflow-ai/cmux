#!/usr/bin/env python3
"""
Regression: zsh wrapper startup files must source user files with the *original*
ZDOTDIR, not the wrapper directory.

The cmuxterm zsh integration sets ZDOTDIR to the app's wrapper directory so zsh
loads wrapper .zshenv/.zprofile/.zshrc. Those wrappers must temporarily restore
ZDOTDIR while sourcing the user's real startup files so $ZDOTDIR semantics match
normal zsh behavior.
"""

from __future__ import annotations

import os
import subprocess
import sys
import shutil
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "Resources" / "shell-integration"
    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing wrapper .zshenv at {wrapper_dir}")
        return 0

    base = Path("/tmp") / f"cmux_zdotdir_test_{os.getpid()}"
    try:
        if base.exists():
            for child in base.iterdir():
                try:
                    child.unlink()
                except Exception:
                    pass
        base.mkdir(parents=True, exist_ok=True)

        orig = base / "orig"
        orig.mkdir(parents=True, exist_ok=True)
        seen_path = base / "seen.txt"

        # User .zshenv that records the ZDOTDIR it sees.
        (orig / ".zshenv").write_text(
            'echo "$ZDOTDIR" > "$CMUX_ZDOTDIR_TEST_OUTPUT"\n',
            encoding="utf-8",
        )

        env = dict(os.environ)
        env["ZDOTDIR"] = str(wrapper_dir)
        env["CMUX_ZSH_ZDOTDIR"] = str(orig)
        env["CMUX_ZDOTDIR_TEST_OUTPUT"] = str(seen_path)
        env["CMUX_SHELL_INTEGRATION"] = "0"

        # Non-interactive is enough: .zshenv is always sourced.
        result = subprocess.run(
            ["zsh", "-c", "true"],
            env=env,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print("FAIL: zsh exited non-zero")
            print(result.stderr.strip())
            return 1

        if not seen_path.exists():
            print("FAIL: user .zshenv did not run (no output file created)")
            return 1

        seen = seen_path.read_text(encoding="utf-8").strip()
        expected = str(orig)
        if seen != expected:
            print(f"FAIL: user .zshenv saw ZDOTDIR={seen!r}, expected {expected!r}")
            return 1

        print("PASS: zsh user startup files see original ZDOTDIR")
        return 0

    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
