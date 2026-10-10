#!/usr/bin/env python3
"""Swift Home performance baseline for the React Home switch decision (cx-59n8).

Launches the tagged app with no activation, seeds a local channel through
`debug.home.api` (the same data path the React Home uses), shows it with
`home.openConversation`, and measures through the debug socket only:
  - frame pacing (`debug.frames`) while the transcript scrolls
    (`debug.home.drive scroll`), during sends, and while keys are typed;
  - key dispatch latency: the `debug.key` round trip per key (the key event
    goes through the window's responder chain into the field and the text is
    in the field when the call returns; the glyph is on screen at the next
    presented frame, so key-to-glyph is about this plus one frame interval);
  - memory: resident size and phys_footprint (`footprint`) at each stage.
Runs on cmux-lawrence-2 (GUI host), never on the laptop. Writes one JSON file.

Usage: home-perf.py --tag <tag> --out results.json [--messages 300]
"""
import argparse, json, os, re, socket, statistics, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--messages", type=int, default=300)
opts = parser.parse_args()
home = os.environ["HOME"]
app = f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
sock = f"/tmp/cmux-debug-{opts.tag}.sock"
work = os.path.dirname(os.path.abspath(opts.out))
os.makedirs(work, exist_ok=True)
results = {"tag": opts.tag, "host": socket.gethostname(), "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except Exception as error:
        return {"ok": False, "error": f"socket: {error}"}


def poll(predicate, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.5)  # harness wait, not app code
    return None


def memory(pid):
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    match = re.search(r"Footprint:\s*([\d.]+)\s*([KMG]B)", out)
    footprint_mb = None
    if match:
        value, unit = float(match.group(1)), match.group(2)
        footprint_mb = value / 1024 if unit == "KB" else value * 1024 if unit == "GB" else value
    return {"rss_mb": round(int(rss) / 1024, 1) if rss.isdigit() else None, "footprint_mb": footprint_mb}


def frames(label, body):
    rpc("debug.frames", {"action": "start"})
    started = time.time()
    extra = body()
    stats = rpc("debug.frames", {"action": "stop"})
    stats["seconds"] = round(time.time() - started, 2)
    if extra:
        stats.update(extra)
    results[label] = stats
    print(label, json.dumps(stats), flush=True)


env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local"}
if os.path.exists(sock):
    os.unlink(sock)
process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=work, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(work, "perf-app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
pid = process.pid
try:
    if not poll(lambda: "conversations" in (rpc("debug.home.api", {"call": "inbox"}) or {}), timeout=180):
        sys.exit("FAIL the local owner never answered")
    results["memory_launch"] = memory(pid)
    created = rpc("debug.home.api", {"call": "submit", "op": {"kind": "create_group", "title": f"perf-{int(time.time())}", "participants": []}})
    channel = created.get("conversation")
    if not channel:
        sys.exit(f"FAIL no channel: {created}")
    seed_started = time.time()
    for index in range(opts.messages):
        text = f"perf message {index}: " + ("lorem ipsum dolor sit amet " * (1 + index % 6))
        rpc("debug.home.api", {"call": "submit", "op": {"kind": "send", "conversation": channel, "text": text}})
    results["seed"] = {"messages": opts.messages, "seconds": round(time.time() - seed_started, 2)}
    opened = rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": channel}, "focus": True})
    shown = poll(lambda: (g := rpc("debug.home.drive", {"action": "geometry"})) and g.get("ok") and g, timeout=60)
    results["open"] = {"action": opened, "geometry": shown}
    if not shown:
        sys.exit(f"FAIL the channel is not shown: {opened}")
    time.sleep(2)  # let the first layout and pictures settle before measuring
    results["memory_open"] = memory(pid)

    def scroll():
        for _ in range(60):
            rpc("debug.home.drive", {"action": "scroll", "dy": -120})
            time.sleep(1 / 30)
        for _ in range(60):
            rpc("debug.home.drive", {"action": "scroll", "dy": 120})
            time.sleep(1 / 30)
    frames("scroll", scroll)

    def send():
        for index in range(20):
            rpc("debug.home.drive", {"action": "type", "text": f"send during measure {index}"})
            rpc("debug.home.drive", {"action": "send"})
            time.sleep(0.5)
    frames("send", send)

    def typing():
        rpc("debug.home.drive", {"action": "focus"})
        trips = []
        for char in "the quick brown fox jumps over the lazy dog " * 2:
            started = time.perf_counter()
            rpc("debug.key", {"key": char})
            trips.append((time.perf_counter() - started) * 1000)
            time.sleep(0.08)
        trips.sort()
        return {"key_dispatch_ms": {"count": len(trips), "p50": round(statistics.median(trips), 2),
                                    "p95": round(trips[int(len(trips) * 0.95) - 1], 2), "max": round(trips[-1], 2)}}
    frames("typing", typing)
    results["memory_end"] = memory(pid)
finally:
    rpc("action.run", {"id": "quitEndSessions"})
    poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
    acp = f"{home}/.acpmux/tags/{opts.tag}"
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))
    with open(opts.out, "w") as handle:
        json.dump(results, handle, indent=1)
    print("wrote", opts.out, flush=True)
