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
go, and no moved-aside `.cleared-` directory may stay). The clear is not part of the action's answer, so the
script waits for the sign of the first clear: the cache directories of the profile (`Cache`, `GPUCache` and
three more) go for each range. If none of them is there at the second start, the script makes an empty
`GPUCache` there first, and the JSON says so. Then it opens the page again and records the page's report, the
requests the server saw, and that the directory is back.

The script takes a Cache Storage directory only below the tagged app's own directory in Application Support
(its name is `com.cmuxterm.app.debug.` and the tag). Of each other app it lists only the names of the profile
directories.

What stays on the Mac: the profile's record in the tagged app's state (the action that deletes a profile is for
a person only, so no script can run it) and the first workspace of the tag's layout. After the quit the script
removes the profile's directory, but only a `Profile-*` directory of the tagged app that was not there before
run 1; if that test does not hold, the directory stays and the JSON says so.

Usage: clear-cache-look.py --tag TAG --app PATH/TO/App.app [--out DIR] [--json FILE]
Exit 0 when every check holds, 1 when one does not, 2 when the app, the page or the script itself failed,
130 on an interrupt, 143 when terminated. Each exit writes the JSON.
"""

import argparse
import glob
import http.server
import json
import os
import pwd
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from state_wait import wait_stable  # noqa: E402

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
# The last part of a tagged build's bundle id, as scripts/reload.sh makes it from the tag.
TAG_PART = re.sub(r"[^a-z0-9]+", ".", TAG.lower()).strip(".") or "agent"
PROFILE = f"clear-cache-look-{os.getpid()}"
CACHE_STORAGE = os.path.join("Service Worker", "CacheStorage")
# The directories that the cache option removes for each range.
CACHE_DIRECTORIES = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]
MOVED_ASIDE = ".cleared-"
# The write of a new profile's record to the daemon runs in the background, after `browserProfile.new` answers.
# So an action that names the profile is tried again for this many seconds before its error stops the look
# (also after a start: when the records are there is not known).
RECORD_PATIENCE = 20
LAUNCHED = []
STATE = {"scratch": None, "profile_dir": None, "profiles_before": None, "page_open": False, "stopping": False}
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


def action(name, args=None, timeout=60, target=None, patience=0):
    """Runs an action; an error stops the look. `patience`: the seconds for which a refused call is tried again."""
    params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
    if target:
        params["target"] = target
    deadline = time.time() + patience
    while True:
        reply = rpc("action.run", params, timeout=timeout)
        error = reply.get("error") if isinstance(reply, dict) else None
        if not error:
            return reply
        if time.time() >= deadline:
            stop(2, f"the action {name} failed: {error}")
        time.sleep(0.5)


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


def panes():
    return [p for w in ((rpc("debug.surfaces") or {}).get("windows") or []) for p in w.get("panes", [])]


def scratch():
    """The driver's own directory, below --out; `stop` removes it."""
    if not STATE["scratch"]:
        os.makedirs(opts.out, exist_ok=True)
        STATE["scratch"] = tempfile.mkdtemp(prefix=f"clear-cache-look-{TAG}-", dir=opts.out)
        open(os.path.join(STATE["scratch"], "ghostty"), "w").close()
        open(os.path.join(STATE["scratch"], "cmux.json"), "w").write("{}\n")
    return STATE["scratch"]


def support_roots():
    """Application Support of the step's HOME and of the account: the app can use either."""
    homes = {os.environ["HOME"], pwd.getpwuid(os.getuid()).pw_dir}
    return [os.path.join(home, "Library", "Application Support") for home in sorted(homes)]


def of_tagged_app(profile_dir):
    """True for `<Application Support>/com.cmuxterm.app.debug.<the tag>/Chromium/<profile_dir's name>`."""
    chromium = os.path.dirname(profile_dir)
    app_directory = os.path.basename(os.path.dirname(chromium))
    return os.path.basename(chromium) == "Chromium" and app_directory.lower() == "com.cmuxterm.app.debug." + TAG_PART


def profiles():
    """The path of each Chromium profile directory of each app, in each Application Support (names only)."""
    return {p for root in support_roots() for p in glob.glob(os.path.join(root, "*", "Chromium", "Profile-*"))}


def stores():
    """Each Cache Storage directory of a Chromium profile of the tagged app. That of another app is never taken."""
    found = {os.path.join(p, CACHE_STORAGE) for p in profiles() if of_tagged_app(p)}
    return {p for p in found if os.path.isdir(p)}


