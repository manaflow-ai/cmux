#!/usr/bin/env python3
"""Guest half of scripts/cmux-next/os-smoke/run.sh. Runs INSIDE a disposable
Tart VM (stdlib only), never on a laptop or a shared Mac.

Launches one cmux-next build the way the GUI proofs do (no-activate,
automation socket, scratch config, bounded window), waits with deadlines for
the first window and the control socket, opens one terminal tab and one
browser tab through the socket, takes debug.window_snapshot, quits, and writes
result.json. When the guest macOS is older than LSMinimumSystemVersion it
also records what LaunchServices (`open`) says, then still execs the binary
directly so the dyld error is captured.

Usage: guest-probe.py APP_PATH OUT_DIR
"""
import glob, http.server, json, os, platform, plistlib, re, signal, socket, subprocess, sys, tempfile, threading, time

APP, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
LAUNCH_DEADLINE = float(os.environ.get("OS_SMOKE_LAUNCH_DEADLINE", "180"))
TAB_DEADLINE = float(os.environ.get("OS_SMOKE_TAB_DEADLINE", "120"))
TITLE = "cmux-os-smoke"
result = {"steps": {}, "notes": []}


def step(name, ok, detail=None):
    result["steps"][name] = {"ok": bool(ok), **({"detail": detail} if detail is not None else {})}
    print("%-9s %s %s" % (name, "ok" if ok else "FAIL", "" if detail is None else json.dumps(detail)[:400]), flush=True)


def version_tuple(text):
    return tuple(int(p) for p in re.findall(r"\d+", text or "0")[:3])


info = plistlib.load(open(os.path.join(APP, "Contents/Info.plist"), "rb"))
bundle_id = info.get("CFBundleIdentifier", "")
min_os = info.get("LSMinimumSystemVersion", "")
guest_os = platform.mac_ver()[0]
result.update({"guest_os": guest_os, "guest_build": subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip(),
               "bundle_id": bundle_id, "ls_minimum_system_version": min_os, "app": os.path.basename(APP)})
BINARY = os.path.join(APP, "Contents/MacOS", info.get("CFBundleExecutable", ""))


def socket_path():
    """Mirror of ControlSocketPath.resolve for the bundle id (CmuxNextControl)."""
    slug = lambda s: re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    for channel in ("nightly", "rc", "staging"):
        base = "com.cmuxterm.app." + channel
        if bundle_id == base:
            return "/tmp/cmux-%s.sock" % channel
        if bundle_id.startswith(base + "."):
            return "/tmp/cmux-%s-%s.sock" % (channel, slug(bundle_id[len(base) + 1:]))
    if bundle_id.startswith("com.cmuxterm.app.debug."):
        return "/tmp/cmux-debug-%s.sock" % slug(bundle_id[len("com.cmuxterm.app.debug."):])
    if bundle_id == "com.cmuxterm.app.debug":
        return "/tmp/cmux-debug.sock"
    return os.path.expanduser("~/.local/state/cmux/cmux.sock")


SOCKET = socket_path()
result["socket"] = SOCKET


def rpc(method, params=None, timeout=30):
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


def wait(predicate, seconds, alive=None, step_s=0.5):
    """Bounded poll with a deadline; stops early when `alive` turns false."""
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        if alive is not None and not alive():
            return None
        time.sleep(step_s)
    return None


def write_result():
    failed = [name for name, s in result["steps"].items() if not s["ok"]]
    result["ok"] = bool(result["steps"]) and not failed
    result["failed_steps"] = failed
    with open(os.path.join(OUT, "result.json"), "w") as f:
        json.dump(result, f, indent=1)


