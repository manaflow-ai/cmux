"""requires(capability): a test that needs a host's program to behave some way says so, and skips with the reason
when this host's does not.

A capability is probed by what the program does, never by where it is: /usr/bin/time on macOS is BSD time, which
takes no -f, and stock macOS has no setsid, timeout or stdbuf at all (manaflow-ai/cmuxterm-hq#9393 review at
7948495f, F2; teamleaderleo/leo-workspace#4434 review, F3). Each probe runs once per process.

    from requires import requires, available
    requires("gnu-time")          # raises unittest.SkipTest naming what is missing
    ok, why = available("setsid")  # the same probe, as a value (for a subTest that skips one row)

test_requires.py holds the probes to their behaviour, and lints every tools/ test: a which() or a fixed path of a
host-dependent program (HOST_PROGRAMS), or shell text that runs one, sits in a function that calls requires() or
available() for its capability. This file imports only the standard library, so another repo can vendor it whole.
"""
from __future__ import annotations

import functools
import shutil
import subprocess
import unittest

# The host-dependent programs a test may run, each with the capability it needs.
HOST_PROGRAMS = {"setsid": "setsid", "timeout": "timeout", "stdbuf": "stdbuf", "time": "gnu-time"}


def _run(argv: list[str]) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None


def _status(script: str, want: int) -> tuple[bool, str]:
    bash = shutil.which("bash")
    if not bash:
        return False, "no bash on this host"
    got = _run([bash, "--noprofile", "--norc", "-c", script])
    if got is None:
        return False, f"`{script}` did not end"
    if got.returncode != want:
        return False, f"`{script}` exited {got.returncode}, not {want}: {got.stderr.strip()[:200]}"
    return True, ""


def _gnu_time() -> tuple[bool, str]:
    ok, why = _status("command time -f shell-tree-probe-%x true", 0)
    if not ok:
        return False, "no GNU time (command time -f): " + why
    got = _run([shutil.which("bash"), "--noprofile", "--norc", "-c", "command time -f shell-tree-probe-%x true"])
    if got is None or "shell-tree-probe-0" not in got.stderr:
        return False, "command time -f does not print its format: not GNU time"
    return True, ""


PROBES = {
    "bash": lambda: _status("exit 7", 7),
    # It runs the command, in a session of its own: the child's session id is its own pid.
    "setsid": lambda: _status("setsid sh -c 'test \"$(ps -o sid= -p $$ | tr -d \" \")\" = \"$$\" && exit 7'", 7),
    # It runs the command, and stops one past its duration with 124.
    "timeout": lambda: _status("timeout 5 sh -c 'exit 7' && exit 1; [ $? = 7 ] && timeout 0.1 sleep 5; "
                               "[ $? = 124 ] && exit 7", 7),
    "stdbuf": lambda: _status("stdbuf -oL sh -c 'exit 7'", 7),
    "gnu-time": _gnu_time,
    "env-split": lambda: _status("env -S 'sh -c \"exit 7\"'", 7),
}


@functools.cache
def available(capability: str) -> tuple[bool, str]:
    """(whether this host has CAPABILITY, why not)."""
    if capability not in PROBES:
        raise KeyError(f"unknown capability {capability!r}: one of {', '.join(sorted(PROBES))}")
    return PROBES[capability]()


def requires(capability: str) -> None:
    """Skip the test (unittest.SkipTest) when this host lacks CAPABILITY, naming why."""
    ok, why = available(capability)
    if not ok:
        raise unittest.SkipTest(f"needs {capability}: {why}")
