#!/usr/bin/env python3
# From feat-cmux-next scripts/cmux-next/austins-day/hog.py (the Austin's-day harness, #28077, merged 2026-10-31 as
# 49cdc9a45da) for the dogfood smoke gate on perf/chrome-parity, which does not have that folder yet. Changed here
# (smoke-hog, 2026-11-02): the cap of --max-fraction of physical memory stopped the hog on the 16 GB M6 minis at
# 14.25 GB, about 4 s after its start, with the free level at 21-47 (the gate needs <= 20): see the docstring.
# Run on the mini by run.py --hog-swap-gb (stock /usr/bin/python3; standard library only).
"""A bounded memory hog for the Austin's-day scenario: it pushes a Mac into swap and never kills it.

  smoke_hog.py --swap-gb 6 --deadline UNIX_TIME [--floor 12] [--resume 20] [--max-fraction 0.9]
               [--disk-reserve-gb 10] [--log FILE]

It allocates 256 MiB chunks of mostly random bytes (each 4 MiB block starts with fresh random bytes
and repeats a shared random tail, so the compressor gains little) and writes one byte every 8 pages of
a few chunks each second, so its pages stay in use and the system must swap other memory (the app's,
the daemon's, the agents') to keep them.

The kernel's free-memory level (kern.memorystatus_level, 0-100) steers it. It grows while the level is
above --floor; at or below --floor (or when the kernel says the pressure is critical) it frees chunks
until the level is back at --resume. So it holds the mini in the band --floor .. --resume while it runs.
It stops growing (and holds) when swap used is --swap-gb above what it was at the start.

Why the level, not a size: the kernel moves the hog's idle pages to swap, so a hog of a fixed size gives
memory back to the system within seconds. The old fixed cap (--max-fraction of physical memory, 14.25 GB
on a 16 GB mini) stopped the hog with the level at 21-47 and swap only +6..8 GB (the smoke gate's SMOKE ENV
"no memory pressure", 2026-11-02). Now the hog may hold more than physical memory, up to:
    --max-fraction of physical memory + the swap it may add (--swap-gb, less --disk-reserve-gb of free disk).
Without a readable level it never goes past --max-fraction of physical memory (no edge to steer by).

Limits, so it never kills the mini: the level band above; a critical kernel pressure level
(kern.memorystatus_vm_pressure_level 4) gives memory back as at --floor; free disk on the swap volume under
--disk-reserve-gb stops the growth and under half of it gives memory back (swap needs the disk); near the
band it adds one chunk per PACE_SECONDS, so the kernel's level keeps up. It exits by itself at --deadline (and
on SIGTERM, SIGINT or SIGHUP) and frees everything; the caller also ends it by its own pid.

Log (--log), one JSON line each:
  - at the start: {"t", "start": true, "physical_mb", "cap_mb", "soft_cap_mb", "swap_start_mb", "disk_free_gb",
    "level", "vm_pressure", "floor", "resume", "swap_gb"};
  - each second: {"t", "held_mb", "swap_used_mb", "level", "vm_pressure", "compressed_mb", "disk_free_gb", "action"}
    ("vm_pressure": the kernel's pressure level, as `memory_pressure` prints it: 1 normal, 2 warning, 4 critical;
    "action": grow, hold or free);
  - at the end: {"t", "held_mb": 0, "released": true, "level_min", "vm_pressure_max", "held_mb_max",
    "swap_growth_mb", "seconds_at_or_below_resume"}: the level the hog reached.
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
GIB = 1 << 30
MIB = 1 << 20
# Near the band (level <= resume + PACE_BAND) the hog adds at most one chunk per PACE_SECONDS (2.5 GB/s): the kernel's
# level lags the allocation, and 256 MiB is 1.6 levels on a 16 GB mini. The pace must stay above the rate at which the
# kernel moves idle hog pages to swap (about 1.4 GB/s seen on cmux23, 2026-11-02), or the level never reaches the band.
PACE_BAND = 10
PACE_SECONDS = 0.1
CRITICAL = 4
SWAP_VOLUME = "/System/Volumes/VM"
SYSCTLS = ("kern.memorystatus_level", "kern.memorystatus_vm_pressure_level", "vm.swapusage", "vm.compressor_bytes_used")


def sysctls(names):
    """{name: value text} of the sysctl names that the kernel has (one `sysctl` call; an unknown name is left out)."""
    try:
        out = subprocess.run(["sysctl", *names], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    found = {}
    for line in out.splitlines():
        name, sep, value = line.partition(":")
        if sep and name.strip() in names:
            found[name.strip()] = value.strip()
    return found


def number(text):
    try:
        return int(text)
    except (TypeError, ValueError):
        return None


def parse_swap_used_mb(text):
    found = re.search(r"used = ([0-9.]+)M", text or "")
    return float(found.group(1)) if found else 0.0


def sample():
    """The kernel's memory state now: level (0-100 or None), vm_pressure (1/2/4 or None), swap_used_mb, compressed_mb."""
    s = sysctls(SYSCTLS)
    compressed = number(s.get("vm.compressor_bytes_used"))
    return {"level": number(s.get("kern.memorystatus_level")),
            "vm_pressure": number(s.get("kern.memorystatus_vm_pressure_level")),
            "swap_used_mb": parse_swap_used_mb(s.get("vm.swapusage")),
            "compressed_mb": round(compressed / MIB) if compressed is not None else None}


