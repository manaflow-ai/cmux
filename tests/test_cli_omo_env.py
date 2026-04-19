#!/usr/bin/env python3
"""
Regression test: `cmux omo` injects the tmux-style auto-mode env *and* unsets
TERM_PROGRAM (otherwise opencode flips to a light theme — regression #2516).

This is the sibling of test_cli_claude_teams_env.py for the opencode-family
agent path. Locks in the asymmetric TERM_PROGRAM contract: claude-teams
preserves it (issue #2947), opencode-family agents must NOT have it leak
through.
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


def run_omo(cli_path: str, base_env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="cmux-omo-env-") as td:
        tmp = Path(td)
        real_bin = tmp / "real-bin"
        real_bin.mkdir(parents=True, exist_ok=True)

        term_log = tmp / "term.log"
        term_program_log = tmp / "term-program.log"
        colorterm_log = tmp / "colorterm.log"
        cmux_bin_log = tmp / "cmux-bin.log"
        argv_log = tmp / "argv.log"
        fake_home = tmp / "home"
        fake_home.mkdir(parents=True, exist_ok=True)

        # Fake opencode shim — logs env on every invocation (the final `--version`
        # call wins, overwriting earlier writes from any plugin-install probes).
        make_executable(
            real_bin / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "${TERM-__UNSET__}" > "$FAKE_TERM_LOG"
printf '%s\\n' "${TERM_PROGRAM-__UNSET__}" > "$FAKE_TERM_PROGRAM_LOG"
printf '%s\\n' "${COLORTERM-__UNSET__}" > "$FAKE_COLORTERM_LOG"
printf '%s\\n' "${CMUX_OMO_CMUX_BIN-__UNSET__}" > "$FAKE_CMUX_BIN_LOG"
printf '%s\\n' "$@" > "$FAKE_ARGV_LOG"
exit 0
""",
        )

        env = base_env.copy()
        env["HOME"] = str(fake_home)
        env["PATH"] = f"{real_bin}:{base_env.get('PATH', '/usr/bin:/bin')}"
        env["FAKE_TERM_LOG"] = str(term_log)
        env["FAKE_TERM_PROGRAM_LOG"] = str(term_program_log)
        env["FAKE_COLORTERM_LOG"] = str(colorterm_log)
        env["FAKE_CMUX_BIN_LOG"] = str(cmux_bin_log)
        env["FAKE_ARGV_LOG"] = str(argv_log)
        # Parent-side TERM_PROGRAM and TERM are intentionally non-empty to
        # exercise the "must be unset" / "must not leak through" path.
        env["TERM_PROGRAM"] = "ghostty"
        env["TERM"] = "xterm-256color"
        # Ensure COLORTERM is unset so we exercise the truecolor fallback.
        env.pop("COLORTERM", None)

        proc = subprocess.run(
            [cli_path, "omo", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print(f"FAIL: `cmux omo --version` exited non-zero: {proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            raise SystemExit(1)

        cmux_bin_value = read_text(cmux_bin_log)
        if not cmux_bin_value or cmux_bin_value == "__UNSET__":
            print("FAIL: missing CMUX_OMO_CMUX_BIN — the omo env shim did not run")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            raise SystemExit(1)

        term_value = read_text(term_log)
        if term_value != "xterm-ghostty":
            print(
                f"FAIL: expected TERM=xterm-ghostty for cmux omo, got {term_value!r}"
            )
            raise SystemExit(1)

        term_program_value = read_text(term_program_log)
        if term_program_value != "__UNSET__":
            print(
                "FAIL: expected TERM_PROGRAM to be unset for cmux omo "
                "(prevents opencode light-theme regression of #2516), "
                f"got {term_program_value!r}"
            )
            raise SystemExit(1)

        colorterm_value = read_text(colorterm_log)
        if colorterm_value != "truecolor":
            print(
                f"FAIL: expected COLORTERM=truecolor fallback when parent had none, "
                f"got {colorterm_value!r}"
            )
            raise SystemExit(1)

        return proc


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    base_env = os.environ.copy()
    run_omo(cli_path, base_env)
    print("OK: cmux omo unsets TERM_PROGRAM, defaults TERM=xterm-ghostty, sets COLORTERM=truecolor")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
