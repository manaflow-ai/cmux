#!/usr/bin/env python3
# Copied from leo-workspace machines/vm-net/syn_retry.py @9a65c0297 (the fleet copy); keep the two the same.
"""syn_retry: a lost first SYN costs MS milliseconds on this machine, where the kernel's own timer makes it cost 1 s.

    syn_retry.py attach MS   (root) every TCP connection's first retransmit timer is MS ms; a no-op when already so
    syn_retry.py detach      (root) back to the kernel's 1 s
    syn_retry.py status      exit 0 and "attached MS" when in place, 3 and "not attached" otherwise (no root needed)

Linux fixes the first SYN's retransmit timer at 1 s (TCP_TIMEOUT_INIT): no sysctl and no route option moves it (route
`rto_min` and `tcp_rto_min_us` were both measured, 2026-11-27: the resend still left at 1023 ms). The one knob is a
sock_ops BPF program on a cgroup, which the kernel asks (BPF_SOCK_OPS_TIMEOUT_INIT) for the timer of each new
connection. This file holds that program as 6 instructions and loads it with bpf(2) from the standard library, so a VM
needs no clang, no bpftool and no kernel headers. Attached to the root cgroup it covers every process.

Measured 2026-11-27 in a network namespace, 500 connects each (kernel 7.0, HZ 1000):
    first SYN of every connect dropped   1024 ms -> 208 ms per connect
    2% of SYNs dropped                   7 connects over 900 ms -> 0
    20% of SYNs dropped                  84 over 900 ms -> 1
    400 ms round trip, nothing dropped   one extra SYN per connect, every connect still 400 ms, starting window 10
The extra SYN on a path slower than MS is harmless while TCP timestamps are on (the kernel's default), since they tell
the kernel the resend was not needed; with timestamps off and two or more resends the starting window drops to 1 packet.

The kernel takes the answer in jiffies, so the kernel's HZ must be known: its config file, or, on a kernel that ships
none (a Freestyle guest's 6.1.102: the fix was skipped there and its resends still cost 1 s, 2026-11-27), measured by
root from /proc/timer_list's jiffies over 0.3 s and snapped to 100, 250, 300 or 1000. A kernel whose HZ is still
unknown is left alone. The attachment lasts until reboot or `detach`; vm-net-syn-retry.service attaches it at each boot.
"""
from __future__ import annotations

import ctypes
import gzip
import os
import platform
import re
import struct
import sys
import time
from pathlib import Path

CGROUP = "/sys/fs/cgroup"
PIN_DIR = "/sys/fs/bpf/vm-net-syn-retry"
PIN = PIN_DIR + "/prog"
MARK = "/run/vm-net-baseline/syn-retry"  # holds MS while attached; /run empties at reboot, as the attachment does
NR_BPF = {"x86_64": 321, "aarch64": 280}
BPF_PROG_LOAD, BPF_OBJ_PIN, BPF_OBJ_GET, BPF_PROG_ATTACH, BPF_PROG_DETACH = 5, 6, 7, 8, 9
PROG_TYPE_SOCK_OPS, CGROUP_SOCK_OPS, ALLOW_MULTI = 13, 3, 2


def ins(code: int, dst: int = 0, src: int = 0, off: int = 0, imm: int = 0) -> bytes:
    return struct.pack("<BBhi", code, (src << 4) | dst, off, imm)


def prog(jiffies: int) -> bytes:
    return b"".join([
        ins(0x61, 2, 1, 0),          # r2 = ctx->op
        ins(0x55, 2, 0, 2, 1),       # if r2 != BPF_SOCK_OPS_TIMEOUT_INIT goto +2
        ins(0xb7, 3, 0, 0, jiffies),  # r3 = the timer, in jiffies
        ins(0x63, 1, 3, 4),          # ctx->reply = r3
        ins(0xb7, 0, 0, 0, 1),       # r0 = 1
        ins(0x95),                   # exit
    ])


def hz_in(text: str) -> int | None:
    m = re.search(r"^CONFIG_HZ=(\d+)$", text, re.M)
    return int(m.group(1)) if m else None


def kernel_hz() -> int | None:
    rel = os.uname().release
    for path in ("/boot/config-" + rel, "/lib/modules/%s/config" % rel, "/lib/modules/%s/build/.config" % rel):
        try:
            hz = hz_in(Path(path).read_text(encoding="ascii", errors="replace"))
        except OSError:
            continue
        if hz:
            return hz
    try:
        hz = hz_in(gzip.decompress(Path("/proc/config.gz").read_bytes()).decode("ascii", "replace"))
    except OSError:
        hz = None
    return hz or hz_measured()


HZ_CHOICES = (100, 250, 300, 1000)


