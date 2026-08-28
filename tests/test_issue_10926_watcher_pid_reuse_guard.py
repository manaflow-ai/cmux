#!/usr/bin/env python3
"""
Regression for https://github.com/manaflow-ai/cmux/issues/10926.

The zsh integration spawns two disowned watcher loops per pane (PR poll,
git HEAD watch); the bash integration spawns one (PR poll). Each loop
guarded parent liveness with a bare `kill -0 $watch_shell_pid`, which is
defeated by PID reuse: once macOS recycles the recorded PID onto any live
process, the guard returns true forever and the watcher never exits
(793 orphans / 2.1 GB after 20 days in the issue).

The fix records a stable parent identity at spawn (PID plus a numeric UTC
`/bin/ps` lstart token) in `_cmux_watcher_parent_start_time`, and the
per-iteration guard `_cmux_watcher_parent_alive` treats a start-time mismatch
or a failed ps as parent-dead.

This test never touches a running cmux instance or /tmp/cmux-debug.sock:
it builds its own scratch HOME, its own unix socket, and unique panel ids.
"""

from __future__ import annotations

import os
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZSH_INTEGRATION = ROOT / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"
BASH_INTEGRATION = ROOT / "Resources" / "shell-integration" / "cmux-bash-integration.bash"

FAKE_START_TIME = "19700101000000"

FAILURES: list[str] = []


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    FAILURES.append(msg)


def base_env(tmp: Path) -> dict[str, str]:
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(tmp / "home"),
        "TMPDIR": str(tmp),
        "TERM": "dumb",
        "LC_ALL": "C",
    }


def run_shell(
    shell_argv: list[str],
    script: str,
    args: list[str],
    env: dict[str, str],
    timeout: float = 15.0,
    pass_fds: tuple[int, ...] = (),
) -> subprocess.CompletedProcess:
    return subprocess.run(
        [*shell_argv, "-c", script, "cmux-test", *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        pass_fds=pass_fds,
    )


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_pid_gone(pid: int, deadline_s: float) -> bool:
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.2)
    return not pid_alive(pid)


def wait_ready(read_fd: int, expected: int = 1, timeout_s: float = 5.0) -> bool:
    """Wait for explicit watcher-ready records without a timing sleep."""
    data = b""
    deadline = time.monotonic() + timeout_s
    while data.count(b"READY\n") < expected:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        readable, _, _ = select.select([read_fd], [], [], remaining)
        if not readable:
            return False
        chunk = os.read(read_fd, 4096)
        if not chunk:
            return False
        data += chunk
    return True


def shell_start_time(shell_argv: list[str], integration: Path, env: dict[str, str], pid: int) -> str:
    """Read the identity token through the shipped shell helper."""
    proc = run_shell(
        shell_argv,
        'source "$1"; _cmux_watcher_parent_start_time "$2"',
        [str(integration), str(pid)],
        env,
    )
    return proc.stdout.strip() if proc.returncode == 0 else ""


