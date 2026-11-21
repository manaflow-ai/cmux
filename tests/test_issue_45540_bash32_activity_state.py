#!/usr/bin/env python3
"""Regression coverage for https://github.com/manaflow-ai/cmux/issues/45540.

``_cmux_prompt_command`` reports the ``prompt`` shell activity state on every
Bash version, but the matching ``running`` report needs the ``PS0`` preexec
hook, which the integration installs only on Bash >= 4.4. On the macOS system
Bash 3.2 a tab therefore settles in ``promptIdle`` forever, and ⌘W closes a
tab running a command without confirmation because the app trusts the reported
idle state over Ghostty's own ``needsConfirmClose()``.

The integration must not report ``prompt`` on shells that cannot also report
``running``; the app then keeps the activity state unknown and falls back to
its own close confirmation.

Runs the real shipped integration under one Bash older than 4.4 and one Bash
4.4+ when both are resolvable (CI supplies ``CMUX_BASH_32_BIN`` and
``CMUX_BASH_NEW_BIN``; a macOS host provides ``/bin/bash`` 3.2 alongside a
newer Homebrew Bash), and skips when only a modern Bash is available.
"""

from __future__ import annotations

import os
import re
import shutil
import socket
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = REPO_ROOT / "Resources/shell-integration/cmux-bash-integration.bash"

_BASH_VERSION_RE = re.compile(r"\bversion\s+(\d+)\.(\d+)")


def _bash_version(bash_bin: Path) -> tuple[int, int]:
    result = subprocess.run(
        [str(bash_bin), "--version"], capture_output=True, text=True,
        timeout=8, check=False,
    )
    match = _BASH_VERSION_RE.search((result.stdout or "") + (result.stderr or ""))
    if result.returncode != 0 or match is None:
        raise AssertionError(
            f"could not determine Bash version for {bash_bin}: "
            f"exit={result.returncode}\n{result.stdout}\n{result.stderr}"
        )
    return (int(match.group(1)), int(match.group(2)))


def _bash_candidates() -> list[tuple[str, Path]]:
    """Resolve one pre-4.4 Bash and one 4.4+ Bash when both exist."""

    configured_legacy = os.environ.get("CMUX_BASH_32_BIN")
    configured_modern = os.environ.get("CMUX_BASH_NEW_BIN")
    if configured_legacy and configured_modern:
        legacy, modern = Path(configured_legacy), Path(configured_modern)
        if legacy.is_file() and modern.is_file():
            return [("old", legacy), ("modern", modern)]

    candidates: list[Path] = []
    for candidate in (
        Path("/bin/bash"),
        shutil.which("bash"),
        "/opt/homebrew/bin/bash",
        "/usr/local/bin/bash",
    ):
        if candidate:
            path = Path(candidate)
            if path.is_file() and path not in candidates:
                candidates.append(path)

    resolved: list[tuple[str, Path]] = []
    for path in candidates:
        major, minor = _bash_version(path)
        if major > 4 or (major == 4 and minor >= 4):
            if not any(kind == "modern" for kind, _ in resolved):
                resolved.append(("modern", path))
        else:
            if not any(kind == "old" for kind, _ in resolved):
                resolved.append(("old", path))
    return resolved


class Bash32ActivityStateContract(unittest.TestCase):
    """The prompt report must track the availability of the running report."""

    def run_prompt(self, bash_bin: Path) -> str:
        with tempfile.TemporaryDirectory(prefix="cmux-45540-", dir="/tmp") as tmp:
            directory = Path(tmp)
            repo = directory / "repo"
            (repo / ".git").mkdir(parents=True)
            (repo / ".git/HEAD").write_text("ref: refs/heads/main\n")
            log = directory / "messages"
            env = {
                "HOME": tmp,
                "TMPDIR": tmp,
                "PATH": "/usr/bin:/bin",
                "TERM": "xterm-256color",
                "CMUX_SOCKET_PATH": str(directory / "socket"),
                "CMUX_TAB_ID": str(uuid.uuid4()),
                "CMUX_PANEL_ID": str(uuid.uuid4()),
                "CMUX_TEST_SCRIPT": str(INTEGRATION),
                "CMUX_TEST_LOG": str(log),
                "CMUX_TEST_FORCE_KEYBOARD_RESET": "1",
                "CMUX_NO_GIT_WATCH": "1",
            }
            script = r'''
source "$CMUX_TEST_SCRIPT"
_cmux_send() { printf '%s\n' "$@" >> "$CMUX_TEST_LOG"; }
_cmux_send_bg() { _cmux_send "$@"; }
# Stop at the process-creation boundary even if a startup guard regresses.
_cmux_capture_shell_start_time() { _cmux_send WATCHER_START; return 1; }
# The history helper's regex is not the behavior under test here; stub it so
# the prompt path reaches the activity report on every Bash version.
_cmux_bash_history_command() { return 1; }
_CMUX_TTY_NAME=ttys-contract
_CMUX_PORTS_LAST_RUN=-100
_cmux_prompt_command
printf 'CONTRACT_FINISHED\n'
'''
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(env["CMUX_SOCKET_PATH"])
                result = subprocess.run(
                    [str(bash_bin), "--noprofile", "--norc", "-c", script],
                    cwd=repo, env=env, capture_output=True, text=True, timeout=15,
                )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CONTRACT_FINISHED", result.stdout)
            return log.read_text() if log.exists() else ""

    def test_prompt_report_follows_preexec_availability(self):
        candidates = _bash_candidates()
        kinds = dict(candidates)
        if "old" not in kinds:
            print("SKIP: no Bash older than 4.4 available for issue 45540")
            return
        old_output = self.run_prompt(kinds["old"])
        self.assertNotIn(
            "report_shell_state prompt", old_output,
            "pre-4.4 Bash must not settle the tab in promptIdle; the app "
            "falls back to its own close confirmation for an unknown state",
        )
        if "modern" in kinds:
            modern_output = self.run_prompt(kinds["modern"])
            self.assertIn("report_shell_state prompt", modern_output)


if __name__ == "__main__":
    unittest.main()
