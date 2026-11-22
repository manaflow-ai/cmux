#!/usr/bin/env python3
"""Time daemon new-tab replies and check whether each tab adopted the spare host (R81).

Usage: new-tab-daemon-bench.py CMUX_BINARY [RUNS] [login|sh]
Runs a headless daemon on a private socket and state dir, sends new-tab with a
caller-chosen terminal_id (as the app does) and reports reply time and whether
the tab's host pid was the spare. Env: GAP (seconds between tabs, default 0.6),
SAMPLE=SECONDS with SAMPLE_OUT=PATH runs `sample` on the daemon meanwhile,
SPANS=1 turns on the daemon's debug timing marks (CMUX_TUI_DEBUG_SPANS) and
prints the mean and p95 gap before each mark.
Run it on a fleet Mac, never on the laptop.
"""
import json, os, socket, subprocess, sys, time, tempfile, shutil, statistics

BIN = sys.argv[1]
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
SHELLMODE = sys.argv[3] if len(sys.argv) > 3 else "login"
d = tempfile.mkdtemp(prefix="r81b-", dir="/tmp")
sock = os.path.join(d, "s.sock")
env = dict(os.environ)
spans_path = os.path.join(d, "spans.jsonl")
if os.environ.get("SPANS"):
    env["CMUX_TUI_DEBUG_SPANS"] = spans_path
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
    if os.environ.get("SPANS") and os.path.exists(spans_path):
        gaps = {}
        order = []
        totals = []
        for line in open(spans_path):
            trace = json.loads(line)
            if trace.get("label") not in ("new-tab", "host"):
                continue
            if trace["label"] == "host":
                trace["marks"] = [["host-process " + name, at] for name, at in trace["marks"]]
            if trace["label"] == "new-tab":
                totals.append(trace["total_us"] / 1000)
            last = 0
            for name, at in trace["marks"]:
                key = " ".join(name.split(" ")[:2]) if name.startswith(("lock.wait", "host-process")) else name
                if key not in gaps:
                    gaps[key] = []
                    order.append(key)
                gaps[key].append((at - last) / 1000)
                last = at
            gaps.setdefault("(after last mark)", []).append((trace["total_us"] - last) / 1000)
        order.append("(after last mark)")
        n = len(totals)
        if os.environ.get("SPANS_DUMP"):
            import shutil as _sh
            _sh.copy(spans_path, os.environ["SPANS_DUMP"])
        print(f"spans over {n} new-tab traces; daemon total p50 {sorted(totals)[n // 2]:.1f} ms")
        print(f"{'gap before mark':58s} {'count':>5s} {'sum/tab':>8s} {'mean':>7s} {'p95':>7s}")
        for key in order:
            values = sorted(gaps[key])
            print(f"{key[:58]:58s} {len(values):5d} {sum(values) / n:8.2f} {sum(values) / len(values):7.2f} {values[min(len(values) - 1, int(0.95 * len(values)))]:7.2f}")
finally:
    daemon.terminate()
    try: daemon.wait(5)
    except Exception: daemon.kill()
    print(open(os.path.join(d, "err.log")).read()[-2000:])
    shutil.rmtree(d, ignore_errors=True)
