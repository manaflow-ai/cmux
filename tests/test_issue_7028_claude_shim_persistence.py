#!/usr/bin/env python3
"""Regression coverage for https://github.com/manaflow-ai/cmux/issues/7028.

The per-surface Claude shim is part of a pane's lifetime. It must live below
the user's durable cmux state directory, because macOS periodically removes
files in ``$TMPDIR`` even while the pane and its shell are still running.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SURFACE_ID = "issue-7028-shim"


def _run_shell(
    shell: str,
    integration: Path,
    home: Path,
    tmpdir: Path,
    wrapper: Path,
) -> subprocess.CompletedProcess[str] | None:
    executable = shutil.which(shell)
    if executable is None:
        return None

    if shell == "bash":
        argv = [executable, "--norc", "--noprofile", "-c"]
        source = 'source "$CMUX_TEST_INTEGRATION"'
    elif shell == "zsh":
        argv = [executable, "-f", "-c"]
        source = 'source "$CMUX_TEST_INTEGRATION"'
    else:
        argv = [executable, "--no-config", "-c"]
        source = 'source "$CMUX_TEST_INTEGRATION"'

    driver = "\n".join(
        [
            source,
            'unset CMUX_CLAUDE_WRAPPER_SHIM_ROOT',
            '_cmux_install_cli_command_shim claude "$CMUX_TEST_WRAPPER"',
            'printf "%s\\n" "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT"',
        ]
    )
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("CMUX_")
    }
    environment.update(
        {
            "HOME": str(home),
            "TMPDIR": str(tmpdir),
            "CMUX_TEST_INTEGRATION": str(integration),
            "CMUX_TEST_WRAPPER": str(wrapper),
            "CMUX_SURFACE_ID": SURFACE_ID,
            "CMUX_SOCKET_PATH": "",
            "CMUX_SHELL_INTEGRATION_DIR": "",
            "CMUX_LOAD_GHOSTTY_BASH_INTEGRATION": "0",
            "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": "",
        }
    )
    return subprocess.run(
        [*argv, driver],
        env=environment,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_claude_shim_root_survives_tmpdir_reaping() -> None:
    integrations = {
        "bash": REPO_ROOT / "Resources/shell-integration/cmux-bash-integration.bash",
        "zsh": REPO_ROOT / "Resources/shell-integration/cmux-zsh-integration.zsh",
        "fish": REPO_ROOT / "Resources/shell-integration/fish/config.fish",
    }

    with tempfile.TemporaryDirectory(prefix="cmux-7028-") as td:
        root = Path(td)
        home = root / "home with spaces"
        tmpdir = root / "tmp"
        wrapper = root / "cmux-claude-wrapper"
        home.mkdir()
        tmpdir.mkdir()
        wrapper.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        wrapper.chmod(0o700)

        expected_root = home / ".cmuxterm" / "cmux-cli-shims" / SURFACE_ID
        legacy_root = tmpdir / "cmux-cli-shims" / SURFACE_ID
        for shell, integration in integrations.items():
            result = _run_shell(shell, integration, home, tmpdir, wrapper)
            if result is None:
                continue
            debug = (
                f"\\n{shell} exit={result.returncode}"
                f"\\n--- stdout ---\\n{result.stdout}"
                f"\\n--- stderr ---\\n{result.stderr}"
            )
            assert result.returncode == 0, f"{shell} integration failed{debug}"
            assert result.stdout.strip().splitlines()[-1:] == [str(expected_root)], (
                f"{shell} still derived its shim root from TMPDIR{debug}"
            )
            assert (expected_root / "claude").is_file(), (
                f"{shell} did not create the durable Claude shim{debug}"
            )
            assert not (legacy_root / "claude").exists(), (
                f"{shell} recreated the purgeable TMPDIR shim{debug}"
            )
            (expected_root / "claude").unlink()


if __name__ == "__main__":
    test_claude_shim_root_survives_tmpdir_reaping()
    print("PASS: Claude shims use durable per-surface storage")
