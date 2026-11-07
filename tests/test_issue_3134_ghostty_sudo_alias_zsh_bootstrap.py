#!/usr/bin/env python3
"""
Regression for issue #3134:
cmux's zsh bootstrap should load Ghostty's integration without letting a user
alias like `alias sudo='sudo '` break Ghostty's `sudo()` wrapper definition.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER_DIR = ROOT / "Resources" / "shell-integration"


def main() -> int:
    if not (WRAPPER_DIR / ".zshenv").exists():
        print(f"SKIP: missing wrapper .zshenv at {WRAPPER_DIR}")
        return 0
    if shutil.which("zsh") is None:
        print("SKIP: zsh is not installed")
        return 0

    base = Path(tempfile.mkdtemp(prefix="cmux_issue_3134_"))
    try:

        home = base / "home"
        orig = base / "orig-zdotdir"
        bundled = base / "bundled-shell-integration"
        marker = base / "marker.txt"

        home.mkdir(parents=True, exist_ok=True)
        orig.mkdir(parents=True, exist_ok=True)
        bundled.mkdir(parents=True, exist_ok=True)

        (orig / ".zshenv").write_text("alias sudo='sudo '\n", encoding="utf-8")
        for filename in (".zprofile", ".zshrc"):
            (orig / filename).write_text("", encoding="utf-8")

        # Use the real Ghostty-style `sudo()` definition here: with
        # `alias sudo='sudo '`, zsh can choke while parsing this exact form.
        (bundled / "ghostty-integration.zsh").write_text(
            "sudo() { :; }\n"
            'print -r -- "loaded" >> "$CMUX_TEST_OUT"\n',
            encoding="utf-8",
        )

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["ZDOTDIR"] = str(WRAPPER_DIR)
        env["GHOSTTY_ZSH_ZDOTDIR"] = str(orig)
        env["CMUX_SHELL_INTEGRATION_DIR"] = str(bundled)
        env["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        env["CMUX_SHELL_INTEGRATION"] = "0"
        env["CMUX_TEST_OUT"] = str(marker)

        result = subprocess.run(
            ["zsh", "-d", "-i", "-c", "true"],
            env=env,
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )

        combined = ((result.stdout or "") + (result.stderr or "")).strip()
        if result.returncode != 0:
            print(f"FAIL: zsh exited non-zero rc={result.returncode}")
            if combined:
                print(combined)
            return 1

        if not marker.exists():
            print("FAIL: Ghostty integration was not loaded")
            if combined:
                print(combined)
            return 1

        entries = [
            line.strip()
            for line in marker.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        if entries != ["loaded"]:
            print(f"FAIL: unexpected marker entries {entries!r}")
            return 1

        print("PASS: cmux zsh bootstrap loads Ghostty integration even when sudo is aliased")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
