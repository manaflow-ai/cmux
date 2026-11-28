#!/usr/bin/env python3
"""Web content in an opaque-origin frame cannot end cmux (plans/cmux-next/crash-elimination.md).

cmux NIGHTLY aborted on 2026-10-04: a frame with an opaque origin called
PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(), and the
Chromium browser process (the app process) hit
DCHECK(!caller_origin.opaque()) in AuthenticatorCommonImpl. This launches a
tagged build, serves a page on 127.0.0.1 (a secure context) whose sandboxed
srcdoc iframe (an opaque origin) calls every WebAuthn entry point, opens it in
a Chromium tab, and passes only when the frame reports every result back and
the app still answers on its socket afterwards.

Run on cmux-lawrence-2 or the fleet, never the laptop (it opens a window).
Launches the tagged app itself (no-activate, automation socket, scratch
cmux.json and an empty Ghostty config) on a fresh state: the tag's daemon
state and run marker move into the run's scratch folder first (nothing is
deleted), so no earlier tab is restored and no safe-mode restart defers the
page. At the end it quits the app and stops the tag's daemons by exact pid
(their command line starts inside this tag's app bundle).

Usage: webauthn-opaque-e2e.py --tag <tag> [--timeout 60]
"""
import argparse, glob, http.server, json, os, re, signal, socket, subprocess, sys, tempfile, threading, time
from urllib.parse import parse_qs, quote, urlparse

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--timeout", type=float, default=60)
parser.add_argument("--app", help="tagged app bundle (default: the DerivedData build of --tag)")
parser.add_argument("--bench", action="store_true", help="measure frame creation cost instead (no WebAuthn calls)")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
SCRATCH = tempfile.mkdtemp(prefix=f"webauthn-{opts.tag}-")
SUPPORT = os.path.expanduser("~/Library/Application Support")
TAG_STATE = [os.path.join(SUPPORT, "cmux/tags", opts.tag, "tui"),
             os.path.join(SUPPORT, "cmux-next", f"com.cmuxterm.app.debug.{opts.tag}")]
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")

# Each call reports "<name> resolved <value>" or "<name> rejected <error name>"
# to /result. Every one of them must come back: a call that aborts the browser
# process never does.
CALLS = {
    "uvpaa": "PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()",
    "conditional": "PublicKeyCredential.isConditionalMediationAvailable()",
    "capabilities": "PublicKeyCredential.getClientCapabilities().then(c=>JSON.stringify(c))",
    "get": "navigator.credentials.get({publicKey:{challenge:new Uint8Array(16),timeout:1000}})",
    "create": ("navigator.credentials.create({publicKey:{challenge:new Uint8Array(16),rp:{name:'x'},"
               "user:{id:new Uint8Array(4),name:'u',displayName:'u'},pubKeyCredParams:[{type:'public-key',alg:-7}],"
               "timeout:1000}})"),
}


def frame_script(label, target="window"):
    """Runs every call on `target`'s PublicKeyCredential and navigator, reports
    each result as "<label>.<call> ...", then checks that page script cannot
    undo a guard: a non-native method must be non-configurable and non-writable."""
    calls = "".join(
        f"Promise.race([Promise.resolve().then(()=>{code}),new Promise((_,no)=>setTimeout(()=>no({{name:'pending'}}),15000))])"
        f".then(v=>r('{label}.{name} resolved '+v),e=>r('{label}.{name} rejected '+(e&&e.name)));"
        for name, code in CALLS.items())
    lock = ("const d=typeof PublicKeyCredential==='function'&&Object.getOwnPropertyDescriptor(PublicKeyCredential,'isUserVerifyingPlatformAuthenticatorAvailable');"
            f"r('{label}.locked '+(!d?'absent':/\\[native code\\]/.test(String(d.value))?'native':String(!d.configurable&&!d.writable"
            "&&!delete PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable)));")
    return ("const r=m=>top.postMessage(m,'*');"
            f"(({{PublicKeyCredential,navigator}})=>{{{calls}{lock}}})({target});")


