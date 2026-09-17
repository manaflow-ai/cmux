#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` preserves fallback provider dirs in PATH.
"""

from __future__ import annotations

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


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with (
        tempfile.TemporaryDirectory(prefix="cmux-claude-teams-fallback-path-") as td,
        canonical_managed_claude_shim_root() as (live_surface_id, live_managed_bin),
    ):
        tmp = Path(td)
        home = tmp / "home"
        fallback_bin = home / ".bun" / "bin"
        managed_bin = tmp / "cmux-cli-shims" / "99999999-9999-4999-8999-999999999999"
        fallback_bin.mkdir(parents=True, exist_ok=True)
        managed_bin.mkdir(parents=True, exist_ok=True)

        make_executable(
            managed_bin / "claude",
            "#!/usr/bin/env bash\necho managed-claude-shim-must-not-run >&2\nexit 42\n",
        )
        wrapper_source = (
            Path(__file__).resolve().parents[1]
            / "Resources"
            / "bin"
            / "cmux-claude-wrapper"
        )
        shutil.copyfile(wrapper_source, live_managed_bin / "claude")
        (live_managed_bin / "claude").chmod(0o755)
        # The production wrapper probes this sibling CLI to verify that the
        # live surface socket is still owned by cmux. Keep that probe live in
        # the fixture while leaving the provider itself under our control.
        make_executable(live_managed_bin / "cmux", "#!/usr/bin/env bash\nexit 0\n")

        claude_log = tmp / "claude.log"
        codex_log = tmp / "codex.log"

        make_executable(
            fallback_bin / "claude-node-helper",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'helper:%s\\n' "$0"
""",
        )
        make_executable(
            fallback_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'ran\n' > "$FAKE_CLAUDE_LOG"
command -v claude-node-helper
claude-node-helper
""",
        )
        make_executable(
            fallback_bin / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex fake 1.0\\n'
  exit 0
fi
printf 'ran\n' > "$FAKE_CODEX_LOG"
exit 86
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = "/usr/bin:/bin"
        env["TMPDIR"] = str(tmp)
        env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(managed_bin / "claude")
        env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(managed_bin)
        env["FAKE_CLAUDE_LOG"] = str(claude_log)
        env["FAKE_CODEX_LOG"] = str(codex_log)
        env.pop("CMUX_CUSTOM_CLAUDE_PATH", None)

        proc = subprocess.run(
            [cli_path, "claude-teams", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams --version` failed with Claude in a fallback dir")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        lines = proc.stdout.strip().splitlines()
        expected_helper = str(fallback_bin / "claude-node-helper")
        if lines != [expected_helper, f"helper:{expected_helper}"]:
            print(f"FAIL: expected fallback helper to remain on PATH, got {lines!r}")
            return 1

        claude_log.unlink()
        unmanaged_env = env.copy()
        unmanaged_env.pop("CMUX_CLAUDE_WRAPPER_SHIM", None)
        unmanaged_env.pop("CMUX_CLAUDE_WRAPPER_SHIM_ROOT", None)

        informational = subprocess.run(
            [cli_path, "claude-teams", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=unmanaged_env,
            timeout=30,
        )
        if informational.returncode != 0 or not claude_log.exists():
            print("FAIL: unmanaged informational invocation should retain compatibility fallback")
            return 1
        claude_log.unlink()

        codex_version = subprocess.run(
            [cli_path, "codex-teams", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=unmanaged_env,
            timeout=30,
        )
        if codex_version.returncode != 0 or codex_version.stdout.strip() != "codex fake 1.0":
            print("FAIL: unmanaged Codex Teams version invocation required a live surface")
            return 1
        if codex_log.exists():
            print("FAIL: Codex Teams version invocation started a real team")
            return 1

        for command in (
            "auth",
            "auto-mode",
            "doctor",
            "gateway",
            "install",
            "kill",
            "logs",
            "mcp",
            "plugin",
            "plugins",
            "project",
            "rm",
            "setup-token",
            "stop",
            "update",
            "upgrade",
        ):
            management = subprocess.run(
                [cli_path, "claude-teams", command],
                capture_output=True,
                text=True,
                check=False,
                env=unmanaged_env,
                timeout=30,
            )
            if management.returncode != 0 or not claude_log.exists():
                print(f"FAIL: Claude management command {command!r} required a live surface")
                return 1
            claude_log.unlink()

        for management_args in (
            ("agents", "--json"),
            ("agents", "--all", "--json"),
            ("daemon", "logs"),
            ("daemon", "status"),
            ("daemon", "stop"),
            ("daemon", "uninstall"),
            ("daemon", "--json-path", "/tmp/cmux-daemon.json", "status"),
        ):
            management = subprocess.run(
                [cli_path, "claude-teams", *management_args],
                capture_output=True,
                text=True,
                check=False,
                env=unmanaged_env,
                timeout=30,
            )
            if management.returncode != 0 or not claude_log.exists():
                print(f"FAIL: Claude management invocation {management_args!r} required a live surface")
                return 1
            claude_log.unlink()

        for real_args in (
            ["agents"],
            ["agents", "--all"],
            ["agents", "--json", "prompt"],
            ["daemon"],
            ["daemon", "run"],
            ["start a team"],
            ["--tmux", "explain --version"],
            ["--model", "config"],
            ["--append-system-prompt", "doctor"],
            ["--tmux", "config"],
            ["--", "config"],
            ["please", "config"],
            ["--unknown-option", "config"],
            ["--continue", "config"],
            ["--remote-control", "session-name", "auth"],
            ["api-key"],
            ["config"],
            ["rc"],
            ["remote-control"],
            ["ultrareview"],
        ):
            unmanaged = subprocess.run(
                [cli_path, "claude-teams", *real_args],
                capture_output=True,
                text=True,
                check=False,
                env=unmanaged_env,
                timeout=30,
            )
            if unmanaged.returncode == 0:
                print(f"FAIL: unmanaged real launch succeeded for args {real_args!r}")
                return 1
            if claude_log.exists():
                print(f"FAIL: unmanaged real launch reached Claude for args {real_args!r}")
                return 1
            if not unmanaged.stderr.strip():
                print(f"FAIL: unmanaged launch lacked actionable guidance for args {real_args!r}")
                return 1

        contextless = subprocess.run(
            [cli_path, "claude-teams", "start a team"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )
        if contextless.returncode == 0 or claude_log.exists():
            print("FAIL: real Teams launch accepted a managed root without a live surface context")
            return 1

        with focused_cmux_server(tmp / "focused-cmux.sock") as (socket_path, requests):
            focused_env = env.copy()
            focused_env["CMUX_SOCKET_PATH"] = socket_path
            for key in (
                "CMUX_WORKSPACE_ID",
                "CMUX_SURFACE_ID",
                "CMUX_PANEL_ID",
                "CMUX_TAB_ID",
                "CMUX_PANE_ID",
            ):
                focused_env.pop(key, None)
            focused = subprocess.run(
                [cli_path, "claude-teams", "start a team"],
                capture_output=True,
                text=True,
                check=False,
                env=focused_env,
                timeout=30,
            )
            focused_codex = subprocess.run(
                [cli_path, "codex-teams", "start a team"],
                capture_output=True,
                text=True,
                check=False,
                env=focused_env,
                timeout=30,
            )
        if focused.returncode == 0 or claude_log.exists():
            print("FAIL: contextless Teams launch borrowed the globally focused cmux surface")
            return 1
        if focused_codex.returncode == 0 or codex_log.exists():
            print("FAIL: contextless Codex Teams launch borrowed the globally focused cmux surface")
            return 1
        if "system.identify" in requests:
            print(f"FAIL: contextless Teams launch consulted mutable focus: {requests!r}")
            return 1

        overridden_tmp = tmp / "unrelated-tmpdir"
        overridden_tmp.mkdir()
        with focused_cmux_server(
            tmp / "live-cmux.sock",
            surface_id=live_surface_id,
        ) as (socket_path, _):
            live_env = env.copy()
            live_env["CMUX_SOCKET_PATH"] = socket_path
            live_env["CMUX_WORKSPACE_ID"] = FOCUSED_WORKSPACE_ID
            live_env["CMUX_SURFACE_ID"] = live_surface_id
            live_env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(live_managed_bin / "claude")
            live_env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(live_managed_bin)
            live_env["TMPDIR"] = str(overridden_tmp)
            live = subprocess.run(
                [cli_path, "claude-teams", "start a team"],
                capture_output=True,
                text=True,
                check=False,
                env=live_env,
                timeout=30,
            )
            live_reached_provider = claude_log.exists()
            claude_log.unlink(missing_ok=True)
            mismatch_env = live_env.copy()
            mismatch_env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(managed_bin / "claude")
            mismatch_env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(managed_bin)
            mismatched_tmux = managed_bin / "tmux"
            mismatched_tmux.unlink(missing_ok=True)
            mismatch = subprocess.run(
                [cli_path, "claude-teams", "start a team"],
                capture_output=True,
                text=True,
                check=False,
                env=mismatch_env,
                timeout=30,
            )
        if live.returncode != 0 or not live_reached_provider or not (live_managed_bin / "tmux").is_file():
            print("FAIL: live surface UUID root was rejected when TMPDIR differed")
            print(f"stderr={live.stderr.strip()}")
            return 1
        if mismatch.returncode == 0 or claude_log.exists() or mismatched_tmux.exists():
            print("FAIL: managed wrapper root for a different surface was accepted")
            return 1

        redirected_root_parent = tmp / "redirected" / "cmux-cli-shims"
        redirected_target = tmp / "redirected-target"
        redirected_root_parent.mkdir(parents=True)
        redirected_target.mkdir()
        make_executable(
            redirected_target / "claude",
            "#!/usr/bin/env bash\necho managed-claude-shim-must-not-run >&2\nexit 42\n",
        )
        redirected_root = redirected_root_parent / live_surface_id
        redirected_root.symlink_to(redirected_target, target_is_directory=True)
        redirected_tmux = redirected_target / "tmux"
        redirected_env = live_env.copy()
        redirected_env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(redirected_root / "claude")
        redirected_env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(redirected_root)
        claude_log.unlink(missing_ok=True)
        with focused_cmux_server(
            tmp / "redirected-cmux.sock",
            surface_id=live_surface_id,
        ) as (socket_path, _):
            redirected_env["CMUX_SOCKET_PATH"] = socket_path
            redirected = subprocess.run(
                [cli_path, "claude-teams", "start a team"],
                capture_output=True,
                text=True,
                check=False,
                env=redirected_env,
                timeout=30,
            )
        if redirected.returncode == 0 or claude_log.exists() or redirected_tmux.exists():
            print("FAIL: symlinked managed wrapper root redirected the tmux shim write")
            return 1

    print("PASS: provider fallback survives while real Teams launches require managed routing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
