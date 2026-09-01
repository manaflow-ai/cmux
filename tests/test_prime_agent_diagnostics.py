#!/usr/bin/env python3
"""Behavior coverage for the Prime Agent diagnostics directory override."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    diagnostics = repo_root / "skills" / "cmux-diagnostics" / "scripts" / "cmux-diagnostics"
    with tempfile.TemporaryDirectory(prefix="cmux-prime-agent-diagnostics-") as temp_dir:
        home = Path(temp_dir) / "home"
        override_dir = home / "custom-prime"
        extension = override_dir / "extensions" / "cmux-prime-agent-session.ts"
        extension.parent.mkdir(parents=True)
        extension.write_text("cmux hooks prime-agent\n", encoding="utf-8")

        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home),
                "PATH": "/usr/bin:/bin",
                "PRIME_AGENT_CODING_AGENT_DIR": str(override_dir),
            }
        )
        for key in ("CMUX_SOCKET", "CMUX_SOCKET_PATH", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID"):
            env.pop(key, None)
        result = subprocess.run(
            [str(diagnostics)],
            cwd=repo_root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )

    if result.returncode != 0:
        print(f"FAIL: diagnostics exited {result.returncode}: {result.stderr}")
        return 1
    prime_lines = [line for line in result.stdout.splitlines() if line.startswith("prime-agent:")]
    if not any(line.endswith("marker-present") for line in prime_lines):
        print(f"FAIL: override installation was not reported: {prime_lines!r}")
        return 1
    print("PASS: diagnostics honors PRIME_AGENT_CODING_AGENT_DIR")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
