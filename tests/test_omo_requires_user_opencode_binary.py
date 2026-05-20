#!/usr/bin/env python3
"""
Regression test: `cmux omo` requires a PATH-resolved user opencode binary.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-omo-missing-opencode-") as td:
        root = Path(td)
        fake_home = root / "home"
        fake_home.mkdir(parents=True, exist_ok=True)
        fake_hit = root / "opencode-hit.txt"
        fake_opencode = root / "opencode"
        fake_opencode.write_text(
            "#!/bin/sh\n"
            f"printf 'EXECUTED\\n' > {fake_hit}\n",
            encoding="utf-8",
        )
        fake_opencode.chmod(0o755)

        env = os.environ.copy()
        env["HOME"] = str(fake_home)
        env["PATH"] = ":"

        proc = subprocess.run(
            [cli_path, "omo", "--version"],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode == 0:
            print("FAIL: `cmux omo --version` succeeded without a PATH-resolved opencode binary")
            return 1

        if fake_hit.exists():
            print("FAIL: missing opencode resolution fell through to execvp current-directory lookup")
            return 1

        if "opencode is not installed or not on PATH" not in proc.stderr:
            print("FAIL: expected a clear missing opencode binary error")
            print(f"stderr={proc.stderr.strip()}")
            return 1

    print("PASS: cmux omo requires a PATH-resolved user opencode binary")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