def check_guard_semantics(name: str, shell_argv: list[str], integration: Path, env: dict[str, str]) -> None:
    # The integration path is $1 in both shells so the scripts stay identical.
    guard_script = (
        'source "$1"; pid="$2"; expected="$3"; '
        "_cmux_watcher_parent_alive \"$pid\" \"$expected\"; "
        'printf \'GUARD:%s\\n\' "$?"'
    )
    self_script = (
        'source "$1"; IFS=:; '
        'start="$(_cmux_watcher_parent_start_time $$)" || { printf "NOSTART\\n"; exit 1; }; '
        'repeat="$(_cmux_watcher_parent_start_time $$)" || { printf "NOREPEAT\\n"; exit 1; }; '
        '_cmux_watcher_parent_identity_valid $$ "$start" || { printf "NONNUMERIC\\n"; exit 1; }; '
        '[[ "$start" == "$repeat" ]] || { printf "UNSTABLE\\n"; exit 1; }; '
        "_cmux_watcher_parent_alive $$ \"$start\"; "
        'printf \'GUARD:%s\\n\' "$?"'
    )

    # 1. Parent alive, identity captured through the shipped helper: guard passes.
    proc = run_shell(shell_argv, self_script, [str(integration)], env)
    if "GUARD:0" not in proc.stdout:
        fail(
            f"[{name}] guard rejected a live parent with its own recorded start time "
            f"(stdout={proc.stdout!r} stderr={proc.stderr[-500:]!r})"
        )

    # Locale and timezone must not change the identity token. Darwin's ps uses
    # both when formatting `lstart`, while the helper pins C/UTC before parsing.
    localized_env = dict(env)
    localized_env["LC_ALL"] = "ja_JP.UTF-8"
    localized_env["TZ"] = "Asia/Tokyo"
    proc = run_shell(shell_argv, self_script, [str(integration)], localized_env)
    if "GUARD:0" not in proc.stdout:
        fail(
            f"[{name}] locale-sensitive start-time identity rejected a live parent "
            f"(stdout={proc.stdout!r} stderr={proc.stderr[-500:]!r})"
        )

    # Missing identity must fail closed even when the PID is alive. A failed
    # start-time capture cannot safely fall back to PID-only liveness.
    empty_script = (
        'source "$1"; '
        '_cmux_watcher_parent_alive "$$" ""; '
        'printf \'GUARD:%s\\n\' "$?"'
    )
    proc = run_shell(shell_argv, empty_script, [str(integration)], env)
    if "GUARD:0" in proc.stdout or "GUARD:" not in proc.stdout:
        fail(
            f"[{name}] guard accepted an empty recorded start time "
            f"(stdout={proc.stdout!r} stderr={proc.stderr[-500:]!r})"
        )

    # Identity lookup failure must also fail closed. Override the helper only
    # in this throwaway shell to model a /bin/ps failure without touching the
    # host process table.
    ps_failure_script = (
        'source "$1"; '
        '_cmux_watcher_parent_start_time() { return 1; }; '
        '_cmux_watcher_parent_alive "$$" "19700101000000"; '
        'printf \'GUARD:%s\\n\' "$?"; '
        '_cmux_capture_shell_start_time; printf \'CAPTURE:%s\\n\' "$?"'
    )
    proc = run_shell(shell_argv, ps_failure_script, [str(integration)], env)
    if "GUARD:0" in proc.stdout or "GUARD:" not in proc.stdout or "CAPTURE:1" not in proc.stdout:
        fail(
            f"[{name}] guard accepted a failed start-time lookup "
            f"(stdout={proc.stdout!r} stderr={proc.stderr[-500:]!r})"
        )

    # 2. PID reuse: recorded PID points at a live process that is NOT the
    #    original parent (start time differs). Guard must report parent-dead.
    decoy = subprocess.Popen(["/bin/sleep", "60"])
    try:
        proc = run_shell(shell_argv, guard_script, [str(integration), str(decoy.pid), FAKE_START_TIME], env)
        if "GUARD:0" in proc.stdout or "GUARD:" not in proc.stdout:
            fail(
                f"[{name}] guard treated a recycled PID (live process, mismatched start time) as the live parent "
                f"(stdout={proc.stdout!r} stderr={proc.stderr[-500:]!r})"
            )
    finally:
        decoy.kill()
        decoy.wait()

    # 3. Parent dead, PID not reused: guard must report parent-dead.
    short = subprocess.Popen(["/bin/sleep", "60"])
    try:
        recorded_start = shell_start_time(shell_argv, integration, env, short.pid)
    finally:
        short.kill()
        short.wait()
    proc = run_shell(shell_argv, guard_script, [str(integration), str(short.pid), recorded_start or FAKE_START_TIME], env)
    if "GUARD:0" in proc.stdout or "GUARD:" not in proc.stdout:
        fail(
            f"[{name}] guard treated a dead parent PID as alive "
            f"(stdout={proc.stdout!r} stderr={proc.stderr[-500:]!r})"
        )


def check_tiered_cadence(name: str, shell_argv: list[str], integration: Path, env: dict[str, str]) -> None:
    """The guard tick must run the ps identity comparison only every Nth call.

    With interval 3: call 1 does the full check (passes, matching identity),
    calls 2 and 3 take the cheap kill -0 path even though the recorded
    identity is now wrong, call 4 does the full check again and fails.
    """
    script = (
        'source "$1"; '
        "_CMUX_WATCHER_IDENTITY_INTERVAL=3; "
        'start="$(_cmux_watcher_parent_start_time $$)" || exit 9; '
        "_cmux_watcher_guard_tick $$ \"$start\"; printf 'T1:%s\\n' \"$?\"; "
        f"_cmux_watcher_guard_tick $$ \"{FAKE_START_TIME}\"; printf 'T2:%s\\n' \"$?\"; "
        f"_cmux_watcher_guard_tick $$ \"{FAKE_START_TIME}\"; printf 'T3:%s\\n' \"$?\"; "
        f"_cmux_watcher_guard_tick $$ \"{FAKE_START_TIME}\"; printf 'T4:%s\\n' \"$?\""
    )
    proc = run_shell(shell_argv, script, [str(integration)], env)
    expected = ["T1:0", "T2:0", "T3:0"]
    got = proc.stdout.split()
    if got[:3] != expected or not got[3:4] or got[3] == "T4:0" or not got[3].startswith("T4:"):
        fail(
            f"[{name}] tiered guard cadence wrong (expected T1:0 T2:0 T3:0 T4:nonzero, "
            f"stdout={proc.stdout!r} stderr={proc.stderr[-500:]!r})"
        )


