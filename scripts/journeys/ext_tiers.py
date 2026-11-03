"""Core tiers of the app's main thread, with no profiler (HARNESS CORES, STATUS 7713 / 7767).

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (standard library only).

The M6 minis have three core tiers (sysctl hw.perflevel0..2: Super 2, Performance 4, Efficiency 6). xctrace's Time
Profiler names them "S Core", "P Core" and "E Core"; S (Super) is the FASTEST tier. On macOS 27 a main thread that
wakes from idle starts on the Efficiency cores and moves to Super after about 25-30 ms of continuous run (STATUS
7767, round hc-ab-xtp-1: the same with xctrace on and off). A split costs about 13 ms on Super and 26-30 ms on
Efficiency, so a frame number from a capture round is only comparable with the start tier of its turn.

proc_pidinfo(PROC_PIDTHREADCOUNTS) gives one thread's CPU time and cycles per tier (XNU recount), for a process of
the same user, with no root and no sampling interrupt. The sampler here reads the main thread (the lowest thread id
of the app's pid) every INTERVAL_MS (10 ms). At 1 ms it cost the turns it measures: in round hc-cost-1 (cmux23, 8 + 8
split runs) the turns that started on Efficiency took p50 35.0 / p95 37.4 ms with it and p50 32.0 / p95 33.5 ms without,
and 4 of 8 turns started on Super with it against 1 of 8 without; it used about 5 % of a core. The Efficiency phase
of a turn is 25-30 ms, so 10 ms still names the start tier (STATUS 7767).

ext_video uses start() / stop() / turn_tiers() for every recording (video_start .. video_stop): each film gets
<name>.tiers.json and, in <name>.meta.json, "tiers": the start tier of each HID action and key-down.

Steps (`do`), for rounds that record no video:
  tiers_start {name, seconds?: 120, interval_ms?: 10}  starts the sampler (it ends at tiers_stop or after `seconds`)
                and returns once its first reading is in.
  tiers_stop  {name}  stops it and writes <journey out>/diag-<name>.json (run.py fetches diag-*.json); the reply
                has the start tier of each journey mark set after tiers_start.
Sampler file: {"levels": ["Super", "Performance", "Efficiency"], "rows": [[uptime_ns, cpu_ms_0.., cycles_0..], ...],
"ps": the 15 busiest processes at the start}. Rows are cumulative; times are CLOCK_UPTIME_RAW (mach_absolute_time:
the clock of time.monotonic() on macOS, of the app's input journal uptimeNanos and of its frame trace).
"""
import atexit
import json
import os
import select
import subprocess
import time

D = None
# Samplers started and not stopped yet, each with its owner (the journey that started it). A journey that fails between
# video_start and video_stop leaves its sampler running (bounded by its `seconds`); the next start() of ANOTHER journey
# and the driver's exit end it. Samplers of the same journey (tiers_start "a" and "b", or tiers_start and a film) run on.
_LIVE = []
# The driver's clock (D.now() = time.monotonic()) is NOT the host clock: the minis' /usr/bin/python3 3.9.6 counts
# mach_absolute_time from the process start (0.004 s at start; hc-film-e2e-1, 2026-11-02). The app's journal
# (uptimeNanos), the frame trace and this sampler use CLOCK_UPTIME_RAW (mach_absolute_time since boot). host_seconds()
# moves a driver time (a HID t_sent, a journey mark) to the host clock; the offset is fixed for the driver process.
_HOST_CLOCK = getattr(time, "CLOCK_UPTIME_RAW", time.CLOCK_MONOTONIC)
HOST_OFFSET = time.clock_gettime(_HOST_CLOCK) - time.monotonic()


def host_seconds(driver_t):
    """A driver time (time.monotonic() of this process) on the host clock (CLOCK_UPTIME_RAW s)."""
    return driver_t + HOST_OFFSET


START_TIMEOUT = 40.0
INTERVAL_MS = 10.0  # the sampler's period (1 ms changed the turns it measured: see the module note)  # s for the sampler's first reading (its 1 + levels sysctl calls and its ps have 5 s each)

