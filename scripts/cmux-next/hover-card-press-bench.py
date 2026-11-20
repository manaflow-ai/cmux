#!/usr/bin/env python3
"""Late frames at a sidebar workspace card's Show details / Hide details press (Lawrence 2026-11-18, msg 38370
follow-up: "fix the one late frame at the press of Show/Hide details").

  python3 scripts/cmux-next/hover-card-press-bench.py --app APP --tag TAG --out DIR [--cycles 20] [--hold-seconds 0]

Launches the tagged DEBUG app (scratch config, CMUX_NEXT_NO_ACTIVATE=1), rests the pointer on a workspace row until
its card shows, then runs CYCLES of: a no-press control, Show details, a no-press control, Hide details. Each traces
the card's parent window's display ticks (`debug.motion` trace_start/trace_stop) and the press's main-thread work
(`debug.motion` start/stop: `hoverCard.detailsPress`, `hoverCard.morph`). A press is late when two ticks in
140-260 ms after the trace started (the press is sent at 150 ms) are more than 1.5 refresh intervals apart. DIR gets
runs.json and summary.json. `--hold-seconds N` keeps pressing for N s after the cycles (a recorder attached to the
app's PID, printed as `PID n`, sees presses). Quits the app with its own quit; signals only the PID it started.
"""
import argparse, json, os, plistlib, socket, subprocess, tempfile, time

p = argparse.ArgumentParser()
p.add_argument("--app", required=True)
p.add_argument("--tag", required=True)
p.add_argument("--out", required=True)
p.add_argument("--cycles", type=int, default=20)
p.add_argument("--hold-seconds", type=float, default=0)
o = p.parse_args()
SOCK = f"/tmp/cmux-debug-{o.tag}.sock"
LABELS = ("-a", "Show details", "-b", "Hide details")
ROW = "Fleet tools GCP grant"


def rpc(method, params=None, timeout=60):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
    c.connect(SOCK)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    c.close()
    r = json.loads(buf or b"{}")
    return r.get("result") if r.get("ok") else {"error": r.get("error")}


def wait(check, seconds, step=0.2):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait on the app's state
        try:
            v = check()
        except OSError:
            v = None
        if v:
            return v
        time.sleep(step)
    return None


def row():
    rows = ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
    for r in rows:
        if str(r.get("key", "")).startswith("workspace") and r.get("in_list") and r.get("title") == ROW:
            f = r["window_frame"]
            f = [f["x"], f["y"], f["width"], f["height"]] if isinstance(f, dict) else f
            return (f[0] + f[2] * 0.4, f[1] + f[3] / 2)
    return None


def pct(a, q):
    a = sorted(a)
    return a[int(round((len(a) - 1) * q))] if a else 0


def summarize(runs):
    out = {}
    for label in LABELS:
        late, worst, press_ms, work = 0, [], [], []
        refresh = 0
        for cyc in runs:
            c = cyc.get(label)
            if not c or c.get("error"):
                continue
            refresh = c.get("refresh_ms") or refresh or 8.33
            t = [x for x in c["ticks"] if 140 <= x <= 260]
            gaps = [b - a for a, b in zip(t, t[1:])]
            w = max(gaps, default=0)
            worst.append(w)
            late += w > 1.5 * refresh
            press_ms.append(c["rpc_ms"])
            work += c["work"].get("hoverCard.detailsPress") or []
        out[label] = {"presses": len(worst), "late": late, "worst_gap_ms": round(max(worst, default=0), 1),
                      "refresh_ms": refresh, "press_rpc_ms_p50": round(pct(press_ms, .5), 2),
                      "frame_start_work_ms_p50": round(pct(work, .5), 2), "frame_start_work_ms_p95": round(pct(work, .95), 2)}
    return out


APP = o.app.rstrip("/")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BIN = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
cfg = os.path.join(tempfile.mkdtemp(prefix=f"card-press-{o.tag}-"), "cmux.json")
with open(cfg, "w") as f:
    f.write("{}\n")
if os.path.exists(SOCK):
    os.unlink(SOCK)
os.makedirs(o.out, exist_ok=True)
app = subprocess.Popen([BIN], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": cfg,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,760", "CMUX_NEXT_NO_ACTIVATE": "1"},
    stdout=open(os.path.join(o.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
runs = []
try:
    wait(lambda: os.path.exists(SOCK) and "error" not in (rpc("debug.focus") or {"error": 1}), 180)
    if not (rpc("debug.focus") or {}).get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60)
    cli = os.path.join(APP, "Contents/Resources/bin/cmux")
    subprocess.run([cli, "workspace", "create", "--name", ROW, "--json"],
                   env=dict(os.environ, CMUX_SOCKET_PATH=SOCK, CMUX_TAG=o.tag), capture_output=True, timeout=60)
    point = wait(row, 60)
    if not point:
        raise SystemExit("hover-card-press: no workspace row")
    rpc("debug.mouse", {"action": "move", "x": 700, "y": 500})
    time.sleep(0.5)
    rpc("debug.mouse", {"action": "move", "x": point[0], "y": point[1]})
    time.sleep(2.0)  # past the dwell: the card shows
    for label in ("Show details", "Hide details"):  # warm-up
        rpc("debug.hover_cards", {"press": label})
        time.sleep(0.8)
    print("PID", app.pid, flush=True)
    for i in range(o.cycles):
        cyc = {}
        for label in LABELS:
            rpc("debug.motion", {"action": "start"})
            rpc("debug.motion", {"action": "trace_start", "window": 0, "targets": ["none"]})
            time.sleep(0.15)
            t = time.monotonic()
            err = (rpc("debug.hover_cards", {} if label.startswith("-") else {"press": label}) or {}).get("error")
            rpc_ms = (time.monotonic() - t) * 1000
            time.sleep(0.75)
            tr = rpc("debug.motion", {"action": "trace_stop"}) or {}
            mo = rpc("debug.motion", {"action": "stop"}) or {}
            cyc[label] = {"error": err, "rpc_ms": rpc_ms,
                          "work": {k: v.get("each_ms") for k, v in (mo.get("work") or {}).items()},
                          "spans": mo.get("spans"), "ticks": [s.get("t") for s in tr.get("samples") or []],
                          "refresh_ms": tr.get("refresh_ms")}
            time.sleep(0.3)
        runs.append(cyc)
        print(i, {l: (c["error"], len(c["ticks"])) for l, c in cyc.items()}, flush=True)
    end = time.monotonic() + o.hold_seconds
    while time.monotonic() < end:  # presses for a recorder attached to the PID
        for label in ("Show details", "Hide details"):
            rpc("debug.hover_cards", {"press": label})
            time.sleep(0.6)
finally:
    with open(os.path.join(o.out, "runs.json"), "w") as f:
        json.dump(runs, f)
    summary = summarize(runs)
    with open(os.path.join(o.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print("SUMMARY", json.dumps(summary), flush=True)
    try:
        rpc("action.run", {"action": "quitEndSessions", "origin": "script"}, timeout=20)
    except OSError:
        pass
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
