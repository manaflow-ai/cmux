#!/usr/bin/env python3
"""A proxied Cloud browser tab never reaches this Mac's localhost (live check).

Starts a listener on 127.0.0.1 and ::1 (this Mac's localhost) and a small HTTP
proxy on 127.0.0.1 (the stand-in for a Cloud machine's proxy), launches the
tagged app (no activation, automation socket), and asks it, through the Cloud
page's own call path (`debug.page` `call` -> `cmux.app.action.run`
`browser.tab.open`), for a CEF tab on http://localhost:<listener port>/ through
the proxy. Passes when the proxy sees the request and the listener sees no
connection. Also checks the typed refusals (WebKit, a non-local proxy host, a
page other than the Cloud page).

  scripts/cmux-next/proxied-tab-e2e.py --tag <tag> [--out DIR]

Run it only on a fleet GUI host (it opens a window); never on a laptop in use.
Exit 1 on any failure. Evidence (JSON, proxy and listener logs, app log) goes to
--out (default $NX_ARTIFACTS or a temp dir).
"""
import argparse, glob, json, os, plistlib, signal, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="proxied-tab-e2e-"))
parser.add_argument("--wait", type=float, default=45.0, help="seconds to wait for the proxied request")
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
events = []
lock = threading.Lock()


def log(kind, **fields):
    with lock:
        events.append({"t": round(time.time(), 3), "kind": kind, **fields})


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def serve(listener, handler):
    def loop():
        while True:
            try:
                conn, peer = listener.accept()
            except OSError:
                return
            threading.Thread(target=handler, args=(conn, peer), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()


# This Mac's localhost on the port the tab asks for: any connection here is a leak.
TARGET_PORT = free_port()
local_hits = []
listeners = []
for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
    sock = socket.socket(family)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, TARGET_PORT))
    sock.listen(16)
    listeners.append(sock)

    def local_handler(conn, peer, host=host):
        data = conn.recv(4096)
        local_hits.append({"listener": host, "peer": str(peer), "first_line": data.split(b"\r\n", 1)[0].decode("latin-1")})
        log("LOCAL_HIT", listener=host, first_line=local_hits[-1]["first_line"])
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nTHIS-MAC!!")
        conn.close()
    serve(sock, local_handler)

# The stand-in for the Cloud machine's proxy: answers every request itself.
PROXY_PORT = free_port()
proxy_requests = []
proxy = socket.socket()
proxy.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
proxy.bind(("127.0.0.1", PROXY_PORT))
proxy.listen(16)


def proxy_handler(conn, peer):
    try:
        while True:
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk
            line = data.split(b"\r\n", 1)[0].decode("latin-1")
            proxy_requests.append(line)
            log("PROXY_REQUEST", line=line)
            body = b"<html><title>proxied</title><body>via the machine proxy</body></html>"
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: " + str(len(body)).encode() +
                         b"\r\n\r\n" + body)
    except OSError:
        pass
    finally:
        conn.close()


serve(proxy, proxy_handler)


def rpc(method, params=None):
    """One request on the tagged app's control socket (line JSON)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(60)
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
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def tab_open(args, page="cmux.cloud"):
    reply = rpc("debug.page", {"page": page, "action": "call", "op": "cmux.app.action.run",
                               "params": {"action": "browser.tab.open", "args": args}})
    log("CALL", page=page, args=args, reply=reply)
    return reply


def args(port=PROXY_PORT, host="127.0.0.1", engine="cef"):
    return {"url": f"http://localhost:{TARGET_PORT}/", "engine": engine,
            "machineStore": {"machine": "vm-e2e", "machineName": "e2e-box",
                             "proxy": {"kind": "http", "host": host, "port": port}}}


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app_log = open(os.path.join(opts.out, "app.log"), "a")
env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
app = subprocess.Popen([BINARY], env=env, stdout=app_log, stderr=app_log, stdin=subprocess.DEVNULL)
log("APP_STARTED", pid=app.pid, app=os.path.basename(APP), target_port=TARGET_PORT, proxy_port=PROXY_PORT)
failures = []
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 90, 0.5):
        failures.append("tagged app did not come up")
    else:
        # Typed refusals first: none of them may open anything.
        for name, call, code in (
            ("webkit", lambda: tab_open(args(engine="webkit")), "cmux.browser.proxy_requires_cef"),
            ("non-local proxy host", lambda: tab_open(args(host="localhost")), "cmux.browser.proxy_invalid"),
            ("other page", lambda: tab_open(args(), page="cmux.history"), None),
        ):
            reply = call()
            got = (reply.get("code") if isinstance(reply, dict) else None) or json.dumps(reply)
            if code and code not in json.dumps(reply):
                failures.append(f"refusal {name}: want {code}, got {got}")
            if not code and '"t": "ok"' in json.dumps(reply):
                failures.append(f"refusal {name}: the call was accepted: {got}")
        reply = tab_open(args())
        if '"t": "ok"' not in json.dumps(reply):
            failures.append(f"browser.tab.open was not accepted: {json.dumps(reply)}")
        else:
            seen = wait(lambda: [r for r in proxy_requests if f"localhost:{TARGET_PORT}" in r], opts.wait, 0.5)
            if not seen:
                failures.append(f"the proxy saw no request for localhost:{TARGET_PORT} in {opts.wait}s")
            time.sleep(5)  # late requests (favicon, retries) must also stay off this Mac
        if local_hits:
            failures.append(f"this Mac's localhost got {len(local_hits)} connection(s): {local_hits}")
        log("SURFACES", surfaces=rpc("debug.surfaces"))
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    for sock in listeners + [proxy]:
        sock.close()

summary = {"pass": not failures, "failures": failures, "target_port": TARGET_PORT, "proxy_port": PROXY_PORT,
           "proxy_requests": proxy_requests, "local_hits": local_hits, "events": events}
with open(os.path.join(opts.out, "proxied-tab-e2e.json"), "w") as f:
    json.dump(summary, f, indent=1)
print(f"proxy requests: {proxy_requests}")
print(f"this Mac's localhost connections: {len(local_hits)}")
for failure in failures:
    print(f"FAIL {failure}")
print("PASS" if not failures else "FAIL", f"(evidence {opts.out}/proxied-tab-e2e.json)")
sys.exit(0 if not failures else 1)
