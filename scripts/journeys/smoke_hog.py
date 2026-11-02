#!/usr/bin/env python3
# From feat-cmux-next scripts/cmux-next/austins-day/hog.py (the Austin's-day harness, #28077, merged 2026-10-31 as
# 49cdc9a45da) for the dogfood smoke gate on perf/chrome-parity, which does not have that folder yet. Changed here
# (smoke-hog, 2026-11-02): a wired part steers the kernel's free level into the band the gate asks; see "Why" below.
# Run on the mini by run.py --hog-swap-gb (stock /usr/bin/python3; standard library only).
"""A bounded memory hog for the Austin's-day scenario: it pushes a Mac into swap and never kills it.

  smoke_hog.py --swap-gb 6 --deadline UNIX_TIME [--floor 12] [--target 16] [--resume 20] [--max-fraction 0.9]
               [--wire-fraction 0.5] [--disk-reserve-gb 10] [--log FILE]

Two parts:
  - The swap part (the original hog): 256 MiB chunks of mostly random bytes (each 4 MiB block starts with
    fresh random bytes and repeats a shared random tail; the compressor works per page, so it gains little).
    It writes one byte every 8 pages of a few chunks each second. It grows until swap used is --swap-gb above
    the start, the level is at --floor, or it holds --max-fraction of physical memory. The kernel compresses
    and swaps it, and other memory (the app's, the daemon's, the agents') with it.
  - The wired part: chunks of the same bytes, locked in memory (mlock). The kernel can neither compress nor
    swap them, so each one lowers the free level by its size at once. When the swap part has stopped growing,
    the wired part grows (one chunk per PACE_SECONDS) while the level is above --target and holds there.

The free level is the kernel's kern.memorystatus_level (0-100), the "System-wide memory free percentage" of
`memory_pressure`. At or below --floor (or when the kernel says critical for CRITICAL_SECONDS in a row) the hog
gives chunks back, the wired ones first, until the level is at --resume again. While the kernel says critical,
neither part grows. A sample that cannot read the level changes nothing (hold).

Why (the smoke gate's SMOKE ENV "no memory pressure (the hog)", 44 rounds on cmux18/19/21/22/23 of 2026-11-02,
and hog-only runs): on macOS the level counts free, active, inactive and speculative pages as available; only
wired memory and the memory the compressor holds lower it. A hog of swappable memory fills the compressor, and
then the kernel moves the compressed memory to swap as fast as the hog makes more, so the level stays at about
30-40: at the old cap (0.9 x 16 GB = 14.25 GB, reached in about 4 s) the rounds had a lowest level of 21-47, and
a hog of 25 GB on cmux21 (swap +16 GB) stayed at 31-39. The gate needs <= 20. Only memory that the kernel cannot
compress or swap lowers the level to a known value, so the wired part steers it.

Limits, so it never kills the mini: the band above (the kernel keeps --floor percent of the memory free); the
wired part at most --wire-fraction of physical memory and 0.8 of vm.user_wire_limit, none when the level cannot
be read; a refused mlock stops the wired part; free disk on the swap volume under --disk-reserve-gb stops the
growth, under half of it gives memory back (swap needs the disk). The kernel unlocks and frees all of it when
the process ends. It exits by itself at --deadline (and on SIGTERM, SIGINT or SIGHUP) and frees everything; the
caller also ends it by its own pid.

Log (--log), one JSON line each:
  - at the start: {"t", "start": true, "physical_mb", "cap_mb", "wire_cap_mb", "swap_start_mb", "disk_free_gb",
    "level", "vm_pressure", "floor", "target", "resume", "swap_gb"};
  - each second: {"t", "held_mb", "wired_mb", "swap_used_mb", "level", "vm_pressure", "compressed_mb",
    "disk_free_gb", "action"} ("held_mb": both parts; "vm_pressure": the kernel's pressure level, 1 normal,
    2 warning, 4 critical; "action": grow, wire, hold or free; "wire_error" once if an mlock was refused);
  - at the end: {"t", "held_mb": 0, "released": true, "level_min", "vm_pressure_max", "held_mb_max",
    "wired_mb_max", "swap_growth_mb", "seconds_at_or_below_resume"}: the level the hog reached.
"""
import argparse
import ctypes
import ctypes.util
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
# The wired part adds at most one chunk per PACE_SECONDS: 256 MiB is 1.6 levels on a 16 GB mini, and the kernel's
# compressor and swap move under it.
PACE_SECONDS = 0.25
CRITICAL = 4
CRITICAL_SECONDS = 5.0
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


