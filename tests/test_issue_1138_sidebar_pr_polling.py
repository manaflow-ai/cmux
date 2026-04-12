#!/usr/bin/env python3
"""
Regression coverage for shell-side sidebar PR refresh hints.

Validates that shell integration:
1) no longer polls GitHub directly while idle at a prompt
2) emits PR action hints after successful `gh pr ...` commands
3) does not emit PR action hints after failed commands or non-PR `gh` commands
4) clears stale PR badges when the checked-out branch changes
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
        repo_path="$PWD"
        if [ "$1" = "-C" ]; then
          repo_path="$2"
          shift
          shift
        fi

        head_file="$repo_path/.git/HEAD"
        branch=""
        if [ -f "$head_file" ]; then
          head_line="$(cat "$head_file")"
          case "$head_line" in
            ref:\ refs/heads/*)
              branch="${head_line#ref: refs/heads/}"
              ;;
          esac
        fi

        if [ "$1" = "rev-parse" ] && [ "$2" = "--git-dir" ]; then
          printf '%s/.git\\n' "$repo_path"
          exit 0
        fi

        if [ "$1" = "branch" ] && [ "$2" = "--show-current" ]; then
          if [ -n "$branch" ]; then
            printf '%s\\n' "$branch"
          fi
          exit 0
        fi

        if [ "$1" = "remote" ] && [ "$2" = "get-url" ] && [ "$3" = "origin" ]; then
          printf 'https://github.com/manaflow-ai/cmux.git\\n'
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
        args_log="${CMUX_TEST_GH_ARGS_LOG:?}"
        printf '%s\\n' "$*" >> "$args_log"
        exit 0
        """
    )


def _shell_command(kind: str, scenario: str) -> str:
    shared = {
        "prompt_does_not_call_gh": (
            'cd "$CMUX_TEST_REPO"\n'
            '_cmux_prompt_entry\n'
            'sleep 1\n'
            '_cmux_cleanup\n'
        ),
        "merge_action": (
            'cd "$CMUX_TEST_REPO"\n'
            '_cmux_pr_command_entry "gh pr merge"\n'
            '_cmux_prompt_entry\n'
            'sleep 1\n'
            '_cmux_cleanup\n'
        ),
        "close_action_target": (
            'cd "$CMUX_TEST_REPO"\n'
            '_cmux_pr_command_entry "gh pr close 2580"\n'
            '_cmux_prompt_entry\n'
            'sleep 1\n'
            '_cmux_cleanup\n'
        ),
        "failed_merge_no_action": (
            'cd "$CMUX_TEST_REPO"\n'
            '_cmux_pr_command_entry "gh pr merge"\n'
            'false\n'
            '_cmux_prompt_entry\n'
            'sleep 1\n'
            '_cmux_cleanup\n'
        ),
        "non_pr_gh_no_action": (
            'cd "$CMUX_TEST_REPO"\n'
            '_cmux_pr_command_entry "gh issue view 1"\n'
            '_cmux_prompt_entry\n'
            'sleep 1\n'
            '_cmux_cleanup\n'
        ),
        "head_change_clears_pr": (
            'cd "$CMUX_TEST_REPO"\n'
            '_cmux_prompt_entry\n'
            'sleep 1\n'
            'printf \'ref: refs/heads/feature/new\\n\' > "$CMUX_TEST_HEAD_FILE"\n'
            '_cmux_prompt_entry\n'
            'sleep 2\n'
            '_cmux_cleanup\n'
        ),
    }[scenario]

    if kind == "zsh":
        return textwrap.dedent(
            f"""\
            source "$CMUX_TEST_SCRIPT"
            _cmux_send() {{ print -r -- "$1" >> "$CMUX_TEST_SEND_LOG"; }}
            _cmux_prompt_entry() {{ _cmux_precmd; }}
            _cmux_pr_command_entry() {{ _cmux_preexec "$1"; }}
            _cmux_cleanup() {{ _cmux_zshexit; }}
            {shared}"""
        )

    if kind == "bash":
        return textwrap.dedent(
            f"""\
            source "$CMUX_TEST_SCRIPT"
            _cmux_send() {{ printf '%s\\n' "$1" >> "$CMUX_TEST_SEND_LOG"; }}
            _cmux_prompt_entry() {{ _cmux_prompt_command; }}
            _cmux_pr_command_entry() {{ _cmux_bash_preexec_hook "$1"; }}
            _cmux_cleanup() {{ type _cmux_bash_cleanup >/dev/null 2>&1 && _cmux_bash_cleanup; }}
            {shared}"""
        )

    raise ValueError(f"Unsupported shell kind: {kind}")


