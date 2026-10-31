#!/usr/bin/env python3
"""Every cmux shell integration drops blank Claude account variables at startup.

Switching a pane to the default Claude account can only blank a variable the
pane inherits from the app or the workspace, not unset it, so the respawned
shell may start with ``CLAUDE_CONFIG_DIR=`` or
``CLAUDE_SECURESTORAGE_CONFIG_DIR=``. Claude Code reads an empty
``CLAUDE_CONFIG_DIR`` as a relative path and an empty
``CLAUDE_SECURESTORAGE_CONFIG_DIR`` as the default account's credentials, so a
``claude`` started outside the cmux wrapper must never see either one blank.

This drives the real bundled integration of each shell, then lists the
environment a child process receives:

1. A blank variable is unset.
2. A non-empty variable is passed through unchanged.
3. Blank variables are unset even with the Claude integration turned off,
   because the cleanup runs before anything in the script can return early.

zsh and bash always run. fish and nushell skip loudly when they are not
installed locally and fail when ``CI`` is set, so CI never skips silently.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
INTEGRATION_DIR = REPO_ROOT / "Resources/shell-integration"
ACCOUNT_KEYS = ("CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR")

POSIX_SHELLS = {
    "zsh": ("cmux-zsh-integration.zsh", ["-f", "-c"]),
    "bash": ("cmux-bash-integration.bash", ["--norc", "--noprofile", "-c"]),
    "fish": ("fish/config.fish", ["--no-config", "-c"]),
}


def _find_shell(shell: str) -> str | None:
    candidates = [shutil.which(shell)]
    if shell == "nu":
        candidates.insert(0, os.environ.get("CMUX_TEST_NU_BIN"))
        candidates += ["/opt/homebrew/bin/nu", "/usr/local/bin/nu"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def _require_shell(shell: str) -> str | None:
    executable = _find_shell(shell)
    if executable is not None:
        return executable
    if shell in ("zsh", "bash") or os.environ.get("CI"):
        raise AssertionError(f"required shell unavailable: {shell}")
    print(f"SKIP: {shell} not found; CI runs this case")
    return None


def _environment(root: Path, account_values: dict[str, str], *, claude_disabled: bool) -> dict[str, str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("CMUX") and key not in ACCOUNT_KEYS and key != "GHOSTTY_RESOURCES_DIR"
    }
    env.update(
        {
            "HOME": str(root / "home"),
            "TMPDIR": str(root),
            "PATH": "/usr/bin:/bin",
            "CMUX_SURFACE_ID": "claude-account-env-test",
            "CMUX_SHELL_INTEGRATION_DIR": "",
            "CMUX_SOCKET_PATH": "",
            "CMUX_LOAD_GHOSTTY_BASH_INTEGRATION": "0",
            "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": "",
        }
    )
    env.update(account_values)
    if claude_disabled:
        env["CMUX_CLAUDE_INTEGRATION_DISABLED"] = "1"
    return env


def _child_account_environment(
    shell: str, executable: str, account_values: dict[str, str], *, claude_disabled: bool = False
) -> dict[str, str]:
    """Source the shell's integration, then return the account keys `/usr/bin/env` sees."""
    with tempfile.TemporaryDirectory(prefix=f"cmux-claude-account-env-{shell}-") as td:
        root = Path(td)
        (root / "home" / ".cmuxterm").mkdir(parents=True)
        env = _environment(root, account_values, claude_disabled=claude_disabled)
        if shell == "nu":
            integration = str(INTEGRATION_DIR / "nushell/cmux-nushell-integration.nu").replace('"', r"\"")
            arguments = [executable, "-n", "-c", f'source "{integration}"; ^/usr/bin/env']
        else:
            filename, flags = POSIX_SHELLS[shell]
            env["CMUX_TEST_INTEGRATION"] = str(INTEGRATION_DIR / filename)
            arguments = [executable, *flags, 'source "$CMUX_TEST_INTEGRATION"; /usr/bin/env']
        result = subprocess.run(
            arguments, env=env, capture_output=True, text=True, timeout=30, check=False
        )
        assert result.returncode == 0, f"{shell}: {result}"
        child: dict[str, str] = {}
        for line in result.stdout.splitlines():
            key, separator, value = line.partition("=")
            if separator and key in ACCOUNT_KEYS:
                child[key] = value
        return child


def _assert_shell(shell: str) -> None:
    executable = _require_shell(shell)
    if executable is None:
        return

    blank = {key: "" for key in ACCOUNT_KEYS}
    child = _child_account_environment(shell, executable, blank)
    assert child == {}, f"{shell} passed blank account variables to a child: {child}"

    child = _child_account_environment(shell, executable, blank, claude_disabled=True)
    assert child == {}, f"{shell} kept blank account variables with Claude integration off: {child}"

    work = {
        "CLAUDE_CONFIG_DIR": "/tmp/cmux-claude-account-env/work",
        "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/cmux-claude-account-env/work-secure",
    }
    child = _child_account_environment(shell, executable, work)
    assert child == work, f"{shell} changed non-empty account variables: {child}"

    mixed = {"CLAUDE_CONFIG_DIR": "", "CLAUDE_SECURESTORAGE_CONFIG_DIR": work["CLAUDE_SECURESTORAGE_CONFIG_DIR"]}
    child = _child_account_environment(shell, executable, mixed)
    assert child == {"CLAUDE_SECURESTORAGE_CONFIG_DIR": work["CLAUDE_SECURESTORAGE_CONFIG_DIR"]}, (
        f"{shell} did not drop only the blank account variable: {child}"
    )
    print(f"PASS: {shell} unsets blank Claude account variables and keeps set ones")


def test_zsh_unsets_blank_claude_account_variables() -> None:
    _assert_shell("zsh")


def test_bash_unsets_blank_claude_account_variables() -> None:
    _assert_shell("bash")


def test_fish_unsets_blank_claude_account_variables() -> None:
    _assert_shell("fish")


def test_nushell_unsets_blank_claude_account_variables() -> None:
    _assert_shell("nu")


if __name__ == "__main__":
    for shell_name in ("zsh", "bash", "fish", "nu"):
        _assert_shell(shell_name)
