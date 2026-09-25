#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` injects the tmux-style auto-mode env.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import (
    FOCUSED_PANE_ID,
    FOCUSED_WINDOW_ID,
    FOCUSED_WORKSPACE_ID,
    canonical_managed_claude_shim_root,
    focused_cmux_server,
    resolve_cmux_cli,
    stable_tmux_numeric_id,
)
from node_runtime import ensure_node_on_path


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8").strip()


def run_claude_teams(
    cli_path: str,
    base_env: dict[str, str],
    node_options: str,
    tmpdir: str | None = None,
    unexpected_path_entries: tuple[str, ...] = (),
) -> tuple[subprocess.CompletedProcess[str], str, str, str]:
    with (
        tempfile.TemporaryDirectory(prefix="cmux-claude-teams-env-") as td,
        canonical_managed_claude_shim_root() as (surface_id, wrapper_shim_bin),
    ):
        tmp = Path(td)
        real_bin = tmp / "real-bin"
        real_bin.mkdir(parents=True, exist_ok=True)

        env_log = tmp / "agent-teams.log"
        sandboxed_log = tmp / "sandboxed.log"
        marker_log = tmp / "sandboxed-marker.log"
        respawn_environment_log = tmp / "respawn-environment.log"
        tmux_log = tmp / "tmux-path.log"
        tmux_shim_log = tmp / "tmux-shim.log"
        cmux_bin_log = tmp / "cmux-bin.log"
        argv_log = tmp / "argv.log"
        tmux_env_log = tmp / "tmux-env.log"
        tmux_pane_log = tmp / "tmux-pane.log"
        term_log = tmp / "term.log"
        term_program_log = tmp / "term-program.log"
        socket_path_log = tmp / "socket-path.log"
        socket_password_log = tmp / "socket-password.log"
        node_options_log = tmp / "node-options.log"
        runtime_node_options_log = tmp / "runtime-node-options.log"
        child_node_options_log = tmp / "child-node-options.log"
        fake_home = tmp / "home"
        fake_home.mkdir(parents=True, exist_ok=True)

        make_executable(
            wrapper_shim_bin / "claude",
            "#!/usr/bin/env bash\necho managed-claude-shim-must-not-run >&2\nexit 42\n",
        )

        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS-__UNSET__}" > "$FAKE_AGENT_TEAMS_LOG"
printf '%s\\n' "${CLAUDE_CODE_SANDBOXED-__UNSET__}" > "$FAKE_SANDBOXED_LOG"
printf '%s\\n' "${CMUX_CLAUDE_TEAMS_SANDBOXED-__UNSET__}" > "$FAKE_SANDBOXED_MARKER_LOG"
printf '%s\\n' "${CMUX_CLAUDE_TEAMS_RESPAWN_ENV_B64-__UNSET__}" > "$FAKE_RESPAWN_ENVIRONMENT_LOG"
# Claude Code restores a shell snapshot before invoking tmux. The snapshot's
# full PATH assignment can discard the launcher-only claude-teams-bin entry,
# while cmux's managed per-surface wrapper root remains available.
export PATH="$FAKE_SHELL_SNAPSHOT_PATH"
command -v tmux > "$FAKE_TMUX_PATH_LOG"
printf '%s\\n' "${CMUX_CLAUDE_TEAMS_TMUX_SHIM-__UNSET__}" > "$FAKE_TMUX_SHIM_LOG"
printf '%s\\n' "${CMUX_CLAUDE_TEAMS_CMUX_BIN-__UNSET__}" > "$FAKE_CMUX_BIN_LOG"
printf '%s\\n' "$@" > "$FAKE_ARGV_LOG"
printf '%s\\n' "${TMUX-__UNSET__}" > "$FAKE_TMUX_ENV_LOG"
printf '%s\\n' "${TMUX_PANE-__UNSET__}" > "$FAKE_TMUX_PANE_LOG"
printf '%s\\n' "${TERM-__UNSET__}" > "$FAKE_TERM_LOG"
printf '%s\\n' "${TERM_PROGRAM-__UNSET__}" > "$FAKE_TERM_PROGRAM_LOG"
printf '%s\\n' "${CMUX_SOCKET_PATH-__UNSET__}" > "$FAKE_SOCKET_PATH_LOG"
printf '%s\\n' "${CMUX_SOCKET_PASSWORD-__UNSET__}" > "$FAKE_SOCKET_PASSWORD_LOG"
printf '%s\\n' "${NODE_OPTIONS-__UNSET__}" > "$FAKE_NODE_OPTIONS_LOG"
exec node "$FAKE_REAL_NODE_SCRIPT" "$@"
""",
        )

        make_executable(
            real_bin / "tmux",
            "#!/usr/bin/env bash\necho real-tmux-must-not-run >&2\nexit 42\n",
        )

        make_executable(
            real_bin / "claude-real.js",
            """#!/usr/bin/env node
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");

