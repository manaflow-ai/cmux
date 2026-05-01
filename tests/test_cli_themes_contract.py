#!/usr/bin/env python3
"""
Executable contract checks for `cmux themes`.

These tests exercise the built CLI with a fake home directory and fake Ghostty
theme resources. They verify accepted legacy spellings and output/filesystem
behavior, not Swift source shape.
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import tempfile
import uuid
from pathlib import Path


THEMES = [
    "Catppuccin Latte",
    "Catppuccin Mocha",
    "Solarized Dark",
]


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates = [path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def write_fake_theme_resources(root: Path) -> Path:
    resources = root / "ghostty-resources"
    themes_dir = resources / "themes"
    themes_dir.mkdir(parents=True)
    for theme in THEMES:
        (themes_dir / theme).write_text("# fake theme\n", encoding="utf-8")
    return resources


def base_env(root: Path, resources: Path) -> tuple[dict[str, str], str]:
    env = dict(os.environ)
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
    ]:
        env.pop(key, None)

    home = root / "home"
    home.mkdir()
    no_socket = str(root / f"cmux-themes-{uuid.uuid4().hex}.sock")

    env["HOME"] = str(home)
    env["CFFIXED_USER_HOME"] = str(home)
    env["GHOSTTY_RESOURCES_DIR"] = str(resources)
    env["XDG_DATA_DIRS"] = ""
    env["CMUX_BUNDLE_ID"] = "com.cmuxterm.themes-contract"
    env["CMUX_SOCKET_PATH"] = no_socket
    env["CMUX_SOCKET"] = no_socket
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    return env, no_socket


def run_cli(cli_path: str, env: dict[str, str], no_socket: str, args: list[str]) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(  # noqa: S603
        [cli_path, *args],
        text=True,
        capture_output=True,
        check=False,
        timeout=10.0,
        env=env,
    )
    merged = f"{proc.stdout}\n{proc.stderr}"
    if no_socket in merged:
        raise RuntimeError(f"themes command unexpectedly touched forced socket path {no_socket!r}")
    return proc


def require_success(proc: subprocess.CompletedProcess[str], args: list[str]) -> None:
    if proc.returncode != 0:
        raise RuntimeError(
            f"cmux {' '.join(args)} failed with {proc.returncode}\n"
            f"stdout={proc.stdout!r}\nstderr={proc.stderr!r}"
        )


def require_failure(proc: subprocess.CompletedProcess[str], args: list[str], expected: str) -> None:
    merged = f"{proc.stdout}\n{proc.stderr}"
    if proc.returncode == 0:
        raise RuntimeError(f"cmux {' '.join(args)} unexpectedly succeeded\nstdout={proc.stdout!r}")
    if expected not in merged:
        raise RuntimeError(
            f"cmux {' '.join(args)} missing {expected!r}\n"
            f"stdout={proc.stdout!r}\nstderr={proc.stderr!r}"
        )


def config_contents(config_path: str) -> str:
    return Path(config_path).read_text(encoding="utf-8")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
        with tempfile.TemporaryDirectory(prefix="cmux-themes-contract-") as tmp:
            root = Path(tmp)
            resources = write_fake_theme_resources(root)
            env, no_socket = base_env(root, resources)

            proc = run_cli(cli_path, env, no_socket, ["--json", "themes", "list"])
            require_success(proc, ["--json", "themes", "list"])
            listing = json.loads(proc.stdout)
            listed_names = {item["name"] for item in listing["themes"]}
            missing = sorted(set(THEMES) - listed_names)
            if missing:
                raise RuntimeError(f"themes list missed fake resources: {missing}")
            config_path = listing["config_path"]
            if str(root) not in config_path:
                raise RuntimeError(f"theme config path escaped fake home: {config_path}")

            proc = run_cli(cli_path, env, no_socket, ["themes", "set", "Catppuccin", "Mocha"])
            require_success(proc, ["themes", "set", "Catppuccin", "Mocha"])
            contents = config_contents(config_path)
            if "theme = light:Catppuccin Mocha,dark:Catppuccin Mocha" not in contents:
                raise RuntimeError(f"multi-token theme set wrote wrong config:\n{contents}")

            proc = run_cli(cli_path, env, no_socket, ["themes", "Catppuccin", "Latte"])
            require_success(proc, ["themes", "Catppuccin", "Latte"])
            contents = config_contents(config_path)
            if "theme = light:Catppuccin Latte,dark:Catppuccin Latte" not in contents:
                raise RuntimeError(f"legacy shorthand theme set wrote wrong config:\n{contents}")

            proc = run_cli(
                cli_path,
                env,
                no_socket,
                [
                    "--json",
                    "themes",
                    "set",
                    "--light",
                    "Catppuccin Latte",
                    "--dark",
                    "Catppuccin Mocha",
                ],
            )
            require_success(proc, ["--json", "themes", "set", "--light", "...", "--dark", "..."])
            payload = json.loads(proc.stdout)
            if payload["light"] != "Catppuccin Latte" or payload["dark"] != "Catppuccin Mocha":
                raise RuntimeError(f"split light/dark JSON mismatch: {payload!r}")

            proc = run_cli(
                cli_path,
                env,
                no_socket,
                [
                    "themes",
                    "set",
                    "--light",
                    "Solarized Dark",
                    "--light",
                    "Catppuccin Latte",
                    "--dark",
                    "Catppuccin Mocha",
                ],
            )
            require_success(proc, ["themes", "set", "--light", "...", "--light", "...", "--dark", "..."])
            contents = config_contents(config_path)
            if "theme = light:Catppuccin Latte,dark:Catppuccin Mocha" not in contents:
                raise RuntimeError(f"repeated --light did not keep last value:\n{contents}")

            proc = run_cli(cli_path, env, no_socket, ["themes", "set", "--light", "Catppuccin Latte", "extra"])
            require_failure(proc, ["themes", "set", "--light", "Catppuccin Latte", "extra"], "themes set: unexpected argument 'extra'")

            proc = run_cli(cli_path, env, no_socket, ["themes", "set", "--unknown", "Catppuccin Latte"])
            require_failure(proc, ["themes", "set", "--unknown", "Catppuccin Latte"], "themes set: unknown flag '--unknown'")

            proc = run_cli(cli_path, env, no_socket, ["themes", "set"])
            require_failure(proc, ["themes", "set"], "themes set requires a theme name or --light/--dark flags")

            proc = run_cli(cli_path, env, no_socket, ["themes", "list", "extra"])
            require_failure(proc, ["themes", "list", "extra"], "themes list does not take any positional arguments")

            proc = run_cli(cli_path, env, no_socket, ["themes", "clear", "extra"])
            require_failure(proc, ["themes", "clear", "extra"], "themes clear does not take any positional arguments")

            proc = run_cli(cli_path, env, no_socket, ["themes", "--bogus"])
            require_failure(proc, ["themes", "--bogus"], "Unknown themes subcommand '--bogus'")

            proc = run_cli(cli_path, env, no_socket, ["--json", "themes", "clear"])
            require_success(proc, ["--json", "themes", "clear"])
            payload = json.loads(proc.stdout)
            if payload["cleared"] is not True:
                raise RuntimeError(f"clear JSON mismatch: {payload!r}")
            if Path(config_path).exists() and "cmux themes start" in config_contents(config_path):
                raise RuntimeError(f"themes clear left managed block in config:\n{config_contents(config_path)}")

        print("PASS: CLI themes contract preserves list, set, shorthand, split light/dark, clear, and legacy errors")
        return 0
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
