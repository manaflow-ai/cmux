#!/usr/bin/env python3
"""A bounded memory hog for the Austin's-day scenario: it pushes a Mac into swap and never kills it.

  hog.py --swap-gb 6 --deadline UNIX_TIME [--floor 12] [--resume 20] [--max-fraction 0.9] [--log FILE]

It allocates 256 MiB chunks of mostly random bytes (each 4 MiB block starts with fresh random bytes
and repeats a shared random tail, so the compressor gains little) and writes one byte every 8 pages of
a few chunks each second, so its pages stay in use and the system must swap other
memory (the app's, the daemon's, the agents') to keep them. It grows until swap used is --swap-gb
above what it was at the start, or until the kernel's free-memory level (kern.memorystatus_level,
0-100) drops to --floor; below --floor it frees chunks until the level is back at --resume. It
never holds more than --max-fraction of physical memory. It exits by itself at --deadline (and on
SIGTERM, SIGINT or SIGHUP) and frees everything; the caller also ends it by its own pid.
Each second it writes one JSON line: {"t", "held_mb", "swap_used_mb", "level"}.
"""
import argparse
import json
import mmap
import os
import random
import re
import signal
import subprocess
import sys
import time

CHUNK = 256 << 20
PAGE = 16384


def sysctl(name):
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def swap_used_mb():
    found = re.search(r"used = ([0-9.]+)M", sysctl("vm.swapusage"))
    return float(found.group(1)) if found else 0.0


def level():
    try:
        return int(sysctl("kern.memorystatus_level"))
    except ValueError:
        return 100


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swap-gb", type=float, default=6.0)
    parser.add_argument("--deadline", type=float, required=True)
    parser.add_argument("--floor", type=int, default=12)
    parser.add_argument("--resume", type=int, default=20)
    parser.add_argument("--max-fraction", type=float, default=0.9)
    parser.add_argument("--log", default=None)
    opts = parser.parse_args()
    stop = {"now": False}
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: stop.update(now=True))
    physical = int(sysctl("hw.memsize") or 0) or (16 << 30)
    cap = int(physical * opts.max_fraction) // CHUNK
    start_swap = swap_used_mb()
    chunks = []
    seed = os.urandom(CHUNK // 64)
    log = open(opts.log, "a") if opts.log else None
    next_report = 0.0
    while not stop["now"] and time.time() < opts.deadline:
        free_level = level()
        grown = swap_used_mb() - start_swap >= opts.swap_gb * 1024
        if free_level <= opts.floor:
            # Too close to the edge: give memory back until the level is at --resume.
            while chunks and level() < opts.resume and not stop["now"]:
                chunks.pop().close()
                time.sleep(0.2)
        elif not grown and len(chunks) < cap:
            chunk = mmap.mmap(-1, CHUNK)
            # Random bytes per 1/64 of the chunk, each block shifted: no two pages alike.
            for block in range(64):
                chunk[block * len(seed):(block + 1) * len(seed)] = os.urandom(16) + seed[16:]
            chunks.append(chunk)
        # Keep the pages in use: one byte per page of a few random chunks.
        for chunk in random.sample(chunks, min(4, len(chunks))):
            for offset in range(0, CHUNK, PAGE * 8):
                chunk[offset] = (chunk[offset] + 1) & 0xFF
        now = time.time()
        if now >= next_report:
            next_report = now + 1
            line = {"t": round(now, 3), "held_mb": len(chunks) * (CHUNK >> 20), "swap_used_mb": swap_used_mb(), "level": free_level}
            if log:
                log.write(json.dumps(line) + "\n")
                log.flush()
        if grown or free_level <= opts.floor or len(chunks) >= cap:
            time.sleep(1)
    for chunk in chunks:
        chunk.close()
    if log:
        log.write(json.dumps({"t": round(time.time(), 3), "held_mb": 0, "released": True}) + "\n")


if __name__ == "__main__":
    sys.exit(main())
