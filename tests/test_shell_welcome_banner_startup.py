#!/usr/bin/env python3
"""
Regression: the first-launch welcome banner must not land in shell history.

cmux used to type `cmux welcome` into the first workspace's shell, which
recorded it in the user's history. The app now sets CMUX_SHOW_WELCOME on that
shell instead, and each bundled integration prints the banner once during
startup by running the bundled CLI directly, then unsets the variable so child
processes and later shells do not repeat it.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    integration_dir = root / "Resources" / "shell-integration"
    integrations = [
        ("zsh", ["/bin/zsh", "-f", "-c"], integration_dir / "cmux-zsh-integration.zsh", 'echo "after=${CMUX_SHOW_WELCOME-unset}"'),
        ("bash", ["/bin/bash", "--noprofile", "--norc", "-c"], integration_dir / "cmux-bash-integration.bash", 'echo "after=${CMUX_SHOW_WELCOME-unset}"'),
        (
            "fish",
            [shutil.which("fish") or "/usr/local/bin/fish", "--no-config", "-c"],
            integration_dir / "fish" / "config.fish",
            "set -q CMUX_SHOW_WELCOME; and echo after=set; or echo after=unset",
        ),
    ]

    with tempfile.TemporaryDirectory(prefix="cmux_welcome_banner_") as tmp:
        bundle = Path(tmp)
        (bundle / "bin").mkdir()
        (bundle / "shell-integration").mkdir()
        fake_cli = bundle / "bin" / "cmux"
        fake_cli.write_text('#!/bin/sh\nprintf "FAKE-CMUX-%s\\n" "$1"\n', encoding="utf-8")
        fake_cli.chmod(0o755)

        checked = 0
        for shell, command, script, unset_probe in integrations:
            if not script.exists():
                print(f"SKIP: missing {shell} integration script at {script}")
                continue
            if not Path(command[0]).exists():
                print(f"SKIP: missing {shell} executable at {command[0]}")
                continue

            for show in (True, False):
                env = dict(os.environ)
                env.pop("CMUX_SHOW_WELCOME", None)
                env["CMUX_SHELL_INTEGRATION_DIR"] = str(bundle / "shell-integration")
                env["CMUX_TEST_INTEGRATION_SCRIPT"] = str(script)
                env["CMUX_FISH_USER_CONFIG_ALREADY_LOADED"] = "1"
                env["PATH"] = "/usr/bin:/bin"
                if show:
                    env["CMUX_SHOW_WELCOME"] = "1"
                result = subprocess.run(
                    [*command, f'source "$CMUX_TEST_INTEGRATION_SCRIPT"; {unset_probe}'],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                output = (result.stdout or "") + (result.stderr or "")
                count = output.count("FAKE-CMUX-welcome")
                if show:
                    if count != 1:
                        print(f"FAIL: {shell} printed the welcome banner {count} times, expected once")
                        print(output)
                        return 1
                    if "after=unset" not in output:
                        print(f"FAIL: {shell} left CMUX_SHOW_WELCOME set after printing the banner")
                        print(output)
                        return 1
                elif count != 0:
                    print(f"FAIL: {shell} printed the welcome banner without CMUX_SHOW_WELCOME")
                    print(output)
                    return 1
            checked += 1

        if checked == 0:
            print("FAIL: no shell integration was exercised")
            return 1

    print("PASS: shell integrations print the welcome banner once from startup without typing a command")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
