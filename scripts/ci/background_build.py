#!/usr/bin/env python3
"""Run a build in the background of a CI job, and join it in a later step.

  background_build.py start --state DIR NAME -- COMMAND...
  background_build.py join  --state DIR NAME [--timeout SECONDS]
  background_build.py stop  --state DIR

build-nightly-app starts the OptChat Chief and iPhone host builds with `start`
and they compile beside the Release build; a step after xcodebuild runs `join`
before the phase scripts copy them into the app.

`start` returns at once. COMMAND runs in its own session (process group), its
output in DIR/NAME.log. Its supervisor holds an exclusive flock on DIR/NAME.lock
from before `start` returns until COMMAND has exited and DIR/NAME.status holds
its exit status. `join` blocks on that lock (nothing polls), prints the log and
exits 0 only for status 0: a failed or killed build, or one that never started,
fails the joining step. `stop` (an always() cleanup step) kills the process
group of every build that has not finished, and never one that has.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def paths(state: Path, name: str) -> dict[str, Path]:
    return {kind: state / f"{name}.{kind}" for kind in ("lock", "log", "status", "pid")}


def start(state: Path, name: str, command: list[str]) -> int:
    state.mkdir(parents=True, exist_ok=True)
    files = paths(state, name)
    if files["pid"].exists():
        print(f"error: {name} was already started in {state}", file=sys.stderr)
        return 2
    for kind in ("status", "log"):
        files[kind].unlink(missing_ok=True)
    lock = os.open(files["lock"], os.O_RDWR | os.O_CREAT, 0o644)
    # Taken here, before the supervisor exists, so a join that runs right after
    # start always waits. The supervisor inherits this open file description,
    # and with it the lock, which ends when the supervisor exits.
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    with open(files["log"], "wb") as log:
        supervisor = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "_supervise", "--state", str(state),
             "--lock-fd", str(lock), name, "--", *command],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True, pass_fds=(lock,))
    os.close(lock)
    files["pid"].write_text(f"{supervisor.pid}\n")
    print(f"started {name} in the background (process group {supervisor.pid}, log {files['log']})")
    return 0


def supervise(state: Path, name: str, lock_fd: int, command: list[str]) -> int:
    files = paths(state, name)
    started = time.monotonic()
    try:
        # close_fds (the default) keeps the lock from COMMAND and anything it
        # leaves running, so the lock ends with this process.
        status = subprocess.call(command, stdin=subprocess.DEVNULL)
    except OSError as error:
        print(f"error: {name} could not start: {error}", flush=True)
        status = 127
    if status < 0:
        status = 128 - status
    print(f"{name} exited with status {status} after {time.monotonic() - started:.0f} s", flush=True)
    partial = files["status"].with_suffix(".status.partial")
    partial.write_text(f"{status}\n")
    os.replace(partial, files["status"])
    os.close(lock_fd)
    return 0


class Timeout(Exception):
    pass


def join(state: Path, name: str, timeout: int) -> int:
    files = paths(state, name)
    if not files["pid"].exists():
        print(f"::error::{name} was never started in {state}")
        return 1
    lock = os.open(files["lock"], os.O_RDONLY)

    def expire(_signum, _frame):
        raise Timeout()

    previous = signal.signal(signal.SIGALRM, expire)
    signal.alarm(timeout)
    started = time.monotonic()
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
    except Timeout:
        print(f"::error::{name} did not finish within {timeout} s")
        return 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        os.close(lock)
    waited = time.monotonic() - started
    print(f"::group::{name} (waited {waited:.0f} s for it)")
    if files["log"].exists():
        sys.stdout.write(files["log"].read_text(errors="replace"))
    print("::endgroup::", flush=True)
    status = files["status"].read_text().strip() if files["status"].exists() else ""
    if status == "0":
        print(f"{name} finished (waited {waited:.0f} s)")
        return 0
    print(f"::error::{name} failed ({'status ' + status if status else 'it ended without a status: killed?'})")
    return 1


def stop(state: Path) -> int:
    for pid_file in sorted(state.glob("*.pid")) if state.is_dir() else []:
        name = pid_file.name[: -len(".pid")]
        if paths(state, name)["status"].exists():
            continue
        group = int(pid_file.read_text().strip())
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(group, sig)
            except ProcessLookupError:
                break
            print(f"sent {signal.Signals(sig).name} to {name} (process group {group})")
            if sig == signal.SIGTERM:
                time.sleep(2)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("start", "join", "stop", "_supervise"):
        sub = commands.add_parser(command)
        sub.add_argument("--state", required=True, type=Path)
        if command != "stop":
            sub.add_argument("name")
        if command == "join":
            sub.add_argument("--timeout", type=int, default=1800)
        if command == "_supervise":
            sub.add_argument("--lock-fd", required=True, type=int)
        if command in ("start", "_supervise"):
            sub.add_argument("build", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command in ("start", "_supervise"):
        build = args.build[1:] if args.build[:1] == ["--"] else args.build
        if not build:
            parser.error("a command is required after --")
        if args.command == "start":
            return start(args.state, args.name, build)
        return supervise(args.state, args.name, args.lock_fd, build)
    if args.command == "join":
        return join(args.state, args.name, args.timeout)
    return stop(args.state)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
