# A writer plus the watcher's rule, emulated from /proc/<pid>/io at the real tick: over budget with free < floor, SIGSTOP the writer's group.
import os, sys, time, subprocess, signal, shutil
mode, cap_mb, budget_mb, floor_gb, tick = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
path = os.path.join(os.environ.get("OUT", "/tmp"), "big.dat")
w = subprocess.Popen(["dd", "if=/dev/zero", f"of={path}", "bs=1M", f"count={cap_mb}", "conv=fsync", "status=none"], start_new_session=True)
t0 = time.time(); stopped_at = None; peak = 0
def kept(pid):
    try:
        d = dict(l.split(":") for l in open(f"/proc/{pid}/io").read().split("\n") if ":" in l)
        return int(d["write_bytes"]) - int(d["cancelled_write_bytes"])
    except Exception: return 0
while w.poll() is None:
    time.sleep(tick if mode == "watch" else 0.5)
    k = kept(w.pid); peak = max(peak, k); free = shutil.disk_usage("/tmp").free
    if mode == "watch" and k > budget_mb << 20 and free < floor_gb * (1 << 30) and stopped_at is None:
        os.killpg(w.pid, signal.SIGSTOP); stopped_at = (time.time() - t0, k, free); break
size = os.path.getsize(path)
print(f"mode={mode} written={size>>20}MB peakKept={peak>>20}MB stopped={stopped_at and (round(stopped_at[0],1), stopped_at[1]>>20, round(stopped_at[2]/2**30,1))} freeAfter={shutil.disk_usage('/tmp').free/2**30:.1f}G t={time.time()-t0:.1f}s", flush=True)
try:
    os.killpg(w.pid, signal.SIGKILL); os.killpg(w.pid, signal.SIGCONT)
except ProcessLookupError: pass
w.wait(); os.unlink(path)
