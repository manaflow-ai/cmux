#!/usr/bin/env python3
"""Time daemon new-tab replies and check whether each tab adopted the spare host (R81).

Usage: new-tab-daemon-bench.py CMUX_BINARY [RUNS] [login|sh]
Runs a headless daemon on a private socket and state dir, sends new-tab with a
caller-chosen terminal_id (as the app does) and reports reply time and whether
the tab's host pid was the spare. Env: GAP (seconds between tabs, default 0.6),
SAMPLE=SECONDS with SAMPLE_OUT=PATH runs `sample` on the daemon meanwhile.
Run it on a fleet Mac, never on the laptop.
"""
import json, os, socket, subprocess, sys, time, tempfile, shutil, statistics

BIN = sys.argv[1]
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
SHELLMODE = sys.argv[3] if len(sys.argv) > 3 else "login"
d = tempfile.mkdtemp(prefix="r81b-", dir="/tmp")
sock = os.path.join(d, "s.sock")
env = dict(os.environ)
daemon = subprocess.Popen([BIN, "--headless", "--session", "r81b", "--socket", sock, "--state", os.path.join(d, "state")],
                          stdout=subprocess.DEVNULL, stderr=open(os.path.join(d, "err.log"), "w"), env=env)
for _ in range(200):
    if os.path.exists(sock): break
    time.sleep(0.05)

def req(obj):
    s = socket.socket(socket.AF_UNIX); s.connect(sock)
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        c = s.recv(65536)
        if not c: break
        buf += c
    s.close()
    return json.loads(buf)

def hosts():
    out = subprocess.run(["pgrep", "-P", str(daemon.pid), "-f", "__terminal-host"], capture_output=True, text=True).stdout
    return set(int(x) for x in out.split())

import glob
def records():
    out = {}
    for f in glob.glob(os.path.join(d, "state", "terminal-hosts-*", "*.json")):
        try:
            r = json.load(open(f)); out[r.get("terminal_id")] = r.get("host_pid")
        except Exception: pass
    return out

times = []
adopted = 0
try:
    time.sleep(1.0)
    sampler = None
    if os.environ.get("SAMPLE"):
        sampler = subprocess.Popen(["sample", str(daemon.pid), os.environ["SAMPLE"], "1", "-mayDie", "-file", os.environ.get("SAMPLE_OUT", "/tmp/r81b-sample.txt")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)
    for i in range(RUNS):
        before = hosts()
        spare = before - set(records().values())
        import uuid; tid = uuid.uuid4().hex
        cmd = {"id": i + 1, "cmd": "new-tab", "terminal_id": tid}
        if SHELLMODE == "sh":
            cmd["env"] = {"SHELL": "/bin/sh"}
        t0 = time.perf_counter()
        r = req(cmd)
        dt = (time.perf_counter() - t0) * 1000
        if not r.get("ok"):
            print("fail", r); break
        tpid = records().get(r["data"].get("terminal_id"))
        time.sleep(float(os.environ.get("GAP", "0.6")))  # let refill finish
        hit = tpid in spare
        adopted += hit
        times.append(dt)
        print(f"run {i:2d}: {dt:7.1f} ms  spare={sorted(spare)} host={tpid} adopted={hit}", flush=True)
    s = sorted(times)
    p = lambda q: s[min(len(s) - 1, int(q * len(s)))]
    print(f"adopted {adopted}/{len(times)} p50={p(0.5):.1f} p95={p(0.95):.1f} min={s[0]:.1f}")
    if sampler: sampler.wait()
finally:
    daemon.terminate()
    try: daemon.wait(5)
    except Exception: daemon.kill()
    print(open(os.path.join(d, "err.log")).read()[-2000:])
    shutil.rmtree(d, ignore_errors=True)
