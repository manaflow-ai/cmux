#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` injects the tmux-style auto-mode env.
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


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8").strip()


def run_claude_teams(
    cli_path: str,
    base_env: dict[str, str],
    node_options: str,
    tmpdir: str | None = None,
) -> tuple[subprocess.CompletedProcess[str], str, str, str]:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-env-") as td:
        tmp = Path(td)
        real_bin = tmp / "real-bin"
        real_bin.mkdir(parents=True, exist_ok=True)

        env_log = tmp / "agent-teams.log"
        tmux_log = tmp / "tmux-path.log"
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
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS-__UNSET__}" > "$FAKE_AGENT_TEAMS_LOG"
command -v tmux > "$FAKE_TMUX_PATH_LOG"
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
        env["PATH"] = f"{real_bin}:{base_env.get('PATH', '/usr/bin:/bin')}"
        env["FAKE_AGENT_TEAMS_LOG"] = str(env_log)
        env["FAKE_TMUX_PATH_LOG"] = str(tmux_log)
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
        env["TMUX"] = "__HOST_TMUX__"
        env["TMUX_PANE"] = "%999"
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "__HOST_TERM_PROGRAM__"
        env["NODE_OPTIONS"] = node_options
        if tmpdir is not None:
            env["TMPDIR"] = tmpdir
        explicit_socket_path = str(tmp / "explicit-cmux.sock")
        explicit_socket_password = "topsecret"

        proc = subprocess.run(
            [
                cli_path,
                "--socket",
                explicit_socket_path,
                "--password",
                explicit_socket_password,
                "claude-teams",
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

        agent_teams_value = read_text(env_log)
        if agent_teams_value != "1":
            print(f"FAIL: expected CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1, got {agent_teams_value!r}")
            raise SystemExit(1)

        tmux_path = read_text(tmux_log)
        if not tmux_path:
            print("FAIL: fake claude did not observe a tmux binary in PATH")
            raise SystemExit(1)

        tmux_name = Path(tmux_path).name
        if tmux_name != "tmux":
            print(f"FAIL: expected tmux shim path to end with 'tmux', got {tmux_path!r}")
            raise SystemExit(1)

        if "claude-teams-bin" not in tmux_path:
            print(f"FAIL: expected stable tmux shim path, got {tmux_path!r}")
            raise SystemExit(1)

        if tmux_path.startswith(str(real_bin)):
            print(f"FAIL: expected cmux tmux shim to shadow PATH, got {tmux_path!r}")
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

        if "--version" not in argv_lines:
            print(f"FAIL: expected launcher to preserve user args, got {argv_lines!r}")
            raise SystemExit(1)

        tmux_env_value = read_text(tmux_env_log)
        if tmux_env_value in {"", "__UNSET__"}:
            print("FAIL: expected a fake TMUX env value")
            raise SystemExit(1)

        tmux_pane_value = read_text(tmux_pane_log)
        if tmux_pane_value in {"", "__UNSET__"} or not tmux_pane_value.startswith("%"):
            print(f"FAIL: expected a fake TMUX_PANE value, got {tmux_pane_value!r}")
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
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    base_env = os.environ.copy()

    proc, node_options_value, runtime_node_options_value, child_node_options_value = run_claude_teams(
        cli_path,
        base_env,
        "--trace-warnings",
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

    if runtime_node_options_value != "--max-old-space-size 2048 --trace-warnings":
        print(
            "FAIL: expected Claude runtime NODE_OPTIONS to preserve the original max-old-space-size flag, "
            f"got {runtime_node_options_value!r}"
        )
        return 1

    if child_node_options_value != "--max-old-space-size 2048 --trace-warnings":
        print(
            "FAIL: expected child NODE_OPTIONS to preserve the original max-old-space-size flag, "
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
