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
import pty
import select
import signal
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"


def run_zsh(
    command: str,
    *,
    env: dict[str, str],
    cwd: Path | None = None,
    timeout: float = 10.0,
    job_control: bool = False,
) -> subprocess.CompletedProcess[str]:
    argv = ["/bin/zsh", "-f", "-c", command, "cmux-test", str(SCRIPT)]
    if not job_control:
        return subprocess.run(
            argv,
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    pid, master_fd = pty.fork()
    if pid == 0:
        if cwd is not None:
            os.chdir(cwd)
        os.execve("/bin/zsh", ["/bin/zsh", "-f", "-i", "-c", command, "cmux-test", str(SCRIPT)], env)
        os._exit(127)

    os.set_blocking(master_fd, False)
    output = bytearray()
    status: int | None = None
    deadline = time.monotonic() + timeout
    try:
        while status is None:
            try:
                chunk = os.read(master_fd, 4096)
                if chunk:
                    output.extend(chunk)
            except BlockingIOError:
                pass
            except OSError:
                break
            waited_pid, status = os.waitpid(pid, os.WNOHANG)
            if waited_pid == 0:
                status = None
            if status is not None:
                break
            if time.monotonic() >= deadline:
                os.killpg(pid, signal.SIGKILL)
                _, status = os.waitpid(pid, 0)
                return subprocess.CompletedProcess(argv, 124, output.decode(errors="replace"), output.decode(errors="replace"))
            select.select([master_fd], [], [], 0.05)

        # Drain bytes already queued before the PTY reports EIO/EOF.
        while True:
            try:
                chunk = os.read(master_fd, 4096)
            except (BlockingIOError, OSError):
                break
            if not chunk:
                break
            output.extend(chunk)
    finally:
        os.close(master_fd)
    returncode = os.waitstatus_to_exitcode(status) if status is not None else 1
    text_output = output.decode(errors="replace")
    return subprocess.CompletedProcess(argv, returncode, text_output, text_output)


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
        "if [ -n \"$CMUX_FAKE_SLEEP_READY_DIR\" ]; then\n"
        ": > \"$CMUX_FAKE_SLEEP_READY_DIR/$PPID\"\n"
        "fi\n"
        "exec /bin/sleep \"$@\"\n",
        encoding="utf-8",
    )
    fake.chmod(0o755)


def base_env(fake_bin: Path) -> dict[str, str]:
    root = fake_bin.parent
    (root / "home").mkdir(exist_ok=True)
    (root / "tmp").mkdir(exist_ok=True)
    return {
        "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(root / "home"),
        "TMPDIR": str(root / "tmp"),
        "LC_ALL": "C",
        "TZ": "UTC",
        "TERM": "dumb",
    }