def disk_free_bytes(path=SWAP_VOLUME):
    for p in (path, "/"):
        try:
            st = os.statvfs(p)
            return st.f_bavail * st.f_frsize
        except OSError:
            continue
    return None


def caps(physical, max_fraction, swap_gb, disk_free, disk_reserve_gb):
    """(soft, hard) caps in chunks: soft = max_fraction of physical memory (the old cap, kept when the level cannot be
    read); hard = soft + the swap the hog may add: swap_gb, less disk_reserve_gb of the free disk (never negative)."""
    soft = int(physical * max_fraction) // CHUNK
    room = swap_gb * GIB
    if disk_free is not None:
        room = min(room, max(0, disk_free - disk_reserve_gb * GIB))
    return soft, soft + int(room) // CHUNK


def plan(s, held, soft_cap, hard_cap, grown, disk_free, opts, backing_off):
    """(action, backing_off) for one step: "free" (give one chunk back), "grow" (add one chunk) or "hold".
    S: sample(); HELD: chunks held; GROWN: swap is --swap-gb above the start; BACKING_OFF: the hog is giving memory back
    since the level reached --floor (until --resume)."""
    level, critical = s.get("level"), (s.get("vm_pressure") or 0) >= CRITICAL
    reserve = opts.disk_reserve_gb * GIB
    disk_low = disk_free is not None and disk_free < reserve / 2
    if level is not None and level <= opts.floor or critical or disk_low:
        backing_off = True
    elif backing_off and (level is None or level >= opts.resume):
        backing_off = False
    if backing_off:
        return ("free" if held else "hold"), backing_off
    cap = soft_cap if level is None else hard_cap
    if grown or held >= cap or (disk_free is not None and disk_free < reserve):
        return "hold", backing_off
    return "grow", backing_off


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swap-gb", type=float, default=6.0)
    parser.add_argument("--deadline", type=float, required=True)
    parser.add_argument("--floor", type=int, default=12)
    parser.add_argument("--resume", type=int, default=20)
    parser.add_argument("--max-fraction", type=float, default=0.9)
    parser.add_argument("--disk-reserve-gb", type=float, default=10.0)
    parser.add_argument("--log", default=None)
    opts = parser.parse_args()
    stop = {"now": False}
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: stop.update(now=True))
    physical = number(sysctls(("hw.memsize",)).get("hw.memsize")) or (16 << 30)
    first = sample()
    start_swap = first["swap_used_mb"]
    disk_start = disk_free_bytes()
    soft_cap, hard_cap = caps(physical, opts.max_fraction, opts.swap_gb, disk_start, opts.disk_reserve_gb)
    chunks = []
    seed = os.urandom(CHUNK // 64)
    log = open(opts.log, "a") if opts.log else None

    def write(row):
        if log:
            log.write(json.dumps(row) + "\n")
            log.flush()

    gb = lambda b: round(b / GIB, 1) if b is not None else None
    write({"t": round(time.time(), 3), "start": True, "physical_mb": physical // MIB, "cap_mb": hard_cap * (CHUNK >> 20),
           "soft_cap_mb": soft_cap * (CHUNK >> 20), "swap_start_mb": start_swap, "disk_free_gb": gb(disk_start),
           "level": first["level"], "vm_pressure": first["vm_pressure"], "floor": opts.floor, "resume": opts.resume,
           "swap_gb": opts.swap_gb})
    reached = {"level_min": None, "vm_pressure_max": None, "held_max": 0, "swap_max": start_swap, "in_band_s": 0}
    backing_off, next_report, last_grow = False, 0.0, 0.0
    while not stop["now"] and time.time() < opts.deadline:
        s = sample()
        disk_free = disk_free_bytes()
        grown = s["swap_used_mb"] - start_swap >= opts.swap_gb * 1024
        action, backing_off = plan(s, len(chunks), soft_cap, hard_cap, grown, disk_free, opts, backing_off)
        now = time.time()
        if action == "grow" and s["level"] is not None and s["level"] <= opts.resume + PACE_BAND \
                and now - last_grow < PACE_SECONDS:
            action = "hold"  # paced near the band; the next step grows
        if action == "free":
            chunks.pop().close()
        elif action == "grow":
            chunk = mmap.mmap(-1, CHUNK)
            # Random bytes per 1/64 of the chunk, each block shifted: no two pages alike.
            for block in range(64):
                chunk[block * len(seed):(block + 1) * len(seed)] = os.urandom(16) + seed[16:]
            chunks.append(chunk)
            last_grow = time.time()
        # Keep the pages in use: one byte per page of a few random chunks.
        for chunk in random.sample(chunks, min(4, len(chunks))):
            for offset in range(0, CHUNK, PAGE * 8):
                chunk[offset] = (chunk[offset] + 1) & 0xFF
        if s["level"] is not None:
            reached["level_min"] = s["level"] if reached["level_min"] is None else min(reached["level_min"], s["level"])
        if s["vm_pressure"] is not None:
            reached["vm_pressure_max"] = max(reached["vm_pressure_max"] or 0, s["vm_pressure"])
        reached["held_max"] = max(reached["held_max"], len(chunks))
        reached["swap_max"] = max(reached["swap_max"], s["swap_used_mb"])
        now = time.time()
        if now >= next_report:
            next_report = now + 1
            if s["level"] is not None and s["level"] <= opts.resume:
                reached["in_band_s"] += 1
            write({"t": round(now, 3), "held_mb": len(chunks) * (CHUNK >> 20), "swap_used_mb": s["swap_used_mb"],
                   "level": s["level"], "vm_pressure": s["vm_pressure"], "compressed_mb": s["compressed_mb"],
                   "disk_free_gb": gb(disk_free), "action": action})
        if action == "free":
            time.sleep(0.2)
        elif action == "hold":
            time.sleep(PACE_SECONDS if not grown and len(chunks) < hard_cap else 1)
    for chunk in chunks:
        chunk.close()
    write({"t": round(time.time(), 3), "held_mb": 0, "released": True, "level_min": reached["level_min"],
           "vm_pressure_max": reached["vm_pressure_max"], "held_mb_max": reached["held_max"] * (CHUNK >> 20),
           "swap_growth_mb": round(reached["swap_max"] - start_swap, 1), "seconds_at_or_below_resume": reached["in_band_s"]})


if __name__ == "__main__":
    sys.exit(main())
