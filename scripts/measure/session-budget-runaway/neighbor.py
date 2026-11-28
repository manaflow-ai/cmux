# Neighbor probe: every 100 ms, time a 64 MB allocate+touch, a 2 ms CPU spin's wall time, a fork+exec of /bin/true, and a 4 KB write+fsync.
import os, sys, time, json, subprocess
dur = float(sys.argv[1]); out = sys.argv[2]
path = os.path.join(os.path.dirname(out), "probe.dat")
rows = []
end = time.time() + dur
while time.time() < end:
    r = {}
    t = time.perf_counter(); b = bytearray(64 << 20); b[::4096] = b"\1" * (len(b) // 4096); del b; r["alloc"] = time.perf_counter() - t
    t = time.perf_counter(); c = time.thread_time()
    while time.thread_time() - c < 0.002: pass
    r["spin"] = time.perf_counter() - t
    t = time.perf_counter()
    try: subprocess.run(["/bin/true"], check=False); r["fork"] = time.perf_counter() - t
    except OSError: r["fork"] = None
    t = time.perf_counter()
    with open(path, "wb") as f: f.write(b"x" * 4096); f.flush(); os.fsync(f.fileno())
    r["fsync"] = time.perf_counter() - t
    rows.append(r); time.sleep(0.1)
os.unlink(path)
def pct(k, p):
    v = sorted(x[k] for x in rows if x[k] is not None)
    return round(v[min(len(v) - 1, int(len(v) * p))] * 1000, 1) if v else None
json.dump({k: {"p50": pct(k, .5), "p99": pct(k, .99)} for k in ["alloc", "spin", "fork", "fsync"]} | {"n": len(rows), "forkFails": sum(1 for x in rows if x["fork"] is None)}, open(out, "w"))
