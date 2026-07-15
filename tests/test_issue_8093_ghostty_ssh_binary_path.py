#!/usr/bin/env python3
"""Regression coverage for Ghostty SSH wrappers in embedded app bundles.

The terminal host owns the exact CLI executable path. Shell integration must
invoke that path directly instead of rebuilding ``<gui executable dir>/ghostty``.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
ZSH_INTEGRATION = ROOT / "ghostty/src/shell-integration/zsh/ghostty-integration"
BASH_INTEGRATION = ROOT / "ghostty/src/shell-integration/bash/ghostty.bash"
EXPECTED_ARGUMENTS = ["+ssh", "--", "user@example.com"]


def _run_wrapper(shell: str, integration: Path, helper: Path, log: Path) -> None:
    env = os.environ.copy()
    env.update(
        {
            "GHOSTTY_BIN": str(helper),
            # Reproduce cmux's GUI executable directory. No `ghostty` binary
            # exists here because cmux embeds GhosttyKit in its own executable.
            "GHOSTTY_BIN_DIR": str(helper.parents[2] / "MacOS"),
            "GHOSTTY_SHELL_FEATURES": "ssh-env,ssh-terminfo",
            "GHOSTTY_TEST_LOG": str(log),
        }
    )

    if shell == "zsh":
        command = [
            "zsh",
            "-dfc",
            (
                "typeset -gi _ghostty_fd=1; "
                'source "$1"; '
                "_ghostty_deferred_init; "
                "ssh user@example.com"
            ),
            "zsh",
            str(integration),
        ]
    else:
        command = [
            "bash",
            "--noprofile",
            "--norc",
            "-ic",
            'source "$1"; ssh user@example.com',
            "bash",
            str(integration),
        ]

    result = subprocess.run(command, env=env, text=True, capture_output=True)
    if result.returncode != 0:
        raise AssertionError(
            f"{shell} SSH wrapper failed with exit {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )

    actual = log.read_text().splitlines() if log.exists() else []
    if actual != EXPECTED_ARGUMENTS:
        raise AssertionError(
            f"{shell} SSH wrapper invoked the wrong executable or arguments: "
            f"expected {EXPECTED_ARGUMENTS!r}, got {actual!r}"
        )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-issue-8093-") as raw_tmp:
        tmp = Path(raw_tmp)
        contents = tmp / "cmux.app/Contents"
        helper = contents / "Resources/bin/cmux-ghostty-cli"
        helper.parent.mkdir(parents=True)
        (contents / "MacOS").mkdir(parents=True)
        helper.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$GHOSTTY_TEST_LOG"\n')
        helper.chmod(0o755)

        for shell, integration in (
            ("zsh", ZSH_INTEGRATION),
            ("bash", BASH_INTEGRATION),
        ):
            log = tmp / f"{shell}-argv.log"
            _run_wrapper(shell, integration, helper, log)

    print("PASS: Ghostty SSH wrappers invoke the host-provided executable path")


if __name__ == "__main__":
    main()