def caps(physical, max_fraction, wire_fraction, user_wire_limit):
    """(cap, wire_cap) in chunks: the swap part's max_fraction of physical memory (the original cap), and the wired
    part's wire_fraction of physical memory, at most 0.8 of the kernel's per-process wire limit (if known)."""
    wire = physical * wire_fraction
    if user_wire_limit:
        wire = min(wire, user_wire_limit * 0.8)
    return int(physical * max_fraction) // CHUNK, int(wire) // CHUNK


def plan(s, held, wired, cap, wire_cap, grown, disk_free, critical_for, wire_ok, opts, backing_off, steered=True):
    """(action, backing_off) for one step: "free" (give one chunk back, a wired one first), "grow" (one more chunk of
    the swap part), "wire" (one more wired chunk) or "hold". S: sample(); HELD, WIRED: chunks of each part; GROWN: swap
    is --swap-gb above the start; CRITICAL_FOR: seconds the kernel has said critical in a row; WIRE_OK: no mlock was
    refused; BACKING_OFF: the hog gives memory back since the level reached --floor (until --resume); STEERED: the
    level could be read at the start. A sample that cannot read the level (a failed sysctl, likely at the edge) then
    changes nothing: hold, and keep the back-off as it is (a back-off goes on freeing; a nearly full disk starts one)."""
    level, critical = s.get("level"), (s.get("vm_pressure") or 0) >= CRITICAL
    reserve = opts.disk_reserve_gb * GIB
    disk_low = disk_free is not None and disk_free < reserve / 2
    if steered and level is None:
        # The disk is read by statvfs, not sysctl: a nearly full disk still starts or keeps a back-off.
        backing_off = backing_off or disk_low
        return ("free" if backing_off and held + wired else "hold"), backing_off
    if (level is not None and level <= opts.floor) or critical_for >= CRITICAL_SECONDS or disk_low:
        backing_off = True
    elif backing_off and not critical and (level is None or level >= opts.resume):
        backing_off = False
    if backing_off:
        return ("free" if held + wired else "hold"), backing_off
    if disk_free is not None and disk_free < reserve:
        return "hold", backing_off
    # The original hog: grows until the swap target, the floor (above) or its cap.
    if not grown and held < cap and not critical:
        return "grow", backing_off
    # Then the wired part steers the level down to --target.
    if level is not None and level > opts.target and wire_ok and wired < wire_cap and not critical:
        return "wire", backing_off
    return "hold", backing_off


class Locker(object):
    """mlock / munlock of an mmap's pages (libc through ctypes)."""

    def __init__(self):
        path = ctypes.util.find_library("c")
        self.libc = ctypes.CDLL(path, use_errno=True) if path else None
        if self.libc:
            for name in ("mlock", "munlock"):
                getattr(self.libc, name).argtypes = (ctypes.c_void_p, ctypes.c_size_t)
                getattr(self.libc, name).restype = ctypes.c_int

    def lock(self, chunk):
        """(buffer handle, None) when the chunk is wired, else (None, error text)."""
        if not self.libc:
            return None, "no libc"
        buf = (ctypes.c_char * len(chunk)).from_buffer(chunk)
        if self.libc.mlock(ctypes.addressof(buf), len(chunk)) != 0:
            error = os.strerror(ctypes.get_errno())
            del buf
            return None, error
        return buf, None

    def unlock(self, chunk, buf):
        self.libc.munlock(ctypes.addressof(buf), len(chunk))


