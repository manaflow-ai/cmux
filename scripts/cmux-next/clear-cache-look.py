#!/usr/bin/env python3
"""Clear Browsing Data's cache option, looked at on a real Chromium engine.

The unit tests of the cache option call the delete on a directory with the layout of a Chromium profile. This
script runs the action itself in a tagged cmux-next app and reads what Chromium then does.

Run 1: start the app, make a second browser profile, and open a local page in it. The page registers a service
worker; the worker's install puts two files into the cache "look-v1" and answers them from that cache (on a miss
it fetches the file and puts it back). The page reports to this script's server. The script waits for files
below `<Chromium profile>/Service Worker/CacheStorage`, closes the workspace and quits the app.

Run 2: start the app again. Before a tab of that profile opens, it runs `browserProfile.clearBrowsingData` with
only the cache option, first for the last hour (Cache Storage must stay), then for all time (Cache Storage must
go, and no moved-aside `.cleared-` directory may stay). Then it opens the page again and records the page's
report, the requests the server saw, and that the directory is back.

Usage: clear-cache-look.py --tag TAG --app PATH/TO/App.app [--out DIR] [--json FILE]
Exit 0 when every check holds, 1 when one does not, 2 when the app or the page gave no answer.
"""

import argparse
import glob
import http.server
import json
import os
import pwd
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
opts = parser.parse_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"clear-cache-look-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
PROFILE = f"clear-cache-look-{os.getpid()}"
CACHE_STORAGE = os.path.join("Service Worker", "CacheStorage")
MOVED_ASIDE = ".cleared-"
LAUNCHED = []
app = None

WORKER = """
const NAME = 'look-v1';
const FILES = ['/a.txt', '/b.txt'];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(NAME).then(cache => cache.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => {
  if (!FILES.includes(new URL(event.request.url).pathname)) return;
  event.respondWith((async () => {
    const cache = await caches.open(NAME);
    const hit = await cache.match(event.request);
    if (hit) return new Response(await hit.text(), {headers: {'x-look-from': 'cache'}});
    const reply = await fetch(event.request);
    await cache.put(event.request, reply.clone());
    return new Response(await reply.text(), {headers: {'x-look-from': 'network'}});
  })());
});
"""

PAGE = """<!doctype html><title>clear-cache-look</title><body>clear-cache-look<script>
(async () => {
  const out = {};
  try {
    out.controlled_at_load = !!navigator.serviceWorker.controller;
    out.names_at_load = await caches.keys();
    await navigator.serviceWorker.register('/sw.js');
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) {
      await Promise.race([
        new Promise(done => navigator.serviceWorker.addEventListener('controllerchange', done, {once: true})),
        new Promise(done => setTimeout(done, 5000)),
      ]);
    }
    out.controlled = !!navigator.serviceWorker.controller;
    const reply = await fetch('/a.txt');
    out.a = (await reply.text()).trim();
    out.a_from = reply.headers.get('x-look-from');
    out.names = await caches.keys();
  } catch (error) {
    out.error = String(error);
  }
  await fetch('/report', {method: 'POST', body: JSON.stringify(out)});
})();
</script>"""


class Site:
    """The page's server: it notes each request with the phase of the look, and keeps the page's reports."""

    def __init__(self):
        self.phase = "run1"
        self.requests = []
        self.reports = {}
        self.arrived = threading.Event()
        site = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def answer(self, status, kind, body):
                self.send_response(status)
                self.send_header("Content-Type", kind)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                site.requests.append({"phase": site.phase, "path": self.path})
                if self.path in ("/", "/index.html"):
                    self.answer(200, "text/html; charset=utf-8", PAGE.encode())
                elif self.path == "/sw.js":
                    self.answer(200, "text/javascript", WORKER.encode())
                elif self.path in ("/a.txt", "/b.txt"):
                    self.answer(200, "text/plain", self.path[1:2].encode())
                else:
                    self.answer(404, "text/plain", b"")

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                try:
                    site.reports[site.phase] = json.loads(body)
                except ValueError:
                    site.reports[site.phase] = {"error": "the report was not JSON"}
                self.answer(204, "text/plain", b"")
                site.arrived.set()

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def report(self, phase, seconds):
        self.phase = phase
        self.arrived.clear()
        return lambda: self.reports.get(phase) if self.arrived.wait(seconds) else None

    def paths(self, phase):
        return [r["path"] for r in self.requests if r["phase"] == phase]


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


def action(name, args=None, timeout=60):
    reply = rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)
    if isinstance(reply, dict) and reply.get("error"):
        stop(2, f"the action {name} failed: {reply['error']}")
    return reply


def wait(check, seconds, step=0.2):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def support_roots():
    """Application Support of the step's HOME and of the account: the app can use either."""
    homes = {os.environ["HOME"], pwd.getpwuid(os.getuid()).pw_dir}
    return [os.path.join(home, "Library", "Application Support") for home in sorted(homes)]


def stores():
    """Each Cache Storage directory of a Chromium profile of this tag's app (of any app, if none names the tag)."""
    found = [p for root in support_roots() for p in glob.glob(os.path.join(root, "*", "Chromium", "Profile-*", CACHE_STORAGE))]
    tagged = [p for p in found if TAG.lower() in p.split(os.sep + "Chromium" + os.sep)[0].lower()]
    return set(tagged or found)


def file_count(directory):
    return sum(len(files) for _, _, files in os.walk(directory))


