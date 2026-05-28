#!/usr/bin/env python3
"""Regression test for https://github.com/manaflow-ai/cmux/issues/1565.

cmux's bash integration fires background helpers (TTY report, shell-state
report, port kick, CWD report, git-branch probe, PR-action hint) after every
prompt. Until the fix, these used `{ cmd; } >/dev/null 2>&1 & disown`. The
helpers complete in single-digit milliseconds, so the job often finishes
before `disown` runs. Bash records the completion in its job table and prints
`[N]+ Done ...` at the next prompt, producing a wall of notifications on
bash 5.3 (where PS0 uses the no-fork `${ ...; }` valsub form so the helpers
run directly in the interactive shell's job table).

The fix wraps each fire-and-forget call in `( cmd & )` (inner `&`). The new
process becomes a job in the throwaway subshell's job table, never in the
interactive shell's, so no notification is ever queued.

This test reproduces the failure with a PTY-driven interactive bash, real
Unix socket so the reporters are not guarded out, and a stubbed `_cmux_send`
that writes to a log. It asserts zero `[N] ... Done` lines after exercising
the prompt path several times.
"""

from __future__ import annotations

import os
import pty
import re
import select
import shlex
import shutil
import signal
import socket
import sys
import tempfile
import time
from pathlib import Path


PROMPT = "__CMUX_TEST_PROMPT__ "
JOB_DONE_RE = re.compile(r"^\[[0-9]+\][^\n\r]*\bDone\b", re.MULTILINE)


def _find_modern_bash() -> str | None:
    """Find a bash >= 5 binary. The Done-spam bug only reliably reproduces on
    bash 5.x because pre-5.3 PS0 forks a throwaway subshell that hides the
    leak, and Apple's system bash 3.2 predates several relevant changes."""
    candidates = [
        "/opt/homebrew/bin/bash",
        "/usr/local/bin/bash",
        shutil.which("bash"),
    ]
    for candidate in candidates:
        if not candidate:
            continue
        if not os.path.exists(candidate):
            continue
        try:
            import subprocess
            result = subprocess.run(
                [candidate, "-c", "echo $BASH_VERSION"],
                capture_output=True,
                text=True,
                timeout=3,
            )
        except Exception:
            continue
        version = result.stdout.strip()
        try:
            major = int(version.split(".", 1)[0])
        except (ValueError, IndexError):
            continue
        if major >= 5:
            return candidate
    return None


class InteractiveBash:
    def __init__(self, bash_path: str, env: dict[str, str]) -> None:
        self.bash_path = bash_path
        self.env = env
        self.pid: int | None = None
        self.fd: int | None = None
        self.output = bytearray()

    def __enter__(self) -> "InteractiveBash":
        pid, fd = pty.fork()
        if pid == 0:
            # If execvpe raises (e.g. resolved bash becomes non-executable
            # between probe and fork), the exception would unwind back into
            # the test harness inside the forked child and run framework
            # code as a duplicate process. Hard-exit instead.
            try:
                os.execvpe(
                    self.bash_path,
                    [self.bash_path, "--noprofile", "--norc", "-i"],
                    self.env,
                )
            except OSError:
                os._exit(127)
        self.pid = pid
        self.fd = fd
        # Drain bash's startup banner before installing the sentinel PS1.
        self._read_until(b"$", timeout=2)
        self.run(f"PS1='{PROMPT}'")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.fd is not None:
            try:
                os.write(self.fd, b"exit\n")
                self._read_until(b"exit", timeout=1)
            except OSError:
                pass
            try:
                os.close(self.fd)
            except OSError:
                pass
        if self.pid is not None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            # Reap the zombie so resources are returned promptly, especially
            # when many tests run in sequence under pytest.
            try:
                os.waitpid(self.pid, 0)
            except (ChildProcessError, OSError):
                pass

    def run(self, command: str, timeout: float = 5) -> None:
        if self.fd is None:
            raise RuntimeError("PTY is not open")
        self._drain()
        os.write(self.fd, command.encode("utf-8") + b"\n")
        chunk = self._read_until(PROMPT.encode("utf-8"), timeout=timeout)
        if PROMPT.encode("utf-8") not in chunk:
            raise AssertionError(
                f"timed out waiting for prompt after {command!r}\n\n"
                f"Captured output:\n{self.text}"
            )

    def _read_until(self, marker: bytes, *, timeout: float) -> bytes:
        if self.fd is None:
            raise RuntimeError("PTY is not open")
        deadline = time.time() + timeout
        captured = bytearray()
        while time.time() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.1)
            if self.fd not in ready:
                continue
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                break
            if not data:
                break
            captured.extend(data)
            self.output.extend(data)
            if marker in captured:
                break
        return bytes(captured)

    def _drain(self) -> None:
        if self.fd is None:
            raise RuntimeError("PTY is not open")
        while True:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if self.fd not in ready:
                return
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                return
            if not data:
                return
            self.output.extend(data)

    @property
    def text(self) -> str:
        return self.output.decode("utf-8", errors="replace")


