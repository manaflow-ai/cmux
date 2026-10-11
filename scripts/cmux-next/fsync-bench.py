#!/usr/bin/env python3
"""Cost of fsync, F_FULLFSYNC and F_BARRIERFSYNC on this disk (40 x 4 KiB writes each)."""
import os, fcntl, time, tempfile
d = tempfile.mkdtemp(dir="/tmp")
f = os.open(os.path.join(d, "x"), os.O_RDWR | os.O_CREAT)
for mode in ("fsync", "fullfsync", "barrier"):
    ts = []
    for i in range(40):
        os.pwrite(f, os.urandom(4096), (i % 16) * 4096)
        t = time.perf_counter()
        if mode == "fsync": os.fsync(f)
        elif mode == "fullfsync": fcntl.fcntl(f, 51)
        else: fcntl.fcntl(f, 85)  # F_BARRIERFSYNC
        ts.append((time.perf_counter() - t) * 1000)
    ts.sort(); print(mode, "p50 %.2f p95 %.2f ms" % (ts[20], ts[37]))
