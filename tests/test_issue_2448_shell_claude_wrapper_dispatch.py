#!/usr/bin/env python3
"""
Regression for issue #2448's shell path handling.

The shell integrations no longer install a cmux-owned `claude` function. They
must leave user PATH, aliases, and functions in control even if an old provider
shim exists next to the copied integration files.
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


def prepare_bundle(tmp: Path) -> tuple[Path, Path]:
    shell_dir = tmp / "bundle" / "Resources" / "shell-integration"
    legacy_provider_dir = tmp / "bundle" / "Resources" / "bin"
    shell_dir.mkdir(parents=True, exist_ok=True)
    legacy_provider_dir.mkdir(parents=True, exist_ok=True)

    for name in SHELL_FILES:
        shutil.copy2(SOURCE_SHELL_DIR / name, shell_dir / name)

    return shell_dir, legacy_provider_dir


def run_zsh_startup(shell_dir: Path, initial_bin: Path, later_bin: Path, log_path: Path) -> tuple[int, str, list[str]]:
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
    env["CMUX_TEST_LATER_BIN"] = str(later_bin)
    env["PATH"] = f"{initial_bin}:/usr/bin:/bin"
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        [ZSH, "-d", "-i", "-c", 'PATH="$CMUX_TEST_LATER_BIN:$PATH"; claude zsh-case'],
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def run_zsh_script(shell_dir: Path, path_bin: Path, log_path: Path, script: str) -> tuple[int, str, list[str]]:
    env = dict(os.environ)
    env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
    env["CMUX_TEST_LOG"] = str(log_path)
    env["CMUX_TEST_PATH_BIN"] = str(path_bin)
    env["PATH"] = f"{path_bin}:/usr/bin:/bin"
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        [ZSH, "-f", "-s"],
        input=script,
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def run_bash_script(shell_dir: Path, path_bin: Path, log_path: Path, script: str) -> tuple[int, str, list[str]]:
    env = dict(os.environ)
    env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
    env["CMUX_TEST_LOG"] = str(log_path)
    env["CMUX_TEST_PATH_BIN"] = str(path_bin)
    env["PATH"] = f"{path_bin}:/usr/bin:/bin"
    env.pop("GHOSTTY_BIN_DIR", None)

    result = subprocess.run(
        [BASH, "--noprofile", "--norc", "-s"],
        input=script,
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, combined, read_lines(log_path)


def install_fake_claudes(legacy_provider_dir: Path, initial_bin: Path, later_bin: Path, user_bin: Path) -> None:
    for directory, label in (
        (legacy_provider_dir, "legacy"),
        (initial_bin, "initial"),
        (later_bin, "later"),
        (user_bin, "user-alias"),
    ):
        directory.mkdir(parents=True, exist_ok=True)
        write_executable(
            directory / "claude",
            f"""#!/bin/bash
set -euo pipefail
printf '{label}:%s\\n' "$*" >> "$CMUX_TEST_LOG"
""",
        )
    write_executable(
        user_bin / "user-claude-function",
        """#!/bin/bash
set -euo pipefail
printf 'user-function:%s\\n' "$*" >> "$CMUX_TEST_LOG"
""",
    )


def main() -> int:
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-issue-2448-") as td:
        tmp = Path(td)
        shell_dir, legacy_provider_dir = prepare_bundle(tmp)
        initial_bin = tmp / "initial-bin"
        later_bin = tmp / "later-bin"
        user_bin = tmp / "user-bin"
        install_fake_claudes(legacy_provider_dir, initial_bin, later_bin, user_bin)

        zsh_log = tmp / "zsh.log"
        rc, output, lines = run_zsh_startup(shell_dir, initial_bin, later_bin, zsh_log)
        if rc != 0:
            failures.append(f"zsh startup exited non-zero rc={rc}: {output}")
        elif lines != ["later:zsh-case"]:
            failures.append(f"zsh startup should use user PATH after integration, saw {lines!r}")

        bash_log = tmp / "bash.log"
        rc, output, lines = run_bash_script(
            shell_dir,
            initial_bin,
            bash_log,
            f'source "{shell_dir / "cmux-bash-integration.bash"}"\nPATH="{later_bin}:$PATH"\nclaude bash-case\n',
        )
        if rc != 0:
            failures.append(f"bash exited non-zero rc={rc}: {output}")
        elif lines != ["later:bash-case"]:
            failures.append(f"bash should use user PATH after integration, saw {lines!r}")

        zsh_alias_log = tmp / "zsh-alias.log"
        rc, output, lines = run_zsh_script(
            shell_dir,
            user_bin,
            zsh_alias_log,
            f'alias claude="{user_bin / "claude"}"\nsource "{shell_dir / "cmux-zsh-integration.zsh"}"\nclaude zsh-alias-case\n',
        )
        if rc != 0:
            failures.append(f"zsh alias case exited non-zero rc={rc}: {output}")
        elif lines != ["user-alias:zsh-alias-case"]:
            failures.append(f"zsh alias case should preserve user alias, saw {lines!r}")

        zsh_function_log = tmp / "zsh-function.log"
        rc, output, lines = run_zsh_script(
            shell_dir,
            user_bin,
            zsh_function_log,
            f'claude() {{ "{user_bin / "user-claude-function"}" "$@"; }}\nsource "{shell_dir / "cmux-zsh-integration.zsh"}"\nclaude zsh-function-case\n',
        )
        if rc != 0:
            failures.append(f"zsh function case exited non-zero rc={rc}: {output}")
        elif lines != ["user-function:zsh-function-case"]:
            failures.append(f"zsh function case should preserve user function, saw {lines!r}")

        bash_alias_log = tmp / "bash-alias.log"
        rc, output, lines = run_bash_script(
            shell_dir,
            user_bin,
            bash_alias_log,
            f'shopt -s expand_aliases\nalias claude="{user_bin / "claude"}"\nsource "{shell_dir / "cmux-bash-integration.bash"}"\nclaude bash-alias-case\n',
        )
        if rc != 0:
            failures.append(f"bash alias case exited non-zero rc={rc}: {output}")
        elif lines != ["user-alias:bash-alias-case"]:
            failures.append(f"bash alias case should preserve user alias, saw {lines!r}")

        bash_function_log = tmp / "bash-function.log"
        rc, output, lines = run_bash_script(
            shell_dir,
            user_bin,
            bash_function_log,
            f'claude() {{ "{user_bin / "user-claude-function"}" "$@"; }}\nsource "{shell_dir / "cmux-bash-integration.bash"}"\nclaude bash-function-case\n',
        )
        if rc != 0:
            failures.append(f"bash function case exited non-zero rc={rc}: {output}")
        elif lines != ["user-function:bash-function-case"]:
            failures.append(f"bash function case should preserve user function, saw {lines!r}")

    if failures:
        print("FAIL: shell integration did not leave user Claude resolution in control")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: zsh and bash integrations leave Claude resolution to user shell state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
