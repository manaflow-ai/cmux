#!/usr/bin/env python3
"""Streaming reply frames in the agent pane, page against page (R104).

Launches one tagged build per page variant, each loading its agent page from a loopback page
server (CMUX_NEXT_AGENT_PANE_DEV_URL), so every variant runs in the same app and the same load
path. Opens an agent tab (Cmd-Shift-I), turns on the full render rate, and runs
`debug.agent_pane action=stream`: a scripted Markdown reply streamed into a long synthetic
transcript, deltas on a timer as a socket sends them. Prints frames, dropped frames, frames
detached from the bottom, per-frame content growth and per-frame layout/React time, per run and
as medians. Run on cmux-lawrence-2 or the fleet, never the laptop.

Usage: agent-stream-e2e.py --tag <tag> --variant before=/dir/with/index.html --variant after=/dir \
    [--rows 2000] [--seconds 6] [--chunk-chars 24] [--chunk-ms 12] [--runs 3]
"""
import argparse, glob, json, os, socket, statistics, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--variant", action="append", required=True, help="name=directory holding index.html")
parser.add_argument("--rows", type=int, default=2000)
parser.add_argument("--seconds", type=float, default=6)
parser.add_argument("--chunk-chars", type=int, default=24)
parser.add_argument("--chunk-ms", type=float, default=12)
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
APP = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
SCRATCH = tempfile.mkdtemp(prefix=f"stream-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")


def rpc(method, params=None, timeout=60):
    """One request on the tagged debug socket (newline-delimited JSON)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def free_port():
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def run_variant(name, directory):
    port = free_port()
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", directory],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900",
           "CMUX_NEXT_AGENT_PANE_DEV_URL": f"http://127.0.0.1:{port}/"}
    log = open(os.path.join(SCRATCH, f"app-{name}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    results = []
    try:
        if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 120, 0.5):
            sys.exit(f"{name}: the tagged app did not come up")
        time.sleep(2)
        rpc("debug.key", {"key": "i", "modifiers": ["cmd", "shift"]})
        if not wait(lambda: "error" not in (rpc("debug.agent_pane", {"action": "pid"}) or {"error": 1}), 60, 0.5):
            sys.exit(f"{name}: no agent tab")
        time.sleep(3)
        print(f"{name}: full rate {rpc('debug.agent_pane', {'action': 'full_rate', 'enabled': True})}", flush=True)
        for run in range(opts.runs):
            result = rpc("debug.agent_pane", {"action": "stream", "rows": opts.rows, "seconds": opts.seconds,
                                              "chunk_chars": opts.chunk_chars, "chunk_ms": opts.chunk_ms},
                         timeout=opts.seconds + 120)
            print(f"{name} run {run + 1}: {json.dumps(result)}", flush=True)
            results.append(result)
    finally:
        app.terminate()
        try:
            app.wait(10)
        except subprocess.TimeoutExpired:
            app.kill()
        server.terminate()
    return results


def median(results, *path):
    values = []
    for result in results:
        value = result
        for key in path:
            value = value.get(key) if isinstance(value, dict) else None
        if isinstance(value, (int, float)):
            values.append(value)
    return round(statistics.median(values), 2) if values else None


all_results = {}
for spec in opts.variant:
    name, directory = spec.split("=", 1)
    all_results[name] = run_variant(name, directory)
json.dump(all_results, open(os.path.join(opts.out, f"agent-stream-{opts.tag}.json"), "w"), indent=1)
print("\nmedians (per run):")
columns = [("nominal_ms",), ("frames",), ("p95_ms",), ("max_ms",), ("dropped_frames",), ("detached_frames",), ("growing_frames",), ("growth_px", "p95"),
           ("growth_px", "max"), ("layout_ms", "p95_ms"), ("react_ms", "p95_ms"), ("other_ms", "p95_ms"), ("deltas",)]
print("variant  " + "  ".join(".".join(column) for column in columns))
for name, results in all_results.items():
    print(f"{name:8} " + "  ".join(str(median(results, *column)) for column in columns))
