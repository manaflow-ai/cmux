#!/usr/bin/env python3
"""
Regression tests for shell integration after removing cmux-owned Claude shims.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHELL_DIR = ROOT / "Resources" / "shell-integration"
SHELL_FILES = (".zshenv", ".zprofile", ".zshrc", "cmux-zsh-integration.zsh", "cmux-bash-integration.bash")
BASH = "/bin/bash"
ZSH = "/bin/zsh"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def prepare_shell_dir(tmp: Path) -> tuple[Path, Path]:
    shell_dir = tmp / "bundle" / "Resources" / "shell-integration"
    legacy_provider_dir = tmp / "bundle" / "Resources" / "bin"
    shell_dir.mkdir(parents=True, exist_ok=True)
    legacy_provider_dir.mkdir(parents=True, exist_ok=True)

    for name in SHELL_FILES:
        shutil.copy2(SOURCE_SHELL_DIR / name, shell_dir / name)

    return shell_dir, legacy_provider_dir


def run_bash(shell_dir: Path, path_value: str, log_path: Path, command: str) -> tuple[int, str, list[str]]:
    env = dict(os.environ)
    env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
    env["CMUX_TEST_LOG"] = str(log_path)
    env["PATH"] = path_value
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        [BASH, "--noprofile", "--norc", "-s"],
        input=f'source "{shell_dir / "cmux-bash-integration.bash"}"\n{command}\n',
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def run_zsh(shell_dir: Path, path_value: str, log_path: Path, command: str) -> tuple[int, str, list[str]]:
    env = dict(os.environ)
    env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
    env["CMUX_TEST_LOG"] = str(log_path)
    env["PATH"] = path_value
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        [ZSH, "-f", "-s"],
        input=f'source "{shell_dir / "cmux-zsh-integration.zsh"}"\n{command}\n',
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_user_owned_claude_is_used(failures: list[str]) -> None:
    for shell_name, runner in (("bash", run_bash), ("zsh", run_zsh)):
        with tempfile.TemporaryDirectory(prefix=f"cmux-{shell_name}-user-claude-") as td:
            tmp = Path(td)
            shell_dir, legacy_provider_dir = prepare_shell_dir(tmp)
            user_bin = tmp / "user-bin"
            user_bin.mkdir(parents=True, exist_ok=True)

            legacy_log = tmp / "legacy.log"
            user_log = tmp / "user.log"
            write_executable(
                legacy_provider_dir / "claude",
                """#!/bin/bash
set -euo pipefail
printf 'legacy:%s\\n' "$*" >> "$CMUX_TEST_LOG"
""",
            )
            write_executable(
                user_bin / "claude",
                f"""#!/bin/bash
set -euo pipefail
printf 'user:%s\\n' "$*" >> "{user_log}"
printf 'hook-bin:%s\\n' "${{CMUX_CLAUDE_HOOK_CMUX_BIN-__UNSET__}}" >> "{user_log}"
""",
            )

            rc, output, legacy_lines = runner(
                shell_dir,
                f"{user_bin}:/usr/bin:/bin",
                legacy_log,
                "claude --version",
            )
            user_lines = read_lines(user_log)
            expect(rc == 0, f"{shell_name}: user claude exited non-zero rc={rc}: {output}", failures)
            expect(user_lines == ["user:--version", "hook-bin:__UNSET__"], f"{shell_name}: expected user claude, saw {user_lines!r}", failures)
            expect(legacy_lines == [], f"{shell_name}: legacy bundled provider should not run, saw {legacy_lines!r}", failures)


def test_missing_claude_stays_missing(failures: list[str]) -> None:
    for shell_name, runner in (("bash", run_bash), ("zsh", run_zsh)):
        with tempfile.TemporaryDirectory(prefix=f"cmux-{shell_name}-missing-claude-") as td:
            tmp = Path(td)
            shell_dir, legacy_provider_dir = prepare_shell_dir(tmp)
            empty_path = tmp / "empty-path"
            empty_path.mkdir(parents=True, exist_ok=True)

            legacy_log = tmp / "legacy.log"
            write_executable(
                legacy_provider_dir / "claude",
                """#!/bin/bash
set -euo pipefail
printf 'legacy:%s\\n' "$*" >> "$CMUX_TEST_LOG"
""",
            )

            rc, _, legacy_lines = runner(
                shell_dir,
                str(empty_path),
                legacy_log,
                "claude missing-case",
            )
            expect(rc != 0, f"{shell_name}: missing claude should fail", failures)
            expect(legacy_lines == [], f"{shell_name}: missing claude should not fall back to legacy provider, saw {legacy_lines!r}", failures)


def main() -> int:
    failures: list[str] = []
    test_user_owned_claude_is_used(failures)
    test_missing_claude_stays_missing(failures)

    if failures:
        print("FAIL: shell integration still assumes a cmux-owned Claude provider")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: shell integration uses user-owned Claude binaries and preserves missing-binary behavior")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
