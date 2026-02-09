#!/usr/bin/env python3
"""
Regression: cmuxterm relies on Ghostty's xterm-ghostty terminfo entry.

In cmuxterm (embedded GhosttyKit), "bright" SGR 90-97 can render incorrectly
for some palettes. zsh-autosuggestions defaults to `fg=8`, which historically
resolved to SGR 90 via terminfo `setaf`.

cmuxterm ships a terminfo overlay that forces bright colors to use indexed
256-color sequences (`38;5;<n>` / `48;5;<n>`) instead of SGR 90-97/100-107.
This test ensures the overlay remains in place.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def run_tput(args: list[str], *, terminfo_dir: Path, term: str) -> bytes:
    env = dict(os.environ)
    env["TERMINFO"] = str(terminfo_dir)
    env["TERM"] = term
    return subprocess.check_output(["tput", *args], env=env)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    overlay = root / "Resources" / "terminfo-overlay"
    if not overlay.exists():
        print(f"FAIL: missing overlay dir: {overlay}")
        return 1

    term = "xterm-ghostty"

    setaf8 = run_tput(["setaf", "8"], terminfo_dir=overlay, term=term).hex()
    setab8 = run_tput(["setab", "8"], terminfo_dir=overlay, term=term).hex()
    setaf7 = run_tput(["setaf", "7"], terminfo_dir=overlay, term=term).hex()
    setaf16 = run_tput(["setaf", "16"], terminfo_dir=overlay, term=term).hex()

    # Expect \e[38;5;8m and \e[48;5;8m for bright black.
    exp_setaf8 = "1b5b33383b353b386d"
    exp_setab8 = "1b5b34383b353b386d"
    # Expect standard 8-color white for 7: \e[37m
    exp_setaf7 = "1b5b33376d"
    # Expect 256-color for 16: \e[38;5;16m
    exp_setaf16 = "1b5b33383b353b31366d"

    if setaf8 != exp_setaf8:
        print(f"FAIL: setaf 8 = {setaf8}, expected {exp_setaf8}")
        return 1
    if setab8 != exp_setab8:
        print(f"FAIL: setab 8 = {setab8}, expected {exp_setab8}")
        return 1
    if setaf7 != exp_setaf7:
        print(f"FAIL: setaf 7 = {setaf7}, expected {exp_setaf7}")
        return 1
    if setaf16 != exp_setaf16:
        print(f"FAIL: setaf 16 = {setaf16}, expected {exp_setaf16}")
        return 1

    print("PASS: terminfo overlay uses 256-color sequences for bright colors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