def check_injected_watcher_loop(name: str, shell_argv: list[str], integration: Path, env: dict[str, str]) -> None:
    # Pin the identity-check cadence to every iteration: the shipped default
    # runs the ps comparison only every Nth iteration to avoid steady-state
    # forks, which would push the reuse-detection bound past this test's.
    env = dict(env)
    env["_CMUX_WATCHER_IDENTITY_INTERVAL"] = "1"

    def spawn_loop(pid: int, expected: str) -> tuple[int | None, int, bool]:
        read_fd, write_fd = os.pipe()
        try:
            ready_command = (
                f"print -r -- READY >&{write_fd}" if name == "zsh" else f"printf 'READY\\n' >&{write_fd}"
            )
            launch_suffix = "&!;" if name == "zsh" else "& disown;"
            loop_script = (
                'source "$1"; '
                f"{{ _cmux_watcher_guard_tick \"$2\" \"$3\" || exit 0; {ready_command}; "
                "while true; do sleep 0.2; _cmux_watcher_guard_tick \"$2\" \"$3\" || exit 0; done; } >/dev/null 2>&1 "
                f"{launch_suffix} "
                'printf \'LOOP:%s\\n\' "$!"'
            )
            proc = run_shell(
                shell_argv,
                loop_script,
                [str(integration), str(pid), expected],
                env,
                pass_fds=(write_fd,),
            )
            loop_pid = None
            for line in proc.stdout.splitlines():
                if line.startswith("LOOP:"):
                    try:
                        loop_pid = int(line.split(":", 1)[1])
                    except ValueError:
                        loop_pid = None
                    break
            return loop_pid, read_fd, wait_ready(read_fd)
        finally:
            os.close(write_fd)

    decoy = subprocess.Popen(["/bin/sleep", "120"])
    try:
        # Normal path: recorded identity matches the live decoy. Watcher keeps running.
        true_start = shell_start_time(shell_argv, integration, env, decoy.pid)
        loop_pid, ready_fd, ready = spawn_loop(decoy.pid, true_start)
        if loop_pid is None:
            fail(f"[{name}] injected watcher loop did not report a PID")
        elif not ready:
            fail(f"[{name}] injected watcher loop did not report its first identity check")
        else:
            if not pid_alive(loop_pid):
                fail(f"[{name}] watcher loop exited although the recorded parent identity is alive and matching")
            else:
                os.kill(loop_pid, signal.SIGKILL)
        os.close(ready_fd)

        # PID reuse: same live PID, mismatched recorded start time. Watcher must
        # exit within a bounded time.
        loop_pid, ready_fd, ready = spawn_loop(decoy.pid, FAKE_START_TIME)
        if loop_pid is None:
            fail(f"[{name}] injected reuse watcher loop did not report a PID")
        elif not wait_pid_gone(loop_pid, 5.0):
            fail(f"[{name}] watcher loop survived PID reuse (live PID, mismatched start time) beyond 5s")
            os.kill(loop_pid, signal.SIGKILL)
        if ready:
            fail(f"[{name}] injected reuse watcher reported ready despite a mismatched identity")
        os.close(ready_fd)
    finally:
        decoy.kill()
        decoy.wait()


def make_socket(path: Path) -> socket.socket:
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(path))
    srv.listen(8)
    return srv


