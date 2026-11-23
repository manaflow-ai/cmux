#!/usr/bin/env python3
"""Machine load for the stress bench (scripts/cmux-next/stress-bench.py): CPU and thread starvation, and memory
pressure up to swap. Every load is a child process of the caller, ends by itself at its deadline, and ends when
its parent goes away, so a cancelled step leaves nothing running.

  stress_load.py cpu --procs P --threads T --seconds S
      P processes with T threads each, every thread hashing a 1 MiB buffer in a loop (hashlib releases the GIL,
      so each thread really holds a core). P x T threads beside the app is the starved Mac: the scheduler
      has more runnable threads than cores, and the app's main thread and render threads wait their turn.

  stress_load.py memory --mb N --seconds S [--step-mb 256] [--touch-seconds 2]
      Allocates N MiB of incompressible pages (each MiB its own copy of random bytes), in steps, and writes one
      byte per page every --touch-seconds so the pages stay dirty and in use: past the free RAM the kernel
      compresses and then swaps. Prints one JSON line per step: {"allocated_mb": ..., "seconds": ...}.

Importable: ``start_cpu(procs, threads, seconds)`` and ``start_memory(mb, seconds)`` return the Popen of the load;
``stop(process)`` ends it (the caller's own child only).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import threading
import time

PAGE = 4096
MIB = 1 << 20


def _watch_parent(parent: int, deadline: float) -> None:
    """Ends this process at its deadline or when the parent that started it is gone."""
    while time.monotonic() < deadline:  # bounded by the load's own deadline
        if os.getppid() != parent:
            os._exit(0)
        time.sleep(0.5)
    os._exit(0)


def _spin(deadline: float) -> None:
    block = os.urandom(MIB)
    while time.monotonic() < deadline:  # bounded by the load's own deadline
        hashlib.sha256(block).digest()


def cpu_worker(threads: int, seconds: float, parent: int) -> None:
    deadline = time.monotonic() + seconds
    for _ in range(max(1, threads)):
        threading.Thread(target=_spin, args=(deadline,), daemon=True).start()
    _watch_parent(parent, deadline)


def cpu(procs: int, threads: int, seconds: float) -> None:
    """The cpu load's own process: starts `procs` workers (its children) and waits for them."""
    me = os.getpid()
    children = [subprocess.Popen([sys.executable, os.path.abspath(__file__), "cpu-worker", "--threads", str(threads),
                                  "--seconds", str(seconds), "--parent", str(me)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
             for _ in range(max(1, procs))]
    print(json.dumps({"cpu_procs": len(children), "threads_each": threads, "pids": [c.pid for c in children]}), flush=True)
    parent = os.getppid()
    deadline = time.monotonic() + seconds + 5
    try:
        while time.monotonic() < deadline and any(c.poll() is None for c in children):
            if os.getppid() != parent:
                break
            time.sleep(0.5)
    finally:
        for child in children:  # this process's own workers, by handle
            if child.poll() is None:
                child.terminate()
        for child in children:
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()


def memory(mb: int, seconds: float, step_mb: int = 256, touch_seconds: float = 2.0) -> None:
    parent = os.getppid()
    deadline = time.monotonic() + seconds
    threading.Thread(target=_watch_parent, args=(parent, deadline), daemon=True).start()
    seed = os.urandom(MIB)
    blocks: list[bytearray] = []
    start = time.monotonic()
    while len(blocks) < mb and time.monotonic() < deadline:
        for _ in range(min(step_mb, mb - len(blocks))):
            block = bytearray(seed)
            # Each MiB differs from the others (a counter in every page), so no page compresses or dedups.
            stamp = len(blocks).to_bytes(8, "little")
            for offset in range(0, MIB, PAGE):
                block[offset:offset + 8] = stamp
            blocks.append(block)
        print(json.dumps({"allocated_mb": len(blocks), "seconds": round(time.monotonic() - start, 2)}), flush=True)
    print(json.dumps({"allocated_mb": len(blocks), "done": True, "seconds": round(time.monotonic() - start, 2)}), flush=True)
    tick = 0
    while time.monotonic() < deadline:  # bounded by the load's own deadline
        tick = (tick + 1) & 0xFF
        for block in blocks:
            for offset in range(8, MIB, PAGE):
                block[offset] = tick
            if time.monotonic() >= deadline:
                break
        time.sleep(touch_seconds)
    os._exit(0)


def start_cpu(procs: int, threads: int, seconds: float) -> subprocess.Popen:
    return subprocess.Popen([sys.executable, os.path.abspath(__file__), "cpu", "--procs", str(procs),
                             "--threads", str(threads), "--seconds", str(seconds)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True)


def start_memory(mb: int, seconds: float, step_mb: int = 256) -> subprocess.Popen:
    return subprocess.Popen([sys.executable, os.path.abspath(__file__), "memory", "--mb", str(mb),
                             "--seconds", str(seconds), "--step-mb", str(step_mb)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True)


def stop(process: subprocess.Popen | None) -> None:
    """Ends a load this caller started (its own Popen; its workers end with it)."""
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("cpu")
    c.add_argument("--procs", type=int, default=os.cpu_count() or 8)
    c.add_argument("--threads", type=int, default=8)
    c.add_argument("--seconds", type=float, default=120)
    w = sub.add_parser("cpu-worker")
    w.add_argument("--threads", type=int, required=True)
    w.add_argument("--seconds", type=float, required=True)
    w.add_argument("--parent", type=int, required=True)
    m = sub.add_parser("memory")
    m.add_argument("--mb", type=int, required=True)
    m.add_argument("--seconds", type=float, default=120)
    m.add_argument("--step-mb", type=int, default=256)
    m.add_argument("--touch-seconds", type=float, default=2.0)
    args = parser.parse_args()
    if args.mode == "cpu":
        cpu(args.procs, args.threads, args.seconds)
    elif args.mode == "cpu-worker":
        cpu_worker(args.threads, args.seconds, args.parent)
    else:
        memory(args.mb, args.seconds, args.step_mb, args.touch_seconds)


if __name__ == "__main__":
    main()