def test_syntax_and_zselect_sleep(env: dict[str, str], log: Path) -> bool:
    syntax = subprocess.run(
        ["/bin/zsh", "-n", str(SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert_ok(syntax, "zsh syntax")

    result = run_zsh(
        "source \"$1\"; (( _CMUX_HAS_ZSELECT )) || { print -r -- SKIP; exit 0; }; "
        "setopt ERR_RETURN ERR_EXIT; _cmux_sleep_cs 20; print -r -- ZSELECT_OK",
        env=env,
    )
    assert_ok(result, "zselect sleep")
    has_zselect = "SKIP" not in result.stdout
    if has_zselect and "ZSELECT_OK" not in result.stdout:
        raise AssertionError(f"zselect sleep produced no completion marker: {result.stdout!r}")
    if has_zselect and log.exists() and log.read_text(encoding="utf-8").strip():
        raise AssertionError("zselect sleep invoked an external sleep executable")
    return has_zselect


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
    ready_dir = tmp / "sleep-ready"
    ready_dir.mkdir(exist_ok=True)
    zselect_ready_file = tmp / "zselect-ready"
    zselect_ready_file.unlink(missing_ok=True)

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
            "CMUX_FAKE_SLEEP_READY_DIR": str(ready_dir),
            "CMUX_ZSELECT_READY_FILE": str(zselect_ready_file),
        }
    )
    # The caller owns the socket and repository for the lifetime of the shell.
    return env, server, repo


def test_real_watchers_and_teardown(
    tmp: Path, fake_bin: Path, log: Path, *, has_zselect: bool
) -> None:
    env, server, repo = watcher_fixture(tmp, fake_bin, log)
    if not has_zselect:
        env["CMUX_TEST_FORCE_NO_ZSELECT"] = "1"
    try:
        command = r'''
if [[ "$CMUX_TEST_FORCE_NO_ZSELECT" == 1 ]]; then
    zmodload() { return 1; }
fi
source "$1"
if (( _CMUX_HAS_ZSELECT )); then
    functions[_cmux_test_sleep_impl]=$functions[_cmux_sleep_cs]
    _cmux_sleep_cs() {
        print -r -- ready >> "$CMUX_ZSELECT_READY_FILE"
        _cmux_test_sleep_impl "$@"
    }
fi
_cmux_run_pr_probe_with_timeout() { return 0; }
_cmux_report_git_branch_for_path() { return 0; }
_cmux_clear_pr_for_panel() { return 0; }
_cmux_pr_cache_clear() { return 0; }
_cmux_start_pr_poll_loop "$PWD" 1
_cmux_start_git_head_watch
[[ "${_CMUX_PR_POLL_PID:-}" == <-> && "${_CMUX_GIT_HEAD_WATCH_PID:-}" == <-> ]] || {
    print -r -- "WATCHERS_MISSING:${_CMUX_PR_POLL_PID:-}:${_CMUX_GIT_HEAD_WATCH_PID:-}"
    exit 3
}
kill -0 "$_CMUX_PR_POLL_PID" || { print -r -- "PR_WATCHER_NOT_ALIVE"; exit 4; }
kill -0 "$_CMUX_GIT_HEAD_WATCH_PID" || { print -r -- "GIT_WATCHER_NOT_ALIVE"; exit 5; }
kill -0 -- -"$_CMUX_PR_POLL_PID" 2>/dev/null || { print -r -- "PR_WATCHER_GROUP_MISSING"; exit 8; }
print -r -- "WATCHERS:${_CMUX_PR_POLL_PID}:${_CMUX_GIT_HEAD_WATCH_PID}"
pr_pid="$_CMUX_PR_POLL_PID"
git_pid="$_CMUX_GIT_HEAD_WATCH_PID"
if (( _CMUX_HAS_ZSELECT )); then
    ready=0
    for (( attempt = 0; attempt < 80; attempt++ )); do
        ready_count="$(wc -l < "$CMUX_ZSELECT_READY_FILE" 2>/dev/null)"
        if (( ready_count >= 2 )); then
            ready=1
            break
        fi
        zselect -t 5 || true
    done
    (( ready )) || {
        print -r -- "ZSELECT_WATCHERS_NOT_READY:$pr_pid:$git_pid"
        exit 7
    }
else
    ready=0
    for (( attempt = 0; attempt < 80; attempt++ )); do
        if [[ -e "$CMUX_FAKE_SLEEP_READY_DIR/$pr_pid" && -e "$CMUX_FAKE_SLEEP_READY_DIR/$git_pid" ]]; then
            ready=1
            break
        fi
        _cmux_sleep_cs 5 || true
    done
    (( ready )) || {
        print -r -- "FALLBACK_WATCHERS_NOT_READY:$pr_pid:$git_pid"
        exit 7
    }
fi
_cmux_stop_git_head_watch
_cmux_halt_pr_poll_loop
pr_alive=1
git_alive=1
for (( attempt = 0; attempt < 40; attempt++ )); do
    kill -0 -- -"$pr_pid" 2>/dev/null || pr_alive=0
    kill -0 "$git_pid" 2>/dev/null || git_alive=0
    (( !pr_alive && !git_alive )) && break
    if (( _CMUX_HAS_ZSELECT )); then
        zselect -t 5 || true
    else
        _cmux_sleep_cs 5 || true
    fi
done
(( !pr_alive && !git_alive )) || {
    print -r -- "TEARDOWN_LEAK:"$pr_pid":"$git_pid":"$pr_alive":"$git_alive
    exit 6
}
print -r -- "TEARDOWN:${_CMUX_PR_POLL_PID}:${_CMUX_GIT_HEAD_WATCH_PID}"
'''
        result = run_zsh(command, env=env, cwd=repo, timeout=8.0, job_control=True)
        assert_ok(result, "watcher loops")
        watcher_lines = [line for line in result.stdout.splitlines() if line.startswith("WATCHERS:")]
        if len(watcher_lines) != 1 or "TEARDOWN::" not in result.stdout:
            raise AssertionError(f"watcher fixture did not start and tear down cleanly: {result.stdout!r}")
        watcher_pids = watcher_lines[0].split(":")[1:]
        if len(watcher_pids) != 2 or not all(pid.isdigit() and int(pid) > 0 for pid in watcher_pids):
            raise AssertionError(f"watcher fixture did not report two live PIDs: {result.stdout!r}")
        calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
        if has_zselect and calls:
            raise AssertionError(
                "the PR and git HEAD watcher loops invoked external sleep despite zsh/zselect availability"
            )
        if not has_zselect and len(calls) < 2:
            raise AssertionError(
                "the PR and git HEAD watcher loops did not exercise the external-sleep fallback"
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
        has_zselect = test_syntax_and_zselect_sleep(base_env(fake_bin), log)
        # Start fallback with a fresh log so exactly one call is attributable to
        # this branch, rather than to a previous fixture.
        log.unlink(missing_ok=True)
        test_fallback_sleep(tmp, fake_bin, log)
        log.unlink(missing_ok=True)
        if has_zselect:
            test_real_watchers_and_teardown(tmp, fake_bin, log, has_zselect=True)
            log.unlink(missing_ok=True)
            fallback_tmp = tmp / "fallback-fixture"
            fallback_tmp.mkdir()
            test_real_watchers_and_teardown(fallback_tmp, fake_bin, log, has_zselect=False)
        else:
            test_real_watchers_and_teardown(tmp, fake_bin, log, has_zselect=False)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("PASS: zsh/zselect watcher waits, fallback, exact loop routing, and teardown")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
