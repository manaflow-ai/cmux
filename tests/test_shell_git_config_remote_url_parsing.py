#!/usr/bin/env python3
"""
Regression coverage for shell-side GitHub remote slug parsing.

The sidebar PR probe reads .git/config directly so it does not spawn git while
refreshing metadata. Quoted git config URL values must match git's parsed value
closely enough that the app still scopes gh calls with --repo.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import textwrap
from pathlib import Path


def _shell_command() -> str:
    return textwrap.dedent(
        """\
        source "$CMUX_TEST_SCRIPT"
        _cmux_github_repo_slug_for_path "$CMUX_TEST_REPO"
        """
    )


def _run_case(
    base: Path,
    *,
    shell: str,
    shell_args: list[str],
    script: Path,
    config_mode: str,
) -> tuple[int, str]:
    repo = base / shell / config_mode / "repo"
    git_dir = repo / ".git"
    git_dir.mkdir(parents=True, exist_ok=True)
    (git_dir / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")

    remote_config = textwrap.dedent(
        """\
        [remote "origin"] ; manually annotated main remote
            url = "https://github.com/manaflow-ai/cmux.git" # canonical repo
            fetch = +refs/heads/*:refs/remotes/origin/*
        """
    )
    stale_remote_config = textwrap.dedent(
        """\
        [remote "origin"]
            url = https://github.com/example/stale.git
        """
    )
    if config_mode == "direct":
        (git_dir / "config").write_text(remote_config, encoding="utf-8")
    elif config_mode == "direct-last-url-wins":
        (git_dir / "config").write_text(
            textwrap.dedent(
                """\
                [remote "origin"]
                    url = https://github.com/example/stale.git
                    url = https://github.com/manaflow-ai/cmux.git
                """
            ),
            encoding="utf-8",
        )
    elif config_mode == "include":
        (git_dir / "config").write_text(
            textwrap.dedent(
                """\
                [include]
                    path = remotes.inc
                """
            ),
            encoding="utf-8",
        )
        (git_dir / "remotes.inc").write_text(remote_config, encoding="utf-8")
    elif config_mode == "includeIf-gitdir":
        (git_dir / "config").write_text(
            textwrap.dedent(
                f"""\
                [includeIf "gitdir:{repo}/"]
                    path = conditional-remotes.inc
                """
            ),
            encoding="utf-8",
        )
        (git_dir / "conditional-remotes.inc").write_text(remote_config, encoding="utf-8")
    elif config_mode == "includeIf-gitdir-recursive":
        (git_dir / "config").write_text(
            textwrap.dedent(
                f"""\
                [includeIf "gitdir:{repo}/**"]
                    path = recursive-conditional-remotes.inc
                """
            ),
            encoding="utf-8",
        )
        (git_dir / "recursive-conditional-remotes.inc").write_text(remote_config, encoding="utf-8")
    elif config_mode == "worktree-config-overrides-common":
        common_dir = git_dir / "common"
        common_dir.mkdir()
        (git_dir / "commondir").write_text("common\n", encoding="utf-8")
        (common_dir / "config").write_text(stale_remote_config, encoding="utf-8")
        (git_dir / "config").write_text(remote_config, encoding="utf-8")
    else:
        return 1, f"unknown config mode {config_mode}"

    env = dict(os.environ)
    env["CMUX_TEST_SCRIPT"] = str(script)
    env["CMUX_TEST_REPO"] = str(repo)

    result = subprocess.run(
        [shell, *shell_args, _shell_command()],
        env=env,
        capture_output=True,
        text=True,
        timeout=5,
    )
    if result.returncode != 0:
        return result.returncode, (result.stdout or "") + (result.stderr or "")

    output = result.stdout.strip()
    if output != "manaflow-ai/cmux":
        return 1, f"{shell} {config_mode}: expected manaflow-ai/cmux, got {output!r}"
    return 0, f"{shell} {config_mode}: ok"


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    cases = [
        ("zsh", ["-f", "-c"], root / "Resources/shell-integration/cmux-zsh-integration.zsh"),
        ("bash", ["--noprofile", "--norc", "-c"], root / "Resources/shell-integration/cmux-bash-integration.bash"),
    ]

    base = Path("/tmp") / f"cmux_shell_git_config_remote_url_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        failures: list[str] = []
        for shell, shell_args, script in cases:
            if not script.exists():
                print(f"SKIP: missing integration script at {script}")
                continue
            for config_mode in (
                "direct",
                "direct-last-url-wins",
                "include",
                "includeIf-gitdir",
                "includeIf-gitdir-recursive",
                "worktree-config-overrides-common",
            ):
                rc, detail = _run_case(
                    base,
                    shell=shell,
                    shell_args=shell_args,
                    script=script,
                    config_mode=config_mode,
                )
                if rc != 0:
                    failures.append(detail)

        if failures:
            print("FAIL:")
            for failure in failures:
                print(failure)
            return 1

        print("PASS: shell git config remote URL parsing follows quoted and included config")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
