"""Kill the process groups a test started even when the test never reaches tearDown.

A script under test that starts a server in its own process group (`set -m`, setsid, nohup) means it to outlive its
caller. A test that kills that group only in tearDown leaves it running at PPID 1 when the run itself is killed (a
runner's timeout, a cancelled CI job, a second Ctrl-C): tests/test_web_overlay_exit_watch.py left six fake
`bun run dev` trees on a lane machine, the oldest 384 h, with their temp dirs (2026-11-25).

Reaper() starts a watcher in its own session whose stdin is a pipe only this process holds (Python's descriptors are
not inherited, and subprocess closes the rest). group(pgid) names a group to kill, pidfile(path) a file naming one
when the watch ends, remove(path) a directory to delete after. When the pipe closes, by close() or by this process
dying any way at all, the watcher SIGKILLs every group it was told about, deletes the directories and exits. close()
waits for that, so a tearDown that calls it ends with nothing left.

Tests run under `python3 -I`, which puts no script folder on sys.path; load this file by path (see the callers).
"""
import subprocess
import sys

_WATCH = r"""
import os, shutil, signal, sys
for s in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
    signal.signal(s, signal.SIG_IGN)  # the test's terminal or runner signals it; only the pipe's end counts
groups, pidfiles, dirs = [], [], []
for line in sys.stdin:
    kind, _, arg = line.rstrip("\n").partition(" ")
    {"g": groups, "f": pidfiles, "d": dirs}.get(kind, []).append(arg)
for path in pidfiles:
    try:
        groups.append(open(path).read().split()[0])
    except (OSError, IndexError):
        pass
for g in groups:
    try:
        if int(g) > 1:
            os.killpg(int(g), signal.SIGKILL)
    except (ValueError, OSError):
        pass
for d in dirs:
    shutil.rmtree(d, ignore_errors=True)
"""


class Reaper:
    def __init__(self):
        self._proc = subprocess.Popen([sys.executable, "-I", "-c", _WATCH], stdin=subprocess.PIPE, text=True,
                                      stdout=subprocess.DEVNULL, start_new_session=True)

    def _say(self, kind, arg):
        self._proc.stdin.write("%s %s\n" % (kind, arg))
        self._proc.stdin.flush()

    def group(self, pgid):
        self._say("g", int(pgid))

    def pidfile(self, path):
        self._say("f", str(path))

    def remove(self, path):
        self._say("d", str(path))

    def close(self, timeout=15):
        if self._proc.stdin and not self._proc.stdin.closed:
            self._proc.stdin.close()
        self._proc.wait(timeout=timeout)
