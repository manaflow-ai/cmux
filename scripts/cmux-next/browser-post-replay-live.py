#!/usr/bin/env python3
"""Live check: a restored, duplicated or woken browser tab never sends a form again (BR-R1).

  scripts/cmux-next/browser-post-replay-live.py --app <tagged .app> --tag <tag> [--out DIR] [--engines webkit,chromium]

A person who submits a form (a payment, a delete) and later duplicates the tab, lets it
sleep, reopens it after closing it, or quits and reopens cmux must never see the form sent
again without a question. A local server counts the POSTs of each form. For each engine
and each case, one tab submits its own form once (the page submits itself on its first
load), then:
  duplicate  Duplicate Tab on it;
  hibernate  it is hidden behind another tab and Hibernate Tab runs on it, then it is
             focused again (a page that shows a form result must refuse to hibernate:
             exemption form_submission);
  reopen     the tab is closed and reopened (Reopen Closed Tab);
  relaunch   cmux quits and launches again, and the restored tab is focused.
Each form's POST count must stay 1. Every document reports what it shows (`result` = the
POST result, `get` = the form's address loaded by GET, `form`, or none for a cmux page) to
the server; nothing reads a page through the socket. The script prints, per case, the
documents that appeared after the step, and saves a main-window snapshot.

Quits through the quit action (the daemon keeps the tabs), relaunches, then quits with
quitEndSessions and stops the tag's daemons (TagTeardown).
"""
import argparse, http.server, json, os, plistlib, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="the tagged .app")
parser.add_argument("--tag", required=True, help="the app's tag (its debug socket name)")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="browser-post-replay-"))
parser.add_argument("--engines", default="webkit,chromium")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    info = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", info["CFBundleExecutable"])
TAG = opts.tag
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"browser-post-replay-{TAG}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
RUN = os.urandom(4).hex()
ENGINES = tuple(e for e in opts.engines.split(",") if e)
CASES = ("duplicate", "hibernate", "reopen", "relaunch")
failures = []
lock = threading.Lock()
posts = {}       # (engine, case) -> POST count of its form
docs = {}        # document id -> {engine, case, kind, nav, first, last}
served = set()   # (engine, case) whose form page was served once


def key_of(path):
    """/<kind>-<engine>-<case>-<run> -> (kind, engine, case), or None."""
    parts = path.split("?")[0].strip("/").split("-")
    if len(parts) != 4 or parts[3] != RUN or parts[1] not in ENGINES or parts[2] not in CASES:
        return None
    return parts[0], parts[1], parts[2]


