#!/usr/bin/env python3
"""
Regression for https://github.com/manaflow-ai/cmux/issues/10926.

The zsh integration spawns two disowned watcher loops per pane (PR poll,
git HEAD watch); the bash integration spawns one (PR poll). Each loop
guarded parent liveness with a bare `kill -0 $watch_shell_pid`, which is
defeated by PID reuse: once macOS recycles the recorded PID onto any live
process, the guard returns true forever and the watcher never exits
(793 orphans / 2.1 GB after 20 days in the issue).

The fix records a stable parent identity at spawn (PID plus /bin/ps lstart
start time) in `_cmux_watcher_parent_start_time`, and the per-iteration
guard `_cmux_watcher_parent_alive` treats a start-time mismatch or a
failed ps as parent-dead.

This test never touches a running cmux instance or /tmp/cmux-debug.sock:
it builds its own scratch HOME, its own unix socket, and unique panel ids.
"""

from __future__ import annotations

import os
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

FAKE_START_TIME = "Thu Jan  1 00:00:00 1970"

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


def run_shell(shell_argv: list[str], script: str, args: list[str], env: dict[str, str], timeout: float = 15.0) -> subprocess.CompletedProcess:
    return subprocess.run(
        [*shell_argv, "-c", script, "cmux-test", *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
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


def ps_lstart(pid: int) -> str:
    out = subprocess.run(
        ["/bin/ps", "-o", "lstart=", "-p", str(pid)],
        capture_output=True,
        text=True,
    ).stdout
    return " ".join(out.split())


def check_guard_semantics(name: str, shell_argv: list[str], integration: Path, env: dict[str, str]) -> None:
    # The integration path is $1 in both shells so the scripts stay identical.
    guard_script = (
        'source "$1"; pid="$2"; expected="$3"; '
        "_cmux_watcher_parent_alive \"$pid\" \"$expected\"; "
        'printf \'GUARD:%s\\n\' "$?"'
    )
    self_script = (
        'source "$1"; '
        'start="$(_cmux_watcher_parent_start_time $$)" || { printf "NOSTART\\n"; exit 1; }; '
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
    short = subprocess.Popen(["/bin/sleep", "0.05"])
    recorded_start = ps_lstart(short.pid)
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
        "_cmux_watcher_guard_tick $$ \"not-the-start-time\"; printf 'T2:%s\\n' \"$?\"; "
        "_cmux_watcher_guard_tick $$ \"not-the-start-time\"; printf 'T3:%s\\n' \"$?\"; "
        "_cmux_watcher_guard_tick $$ \"not-the-start-time\"; printf 'T4:%s\\n' \"$?\""
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
    if name == "zsh":
        loop_script = (
            'source "$1"; '
            "{ while true; do _cmux_watcher_guard_tick \"$2\" \"$3\" || exit 0; sleep 0.2; done } >/dev/null 2>&1 &!; "
            'printf \'LOOP:%s\\n\' "$!"'
        )
    else:
        loop_script = (
            'source "$1"; '
            "{ while true; do _cmux_watcher_guard_tick \"$2\" \"$3\" || exit 0; sleep 0.2; done } >/dev/null 2>&1 & "
            "disown; "
            'printf \'LOOP:%s\\n\' "$!"'
        )

    def spawn_loop(pid: int, expected: str) -> int | None:
        proc = run_shell(shell_argv, loop_script, [str(integration), str(pid), expected], env)
        for line in proc.stdout.splitlines():
            if line.startswith("LOOP:"):
                try:
                    return int(line.split(":", 1)[1])
                except ValueError:
                    return None
        return None

    decoy = subprocess.Popen(["/bin/sleep", "120"])
    try:
        # Normal path: recorded identity matches the live decoy. Watcher keeps running.
        true_start = ps_lstart(decoy.pid)
        loop_pid = spawn_loop(decoy.pid, true_start)
        if loop_pid is None:
            fail(f"[{name}] injected watcher loop did not report a PID")
        else:
            time.sleep(2.0)
            if not pid_alive(loop_pid):
                fail(f"[{name}] watcher loop exited although the recorded parent identity is alive and matching")
            else:
                os.kill(loop_pid, signal.SIGKILL)

        # PID reuse: same live PID, mismatched recorded start time. Watcher must
        # exit within a bounded time.
        loop_pid = spawn_loop(decoy.pid, FAKE_START_TIME)
        if loop_pid is None:
            fail(f"[{name}] injected reuse watcher loop did not report a PID")
        elif not wait_pid_gone(loop_pid, 5.0):
            fail(f"[{name}] watcher loop survived PID reuse (live PID, mismatched start time) beyond 5s")
            os.kill(loop_pid, signal.SIGKILL)
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

    if name == "zsh":
        parent_script = f"""
source "$1"
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
    )
    watcher_pids: list[int] = []
    try:
        deadline = time.time() + 10
        line = ""
        while time.time() < deadline:
            line = parent.stdout.readline()
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

        time.sleep(2.5)
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