fs.writeFileSync(
  process.env.FAKE_RUNTIME_NODE_OPTIONS_LOG,
  `${process.env.NODE_OPTIONS ?? "__UNSET__"}\\n`,
  "utf8",
);

const child = spawnSync(
  process.execPath,
  ["-e", "process.stdout.write(process.env.NODE_OPTIONS ?? '__UNSET__')"],
  { encoding: "utf8" },
);
if (child.error) {
  console.error(child.error.message);
  process.exit(1);
}
if ((child.status ?? 0) != 0) {
  process.stderr.write(child.stderr ?? "");
  process.exit(child.status ?? 1);
}

fs.writeFileSync(
  process.env.FAKE_CHILD_NODE_OPTIONS_LOG,
  `${child.stdout ?? ""}\\n`,
  "utf8",
);
""",
        )

        env = base_env.copy()
        env["HOME"] = str(fake_home)
        inherited_path = base_env.get("PATH", "/usr/bin:/bin")
        if unexpected_path_entries:
            inherited_path = ":".join((*unexpected_path_entries, inherited_path))
        env["PATH"] = f"{real_bin}:{inherited_path}"
        env["FAKE_AGENT_TEAMS_LOG"] = str(env_log)
        env["FAKE_SANDBOXED_LOG"] = str(sandboxed_log)
        env["FAKE_SANDBOXED_MARKER_LOG"] = str(marker_log)
        env["FAKE_RESPAWN_ENVIRONMENT_LOG"] = str(respawn_environment_log)
        env["FAKE_TMUX_PATH_LOG"] = str(tmux_log)
        env["FAKE_TMUX_SHIM_LOG"] = str(tmux_shim_log)
        env["FAKE_CMUX_BIN_LOG"] = str(cmux_bin_log)
        env["FAKE_ARGV_LOG"] = str(argv_log)
        env["FAKE_TMUX_ENV_LOG"] = str(tmux_env_log)
        env["FAKE_TMUX_PANE_LOG"] = str(tmux_pane_log)
        env["FAKE_TERM_LOG"] = str(term_log)
        env["FAKE_TERM_PROGRAM_LOG"] = str(term_program_log)
        env["FAKE_SOCKET_PATH_LOG"] = str(socket_path_log)
        env["FAKE_SOCKET_PASSWORD_LOG"] = str(socket_password_log)
        env["FAKE_NODE_OPTIONS_LOG"] = str(node_options_log)
        env["FAKE_RUNTIME_NODE_OPTIONS_LOG"] = str(runtime_node_options_log)
        env["FAKE_CHILD_NODE_OPTIONS_LOG"] = str(child_node_options_log)
        env["FAKE_REAL_NODE_SCRIPT"] = str(real_bin / "claude-real.js")
        env["FAKE_SHELL_SNAPSHOT_PATH"] = f"{wrapper_shim_bin}:{env['PATH']}"
        env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(wrapper_shim_bin / "claude")
        env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(wrapper_shim_bin)
        env["CMUX_WORKSPACE_ID"] = FOCUSED_WORKSPACE_ID
        env["CMUX_SURFACE_ID"] = surface_id
        env["TMUX"] = "__HOST_TMUX__"
        env["TMUX_PANE"] = "%999"
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "__HOST_TERM_PROGRAM__"
        env["NODE_OPTIONS"] = node_options
        env["CLAUDE_CONFIG_DIR"] = str(fake_home / "claude-config")
        env["ANTHROPIC_API_KEY"] = "sk-ant-must-not-cross-respawn-transport"
        expect_managed_tmux_shim = True
        env["TMPDIR"] = str(tmp) if tmpdir is None else tmpdir
        explicit_socket_path_hint = tmp / "explicit-cmux.sock"
        explicit_socket_password = "topsecret"

        with focused_cmux_server(
            explicit_socket_path_hint,
            surface_id=surface_id,
            identified_workspace_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            identified_window_id="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            identified_pane_id="cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            identified_surface_id="dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        ) as (explicit_socket_path, socket_requests):
            proc = subprocess.run(
                [
                    cli_path,
                    "--socket",
                    explicit_socket_path,
                    "--password",
                    explicit_socket_password,
                    "claude-teams",
                    # The trust-gate bypass (CLAUDE_CODE_SANDBOXED) is only granted
                    # once the user opts into skipping safety prompts, so exercise the
                    # bypass path with --dangerously-skip-permissions.
                    "--dangerously-skip-permissions",
                    "--version",
                ],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )

        if proc.returncode != 0:
            return proc, "", "", ""

        if socket_requests != ["auth", "surface.list"]:
            print(
                "FAIL: managed launch identity must authenticate and resolve directly without consulting "
                f"mutable global focus, got requests {socket_requests!r}"
            )
            raise SystemExit(1)

        agent_teams_value = read_text(env_log)
        if agent_teams_value != "1":
            print(f"FAIL: expected CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1, got {agent_teams_value!r}")
            raise SystemExit(1)

        # #6447: the lead must skip Claude Code's interactive "trust this folder?"
        # gate (which otherwise deadlocks the unattended session) via
        # CLAUDE_CODE_SANDBOXED.
        sandboxed_value = read_text(sandboxed_log)
        if sandboxed_value != "1":
            print(f"FAIL: expected CLAUDE_CODE_SANDBOXED=1 to skip the trust gate, got {sandboxed_value!r}")
            raise SystemExit(1)

        # The launcher records the opt-in in CMUX_CLAUDE_TEAMS_SANDBOXED so teammate
        # respawns re-apply the same trust decision without re-deriving it from
        # untrusted command text.
        marker_value = read_text(marker_log)
        if marker_value != "1":
            print(f"FAIL: expected CMUX_CLAUDE_TEAMS_SANDBOXED=1 opt-in marker, got {marker_value!r}")
            raise SystemExit(1)

        encoded_respawn_environment = read_text(respawn_environment_log)
        try:
            respawn_environment = json.loads(
                base64.b64decode(encoded_respawn_environment, validate=True).decode("utf-8")
            )
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            print(
                "FAIL: expected CMUX_CLAUDE_TEAMS_RESPAWN_ENV_B64 to contain a base64 JSON object, "
                f"got {encoded_respawn_environment!r}: {exc}"
            )
            raise SystemExit(1) from exc

        transported_path = respawn_environment.get("PATH", "")
        expected_shim_prefix = f"{wrapper_shim_bin}:"
        if not transported_path.startswith(expected_shim_prefix) or str(real_bin) not in transported_path.split(":"):
            print(
                "FAIL: expected the respawn transport to carry the final launcher PATH "
                f"(managed shim first, invoking tool path retained), got {transported_path!r}"
            )
            raise SystemExit(1)
        if unexpected_path_entries:
            transported_components = transported_path.split(":")
            for unexpected_path_entry in unexpected_path_entries:
                normalized_unexpected_path = os.path.normpath(
                    os.path.join(os.getcwd(), unexpected_path_entry.strip())
                )
                if (
                    unexpected_path_entry in transported_path
                    or normalized_unexpected_path in transported_components
                ):
                    print(
                        "FAIL: respawn transport must reject the malformed relative PATH entry "
                        "and its cwd-normalized form, "
                        f"got {transported_path!r}"
                    )
                    raise SystemExit(1)
            malformed_scalars = {
                scalar
                for component in transported_components
                for scalar in component
                if ord(scalar) < 0x20
                or 0x7F <= ord(scalar) <= 0x9F
                or scalar == "\uFFFD"
            }
            if malformed_scalars:
                print(
                    "FAIL: respawn transport PATH contains malformed control/replacement "
                    f"scalars {sorted(malformed_scalars)!r}: {transported_path!r}"
                )
                raise SystemExit(1)

        expected_config_directory = str(fake_home / "claude-config")
        if respawn_environment.get("CLAUDE_CONFIG_DIR") != expected_config_directory:
            print(
                "FAIL: expected the respawn transport to retain allowlisted Claude configuration, "
                f"got {respawn_environment!r}"
            )
            raise SystemExit(1)

        if "ANTHROPIC_API_KEY" in respawn_environment:
            print(f"FAIL: respawn transport must reject secrets, got {respawn_environment!r}")
            raise SystemExit(1)

        tmux_path = read_text(tmux_log)
        if not tmux_path:
            print("FAIL: fake claude did not observe a tmux binary in PATH")
            raise SystemExit(1)

        tmux_name = Path(tmux_path).name
        if tmux_name != "tmux":
            print(f"FAIL: expected tmux shim path to end with 'tmux', got {tmux_path!r}")
            raise SystemExit(1)

        if expect_managed_tmux_shim:
            expected_tmux_path = str(wrapper_shim_bin / "tmux")
            if tmux_path != expected_tmux_path:
                print(
                    "FAIL: expected Claude's restored PATH to resolve the tmux shim "
                    f"at {expected_tmux_path!r}, got {tmux_path!r}"
                )
                raise SystemExit(1)

            if tmux_path.startswith(str(real_bin)):
                print(f"FAIL: expected cmux tmux shim to shadow PATH, got {tmux_path!r}")
                raise SystemExit(1)

            tmux_shim_value = read_text(tmux_shim_log)
            if tmux_shim_value != expected_tmux_path:
                print(
                    f"FAIL: expected CMUX_CLAUDE_TEAMS_TMUX_SHIM={expected_tmux_path!r}, "
                    f"got {tmux_shim_value!r}"
                )
                raise SystemExit(1)

        cmux_bin_value = read_text(cmux_bin_log)
        if not cmux_bin_value or cmux_bin_value == "__UNSET__":
            print("FAIL: missing CMUX_CLAUDE_TEAMS_CMUX_BIN")
            raise SystemExit(1)

        if not os.path.exists(cmux_bin_value):
            print(f"FAIL: CMUX_CLAUDE_TEAMS_CMUX_BIN does not exist: {cmux_bin_value!r}")
            raise SystemExit(1)

        argv_lines = argv_log.read_text(encoding="utf-8").splitlines()
        if argv_lines[:2] != ["--teammate-mode", "auto"]:
            print(f"FAIL: expected launcher to prepend --teammate-mode auto, got {argv_lines!r}")
            raise SystemExit(1)

        # #6447: so a plain `cmux claude-teams "make a demo team"` actually opens
        # split panes, the lead is nudged (via an appended system prompt) toward
        # named split-pane teammates instead of nameless in-process subagents.
        if "--append-system-prompt" not in argv_lines:
            print(f"FAIL: expected claude-teams to append a team-spawn system prompt, got {argv_lines!r}")
            raise SystemExit(1)
        nudge_index = argv_lines.index("--append-system-prompt")
        nudge_text = argv_lines[nudge_index + 1] if nudge_index + 1 < len(argv_lines) else ""
        if "teammate" not in nudge_text.lower() or "pane" not in nudge_text.lower():
            print(f"FAIL: team-spawn nudge must steer toward split-pane teammates, got {nudge_text!r}")
            raise SystemExit(1)

        if "--version" not in argv_lines:
            print(f"FAIL: expected launcher to preserve user args, got {argv_lines!r}")
            raise SystemExit(1)

        tmux_env_value = read_text(tmux_env_log)
        expected_pane_token = stable_tmux_numeric_id(FOCUSED_PANE_ID)
        expected_tmux = (
            f"/tmp/cmux-claude-teams/{FOCUSED_WORKSPACE_ID},"
            f"{FOCUSED_WINDOW_ID},{expected_pane_token}"
        )
        if tmux_env_value != expected_tmux:
            print(f"FAIL: expected launch-surface TMUX={expected_tmux!r}, got {tmux_env_value!r}")
            raise SystemExit(1)

        tmux_pane_value = read_text(tmux_pane_log)
        expected_tmux_pane = f"%{expected_pane_token}"
        if tmux_pane_value != expected_tmux_pane:
            print(f"FAIL: expected launch-surface TMUX_PANE={expected_tmux_pane!r}, got {tmux_pane_value!r}")
            raise SystemExit(1)

        term_value = read_text(term_log)
        if term_value != "screen-256color":
            print(f"FAIL: expected TERM=screen-256color, got {term_value!r}")
            raise SystemExit(1)

        term_program_value = read_text(term_program_log)
        if term_program_value != "__UNSET__":
            print(f"FAIL: expected TERM_PROGRAM to be unset, got {term_program_value!r}")
            raise SystemExit(1)

        socket_path_value = read_text(socket_path_log)
        if socket_path_value != explicit_socket_path:
            print(f"FAIL: expected CMUX_SOCKET_PATH={explicit_socket_path!r}, got {socket_path_value!r}")
            raise SystemExit(1)

        socket_password_value = read_text(socket_password_log)
        if socket_password_value != explicit_socket_password:
            print(
                "FAIL: expected CMUX_SOCKET_PASSWORD to preserve the explicit CLI override, "
                f"got {socket_password_value!r}"
            )
            raise SystemExit(1)

        return proc, read_text(node_options_log), read_text(runtime_node_options_log), read_text(child_node_options_log)


def main() -> int:
    node_path = ensure_node_on_path()
    if node_path is None:
        print("SKIP: node runtime not found; fake claude execs node")
        return 0
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    base_env = os.environ.copy()
    # Keep the PATH fixture independent of the runner's shell. In particular,
    # an ambient component resolving to this checkout would make the malformed
    # `.../..` assertion indistinguishable from a pre-existing current-directory
    # entry. The fake Claude only needs its Node directory and the system tools.
    base_env["PATH"] = f"{Path(node_path).parent}:/usr/bin:/bin"

    proc, node_options_value, runtime_node_options_value, child_node_options_value = run_claude_teams(
        cli_path,
        base_env,
        "--trace-warnings",
        unexpected_path_entries=(
            "\ncmux-10221-garbage-dir\n",
            "\ncmux-10221-garbage-dir/..\n",
        ),
    )
    if proc.returncode != 0:
        print("FAIL: `cmux claude-teams --version` exited non-zero")
        print(f"exit={proc.returncode}")
        print(f"stdout={proc.stdout.strip()}")
        print(f"stderr={proc.stderr.strip()}")
        return 1

    require_flag, _, remaining_flags = node_options_value.partition(" ")
    if not require_flag.startswith("--require="):
        print(
            "FAIL: expected NODE_OPTIONS to prepend the restore preload, "
            f"got {node_options_value!r}"
        )
        return 1

    if remaining_flags != "--max-old-space-size=4096 --trace-warnings":
        print(
            "FAIL: expected NODE_OPTIONS to prepend the V8 heap cap after the restore preload, "
            f"got {node_options_value!r}"
        )
        return 1

    if runtime_node_options_value != "--trace-warnings":
        print(
            "FAIL: expected Claude runtime NODE_OPTIONS to be restored to the original value, "
            f"got {runtime_node_options_value!r}"
        )
        return 1

    if child_node_options_value != "--trace-warnings":
        print(
            "FAIL: expected child NODE_OPTIONS to inherit the restored original value, "
            f"got {child_node_options_value!r}"
        )
        return 1

    proc, node_options_value, runtime_node_options_value, child_node_options_value = run_claude_teams(
        cli_path,
        base_env,
        "--max-old-space-size 2048 --trace-warnings",
    )
    if proc.returncode != 0:
        print("FAIL: `cmux claude-teams --version` with existing heap flag exited non-zero")
        print(f"exit={proc.returncode}")
        print(f"stdout={proc.stdout.strip()}")
        print(f"stderr={proc.stderr.strip()}")
        return 1

    require_flag, _, remaining_flags = node_options_value.partition(" ")
    if not require_flag.startswith("--require="):
        print(
            "FAIL: expected NODE_OPTIONS to prepend the restore preload, "
            f"got {node_options_value!r}"
        )
        return 1

    if remaining_flags != "--max-old-space-size=4096 --trace-warnings":
        print(
            "FAIL: expected launcher to replace the existing space-separated NODE_OPTIONS heap cap after the restore preload, "
            f"got {node_options_value!r}"
        )
        return 1

    if runtime_node_options_value != "--max-old-space-size=2048 --trace-warnings":
        print(
            "FAIL: expected Claude runtime NODE_OPTIONS to preserve the original max-old-space-size value, "
            f"got {runtime_node_options_value!r}"
        )
        return 1

    if child_node_options_value != "--max-old-space-size=2048 --trace-warnings":
        print(
            "FAIL: expected child NODE_OPTIONS to preserve the original max-old-space-size value, "
            f"got {child_node_options_value!r}"
        )
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-bad-tmp-") as td:
        bad_tmpdir = Path(td) / "not-a-directory"
        bad_tmpdir.write_text("occupied", encoding="utf-8")
        proc, node_options_value, runtime_node_options_value, child_node_options_value = run_claude_teams(
            cli_path,
            base_env,
            "--trace-warnings",
            tmpdir=str(bad_tmpdir),
        )
    if proc.returncode != 0:
        print("FAIL: `cmux claude-teams --version` should still succeed when TMPDIR is unusable")
        print(f"exit={proc.returncode}")
        print(f"stdout={proc.stdout.strip()}")
        print(f"stderr={proc.stderr.strip()}")
        return 1

    if node_options_value != "--trace-warnings":
        print(
            "FAIL: expected claude-teams to skip restore preload injection when TMPDIR is unusable, "
            f"got {node_options_value!r}"
        )
        return 1

    if runtime_node_options_value != "--trace-warnings":
        print(
            "FAIL: expected Claude runtime NODE_OPTIONS to remain unchanged when TMPDIR is unusable, "
            f"got {runtime_node_options_value!r}"
        )
        return 1

    if child_node_options_value != "--trace-warnings":
        print(
            "FAIL: expected child NODE_OPTIONS to remain unchanged when TMPDIR is unusable, "
            f"got {child_node_options_value!r}"
        )
        return 1

    print("PASS: cmux claude-teams restores child NODE_OPTIONS while injecting the auto-mode tmux env")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
