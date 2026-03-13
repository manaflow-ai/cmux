#!/usr/bin/env python3
"""
Regression: the cmux zsh wrapper should prefer a bundled Ghostty zsh
integration file in CMUX_SHELL_INTEGRATION_DIR over the fallback integration
under GHOSTTY_RESOURCES_DIR.

Without this, tagged cmux builds can silently load Ghostty's installed app
integration instead of the version bundled with the build under test.
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

    base = Path("/tmp") / f"cmux_bundled_ghostty_zsh_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        home = base / "home"
        orig = base / "orig-zdotdir"
        bundled = base / "bundled-shell-integration"
        fallback = base / "ghostty-resources"
        marker = base / "marker.txt"

        home.mkdir(parents=True, exist_ok=True)
        orig.mkdir(parents=True, exist_ok=True)
        bundled.mkdir(parents=True, exist_ok=True)
        (fallback / "shell-integration" / "zsh").mkdir(parents=True, exist_ok=True)

        for filename in (".zshenv", ".zprofile", ".zshrc"):
            (orig / filename).write_text("", encoding="utf-8")

        (bundled / "ghostty-integration.zsh").write_text(
            'echo "bundled" >> "$CMUX_TEST_OUT"\n',
            encoding="utf-8",
        )
        (fallback / "shell-integration" / "zsh" / "ghostty-integration").write_text(
            'echo "fallback" >> "$CMUX_TEST_OUT"\n',
            encoding="utf-8",
        )

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["ZDOTDIR"] = str(wrapper_dir)
        env["GHOSTTY_ZSH_ZDOTDIR"] = str(orig)
        env["CMUX_SHELL_INTEGRATION_DIR"] = str(bundled)
        env["GHOSTTY_RESOURCES_DIR"] = str(fallback)
        env["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        env["CMUX_SHELL_INTEGRATION"] = "0"
        env["CMUX_TEST_OUT"] = str(marker)

        result = subprocess.run(
            ["zsh", "-d", "-i", "-c", "true"],
            env=env,
            capture_output=True,
            text=True,
            timeout=8,
        )
        if result.returncode != 0:
            print(f"FAIL: zsh exited non-zero rc={result.returncode}")
            combined = ((result.stdout or "") + (result.stderr or "")).strip()
            if combined:
                print(combined)
            return 1

        if not marker.exists():
            print("FAIL: no Ghostty integration marker was written")
            return 1

        entries = [
            line.strip()
            for line in marker.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        if entries != ["bundled"]:
            print(f"FAIL: expected only bundled integration, saw {entries!r}")
            return 1

        print("PASS: wrapper prefers bundled ghostty-integration.zsh over fallback resources")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
