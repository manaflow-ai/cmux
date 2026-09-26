#!/usr/bin/env python3
"""
Regression: the first-launch welcome banner must not land in shell history,
and must print at most once.

cmux used to type `cmux welcome` into the first workspace's shell, which
recorded it in the user's history. The app now writes a one-shot token file and
passes its path in CMUX_SHOW_WELCOME_FILE. Each bundled integration unsets the
variable, prints the banner only if its `rm` of the token succeeds, and never
prints inside tmux, so a child that inherited the variable (for example
`exec tmux` from .bashrc) cannot repeat it.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ENV_KEY = "CMUX_SHOW_WELCOME_FILE"
BANNER = "FAKE-CMUX-welcome"


def run(command: list[str], env: dict[str, str]) -> str:
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
    return (result.stdout or "") + (result.stderr or "")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    integration_dir = root / "Resources" / "shell-integration"
    fish = shutil.which("fish") or "/usr/local/bin/fish"
    integrations = [
        ("zsh", ["/bin/zsh", "-f", "-c"], integration_dir / "cmux-zsh-integration.zsh", f'echo "after=${{{ENV_KEY}-unset}}"'),
        ("bash", ["/bin/bash", "--noprofile", "--norc", "-c"], integration_dir / "cmux-bash-integration.bash", f'echo "after=${{{ENV_KEY}-unset}}"'),
        ("fish", [fish, "--no-config", "-c"], integration_dir / "fish" / "config.fish", f"set -q {ENV_KEY}; and echo after=set; or echo after=unset"),
    ]

    with tempfile.TemporaryDirectory(prefix="cmux_welcome_banner_") as tmp:
        bundle = Path(tmp) / "bundle"
        (bundle / "bin").mkdir(parents=True)
        shell_dir = bundle / "shell-integration"
        shell_dir.mkdir()
        for name in ("cmux-bash-bootstrap.bash", "cmux-bash-integration.bash", "cmux-zsh-integration.zsh", ".zshenv"):
            (shell_dir / name).symlink_to(integration_dir / name)
        fake_cli = bundle / "bin" / "cmux"
        fake_cli.write_text('#!/bin/sh\nprintf "FAKE-CMUX-%s\\n" "$1"\n', encoding="utf-8")
        fake_cli.chmod(0o755)
        home = Path(tmp) / "home"
        home.mkdir()

        def base_env() -> dict[str, str]:
            env = dict(os.environ)
            for key in (ENV_KEY, "CMUX_SHOW_WELCOME", "TMUX", "ZDOTDIR", "PROMPT_COMMAND"):
                env.pop(key, None)
            env["HOME"] = str(home)
            env["CMUX_SHELL_INTEGRATION_DIR"] = str(shell_dir)
            env["CMUX_FISH_USER_CONFIG_ALREADY_LOADED"] = "1"
            env["PATH"] = "/usr/bin:/bin"
            return env

        def new_token() -> Path:
            token = Path(tempfile.mkstemp(dir=tmp, prefix="token-")[1])
            return token

        checked = 0
        for shell, command, script, unset_probe in integrations:
            if not script.exists():
                print(f"SKIP: missing {shell} integration script at {script}")
                continue
            if not Path(command[0]).exists():
                print(f"SKIP: missing {shell} executable at {command[0]}")
                continue

            def source(env: dict[str, str]) -> str:
                env["CMUX_TEST_INTEGRATION_SCRIPT"] = str(script)
                return run([*command, f'source "$CMUX_TEST_INTEGRATION_SCRIPT"; {unset_probe}'], env)

            # Token present: prints once, consumes the token, unsets the variable.
            token = new_token()
            env = base_env()
            env[ENV_KEY] = str(token)
            output = source(env)
            if output.count(BANNER) != 1 or "after=unset" not in output or token.exists():
                print(f"FAIL: {shell} with a fresh token should print once, unset {ENV_KEY}, and remove the token")
                print(output)
                return 1

            # A second shell that inherited the same path must not print again.
            env = base_env()
            env[ENV_KEY] = str(token)
            output = source(env)
            if output.count(BANNER) != 0 or "after=unset" not in output:
                print(f"FAIL: {shell} reprinted the banner from an already consumed token")
                print(output)
                return 1

            # Inside tmux the banner is skipped (and the token still consumed).
            token = new_token()
            env = base_env()
            env[ENV_KEY] = str(token)
            env["TMUX"] = "/tmp/tmux-test/default,1,0"
            output = source(env)
            if output.count(BANNER) != 0 or "after=unset" not in output:
                print(f"FAIL: {shell} printed the banner inside tmux")
                print(output)
                return 1

            # No variable: nothing prints.
            output = source(base_env())
            if output.count(BANNER) != 0:
                print(f"FAIL: {shell} printed the welcome banner without {ENV_KEY}")
                print(output)
                return 1
            checked += 1

        # The bash bootstrap (exported as PROMPT_COMMAND, first prompt) moves the
        # token path out of the environment before sourcing the integration.
        bootstrap = "\n".join(
            line
            for line in (integration_dir / "cmux-bash-bootstrap.bash").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")
        )
        token = new_token()
        env = base_env()
        env[ENV_KEY] = str(token)
        env["CMUX_TEST_BOOTSTRAP"] = bootstrap
        output = run(
            ["/bin/bash", "--noprofile", "--norc", "-c", f'eval "$CMUX_TEST_BOOTSTRAP"; /usr/bin/env | /usr/bin/grep -c "^{ENV_KEY}=" || true; echo "local=${{_CMUX_BOOTSTRAP_WELCOME_FILE-unset}}"'],
            env,
        )
        lines = output.splitlines()
        if output.count(BANNER) != 1 or "0" not in lines or "local=unset" not in lines or token.exists():
            print("FAIL: bash bootstrap should print once and leave no token variable behind")
            print(output)
            return 1
        checked += 1

        # The zsh ZDOTDIR bootstrap moves the token path out of the environment
        # before the user's .zshenv runs, then the integration consumes it.
        home_zshenv = home / ".zshenv"
        home_zshenv.write_text(f'echo "user-zshenv=${{{ENV_KEY}-unset}}"\n', encoding="utf-8")
        token = new_token()
        env = base_env()
        env[ENV_KEY] = str(token)
        env["ZDOTDIR"] = str(shell_dir)
        output = run(["/bin/zsh", "-i", "-c", f'echo "after=${{{ENV_KEY}-unset}}"'], env)
        if output.count(BANNER) != 1 or "user-zshenv=unset" not in output or "after=unset" not in output or token.exists():
            print("FAIL: zsh bootstrap should hide the token from user startup files and print once")
            print(output)
            return 1
        checked += 1

        if checked == 0:
            print("FAIL: no shell integration was exercised")
            return 1

    print("PASS: shell integrations print the welcome banner at most once from startup without typing a command")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
