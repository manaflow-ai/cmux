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

The runner's job hooks are the runner's, not the job's. A runner started with ACTIONS_RUNNER_HOOK_JOB_STARTED runs
that hook before the first step, with the job's environment, and the hook may leave processes for the whole job:
glaeda's keeps a holder for the job's admission and a telemetry sampler, both carrying RUNNER_TRACKING_ID. The
first one-job nightly (run 43366166125) counted those two and refused its secrets. So a process whose program, or
the script its interpreter runs, sits in the directory of a hook the job's Runner.Worker was started with is
spared. The directory is read from the Worker's own environment, which no step can change, and one inside _work
or $RUNNER_TEMP, where the job writes, is not taken.

Xcode's build daemons are the build step's to end, not this check's to spare. actool (the asset catalogs) starts
ibtoold, which re-parents to launchd, keeps the job's environment and idles about a minute after xcodebuild returns.
Run 43431310245 reached this check 80 s after the Release build's last actool call and refused on two ibtoolds;
run 43425913710 reached it 2.5 min after and passed. So "Build nightly app (Release)" ends its own with
`--end-build-daemons` when it exits: only processes this check would count (this job's tracking id or a cwd under
its roots) whose program is one of BUILD_DAEMONS in the selected Xcode's Developer directory. It never spares
anything here: one that will not end still fails this check.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

RUNNER_PROCESSES = {"Runner.Worker", "Runner.Listener", "run.sh", "run-helper.sh", "runsvc.sh"}
HOOK_VARIABLES = ("ACTIONS_RUNNER_HOOK_JOB_STARTED", "ACTIONS_RUNNER_HOOK_JOB_COMPLETED")
HOOK_IN_PS = re.compile(rf"(?:^| )(?:{'|'.join(HOOK_VARIABLES)})=(/\S+)")  # ps -E: the environment after the arguments
GRACE_S = 20.0
POLL_S = 1.0
# Xcode's per-build daemons (the program in $DEVELOPER_DIR/usr/bin) a build step may end once xcodebuild returns.
BUILD_DAEMONS = ("ibtoold",)


@dataclass(frozen=True)
class Proc:
    ppid: int
    command: str
    tracked: bool  # carries this job's RUNNER_TRACKING_ID
    cwd: str | None
    hooks: tuple[str, ...] = ()  # the job hooks (HOOK_VARIABLES) in its environment


def hook_dirs(table: dict[int, Proc], me: int, roots: list[str]) -> list[str]:
    """The directories of the job hooks this job's Runner.Worker (the nearest one above `me`) was started with,
    less any inside a root: the job writes there, so what runs from it is the job's."""
    insides = [r.rstrip("/") + "/" for r in roots]
    seen, pid = set(), me
    while pid > 1 and pid in table and pid not in seen:
        seen.add(pid)
        if os.path.basename(table[pid].command.split(" ", 1)[0]) == "Runner.Worker":
            dirs = {form(os.path.dirname(hook)) for hook in table[pid].hooks
                    for form in (os.path.normpath, os.path.realpath)}
            return sorted(d for d in dirs if d != "/" and not any((d + "/").startswith(i) for i in insides))
        pid = table[pid].ppid
    return []


def strays(table: dict[int, Proc], me: int, roots: list[str], hooks: list[str] | tuple[str, ...] = ()) -> list[int]:
    """The pids in table that are this job's (tracked, or working under a root) and neither the runner, one of its
    job hooks' processes (a program in a `hooks` directory) nor this process, its ancestors or its descendants."""
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

    def hook(proc: Proc) -> bool:
        """Its program (argv[0]) or the script an interpreter runs (argv[1]) is a file of a hook directory."""
        return any(word.startswith("/") and os.path.dirname(os.path.normpath(word)) in hooks
                   for word in proc.command.split(" ", 2)[:2])

    found = []
    for pid, proc in sorted(table.items()):
        cwd = proc.cwd or ""
        if not (proc.tracked or any(cwd == r.rstrip("/") or cwd.startswith(i) for r, i in zip(roots, insides))):
            continue
        if ours(pid) or runner(proc) or hook(proc):
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
        hooks = tuple(value.decode(errors="replace") for name, _, value in (e.partition(b"=") for e in environ)
                      if name.decode(errors="replace") in HOOK_VARIABLES and value.startswith(b"/"))
        table[int(entry.name)] = Proc(ppid, command, marker in environ, cwd, hooks)
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
            table[int(parts[0])] = Proc(int(parts[1]), rest, tracked, where.get(int(parts[0])),
                                        tuple(HOOK_IN_PS.findall(rest)))
    return table if os.getpid() in table else None


