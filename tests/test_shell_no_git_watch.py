#!/usr/bin/env python3
"""Executable contract for the supported zsh/bash CMUX_NO_GIT_WATCH opt-out.

Uses the shipped integrations with an isolated HOME and socket. Only message
delivery and watcher parent-identity capture are replaced: no app, GitHub access,
or long-lived watcher is needed to check the public shell behavior.
"""

from __future__ import annotations

import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
import uuid


INTEGRATION_DIR = Path(__file__).resolve().parents[1] / "Resources/shell-integration"
SHELLS = ("zsh", "bash")
CACHE_SUFFIXES = ("branch", "repo", "result", "timestamp", "no-pr-branch")


class NoGitWatchContract(unittest.TestCase):
    def run_shell(self, shell: str, body: str, value: str | None = "1") -> str:
        with tempfile.TemporaryDirectory(prefix="cmux-no-git-", dir="/tmp") as tmp:
            directory = Path(tmp)
            repo = directory / "repo"
            (repo / ".git").mkdir(parents=True)
            (repo / ".git/HEAD").write_text("ref: refs/heads/contract-before\n")
            panel = str(uuid.uuid4())
            state = directory / f"cmux-pr-{os.geteuid()}"
            state.mkdir(mode=0o700)
            cache = state / f"cache-{panel}"
            force = state / f"force-{panel}"
            files = [Path(f"{cache}.{suffix}") for suffix in CACHE_SUFFIXES] + [force]
            env = {
                "HOME": tmp,
                "TMPDIR": tmp,
                "PATH": "/usr/bin:/bin",
                "TERM": "xterm-256color",
                "CMUX_SOCKET_PATH": str(directory / "socket"),
                "CMUX_TAB_ID": str(uuid.uuid4()),
                "CMUX_PANEL_ID": panel,
                "CMUX_TEST_SCRIPT": str(INTEGRATION_DIR / f"cmux-{shell}-integration.{shell if shell == 'zsh' else 'bash'}"),
                "CMUX_TEST_LOG": str(directory / "messages"),
                "CMUX_TEST_CACHE": str(cache),
                "CMUX_TEST_FORCE": str(force),
                "CMUX_TEST_FORCE_KEYBOARD_RESET": "1",
            }
            # Intentionally leave CMUX_NO_PR_WATCH unset: the documented single
            # variable must suffice, independent of the caller's environment.
            if value is not None:
                env["CMUX_NO_GIT_WATCH"] = value
            prompt = "_cmux_precmd" if shell == "zsh" else "_cmux_prompt_command"
            preexec = "_cmux_preexec" if shell == "zsh" else "_cmux_preexec_command"
            script = r'''
source "$CMUX_TEST_SCRIPT"
_cmux_send() { printf '%s\n' "$@" >> "$CMUX_TEST_LOG"; }
_cmux_send_bg() { _cmux_send "$@"; }
# Stop at the process-creation boundary even if a startup guard regresses.
_cmux_capture_shell_start_time() { _cmux_send WATCHER_START; return 1; }
_CMUX_TTY_NAME=ttys-contract
_CMUX_PORTS_LAST_RUN=-100
'''
            script += f'_test_prompt() {{ {prompt}; }}\n'
            script += f'_test_preexec() {{ {preexec} "$1"; }}\n'
            script += body
            # The marker is emitted before shell-exit cleanup, so an exit hook
            # cannot make a broken prompt-time cleanup assertion pass.
            script += '\nprintf "CONTRACT_FINISHED\\n"\n'
            args = ["-f", "-c"] if shell == "zsh" else ["--noprofile", "--norc", "-c"]
            try:
                for file in files:
                    file.write_text("stale\n")
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                    listener.bind(env["CMUX_SOCKET_PATH"])
                    result = subprocess.run(
                        [f"/bin/{shell}", *args, script], cwd=repo, env=env,
                        capture_output=True, text=True, timeout=15,
                    )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("CONTRACT_FINISHED", result.stdout)
                messages = Path(env["CMUX_TEST_LOG"])
                return result.stdout + (messages.read_text() if messages.exists() else "")
            finally:
                for file in files:
                    file.unlink(missing_ok=True)

    def test_disabled_prompt_command_and_head_change(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_shell(shell, r'''
_test_prompt
_test_preexec 'gh pr close 15068'
printf 'ref: refs/heads/contract-after\n' > .git/HEAD
_test_prompt
_cmux_report_git_branch_for_path "$PWD"
_cmux_clear_pr_for_panel
cd "$HOME"
_test_prompt
_cmux_report_git_branch_for_path "$PWD"
# Bash no longer writes PR caches (#15075) and leaves files from older
# integrations alone instead of checking for them at every prompt.
if [[ -n "${ZSH_VERSION:-}" ]]; then
    for file in "$CMUX_TEST_CACHE.branch" "$CMUX_TEST_CACHE.repo" \
        "$CMUX_TEST_CACHE.result" "$CMUX_TEST_CACHE.timestamp" \
        "$CMUX_TEST_CACHE.no-pr-branch" "$CMUX_TEST_FORCE"; do
        [[ -e "$file" ]] && _cmux_send CACHE_REMAINS
    done
fi
[[ -n "$_CMUX_GIT_ACTIVE_PWD_FILE" ]] && _cmux_send ACTIVE_PWD_CREATED
[[ -n "$_CMUX_GIT_JOB_PID" ]] && _cmux_send GIT_JOB_STARTED
[[ -n "$_CMUX_GIT_HEAD_PATH$_CMUX_GIT_HEAD_SIGNATURE" ]] && _cmux_send HEAD_TRACKED
[[ -n "$_CMUX_LAST_PR_ACTION$_CMUX_LAST_PR_TARGET" ]] && _cmux_send HINT_REMAINS
[[ -n "${_CMUX_PR_ACTION_HINT_FILE:-}" && -e "$_CMUX_PR_ACTION_HINT_FILE" ]] && _cmux_send HINT_FILE_REMAINS
''')
                for forbidden in (
                    "report_git_branch", "clear_git_branch", "report_pr ", "clear_pr",
                    "report_pr_action", "WATCHER_START", "CACHE_REMAINS",
                    "ACTIVE_PWD_CREATED", "GIT_JOB_STARTED", "HEAD_TRACKED",
                    "HINT_REMAINS", "HINT_FILE_REMAINS",
                ):
                    self.assertNotIn(forbidden, output)
                for preserved in (
                    "report_tty ttys-contract", "report_shell_state prompt",
                    "report_shell_state running", "report_pwd ",
                    "--reason=command", "--reason=refresh", "\x1b[>m\x1b[<8u",
                ):
                    self.assertIn(preserved, output)
                self.assertGreaterEqual(output.count("report_pwd "), 2)

    def test_watcher_startup_is_blocked(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_shell(shell, r'''
# Retained legacy helpers may be removed by #2924. When present, they must
# honor the opt-out even if a future caller reintroduces them.
if typeset -f _cmux_start_pr_poll_loop >/dev/null; then
    _cmux_start_pr_poll_loop "$PWD"
fi
if typeset -f _cmux_start_git_head_watch >/dev/null; then
    _cmux_start_git_head_watch
fi
''')
                self.assertNotIn("WATCHER_START", output)

    def test_only_literal_one_disables_branch_reports(self):
        for shell in SHELLS:
            for value in (None, "", "0", "true"):
                with self.subTest(shell=shell, value=value):
                    output = self.run_shell(shell, r'''
_cmux_report_git_branch_for_path "$PWD"
_cmux_clear_pr_for_panel
cd "$HOME"
_cmux_report_git_branch_for_path "$PWD"
''', value=value)
                    self.assertIn("report_git_branch contract-before --status=unknown", output)
                    self.assertIn("clear_git_branch ", output)
                    self.assertIn("clear_pr ", output)

    def test_unsetting_restores_reports(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_shell(shell, r'''
_test_prompt
unset CMUX_NO_GIT_WATCH
_test_preexec 'gh pr close 15068'
_test_prompt
_cmux_report_git_branch_for_path "$PWD"
''')
                self.assertIn("report_git_branch contract-before", output)
                self.assertIn("report_pr_action close ", output)
                self.assertIn('--target="15068"', output)

    def test_next_prompt_stops_tracked_jobs(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                # These are only our own disposable processes, each in a new
                # group so the PR-loop group kill cannot touch the test runner.
                jobs = {}
                try:
                    names = ["_CMUX_GIT_JOB_PID"]
                    if shell == "zsh":
                        # Bash has no HEAD watcher, and #15075 removed its PR poller.
                        names += ["_CMUX_PR_POLL_PID", "_CMUX_GIT_HEAD_WATCH_PID"]
                    for name in names:
                        jobs[name] = subprocess.Popen(["/bin/sleep", "60"], start_new_session=True)
                    # Observe only prompt-time shutdown. zsh's normal exit hook
                    # could otherwise stop these jobs after a broken prompt.
                    body = "add-zsh-hook -d zshexit _cmux_zshexit\n" if shell == "zsh" else ""
                    body += "\n".join(f"{name}={job.pid}" for name, job in jobs.items())
                    body += "\nexport CMUX_NO_GIT_WATCH=1\n"
                    if shell == "bash":
                        # Exercise the transport-unavailable path: prompt
                        # cleanup must stop tracked jobs after socket loss.
                        body += "rm -f \"$CMUX_SOCKET_PATH\"\n"
                    body += "_test_prompt\n"
                    self.run_shell(shell, body, value=None)
                    for name, job in jobs.items():
                        self.assertLess(job.wait(timeout=3), 0, f"{shell}: {name} was not stopped")
                finally:
                    for job in jobs.values():
                        if job.poll() is None:
                            job.kill()
                        job.wait()


if __name__ == "__main__":
    unittest.main()