SAMPLER = r'''
import ctypes, json, os, subprocess, sys, time
pid, seconds, interval, out, stop = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]) / 1000, sys.argv[4], sys.argv[5]
lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libc = ctypes.CDLL(None)
class TB(ctypes.Structure): _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
tb = TB(); libc.mach_timebase_info(ctypes.byref(tb)); tick = tb.numer / tb.denom
sysctl = lambda k: subprocess.run(["/usr/sbin/sysctl", "-n", k], capture_output=True, text=True, timeout=5).stdout.strip()
n = int(sysctl("hw.nperflevels") or 1)
levels = [sysctl(f"hw.perflevel{i}.name") for i in range(n)]
try:
    ps = subprocess.run(["/bin/ps", "-A", "-r", "-o", "pid=,pcpu=,pri=,nice=,comm="], capture_output=True, text=True, timeout=5).stdout
except subprocess.TimeoutExpired:
    ps = "(ps did not answer in 5 s)"
ps = [l.strip() for l in ps.splitlines()[:15]]
ids = (ctypes.c_uint64 * 4096)()
got = lib.proc_pidinfo(pid, 28, 0, ids, ctypes.sizeof(ids))  # PROC_PIDLISTTHREADIDS
if got <= 0: sys.exit(f"tiers: PROC_PIDLISTTHREADIDS failed: errno {ctypes.get_errno()}")
main = min(t for t in ids[: got // 8] if t)
size = 8 + 40 * n + 40
buf = ctypes.create_string_buffer(size)
def read():
    k = lib.proc_pidinfo(pid, 34, ctypes.c_uint64(main), buf, size)  # PROC_PIDTHREADCOUNTS
    if k <= 0: return None
    raw = buf.raw
    f = [int.from_bytes(raw[8 + 8 * i: 16 + 8 * i], "little") for i in range(5 * n)]
    return ([time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)] + [round((f[5 * l + 2] + f[5 * l + 3]) * tick / 1e6, 4) for l in range(n)]
            + [f[5 * l + 1] for l in range(n)])
first = read()
if first is None: sys.exit(f"tiers: PROC_PIDTHREADCOUNTS failed: errno {ctypes.get_errno()}")
rows = [first]
print("ready", flush=True)
end, i = time.monotonic() + seconds, 0
while time.monotonic() < end:
    time.sleep(interval)
    r = read()
    if r is None: break
    rows.append(r)
    i += 1
    if i % 32 == 0 and os.path.exists(stop): break
json.dump({"pid": pid, "main_tid": main, "levels": levels, "interval_ms": interval * 1000, "rows": rows, "ps": ps}, open(out, "w"))
print("done", len(rows), flush=True)
'''


def install(driver):
    global D
    D = driver


def reap(keep_owner=None):
    """Ends every sampler that was started and not stopped, except KEEP_OWNER's (a failed journey's: its file is not
    written)."""
    for handle in [h for h in _LIVE if keep_owner is None or h.get("owner") is not keep_owner]:
        _LIVE.remove(handle)
        if handle["proc"].poll() is None:
            handle["proc"].kill()
            handle["proc"].wait()


atexit.register(lambda: reap())


