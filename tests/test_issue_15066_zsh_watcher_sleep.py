#!/usr/bin/env python3
"""Regression coverage for the fork-free zsh watcher waits (issue #15066).

The test exercises the shipped zsh integration through real shell processes:

* zsh/zselect waits must not invoke an external ``sleep`` executable;
* disabling zsh/zselect must retain the working sleep fallback;
* the PR and git HEAD watcher loops must use the helper, and stopping the PR
  loop must tear down its process group while a zselect wait is active.

The socket, repository, and fake sleep executable are all private fixtures;
no running cmux instance or network access is involved.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"


def run_zsh(command: str, *, env: dict[str, str], cwd: Path | None = None, timeout: float = 10.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/zsh", "-f", "-c", command, "cmux-test", str(SCRIPT)],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def assert_ok(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        raise AssertionError(
            f"{label} failed with {result.returncode}:\nstdout={result.stdout}\nstderr={result.stderr}"
        )


def make_fake_sleep(directory: Path, log: Path) -> None:
    fake = directory / "sleep"
    fake.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$*\" >> {log}\n"
        "exec /bin/sleep \"$@\"\n",
        encoding="utf-8",
    )
    fake.chmod(0o755)


def base_env(fake_bin: Path) -> dict[str, str]:
    env = dict(os.environ)
    env.update(
        {
            "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "TZ": "UTC",
            "TERM": "dumb",
        }
    )
    return env


def test_syntax_and_zselect_sleep(tmp: Path, env: dict[str, str], log: Path) -> None:
    syntax = subprocess.run(
        ["/bin/zsh", "-n", str(SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert_ok(syntax, "zsh syntax")

    started = time.monotonic()
    result = run_zsh(
        "source \"$1\"; (( _CMUX_HAS_ZSELECT )) || { print -r -- SKIP; exit 0; }; "
        "_cmux_sleep_cs 20; print -r -- ZSELECT_OK",
        env=env,
    )
    elapsed = time.monotonic() - started
    assert_ok(result, "zselect sleep")
    if "SKIP" not in result.stdout and "ZSELECT_OK" not in result.stdout:
        raise AssertionError(f"zselect sleep produced no completion marker: {result.stdout!r}")
    if "SKIP" not in result.stdout and not 0.1 <= elapsed <= 2.0:
        raise AssertionError(f"zselect 20cs wait took an unexpected {elapsed:.3f}s")
    if "SKIP" not in result.stdout and log.exists() and log.read_text(encoding="utf-8").strip():
        raise AssertionError("zselect sleep invoked an external sleep executable")


def test_fallback_sleep(tmp: Path, fake_bin: Path, log: Path) -> None:
    env = base_env(fake_bin)
    result = run_zsh(
        # The function override models a zsh build without zsh/zselect before
        # the integration is sourced, so the production capability probe takes
        # its documented fallback branch.
        "zmodload() { return 1; }; source \"$1\"; (( !_CMUX_HAS_ZSELECT )) || exit 2; "
        "_cmux_sleep_cs 20; print -r -- FALLBACK_OK",
        env=env,
    )
    assert_ok(result, "zselect fallback")
    if "FALLBACK_OK" not in result.stdout:
        raise AssertionError(f"fallback sleep did not complete: {result.stdout!r}")
    calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    if len(calls) != 1 or abs(float(calls[0]) - 0.2) > 1e-9:
        raise AssertionError(f"fallback should launch sleep once for 20cs, got {calls!r}")


def watcher_fixture(tmp: Path, fake_bin: Path, log: Path) -> tuple[dict[str, str], socket.socket, Path]:
    sock_path = tmp / "cmux.sock"
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(sock_path))
    server.listen(1)

    repo = tmp / "repo"
    (repo / ".git").mkdir(parents=True)
    (repo / ".git" / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")

    env = base_env(fake_bin)
    env.update(
        {
            "CMUX_SOCKET_PATH": str(sock_path),
            "CMUX_TAB_ID": "tab-15066",
            "CMUX_PANEL_ID": f"panel-15066-{os.getpid()}",
            "CMUX_NO_PR_WATCH": "",
            "CMUX_NO_GIT_WATCH": "",
            "_CMUX_WATCHER_IDENTITY_INTERVAL": "1",
        }
    )
    # The caller owns the socket and repository for the lifetime of the shell.
    return env, server, repo


def test_real_watchers_and_teardown(tmp: Path, fake_bin: Path, log: Path) -> None:
    env, server, repo = watcher_fixture(tmp, fake_bin, log)
    try:
        command = r'''
source "$1"
_cmux_run_pr_probe_with_timeout() { return 0; }
_cmux_report_git_branch_for_path() { return 0; }
_cmux_clear_pr_for_panel() { return 0; }
_cmux_pr_cache_clear() { return 0; }
_cmux_start_pr_poll_loop "$PWD" 1
_cmux_start_git_head_watch
print -r -- "WATCHERS:${_CMUX_PR_POLL_PID}:${_CMUX_GIT_HEAD_WATCH_PID}"
# zselect is the wait in this parent too, so the fixture never needs a real
# sleep executable while the two watcher children make their first pass.
zselect -t 150 || true
_cmux_stop_git_head_watch
_cmux_halt_pr_poll_loop
print -r -- "TEARDOWN:${_CMUX_PR_POLL_PID}:${_CMUX_GIT_HEAD_WATCH_PID}"
'''
        result = run_zsh(command, env=env, cwd=repo, timeout=8.0)
        assert_ok(result, "watcher loops")
        if "WATCHERS:" not in result.stdout or "TEARDOWN::" not in result.stdout:
            raise AssertionError(f"watcher fixture did not start and tear down cleanly: {result.stdout!r}")
        if log.exists() and log.read_text(encoding="utf-8").strip():
            raise AssertionError(
                "the PR and git HEAD watcher loops invoked external sleep despite zsh/zselect availability"
            )
    finally:
        server.close()


def main() -> int:
    if not SCRIPT.exists():
        print("SKIP: zsh integration resource not found")
        return 0
    if shutil.which("zsh") is None:
        print("SKIP: zsh is not installed")
        return 0

    tmp = Path(tempfile.mkdtemp(prefix="cmux_15066_"))
    fake_bin = tmp / "bin"
    fake_bin.mkdir()
    log = tmp / "sleep.log"
    make_fake_sleep(fake_bin, log)
    try:
        test_syntax_and_zselect_sleep(tmp, base_env(fake_bin), log)
        # Start fallback with a fresh log so exactly one call is attributable to
        # this branch, rather than to a previous fixture.
        log.unlink(missing_ok=True)
        test_fallback_sleep(tmp, fake_bin, log)
        log.unlink(missing_ok=True)
        test_real_watchers_and_teardown(tmp, fake_bin, log)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("PASS: zsh/zselect watcher waits, fallback, exact loop routing, and teardown")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
