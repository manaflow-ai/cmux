#!/usr/bin/env python3
"""Regression test for cmux/cmux#3428.

The bash shell integration in Resources/shell-integration/cmux-bash-integration.bash
backgrounds reporter calls. Before #3428 it used `{ cmd; } >/dev/null 2>&1 & disown`
which races SIGCHLD against `disown`: when the bg job (a fast `_cmux_send`
socket write) completes before `disown` runs, bash registers the completion
and prints `[N] Done ...` (or the localized equivalent, e.g. `[N] Fertig ...`)
at the next prompt. The fix replaces that with `( cmd & ) >/dev/null 2>&1` so
the job lives in the subshell's own job table and the interactive shell never
tracks it.

This test spawns an interactive bash via PTY, sources the integration,
exercises the five reporter sites in scope for #3428, and asserts no
`[N] Done` line is emitted by job-control.

Locale is forced to C so bash's job-control message is the English word "Done"
across CI runners regardless of the host locale.
"""

from __future__ import annotations

import errno
import os
import pty
import re
import select
import shlex
import shutil
import socket
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = ROOT / "Resources" / "shell-integration" / "cmux-bash-integration.bash"

# Strip ANSI CSI / OSC escape sequences before scanning for the "Done" pattern.
# Job-control output is plain text, but bash's own readline emits bracketed-paste
# and prompt-redraw escapes that we don't want to count as line breaks.
_ANSI_RE = re.compile(rb"\x1b\[[?]?[0-9;]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

# bash job-control "Done" line, e.g.:
#   [2]+  Done                       { _cmux_send "..."; } > /dev/null 2>&1
_DONE_LINE_RE = re.compile(r"^\[\d+\][+-]?\s+Done\b.*", re.MULTILINE)

# Bash driver script. Sourced via stdin into an interactive bash with a PTY.
# Sites in scope for #3428 (all in cmux-bash-integration.bash):
#   site 1: _cmux_report_tty_once               (line ~385)
#   site 2: _cmux_report_shell_activity_state   (line ~405)
#   site 3: _cmux_ports_kick                    (line ~421)
#   site 4: _cmux_emit_pr_command_hint          (line ~519)
#   site 5: CWD reporter inside _cmux_prompt_command (line ~1010)
# Site 6 (the git-branch probe at ~line 1067) also backgrounds a job, but its
# fix is intentionally different (it captures $!) and is OUT OF SCOPE for
# #3428. We mute it via the _CMUX_GIT_JOB_PID seed below so it doesn't pollute
# the assertion.
_DRIVER = r"""
PS1='> '
PS2='> '
unset PROMPT_COMMAND

export CMUX_TAB_ID=test-tab-3428
export CMUX_PANEL_ID=test-panel-3428
export CMUX_SOCKET_PATH=__SOCKET_PATH__

source __INTEGRATION__

_cmux_send()                    { :; }
_cmux_socket_is_unix()          { return 0; }
_cmux_has_port_scan_transport() { return 0; }
_cmux_report_tty_payload()      { printf 'report_tty test-tty\n'; }

_CMUX_GIT_JOB_PID=$$
_CMUX_GIT_JOB_STARTED_AT=0
_CMUX_GIT_LAST_PWD="$PWD"
_CMUX_TTY_REPORTED=0
_CMUX_SHELL_ACTIVITY_LAST=""
_CMUX_PORTS_LAST_RUN=0
_CMUX_PWD_LAST_PWD=/__never_seen__
_CMUX_LAST_PR_ACTION=create

_cmux_report_tty_once
_cmux_report_shell_activity_state running
_cmux_report_shell_activity_state idle
_cmux_ports_kick command
_cmux_emit_pr_command_hint

_CMUX_PWD_LAST_PWD=/__never_seen__
_cmux_prompt_command

sleep 0.5
echo __PROBE_END__
exit 0
"""


def _capture(bash_path: str) -> str:
    env = {
        "LC_ALL": "C",
        "LANG": "C",
        "LC_MESSAGES": "C",
        "TERM": "dumb",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", "/tmp"),
    }

    sock_dir = tempfile.mkdtemp(prefix="cmux-3428-")
    sock_path = os.path.join(sock_dir, "fake.sock")
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(sock_path)
    listener.listen(1)

    pid, fd = pty.fork()
    if pid == 0:
        try:
            listener.close()
            for key, value in env.items():
                os.environ[key] = value
            for stale in ("PROMPT_COMMAND", "BASH_ENV", "ENV"):
                os.environ.pop(stale, None)
            os.execvp(bash_path, [bash_path, "--noprofile", "--norc", "-i"])
        except Exception:
            os._exit(127)

    script = (
        _DRIVER
        .replace("__INTEGRATION__", shlex.quote(str(INTEGRATION)))
        .replace("__SOCKET_PATH__", shlex.quote(sock_path))
        .encode("utf-8")
    )
    output = bytearray()
    child_reaped = False
    try:
        os.write(fd, script)
        deadline = time.time() + 8.0
        while time.time() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.4)
            if not readable:
                try:
                    wait_pid, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    child_reaped = True
                    break
                if wait_pid == pid:
                    child_reaped = True
                    break
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
    finally:
        if not child_reaped:
            try:
                os.kill(pid, 15)
            except OSError:
                pass
            for _ in range(50):
                try:
                    wait_pid, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    child_reaped = True
                    break
                if wait_pid == pid:
                    child_reaped = True
                    break
                time.sleep(0.1)
            if not child_reaped:
                try:
                    os.kill(pid, 9)
                except OSError:
                    pass
                try:
                    os.waitpid(pid, 0)
                except (OSError, ChildProcessError):
                    pass
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            listener.close()
        except OSError:
            pass
        try:
            os.unlink(sock_path)
        except OSError:
            pass
        try:
            os.rmdir(sock_dir)
        except OSError:
            pass

    cleaned = _ANSI_RE.sub(b"", bytes(output)).decode("utf-8", errors="replace")
    return cleaned


def main() -> int:
    bash = shutil.which("bash") or "/bin/bash"
    if not Path(bash).exists():
        print("SKIP: bash not available")
        return 0
    if not INTEGRATION.exists():
        print(f"SKIP: integration script missing: {INTEGRATION}")
        return 0

    transcript = _capture(bash)

    # Sanity check: make sure the driver actually ran end-to-end.
    if "__PROBE_END__" not in transcript:
        print("FAIL: probe marker missing - bash session did not run the driver to completion")
        print("--- transcript ---")
        print(transcript)
        return 1

    matches = _DONE_LINE_RE.findall(transcript)
    if matches:
        print(
            f"FAIL: cmux-bash-integration.bash emitted "
            f"{len(matches)} job-control 'Done' line(s) (expected 0)"
        )
        print("Sample (first 5):")
        for line in matches[:5]:
            print(f"  {line}")
        print("--- transcript ---")
        print(transcript)
        return 1

    print(
        f"PASS: no '[N] Done' notifications observed across "
        f"{len(transcript.splitlines())} output lines"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