def file_count(directory):
    return sum(len(files) for _, _, files in os.walk(directory))


def cache_directories(profile_dir):
    return [name for name in CACHE_DIRECTORIES if os.path.isdir(os.path.join(profile_dir, name))]


def moved_aside(profile_dir):
    return [name for name in os.listdir(profile_dir) if name.startswith(MOVED_ASIDE)]


def launch():
    global app
    if os.path.exists(SOCKET):
        ps = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout
        if any(line.startswith(APP + "/Contents/MacOS/") for line in ps.splitlines()):
            stop(2, f"{SOCKET} exists and a {TAG} app runs; pick a fresh tag")
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch(), "cmux.json"),
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch(), "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900"}
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    LAUNCHED.append(app.pid)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        stop(2, "the tagged app did not come up")
    # The first workspace: a pane shows, then the restored panes stop changing (run 2 reads their kinds next).
    if not wait(panes, 30):
        stop(2, "the tagged app showed no pane in 30 s after it came up")
    wait_stable(lambda: sorted(json.dumps(p, sort_keys=True) for p in panes()), "the launch's panes", timeout=15,
                interval=0.2, raise_on_timeout=False)


def quit_app():
    global app
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                os.kill(app.pid, signal.SIGKILL)
                app.wait(timeout=10)
            except (OSError, subprocess.SubprocessError):
                pass
    app = None
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def cleanup():
    if not LAUNCHED:
        return
    if app:
        if STATE["page_open"]:
            # No `action()` here: a failed close must not stop the cleanup. The page's workspace must not
            # come back at the tag's next start.
            rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "focus": True, "origin": "script"},
                timeout=10)
        quit_app()
    try:
        subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                       env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    except (OSError, subprocess.SubprocessError):
        ps = ""
    for line in ps.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith(APP + "/") and int(parts[0]) != os.getpid():
            try:
                os.kill(int(parts[0]), signal.SIGTERM)
            except OSError:
                pass
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    # The profile's record stays in the app's state: no script can delete a profile. Its directory goes only
    # when it is a `Profile-*` directory of the tagged app that was not there before run 1.
    profile_dir = STATE["profile_dir"]
    if profile_dir:
        own = (os.path.basename(profile_dir).startswith("Profile-") and of_tagged_app(profile_dir)
               and STATE["profiles_before"] is not None and profile_dir not in STATE["profiles_before"])
        if own:
            shutil.rmtree(profile_dir, ignore_errors=True)
            RESULT["profile_directory_removed"] = not os.path.exists(profile_dir)
        else:
            RESULT["profile_directory_removed"] = False
            RESULT["profile_directory_kept"] = os.sep.join(profile_dir.split(os.sep)[-3:])


RESULT = {"tag": TAG, "host": os.uname().nodename, "checks": {}, "pass": False}


def stop(code, reason=None):
    if STATE["stopping"]:
        sys.exit(code)
    STATE["stopping"] = True
    if reason:
        RESULT["stopped"] = reason
        print(f"CLEAR-CACHE-LOOK STOPPED: {reason}", flush=True)
    try:
        cleanup()
    except Exception as error:
        RESULT["cleanup_failed"] = repr(error)
    finally:
        if STATE["scratch"]:
            shutil.rmtree(STATE["scratch"], ignore_errors=True)
        if opts.json:
            os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
            open(opts.json, "w").write(json.dumps(RESULT, indent=1))
    sys.exit(code)


def open_page(site, phase):
    """Opens the page in the profile, in a workspace of its own; the page's report, or None."""
    arrived = site.report(phase, 90)
    earlier = {p.get("workspace") for p in panes()}
    action("newTab", {"name": f"clear-cache-look-{phase}"})
    STATE["page_open"] = True
    # The new workspace's pane: with no pane the open does nothing and gives no error. A miss of this wait does
    # not stop the look; the JSON says it.
    RESULT[f"{phase}_pane_came"] = bool(wait(lambda: any(
        p.get("focused") and p.get("kind") == "terminal" and p.get("workspace") not in earlier for p in panes()), 30))
    action("browserProfile.openLink", {"browserProfile": PROFILE, "url": site.url}, patience=RECORD_PATIENCE)
    return arrived()


def close_page():
    action("closeWorkspace", {"confirm": True})
    STATE["page_open"] = False


def clear(scope):
    action("browserProfile.clearBrowsingData",
           {"range": scope, "history": False, "cookies": False, "cache": True, "confirm": True},
           target=f"browser-profile:{PROFILE}", patience=RECORD_PATIENCE)