def build_daemons(table: dict[int, Proc], found: list[int], developer_dir: str) -> list[int]:
    """The pids in `found` (strays) whose program (argv[0]) is a BUILD_DAEMONS binary of developer_dir."""
    if not developer_dir.startswith("/"):
        return []
    programs = {os.path.join(os.path.normpath(developer_dir), "usr/bin", name) for name in BUILD_DAEMONS}
    return [pid for pid in found if os.path.normpath(table[pid].command.split(" ", 1)[0]) in programs]


def developer_dir() -> str:
    chosen = os.environ.get("DEVELOPER_DIR", "")
    if chosen:
        return chosen
    try:
        return subprocess.run(["/usr/bin/xcode-select", "-p"], stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def end_build_daemons(read, tracking: str, roots: list[str], wait_s: float = 10.0) -> int:
    """SIGTERM this job's Xcode build daemons, then SIGKILL any still running after wait_s. Never fails the step:
    the check before the secrets still counts whatever is left."""
    import signal
    table = read(tracking)
    if table is None:
        print("::warning::end-build-daemons: could not read this user's processes; the check before the secrets will")
        return 0
    devdir = developer_dir()
    pids = build_daemons(table, strays(table, os.getpid(), roots, hook_dirs(table, os.getpid(), roots)), devdir)
    if not pids:
        print(f"No Xcode build daemon of this job is running (Developer directory {devdir or 'unknown'}).")
        return 0
    commands = {pid: table[pid].command for pid in pids}
    for pid in pids:
        print("Ending this job's Xcode build daemon:" + describe(table, pid)[1:])
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + wait_s
    while True:
        table = read(tracking) or {}
        left = [pid for pid in pids if pid in table and table[pid].command == commands[pid]]
        if not left or time.monotonic() >= deadline:
            break
        time.sleep(POLL_S)
    for pid in left:
        print(f"::warning::Xcode build daemon {pid} outlived SIGTERM by {wait_s:.0f} s; sending SIGKILL")
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return 0


def describe(table: dict[int, Proc], pid: int) -> str:
    proc = table[pid]
    command = proc.command.split(" RUNNER_TRACKING_ID=", 1)[0][:400]
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
    if sys.argv[1:] == ["--end-build-daemons"]:
        return end_build_daemons(read, tracking, roots)
    if sys.argv[1:]:
        print(f"usage: {sys.argv[0]} [--end-build-daemons]")
        return 2
    deadline = time.monotonic() + GRACE_S
    while True:
        table = read(tracking)
        if table is None:
            print("::error::refuse_stray_processes: could not read every process of this user, so the job "
                  "cannot show nothing of its own still runs; refusing the secrets")
            return 1
        hooks = hook_dirs(table, os.getpid(), roots)
        found = strays(table, os.getpid(), roots, hooks)
        if not found:
            print(f"No process of this job outlived its step (roots {', '.join(roots)}"
                  + (f"; the runner's job hooks in {', '.join(hooks)} are its own" if hooks else "") + ").")
            return 0
        if time.monotonic() >= deadline:
            break
        time.sleep(POLL_S)
    print(f"::error::{len(found)} process(es) of this job outlived their step and would run beside the secrets "
          f"(they carry RUNNER_TRACKING_ID or work under {', '.join(roots)}; the runner's job hooks: "
          f"{', '.join(hooks) or 'none in its Runner.Worker environment'}):")
    for pid in found[:20]:
        print(describe(table, pid))
    return 1


if __name__ == "__main__":
    sys.exit(main())
