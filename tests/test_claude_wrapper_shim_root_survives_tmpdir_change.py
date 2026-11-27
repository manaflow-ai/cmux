#!/usr/bin/env python3
"""Behavior coverage for preserving cmux's app-installed command-shim root."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SURFACE_ID = "99999999-9999-4999-8999-999999999999"


def make_executable(path: Path) -> None:
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)


def run_integration(
    shell: str,
    argv: list[str],
    driver: str,
    integration: Path,
    environment: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    executable = shutil.which(shell)
    if executable is None:
        raise RuntimeError(f"required shell is unavailable: {shell}")
    env = environment.copy()
    env["CMUX_TEST_INTEGRATION"] = str(integration)
    return subprocess.run(
        [executable, *argv, driver],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def main() -> int:
    integrations = {
        "bash": (
            ["--noprofile", "--norc", "-c"],
            'source "$CMUX_TEST_INTEGRATION"\n'
            '_cmux_install_cli_command_shim claude "$CMUX_TEST_WRAPPER"\n'
            'printf "%s\\n" "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT"',
            REPO_ROOT / "Resources/shell-integration/cmux-bash-integration.bash",
        ),
        "zsh": (
            ["-f", "-c"],
            'source "$CMUX_TEST_INTEGRATION"\n'
            '_cmux_install_cli_command_shim claude "$CMUX_TEST_WRAPPER"\n'
            'printf "%s\\n" "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT"',
            REPO_ROOT / "Resources/shell-integration/cmux-zsh-integration.zsh",
        ),
    }
    fish = shutil.which("fish")
    if fish is not None:
        integrations["fish"] = (
            ["--no-config", "-c"],
            'source "$CMUX_TEST_INTEGRATION"\n'
            '_cmux_install_cli_command_shim claude "$CMUX_TEST_WRAPPER"\n'
            'printf "%s\\n" "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT"',
            REPO_ROOT / "Resources/shell-integration/fish/config.fish",
        )

    with tempfile.TemporaryDirectory(prefix="cmux-shim-root-") as td:
        root = Path(td)
        managed_root = root / "app installed" / "cmux-cli-shims" / SURFACE_ID
        changed_tmpdir = root / "profile tmp"
        wrapper = root / "cmux-claude-wrapper"
        managed_root.mkdir(parents=True)
        changed_tmpdir.mkdir()
        make_executable(wrapper)

        env = {
            key: value for key, value in os.environ.items() if not key.startswith("CMUX_")
        }
        env.update(
            {
                "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(managed_root),
                "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION": "0",
                "CMUX_SHELL_INTEGRATION_DIR": "",
                "CMUX_SOCKET_PATH": "",
                "CMUX_SURFACE_ID": SURFACE_ID,
                "CMUX_TEST_WRAPPER": str(wrapper),
                "GHOSTTY_RESOURCES_DIR": "",
                "TMPDIR": str(changed_tmpdir),
            }
        )

        for shell, (argv, driver, integration) in integrations.items():
            proc = run_integration(shell, argv, driver, integration, env)
            if proc.returncode != 0:
                print(f"FAIL: {shell} integration failed after TMPDIR changed")
                print(f"stdout={proc.stdout!r}")
                print(f"stderr={proc.stderr!r}")
                return 1
            if proc.stdout.strip().splitlines()[-1:] != [str(managed_root)]:
                print(f"FAIL: {shell} replaced the app-installed shim root")
                print(f"stdout={proc.stdout!r}")
                return 1
            if not (managed_root / "claude").is_file():
                print(f"FAIL: {shell} did not write into the app-installed shim root")
                return 1
            fallback = changed_tmpdir / "cmux-cli-shims" / SURFACE_ID / "claude"
            if fallback.exists():
                print(f"FAIL: {shell} re-derived the shim root from changed TMPDIR")
                return 1
            (managed_root / "claude").unlink()

    print("PASS: shell integrations preserve the app-installed shim root after TMPDIR changes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
