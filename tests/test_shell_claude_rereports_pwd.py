#!/usr/bin/env python3
"""The first prompt after a `claude` command re-reports the shell's $PWD.

While Claude runs, its hooks report the Claude session's directory for the pane
(`claude --worktree` moves it to another checkout). The shell sends report_pwd
only when $PWD differs from what it last sent, so without this a killed Claude,
or one launched as `(cd x && claude)`, would leave the pane on Claude's
directory. Uses the shipped integrations with message delivery replaced.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest
import uuid


INTEGRATION_DIR = Path(__file__).resolve().parents[1] / "Resources/shell-integration"

COMMON_BODY = r'''
_test_prompt
_test_prompt
_test_preexec 'ls -la'
_test_prompt
_test_preexec 'claude --worktree wt2'
_test_prompt
_test_preexec '(cd sub && claude)'
_test_prompt
_test_preexec 'npx claudette'
_test_prompt
'''

FISH_BODY = r'''
_test_prompt
_test_prompt
_test_preexec 'ls -la'
_test_prompt
_test_preexec 'claude --worktree wt2'
_test_prompt
_test_preexec '(cd sub && claude)'
_test_prompt
_test_preexec 'npx claudette'
_test_prompt
'''


class ClaudeRereportsPwd(unittest.TestCase):
    def run_shell(self, shell: str, body: str) -> list[str]:
        with tempfile.TemporaryDirectory(prefix="cmux-claude-pwd-", dir="/tmp") as tmp:
            directory = Path(tmp)
            log = directory / "messages"
            if shell == "fish":
                script_path = INTEGRATION_DIR / "fish/config.fish"
            else:
                script_path = INTEGRATION_DIR / f"cmux-{shell}-integration.{shell}"
            env = {
                "HOME": tmp,
                "TMPDIR": tmp,
                "PATH": "/usr/bin:/bin",
                "TERM": "xterm-256color",
                "CMUX_SOCKET_PATH": str(directory / "socket"),
                "CMUX_TAB_ID": str(uuid.uuid4()),
                "CMUX_PANEL_ID": str(uuid.uuid4()),
                "CMUX_NO_GIT_WATCH": "1",
                "CMUX_NO_PR_WATCH": "1",
                "CMUX_SHELL_INTEGRATION": "1",
                "CMUX_FISH_USER_CONFIG_ALREADY_LOADED": "1",
                "CMUX_TEST_SCRIPT": str(script_path),
                "CMUX_TEST_LOG": str(log),
            }
            if shell == "fish":
                fish = shutil.which("fish")
                assert fish is not None
                script = r'''
source "$CMUX_TEST_SCRIPT"
function _cmux_send
    printf '%s\n' $argv >> "$CMUX_TEST_LOG"
end
function _cmux_send_bg
    _cmux_send $argv
end
set -g _CMUX_TTY_NAME ttys-contract
set -g _CMUX_PORTS_LAST_RUN (date +%s)
function _test_prompt
    _cmux_prompt
end
function _test_preexec
    _cmux_preexec $argv[1]
end
''' + body
                argv = [fish, "-c", script]
            else:
                prompt = "_cmux_precmd" if shell == "zsh" else "_cmux_prompt_command"
                preexec = "_cmux_preexec" if shell == "zsh" else "_cmux_preexec_command"
                script = r'''
source "$CMUX_TEST_SCRIPT"
_cmux_send() { printf '%s\n' "$@" >> "$CMUX_TEST_LOG"; }
_cmux_send_bg() { _cmux_send "$@"; }
_cmux_capture_shell_start_time() { return 1; }
_CMUX_TTY_NAME=ttys-contract
_CMUX_PORTS_LAST_RUN=-100
'''
                script += f'_test_prompt() {{ {prompt}; }}\n'
                script += f'_test_preexec() {{ {preexec} "$1"; }}\n'
                script += body
                args = ["-f", "-c"] if shell == "zsh" else ["--noprofile", "--norc", "-c"]
                argv = [f"/bin/{shell}", *args, script]
            script_done = '\nprintf "CONTRACT_FINISHED\\n"\n'
            argv[-1] += script_done
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(env["CMUX_SOCKET_PATH"])
                result = subprocess.run(
                    argv, cwd=tmp, env=env, capture_output=True, text=True, timeout=15,
                )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CONTRACT_FINISHED", result.stdout, result.stderr)
            lines = log.read_text().splitlines() if log.exists() else []
            return [line for line in lines if line.startswith("report_pwd ")]

    def assert_rereports(self, reports: list[str]) -> None:
        # The first prompt, then once after each of the two claude commands;
        # repeated prompts, `ls` and `claudette` keep the dedupe.
        self.assertEqual(len(reports), 3, reports)
        self.assertEqual(len(set(reports)), 1, reports)

    def test_zsh(self) -> None:
        self.assert_rereports(self.run_shell("zsh", COMMON_BODY))

    def test_bash(self) -> None:
        self.assert_rereports(self.run_shell("bash", COMMON_BODY))

    def test_bash_subshell_preexec(self) -> None:
        # Before bash 5.3, PS0 runs preexec in a subshell that cannot clear
        # the prompt's dedupe directly.
        reports = self.run_shell("bash", r'''
_test_prompt
( _CMUX_IN_PREEXEC=1; _cmux_preexec_command 'claude' )
_test_prompt
_test_prompt
''')
        self.assertEqual(len(reports), 2, reports)

    @unittest.skipUnless(
        shutil.which("fish") or os.environ.get("GITHUB_ACTIONS") == "true",
        "fish is not installed",
    )
    def test_fish(self) -> None:
        self.assert_rereports(self.run_shell("fish", FISH_BODY))


if __name__ == "__main__":
    unittest.main()
