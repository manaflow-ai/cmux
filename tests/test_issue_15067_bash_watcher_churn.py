#!/usr/bin/env python3
"""Measure bash watcher launches separately from the normal prompt lifecycle.

The old PR poller has no production callers after #2585. Exercise it explicitly
to reproduce its launch cost, then require retirement to leave no sleeping jobs.
The normal-lifecycle case is a separate oracle: it already passed before removal.
All shells, sockets, and logs belong to this test, not to a running cmux app.
"""

from __future__ import annotations

from contextlib import ExitStack
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = ROOT / "Resources/shell-integration/cmux-bash-integration.bash"


def stop_shell(shell: subprocess.Popen) -> str:
    if shell.poll() is None:
        try:
            _, error = shell.communicate("stop\n", timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(shell.pid, signal.SIGKILL)
            _, error = shell.communicate(timeout=5)
        return error
    return ""


class BashWatcherChurnTests(unittest.TestCase):
    def measure(self, *, legacy: bool, panes: int) -> tuple[list[int], list[str]]:
        with tempfile.TemporaryDirectory(prefix="cmux15067-", dir="/tmp") as directory, ExitStack() as stack:
            root = Path(directory)
            bindir = root / "bin"
            bindir.mkdir()
            # Count each actual external sleep invocation; retain its real delay.
            (bindir / "sleep").write_text(
                '#!/bin/bash\nprintf "%s\\n" "$*" >> "$CMUX_TEST_SLEEP_LOG"\nexec /bin/sleep "$@"\n'
            )
            (bindir / "sleep").chmod(0o755)
            (bindir / "gh").write_text(
                '#!/bin/bash\nprintf "%s\\n" "$*" >> "$CMUX_TEST_GH_LOG"\nexit 1\n'
            )
            (bindir / "gh").chmod(0o755)
            server = stack.enter_context(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM))
            server.bind(str(root / "socket"))
            shells = []
            for pane in range(panes):
                home = root / str(pane)
                home.mkdir()
                (home / ".git").mkdir()
                (home / ".git/HEAD").write_text("ref: refs/heads/feature/old\n")
                env = {
                    "PATH": f"{bindir}:/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": str(home), "TMPDIR": str(home), "TERM": "dumb", "LC_ALL": "C",
                    "CMUX_SOCKET_PATH": str(root / "socket"),
                    "CMUX_TAB_ID": f"tab-15067-{os.getpid()}",
                    "CMUX_PANEL_ID": f"panel-15067-{os.getpid()}-{pane}",
                    "CMUX_TEST_INTEGRATION": str(INTEGRATION),
                    "CMUX_TEST_SLEEP_LOG": str(home / "sleeps"),
                    "CMUX_TEST_GH_LOG": str(home / "gh"),
                    "CMUX_TEST_SEND_LOG": str(home / "send"),
                }
                script = (
                    'set -m\ncd "$HOME"\nsource "$CMUX_TEST_INTEGRATION"\n'
                    '_cmux_send() { printf "%s\\n" "$1" >> "$CMUX_TEST_SEND_LOG"; }\n'
                    '_CMUX_TTY_NAME=test; _CMUX_TTY_REPORTED=1\n'
                    'trap \'if declare -F _cmux_halt_pr_poll_loop >/dev/null; then '
                    '_cmux_halt_pr_poll_loop; fi\' EXIT\n'
                    '_cmux_prompt_command\n'
                )
                if legacy:
                    # Isolate the timer from Darwin's identity provider and
                    # GitHub. The real identity guard is covered by #10926.
                    # This is an explicit legacy invocation, not a prompt path.
                    script += (
                        'if declare -F _cmux_start_pr_poll_loop >/dev/null; then '
                        '_cmux_capture_shell_start_time() { _CMUX_SHELL_START_TIME=1000000000; }; '
                        '_cmux_watcher_parent_alive() { kill -0 "$1"; }; '
                        '_cmux_run_pr_probe_with_timeout() { :; }; '
                        '_cmux_start_pr_poll_loop "$PWD" 1; fi\n'
                    )
                else:
                    script += (
                        'printf "ref: refs/heads/feature/new\\n" > .git/HEAD\n'
                        '_cmux_prompt_command\n'
                        '_cmux_preexec_command "gh pr merge 42"\n'
                        ':; _cmux_prompt_command\n'
                    )
                script += 'printf "READY\\n"\nIFS= read -r stop\n'
                shell = subprocess.Popen(
                    ["/bin/bash", "--noprofile", "--norc", "-c", script], env=env,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True, start_new_session=True,
                )
                stack.callback(stop_shell, shell)
                shells.append((shell, home))
                ready, _, _ = select.select([shell.stdout], [], [], 15)
                self.assertTrue(ready, "bash did not finish the prompt lifecycle")
                # Prompt hooks may write terminal protocol escapes before READY.
                self.assertIn("READY", shell.stdout.readline())

            # Observation window, not synchronization: measure recurring work
            # while Python waits, so the driver adds no shell sleep launches.
            time.sleep(2.2)
            for shell, _ in shells:
                error = stop_shell(shell)
                self.assertEqual(shell.returncode, 0)
                self.assertNotIn("command not found", error)
            counts = []
            sends = []
            for _, home in shells:
                path = home / "sleeps"
                counts.append(len(path.read_text().splitlines()) if path.exists() else 0)
                path = home / "gh"
                self.assertFalse(path.exists(), "bash must leave GitHub polling to the app")
                sends.append((home / "send").read_text())
            print(f"{'legacy' if legacy else 'prompt'}: panes={panes}, sleeps={counts}", flush=True)
            return counts, sends

    def test_retired_poller_cannot_spawn_recurring_sleeps(self) -> None:
        counts, _ = self.measure(legacy=True, panes=4)
        self.assertEqual(counts, [0] * 4, "obsolete per-pane PR pollers still launch sleep")

    def test_prompt_branch_and_pr_hints_without_watcher_launches(self) -> None:
        counts, sends = self.measure(legacy=False, panes=2)
        self.assertEqual(counts, [0, 0])
        for send in sends:
            self.assertIn("report_git_branch feature/new ", send)
            self.assertIn("clear_pr --tab=", send)
            self.assertIn("report_pr_action merge ", send)
            self.assertIn('--target="42"', send)


if __name__ == "__main__":
    unittest.main()
