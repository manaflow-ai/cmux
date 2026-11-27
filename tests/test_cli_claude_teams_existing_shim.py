#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` launches through the managed Claude wrapper.

The wrapper is what injects Claude hooks/session identity while preserving the
`claudeTeams` launch capture used to build a structured restore command. A
direct launch of the resolved Claude binary appears to work until cmux restarts,
when every team pane restores as an unbound shell.
"""

from __future__ import annotations

import base64
import os
import shutil
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


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip() if path.exists() else ""


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

        tmux_path_log = tmp / "tmux-path.log"
        launch_kind_log = tmp / "launch-kind.log"
        launch_argv_log = tmp / "launch-argv.log"
        wrapper_marker_log = tmp / "wrapper-marker.log"
        claude_argv_log = tmp / "claude-argv.log"

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

        wrapper_source = (
            Path(__file__).resolve().parents[1]
            / "Resources"
            / "bin"
            / "cmux-claude-wrapper"
        )
        shutil.copyfile(wrapper_source, cmux_shim_bin / "claude")
        (cmux_shim_bin / "claude").chmod(0o755)
        # The production wrapper lives beside the bundled cmux CLI and uses it
        # for its bounded socket-ownership probe. This fixture copies the wrapper
        # into the per-surface directory, so provide the equivalent sibling seam.
        make_executable(cmux_shim_bin / "cmux", "#!/usr/bin/env bash\nexit 0\n")
        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$(command -v tmux)" > "$FAKE_TMUX_PATH_LOG"
printf '%s\\n' "${CMUX_AGENT_LAUNCH_KIND-__UNSET__}" > "$FAKE_LAUNCH_KIND_LOG"
printf '%s\\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-__UNSET__}" > "$FAKE_LAUNCH_ARGV_LOG"
printf '%s\\n' "${CMUX_CLAUDE_TEAMS_WRAPPER_LAUNCH-__UNSET__}" > "$FAKE_WRAPPER_MARKER_LOG"
printf '%s\\n' "$@" > "$FAKE_CLAUDE_ARGV_LOG"
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
        env["CMUX_BUNDLED_CLI_PATH"] = cli_path
        env["CMUX_SOCKET_CAPABILITY"] = "claude-teams-test-capability"
        env["FAKE_TMUX_PATH_LOG"] = str(tmux_path_log)
        env["FAKE_LAUNCH_KIND_LOG"] = str(launch_kind_log)
        env["FAKE_LAUNCH_ARGV_LOG"] = str(launch_argv_log)
        env["FAKE_WRAPPER_MARKER_LOG"] = str(wrapper_marker_log)
        env["FAKE_CLAUDE_ARGV_LOG"] = str(claude_argv_log)
        socket_path = tmp / "cmux.sock"

        with focused_cmux_server(socket_path, surface_id=surface_id) as (
            live_socket_path,
            _,
        ):
            env["CMUX_SOCKET_PATH"] = live_socket_path
            proc = subprocess.run(
                [cli_path, "claude-teams", "restore wrapper capture"],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )

        shim_dir.chmod(0o755)
        shim_path.chmod(0o755)

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams` failed with an existing managed wrapper")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        expected = str(cmux_shim_bin / "tmux")
        actual = read_text(tmux_path_log)
        if actual != expected:
            print(f"FAIL: expected managed shim path {expected!r}, got {actual!r}")
            return 1

        claude_argv = read_text(claude_argv_log).splitlines()
        if "--session-id" not in claude_argv or "--settings" not in claude_argv:
            print(
                "FAIL: managed Claude wrapper did not inject session identity and hooks; "
                f"argv={claude_argv!r}"
            )
            return 1

        launch_kind = read_text(launch_kind_log)
        if launch_kind != "claudeTeams":
            print(
                "FAIL: wrapper did not preserve the Claude Teams restore capture; "
                f"CMUX_AGENT_LAUNCH_KIND={launch_kind!r}"
            )
            return 1

        try:
            launch_argv = (
                base64.b64decode(read_text(launch_argv_log), validate=True)
                .decode("utf-8")
                .split("\0")
            )
        except (ValueError, UnicodeDecodeError) as exc:
            print(f"FAIL: invalid Claude Teams restore argv capture: {exc}")
            return 1
        if launch_argv and launch_argv[-1] == "":
            launch_argv.pop()
        if (
            len(launch_argv) < 3
            or Path(launch_argv[0]).resolve() != Path(cli_path).resolve()
            or launch_argv[1] != "claude-teams"
            or "restore wrapper capture" not in launch_argv
        ):
            print(f"FAIL: unexpected Claude Teams restore argv capture: {launch_argv!r}")
            return 1

        wrapper_marker = read_text(wrapper_marker_log)
        if wrapper_marker != "__UNSET__":
            print(f"FAIL: one-shot wrapper marker leaked into Claude: {wrapper_marker!r}")
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

    print(
        "PASS: managed Claude wrapper captures a restorable Teams session and "
        "ordinary tmux still delegates"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
