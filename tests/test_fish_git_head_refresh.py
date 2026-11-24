#!/usr/bin/env python3
"""
Regression test for #46004: the fish integration must re-report the pwd when
the git HEAD changes in the same directory, so the sidebar re-reads the branch.

Runs the bundled fish integration in real fish against a fake unix socket.
Prompts once, switches branch without changing directory, prompts again, and
asserts a second ``report_pwd`` reached the socket.

Skips loudly without ``fish`` locally; fails when ``CI`` is set.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = REPO_ROOT / "Resources/shell-integration/fish/config.fish"


def _find_fish() -> str | None:
    override = os.environ.get("CMUX_TEST_FISH_BIN")
    candidates = [
        override,
        shutil.which("fish"),
        "/opt/homebrew/bin/fish",
        "/usr/local/bin/fish",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


class FishGitHeadRefreshTests(unittest.TestCase):
    def test_branch_change_in_same_directory_reports_pwd_again(self) -> None:
        fish = _find_fish()
        if fish is None:
            if os.environ.get("CI"):
                self.fail("fish is required on CI for this test but was not found")
            self.skipTest("fish not found; install fish to run this test")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            git_env = {
                **os.environ,
                "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@t",
                "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@t",
            }
            subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "commit", "-q", "--allow-empty", "-m", "init"],
                check=True,
                env=git_env,
            )

            sock_path = root / "s.sock"
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(sock_path))
            server.listen(16)
            server.settimeout(0.2)
            received: list[str] = []
            stop = threading.Event()

            def serve() -> None:
                while not stop.is_set():
                    try:
                        conn, _ = server.accept()
                    except TimeoutError:
                        continue
                    except OSError:
                        return
                    with conn:
                        conn.settimeout(2)
                        data = b""
                        try:
                            while chunk := conn.recv(4096):
                                data += chunk
                        except TimeoutError:
                            pass
                    received.extend(
                        line.strip()
                        for line in data.decode(errors="replace").splitlines()
                        if line.strip()
                    )

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            env = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": str(root),
                "TERM": "xterm-256color",
                "CMUX_TAB_ID": "tab-46004",
                "CMUX_PANEL_ID": "panel-46004",
                "CMUX_SOCKET_PATH": str(sock_path),
                "CMUX_SHELL_INTEGRATION": "1",
                "CMUX_TEST_SYNC_SEND": "1",
                "CMUX_FISH_INTEGRATION_FILE": str(INTEGRATION),
                "XDG_CONFIG_HOME": str(root / "config"),
            }
            # First prompt on main, switch branch in the same directory, prompt again.
            # `emit fish_prompt` fires the integration's --on-event handler, as a real prompt does.
            script = (
                f"source {INTEGRATION}\n"
                "emit fish_prompt\n"
                "sleep 1\n"
                "git switch -q -c feature-46004\n"
                "emit fish_prompt\n"
            )
            try:
                subprocess.run(
                    [fish, "--no-config", "-c", script],
                    cwd=str(repo),
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                # report_pwd is sent in the background (`&`); give those sends time to land.
                time.sleep(1.5)
            finally:
                stop.set()
                thread.join(timeout=5)
                server.close()

            pwd_reports = [line for line in received if line.startswith("report_pwd")]
            self.assertEqual(
                len(pwd_reports),
                2,
                f"expected report_pwd on both prompts (branch change in same dir); got {received!r}",
            )


if __name__ == "__main__":
    unittest.main()
