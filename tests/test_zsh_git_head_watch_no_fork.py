#!/usr/bin/env python3
"""Regression coverage: the zsh git HEAD watcher must poll without forking.

The watcher runs once per second in every pane whose shell is inside a git
repository. Reading HEAD through ``$(...)`` forked a subshell on every poll,
so many open panes produced a steady stream of process launches. The test
starts the real watcher loop and records the PID that performs each HEAD read;
every read must happen in the watcher process itself.

The socket and repository are private fixtures; no running cmux instance is
involved.
"""

from __future__ import annotations

import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"

COMMAND = r'''
source "$1"
zmodload zsh/system
_cmux_report_git_branch_for_path() { :; }
_cmux_pr_cache_clear() { :; }
_cmux_clear_pr_for_panel() { :; }
# Log the PID of every HEAD read, through whichever reader helper exists.
local reader
for reader in _cmux_git_head_signature_into_reply _cmux_git_head_signature; do
    (( $+functions[$reader] )) || continue
    functions[_cmux_test_impl_$reader]=$functions[$reader]
    functions[$reader]='print -r -- "$sysparams[pid]" >> "$CMUX_TEST_READ_LOG"; '"_cmux_test_impl_$reader"' "$@"'
done
_cmux_start_git_head_watch
[[ "${_CMUX_GIT_HEAD_WATCH_PID:-}" == <-> ]] || { print -r -- WATCHER_MISSING; exit 3; }
print -r -- "WATCHER:$_CMUX_GIT_HEAD_WATCH_PID"
zselect -t 350 || true
_cmux_stop_git_head_watch
'''


def main() -> int:
    if not SCRIPT.exists():
        print("SKIP: zsh integration resource not found")
        return 0
    if shutil.which("zsh") is None:
        print("SKIP: zsh is not installed")
        return 0

    tmp = Path(tempfile.mkdtemp(prefix="cmux_head_watch_"))
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock_path = tmp / "cmux.sock"
        server.bind(str(sock_path))
        server.listen(1)
        repo = tmp / "repo"
        (repo / ".git").mkdir(parents=True)
        (repo / ".git" / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
        read_log = tmp / "reads.log"
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(tmp),
            "TMPDIR": str(tmp),
            "LC_ALL": "C",
            "TERM": "dumb",
            "CMUX_SOCKET_PATH": str(sock_path),
            "CMUX_TAB_ID": "tab-head-watch",
            "CMUX_PANEL_ID": "panel-head-watch",
            "CMUX_TEST_READ_LOG": str(read_log),
        }
        result = subprocess.run(
            ["/bin/zsh", "-f", "-c", COMMAND, "cmux-test", str(SCRIPT)],
            cwd=repo,
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        if result.returncode != 0 or "WATCHER:" not in result.stdout:
            raise AssertionError(
                f"watcher fixture failed ({result.returncode}):\n"
                f"stdout={result.stdout}\nstderr={result.stderr}"
            )
        watcher_pid = result.stdout.split("WATCHER:", 1)[1].split()[0]
        # The first read seeds the signature in the interactive shell itself.
        reads = read_log.read_text(encoding="utf-8").split() if read_log.exists() else []
        loop_reads = reads[1:]
        if len(loop_reads) < 2:
            raise AssertionError(f"watcher loop polled HEAD only {len(loop_reads)} time(s)")
        forked = [pid for pid in loop_reads if pid != watcher_pid]
        if forked:
            raise AssertionError(
                f"{len(forked)} of {len(loop_reads)} HEAD polls ran in a forked subshell "
                f"(watcher={watcher_pid}, readers={sorted(set(forked))})"
            )
    finally:
        server.close()
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"PASS: git HEAD watcher polled {len(loop_reads)} times without forking")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
