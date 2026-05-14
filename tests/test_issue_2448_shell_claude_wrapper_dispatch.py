#!/usr/bin/env python3
"""
Regression for issue #2448:
shell integrations should dispatch `claude` through the bundled wrapper even
when GHOSTTY_BIN_DIR is unset and PATH later prefers another binary.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHELL_DIR = ROOT / "Resources" / "shell-integration"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def prepare_bundle(tmp: Path) -> tuple[Path, Path]:
    shell_dir = tmp / "bundle" / "Resources" / "shell-integration"
    bin_dir = tmp / "bundle" / "Resources" / "bin"
    shell_dir.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)

    for name in (".zshenv", ".zprofile", ".zshrc", "cmux-zsh-integration.zsh", "cmux-bash-integration.bash"):
        shutil.copy2(SOURCE_SHELL_DIR / name, shell_dir / name)

    return shell_dir, bin_dir


def run_zsh(shell_dir: Path, real_bin: Path, log_path: Path) -> tuple[int, str, list[str]]:
    home = shell_dir.parent.parent.parent / "home"
    orig = shell_dir.parent.parent.parent / "orig-zdotdir"
    home.mkdir(parents=True, exist_ok=True)
    orig.mkdir(parents=True, exist_ok=True)

    for filename in (".zshenv", ".zprofile", ".zshrc"):
        (orig / filename).write_text("", encoding="utf-8")

    env = dict(os.environ)
    env["HOME"] = str(home)
    env["ZDOTDIR"] = str(shell_dir)
    env["CMUX_ZSH_ZDOTDIR"] = str(orig)
    env["CMUX_SHELL_INTEGRATION"] = "1"
    env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
    env["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "0"
    env["CMUX_TEST_LOG"] = str(log_path)
    env["CMUX_TEST_REAL_BIN"] = str(real_bin)
    env["PATH"] = f"{real_bin}:/usr/bin:/bin"
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        ["zsh", "-d", "-i", "-c", 'PATH="$CMUX_TEST_REAL_BIN:$PATH"; claude zsh-case'],
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def run_zsh_with_alias(shell_dir: Path, real_bin: Path, log_path: Path) -> tuple[int, str, list[str]]:
    env = dict(os.environ)
    env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
    env["CMUX_TEST_LOG"] = str(log_path)
    env["CMUX_TEST_REAL_BIN"] = str(real_bin)
    env["PATH"] = f"{real_bin}:/usr/bin:/bin"
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        [
            "zsh",
            "-fic",
            f'alias claude="echo alias"; source "{shell_dir / "cmux-zsh-integration.zsh"}"; '
            'PATH="$CMUX_TEST_REAL_BIN:$PATH"; claude zsh-alias-case',
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def run_bash(shell_dir: Path, real_bin: Path, log_path: Path) -> tuple[int, str, list[str]]:
    env = dict(os.environ)
    env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
    env["CMUX_TEST_LOG"] = str(log_path)
    env["CMUX_TEST_REAL_BIN"] = str(real_bin)
    env["PATH"] = f"{real_bin}:/usr/bin:/bin"
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        [
            "bash",
            "--noprofile",
            "--norc",
            "-c",
            f'source "{shell_dir / "cmux-bash-integration.bash"}"; PATH="$CMUX_TEST_REAL_BIN:$PATH"; claude bash-case',
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def run_bash_with_alias(shell_dir: Path, real_bin: Path, log_path: Path) -> tuple[int, str, list[str]]:
    env = dict(os.environ)
    env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
    env["CMUX_TEST_LOG"] = str(log_path)
    env["CMUX_TEST_REAL_BIN"] = str(real_bin)
    env["PATH"] = f"{real_bin}:/usr/bin:/bin"
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        [
            "bash",
            "--noprofile",
            "--norc",
            "-ic",
            f'alias claude="$CMUX_TEST_REAL_BIN/user-claude"; source "{shell_dir / "cmux-bash-integration.bash"}"; '
            'PATH="$CMUX_TEST_REAL_BIN:$PATH"; claude bash-alias-case',
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def run_bash_with_function(shell_dir: Path, real_bin: Path, log_path: Path) -> tuple[int, str, list[str]]:
    env = dict(os.environ)
    env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
    env["CMUX_TEST_LOG"] = str(log_path)
    env["CMUX_TEST_REAL_BIN"] = str(real_bin)
    env["PATH"] = f"{real_bin}:/usr/bin:/bin"
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        [
            "bash",
            "--noprofile",
            "--norc",
            "-ic",
            f'claude() {{ "$CMUX_TEST_REAL_BIN/user-claude-function" "$@"; }}; '
            f'source "{shell_dir / "cmux-bash-integration.bash"}"; '
            'PATH="$CMUX_TEST_REAL_BIN:$PATH"; claude bash-function-case',
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def main() -> int:
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-issue-2448-") as td:
        tmp = Path(td)
        shell_dir, bundle_bin = prepare_bundle(tmp)
        real_bin = tmp / "real-bin"
        real_bin.mkdir(parents=True, exist_ok=True)

        write_executable(
            bundle_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'wrapper:%s\n' "$*" >> "$CMUX_TEST_LOG"
""",
        )
        write_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'real:%s\n' "$*" >> "$CMUX_TEST_LOG"
""",
        )
        write_executable(
            real_bin / "user-claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'user-alias:%s\n' "$*" >> "$CMUX_TEST_LOG"
""",
        )
        write_executable(
            real_bin / "user-claude-function",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'user-function:%s\n' "$*" >> "$CMUX_TEST_LOG"
""",
        )

        zsh_log = tmp / "zsh.log"
        rc, output, lines = run_zsh(shell_dir, real_bin, zsh_log)
        if rc != 0:
            failures.append(f"zsh exited non-zero rc={rc}: {output}")
        elif lines != ["wrapper:zsh-case"]:
            failures.append(f"zsh expected wrapper dispatch, saw {lines!r}")

        bash_log = tmp / "bash.log"
        rc, output, lines = run_bash(shell_dir, real_bin, bash_log)
        if rc != 0:
            failures.append(f"bash exited non-zero rc={rc}: {output}")
        elif lines != ["wrapper:bash-case"]:
            failures.append(f"bash expected wrapper dispatch, saw {lines!r}")

        zsh_alias_log = tmp / "zsh-alias.log"
        rc, output, lines = run_zsh_with_alias(shell_dir, real_bin, zsh_alias_log)
        if rc != 0:
            failures.append(f"zsh alias case exited non-zero rc={rc}: {output}")
        elif lines != ["wrapper:zsh-alias-case"]:
            failures.append(f"zsh alias case expected wrapper dispatch, saw {lines!r}")

        bash_alias_log = tmp / "bash-alias.log"
        rc, output, lines = run_bash_with_alias(shell_dir, real_bin, bash_alias_log)
        if rc != 0:
            failures.append(f"bash alias case exited non-zero rc={rc}: {output}")
        elif lines != ["user-alias:bash-alias-case"]:
            failures.append(f"bash alias case should preserve user alias, saw {lines!r}")

        bash_function_log = tmp / "bash-function.log"
        rc, output, lines = run_bash_with_function(shell_dir, real_bin, bash_function_log)
        if rc != 0:
            failures.append(f"bash function case exited non-zero rc={rc}: {output}")
        elif lines != ["user-function:bash-function-case"]:
            failures.append(f"bash function case should preserve user function, saw {lines!r}")

    if failures:
        print("FAIL: shell integration did not keep claude on the bundled wrapper")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: zsh and bash integrations dispatch claude through the bundled wrapper")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
