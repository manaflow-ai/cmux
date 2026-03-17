#!/usr/bin/env python3
"""
Regression coverage for issue #1138.

Validates that shell integration:
1) keeps polling PR state while idle and recovers after a transient gh failure
2) resolves the current branch PR via `gh pr view` instead of repository-wide
   branch-name matching
3) clears stale PR state when the branch changes and the new probe fails
4) recovers when a gh probe wedges longer than the async timeout
5) keeps polling in bash after prompt-render helper commands run
6) tears down the timed-out gh probe instead of leaking it in the background
7) falls back to explicit branch lookup when implicit gh branch resolution fails
8) does not clear an existing PR badge on the first prompt while establishing
   the HEAD baseline
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
        count_file="${CMUX_TEST_GH_COUNT_FILE:?}"
        pid_file="${CMUX_TEST_GH_PID_FILE:-}"
        scenario="${CMUX_TEST_SCENARIO:?}"
        head_file="${CMUX_TEST_HEAD_FILE:?}"

        printf '%s\\n' "$*" >> "$args_log"

        count=0
        if [ -f "$count_file" ]; then
          count="$(cat "$count_file")"
        fi
        count=$((count + 1))
        printf '%s\\n' "$count" > "$count_file"

        if [ "$1" != "pr" ] || [ "$2" != "view" ]; then
          printf 'unexpected gh args: %s\\n' "$*" >&2
          exit 9
        fi

        requested_branch=""
        if [ $# -ge 3 ]; then
          case "$3" in
            --*)
              ;;
            *)
              requested_branch="$3"
              ;;
          esac
        fi

        branch=""
        if [ -f "$head_file" ]; then
          head_line="$(cat "$head_file")"
          case "$head_line" in
            ref:\ refs/heads/*)
              branch="${head_line#ref: refs/heads/}"
              ;;
          esac
        fi

        case "$scenario" in
          prompt_helper_idle)
            printf '1138\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/1138\\n'
            ;;
          initial_prompt_preserves_pr_badge)
            printf '1138\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/1138\\n'
            ;;
          transient_same_context)
            if [ "$count" -eq 1 ]; then
              printf 'rate limit exceeded\\n' >&2
              exit 1
            fi
            printf '1138\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/1138\\n'
            ;;
          branch_switch_clear)
            if [ "$branch" = "feature/old" ]; then
              printf '111\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/111\\n'
              exit 0
            fi
            if [ "$branch" = "feature/new" ]; then
              printf 'network unavailable\\n' >&2
              exit 1
            fi
            printf 'no pull requests found for branch "%s"\\n' "$branch" >&2
            exit 1
            ;;
          timeout_recovery)
            if [ "$count" -eq 1 ]; then
              if [ -n "$pid_file" ]; then
                printf '%s\\n' "$$" > "$pid_file"
              fi
              sleep "${CMUX_TEST_HANG_SECONDS:-4}"
              exit 0
            fi
            printf '1138\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/1138\\n'
            ;;
          explicit_branch_fallback)
            if [ -z "$requested_branch" ]; then
              printf 'no pull requests found for branch "%s"\\n' "$branch" >&2
              exit 1
            fi
            if [ "$requested_branch" = "$branch" ]; then
              printf '1138\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/1138\\n'
              exit 0
            fi
            printf 'unexpected branch lookup: %s\\n' "$requested_branch" >&2
            exit 8
            ;;
          *)
            printf 'unknown scenario: %s\\n' "$scenario" >&2
            exit 2
            ;;
        esac
        """
    )


