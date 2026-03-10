#!/usr/bin/env python3
"""
Regression for issue #1138:
sidebar PR badges should recover from a transient gh failure without waiting
for another prompt, and a failed gh probe should not eagerly clear PR state.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import textwrap
from pathlib import Path


class BoundUnixSocket:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.sock: socket.socket | None = None

    def __enter__(self) -> "BoundUnixSocket":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(self.path))
        self.sock.listen(1)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.sock is not None:
            self.sock.close()
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


def _write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def _git_stub() -> str:
    return textwrap.dedent(
        """\
        #!/bin/sh
        if [ "$1" = "-C" ]; then
          shift
          shift
        fi

        if [ "$1" = "branch" ] && [ "$2" = "--show-current" ]; then
          printf '%s\\n' 'feature/issue-1138'
          exit 0
        fi

        if [ "$1" = "status" ] && [ "$2" = "--porcelain" ] && [ "$3" = "-uno" ]; then
          exit 0
        fi

        printf 'unexpected git args: %s\\n' "$*" >&2
        exit 1
        """
    )


def _gh_stub() -> str:
    return textwrap.dedent(
        """\
        #!/bin/sh
        count_file="${CMUX_TEST_GH_COUNT_FILE:?}"
        count=0
        if [ -f "$count_file" ]; then
          count="$(cat "$count_file")"
        fi
        count=$((count + 1))
        printf '%s\\n' "$count" > "$count_file"

        if [ "$count" -eq 1 ]; then
          printf 'rate limit exceeded\\n' >&2
          exit 1
        fi

        printf '1138\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/1138\\n'
        """
    )


def _shell_command(kind: str) -> str:
    if kind == "zsh":
        return textwrap.dedent(
            """\
            source "$CMUX_TEST_SCRIPT"
            _cmux_send() { print -r -- "$1" >> "$CMUX_TEST_SEND_LOG"; }
            cd "$CMUX_TEST_REPO"
            _CMUX_PR_POLL_INTERVAL=1
            _cmux_precmd
            sleep 3
            _cmux_zshexit
            """
        )

    if kind == "bash":
        return textwrap.dedent(
            """\
            source "$CMUX_TEST_SCRIPT"
            _cmux_send() { printf '%s\\n' "$1" >> "$CMUX_TEST_SEND_LOG"; }
            cd "$CMUX_TEST_REPO"
            _CMUX_PR_POLL_INTERVAL=1
            _cmux_prompt_command
            sleep 3
            type _cmux_bash_cleanup >/dev/null 2>&1 && _cmux_bash_cleanup
            """
        )

    raise ValueError(f"Unsupported shell kind: {kind}")


def _run_case(base: Path, *, shell: str, shell_args: list[str], script: Path) -> tuple[int, str]:
    bindir = base / "bin"
    repo = base / "repo"
    repo_git = repo / ".git"
    socket_path = base / "cmux.sock"
    send_log = base / f"{shell}-send.log"
    gh_count_file = base / f"{shell}-gh-count.txt"

    bindir.mkdir(parents=True, exist_ok=True)
    repo_git.mkdir(parents=True, exist_ok=True)
    (repo_git / "HEAD").write_text("ref: refs/heads/feature/issue-1138\n", encoding="utf-8")
    _write_executable(bindir / "git", _git_stub())
    _write_executable(bindir / "gh", _gh_stub())

    env = dict(os.environ)
    env["PATH"] = f"{bindir}:{env.get('PATH', '')}"
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_TAB_ID"] = "00000000-0000-0000-0000-000000000001"
    env["CMUX_PANEL_ID"] = "00000000-0000-0000-0000-000000000002"
    env["CMUX_TEST_SCRIPT"] = str(script)
    env["CMUX_TEST_REPO"] = str(repo)
    env["CMUX_TEST_SEND_LOG"] = str(send_log)
    env["CMUX_TEST_GH_COUNT_FILE"] = str(gh_count_file)

    with BoundUnixSocket(socket_path):
        result = subprocess.run(
            [shell, *shell_args, _shell_command(shell)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        return (result.returncode, output)

    send_lines = []
    if send_log.exists():
        send_lines = [line.strip() for line in send_log.read_text(encoding="utf-8").splitlines() if line.strip()]

    gh_count = 0
    if gh_count_file.exists():
        gh_count = int(gh_count_file.read_text(encoding="utf-8").strip() or "0")

    report_line = (
        "report_pr 1138 https://github.com/manaflow-ai/cmux/pull/1138 "
        "--state=open --tab=00000000-0000-0000-0000-000000000001 "
        "--panel=00000000-0000-0000-0000-000000000002"
    )
    if gh_count < 2:
        return (1, f"{shell}: expected at least 2 gh probes while idle, saw {gh_count}")
    if any(line.startswith("clear_pr ") for line in send_lines):
        return (1, f"{shell}: transient gh failure should not send clear_pr\n" + "\n".join(send_lines))
    if report_line not in send_lines:
        return (1, f"{shell}: expected recovered report_pr payload\n" + "\n".join(send_lines))

    return (0, f"{shell}: ok")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    cases = [
        ("zsh", ["-f", "-c"], root / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"),
        ("bash", ["--noprofile", "--norc", "-c"], root / "Resources" / "shell-integration" / "cmux-bash-integration.bash"),
    ]

    base = Path("/tmp") / f"cmux_issue_1138_pr_poll_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        failures: list[str] = []
        for shell, shell_args, script in cases:
            if not script.exists():
                print(f"SKIP: missing integration script at {script}")
                continue
            rc, detail = _run_case(base / shell, shell=shell, shell_args=shell_args, script=script)
            if rc != 0:
                failures.append(detail)

        if failures:
            print("FAIL:")
            for failure in failures:
                print(failure)
            return 1

        print("PASS: shell integrations keep polling PR state and recover after transient gh failures")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