def main():
    if not BINARY:
        stop(2, f"no binary in {APP}/Contents/MacOS")
    site = Site()
    checks = RESULT["checks"]

    # Run 1: fill the profile's Cache Storage.
    STATE["profiles_before"] = profiles()
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
    profile_dir = STATE["profile_dir"] = os.path.dirname(os.path.dirname(store))
    RESULT["profile_directory"] = os.path.basename(profile_dir)
    RESULT["run1"]["files"] = file_count(store)
    browsers = sum(1 for p in panes() if p.get("kind") == "browser")
    close_page()
    # The tab's close: its browser pane is gone.
    if not wait(lambda: sum(1 for p in panes() if p.get("kind") == "browser") < max(1, browsers), 15):
        stop(2, "the page's browser pane did not close in 15 s")
    quit_app()

    # Run 2: the clear, before Chromium opens the profile.
    launch()
    survived = file_count(store) if os.path.isdir(store) else 0
    checks["cache_storage_survives_the_quit"] = survived > 0
    # A browser pane here can be a tab of the profile: then Chromium has the profile open and the clear
    # takes another path. The JSON says how many there are.
    kinds = [p.get("kind") for p in panes()]
    RESULT["run2"] = {"files_at_start": survived, "pane_kinds_at_start": kinds,
                      "browser_panes_at_start": kinds.count("browser"),
                      "profile_entries_at_start": sorted(os.listdir(profile_dir)),
                      "cache_directories_at_start": cache_directories(profile_dir)}
    if not survived:
        stop(1, "the Cache Storage directory has no files after the quit")
    # The sign of the first clear needs one cache directory. If the engine made none here, the driver makes an
    # empty one: the profile is not open now, and the clear moves each of the 5 names that is there.
    planted = not cache_directories(profile_dir)
    if planted:
        os.makedirs(os.path.join(profile_dir, "GPUCache"))
    RESULT["run2"]["cache_directory_planted"] = planted
    clear("hour")
    # The clear runs after the action's answer. Its sign: the cache directories are gone, and then no
    # moved-aside directory stays (the delete starts after the last move). Only then is Cache Storage read.
    ran = wait(lambda: not cache_directories(profile_dir), 20) and wait(lambda: not moved_aside(profile_dir), 30)
    checks["the_last_hour_clear_ran"] = bool(ran)
    checks["the_last_hour_keeps_cache_storage"] = os.path.isdir(store) and file_count(store) > 0
    clear("all")
    gone = wait(lambda: not os.path.exists(store), 20)
    checks["all_time_removes_cache_storage"] = bool(gone)
    leftovers = wait(lambda: not moved_aside(profile_dir), 30)
    checks["no_moved_aside_directory_stays"] = bool(leftovers)
    RESULT["run2"]["moved_aside_left"] = moved_aside(profile_dir)
    checks["the_registrations_stay"] = os.path.isdir(os.path.join(profile_dir, "Service Worker", "Database"))

    # The page again: what Chromium and the worker do with the directory gone.
    again = open_page(site, "reopen")
    RESULT["run2"].update({"report": again, "requests": site.paths("reopen")})
    if again is None:
        stop(2, "the page gave no report after the clear")
    checks["the_page_reports_no_error_after_the_clear"] = "error" not in again and again.get("a") == "a"
    checks["the_worker_fetches_its_file_again"] = bool(
        again.get("controlled") and again.get("a_from") == "network" and "/a.txt" in site.paths("reopen"))
    back = wait(lambda: os.path.isdir(store) and file_count(store) > 0, 30)
    checks["cache_storage_is_back"] = bool(back)
    RESULT["run2"]["files_after_reopen"] = file_count(store) if os.path.isdir(store) else 0
    close_page()

    RESULT["pass"] = all(checks.values())
    print(json.dumps(RESULT, indent=1), flush=True)
    for name, held in checks.items():
        print(f"{'ok  ' if held else 'FAIL'} {name}", flush=True)
    print("CLEAR-CACHE-LOOK", "PASS" if RESULT["pass"] else "FAIL", flush=True)
    stop(0 if RESULT["pass"] else 1)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: None if STATE["stopping"] else stop(143, "terminated"))
    try:
        main()
    except KeyboardInterrupt:
        stop(130, "interrupted")
    except Exception as error:
        stop(2, f"the driver failed: {error!r}")