def launch():
    global app
    if os.path.exists(SOCKET):
        ps = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout
        if any(line.startswith(APP + "/Contents/MacOS/") for line in ps.splitlines()):
            sys.exit(f"{SOCKET} exists and a {TAG} app runs; pick a fresh tag")
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900"}
    os.makedirs(opts.out, exist_ok=True)
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    LAUNCHED.append(app.pid)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        stop(2, "the tagged app did not come up")
    time.sleep(2)  # the first workspace


def quit_app():
    global app
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
            app.wait(timeout=10)
    app = None
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def cleanup():
    if not LAUNCHED:
        return
    if app:
        # No `action()` here: a failed delete must not stop the cleanup.
        rpc("action.run", {"action": "browserProfile.delete", "args": {"browserProfile": PROFILE}, "focus": True,
                           "origin": "script"}, timeout=10)
        quit_app()
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in ps.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith(APP + "/") and int(parts[0]) != os.getpid():
            try:
                os.kill(int(parts[0]), signal.SIGTERM)
            except OSError:
                pass
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


RESULT = {"tag": TAG, "host": os.uname().nodename, "checks": {}, "pass": False}


def stop(code, reason=None):
    if reason:
        RESULT["stopped"] = reason
        print(f"CLEAR-CACHE-LOOK STOPPED: {reason}", flush=True)
    try:
        cleanup()
    finally:
        if opts.json:
            os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
            open(opts.json, "w").write(json.dumps(RESULT, indent=1))
    sys.exit(code)


def open_page(site, phase):
    """Opens the page in the profile, in a workspace of its own; the page's report, or None."""
    arrived = site.report(phase, 90)
    action("newTab", {"name": f"clear-cache-look-{phase}"})
    time.sleep(1)  # the new workspace's pane
    action("browserProfile.openLink", {"browserProfile": PROFILE, "url": site.url})
    return arrived()


def clear(scope):
    action("browserProfile.clearBrowsingData",
           {"browserProfile": PROFILE, "range": scope, "history": False, "cookies": False, "cache": True})


def main():
    if not BINARY:
        sys.exit(f"no binary in {APP}/Contents/MacOS")
    site = Site()
    checks = RESULT["checks"]

    # Run 1: fill the profile's Cache Storage.
    before = stores()
    launch()
    action("browserProfile.new", {"name": PROFILE})
    first = open_page(site, "run1")
    RESULT["run1"] = {"report": first, "requests": site.paths("run1")}
    if first is None:
        stop(2, "the page gave no report in run 1")
    checks["run1_page_reports_no_error"] = "error" not in first and first.get("a") == "a"
    store = wait(lambda: next((p for p in sorted(stores() - before) if file_count(p) > 0), None), 30)
    checks["run1_cache_storage_has_files"] = bool(store)
    if not store:
        RESULT["run1"]["stores"] = sorted(stores() - before)
        stop(1, "no new Cache Storage directory with files after the page's report")
    profile_dir = os.path.dirname(os.path.dirname(store))
    RESULT["profile_directory"] = os.path.basename(profile_dir)
    RESULT["run1"]["files"] = file_count(store)
    action("closeWorkspace", {"confirm": True})
    time.sleep(2)  # the tab's close
    quit_app()

    # Run 2: the clear, before Chromium opens the profile.
    launch()
    survived = file_count(store) if os.path.isdir(store) else 0
    checks["cache_storage_survives_the_quit"] = survived > 0
    RESULT["run2"] = {"files_at_start": survived}
    if not survived:
        stop(1, "the Cache Storage directory has no files after the quit")
    clear("hour")
    time.sleep(3)  # a delete that must not come
    checks["the_last_hour_keeps_cache_storage"] = os.path.isdir(store) and file_count(store) > 0
    clear("all")
    gone = wait(lambda: not os.path.exists(store), 20)
    checks["all_time_removes_cache_storage"] = bool(gone)
    leftovers = wait(lambda: not [n for n in os.listdir(profile_dir) if n.startswith(MOVED_ASIDE)], 30)
    checks["no_moved_aside_directory_stays"] = bool(leftovers)
    RESULT["run2"]["moved_aside_left"] = [n for n in os.listdir(profile_dir) if n.startswith(MOVED_ASIDE)]
    checks["the_registrations_stay"] = os.path.isdir(os.path.join(profile_dir, "Service Worker", "Database"))

    # The page again: what Chromium and the worker do with the directory gone.
    again = open_page(site, "reopen")
    RESULT["run2"].update({"report": again, "requests": site.paths("reopen")})
    if again is None:
        stop(2, "the page gave no report after the clear")
    checks["the_page_reports_no_error_after_the_clear"] = "error" not in again and again.get("a") == "a"
    checks["the_worker_fetches_its_file_again"] = "/a.txt" in site.paths("reopen")
    back = wait(lambda: os.path.isdir(store) and file_count(store) > 0, 30)
    checks["cache_storage_is_back"] = bool(back)
    RESULT["run2"]["files_after_reopen"] = file_count(store) if os.path.isdir(store) else 0
    action("closeWorkspace", {"confirm": True})

    RESULT["pass"] = all(checks.values())
    print(json.dumps(RESULT, indent=1), flush=True)
    for name, held in checks.items():
        print(f"{'ok  ' if held else 'FAIL'} {name}", flush=True)
    print("CLEAR-CACHE-LOOK", "PASS" if RESULT["pass"] else "FAIL", flush=True)
    stop(0 if RESULT["pass"] else 1)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: stop(143, "terminated"))
    try:
        main()
    except KeyboardInterrupt:
        stop(130, "interrupted")
