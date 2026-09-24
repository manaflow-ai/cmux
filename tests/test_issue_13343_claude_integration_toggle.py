#!/usr/bin/env python3
"""Regression coverage for https://github.com/manaflow-ai/cmux/issues/13343."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INTEGRATIONS = {
    "zsh": REPO_ROOT / "Resources/shell-integration/cmux-zsh-integration.zsh",
    "bash": REPO_ROOT / "Resources/shell-integration/cmux-bash-integration.bash",
    "nu": REPO_ROOT / "Resources/shell-integration/nushell/cmux-nushell-integration.nu",
}

DRIVERS = {
    "zsh": r"""
source "$CMUX_TEST_INTEGRATION"
if (( $+functions[claude] )); then
    print -r -- 'function=1'
else
    print -r -- 'function=0'
fi
print -r -- "command=$(command -v claude)"
shim="$TMPDIR/cmux-cli-shims/$CMUX_SURFACE_ID/claude"
if [[ -e "$shim" ]]; then
    print -r -- 'shim=1'
else
    print -r -- 'shim=0'
fi
""",
    "bash": r"""
source "$CMUX_TEST_INTEGRATION"
if declare -F claude >/dev/null 2>&1; then
    printf '%s\n' 'function=1'
else
    printf '%s\n' 'function=0'
fi
printf 'command=%s\n' "$(command -v claude)"
shim="$TMPDIR/cmux-cli-shims/$CMUX_SURFACE_ID/claude"
if [[ -e "$shim" ]]; then
    printf '%s\n' 'shim=1'
else
    printf '%s\n' 'shim=0'
fi
""",
}


def _clean_environment(root: Path, user_bin: Path, shell: str) -> dict[str, str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("CMUX") and key != "GHOSTTY_RESOURCES_DIR"
    }
    env.update(
        {
            "PATH": f"{user_bin}:/usr/bin:/bin",
            "TMPDIR": str(root),
            "CMUX_SURFACE_ID": f"issue-13343-{shell}",
            "CMUX_SHELL_INTEGRATION_DIR": str(REPO_ROOT / "Resources/shell-integration"),
            "CMUX_SOCKET_PATH": "",
            "GHOSTTY_RESOURCES_DIR": "",
        }
    )
    return env


def _run_posix_shell(
    shell: str, *, disabled: bool
) -> tuple[subprocess.CompletedProcess[str], str]:
    shell_path = shutil.which(shell)
    assert shell_path is not None, f"{shell} is unavailable"

    with tempfile.TemporaryDirectory(prefix=f"cmux-13343-{shell}-") as td:
        root = Path(td)
        user_bin = root / "user-bin"
        user_bin.mkdir()
        user_claude = user_bin / "claude"
        user_claude.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        user_claude.chmod(0o700)

        env = _clean_environment(root, user_bin, shell)
        env["CMUX_TEST_INTEGRATION"] = str(INTEGRATIONS[shell])
        if shell == "zsh":
            env["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "0"
            arguments = [shell_path, "-f", "-c", DRIVERS[shell]]
        else:
            env["CMUX_LOAD_GHOSTTY_BASH_INTEGRATION"] = "0"
            arguments = [shell_path, "--norc", "--noprofile", "-c", DRIVERS[shell]]
        if disabled:
            env["CMUX_CLAUDE_INTEGRATION_DISABLED"] = "1"

        result = subprocess.run(
            arguments,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        return result, str(user_claude)


def _find_nu() -> str | None:
    candidates = [
        os.environ.get("CMUX_TEST_NU_BIN"),
        shutil.which("nu"),
        "/opt/homebrew/bin/nu",
        "/usr/local/bin/nu",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def _run_nushell(
    *, disabled: bool
) -> tuple[subprocess.CompletedProcess[str], str] | None:
    nu = _find_nu()
    if nu is None:
        if os.environ.get("CI"):
            raise AssertionError("nushell is required on CI for issue #13343 coverage")
        return None

    with tempfile.TemporaryDirectory(prefix="cmux-13343-nu-") as td:
        root = Path(td)
        user_bin = root / "user-bin"
        user_bin.mkdir()
        user_claude = user_bin / "claude"
        user_claude.write_text("#!/bin/sh\necho user-claude\n", encoding="utf-8")
        user_claude.chmod(0o700)
        shim = root / "cmux-claude-shim"
        shim.write_text("#!/bin/sh\necho cmux-shim\n", encoding="utf-8")
        shim.chmod(0o700)

        env = _clean_environment(root, user_bin, "nu")
        env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(shim)
        if disabled:
            env["CMUX_CLAUDE_INTEGRATION_DISABLED"] = "1"

        integration = str(INTEGRATIONS["nu"]).replace('"', r'\"')
        # Nushell cannot drop a definition at run time (`hide` is parse-time),
        # so the wrapper stays defined and the toggle decides where it routes.
        script = "; ".join(
            [
                f'source "{integration}"',
                "print $\"custom=((scope commands | where name == 'claude' | length))\"",
                "print $\"ran=((claude | str trim))\"",
            ]
        )
        result = subprocess.run(
            [nu, "-n", "-c", script],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        return result, str(user_claude)


def _assert_enabled(shell: str) -> None:
    result, _ = _run_posix_shell(shell, disabled=False)
    assert result.returncode == 0, result.stderr
    assert "function=1" in result.stdout, result.stdout
    assert "shim=1" in result.stdout, result.stdout


def _assert_disabled(shell: str) -> None:
    result, user_claude = _run_posix_shell(shell, disabled=True)
    assert result.returncode == 0, result.stderr
    assert "function=0" in result.stdout, result.stdout
    assert "shim=0" in result.stdout, result.stdout
    assert f"command={user_claude}" in result.stdout, result.stdout


def test_zsh_enabled_installs_claude_wrapper_and_shim() -> None:
    _assert_enabled("zsh")


def test_zsh_disabled_leaves_user_claude_unwrapped() -> None:
    _assert_disabled("zsh")


def test_bash_enabled_installs_claude_wrapper_and_shim() -> None:
    _assert_enabled("bash")


def test_bash_disabled_leaves_user_claude_unwrapped() -> None:
    _assert_disabled("bash")


def test_nushell_enabled_defines_claude_wrapper() -> None:
    run = _run_nushell(disabled=False)
    if run is None:
        return
    result, _ = run
    assert result.returncode == 0, result.stderr
    assert "custom=1" in result.stdout, result.stdout
    assert "ran=cmux-shim" in result.stdout, result.stdout


def test_nushell_disabled_leaves_user_claude_unwrapped() -> None:
    run = _run_nushell(disabled=True)
    if run is None:
        return
    result, _ = run
    assert result.returncode == 0, result.stderr
    assert "ran=user-claude" in result.stdout, result.stdout


if __name__ == "__main__":
    for shell_name in ("zsh", "bash"):
        _assert_enabled(shell_name)
        _assert_disabled(shell_name)

    nu_enabled = _run_nushell(disabled=False)
    nu_disabled = _run_nushell(disabled=True)
    if nu_enabled is not None and nu_disabled is not None:
        enabled_result, _ = nu_enabled
        disabled_result, _ = nu_disabled
        assert enabled_result.returncode == 0, enabled_result.stderr
        assert "custom=1" in enabled_result.stdout, enabled_result.stdout
        assert "ran=cmux-shim" in enabled_result.stdout, enabled_result.stdout
        assert disabled_result.returncode == 0, disabled_result.stderr
        assert "ran=user-claude" in disabled_result.stdout, disabled_result.stdout

    print("PASS: Claude integration toggle controls shell wrapper and shim installation")
