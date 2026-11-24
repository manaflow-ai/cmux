#!/usr/bin/env python3
"""background-ready-idle.py: what a cmux NEXT copy costs while it waits in the background, and its stop.

  measure APP PID SECONDS ARM STATE   one idle window over APP's processes (PID's descendants, every process run
                                      from APP, the ones macOS counts PID responsible for: procs.Instance); PID 0
                                      after a quit: only APP's leftovers. Prints `BR-IDLE ARM {json}`:
      memory    per process kind and total: rss MB, phys_footprint MB (at the window's end)
      window    per kind and total: CPU % of one core, wakeups/s, energy mW (ri_energy_nj), threads
      files     per pid: open files by lsof type (REG, DIR, unix, IPv4, KQUEUE, ...), the total and its sockets
      sleep     `pmset -g assertions` lines owned by these pids; can_sleep is false when one prevents sleep
  stop APP                            ends every process of APP's copy by its pid: SIGTERM to the app, 10 s, SIGTERM
                                      to the rest, 5 s, SIGKILL to what is left (Chromium's code-sign clone cleanup
                                      helper gets 15 s first). Never a process outside the copy's set, never by name.
                                      Prints `BR-STOP {json}`.

procs.py (scripts/perf-bench) is copied beside this file by background-ready.sh. Exits 0, or 1 with the reason.
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / "perf-bench")]
import procs  # noqa: E402

SOCKET_TYPES = {"unix", "IPv4", "IPv6", "systm", "ndrv", "key"}
# The root of an instance whose app is gone (0 after a quit): no process has it, so only the copy's own processes count.
# Not -1, which responsibility_get_pid_responsible_for_pid returns for a pid it cannot read.
NO_PID = 999_999_999
PREVENTS_SLEEP = ("PreventSystemSleep", "PreventUserIdleSystemSleep", "NoIdleSleepAssertion")


def instance(app: str, pid: int) -> procs.Instance:
    return procs.Instance(app, pid if pid > 0 and procs._alive(pid) else NO_PID)


def open_files(pids: dict[int, str]) -> dict:
    """Per pid: lsof's open files counted by type; totals per kind and overall."""
    if not pids:
        return {"pids": [], "total": 0, "sockets": 0}
    out = subprocess.run(["lsof", "-n", "-P", "-w", "-F", "pt", "-p", ",".join(str(p) for p in pids)],
                         capture_output=True, text=True).stdout
    by_pid: dict[int, dict[str, int]] = {}
    pid = None
    for line in out.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid = int(line[1:])
            by_pid.setdefault(pid, {})
        elif line.startswith("t") and pid is not None:
            kind = line[1:] or "?"
            by_pid[pid][kind] = by_pid[pid].get(kind, 0) + 1
    rows, kinds = [], {}
    for pid, types in sorted(by_pid.items()):
        kind = procs.kind_of(pids.get(pid, ""))
        total = sum(types.values())
        sockets = sum(n for t, n in types.items() if t in SOCKET_TYPES)
        rows.append({"pid": pid, "kind": kind, "files": total, "sockets": sockets, "types": dict(sorted(types.items()))})
        entry = kinds.setdefault(kind, {"files": 0, "sockets": 0})
        entry["files"] += total
        entry["sockets"] += sockets
    return {"total": sum(r["files"] for r in rows), "sockets": sum(r["sockets"] for r in rows), "kinds": kinds,
            "pids": rows}


def assertions(pids: set[int]) -> dict:
    """`pmset -g assertions` lines owned by `pids` ("pid 123(name): [0x...] 00:01:02 Type named: ...")."""
    out = subprocess.run(["pmset", "-g", "assertions"], capture_output=True, text=True).stdout
    lines = [line.strip() for line in out.splitlines()
             if (m := re.search(r"\bpid (\d+)\(", line)) and int(m.group(1)) in pids]
    return {"lines": lines, "can_sleep": not any(kind in line for line in lines for kind in PREVENTS_SLEEP)}


def memory(pids: dict[int, str]) -> dict:
    rss = procs.resident_mb()
    kinds: dict[str, dict] = {}
    total = {"rss_mb": 0.0, "footprint_mb": 0.0, "processes": 0}
    for pid, cmd in pids.items():
        got = procs.counters(pid)
        if got is None:
            continue
        foot, res = got[3] / procs.MB, rss.get(pid) or 0.0
        entry = kinds.setdefault(procs.kind_of(cmd), {"n": 0, "rss_mb": 0.0, "footprint_mb": 0.0})
        entry["n"] += 1
        entry["rss_mb"] += res
        entry["footprint_mb"] += foot
        total["rss_mb"] += res
        total["footprint_mb"] += foot
        total["processes"] += 1
    rounded = lambda d: {k: round(v, 1) if isinstance(v, float) else v for k, v in d.items()}  # noqa: E731
    return {**rounded(total), "kinds": {k: rounded(v) for k, v in sorted(kinds.items(), key=lambda kv: -kv[1]["footprint_mb"])}}


def measure(app: str, pid: int, seconds: float, arm: str, state: str) -> int:
    inst = instance(app, pid)
    started = inst.pids()
    window = inst.window(seconds)
    found = inst.pids()
    row = {"arm": arm, "state": state, "pid": pid, "seconds": seconds, "load_1m": round(procs.load_average(), 2),
           "processes_at_start": len(started), "memory": memory(found), "window": window,
           "files": open_files(found), "sleep": assertions(set(found))}
    print("BR-IDLE", arm, json.dumps(row, sort_keys=True), flush=True)
    return 0


def stop(app: str) -> int:
    main = procs.main_pid(app)
    inst = instance(app, main or 0)
    pids = set(inst.pids())
    if main:
        pids.add(main)
    pids.discard(os.getpid())

    def alive(group):
        return {p for p in group if procs._alive(p)}

    def send(group, sig):
        for p in group:
            try:
                os.kill(p, sig)  # one positive pid at a time: never a group, never -1
            except (ProcessLookupError, PermissionError):
                pass

    def wait(group, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and alive(group):
            time.sleep(0.2)  # bench: waiting for the copy's processes to end

    if main:
        send({main}, signal.SIGTERM)
        wait({main}, 10)
    found = inst.pids()
    pids |= set(found)
    pids.discard(os.getpid())
    cleanups = {p for p, cmd in found.items() if procs.CLONE_CLEANUP in cmd}
    rest = alive(pids - cleanups)
    send(rest, signal.SIGTERM)
    wait(rest, 5)
    killed = alive(rest)
    send(killed, signal.SIGKILL)
    wait(cleanups, procs.CLONE_CLEANUP_WAIT_S)
    send(alive(cleanups), signal.SIGKILL)
    wait(pids, 5)
    left = sorted(alive(pids))
    print("BR-STOP", json.dumps({"app": app, "main": main, "pids": len(pids), "sigkill": len(killed), "left": left}),
          flush=True)
    return 1 if left else 0


def main(argv: list[str]) -> int:
    if len(argv) == 6 and argv[0] == "measure":
        return measure(argv[1], int(argv[2]), float(argv[3]), argv[4], argv[5])
    if len(argv) == 2 and argv[0] == "stop":
        return stop(argv[1])
    print(__doc__.splitlines()[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