def page(engine, case, kind, extra=""):
    return f"""<!doctype html><title>{kind} {engine} {case}</title>
<body style="margin:0;font:32px system-ui"><p>{kind.upper()} {engine} {case}</p>{extra}
<script>
const doc = Math.random().toString(36).slice(2);
const nav = (performance.getEntriesByType('navigation')[0] || {{}}).type || '';
const report = () => navigator.sendBeacon('/report', JSON.stringify({{doc, engine: '{engine}', kind: '{kind}', case: '{case}', nav,
  chromium: /Chrome\\//.test(navigator.userAgent)}}));
report(); setInterval(report, 250);
</script>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, body, status=200, cache="no-store"):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", cache)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        key = key_of(self.path)
        if self.path.startswith("/front"):
            return self.reply("<!doctype html><title>front</title><p>front</p>")
        if not key:
            return self.reply("", 404)
        kind, engine, case = key
        if kind == "form":
            with lock:
                first = (engine, case) not in served
                served.add((engine, case))
            submit = "setTimeout(() => document.forms[0].submit(), 400);" if first else ""
            form = f'<form method="post" action="/submit-{engine}-{case}-{RUN}"><input name="n" value="1"><button>Pay</button></form><script>{submit}</script>'
            return self.reply(page(engine, case, "form", form))
        if kind == "submit":
            return self.reply(page(engine, case, "get"))
        self.reply("", 404)

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/report":
            try:
                r = json.loads(data)
            except ValueError:
                r = None
            if isinstance(r, dict) and r.get("doc"):
                with lock:
                    now = time.monotonic()
                    d = docs.setdefault(r["doc"], {**{k: r.get(k) for k in ("engine", "case", "kind", "nav", "chromium")}, "first": now})
                    d["last"] = now
            self.send_response(204)
            self.end_headers()
            return
        key = key_of(self.path)
        if not key or key[0] != "submit":
            return self.reply("", 404)
        _, engine, case = key
        with lock:
            posts[(engine, case)] = posts.get((engine, case), 0) + 1
            n = posts[(engine, case)]
        print(f"note: POST {engine}/{case} #{n}", flush=True)
        # A result a browser may keep in its cache for back/forward and restore.
        self.reply(page(engine, case, "result"), cache="private, max-age=600")

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
ORIGIN = f"http://127.0.0.1:{server.server_port}"


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def rpc(method, params=None, timeout=30):
    try:
        r = subprocess.run([CLI, "--app-socket", SOCKET, "--json", "app", "call", method, json.dumps(params or {})],
                           capture_output=True, text=True, timeout=timeout, env=CLI_ENV)
    except subprocess.TimeoutExpired:
        return {"error": f"{method} timed out"}
    try:
        value = json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}
    return value if isinstance(value, dict) else {"value": value}


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    print(f"note: timed out: {what}", flush=True)
    return None


def snapshot(name):
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, f"{name}.png")})


def shown_since(engine, case, since):
    """Kinds of the documents of (engine, case) that reported after `since`."""
    with lock:
        return sorted({f"{d['kind']}({d['nav']})" for d in docs.values()
                       if d["engine"] == engine and d["case"] == case and d["last"] > since})


def result_shown(engine, case):
    with lock:
        return any(d["engine"] == engine and d["case"] == case and d["kind"] == "result"
                   and d["chromium"] == (engine == "chromium") for d in docs.values())


app = None


def launch():
    global app
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                                          "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_CONFIG_FILE": CONFIG,
                                          "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY},
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT)
    print(f"app pid {app.pid}, scratch {SCRATCH}, origin {ORIGIN}, out {opts.out}", flush=True)
    return wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)


def end(action):
    rpc("action.run", {"action": action} if action != "quit" else {"id": "quit"})
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.kill()  # the PID launched above, never a pattern
        app.wait()


def open_tab(engine, url):
    reply = rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": url}, "focus": True}, timeout=60)
    return (reply.get("created") or [None])[0]


def submit(engine, case):
    tab = open_tab(engine, f"{ORIGIN}/form-{engine}-{case}-{RUN}")
    check(bool(tab), f"{engine}/{case}: a tab opens")
    check(wait_for(lambda: posts.get((engine, case)) and result_shown(engine, case), f"{engine}/{case} result", 30) is not None,
          f"{engine}/{case}: the form is sent once and its result shows (posts={posts.get((engine, case))})")
    time.sleep(2)  # the history write-back's debounce, so the daemon has the entry
    return tab


def settle(engine, case, since, name):
    time.sleep(6)  # time for a replayed POST to arrive; the count is the check
    snapshot(name)
    shown = shown_since(engine, case, since)
    print(f"note: {engine}/{case}: shown after the step: {shown or ['nothing (cmux page or blank)']}", flush=True)
    check(posts.get((engine, case)) == 1, f"{engine}/{case}: the form was sent once in total (posts={posts.get((engine, case))})")
    return shown


def hibernation():
    return rpc("debug.surfaces").get("hibernation") or {}


write(CONFIG, "{}\n")
write(EMPTY_GHOSTTY, "")
teardown = TagTeardown(APP)
teardown.install()
relaunch_tabs = {}
try:
    check(launch() is not None, "the app starts")
    rpc("action.run", {"action": "workspace.selectFirst"})
    rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    time.sleep(1)
    for engine in ENGINES:
        # duplicate
        tab = submit(engine, "duplicate")
        since = time.monotonic()
        reply = rpc("action.run", {"action": "duplicateTab", "target": f"tab:{tab}", "origin": "script"})
        print(f"note: {engine}/duplicate: duplicateTab -> {json.dumps(reply)[:200]}", flush=True)
        settle(engine, "duplicate", since, f"{engine}-duplicate")

        # hibernate, then wake
        tab = submit(engine, "hibernate")
        front = open_tab(engine, f"{ORIGIN}/front")
        time.sleep(1)
        reply = rpc("action.run", {"action": "hibernateTab", "target": f"tab:{tab}", "origin": "script"})
        time.sleep(2)
        state = hibernation()
        slept = tab in (state.get("hibernated") or [])
        exemption = (state.get("exemptions") or {}).get(tab)
        print(f"note: {engine}/hibernate: hibernateTab -> {json.dumps(reply)[:200]}; hibernated={slept} exemption={exemption}", flush=True)
        check(not slept and exemption == "form_submission",
              f"{engine}/hibernate: a page that shows a form result does not hibernate (hibernated={slept}, exemption={exemption})")
        since = time.monotonic()
        rpc("action.run", {"action": "wakeTab", "target": f"tab:{tab}", "origin": "script"})
        rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab}", "focus": True})
        settle(engine, "hibernate", since, f"{engine}-hibernate")
        rpc("action.run", {"action": "closeTab", "target": f"tab:{front}", "origin": "script"})

        # close, then reopen
        tab = submit(engine, "reopen")
        rpc("action.run", {"action": "closeTab", "target": f"tab:{tab}", "origin": "script"})
        time.sleep(2)
        since = time.monotonic()
        reply = rpc("action.run", {"action": "reopenClosedBrowserPanel", "origin": "script"})
        print(f"note: {engine}/reopen: reopen -> {json.dumps(reply)[:200]}", flush=True)
        settle(engine, "reopen", since, f"{engine}-reopen")

        # relaunch (after the loop)
        relaunch_tabs[engine] = submit(engine, "relaunch")

    end("quit")
    launch()
    tabs = rpc("browser.page.tabs", {"all": True}).get("tabs") or []
    print("note: tabs after relaunch", [(t.get("id"), t.get("url")) for t in tabs], flush=True)
    for engine in ENGINES:
        tab = next((t for t in tabs if f"-{engine}-relaunch-{RUN}" in (t.get("url") or "")), None)
        check(tab is not None, f"{engine}/relaunch: the tab comes back")
        if tab is None:
            continue
        since = time.monotonic()
        rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab['id']}", "focus": True})
        wait_for(lambda: shown_since(engine, "relaunch", since), f"{engine}/relaunch shows a page", 15)
        settle(engine, "relaunch", since, f"{engine}-relaunch")
    # Tabs of the other cases came back too: none of them may send its form on the way.
    time.sleep(3)
    for engine in ENGINES:
        for case in CASES:
            check(posts.get((engine, case)) == 1, f"{engine}/{case}: still one POST after the relaunch (posts={posts.get((engine, case))})")
finally:
    if app and app.poll() is None:
        end("quitEndSessions")
    teardown.end()
    server.shutdown()
    server.server_close()

print(f"POST counts: {json.dumps({f'{e}/{c}': n for (e, c), n in sorted(posts.items())})}")
print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
