#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` prefers the managed per-surface shim root.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import (
    FOCUSED_WORKSPACE_ID,
    canonical_managed_claude_shim_root,
    focused_cmux_server,
    resolve_cmux_cli,
)


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with (
        tempfile.TemporaryDirectory(prefix="cmux-claude-teams-shim-") as td,
        canonical_managed_claude_shim_root() as (surface_id, cmux_shim_bin),
    ):
        tmp = Path(td)
        home = tmp / "home"
        second_cmux_shim_bin = tmp / "cmux-cli-shims" / "99999999-9999-4999-8999-999999999999"
        real_bin = tmp / "real-bin"
        home.mkdir(parents=True, exist_ok=True)
        second_cmux_shim_bin.mkdir(parents=True, exist_ok=True)
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
            cmux_shim_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
echo cmux-claude-command-shim-should-not-run
exit 42
""",
        )
        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'shim=%s\\n' "$(command -v tmux)"
""",
        )
        make_executable(
            real_bin / "tmux",
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf 'real-tmux:%s\\n' \"$*\"\n",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = f"{cmux_shim_bin}:{real_bin}:/usr/bin:/bin"
        env["TMPDIR"] = str(tmp)
        env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(cmux_shim_bin / "claude")
        env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(cmux_shim_bin)
        env["CMUX_WORKSPACE_ID"] = FOCUSED_WORKSPACE_ID
        env["CMUX_SURFACE_ID"] = surface_id
        socket_path = tmp / "cmux.sock"

        with focused_cmux_server(socket_path, surface_id=surface_id) as (
            live_socket_path,
            _,
        ):
            env["CMUX_SOCKET_PATH"] = live_socket_path
            proc = subprocess.run(
                [cli_path, "claude-teams", "--version"],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )

        shim_dir.chmod(0o755)
        shim_path.chmod(0o755)

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams --version` failed with an existing shim")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        expected = str(cmux_shim_bin / "tmux")
        actual = proc.stdout.strip()
        if actual != f"shim={expected}":
            print(f"FAIL: expected managed shim path {expected!r}, got {actual!r}")
            return 1

        managed_shim = cmux_shim_bin / "tmux"
        second_managed_shim = second_cmux_shim_bin / "tmux"
        second_managed_shim.write_bytes(managed_shim.read_bytes())
        second_managed_shim.chmod(0o755)

        marker_free_env = env.copy()
        marker_free_env.pop("CMUX_CLAUDE_TEAMS_CMUX_BIN", None)
        marker_free_env["PATH"] = (
            f"{cmux_shim_bin}:{second_cmux_shim_bin}:{real_bin}:/usr/bin:/bin"
        )
        delegated = subprocess.run(
            ["tmux", "display-message", "marker-free"],
            capture_output=True,
            text=True,
            check=False,
            env=marker_free_env,
            timeout=30,
        )
        if delegated.returncode != 0:
            print("FAIL: persistent shim did not delegate marker-free tmux invocation")
            print(f"exit={delegated.returncode}")
            print(f"stdout={delegated.stdout.strip()}")
            print(f"stderr={delegated.stderr.strip()}")
            return 1
        if delegated.stdout.strip() != "real-tmux:display-message marker-free":
            print(
                "FAIL: marker-free invocation did not reach the real tmux through "
                f"multiple managed shims: {delegated.stdout.strip()!r}"
            )
            return 1

    print("PASS: managed teams shim routes only marked launches and delegates ordinary tmux")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