def start(pid, path, seconds=120.0, interval_ms=INTERVAL_MS, sampler=None, timeout=None, owner=None):
    """Starts the sampler on PID's main thread; returns its handle once the first reading is in (OSError if not, also
    after START_TIMEOUT s). OWNER: the journey that starts it (other journeys' samplers are ended first; with no owner,
    every live sampler is). SAMPLER replaces the sampler's code (tests)."""
    reap(keep_owner=owner) if owner is not None else reap()
    path = str(path)
    stop_path = path + ".stop"
    for p in (path, stop_path):
        if os.path.exists(p):
            os.unlink(p)
    python = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else "python3"
    proc = subprocess.Popen([python, "-I", "-c", sampler or SAMPLER, str(pid), str(float(seconds)), str(float(interval_ms)),
                             path, stop_path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    ready, _, _ = select.select([proc.stdout], [], [], START_TIMEOUT if timeout is None else timeout)
    line = proc.stdout.readline() if ready else ""
    if not ready:
        proc.kill()
        proc.wait()
        raise OSError(f"tiers sampler gave no first reading on pid {pid} within {START_TIMEOUT if timeout is None else timeout} s")
    if not line.startswith("ready"):
        proc.kill()
        proc.wait()
        raise OSError(f"tiers sampler did not start on pid {pid}: {(line + (proc.stdout.read() or ''))[-300:]}")
    handle = {"proc": proc, "path": path, "stop": stop_path, "seconds": float(seconds), "owner": owner}
    _LIVE.append(handle)
    return handle


def stop(handle, timeout=30.0):
    """Stops the sampler; returns its data (dict). OSError when it wrote nothing."""
    if handle in _LIVE:
        _LIVE.remove(handle)
    with open(handle["stop"], "w"):
        pass
    try:
        rest = handle["proc"].communicate(timeout=timeout)[0] or ""
    except subprocess.TimeoutExpired:
        handle["proc"].kill()
        handle["proc"].wait()
        raise OSError("tiers sampler did not end")
    finally:
        if os.path.exists(handle["stop"]):
            os.unlink(handle["stop"])
    if handle["proc"].returncode != 0 or not os.path.exists(handle["path"]):
        raise OSError(f"tiers sampler failed ({handle['proc'].returncode}): {rest.strip()[-300:]}")
    with open(handle["path"]) as f:
        return json.load(f)


BUSY_MS = 0.3  # CPU ms in one sample interval that counts as running there


def turn_tiers(data, times_s, window_ms=100.0):
    """For each host time T (seconds, CLOCK_UPTIME_RAW): where the main thread ran in the WINDOW_MS after T.
    start_tier: the tier of the first sample interval with BUSY_MS of main-thread CPU (None: idle);
    ms_to_super: wall ms from T to the first interval with BUSY_MS on the fastest tier (levels[0]; None: none);
    e_cpu_ms_before_super: CPU ms on the other tiers before that; cpu_ms: CPU ms per tier in the window."""
    rows, levels = data["rows"], data["levels"]
    n = len(levels)
    out = []
    for t in times_s:
        a, b = int(t * 1e9), int((t + window_ms / 1000) * 1e9)
        turn = {"t": round(t, 6), "start_tier": None, "ms_to_super": None, "e_cpu_ms_before_super": 0.0,
                "cpu_ms": {name: 0.0 for name in levels}}
        if not rows or rows[0][0] > a or rows[-1][0] < a:
            turn["error"] = "the sampler does not cover this time"
            out.append(turn)
            continue
        for r0, r1 in zip(rows, rows[1:]):
            if r1[0] <= a or r0[0] >= b:
                continue
            d = [r1[1 + i] - r0[1 + i] for i in range(n)]
            for i in range(n):
                turn["cpu_ms"][levels[i]] = round(turn["cpu_ms"][levels[i]] + d[i], 3)
            if turn["start_tier"] is None and max(d) >= BUSY_MS:
                turn["start_tier"] = levels[d.index(max(d))]
            if turn["ms_to_super"] is None:
                if d[0] >= BUSY_MS:
                    turn["ms_to_super"] = round(max(0, r0[0] - a) / 1e6, 2)
                else:
                    turn["e_cpu_ms_before_super"] = round(turn["e_cpu_ms_before_super"] + sum(d[1:]), 3)
        out.append(turn)
    return out


def _tiers(j):
    if not hasattr(j, "hc_tiers"):
        j.hc_tiers = {}
    return j.hc_tiers


def step_tiers_start(j, step):
    name = step["name"]
    if not name.isalpha() or not name.islower():
        raise D.StepError(f"tiers_start: name {name!r} must be lowercase letters (diag-<name>.json)")
    try:
        handle = start(j.app.pid, j.out / f"diag-{name}.json", step.get("seconds", 120), step.get("interval_ms", INTERVAL_MS), owner=j)
    except OSError as error:
        raise D.StepError(str(error))
    handle["t"] = D.now()
    _tiers(j)[name] = handle
    return {"path": handle["path"], "seconds": handle["seconds"]}


def step_tiers_stop(j, step):
    handle = _tiers(j).pop(step["name"], None)
    if not handle:
        raise D.StepError(f"tiers_stop: no sampler {step['name']!r} runs")
    try:
        data = stop(handle)
    except OSError as error:
        raise D.StepError(str(error))
    marks = {k: v for k, v in (getattr(j, "marks", None) or {}).items() if isinstance(v, (int, float)) and v >= handle["t"]}
    turns = turn_tiers(data, [host_seconds(v) for v in marks.values()])
    return {"path": handle["path"], "rows": len(data["rows"]), "levels": data["levels"],
            "marks": {k: t for k, t in zip(marks, turns)}}


STEPS = {"tiers_start": step_tiers_start, "tiers_stop": step_tiers_stop}
CONDITIONS = {}
