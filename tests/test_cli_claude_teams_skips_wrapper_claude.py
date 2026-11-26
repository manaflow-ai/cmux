#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` skips cmux wrapper scripts on PATH.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-wrapper-") as td:
        tmp = Path(td)
        wrapper_bin = tmp / "wrapper-bin"
        real_bin = tmp / "real-bin"
        logs = tmp / "logs"
        wrapper_bin.mkdir(parents=True, exist_ok=True)
        real_bin.mkdir(parents=True, exist_ok=True)
        logs.mkdir(parents=True, exist_ok=True)

        real_hit = logs / "real-hit.txt"

        make_executable(
            wrapper_bin / "claude",
            """#!/usr/bin/env bash
# cmux claude wrapper - injects hooks and session tracking
set -euo pipefail
echo WRAPPER_EXECUTED >&2
exit 91
""",
        )

        make_executable(
            real_bin / "claude",
            f"""#!/usr/bin/env bash
set -euo pipefail
printf 'REAL\\n' > {real_hit}
""",
        )

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_bin}:{real_bin}:/usr/bin:/bin"

        proc = subprocess.run(
            [cli_path, "claude-teams", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams --version` executed a wrapper instead of the real claude binary")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        if not real_hit.exists():
            print("FAIL: real claude binary was not reached")
            return 1

    print("PASS: cmux claude-teams skips cmux wrapper scripts on PATH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