def fill(chunk, seed):
    # Random bytes per 1/64 of the chunk, each block shifted: no two pages alike.
    block = len(seed)
    for i in range(len(chunk) // block):
        chunk[i * block:(i + 1) * block] = os.urandom(16) + seed[16:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swap-gb", type=float, default=6.0)
    parser.add_argument("--deadline", type=float, required=True)
    parser.add_argument("--floor", type=int, default=12)
    parser.add_argument("--target", type=int, default=16)
    parser.add_argument("--resume", type=int, default=20)
    parser.add_argument("--max-fraction", type=float, default=0.9)
    parser.add_argument("--wire-fraction", type=float, default=0.5)
    parser.add_argument("--disk-reserve-gb", type=float, default=10.0)
    parser.add_argument("--log", default=None)
    opts = parser.parse_args()
    if not opts.floor < opts.target < opts.resume:
        parser.error("--floor < --target < --resume")
    stop = {"now": False}
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: stop.update(now=True))
    found = sysctls(("hw.memsize", "vm.user_wire_limit"))
    physical = number(found.get("hw.memsize")) or (16 << 30)
    first = sample()
    start_swap = first["swap_used_mb"]
    disk_start = disk_free_bytes()
    cap, wire_cap = caps(physical, opts.max_fraction, opts.wire_fraction, number(found.get("vm.user_wire_limit")))
    if first["level"] is None:
        wire_cap = 0  # no level to steer by: never wire
    chunks, wired = [], []  # wired: (chunk, ctypes buffer)
    locker = Locker()
    seed = os.urandom(CHUNK // 64)
    log = open(opts.log, "a") if opts.log else None

    def write(row):
        if log:
            log.write(json.dumps(row) + "\n")
            log.flush()

    mb = lambda n: n * (CHUNK >> 20)
    gb = lambda b: round(b / GIB, 1) if b is not None else None
    write({"t": round(time.time(), 3), "start": True, "physical_mb": physical // MIB, "cap_mb": mb(cap),
           "wire_cap_mb": mb(wire_cap), "swap_start_mb": start_swap, "disk_free_gb": gb(disk_start),
           "level": first["level"], "vm_pressure": first["vm_pressure"], "floor": opts.floor, "target": opts.target,
           "resume": opts.resume, "swap_gb": opts.swap_gb})
    reached = {"level_min": None, "vm_pressure_max": None, "held_max": 0, "wired_max": 0, "swap_max": start_swap, "in_band_s": 0}
    backing_off, next_report, last_wire, critical_since, wire_error = False, 0.0, 0.0, None, None
    while not stop["now"] and time.time() < opts.deadline:
        s = sample()
        disk_free = disk_free_bytes()
        grown = s["swap_used_mb"] - start_swap >= opts.swap_gb * 1024
        mono = time.monotonic()
        if s["vm_pressure"] is not None:  # a failed sample keeps the count of critical seconds as it is
            critical_since = (critical_since or mono) if s["vm_pressure"] >= CRITICAL else None
        critical_for = mono - critical_since if critical_since is not None else 0.0
        action, backing_off = plan(s, len(chunks), len(wired), cap, wire_cap, grown, disk_free, critical_for,
                                   wire_error is None, opts, backing_off, steered=first["level"] is not None)
        if action == "wire" and mono - last_wire < PACE_SECONDS:
            action = "hold"  # paced; a later step wires
        if action == "free":
            if wired:
                chunk, buf = wired.pop()
                locker.unlock(chunk, buf)
                del buf
                chunk.close()
            else:
                chunks.pop().close()
        elif action in ("grow", "wire"):
            chunk = mmap.mmap(-1, CHUNK)
            fill(chunk, seed)
            if action == "grow":
                chunks.append(chunk)
            else:
                buf, error = locker.lock(chunk)
                last_wire = time.monotonic()
                if buf is None:
                    wire_error = error
                    chunk.close()
                    write({"t": round(time.time(), 3), "wire_error": error, "wired_mb": mb(len(wired))})
                else:
                    wired.append((chunk, buf))
                del buf  # only the list holds the export: a free can close the chunk
        # Keep the swap part's pages in use: one byte per 8 pages of a few random chunks.
        for chunk in random.sample(chunks, min(4, len(chunks))):
            for offset in range(0, CHUNK, PAGE * 8):
                chunk[offset] = (chunk[offset] + 1) & 0xFF
        if s["level"] is not None:
            reached["level_min"] = s["level"] if reached["level_min"] is None else min(reached["level_min"], s["level"])
        if s["vm_pressure"] is not None:
            reached["vm_pressure_max"] = max(reached["vm_pressure_max"] or 0, s["vm_pressure"])
        reached["held_max"] = max(reached["held_max"], len(chunks) + len(wired))
        reached["wired_max"] = max(reached["wired_max"], len(wired))
        reached["swap_max"] = max(reached["swap_max"], s["swap_used_mb"])
        now = time.time()
        if now >= next_report:
            next_report = now + 1
            if s["level"] is not None and s["level"] <= opts.resume:
                reached["in_band_s"] += 1
            write({"t": round(now, 3), "held_mb": mb(len(chunks) + len(wired)), "wired_mb": mb(len(wired)),
                   "swap_used_mb": s["swap_used_mb"], "level": s["level"], "vm_pressure": s["vm_pressure"],
                   "compressed_mb": s["compressed_mb"], "disk_free_gb": gb(disk_free), "action": action})
        if action == "free":
            time.sleep(0.2)
        elif action == "hold":
            time.sleep(PACE_SECONDS)
    while wired:
        chunk, buf = wired.pop()
        locker.unlock(chunk, buf)
        del buf
        chunk.close()
    for chunk in chunks:
        chunk.close()
    write({"t": round(time.time(), 3), "held_mb": 0, "released": True, "level_min": reached["level_min"],
           "vm_pressure_max": reached["vm_pressure_max"], "held_mb_max": mb(reached["held_max"]),
           "wired_mb_max": mb(reached["wired_max"]), "swap_growth_mb": round(reached["swap_max"] - start_swap, 1),
           "seconds_at_or_below_resume": reached["in_band_s"]})
    if log:
        log.close()


if __name__ == "__main__":
    sys.exit(main())