def jiffies_in(text: str) -> int | None:
    m = re.search(r"^jiffies: (\d+)$", text, re.M)
    return int(m.group(1)) if m else None


def hz_snap(ticks: int, seconds: float) -> int | None:
    """The kernel HZ that `ticks` jiffies over `seconds` came from, when it is within 10% of one a kernel can have."""
    if seconds <= 0:
        return None
    rate = ticks / seconds
    best = min(HZ_CHOICES, key=lambda hz: abs(rate - hz))
    return best if abs(rate - best) <= best * 0.1 else None


def hz_measured(window: float = 0.3) -> int | None:
    """HZ from the jiffies counter in /proc/timer_list (root only), read twice `window` s apart."""
    def read() -> tuple[int | None, float]:
        try:
            text = Path("/proc/timer_list").read_text(encoding="ascii", errors="replace")
        except OSError:
            return None, 0.0
        return jiffies_in(text), time.monotonic()
    j0, t0 = read()
    if j0 is None:
        return None
    time.sleep(window)
    j1, t1 = read()
    return None if j1 is None else hz_snap(j1 - j0, t1 - t0)


def available() -> tuple[bool, str]:
    if not sys.platform.startswith("linux") or platform.machine() not in NR_BPF:
        return False, "no bpf(2) number known for %s %s" % (sys.platform, platform.machine())
    if not Path(CGROUP, "cgroup.controllers").exists():
        return False, "%s is not cgroup v2" % CGROUP
    if not kernel_hz():
        return False, "kernel %s's HZ cannot be read (no config file)" % os.uname().release
    return True, "cgroup v2 and HZ %d" % kernel_hz()


def bpf(cmd: int, attr: bytes) -> int:
    libc = ctypes.CDLL(None, use_errno=True)
    buf = ctypes.create_string_buffer(attr, 144)
    r = libc.syscall(NR_BPF[platform.machine()], cmd, buf, len(buf))
    if r < 0:
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
    return r


def attached() -> int | None:
    try:
        return int(Path(MARK).read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return None


def detach() -> None:
    if os.path.exists(PIN):
        name = ctypes.create_string_buffer(PIN.encode())
        fd = bpf(BPF_OBJ_GET, struct.pack("<QI", ctypes.addressof(name), 0))
        cfd = os.open(CGROUP, os.O_RDONLY | os.O_DIRECTORY)
        try:
            bpf(BPF_PROG_DETACH, struct.pack("<IIII", cfd, fd, CGROUP_SOCK_OPS, 0))
        except OSError:
            pass  # pinned but no longer attached: the pin is all that is left to remove
        os.close(cfd)
        os.close(fd)
        os.unlink(PIN)
    if os.path.exists(MARK):
        os.unlink(MARK)


def attach(ms: int) -> str:
    ok, why = available()
    if not ok:
        raise OSError(why)
    if attached() == ms and os.path.exists(PIN):
        return "already attached %d" % ms
    detach()
    jiffies = max(1, round(ms * kernel_hz() / 1000))
    code = prog(jiffies)
    cbuf = ctypes.create_string_buffer(code, len(code))
    lic = ctypes.create_string_buffer(b"GPL")
    fd = bpf(BPF_PROG_LOAD, struct.pack("<IIQQIIQI", PROG_TYPE_SOCK_OPS, len(code) // 8, ctypes.addressof(cbuf),
                                        ctypes.addressof(lic), 0, 0, 0, 0))
    os.makedirs(PIN_DIR, mode=0o700, exist_ok=True)
    name = ctypes.create_string_buffer(PIN.encode())
    bpf(BPF_OBJ_PIN, struct.pack("<QI", ctypes.addressof(name), fd))
    cfd = os.open(CGROUP, os.O_RDONLY | os.O_DIRECTORY)
    bpf(BPF_PROG_ATTACH, struct.pack("<IIII", cfd, fd, CGROUP_SOCK_OPS, ALLOW_MULTI))
    os.close(cfd)
    os.makedirs(os.path.dirname(MARK), mode=0o755, exist_ok=True)
    Path(MARK).write_text("%d\n" % ms, encoding="ascii")
    os.chmod(MARK, 0o644)
    return "attached %d (%d jiffies at HZ %d)" % (ms, jiffies, kernel_hz())


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else ""
    try:
        if cmd == "attach" and len(argv) == 2:
            print(attach(int(argv[1])))
            return 0
        if cmd == "detach":
            detach()
            print("detached")
            return 0
    except OSError as e:
        print("syn_retry: %s: %s" % (cmd, e), file=sys.stderr)
        return 1
    if cmd == "status":
        ms = attached()
        print("attached %d" % ms if ms else "not attached")
        return 0 if ms else 3
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