def check_real_loops(name: str, shell_argv: list[str], integration: Path, tmp: Path) -> None:
    """Drive the shipped _cmux_start_* functions from a throwaway parent shell.

    Parent alive: watchers keep running. Parent killed (SIGKILL, so no exit
    hooks run, matching the SIGHUP-less pane-close path): watchers exit within
    a bounded time because the recorded PID is dead and not reused.
    """
    sock_path = tmp / f"watch-{name}.sock"
    srv = make_socket(sock_path)
    head_file = tmp / "fake-head"
    head_file.write_text("ref: refs/heads/main\n", encoding="utf-8")

    env = base_env(tmp)
    env.update(
        {
            "CMUX_SOCKET_PATH": str(sock_path),
            "CMUX_TAB_ID": "tab-test-10926",
            "CMUX_PANEL_ID": f"panel-test-10926-{name}-{os.getpid()}",
            "_CMUX_WATCHER_IDENTITY_INTERVAL": "1",
        }
    )

    ready_read, ready_write = os.pipe()
    if name == "zsh":
        parent_script = f"""
source "$1"
functions[_cmux_test_guard_tick_impl]="${{functions[_cmux_watcher_guard_tick]}}"
typeset -g _CMUX_TEST_READY_SENT=0
_cmux_watcher_guard_tick() {{
    _cmux_test_guard_tick_impl "$@"
    local guard_status=$?
    if (( guard_status == 0 && _CMUX_TEST_READY_SENT == 0 )); then
        print -r -- READY >&{ready_write}
        _CMUX_TEST_READY_SENT=1
    fi
    return "$guard_status"
}}
_cmux_run_pr_probe_with_timeout() {{ true; }}
_cmux_pr_force_signal_path() {{ print -r -- {str(tmp / 'pr-force')!r}; }}
_cmux_git_resolve_head_path() {{ print -r -- {str(head_file)!r}; }}
_cmux_git_head_signature() {{ print -r -- "sig"; }}
_cmux_report_git_branch_for_path() {{ true; }}
_CMUX_PR_POLL_INTERVAL=1
_cmux_start_pr_poll_loop "$PWD" 1
_cmux_start_git_head_watch
print -r -- "WATCHERS:$_CMUX_PR_POLL_PID:$_CMUX_GIT_HEAD_WATCH_PID"
sleep 300
"""
    else:
        parent_script = f"""
source "$1"
eval "$(declare -f _cmux_watcher_guard_tick | sed 's/_cmux_watcher_guard_tick/_cmux_test_guard_tick_impl/g')"
_CMUX_TEST_READY_SENT=0
_cmux_watcher_guard_tick() {{
    _cmux_test_guard_tick_impl "$@"
    local guard_status=$?
    if [[ "$guard_status" == "0" && "${{_CMUX_TEST_READY_SENT:-0}}" != "1" ]]; then
        printf 'READY\\n' >&{ready_write}
        _CMUX_TEST_READY_SENT=1
    fi
    return "$guard_status"
}}
_cmux_run_pr_probe_with_timeout() {{ true; }}
_cmux_pr_force_signal_path() {{ printf '%s\\n' {str(tmp / 'pr-force')!r}; }}
_CMUX_PR_POLL_INTERVAL=1
_cmux_start_pr_poll_loop "$PWD" 1
printf 'WATCHERS:%s:\\n' "$_CMUX_PR_POLL_PID"
sleep 300
"""

    parent = subprocess.Popen(
        [*shell_argv, "-c", parent_script, "cmux-test-parent", str(integration)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
        pass_fds=(ready_write,),
    )
    os.close(ready_write)
    watcher_pids: list[int] = []
    try:
        deadline = time.monotonic() + 10
        line = ""
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            readable, _, _ = select.select([parent.stdout], [], [], remaining)
            if not readable:
                break
            line = parent.stdout.readline()
            if not line:
                break
            if line.startswith("WATCHERS:"):
                break
        if not line.startswith("WATCHERS:"):
            fail(f"[{name}] real-loop parent never reported watcher PIDs")
            return
        for token in line.strip().split(":")[1:]:
            if token:
                watcher_pids.append(int(token))
        if not watcher_pids:
            fail(f"[{name}] real-loop parent reported no watcher PIDs")
            return

        expected_ready = 2 if name == "zsh" else 1
        if not wait_ready(ready_read, expected=expected_ready):
            fail(f"[{name}] real-loop watchers did not report their first identity checks")
        for pid in watcher_pids:
            if not pid_alive(pid):
                fail(f"[{name}] shipped watcher {pid} exited while its parent shell was still alive")

        os.killpg(parent.pid, signal.SIGKILL)
        parent.wait(timeout=5)

        for pid in watcher_pids:
            if not wait_pid_gone(pid, 12.0):
                fail(f"[{name}] shipped watcher {pid} survived >12s after its parent shell died")
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
    finally:
        os.close(ready_read)
        srv.close()
        if parent.poll() is None:
            try:
                os.killpg(parent.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            parent.wait(timeout=5)
        for pid in watcher_pids:
            if pid_alive(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


def main() -> int:
    if not ZSH_INTEGRATION.exists() or not BASH_INTEGRATION.exists():
        print("SKIP: shell integration resources not found")
        return 0
    zsh = shutil.which("zsh")
    bash = shutil.which("bash")
    if zsh is None or bash is None:
        print("SKIP: zsh or bash not installed")
        return 0

    tmp = Path(tempfile.mkdtemp(prefix="cmux_10926_"))
    (tmp / "home").mkdir()
    try:
        shells = [
            ("zsh", [zsh, "-f"], ZSH_INTEGRATION),
            ("bash", [bash, "--norc"], BASH_INTEGRATION),
        ]
        for name, argv, integration in shells:
            env = base_env(tmp)
            check_guard_semantics(name, argv, integration, env)
            check_tiered_cadence(name, argv, integration, env)
            check_injected_watcher_loop(name, argv, integration, env)
            check_real_loops(name, argv, integration, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if FAILURES:
        print(f"FAILED: {len(FAILURES)} assertion(s)")
        return 1
    print("PASS: watcher parent-identity guard holds under PID reuse for zsh and bash")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