# 1. OS gate: what LaunchServices would do with this bundle on this guest.
below_floor = bool(min_os) and version_tuple(guest_os) < version_tuple(min_os)
result["below_ls_minimum"] = below_floor
if below_floor:
    ls = subprocess.run(["/usr/bin/open", "-g", "-n", APP], capture_output=True, text=True, timeout=60)
    result["launchservices"] = {"exit": ls.returncode, "output": (ls.stdout + ls.stderr).strip()[-2000:]}
    print("launchservices (open) exit %d: %s" % (ls.returncode, result["launchservices"]["output"][:400]), flush=True)
    subprocess.run(["/usr/bin/pkill", "-f", BINARY], capture_output=True)

# 2. Launch the binary directly (the GUI-proof launch path).
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
scratch = tempfile.mkdtemp(prefix="os-smoke-")
open(os.path.join(scratch, "cmux.json"), "w").write("{}\n")
open(os.path.join(scratch, "ghostty"), "w").write("")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"), "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"),
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
log_path = os.path.join(OUT, "app.log")
log = open(log_path, "a")
started = time.time()
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
alive = lambda: app.poll() is None
try:
    windows = wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), LAUNCH_DEADLINE, alive)
    result["launch_seconds"] = round(time.time() - started, 1)
    if not alive():
        code = app.returncode
        tail = open(log_path, errors="replace").read()[-3000:]
        dyld = [l for l in tail.splitlines() if "dyld" in l or "Symbol not found" in l or "Library not loaded" in l]
        step("launch", False, {"exit": code, "signal": -code if code < 0 else None, "dyld": dyld[:6], "log_tail": tail[-1200:]})
        for report in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*.ips")):
            if os.path.getmtime(report) >= started - 1:
                subprocess.run(["cp", report, OUT])
                result["notes"].append("crash report " + os.path.basename(report))
    else:
        step("launch", True, {"pid": app.pid, "seconds": result["launch_seconds"]})
        step("socket", os.path.exists(SOCKET), SOCKET)
        step("window", bool(windows), {"windows": windows} if windows else "no window before the deadline")
    if windows and alive():
        before = (rpc("debug.surfaces") or {}).get("live_terminals") or 0
        # The first window opens on Home (no tabs): a new workspace brings its terminal.
        opened = rpc("action.run", {"action": "newTab", "focus": True, "wait": True})
        grown = wait(lambda: ((rpc("debug.surfaces") or {}).get("live_terminals") or 0) > before, TAB_DEADLINE, alive)
        step("terminal", grown and "error" not in (opened or {}), {"run": opened, "live_terminals_before": before,
                                                                   "after": (rpc("debug.surfaces") or {}).get("live_terminals")})

        class Page(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = ("<!doctype html><title>%s</title><h1>%s</h1>" % (TITLE, TITLE)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        page = "http://127.0.0.1:%d/" % server.server_address[1]
        opened = rpc("action.run", {"action": "openBrowser", "args": {"url": page}, "focus": True})
        state = wait(lambda: (lambda s: s if isinstance(s, dict) and s.get("title") == TITLE else None)(rpc("browser.page.state")),
                     TAB_DEADLINE, alive)
        step("browser", bool(state) and "error" not in (opened or {}),
             {"run": opened, "state": state or rpc("browser.page.state"), "cef": rpc("debug.cef")})
        shot_path = os.path.join(OUT, "window.png")
        shot = rpc("debug.window_snapshot", {"kind": "main", "path": shot_path}, timeout=60)
        step("snapshot", os.path.exists(shot_path) and os.path.getsize(shot_path) > 0, shot)
        with open(os.path.join(OUT, "surfaces.json"), "w") as f:
            json.dump(rpc("debug.surfaces"), f, indent=1)
finally:
    if alive():
        quit_reply = rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
        try:
            app.wait(timeout=30)
            step("quit", True, {"run": quit_reply, "exit": app.returncode})
        except subprocess.TimeoutExpired:
            app.send_signal(signal.SIGKILL)
            app.wait()
            step("quit", False, {"run": quit_reply, "detail": "no exit 30 s after quitEndSessions; SIGKILL"})
    write_result()
sys.exit(0 if result["ok"] else 1)
