#!/usr/bin/env python3
"""Regression coverage for duplicate cmux CLI shim entries in PATH."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SHELL_INTEGRATION_ROOT = REPO_ROOT / "Resources" / "shell-integration"


def _write_executable(path: Path) -> None:
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)


def _prepare_bundle(root: Path) -> tuple[Path, dict[str, Path]]:
    resources = root / "bundle" / "Resources"
    integration_root = resources / "shell-integration"
    fish_root = integration_root / "fish"
    bin_root = resources / "bin"
    fish_root.mkdir(parents=True)
    bin_root.mkdir(parents=True)

    integrations = {
        "zsh": integration_root / "cmux-zsh-integration.zsh",
        "bash": integration_root / "cmux-bash-integration.bash",
        "fish": fish_root / "config.fish",
    }
    shutil.copy2(SHELL_INTEGRATION_ROOT / "cmux-zsh-integration.zsh", integrations["zsh"])
    shutil.copy2(SHELL_INTEGRATION_ROOT / "cmux-bash-integration.bash", integrations["bash"])
    shutil.copy2(SHELL_INTEGRATION_ROOT / "fish" / "config.fish", integrations["fish"])
    _write_executable(bin_root / "cmux-claude-wrapper")
    return integration_root, integrations


def _run_shell(
    shell_name: str,
    executable: str,
    integration_root: Path,
    integration: Path,
    temporary_root: Path,
    normalized_shim_root: Path,
) -> subprocess.CompletedProcess[str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
    env.update(
        {
            # macOS normally exports TMPDIR with this trailing slash.
            "TMPDIR": f"{temporary_root}/",
            "PATH": f"{normalized_shim_root}:/usr/bin:/bin",
            "CMUX_SURFACE_ID": "path-normalization-surface",
            "CMUX_SHELL_INTEGRATION": "1",
            "CMUX_SHELL_INTEGRATION_DIR": str(integration_root),
            "CMUX_TEST_INTEGRATION": str(integration),
            "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION": "0",
            "CMUX_SOCKET_PATH": "",
            "GHOSTTY_RESOURCES_DIR": "",
        }
    )

    if shell_name == "zsh":
        command = [
            executable,
            "-f",
            "-c",
            'source "$CMUX_TEST_INTEGRATION" >/dev/null 2>&1; '
            'printf "root=%s\\n" "${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}"; '
            'printf "path=%s\\n" "$PATH"',
        ]
    elif shell_name == "bash":
        command = [
            executable,
            "--noprofile",
            "--norc",
            "-c",
            'source "$CMUX_TEST_INTEGRATION" >/dev/null 2>&1; '
            'printf "root=%s\\n" "${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}"; '
            'printf "path=%s\\n" "$PATH"',
        ]
    else:
        command = [
            executable,
            "--no-config",
            "-c",
            'source "$CMUX_TEST_INTEGRATION" >/dev/null 2>&1; '
            'printf "root=%s\\n" "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT"; '
            'printf "path=%s\\n" (string join : $PATH)',
        ]

    return subprocess.run(
        command,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_shell_cli_shim_path_is_normalized() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-shim-path-normalization-") as td:
        root = Path(td)
        integration_root, integrations = _prepare_bundle(root)
        temporary_root = root / "temporary"
        normalized_shim_root = (
            temporary_root / "cmux-cli-shims" / "path-normalization-surface"
        )
        normalized_shim_root.mkdir(parents=True)

        tested_shells: list[str] = []
        for shell_name in ("zsh", "bash", "fish"):
            executable = shutil.which(shell_name)
            if executable is None:
                continue
            tested_shells.append(shell_name)
            proc = _run_shell(
                shell_name,
                executable,
                integration_root,
                integrations[shell_name],
                temporary_root,
                normalized_shim_root,
            )
            debug = (
                f"\nshell={shell_name} exit={proc.returncode}"
                f"\n--- stdout ---\n{proc.stdout}"
                f"\n--- stderr ---\n{proc.stderr}"
            )
            assert proc.returncode == 0, "shell integration failed" + debug

            output = dict(
                line.split("=", 1)
                for line in proc.stdout.splitlines()
                if "=" in line
            )
            expected = str(normalized_shim_root)
            assert output.get("root") == expected, (
                "cmux exported a non-normalized CLI shim root" + debug
            )

            path_entries = output.get("path", "").split(":")
            matching_entries = [
                entry for entry in path_entries if os.path.normpath(entry) == expected
            ]
            assert matching_entries == [expected], (
                "cmux left duplicate equivalent CLI shim directories in PATH" + debug
            )

        assert {"zsh", "bash"}.issubset(tested_shells), (
            f"required test shells were unavailable: tested {tested_shells!r}"
        )


if __name__ == "__main__":
    test_shell_cli_shim_path_is_normalized()
    print("PASS: shell integrations keep one normalized cmux CLI shim PATH entry")
