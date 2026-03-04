#!/usr/bin/env python3
"""
Regression tests for Resources/bin/claude tmux environment handling.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "claude"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def run_wrapper(args: list[str], env_overrides: dict[str, str | None]) -> tuple[int, list[str], str, str]:
    tmp_dir_override = os.environ.get("CMUX_TEST_TMPDIR")
    tmp_kwargs = {"prefix": "cmux-claude-wrapper-test-"}
    if tmp_dir_override:
        tmp_kwargs["dir"] = tmp_dir_override

    with tempfile.TemporaryDirectory(**tmp_kwargs) as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper"
        real_dir = tmp / "realbin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "claude"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        argv_log = tmp / "argv.log"
        claudecode_log = tmp / "claudecode.log"
        fake_claude = real_dir / "claude"
        make_executable(
            fake_claude,
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_ARGV_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_ARGV_LOG"
done
printf '%s' "${CLAUDECODE:-}" > "$FAKE_CLAUDECODE_LOG"
""",
        )

        env = os.environ.copy()
        env["FAKE_ARGV_LOG"] = str(argv_log)
        env["FAKE_CLAUDECODE_LOG"] = str(claudecode_log)
        env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '')}"

        for key, value in env_overrides.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value

        proc = subprocess.run(
            ["/bin/bash", str(wrapper), *args],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        argv = read_lines(argv_log)
        claudecode = claudecode_log.read_text(encoding="utf-8") if claudecode_log.exists() else ""
        return proc.returncode, argv, claudecode, proc.stderr.strip()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_tmux_like_env_injects_hooks_without_surface(failures: list[str]) -> None:
    code, argv, claudecode, stderr = run_wrapper(
        ["chat", "hello"],
        {
            "TMUX": "/tmp/tmux-1000/default,1,0",
            "CMUX_SOCKET_PATH": "/tmp/cmux-debug-regression.sock",
            "CMUX_SURFACE_ID": None,
            "CLAUDECODE": "nested-session-marker",
        },
    )
    expect(code == 0, f"tmux env wrapper exit should be 0, got {code}: {stderr}", failures)
    expect("--settings" in argv, f"expected --settings injection with tmux + socket env, argv={argv}", failures)
    expect("--session-id" in argv, f"expected --session-id injection with tmux + socket env, argv={argv}", failures)
    expect("chat" in argv and "hello" in argv, f"expected original args to pass through, argv={argv}", failures)
    expect(claudecode == "", f"expected CLAUDECODE to be unset before exec, got {claudecode!r}", failures)


def test_plain_tmux_without_cmux_socket_passthrough(failures: list[str]) -> None:
    code, argv, _claudecode, stderr = run_wrapper(
        ["chat", "hello"],
        {
            "TMUX": "/tmp/tmux-1000/default,1,0",
            "CMUX_SOCKET_PATH": None,
            "CMUX_SURFACE_ID": None,
        },
    )
    expect(code == 0, f"plain tmux wrapper exit should be 0, got {code}: {stderr}", failures)
    expect("--settings" not in argv, f"plain tmux should pass through without hooks, argv={argv}", failures)
    expect("--session-id" not in argv, f"plain tmux should not inject session-id, argv={argv}", failures)


def test_hooks_disabled_passthrough(failures: list[str]) -> None:
    code, argv, _claudecode, stderr = run_wrapper(
        ["chat", "hello"],
        {
            "TMUX": "/tmp/tmux-1000/default,1,0",
            "CMUX_SOCKET_PATH": "/tmp/cmux-debug-regression.sock",
            "CMUX_SURFACE_ID": None,
            "CMUX_CLAUDE_HOOKS_DISABLED": "1",
        },
    )
    expect(code == 0, f"hooks disabled wrapper exit should be 0, got {code}: {stderr}", failures)
    expect("--settings" not in argv, f"hooks-disabled mode should pass through, argv={argv}", failures)
    expect("--session-id" not in argv, f"hooks-disabled mode should not inject session-id, argv={argv}", failures)


def main() -> int:
    failures: list[str] = []
    test_tmux_like_env_injects_hooks_without_surface(failures)
    test_plain_tmux_without_cmux_socket_passthrough(failures)
    test_hooks_disabled_passthrough(failures)

    if failures:
        print("claude wrapper tmux env regression tests failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: claude wrapper tmux env regression tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
