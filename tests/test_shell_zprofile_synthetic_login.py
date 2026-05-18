#!/usr/bin/env python3
"""
Regression for issue #4253:
cmux should source the user's .zprofile for a top-level zsh pane even when the
underlying zsh process did not enter login mode early enough for zsh's normal
startup-file selection to do it.

The app marks that top-level pane with CMUX_ZSH_SOURCE_LOGIN_PROFILE. The zsh
wrapper must restore the user's real ZDOTDIR, run the user's .zshenv first, and
then source .zprofile once for this synthetic login-profile path.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def run_startup_case(
    *,
    wrapper_dir: Path,
    base: Path,
    name: str,
    login: bool,
) -> tuple[bool, str]:
    home = base / f"{name}-home"
    orig = base / f"{name}-orig-zdotdir"
    home.mkdir(parents=True, exist_ok=True)
    orig.mkdir(parents=True, exist_ok=True)

    out_path = base / f"{name}-startup-order.txt"
    (orig / ".zshenv").write_text(
        f'echo "{name}:zshenv:$ZDOTDIR" >> "{out_path}"\n',
        encoding="utf-8",
    )
    (orig / ".zprofile").write_text(
        f'echo "{name}:zprofile:$ZDOTDIR" >> "{out_path}"\n',
        encoding="utf-8",
    )

    env = dict(os.environ)
    env["HOME"] = str(home)
    env["ZDOTDIR"] = str(wrapper_dir)
    env["CMUX_ZSH_ZDOTDIR"] = str(orig)
    env["CMUX_ZSH_SOURCE_LOGIN_PROFILE"] = "1"
    env["CMUX_SHELL_INTEGRATION"] = "0"

    args = ["zsh", "-d", "-i"]
    if login:
        args.append("-l")
    args.extend(["-c", "true"])

    result = subprocess.run(
        args,
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
    )
    if result.returncode != 0:
        combined = ((result.stdout or "") + (result.stderr or "")).strip()
        return (False, f"{name}: zsh exited non-zero rc={result.returncode}\n{combined}")

    if not out_path.exists():
        return (False, f"{name}: no startup marker was written")

    lines = [
        line.strip()
        for line in out_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    expected = [f"{name}:zshenv:{orig}", f"{name}:zprofile:{orig}"]
    if lines != expected:
        return (False, f"{name}: expected startup order {expected!r}, saw {lines!r}")

    return (True, "")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "Resources" / "shell-integration"
    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing wrapper .zshenv at {wrapper_dir}")
        return 0

    base = Path(tempfile.mkdtemp(prefix="cmux_zprofile_synthetic_login_"))
    try:
        cases = [
            ("synthetic", False),
            ("native-login", True),
        ]
        for name, login in cases:
            passed, message = run_startup_case(
                wrapper_dir=wrapper_dir,
                base=base,
                name=name,
                login=login,
            )
            if not passed:
                print(f"FAIL: {message}")
                return 1

        print("PASS: synthetic login zsh path sources .zprofile after .zshenv")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
