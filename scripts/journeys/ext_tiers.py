"""HARNESS CORES steps: where the app's main thread runs (Super, Performance or Efficiency cores), with no profiler.

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (standard library only).

The M6 minis have three core tiers (sysctl hw.perflevel0..2: Super 2, Performance 4, Efficiency 6). xctrace's Time
Profiler names them "S Core", "P Core" and "E Core"; S is the fastest tier. proc_pidinfo(PROC_PIDTHREADCOUNTS) gives
one thread's CPU time, cycles and instructions per tier (XNU recount), for a process of the same user, with no root
and no sampling interrupt. So a round can read the tier split of the main thread with xctrace on or off.

Steps (`do`):
  tiers_start {name, seconds?: 4, interval_ms?: 1}  starts a sampler process that reads the app main thread's
                per-tier counters (the lowest thread id of the app's pid) every interval_ms for `seconds`, and a
                `ps` snapshot of the busiest processes first; it returns once the first reading is in.
  tiers_stop  {name}  waits for the sampler and writes <journey out>/diag-<name>.json (run.py fetches diag-*.json):
                {"levels": [...], "tick_ns": ..., "rows": [[uptime_ns, ms_0, ms_1, ms_2, cycles_0, ...], ...], "ps": ...}.
                Times are CLOCK_UPTIME_RAW, the clock of the app's input journal (uptimeNanos) and frame trace.
"""
import json
import os
import subprocess

D = None

SAMPLER = r'''
import ctypes, json, subprocess, sys, time
pid, seconds, interval, out = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]) / 1000, sys.argv[4]
lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libc = ctypes.CDLL(None)
class TB(ctypes.Structure): _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
tb = TB(); libc.mach_timebase_info(ctypes.byref(tb)); tick = tb.numer / tb.denom
sysctl = lambda k: subprocess.run(["/usr/sbin/sysctl", "-n", k], capture_output=True, text=True).stdout.strip()
n = int(sysctl("hw.nperflevels") or 1)
levels = [sysctl(f"hw.perflevel{i}.name") for i in range(n)]
ps = subprocess.run(["/bin/ps", "-A", "-r", "-o", "pid=,pcpu=,pri=,nice=,comm="], capture_output=True, text=True).stdout
ps = [l.strip() for l in ps.splitlines()[:15]]
ids = (ctypes.c_uint64 * 4096)()
got = lib.proc_pidinfo(pid, 28, 0, ids, ctypes.sizeof(ids))
if got <= 0: sys.exit(f"tiers: PROC_PIDLISTTHREADIDS failed: errno {ctypes.get_errno()}")
main = min(t for t in ids[: got // 8] if t)
size = 8 + 40 * n + 40
buf = ctypes.create_string_buffer(size)
rows = []
def read():
    k = lib.proc_pidinfo(pid, 34, ctypes.c_uint64(main), buf, size)
    if k <= 0: return None
    raw = buf.raw
    f = [int.from_bytes(raw[8 + 8 * i: 16 + 8 * i], "little") for i in range(5 * n)]
    return [time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)] + [round((f[5 * l + 2] + f[5 * l + 3]) * tick / 1e6, 4) for l in range(n)] + [f[5 * l + 1] for l in range(n)]
first = read()
if first is None: sys.exit(f"tiers: PROC_PIDTHREADCOUNTS failed: errno {ctypes.get_errno()}")
rows.append(first)
print("ready", flush=True)
end = time.monotonic() + seconds
while time.monotonic() < end:
    time.sleep(interval)
    r = read()
    if r is None: break
    rows.append(r)
json.dump({"pid": pid, "main_tid": main, "levels": levels, "interval_ms": interval * 1000, "rows": rows, "ps": ps}, open(out, "w"))
print("done", len(rows), flush=True)
'''


def install(driver):
    global D
    D = driver


def _tiers(j):
    if not hasattr(j, "hc_tiers"):
        j.hc_tiers = {}
    return j.hc_tiers


def step_tiers_start(j, step):
    name = step["name"]
    if not name.isalpha() or not name.islower():
        raise D.StepError(f"tiers_start: name {name!r} must be lowercase letters (diag-<name>.json)")
    path = j.out / f"diag-{name}.json"
    seconds = float(step.get("seconds", 4.0))
    interval = float(step.get("interval_ms", 1))
    proc = subprocess.Popen(["/usr/bin/python3", "-I", "-c", SAMPLER, str(j.app.pid), str(seconds), str(interval), str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    line = proc.stdout.readline()
    if not line.startswith("ready"):
        proc.kill()
        raise D.StepError(f"tiers sampler did not start on pid {j.app.pid}: {(line + (proc.stdout.read() or ''))[-300:]}")
    _tiers(j)[name] = {"proc": proc, "path": path, "seconds": seconds, "t": D.now()}
    return {"path": str(path), "seconds": seconds, "interval_ms": interval}


def step_tiers_stop(j, step):
    rec = _tiers(j).pop(step["name"], None)
    if not rec:
        raise D.StepError(f"tiers_stop: no sampler {step['name']!r} runs")
    try:
        rest = rec["proc"].communicate(timeout=rec["seconds"] + 30)[0] or ""
    except subprocess.TimeoutExpired:
        rec["proc"].kill()
        raise D.StepError("tiers_stop: the sampler did not end")
    if rec["proc"].returncode != 0 or not os.path.exists(rec["path"]):
        raise D.StepError(f"tiers sampler failed ({rec['proc'].returncode}): {rest.strip()[-300:]}")
    data = json.load(open(rec["path"]))
    return {"path": str(rec["path"]), "rows": len(data["rows"]), "levels": data["levels"], "said": rest.strip()[-80:]}


STEPS = {"tiers_start": step_tiers_start, "tiers_stop": step_tiers_stop}
