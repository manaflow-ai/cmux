#!/usr/bin/env python3
"""
Regression: ANSI color escape bytes in replay content must be preserved.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    integration_script = root / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"
    if not integration_script.exists():
        print(f"SKIP: missing zsh integration script at {integration_script}")
        return 0

    base = Path("/tmp") / f"cmux_scrollback_color_replay_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        replay_file = base / "replay.bin"
        replay_file.write_bytes(b"\x1b[31mRED\x1b[0m\n")

        env = dict(os.environ)
        env["PATH"] = str(base / "empty-bin")
        env["CMUX_RESTORE_SCROLLBACK_FILE"] = str(replay_file)
        env["CMUX_TEST_INTEGRATION_SCRIPT"] = str(integration_script)

        result = subprocess.run(
            ["/bin/zsh", "-f", "-c", 'source "$CMUX_TEST_INTEGRATION_SCRIPT"'],
            env=env,
            capture_output=True,
            timeout=5,
        )
        if result.returncode != 0:
            print(f"FAIL: zsh exited non-zero rc={result.returncode}")
            if result.stderr:
                print(result.stderr.decode("utf-8", errors="replace").strip())
            return 1

        output = (result.stdout or b"") + (result.stderr or b"")
        if b"\x1b[31mRED\x1b[0m" not in output:
            print("FAIL: ANSI color escape sequence not preserved in replay output")
            return 1

        if replay_file.exists():
            print("FAIL: replay file was not deleted after replay")
            return 1

        print("PASS: ANSI color escape sequence preserved during replay")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
