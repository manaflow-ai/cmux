#!/usr/bin/env python3
"""Live check of the cmux.16 CEF pin and shim batch on a tagged DEBUG build.

  scripts/cmux-next/cef16-live-check.py --tag <tag> [--out DIR]

Launches the tagged app (no activation, automation socket), opens a Chromium
tab on a local http page, then checks:
 1. CEF started with fork API 17 and the shim ABI identity the app expects;
 2. the page loads and its title arrives;
 3. raw DevTools: with events watched, a raw send with id 1073741900 answers
    as event 32 (CMUX_SHIM_DEVTOOLS_EVENT), never as DEVTOOLS_RESULT; a raw
    send with id 5 is refused (-1);
 4. cmux-page: cmux-page://cmux.history/ renders under its own CSP, and a web
    page's fetch('cmux-page://cmux.history/index.html') fails.
Run it only on a fleet GUI host (it opens a window). Exit 1 on any failure;
evidence JSON goes to --out (default $NX_ARTIFACTS or a temp dir).
"""
import argparse, glob, http.server, json, os, plistlib, signal, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="cef16-live-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
TMP = os.environ.get("TMPDIR", "/tmp")
CONFIG = os.path.join(opts.out, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": TMP,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
evidence = {"checks": {}, "calls": []}
failures = []

TITLE = "cef16 live page"


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<html><head><title>{TITLE}</title></head><body>hello cef16</body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
PAGE = f"http://127.0.0.1:{server.server_address[1]}/"


def rpc(method, params=None, timeout=60):
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
        result = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        result = {"error": str(error)}
    evidence["calls"].append({"method": method, "params": params, "result": result})
    return result


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def cdp(method, params=None):
    result = rpc("debug.cef.devtools", {"method": method, "params": params or {}})
    if not isinstance(result, dict) or "error" in result:
        return {"error": result}
    try:
        return json.loads(result.get("result") or "{}")
    except ValueError:
        return {"error": result}


def js(expression):
    value = cdp("Runtime.evaluate", {"expression": expression, "returnByValue": True, "awaitPromise": True})
    return (value.get("result") or {}).get("value") if "error" not in value else value


def check(name, ok, detail):
    evidence["checks"][name] = {"pass": bool(ok), "detail": detail}
    if not ok:
        failures.append(f"{name}: {json.dumps(detail)[:400]}")
    print(("PASS " if ok else "FAIL ") + name + ": " + json.dumps(detail)[:300])


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
log = open(os.path.join(opts.out, "app.log"), "a")
env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
evidence["pid"] = app.pid
started = time.time()
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 90):
        sys.exit("tagged app did not come up")
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": PAGE}})

    # 1. CEF started with fork API 17 and the expected shim ABI.
    info = wait(lambda: (lambda r: r if "fork_api" in r else None)(rpc("debug.cef.raw", {"action": "info"})), 60)
    cef = rpc("debug.cef")
    check("1 fork API 17, shim loaded", bool(info) and info.get("fork_api") == 17 and cef.get("unavailable") in (None,),
          {"info": info, "cef_state": cef.get("state"), "unavailable": cef.get("unavailable")})

    # 2. The page loads and its title arrives.
    state = wait(lambda: (lambda s: s if s.get("title") == TITLE else None)(rpc("browser.page.state")), 30)
    check("2 page title arrives", bool(state), {"state": state or rpc("browser.page.state")})

    # 3. Raw DevTools.
    rpc("debug.cef.raw", {"action": "clear"})
    watch = rpc("debug.cef.raw", {"action": "watch", "enabled": True})
    raw_id = 1073741900
    sent = rpc("debug.cef.raw", {"action": "send", "message": json.dumps(
        {"id": raw_id, "method": "Runtime.evaluate", "params": {"expression": "'\\ud800'"}})})
    log_reply = wait(lambda: (lambda l: l if any(f'"id":{raw_id}' in m["json"].replace(" ", "") for m in l.get("messages", [])) else None)(
        rpc("debug.cef.raw", {"action": "log"})), 15)
    low = rpc("debug.cef.raw", {"action": "send", "message": json.dumps({"id": 5, "method": "Runtime.evaluate",
                                                                          "params": {"expression": "1"}})})
    missing = rpc("debug.cef.raw", {"action": "send", "message": json.dumps({"method": "Runtime.evaluate"})})
    final_log = rpc("debug.cef.raw", {"action": "log"})
    replies = [m["json"] for m in final_log.get("messages", []) if f'"id":{raw_id}' in m["json"].replace(" ", "")]
    check("3a raw send accepted", watch.get("ok") is True and sent.get("result") == 1, {"watch": watch, "send": sent})
    check("3b raw reply arrives as event 32", bool(log_reply) and len(replies) == 1, {"replies": replies})
    check("3c raw reply never a DEVTOOLS_RESULT", raw_id not in final_log.get("result_ids", []),
          {"result_ids": final_log.get("result_ids")})
    check("3d raw send with id 5 refused (-1)", low.get("result") == -1 and missing.get("result") == -1,
          {"id5": low, "no_id": missing})
    events = [m["json"] for m in final_log.get("messages", []) if '"id"' not in m["json"]]
    evidence["watched_events_sample"] = events[:5]
    rpc("debug.cef.raw", {"action": "watch", "enabled": False})

    # 4. cmux-page.
    origin_fetch = js("fetch('cmux-page://cmux.history/index.html').then(r => 'ok:' + r.status, e => 'err:' + e)")
    check("4b a web page cannot fetch cmux-page", isinstance(origin_fetch, str) and origin_fetch.startswith("err:"),
          {"fetch": origin_fetch})
    cdp("Page.navigate", {"url": "cmux-page://cmux.history/"})
    page = wait(lambda: (lambda u: u if isinstance(u, str) and u.startswith("cmux-page://cmux.history") else None)(
        js("document.readyState === 'complete' ? location.href : ''")), 20)
    title = js("document.title")
    text = js("(document.body && document.body.innerText || '').slice(0, 200)")
    elements = js("document.querySelectorAll('*').length")
    csp = js("fetch(location.origin + '/index.html').then(r => r.headers.get('content-security-policy') + ' | ' + "
             "r.headers.get('x-content-type-options'), e => 'err:' + e)")
    check("4a cmux-page://cmux.history renders", bool(page) and isinstance(elements, int) and elements > 5,
          {"url": page, "title": title, "text": text, "elements": elements})
    check("4c cmux-page response carries its own CSP and nosniff",
          isinstance(csp, str) and "default-src" in csp and "nosniff" in csp, {"headers": csp})
    try:
        shot = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "window.png")})
        evidence["snapshot"] = shot
    except Exception as error:  # noqa: BLE001
        evidence["snapshot"] = str(error)
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    server.shutdown()
    evidence["app_exit"] = app.returncode
    try:
        logs = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start",
                               time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(started - 2)),
                               "--predicate", f"processID == {app.pid}"], capture_output=True, text=True, timeout=120).stdout
        with open(os.path.join(opts.out, "unified.log"), "w") as f:
            f.write(logs)
        lines = [line for line in logs.splitlines() if any(k in line for k in ("CEF", "shim", "abi", "ABI", "Chromium"))]
        evidence["log_cef_lines"] = lines[:60]
        evidence["log_shim_refusal"] = [line for line in lines if "abiMismatch" in line or "missingSymbol" in line]
        if evidence["log_shim_refusal"]:
            failures.append("shim refusal in the log")
    except (OSError, subprocess.TimeoutExpired) as error:
        evidence["log_error"] = str(error)

evidence["failures"] = failures
with open(os.path.join(opts.out, "cef16-live.json"), "w") as f:
    json.dump(evidence, f, indent=1)
print("PASS" if not failures else "FAIL", f"(evidence {opts.out}/cef16-live.json)")
sys.exit(0 if not failures else 1)