def srcdoc(script, sandbox=True):
    attribute = " sandbox='allow-scripts'" if sandbox else ""
    escaped = script.replace("&", "&amp;").replace('"', "&quot;")
    return f"<iframe{attribute} srcdoc=\"<script>{escaped}</script>\"></iframe>"


def srcdoc_body(script):
    escaped = ("<body><script>" + script + "</script></body>").replace("&", "&amp;").replace('"', "&quot;")
    return f"<iframe sandbox='allow-scripts' srcdoc=\"{escaped}\"></iframe>"


# Frames with an opaque origin: a sandboxed srcdoc iframe, a sandboxed src
# iframe, a data: URL iframe (not a secure context: no PublicKeyCredential),
# a sandboxed frame nested in a sandboxed frame, and a sandboxed iframe
# created after load. An about:blank child of a sandboxed frame gets a new
# opaque origin (its parent cannot script it, SecurityError), so no page
# script can run there; the nested frame is the child case script can reach.
FRAMES = ["srcdoc", "src", "data", "nested", "late"]
LATE = ("addEventListener('load',()=>setTimeout(()=>{const t=document.createElement('template');"
        "t.innerHTML=" + json.dumps(srcdoc(frame_script("late"))).replace("</", "<\\/") + ";document.body.appendChild(t.content)},500));")
# The page itself (127.0.0.1 is a secure context, not opaque) must keep the
# real methods: it reports whether its isUserVerifyingPlatformAuthenticatorAvailable
# is native code and what the real call returned.
# The page keeps every report and sends the whole set every 500 ms, so a
# lost request cannot drop a result.
PARENT = ("const seen=new Set();const report=m=>seen.add(String(m));"
          "setInterval(()=>fetch('/result?v='+encodeURIComponent(JSON.stringify([...seen]))),500);"
          "addEventListener('message',e=>report(e.data));"
          "const native=/\\[native code\\]/.test(String(PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable));"
          "PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(v=>report('parent native '+native+' resolved '+v),"
          "e=>report('parent native '+native+' rejected '+(e&&e.name)));")
PAGE = ("<html><body><script>" + PARENT + LATE + "</script>"
        + srcdoc(frame_script("srcdoc"))
        + "<iframe sandbox='allow-scripts' src='/frame'></iframe>"
        + "<iframe src='data:text/html," + quote("<script>" + frame_script("data") + "</script>") + "'></iframe>"
        + srcdoc_body("document.body.insertAdjacentHTML('beforeend'," + json.dumps(srcdoc(frame_script("nested"))).replace("</", "<\\/") + ")")
        + "opaque webauthn</body></html>")
FRAME_PAGE = "<html><body><script>" + frame_script("src") + "</script></body></html>"
# --bench: the cost of a frame's context creation, normal and opaque, as the
# mean time per loaded frame of 200 same-origin and 200 sandboxed srcdoc frames.
BENCH = ("<html><body><script>const report=m=>fetch('/result?v='+encodeURIComponent(JSON.stringify([m])));"
         "async function batch(sandbox){const t=performance.now();await Promise.all(Array.from({length:200},()=>"
         "new Promise(ok=>{const i=document.createElement('iframe');if(sandbox)i.sandbox='allow-scripts';"
         "i.srcdoc='<script>1<\\/script>';i.onload=ok;document.body.appendChild(i)})));"
         "const ms=(performance.now()-t)/200;document.querySelectorAll('iframe').forEach(i=>i.remove());return ms}"
         "addEventListener('load',async()=>{const plain=await batch(false);const opaque=await batch(true);"
         "report('bench plain '+plain.toFixed(3)+' opaque '+opaque.toFixed(3))})</script></body></html>")
