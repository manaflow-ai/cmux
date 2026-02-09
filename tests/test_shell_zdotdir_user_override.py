#!/usr/bin/env python3
"""
Regression: if the user's .zshenv changes ZDOTDIR, then .zshrc should be sourced
from the updated ZDOTDIR (matching vanilla zsh semantics).

Why this matters for cmuxterm:
- cmuxterm sets ZDOTDIR to the app wrapper directory so zsh loads wrapper
  startup files.
- The wrapper .zshenv temporarily restores ZDOTDIR to the original directory
  while sourcing the user's real .zshenv.
- Some users set ZDOTDIR in their .zshenv to point to a dotfiles directory that
  contains their real .zshrc (and plugin setup like zsh-autosuggestions).

If we clobber that user-chosen ZDOTDIR before sourcing .zshrc, interactive
startup behavior diverges from Ghostty/vanilla zsh and plugins may not load.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "Resources" / "shell-integration"
    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing wrapper .zshenv at {wrapper_dir}")
        return 0

    base = Path("/tmp") / f"cmux_zdotdir_user_override_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        orig = base / "orig"
        alt = base / "alt"
        home = base / "home"
        orig.mkdir(parents=True, exist_ok=True)
        alt.mkdir(parents=True, exist_ok=True)
        home.mkdir(parents=True, exist_ok=True)

        out_path = base / "sourced.txt"

        # User .zshenv that redirects ZDOTDIR to an alternate directory.
        # This is a common pattern for dotfiles-managed setups.
        (orig / ".zshenv").write_text(
            f'export ZDOTDIR="{alt}"\n',
            encoding="utf-8",
        )

        # Two competing .zshrc files to prove which directory was honored.
        (orig / ".zshrc").write_text(
            f'echo "orig" > "{out_path}"\n',
            encoding="utf-8",
        )
        (alt / ".zshrc").write_text(
            f'echo "alt" > "{out_path}"\n',
            encoding="utf-8",
        )

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["ZDOTDIR"] = str(wrapper_dir)
        env["CMUX_ZSH_ZDOTDIR"] = str(orig)
        env["CMUX_SHELL_INTEGRATION"] = "0"

        # Interactive is required for .zshrc; -d disables global rc files for isolation.
        result = subprocess.run(
            ["zsh", "-d", "-i", "-c", "true"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            print("FAIL: zsh exited non-zero")
            if result.stderr.strip():
                print(result.stderr.strip())
            return 1

        if not out_path.exists():
            print("FAIL: no output file created (user .zshrc did not run?)")
            return 1

        seen = out_path.read_text(encoding="utf-8").strip()
        if seen != "alt":
            print(f"FAIL: expected .zshrc from alt ZDOTDIR, got {seen!r}")
            print(f"  orig={orig}")
            print(f"  alt={alt}")
            return 1

        print("PASS: .zshrc sourced from user-updated ZDOTDIR")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
