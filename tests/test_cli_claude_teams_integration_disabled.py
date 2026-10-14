#!/usr/bin/env python3
"""
Regression test for https://github.com/manaflow-ai/cmux/issues/17571.

With Settings > Automation > Claude Code integration turned off, the app does
not install the per-surface `claude` shim (#13590), so the surface exports no
CMUX_CLAUDE_WRAPPER_SHIM_ROOT. It still installs the per-surface agent command
shim directory and exports it as CMUX_AGENT_COMMAND_SHIM_ROOT, together with
CMUX_CLAUDE_INTEGRATION_DISABLED=1 (see TerminalSurface+RuntimeSurfaceCreation).

0.65.0 required the Claude shim root and refused every `cmux claude-teams`
launch from such a surface with "must be launched from a cmux-managed terminal
surface". This test builds the environment exactly as the app exports it with
the integration off and requires that Teams:

- launches the user's real `claude` directly (no wrapper, no hook injection),
- puts the tmux shim in the surface's agent command shim directory, which is
  the directory Claude's shell snapshot keeps on PATH,
- still refuses when the integration is on but the Claude shim is missing, and
- refuses an agent shim root that belongs to another surface.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import uuid
from pathlib import Path

from claude_teams_test_utils import (
    FOCUSED_WORKSPACE_ID,
    focused_cmux_server,
    resolve_cmux_cli,
)

MANAGED_TERMINAL_REQUIRED = "must be launched from a cmux-managed terminal surface"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip() if path.exists() else ""


def install_surface_shims(home: Path, surface_id: str) -> Path:
    """Mirror the app's install with the Claude integration off.

    The live app roots per-surface shims at ~/.cmuxterm/cmux-cli-shims and,
    with Claude disabled, installs every other bundled agent shim but not
    `claude`.
    """
    root = home / ".cmuxterm" / "cmux-cli-shims" / surface_id
    root.mkdir(parents=True)
    for directory in (root.parent.parent, root.parent, root):
        directory.chmod(0o700)
    make_executable(root / "codex", "#!/usr/bin/env bash\nexit 0\n")
    return root


def run_claude_teams(
    cli_path: str,
    env: dict[str, str],
    surface_id: str,
    tmp: Path,
) -> subprocess.CompletedProcess[str]:
    with focused_cmux_server(tmp / "cmux.sock", surface_id=surface_id) as (
        live_socket_path,
        _,
    ):
        env = env.copy()
        env["CMUX_SOCKET_PATH"] = live_socket_path
        return subprocess.run(
            [cli_path, "claude-teams", "integration off prompt"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-integration-off-") as td:
        tmp = Path(td)
        home = tmp / "home"
        real_bin = tmp / "real-bin"
        real_bin.mkdir(parents=True)
        surface_id = str(uuid.uuid4())
        agent_root = install_surface_shims(home, surface_id)

        tmux_path_log = tmp / "tmux-path.log"
        claude_argv_log = tmp / "claude-argv.log"
        wrapper_marker_log = tmp / "wrapper-marker.log"
        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$(command -v tmux)" > "$FAKE_TMUX_PATH_LOG"
printf '%s\\n' "${CMUX_CLAUDE_TEAMS_WRAPPER_LAUNCH-__UNSET__}" > "$FAKE_WRAPPER_MARKER_LOG"
printf '%s\\n' "$@" > "$FAKE_CLAUDE_ARGV_LOG"
""",
        )

        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("CMUX") and not key.startswith("CLAUDE")
        }
        env.update(
            {
                "HOME": str(home),
                "TMPDIR": str(tmp),
                "PATH": f"{agent_root}:{real_bin}:/usr/bin:/bin",
                "CMUX_WORKSPACE_ID": FOCUSED_WORKSPACE_ID,
                "CMUX_SURFACE_ID": surface_id,
                "CMUX_BUNDLED_CLI_PATH": cli_path,
                "CMUX_SOCKET_CAPABILITY": "claude-teams-test-capability",
                "CMUX_AGENT_COMMAND_SHIM_ROOT": str(agent_root),
                "CMUX_CODEX_WRAPPER_SHIM": str(agent_root / "codex"),
                "CMUX_CODEX_WRAPPER_SHIM_ROOT": str(agent_root),
                "CMUX_CLAUDE_INTEGRATION_DISABLED": "1",
                "CMUX_CLAUDE_HOOKS_DISABLED": "1",
                "FAKE_TMUX_PATH_LOG": str(tmux_path_log),
                "FAKE_CLAUDE_ARGV_LOG": str(claude_argv_log),
                "FAKE_WRAPPER_MARKER_LOG": str(wrapper_marker_log),
            }
        )

        # 1. Integration off: Teams launches the real claude with tmux beside it.
        proc = run_claude_teams(cli_path, env, surface_id, tmp)
        if proc.returncode != 0:
            failures.append(
                "claude-teams refused to launch with the Claude integration off "
                f"(exit={proc.returncode} stderr={proc.stderr.strip()!r})"
            )
        else:
            expected_tmux = str(agent_root / "tmux")
            actual_tmux = read_text(tmux_path_log)
            if actual_tmux != expected_tmux:
                failures.append(
                    f"tmux resolved to {actual_tmux!r}, expected the surface shim {expected_tmux!r}"
                )
            claude_argv = read_text(claude_argv_log).splitlines()
            if "integration off prompt" not in claude_argv:
                failures.append(f"real claude did not receive the prompt: argv={claude_argv!r}")
            if "--settings" in claude_argv or "--session-id" in claude_argv:
                failures.append(
                    f"hooks were injected although the integration is off: argv={claude_argv!r}"
                )
            if read_text(wrapper_marker_log) != "__UNSET__":
                failures.append("the one-shot wrapper marker leaked into a direct claude launch")
            if (agent_root / "claude").exists():
                failures.append("claude-teams installed a claude shim the integration toggle removed")

        # 1b. Claude shim keys inherited from a parent cmux surface (for example
        #     when cmux itself was started from a cmux terminal) must not win
        #     over this surface's own agent shim root while the integration is
        #     off: the app exports no Claude shim keys for such a surface.
        parent_root = home / ".cmuxterm" / "cmux-cli-shims" / str(uuid.uuid4())
        parent_root.mkdir()
        parent_root.chmod(0o700)
        make_executable(parent_root / "claude", "#!/usr/bin/env bash\nexit 97\n")
        inherited_env = env.copy()
        inherited_env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(parent_root)
        inherited_env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(parent_root / "claude")
        # The parent's shim directory is inherited on PATH too; its claude must
        # never run, and this run must write its own tmux shim.
        inherited_env["PATH"] = f"{agent_root}:{parent_root}:{real_bin}:/usr/bin:/bin"
        (agent_root / "tmux").unlink(missing_ok=True)
        tmux_path_log.unlink(missing_ok=True)
        proc = run_claude_teams(cli_path, inherited_env, surface_id, tmp)
        if proc.returncode != 0:
            failures.append(
                "inherited Claude shim keys from another surface blocked Teams with "
                f"the integration off (exit={proc.returncode} stderr={proc.stderr.strip()!r})"
            )
        elif read_text(tmux_path_log) != str(agent_root / "tmux"):
            failures.append(
                f"tmux resolved to {read_text(tmux_path_log)!r} with inherited Claude shim keys"
            )
        if (parent_root / "tmux").exists():
            failures.append("claude-teams wrote tmux into a parent surface's Claude shim root")

        # 2. Integration on but the Claude shim is missing: keep refusing, since
        #    launching without hooks would silently drop session tracking.
        enabled_env = env.copy()
        enabled_env["CMUX_CLAUDE_INTEGRATION_DISABLED"] = "0"
        enabled_env.pop("CMUX_CLAUDE_HOOKS_DISABLED")
        proc = run_claude_teams(cli_path, enabled_env, surface_id, tmp)
        if proc.returncode == 0 or MANAGED_TERMINAL_REQUIRED not in proc.stderr:
            failures.append(
                "claude-teams launched with the integration on but no Claude shim "
                f"(exit={proc.returncode} stderr={proc.stderr.strip()!r})"
            )

        # 3. An agent shim root owned by another surface is not trusted.
        other_root = install_surface_shims(home, str(uuid.uuid4()))
        foreign_env = env.copy()
        foreign_env["CMUX_AGENT_COMMAND_SHIM_ROOT"] = str(other_root)
        foreign_env["PATH"] = f"{other_root}:{real_bin}:/usr/bin:/bin"
        proc = run_claude_teams(cli_path, foreign_env, surface_id, tmp)
        if proc.returncode == 0 or MANAGED_TERMINAL_REQUIRED not in proc.stderr:
            failures.append(
                "claude-teams trusted another surface's shim root "
                f"(exit={proc.returncode} stderr={proc.stderr.strip()!r})"
            )
        if (other_root / "tmux").exists():
            failures.append("claude-teams wrote tmux into another surface's shim root")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: claude-teams launches with the Claude integration off and keeps its guards")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