RESULTS = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/result":
            for value in json.loads(parse_qs(url.query).get("v", ["[]"])[0]):
                key = value.split(" ", 1)[0]
                if key not in RESULTS:
                    print(f"frame: {value}", flush=True)
                RESULTS[key] = value
        body = {"/": PAGE, "/frame": FRAME_PAGE, "/bench": BENCH}.get(url.path, "ok").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def rpc(method, params=None):
    """One request on the tagged debug socket (newline-delimited JSON)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
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


def wait(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    return None


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_address[1]}/{'bench' if opts.bench else ''}"
app = None
failed = None
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    for index, path in enumerate(TAG_STATE):
        if os.path.exists(path):
            os.rename(path, os.path.join(SCRATCH, f"previous-state-{index}"))
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(SCRATCH, "app.log"), "a"),
                           stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 90):
        sys.exit("FAIL the tagged app did not come up")
    # `focus: true`: a socket run may not change the view by default
    # (ActionRunScope), so the new tab would stay unselected behind the
    # start tab, and Chromium never creates or loads an unshown tab.
    opened = rpc("action.run", {"action": "tab new-chromium", "focus": True, "args": {"url": url}})
    print(f"opened {url}: {json.dumps(opened)[:300]}", flush=True)
    expected = {"bench"} if opts.bench else {f"{frame}.{call}" for frame in FRAMES for call in [*CALLS, "locked"]} | {"parent"}
    done = wait(lambda: app.poll() is not None or set(RESULTS) >= expected, opts.timeout)
    time.sleep(3)  # test harness: an abort after the last report still fails the run
    if app.poll() is not None:
        failed = f"the app exited with {app.returncode} (signal {-app.returncode if app.returncode < 0 else 0})"
    elif not done or not set(RESULTS) >= expected:
        failed = f"missing results {sorted(expected - set(RESULTS))} after {opts.timeout:.0f} s"
    elif not opts.bench and not RESULTS["parent"].startswith("parent native true"):
        failed = "the non-opaque page lost its native WebAuthn methods"
    elif not opts.bench and any(not re.match(r"\S+ rejected (NotAllowedError|SecurityError)$", RESULTS[f"{frame}.{call}"])
                                and not (frame == "data" and RESULTS[f"{frame}.{call}"].endswith("rejected TypeError"))
                                for frame in FRAMES for call in ("create", "get")):
        failed = "navigator.credentials.create/get from an opaque frame did not reject with NotAllowedError or SecurityError"
    elif not opts.bench and any(RESULTS[f"{frame}.locked"].split(" ", 1)[1] not in ("native", "true", "absent") for frame in FRAMES):
        failed = "page script can replace or delete a guarded method"
    elif (rpc("debug.surfaces") or {}).get("error"):
        failed = "the app stopped answering on its socket"
    if failed:
        page = rpc("debug.cef.devtools", {"method": "Runtime.evaluate", "params": {"returnByValue": True,
                   "expression": "location.href+' '+document.readyState+' secure='+isSecureContext"}})
        print(f"page: {json.dumps(page)[:400]}", flush=True)
        sys.exit(f"FAIL {failed}; results {RESULTS}")
    if opts.bench:
        print(f"ok: {RESULTS['bench']} (ms per frame)")
    else:
        print(f"ok: every WebAuthn call from {len(FRAMES)} opaque frames came back and the app is alive")
finally:
    server.shutdown()
    if app and app.poll() is not None and app.returncode != 0:
        print(open(os.path.join(SCRATCH, "app.log")).read()[-3000:])
    if app and app.poll() is None:
        rpc("debug.quit")
        try:
            app.wait(timeout=15)
        except subprocess.TimeoutExpired:
            app.send_signal(signal.SIGKILL)
            print(f"killed {app.pid}", flush=True)
    # The tag's daemons: exact pids whose command line starts inside this
    # tag's app bundle (no pattern kill).
    bundle = os.path.join(APP, "Contents") + os.sep
    listing = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True).stdout
    for line in listing.splitlines():
        pid, _, args = line.strip().partition(" ")
        if args.startswith(bundle) and int(pid) != os.getpid():
            os.kill(int(pid), signal.SIGTERM)
            print(f"stopped {pid}", flush=True)
