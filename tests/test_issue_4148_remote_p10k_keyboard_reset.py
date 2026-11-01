#!/usr/bin/env python3
"""Regression coverage for cmux#4148.

The prompt-boundary Kitty reset must not race Powerlevel10k's first remote
worker handshake.  The reset remains enabled for local p10k and remote shells
without p10k.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = ROOT / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"
RESET = "\x1b[>m\x1b[<8u"


def run_reset(remote: bool, p10k: str | None) -> subprocess.CompletedProcess[str]:
    setup = [f'source "$1"', 'export CMUX_TEST_FORCE_KEYBOARD_RESET=1']
    if remote:
        setup.append("export CMUX_REMOTE_TRANSPORT=ws")
    if p10k:
        setup.append(f"{p10k}() {{ :; }}")
    setup.append("_cmux_reset_terminal_keyboard_protocols")
    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
    env.update({"HOME": "/tmp", "LC_ALL": "C", "PATH": "/usr/bin:/bin"})
    return subprocess.run(
        ["zsh", "-f", "-c", "\n".join(setup), "cmux-test", str(INTEGRATION)],
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )


def test_remote_p10k_prompt_does_not_reset_kitty_protocol() -> None:
    if shutil.which("zsh") is None:
        return

    remote_p10k = run_reset(remote=True, p10k="p10k")
    assert remote_p10k.returncode == 0, remote_p10k.stderr
    assert remote_p10k.stdout == ""

    remote_p9k_init = run_reset(remote=True, p10k="_p9k_init")
    assert remote_p9k_init.returncode == 0, remote_p9k_init.stderr
    assert remote_p9k_init.stdout == ""

    local_p10k = run_reset(remote=False, p10k="p10k")
    assert local_p10k.returncode == 0, local_p10k.stderr
    assert local_p10k.stdout == RESET

    remote_plain = run_reset(remote=True, p10k=None)
    assert remote_plain.returncode == 0, remote_plain.stderr
    assert remote_plain.stdout == RESET


if __name__ == "__main__":
    test_remote_p10k_prompt_does_not_reset_kitty_protocol()
    print("PASS: remote Powerlevel10k prompt skips the Kitty reset race")