def _read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _run_case(base: Path, *, shell: str, shell_args: list[str], script: Path, scenario: str) -> tuple[int, str]:
    bindir = base / "bin"
    repo = base / "repo"
    repo_git = repo / ".git"
    socket_path = base / "cmux.sock"
    send_log = base / f"{shell}-{scenario}-send.log"
    gh_args_log = base / f"{shell}-{scenario}-gh-args.log"
    head_file = repo_git / "HEAD"

    bindir.mkdir(parents=True, exist_ok=True)
    repo_git.mkdir(parents=True, exist_ok=True)
    initial_branch = "feature/old" if scenario == "head_change_clears_pr" else "feature/issue-1138"
    head_file.write_text(f"ref: refs/heads/{initial_branch}\n", encoding="utf-8")
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
    env["CMUX_TEST_GH_ARGS_LOG"] = str(gh_args_log)
    env["CMUX_TEST_HEAD_FILE"] = str(head_file)

    with BoundUnixSocket(socket_path):
        result = subprocess.run(
            [shell, *shell_args, _shell_command(shell, scenario)],
            env=env,
            capture_output=True,
            text=True,
            timeout=12,
        )

    combined_output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        return (result.returncode, combined_output)

    send_lines = _read_lines(send_log)
    gh_args_lines = _read_lines(gh_args_log)
    pr_action_lines = [line for line in send_lines if line.startswith("report_pr_action ")]

    if scenario == "prompt_does_not_call_gh":
        if gh_args_lines:
            return (1, f"{shell}/{scenario}: expected no gh invocations\n" + "\n".join(gh_args_lines))
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "merge_action":
        expected = "report_pr_action merge --tab=00000000-0000-0000-0000-000000000001 --panel=00000000-0000-0000-0000-000000000002"
        if expected not in pr_action_lines:
            return (1, f"{shell}/{scenario}: missing merge action hint\n" + "\n".join(send_lines))
        if gh_args_lines:
            return (1, f"{shell}/{scenario}: expected no gh invocations\n" + "\n".join(gh_args_lines))
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "close_action_target":
        expected = "report_pr_action close --tab=00000000-0000-0000-0000-000000000001 --panel=00000000-0000-0000-0000-000000000002 --target=\"2580\""
        if expected not in pr_action_lines:
            return (1, f"{shell}/{scenario}: missing close action hint\n" + "\n".join(send_lines))
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "failed_merge_no_action":
        if pr_action_lines:
            return (1, f"{shell}/{scenario}: failed command should not emit PR action hint\n" + "\n".join(send_lines))
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "non_pr_gh_no_action":
        if pr_action_lines:
            return (1, f"{shell}/{scenario}: non-PR gh command should not emit PR action hint\n" + "\n".join(send_lines))
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "head_change_clears_pr":
        expected = "clear_pr --tab=00000000-0000-0000-0000-000000000001 --panel=00000000-0000-0000-0000-000000000002"
        if expected not in send_lines:
            return (1, f"{shell}/{scenario}: missing clear_pr after HEAD change\n" + "\n".join(send_lines))
        if gh_args_lines:
            return (1, f"{shell}/{scenario}: expected no gh invocations\n" + "\n".join(gh_args_lines))
        return (0, f"{shell}/{scenario}: ok")

    return (1, f"{shell}/{scenario}: unhandled scenario")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    cases = [
        ("zsh", ["-f", "-c"], root / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"),
        ("bash", ["--noprofile", "--norc", "-c"], root / "Resources" / "shell-integration" / "cmux-bash-integration.bash"),
    ]
    scenarios = [
        "prompt_does_not_call_gh",
        "merge_action",
        "close_action_target",
        "failed_merge_no_action",
        "non_pr_gh_no_action",
        "head_change_clears_pr",
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
            for scenario in scenarios:
                rc, detail = _run_case(
                    base / f"{shell}-{scenario}",
                    shell=shell,
                    shell_args=shell_args,
                    script=script,
                    scenario=scenario,
                )
                if rc != 0:
                    failures.append(detail)

        if failures:
            print("FAIL:")
            for failure in failures:
                print(failure)
            return 1

        print("PASS: shell integrations emit PR action hints locally and no longer poll GitHub directly")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
