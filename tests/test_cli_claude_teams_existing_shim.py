#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` reuses an existing tmux shim.
"""

from __future__ import annotations

import glob
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-shim-") as td:
        tmp = Path(td)
        home = tmp / "home"
        real_bin = tmp / "real-bin"
        home.mkdir(parents=True, exist_ok=True)
        real_bin.mkdir(parents=True, exist_ok=True)

        shim_dir = home / ".cmuxterm" / "claude-teams-bin"
        shim_dir.mkdir(parents=True, exist_ok=True)
        shim_path = shim_dir / "tmux"
        shim_path.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "exec \"${CMUX_CLAUDE_TEAMS_CMUX_BIN:-cmux}\" __tmux-compat \"$@\"\n",
            encoding="utf-8",
        )
        shim_path.chmod(0o555)
        shim_dir.chmod(0o555)

        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'shim=%s\\n' "$(command -v tmux)"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = f"{real_bin}:/usr/bin:/bin"

        proc = subprocess.run(
            [cli_path, "claude-teams", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )

        shim_dir.chmod(0o755)
        shim_path.chmod(0o755)

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams --version` failed with an existing shim")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        expected = str(shim_path)
        actual = proc.stdout.strip()
        if actual != f"shim={expected}":
            print(f"FAIL: expected existing shim path {expected!r}, got {actual!r}")
            return 1

    print("PASS: cmux claude-teams reuses an existing tmux shim")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
