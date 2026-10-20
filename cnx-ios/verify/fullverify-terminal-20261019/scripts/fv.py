"""fvterm helpers (verifier scripts; kept outside the repo tree)."""
import json, os, subprocess, sys, time, re
sys.path.insert(0, "/tmp/fv-term-3e6a/cnx-ios/verify/termqa")
import tq
from tq import ctx, load, rsh
RAW = os.path.expanduser("~/cnx-ios-e2e/fvterm-raw")
EV = "/tmp/fv-term-3e6a/cnx-ios/verify/fullverify-terminal-20261019"
os.makedirs(EV, exist_ok=True)
TOUCH = os.path.join(RAW, "touch.jsonl")

def jl(path, obj):
    with open(path, "a") as f:
        f.write(json.dumps(obj) + "\n")

def touch(kind, dur=None, **kw):
    jl(TOUCH, dict(t=time.time(), kind=kind, **({"dur": dur} if dur is not None else {}), **kw))

def mem(note=""):
    s, m, j = ctx()
    pid = j.app_pid()
    out = {"t": time.time(), "ts": time.strftime("%H:%M:%S"), "note": note, "pid": pid}
    if pid:
        ps = subprocess.run(["ps", "-o", "rss=,%cpu=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
        if ps:
            out["rss_mb"] = round(int(ps[0]) / 1024, 1); out["cpu"] = float(ps[1])
        fp = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
        mm = re.search(r"phys_footprint:\s*([\d.]+)\s*(\w+)", fp) or re.search(r"Footprint:\s*([\d.]+)\s*(\w+)", fp)
        if mm:
            v = float(mm.group(1)); u = mm.group(2).upper()
            out["footprint_mb"] = round(v / 1024 if u.startswith("K") else v * 1024 if u.startswith("G") else v, 1)
    r = rsh("ps -axo pid=,rss=,%cpu=,command= | grep -E 'cnx-e2e-90375ce5.app/Contents/(Resources/bin/(cnx-hostd|cmux-tui --headless --session cmux-app)|MacOS/)' | grep -v grep", timeout=30)
    macs = []
    for line in r.stdout.splitlines():
        p = line.split(None, 3)
        if len(p) == 4:
            macs.append({"pid": int(p[0]), "rss_mb": round(int(p[1]) / 1024, 1), "cpu": float(p[2]), "cmd": os.path.basename(p[3].split(" --")[0])[:40]})
    out["mac"] = macs
    jl(os.path.join(RAW, "mem.jsonl"), out)
    return out

def cpu_window(seconds=60, step=5, note=""):
    """App CPU over a window: ps cputime delta (accurate average) + samples."""
    s, m, j = ctx(); pid = j.app_pid()
    def ct():
        t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        parts = [float(x) for x in t.replace("-", ":").split(":")]
        sec = 0
        for p in parts: sec = sec * 60 + p
        return sec
    c0, t0 = ct(), time.time(); samples = []
    while time.time() - t0 < seconds:
        time.sleep(step); samples.append(mem(note))
    c1, t1 = ct(), time.time()
    return {"avg_cpu_pct": round(100 * (c1 - c0) / (t1 - t0), 1), "secs": round(t1 - t0, 1), "note": note,
            "footprint_mb": [x.get("footprint_mb") for x in samples]}

FX = "cnx-ios-e2e/fvterm/fx"

def run_cmd(cmd, hide=True):
    """Type a shell command in the composer on the soft keyboard and tap Send (phone stimulus)."""
    s, m, j = ctx()
    touch("type", dur=0, text=cmd[:60])
    tq.composer_send(cmd)
    touch("tap", what="send")
    if hide:
        time.sleep(0.8); j.hide_keyboard(); touch("tap", what="hide-kb")

def rec(name):
    t = time.time()
    v = tq.rec_start(name)
    jl(os.path.join(RAW, "recs.jsonl"), {"name": name, "t_call": t, "t_birth": os.stat(v).st_birthtime})
    return v

def stop():
    return tq.rec_stop()

def motion(video, out, **kw):
    args = [sys.executable, "/tmp/fv-term-3e6a/cnx-ios/verify/termqa/motion.py", video, "--json", out, "--quiet"]
    for k, v in kw.items():
        args += [f"--{k.replace('_','-')}", str(v)]
    r = subprocess.run(args, capture_output=True, text=True)
    try:
        return json.load(open(out))["summary"]
    except Exception:
        return {"err": (r.stderr or r.stdout)[-600:]}

def rows(video, out, **kw):
    args = [sys.executable, "/tmp/fv-term-3e6a/cnx-ios/verify/termqa/rows.py", video, "--json", out, "--quiet"]
    for k, v in kw.items():
        args += [f"--{k.replace('_','-')}", str(v)]
    r = subprocess.run(args, capture_output=True, text=True)
    try:
        return json.load(open(out))["summary"]
    except Exception:
        return {"err": (r.stderr or r.stdout)[-600:]}

def rec2(name):
    """Recorder with the host time of its first frame ('Recording started' on stderr)."""
    st = load()
    path = os.path.join(RAW, f"{name}.mp4")
    errf = path + ".stderr"
    t_call = time.time()
    p = subprocess.Popen(["xcrun", "simctl", "io", st["udid"], "recordVideo", "--codec", "h264", "--force", path],
                         stdout=subprocess.DEVNULL, stderr=open(errf, "w"), start_new_session=True)
    t_start = None
    while time.time() - t_call < 15:
        if "Recording started" in open(errf).read():
            t_start = time.time(); break
        if p.poll() is not None:
            raise RuntimeError("recordVideo exited")
        time.sleep(0.01)
    st["rec"] = {"pid": p.pid, "path": path, "t0": t_start}
    tq.save(st)
    jl(os.path.join(RAW, "recs.jsonl"), {"name": name, "t_call": t_call, "t_started": t_start})
    return path, t_start

def clock_offset(n=5):
    """mini clock minus laptop clock (s), min-RTT sample."""
    best = None
    for _ in range(n):
        a = time.time(); r = rsh("python3 -c 'import time; print(time.time())'", timeout=20); b = time.time()
        try:
            rt = float(r.stdout.strip())
        except ValueError:
            continue
        cand = (b - a, rt - (a + b) / 2)
        if best is None or cand[0] < best[0]:
            best = cand
    return {"rtt_s": round(best[0], 3), "offset_s": round(best[1], 3)}
