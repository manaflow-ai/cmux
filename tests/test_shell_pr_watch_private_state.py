#!/usr/bin/env python3
"""Regression: the zsh PR watcher keeps its files out of the shared /tmp.

Any local account can create names in /tmp. The watcher used to write its
per-panel cache, force-probe signal and debug log at fixed /tmp names with
shell redirections, which write through a symlink someone else planted there.
It must keep those files in a directory only this user can write.

Uses the shipped integration with an isolated TMPDIR. Message delivery and
`gh` are replaced; no app, network or long-lived watcher is involved.
"""

from __future__ import annotations

import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import unittest
import uuid


ZSH_INTEGRATION = Path(__file__).resolve().parents[1] / "Resources/shell-integration/cmux-zsh-integration.zsh"
CACHE_SUFFIXES = ("branch", "repo", "result", "timestamp", "no-pr-branch")
ORIGINAL = "original\n"


class PRWatchPrivateStateContract(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory(prefix="cmux-pr-state-")
        self.directory = Path(self._temp.name)
        self.addCleanup(self._temp.cleanup)
        self.tmpdir = self.directory / "tmp"
        self.tmpdir.mkdir()
        self.repo = self.directory / "repo"
        (self.repo / ".git").mkdir(parents=True)
        (self.repo / ".git/HEAD").write_text("ref: refs/heads/contract-branch\n")
        self.victim = self.directory / "victim.txt"
        self.victim.write_text(ORIGINAL)
        self.panel = str(uuid.uuid4())
        self.socket_path = self.directory / "cmux.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self.socket_path))
        self.addCleanup(listener.close)

    def plant_symlink(self, path: Path, target: Path) -> None:
        if os.path.lexists(path):
            self.skipTest(f"{path} already exists on this machine")
        path.symlink_to(target)
        self.addCleanup(path.unlink, missing_ok=True)

    def run_zsh(self, body: str, tmpdir: Path | None = None) -> str:
        env = {
            "HOME": str(self.directory),
            "TMPDIR": str(tmpdir or self.tmpdir),
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            "CMUX_SOCKET_PATH": str(self.socket_path),
            "CMUX_TAB_ID": str(uuid.uuid4()),
            "CMUX_PANEL_ID": self.panel,
            "CMUX_TEST_SCRIPT": str(ZSH_INTEGRATION),
        }
        script = r'''
source "$CMUX_TEST_SCRIPT"
_cmux_send() { :; }
_cmux_send_bg() { :; }
gh() { return 0; }
# Keep shell-exit cleanup from removing the files this contract inspects.
add-zsh-hook -d zshexit _cmux_zshexit
''' + body
        result = subprocess.run(
            ["/bin/zsh", "-f", "-c", script], cwd=self.repo, env=env,
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def assert_private_directory(self, path: Path) -> None:
        info = os.lstat(path)
        self.assertTrue(stat.S_ISDIR(info.st_mode), f"{path} is not a directory")
        self.assertEqual(info.st_uid, os.geteuid())
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o700)

    def test_probe_request_writes_no_file_in_shared_tmp(self):
        self.plant_symlink(Path(f"/tmp/cmux-pr-force-{self.panel}"), self.victim)

        # One function call: the preexec hook clears the signal before the
        # next top-level command.
        output = self.run_zsh(r'''
_test_probe() {
    _cmux_pr_request_probe
    print -r -- "SIGNAL=$(_cmux_pr_force_signal_path)"
}
_test_probe
''')

        self.assertEqual(self.victim.read_text(), ORIGINAL)
        signal = Path(output.split("SIGNAL=", 1)[1].strip())
        self.assertTrue(signal.is_file(), f"no force signal at {signal}")
        self.assert_private_directory(signal.parent)

    def test_cache_writes_no_file_in_shared_tmp(self):
        for suffix in CACHE_SUFFIXES:
            self.plant_symlink(Path(f"/tmp/cmux-pr-cache-{self.panel}.{suffix}"), self.victim)

        output = self.run_zsh(r'''
_cmux_report_pr_for_path "$PWD"
print -r -- "PREFIX=$(_cmux_pr_cache_prefix)"
''')

        self.assertEqual(self.victim.read_text(), ORIGINAL)
        prefix = output.split("PREFIX=", 1)[1].strip()
        cached = Path(f"{prefix}.no-pr-branch")
        self.assertEqual(cached.read_text(), "contract-branch\n")
        self.assert_private_directory(cached.parent)

    def test_debug_log_writes_no_file_in_shared_tmp(self):
        self.plant_symlink(Path("/tmp/cmux-pr-debug.log"), self.victim)

        self.run_zsh(r'''
_CMUX_PR_DEBUG=1
_cmux_pr_debug_log contract-branch cache-miss
''')

        self.assertEqual(self.victim.read_text(), ORIGINAL)

    def test_nonsticky_tmp_ancestor_does_not_host_state(self):
        self.tmpdir.chmod(0o777)
        self.run_zsh(r'''
_cmux_pr_request_probe
_cmux_report_pr_for_path "$PWD"
_CMUX_PR_DEBUG=1
_cmux_pr_debug_log contract-branch cache-miss
''')
        state = self.tmpdir / f"cmux-pr-{os.geteuid()}"
        self.assertTrue(not state.exists() or not any(state.iterdir()), state.exists() and list(state.iterdir()))

    def test_state_directory_replaced_by_a_symlink_is_not_used(self):
        elsewhere = self.directory / "elsewhere"
        elsewhere.mkdir()
        (self.tmpdir / f"cmux-pr-{os.geteuid()}").symlink_to(elsewhere)

        self.run_zsh(r'''
_cmux_pr_request_probe
_cmux_report_pr_for_path "$PWD"
_CMUX_PR_DEBUG=1
_cmux_pr_debug_log contract-branch cache-miss
''')

        self.assertEqual(list(elsewhere.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
