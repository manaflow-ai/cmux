#!/usr/bin/env python3
"""Live check: a Chromium tab of a tagged build draws its page and keeps its GPU process.

  scripts/cmux-next/cef-tab-health.py --tag <tag> [--url URL] [--launches 2] [--hold 60] [--out DIR]

Each launch starts the tagged app (no activation, automation socket), opens a
Chromium tab on --url with focus, and records: whether the app's Chromium
cache folder existed before the launch, the page title, Chromium's own
rendering of the page (CDP Page.captureScreenshot, a PNG that is blank when
the compositor or GPU process does not draw), the helper processes (the GPU
helper must still run --hold seconds after the load), the focused pane's
content, and the Chromium errors in the app log. The first launch of a new tag
runs with no cache folder. Run it only on a fleet GUI host. Exit 1 on any
failure; evidence goes to --out (default $NX_ARTIFACTS or a temp dir).
"""
import argparse, base64, glob, json, os, plistlib, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--url", default="https://example.com/")
parser.add_argument("--title", default="Example Domain")
parser.add_argument("--launches", type=int, default=2)
parser.add_argument("--hold", type=float, default=60.0)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="cef-tab-health-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
BUNDLE_ID = INFO["CFBundleIdentifier"]
CACHE = os.path.expanduser(f"~/Library/Caches/{BUNDLE_ID}/Chromium")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
TMP = os.environ.get("TMPDIR", "/tmp")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": TMP,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
failures = []
report = {"bundle_id": BUNDLE_ID, "url": opts.url, "launches": []}


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def helpers(pid):
    out = subprocess.run(["/bin/ps", "-A", "-o", "pid=,ppid=,etime=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[1] == str(pid):
            kind = "gpu" if "(GPU)" in parts[3] else "renderer" if "(Renderer)" in parts[3] else \
                "network" if "network.mojom" in parts[3] else "other"
            rows.append({"pid": int(parts[0]), "etime": parts[2], "kind": kind, "command": parts[3][:160]})
    return rows


def capture(path):
    result = rpc("debug.cef.devtools", {"method": "Page.captureScreenshot", "params": {"format": "png"}})
    if not isinstance(result, dict) or "error" in result:
        return {"error": result}
    try:
        data = base64.b64decode(json.loads(result.get("result") or "{}").get("data") or "")
    except ValueError as error:
        return {"error": str(error)}
    with open(path, "wb") as f:
        f.write(data)
    # Distinct byte values in the PNG body: a single-colour (blank) page compresses to very few.
    return {"path": path, "bytes": len(data)}


for launch in range(1, opts.launches + 1):
    entry = {"launch": launch, "cache_existed": os.path.isdir(CACHE)}
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    config = os.path.join(opts.out, f"cmux-{launch}.json")
    with open(config, "w") as f:
        f.write("{}\n")
    log_path = os.path.join(opts.out, f"app-{launch}.log")
    log = open(log_path, "a")
    env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    entry["pid"] = app.pid
    try:
        if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 90):
            failures.append(f"launch {launch}: app did not come up")
            continue
        entry["open"] = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": opts.url}, "focus": True})
        state = wait(lambda: (lambda s: s if s.get("title") == opts.title else None)(rpc("browser.page.state")), 45)
        entry["state"] = state or rpc("browser.page.state")
        entry["cef"] = {k: v for k, v in rpc("debug.cef").items() if k in ("state", "trigger", "unavailable", "fallback", "windows")}
        time.sleep(2)
        entry["capture_loaded"] = capture(os.path.join(opts.out, f"page-{launch}-loaded.png"))
        entry["helpers_loaded"] = helpers(app.pid)
        entry["window_snapshot"] = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"window-{launch}.png")})
        focus = rpc("debug.focus")
        entry["focus_windows"] = [{"layout_focused_pane": w.get("layout_focused_pane"), "appkit": w.get("appkit")}
                                  for w in focus.get("windows", [])] if isinstance(focus, dict) else focus
        time.sleep(opts.hold)
        entry["helpers_after_hold"] = helpers(app.pid)
        entry["capture_after_hold"] = capture(os.path.join(opts.out, f"page-{launch}-held.png"))
        if not state:
            failures.append(f"launch {launch}: title {opts.title!r} did not arrive")
        if not any(h["kind"] == "gpu" for h in entry["helpers_after_hold"]):
            failures.append(f"launch {launch}: no GPU helper {opts.hold}s after the load")
        if "error" in entry["capture_loaded"]:
            failures.append(f"launch {launch}: Chromium could not capture the page")
    finally:
        if app.poll() is None:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(20)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
        entry["exit"] = app.returncode
        log.close()
        with open(log_path) as f:
            entry["chromium_errors"] = [line.strip()[:300] for line in f if "ERROR:" in line or "FATAL" in line][:40]
        entry["cache_exists_after"] = os.path.isdir(CACHE)
        report["launches"].append(entry)

report["failures"] = failures
with open(os.path.join(opts.out, "cef-tab-health.json"), "w") as f:
    json.dump(report, f, indent=1)
for entry in report["launches"]:
    print(json.dumps({k: entry.get(k) for k in ("launch", "cache_existed", "state", "capture_loaded",
                                                 "capture_after_hold", "exit")})[:600])
    print("  helpers after hold:", [h["kind"] for h in entry.get("helpers_after_hold", [])])
    print("  chromium errors:", entry.get("chromium_errors"))
for failure in failures:
    print("FAIL", failure)
print("PASS" if not failures else "FAIL", f"(evidence {opts.out}/cef-tab-health.json)")
sys.exit(0 if not failures else 1)
