#!/usr/bin/env python3
"""
Regression for issue #734:
cmux wrapper .zshenv should only source Ghostty zsh integration when Ghostty
actually enabled shell integration (signaled by GHOSTTY_ZSH_ZDOTDIR being set).
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


def _run_case(
    *,
    wrapper_dir: Path,
    home: Path,
    orig_zdotdir: Path,
    ghostty_resources: Path,
    out_path: Path,
    ghostty_enabled: bool,
) -> tuple[int, str]:
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["ZDOTDIR"] = str(wrapper_dir)
    env["GHOSTTY_RESOURCES_DIR"] = str(ghostty_resources)
    env["CMUX_SHELL_INTEGRATION"] = "0"
    env["CMUX_TEST_OUT"] = str(out_path)

    # Keep input deterministic and local to this test.
    for key in (
        "GHOSTTY_ZSH_ZDOTDIR",
        "CMUX_ZSH_ZDOTDIR",
        "CMUX_ORIGINAL_ZDOTDIR",
        "GHOSTTY_SHELL_FEATURES",
        "GHOSTTY_BIN_DIR",
    ):
        env.pop(key, None)

    if ghostty_enabled:
        env["GHOSTTY_ZSH_ZDOTDIR"] = str(orig_zdotdir)
    else:
        env["CMUX_ZSH_ZDOTDIR"] = str(orig_zdotdir)

    result = subprocess.run(
        ["zsh", "-d", "-i", "-c", "true"],
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
    )
    return (result.returncode, (result.stdout or "") + (result.stderr or ""))


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "Resources" / "shell-integration"
    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing wrapper .zshenv at {wrapper_dir}")
        return 0

    base = Path("/tmp") / f"cmux_issue_734_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        home = base / "home"
        orig = base / "orig-zdotdir"
        resources = base / "ghostty-resources"
        home.mkdir(parents=True, exist_ok=True)
        orig.mkdir(parents=True, exist_ok=True)
        (resources / "shell-integration" / "zsh").mkdir(parents=True, exist_ok=True)

        # Keep user startup files inert and local.
        for filename in (".zshenv", ".zprofile", ".zshrc"):
            (orig / filename).write_text("", encoding="utf-8")

        marker = base / "ghostty-sourced.txt"
        (resources / "shell-integration" / "zsh" / "ghostty-integration").write_text(
            'echo "sourced" >> "$CMUX_TEST_OUT"\n',
            encoding="utf-8",
        )

        rc, out = _run_case(
            wrapper_dir=wrapper_dir,
            home=home,
            orig_zdotdir=orig,
            ghostty_resources=resources,
            out_path=marker,
            ghostty_enabled=False,
        )
        if rc != 0:
            print(f"FAIL: zsh exited non-zero when ghostty_enabled=False rc={rc}")
            if out.strip():
                print(out.strip())
            return 1
        if marker.exists():
            print("FAIL: ghostty integration sourced when Ghostty shell integration was disabled")
            return 1

        rc, out = _run_case(
            wrapper_dir=wrapper_dir,
            home=home,
            orig_zdotdir=orig,
            ghostty_resources=resources,
            out_path=marker,
            ghostty_enabled=True,
        )
        if rc != 0:
            print(f"FAIL: zsh exited non-zero when ghostty_enabled=True rc={rc}")
            if out.strip():
                print(out.strip())
            return 1
        if not marker.exists():
            print("FAIL: ghostty integration not sourced when Ghostty shell integration was enabled")
            return 1

        contents = marker.read_text(encoding="utf-8")
        if "sourced" not in contents:
            print("FAIL: expected marker output missing after enabled run")
            return 1

        print("PASS: wrapper respects Ghostty shell-integration=none via GHOSTTY_ZSH_ZDOTDIR gate")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
