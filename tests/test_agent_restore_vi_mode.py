#!/usr/bin/env python3
"""Run cmux's startup-input delivery against real vi-normal-mode shell prompts.

CMUX_TEST_FISH can select an isolated fish binary. No app or socket is used.
"""
from __future__ import annotations

import os
import fcntl
import termios
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIFECYCLE = ROOT / "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Lifecycle"


class AgentRestoreViModeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="cmux-vi-restore-build-")
        cls.harness = Path(cls.build.name) / "restore-input"
        subprocess.run([
            "swiftc", "-enable-upcoming-feature", "InternalImportsByDefault", str(LIFECYCLE / "TerminalStartupInputGate.swift"),
            str(LIFECYCLE / "TerminalSurface+ShellReadiness.swift"),
            str(ROOT / "tests/fixtures/vi_restore/RestoreInputHarness.swift"),
            "-o", str(cls.harness),
        ], check=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def test_zsh_normal_mode(self):
        self.run_shell(shutil.which("zsh"), "zsh")

    def test_fish_normal_mode(self):
        self.run_shell(os.environ.get("CMUX_TEST_FISH") or shutil.which("fish"), "fish")

    def run_shell(self, executable, kind):
        if not executable:
            self.skipTest(f"{kind} is not installed")
        with tempfile.TemporaryDirectory(prefix="cmux-vi-restore-") as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "fish").mkdir()
            cli = root / "bin/cmux"
            cli.write_text('#!/bin/sh\nprintf "%s|%s|%s\\n" "$*" "$CMUX_TEST_INITIALIZED" "$PPID" >> "$CMUX_TEST_CALLS"\nprintf "COMMAND_DONE\\n"\n')
            cli.chmod(0o700)
            # fish 4.0 initializes bindings lazily. fish_user_key_bindings keeps
            # the requested initial mode when that initialization occurs.
            (root / "fish/config.fish").write_text(
                'fish_vi_key_bindings default\n'
                'function fish_user_key_bindings; fish_vi_key_bindings default; end\n'
                'set -gx CMUX_TEST_INITIALIZED yes\n'
                'printf "init\\n" >> "$CMUX_TEST_INIT_LOG"\n'
                'function fish_prompt; set -g fish_bind_mode default; printf "READY>"; end\n'
            )
            (root / ".zshrc").write_text(
                'bindkey -v\n'
                'function zle-line-init() { zle -K vicmd; }; zle -N zle-line-init\n'
                'export CMUX_TEST_INITIALIZED=yes\n'
                'printf "init\\n" >> "$CMUX_TEST_INIT_LOG"\n'
                'PROMPT="READY>"\n'
            )
            env = {
                "HOME": directory, "ZDOTDIR": directory,
                "XDG_CONFIG_HOME": directory, "TERM": "xterm-256color",
                "PATH": f"{root}/bin:/usr/bin:/bin", "LC_ALL": "en_US.UTF-8",
                "CMUX_TEST_CALLS": str(root / "calls"),
                "CMUX_TEST_INIT_LOG": str(root / "init"),
            }
            fd, slave = pty.openpty()
            child = subprocess.Popen(
                [executable, "-i"], stdin=slave, stdout=slave, stderr=slave,
                env=env, start_new_session=True,
                preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
            )
            os.close(slave)
            pid = child.pid
            try:
                self.read_prompt(fd)
                for session in ("restore-first", "restore-second"):
                    payload = subprocess.check_output([
                        str(self.harness), f" cmux restore claude {session}\n",
                    ])
                    os.write(fd, payload)
                    output = self.read_prompt(fd, command_completed=True)
                    self.assertTrue((root / "calls").exists(), repr(output))
                calls = (root / "calls").read_text().splitlines()
                self.assertEqual(calls, [
                    f"restore claude restore-first|yes|{pid}",
                    f"restore claude restore-second|yes|{pid}",
                ], "each restore must execute once in the original initialized shell")
                self.assertEqual((root / "init").read_text(), "init\n")
            finally:
                child.kill()
                os.close(fd)
                child.wait(timeout=30)

    def read_prompt(self, fd, command_completed=False):
        output = b""
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            prompt_output = output
            if command_completed:
                marker = output.find(b"COMMAND_DONE\r\n")
                prompt_output = output[marker + len(b"COMMAND_DONE\r\n"):] if marker >= 0 else b""
            if b"READY>" in prompt_output and b"\x1b[?2004h" in prompt_output:
                return output
            if select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
                try:
                    output += os.read(fd, 65536)
                except OSError:
                    break
        self.fail(f"interactive shell did not reach a paste-ready prompt: {output!r}")


if __name__ == "__main__":
    unittest.main()
