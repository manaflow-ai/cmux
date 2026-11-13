#!/usr/bin/env python3
"""nightly.yml nightly-next-one, "Refuse stray processes before secrets": no process of this job outlives its step.

nightly-next-one builds, signs and publishes in one job, so build-time code (a dependency's build script, bun or
npm install, cargo build.rs, zig, a SwiftPM plugin) and the app's own code run by the verify steps share a job with
the Developer ID key, the release App key, the R2 credentials and the writer token. A detached process left by any
of them would run as the same user into the steps that unlock the keychain or hold those secrets. The split path
keeps them apart by job (#21024: "This job holds signing secrets, so it runs no code from the bundle"). Here the
job runs this check right before the first signing secret and again right before the publication secrets.

It fails when any process other than the runner itself and this step's own process tree carries this job's
RUNNER_TRACKING_ID in its environment or has its working directory under this runner's _work directory or
$RUNNER_TEMP. Modeled on glaeda's stray_job_processes (scripts/glaeda-cmux-runner-hook). It reads every process
of this user: /proc on Linux, `ps -E` and `lsof -d cwd` on macOS. A listing it cannot read in full fails too.
A stray gets GRACE_S to exit on its own (a build service finishing its shutdown); nothing is killed here.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

RUNNER_PROCESSES = {"Runner.Worker", "Runner.Listener", "run.sh", "run-helper.sh", "runsvc.sh"}
GRACE_S = 20.0
POLL_S = 1.0


@dataclass(frozen=True)
class Proc:
    ppid: int
    command: str
    tracked: bool  # carries this job's RUNNER_TRACKING_ID
    cwd: str | None


def strays(table: dict[int, Proc], me: int, roots: list[str]) -> list[int]:
    """The pids in table that are this job's (tracked, or working under a root) and neither the runner nor this
    process, its ancestors or its descendants."""
    insides = [r.rstrip("/") + "/" for r in roots]
    mine, walk = set(), me
    for _ in range(256):
        if walk <= 1 or walk in mine:
            break
        mine.add(walk)
        walk = table[walk].ppid if walk in table else 0

    def ours(pid: int) -> bool:
        """This process, an ancestor of it (the step's shell, the Runner.Worker) or a descendant of it (ps)."""
        if pid in mine:
            return True
        seen = set()
        while pid > 1 and pid not in seen:
            if pid == me:
                return True
            seen.add(pid)
            pid = table[pid].ppid if pid in table else 0
        return False

    def runner(proc: Proc) -> bool:
        argv0 = proc.command.split(" ", 1)[0]
        return os.path.basename(argv0) in RUNNER_PROCESSES

    found = []
    for pid, proc in sorted(table.items()):
        cwd = proc.cwd or ""
        if not (proc.tracked or any(cwd == r.rstrip("/") or cwd.startswith(i) for r, i in zip(roots, insides))):
            continue
        if ours(pid) or runner(proc):
            continue
        found.append(pid)
    return found


def linux_table(tracking: str) -> dict[int, Proc] | None:
    uid, table = os.getuid(), {}
    marker = f"RUNNER_TRACKING_ID={tracking}".encode()
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != uid:
                continue
            stat = (entry / "stat").read_text()
            ppid = int(stat[stat.rindex(")") + 2:].split()[1])
            command = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
            environ = (entry / "environ").read_bytes().split(b"\0")
            cwd = os.path.realpath(entry / "cwd")
        except (FileNotFoundError, ProcessLookupError):
            continue  # it ended while being read
        except PermissionError:
            continue  # a non-dumpable process of this user (ssh-agent): the macOS runner reads it through ps
        table[int(entry.name)] = Proc(ppid, command, marker in environ, cwd)
    return table if os.getpid() in table else None


def mac_table(tracking: str) -> dict[int, Proc] | None:
    uid = str(os.getuid())
    try:
        listing = subprocess.run(["/bin/ps", "-E", "-U", uid, "-ww", "-o", "pid=,ppid=,command="],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20,
                                 env={"LC_ALL": "C"}, errors="replace")
        cwds = subprocess.run(["/usr/sbin/lsof", "-nP", "-w", "-a", "-u", uid, "-d", "cwd", "-Fpn"],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20, errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return None
    if listing.returncode != 0 or f"p{os.getpid()}" not in cwds.stdout.split():
        return None
    where, pid = {}, 0
    for line in cwds.stdout.splitlines():
        if line[:1] == "p" and line[1:].isdigit():
            pid = int(line[1:])
        elif line[:1] == "n" and pid:
            where[pid] = os.path.realpath(line[1:])
    marker, table = f"RUNNER_TRACKING_ID={tracking}", {}
    for line in listing.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            rest = parts[2] if len(parts) == 3 else ""
            # ps -E prints the environment after the arguments; the marker ends at a space or the line's end.
            tracked = f" {marker} " in f" {rest} "
            table[int(parts[0])] = Proc(int(parts[1]), rest, tracked, where.get(int(parts[0])))
    return table if os.getpid() in table else None


def describe(table: dict[int, Proc], pid: int) -> str:
    proc = table[pid]
    command = proc.command.split(" RUNNER_TRACKING_ID=", 1)[0][:160]
    return f"  pid {pid} (parent {proc.ppid}){' tracked' if proc.tracked else ''} cwd {proc.cwd}: {command}"


def main() -> int:
    tracking = os.environ.get("RUNNER_TRACKING_ID", "")
    temp = os.environ.get("RUNNER_TEMP", "")
    workspace = os.environ.get("RUNNER_WORKSPACE", "")
    if not tracking or not temp or not workspace:
        print("::error::refuse_stray_processes: RUNNER_TRACKING_ID, RUNNER_TEMP and RUNNER_WORKSPACE must be set")
        return 1
    roots = sorted({os.path.realpath(os.path.dirname(workspace.rstrip("/"))), os.path.realpath(temp)})
    read = linux_table if sys.platform.startswith("linux") else mac_table
    deadline = time.monotonic() + GRACE_S
    while True:
        table = read(tracking)
        if table is None:
            print("::error::refuse_stray_processes: could not read every process of this user, so the job "
                  "cannot show nothing of its own still runs; refusing the secrets")
            return 1
        found = strays(table, os.getpid(), roots)
        if not found:
            print(f"No process of this job outlived its step (roots {', '.join(roots)}).")
            return 0
        if time.monotonic() >= deadline:
            break
        time.sleep(POLL_S)
    print(f"::error::{len(found)} process(es) of this job outlived their step and would run beside the secrets "
          f"(they carry RUNNER_TRACKING_ID or work under {', '.join(roots)}):")
    for pid in found[:20]:
        print(describe(table, pid))
    return 1


if __name__ == "__main__":
    sys.exit(main())