def test_bash_integration_no_done_spam() -> None:
    bash_path = _find_modern_bash()
    if bash_path is None:
        msg = ("no bash >= 5 found; the Done-spam bug only reproduces "
               "on modern bash where the helpers fire from PROMPT_COMMAND "
               "and PS0 valsub.")
        # In CI we want a missing modern bash to be a loud configuration
        # failure, not a silent skip that would let a regression land.
        if os.environ.get("CI"):
            raise RuntimeError(f"CI requires bash >= 5: {msg}")
        print(f"SKIP: {msg}")
        return

    repo_root = Path(__file__).resolve().parents[1]
    integration_script = (
        repo_root / "Resources/shell-integration/cmux-bash-integration.bash"
    )
    assert integration_script.exists(), integration_script

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        socket_path = tmp_path / "cmux.sock"
        repo_path = tmp_path / "repo"
        send_log = tmp_path / "send.log"

        # Minimal git repo so the git-branch probe has something to report.
        (repo_path / ".git").mkdir(parents=True)
        (repo_path / ".git" / "HEAD").write_text(
            "ref: refs/heads/feature/done-spam\n", encoding="utf-8"
        )

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.bind(str(socket_path))
            sock.listen(1)

            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("CMUX")
            }
            env.update({
                "LC_ALL": "C",
                "LANG": "C",
                "TERM": "xterm-256color",
            })

            with InteractiveBash(bash_path, env) as bash:
                bash.run("set -m")  # explicit; default for interactive shells
                bash.run(f"source {shlex.quote(str(integration_script))}")
                # Stub the network write so we don't depend on ncat/socat/nc
                # being installed, and so timing matches a fast (file I/O)
                # path similar to a Unix-socket write.
                bash.run(
                    "_cmux_send() { printf '%s\\n' \"$1\" >> "
                    f"{shlex.quote(str(send_log))}"
                    "; }"
                )
                bash.run(f"export CMUX_SOCKET_PATH={shlex.quote(str(socket_path))}")
                bash.run("export CMUX_TAB_ID=tab-test")
                bash.run("export CMUX_PANEL_ID=panel-test")
                bash.run("_CMUX_TTY_NAME=ttys-test")
                bash.run(f"cd {shlex.quote(str(repo_path))}")

                # Each `run` call triggers PS0 (preexec) and PROMPT_COMMAND,
                # exercising the full reporter set.
                marker = "__CMUX_DONE_CHECK__"
                for _ in range(8):
                    bash.run("true")
                bash.run(f"echo {marker}")

                # Make sure the dispatch path actually fired. If the helpers
                # silently no-oped (e.g. an environment guard regression
                # short-circuited every reporter), the Done-line assertion
                # below would pass trivially. Greptile flagged this in PR
                # #4958 review; the check forces the test to fail loud if
                # _cmux_send is never reached.
                if not send_log.exists() or send_log.stat().st_size == 0:
                    raise AssertionError(
                        "expected at least one _cmux_send invocation but "
                        f"{send_log} is empty. The reporter dispatch path "
                        "appears to have been silently bypassed.\n\n"
                        f"Bash: {bash_path}\n\n"
                        f"Full PTY output:\n{bash.text}"
                    )

                done_lines = JOB_DONE_RE.findall(bash.text)
                if done_lines:
                    raise AssertionError(
                        "bash integration emitted job-completion "
                        f"notifications ({len(done_lines)} line(s)). "
                        "Issue: https://github.com/manaflow-ai/cmux/issues/1565\n\n"
                        f"Done lines:\n{chr(10).join(done_lines)}\n\n"
                        f"Bash: {bash_path}\n\n"
                        f"Full PTY output:\n{bash.text}"
                    )
        finally:
            sock.close()


if __name__ == "__main__":
    try:
        test_bash_integration_no_done_spam()
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
    print("OK")