def _shell_command(kind: str, scenario: str) -> str:
    shared = {
        "prompt_helper_idle": (
            'cd "$CMUX_TEST_REPO"\n'
            '_CMUX_PR_POLL_INTERVAL=1\n'
            '_cmux_prompt_entry\n'
            ': "$(/bin/printf helper)"\n'
            'sleep 3\n'
            '_cmux_cleanup\n'
        ),
        "transient_same_context": (
            'cd "$CMUX_TEST_REPO"\n'
            '_CMUX_PR_POLL_INTERVAL=1\n'
            '_cmux_prompt_entry\n'
            'sleep 3\n'
            '_cmux_cleanup\n'
        ),
        "branch_switch_clear": (
            'cd "$CMUX_TEST_REPO"\n'
            '_CMUX_PR_POLL_INTERVAL=10\n'
            '_cmux_prompt_entry\n'
            'sleep 1\n'
            'printf \'ref: refs/heads/feature/new\\n\' > "$CMUX_TEST_HEAD_FILE"\n'
            '_cmux_prompt_entry\n'
            'sleep 2\n'
            '_cmux_cleanup\n'
        ),
        "timeout_recovery": (
            'cd "$CMUX_TEST_REPO"\n'
            '_CMUX_PR_POLL_INTERVAL=1\n'
            '_CMUX_ASYNC_JOB_TIMEOUT=1\n'
            '_cmux_prompt_entry\n'
            'sleep 4\n'
            '_cmux_cleanup\n'
        ),
        "explicit_branch_fallback": (
            'cd "$CMUX_TEST_REPO"\n'
            '_CMUX_PR_POLL_INTERVAL=10\n'
            '_cmux_prompt_entry\n'
            'sleep 2\n'
            '_cmux_cleanup\n'
        ),
        "initial_prompt_preserves_pr_badge": (
            'cd "$CMUX_TEST_REPO"\n'
            '_CMUX_PR_POLL_INTERVAL=10\n'
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
            _cmux_cleanup() {{ _cmux_zshexit; }}
            {shared}"""
        )

    if kind == "bash":
        return textwrap.dedent(
            f"""\
            source "$CMUX_TEST_SCRIPT"
            _cmux_send() {{ printf '%s\\n' "$1" >> "$CMUX_TEST_SEND_LOG"; }}
            _cmux_prompt_entry() {{ _cmux_prompt_command; }}
            _cmux_cleanup() {{ type _cmux_bash_cleanup >/dev/null 2>&1 && _cmux_bash_cleanup; }}
            {shared}"""
        )

    raise ValueError(f"Unsupported shell kind: {kind}")


def _read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _report_line(number: int) -> str:
    return (
        f"report_pr {number} https://github.com/manaflow-ai/cmux/pull/{number} "
        "--state=open --tab=00000000-0000-0000-0000-000000000001 "
        "--panel=00000000-0000-0000-0000-000000000002"
    )


def _pid_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _run_case(base: Path, *, shell: str, shell_args: list[str], script: Path, scenario: str) -> tuple[int, str]:
    bindir = base / "bin"
    repo = base / "repo"
    repo_git = repo / ".git"
    socket_path = base / "cmux.sock"
    send_log = base / f"{shell}-{scenario}-send.log"
    gh_count_file = base / f"{shell}-{scenario}-gh-count.txt"
    gh_args_log = base / f"{shell}-{scenario}-gh-args.log"
    gh_pid_file = base / f"{shell}-{scenario}-gh-pid.txt"
    head_file = repo_git / "HEAD"

    bindir.mkdir(parents=True, exist_ok=True)
    repo_git.mkdir(parents=True, exist_ok=True)
    initial_branch = "feature/old" if scenario == "branch_switch_clear" else "feature/issue-1138"
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
    env["CMUX_TEST_GH_COUNT_FILE"] = str(gh_count_file)
    env["CMUX_TEST_GH_ARGS_LOG"] = str(gh_args_log)
    env["CMUX_TEST_GH_PID_FILE"] = str(gh_pid_file)
    env["CMUX_TEST_SCENARIO"] = scenario
    env["CMUX_TEST_HEAD_FILE"] = str(head_file)
    env["CMUX_TEST_HANG_SECONDS"] = "4"

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
    gh_count = int((gh_count_file.read_text(encoding="utf-8").strip() or "0")) if gh_count_file.exists() else 0

    if not gh_args_lines:
        return (1, f"{shell}/{scenario}: expected at least one gh invocation")
    if any(not line.startswith("pr view ") for line in gh_args_lines):
        return (1, f"{shell}/{scenario}: expected gh pr view only\n" + "\n".join(gh_args_lines))

    if scenario == "prompt_helper_idle":
        if gh_count < 2:
            return (1, f"{shell}/{scenario}: expected idle polling to survive prompt helpers, saw {gh_count}")
        if _report_line(1138) not in send_lines:
            return (1, f"{shell}/{scenario}: missing report_pr payload\n" + "\n".join(send_lines))
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "transient_same_context":
        if gh_count < 2:
            return (1, f"{shell}/{scenario}: expected at least 2 gh probes while idle, saw {gh_count}")
        if any(line.startswith("clear_pr ") for line in send_lines):
            return (1, f"{shell}/{scenario}: transient failure should not clear PR state\n" + "\n".join(send_lines))
        if _report_line(1138) not in send_lines:
            return (1, f"{shell}/{scenario}: expected recovered report_pr payload\n" + "\n".join(send_lines))
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "branch_switch_clear":
        old_report = _report_line(111)
        if old_report not in send_lines:
            return (1, f"{shell}/{scenario}: missing old-branch report\n" + "\n".join(send_lines))
        try:
            old_index = send_lines.index(old_report)
        except ValueError:
            return (1, f"{shell}/{scenario}: missing old-branch report\n" + "\n".join(send_lines))
        clear_indices = [idx for idx, line in enumerate(send_lines) if line.startswith("clear_pr ")]
        if not clear_indices:
            return (1, f"{shell}/{scenario}: expected clear_pr after branch change\n" + "\n".join(send_lines))
        if clear_indices[0] <= old_index:
            return (1, f"{shell}/{scenario}: clear_pr happened before old report\n" + "\n".join(send_lines))
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "timeout_recovery":
        if gh_count < 2:
            return (1, f"{shell}/{scenario}: expected timed-out probe to be retried, saw {gh_count}")
        if _report_line(1138) not in send_lines:
            return (1, f"{shell}/{scenario}: missing report_pr after timeout recovery\n" + "\n".join(send_lines))
        if gh_pid_file.exists():
            gh_pid = int(gh_pid_file.read_text(encoding="utf-8").strip() or "0")
            if gh_pid > 0 and _pid_exists(gh_pid):
                return (1, f"{shell}/{scenario}: timed-out gh probe still running as pid {gh_pid}")
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "explicit_branch_fallback":
        if _report_line(1138) not in send_lines:
            return (1, f"{shell}/{scenario}: missing report_pr payload\n" + "\n".join(send_lines))
        if not any(line.startswith("pr view feature/issue-1138 ") for line in gh_args_lines):
            return (
                1,
                f"{shell}/{scenario}: expected explicit branch fallback\n" + "\n".join(gh_args_lines),
            )
        return (0, f"{shell}/{scenario}: ok")

    if scenario == "initial_prompt_preserves_pr_badge":
        if _report_line(1138) not in send_lines:
            return (1, f"{shell}/{scenario}: missing report_pr payload\n" + "\n".join(send_lines))
        if any(line.startswith("clear_pr ") for line in send_lines):
            return (
                1,
                f"{shell}/{scenario}: initial prompt should not clear an existing PR badge\n"
                + "\n".join(send_lines),
            )
        return (0, f"{shell}/{scenario}: ok")

    return (1, f"{shell}/{scenario}: unhandled scenario")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    cases = [
        ("zsh", ["-f", "-c"], root / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"),
        ("bash", ["--noprofile", "--norc", "-c"], root / "Resources" / "shell-integration" / "cmux-bash-integration.bash"),
    ]
    scenarios = [
        "prompt_helper_idle",
        "transient_same_context",
        "branch_switch_clear",
        "timeout_recovery",
        "explicit_branch_fallback",
        "initial_prompt_preserves_pr_badge",
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

        print("PASS: shell integrations poll PR state robustly across transient failures, branch changes, and timeouts")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
