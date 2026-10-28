#!/usr/bin/env python3
"""A directory name cannot inject escape sequences through the shell integration.

At startup the zsh, bash, fish and nushell integrations replay the saved
scrollback and then report the shell's directory and host in an OSC 1337
CurrentDir sequence (`_cmux_restore_scrollback_once`). The directory name comes
from the file system, so it is untrusted: a raw ESC or BEL byte in it ended the
report early and started a sequence of its own, such as an OSC 52 clipboard
write (Ghostty 1.4.0, 6eb24a0f0, "shell-integration: don't let directory names
inject escape sequences"). The report must carry the name without its control
bytes, and its backslashes as they are.

Runs the shipped integrations, no app: python3 -I tests/test_shell_restore_cwd_control_bytes.py
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid


INTEGRATION_DIR = Path(__file__).resolve().parents[1] / "Resources/shell-integration"

# A raw BEL ends the OSC early, the ESC ] 52 starts a clipboard write, and the
# literal backslash escapes would become the same bytes in a shell that expands
# escapes in the value it prints (zsh `print` without -r).
HOSTILE_NAME = "x\a\x1b]52;c;SGVsbG8=\a" + r"y\a\e]52;c;SGk=\a"
CLEAN_NAME = "x]52;c;SGVsbG8=" + r"y\a\e]52;c;SGk=\a"


class RestoreCwdControlBytes(unittest.TestCase):
    def run_shell(self, shell: str) -> bytes:
        with tempfile.TemporaryDirectory(prefix="cmux-cwd-ctl-", dir="/tmp") as tmp:
            root = Path(tmp)
            cwd = root / HOSTILE_NAME
            cwd.mkdir()
            replay = root / f"replay-{uuid.uuid4().hex}"
            replay.write_bytes(b"saved scrollback\r\n")
            env = {
                "HOME": tmp,
                "TMPDIR": tmp,
                "PATH": "/usr/bin:/bin",
                "TERM": "xterm-256color",
                "HOST": "host",
                "HOSTNAME": "host",
                "CMUX_SOCKET_PATH": str(root / "socket"),
                "CMUX_TAB_ID": str(uuid.uuid4()),
                "CMUX_PANEL_ID": str(uuid.uuid4()),
                "CMUX_NO_GIT_WATCH": "1",
                "CMUX_NO_PR_WATCH": "1",
                "CMUX_SHELL_INTEGRATION": "1",
                "CMUX_FISH_USER_CONFIG_ALREADY_LOADED": "1",
                "CMUX_RESTORE_SCROLLBACK_FILE": str(replay),
            }
            if shell == "fish":
                argv = [shutil.which("fish") or "fish", "--no-config", "-c",
                        f"source {INTEGRATION_DIR / 'fish/config.fish'}"]
            elif shell == "nu":
                argv = [shutil.which("nu") or "nu", "--no-config-file", "-c",
                        f"source {INTEGRATION_DIR / 'nushell/cmux-nushell-integration.nu'}"]
            else:
                script = INTEGRATION_DIR / f"cmux-{shell}-integration.{shell}"
                args = ["-f", "-c"] if shell == "zsh" else ["--noprofile", "--norc", "-c"]
                argv = [shutil.which(shell) or f"/bin/{shell}", *args, f'source "{script}"']
            result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertIn(b"saved scrollback", result.stdout)
            return result.stdout

    def assert_reports_clean_directory(self, output: bytes) -> None:
        # Exactly the three CurrentDir reports (replay start, replay end, the
        # directory), each framed by one ESC and one BEL, and nothing else.
        self.assertEqual(output.count(b"\x1b]1337;CurrentDir=kitty-shell-cwd://"), 3, output)
        self.assertEqual(output.count(b"\x1b]"), 3, output)
        self.assertEqual(output.count(b"\a"), 3, output)
        self.assertNotIn(b"\x1b]52;", output)
        last = output[output.rindex(b"\x1b]1337;"):]
        self.assertTrue(last.endswith(b"\a"), last)
        self.assertTrue(last[:-1].endswith(("/" + CLEAN_NAME).encode()), last)

    def test_zsh(self) -> None:
        self.assert_reports_clean_directory(self.run_shell("zsh"))

    def test_bash(self) -> None:
        self.assert_reports_clean_directory(self.run_shell("bash"))

    @unittest.skipUnless(shutil.which("fish") or os.environ.get("GITHUB_ACTIONS") == "true",
                         "fish is not installed")
    def test_fish(self) -> None:
        self.assert_reports_clean_directory(self.run_shell("fish"))

    @unittest.skipUnless(shutil.which("nu"), "nushell is not installed")
    def test_nushell(self) -> None:
        self.assert_reports_clean_directory(self.run_shell("nu"))


if __name__ == "__main__":
    unittest.main()
