#!/usr/bin/env python3
"""
Regression: scrollback replay must not depend on PATH containing coreutils.

cmux can launch shells with PATH initially pointing at app resources. If replay
relies on bare `cat`/`rm`, startup replay silently fails before user rc files
restore PATH.
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

    base = Path("/tmp") / f"cmux_scrollback_restore_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        replay_file = base / "replay.txt"
        replay_file.write_text("scrollback-line-1\nscrollback-line-2\n", encoding="utf-8")

        env = dict(os.environ)
        env["PATH"] = str(base / "empty-bin")
        env["CMUX_RESTORE_SCROLLBACK_FILE"] = str(replay_file)
        env["CMUX_TEST_INTEGRATION_SCRIPT"] = str(integration_script)

        result = subprocess.run(
            ["/bin/zsh", "-f", "-c", 'source "$CMUX_TEST_INTEGRATION_SCRIPT"'],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            print(f"FAIL: zsh exited non-zero rc={result.returncode}")
            if result.stderr.strip():
                print(result.stderr.strip())
            return 1

        output = (result.stdout or "") + (result.stderr or "")
        if "scrollback-line-1" not in output or "scrollback-line-2" not in output:
            print("FAIL: replay text was not printed during integration startup")
            return 1

        if replay_file.exists():
            print("FAIL: replay file was not deleted after replay")
            return 1

        print("PASS: scrollback replay works with minimal PATH")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
