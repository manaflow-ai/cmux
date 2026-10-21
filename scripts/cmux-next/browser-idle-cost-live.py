#!/usr/bin/env python3
"""Live check: what idle Chromium tabs cost, and that page console output stays off disk (perf100 browser lane).

  scripts/cmux-next/browser-idle-cost-live.py --app PATH --tabs 5 [--out DIR] [--budget FILE]

A local server serves the pages. The tagged app opens --tabs Chromium tabs of a static page and a
static front tab that stays shown (until the chatty phase), then runs these phases, each one adding a tab:

  static   only the static tabs;
  loading  one more tab whose load never ends (an image request the server keeps open);
  chatty   one more tab, shown, that calls console.log 4 times a second, as the 1Password extension's
           background page does (a background page never freezes; a hidden tab would after 30 s).

Each phase waits --settle-s (past the 30 s hidden-tab freeze), then measures --idle-s: CPU seconds,
idle wakeups and bytes written per Chromium process class (app/browser, gpu, renderer, utility),
footprint per renderer, and how many bytes cef.log grew. The chatty tab's lines carry a run marker;
the run counts the marker lines in cef.log (and cef.previous.log) at the end, and the page counts its
calls to the server, so "0 lines" cannot mean "never logged". CPU limits are reported, and gated only
where the budget file names them.

With --budget, a breach of any limit in the file (see browser-idle-cost-budget.json) is a FAIL.
`sample` output of the GPU process and the app for 3 s per phase goes to the artifacts.
Quits the app through the socket, then ends the tag's daemons (TagTeardown).
"""
import argparse, glob, http.server, importlib.util, json, os, plistlib, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tag_teardown import TagTeardown  # noqa: E402

_spec = importlib.util.spec_from_file_location("browser_engine_bench", os.path.join(HERE, "..", "perf", "browser_engine_bench.py"))
bench = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bench)

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="tagged .app")
parser.add_argument("--tabs", type=int, default=5)
parser.add_argument("--settle-s", type=float, default=40)
parser.add_argument("--idle-s", type=float, default=60)
parser.add_argument("--phases", default="static,loading,chatty")
parser.add_argument("--budget", help="JSON limits; a breach is a FAIL")
parser.add_argument("--no-sample", action="store_true")
parser.add_argument("--env", action="append", default=[], help="KEY=VALUE for the app, e.g. CMUX_NEXT_CEF_EXTRA_SWITCHES=process-per-site")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="browser-idle-cost-"))
opts = parser.parse_args()
PHASES = opts.phases.split(",")
if not set(PHASES) <= {"static", "loading", "chatty"}:
    parser.error(f"unknown phase in {opts.phases}")
if any("=" not in item for item in opts.env):
    parser.error("--env takes KEY=VALUE")
os.makedirs(opts.out, exist_ok=True)

APP = os.path.realpath(opts.app)
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
TAG = INFO["CFBundleIdentifier"].rsplit(".", 1)[-1]
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CEF_LOG = os.path.expanduser(f"~/Library/Application Support/{INFO['CFBundleIdentifier']}/Chromium/cef.log")
SCRATCH = tempfile.mkdtemp(prefix="browser-idle-cost-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
RUN = os.urandom(4).hex()
MARKER = f"cmux-idle-cost-{RUN}"
failures = []
stop_serving = threading.Event()
loaded = set()
ticks = [0]  # the chatty page's console.log calls, in fours
visibility = {}  # static page -> its latest document.visibilityState  # the chatty page's console.log calls, in fours

PAGES = {
    "static": "<title>static {n}</title><body style='font:16px system-ui'><h1>Static page {n}</h1><p>Nothing runs here.</p>"
              "<script>fetch('/loaded/{n}',{{method:'POST'}});const v=()=>fetch('/vis/{n}/'+document.visibilityState,{{method:'POST'}});"
              "v();document.addEventListener('visibilitychange',v)</script>",
    "loading": "<title>loading</title><body><h1>This load never ends</h1><img src='/never'>"
               "<script>fetch('/loaded/loading',{{method:'POST'}})</script>",
    "chatty": "<title>chatty</title><body><h1>Console chatter</h1><script>let i=0;"
              "setInterval(()=>{{console.log('" + MARKER + " ' + (i++));if(i%4==0)fetch('/tick',{{method:'POST'}})}}, 250);fetch('/loaded/chatty',{{method:'POST'}})</script>",
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/never":
            stop_serving.wait(3600)  # keeps the page loading; ends with the run
            return
        kind, _, n = self.path.strip("/").partition("-")
        if kind not in PAGES:
            self.send_error(404)
            return
        body = PAGES[kind].format(n=n).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        if self.path == "/tick":
            ticks[0] += 4
        elif self.path.startswith("/vis/"):
            parts = self.path.split("/", 3)
            if len(parts) == 4:
                visibility[parts[2]] = parts[3]
        loaded.add(self.path.removeprefix("/loaded/"))
        self.send_response(204)
        self.end_headers()

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
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    check(False, f"timed out: {what}")
    return None


def processes(app_pid):
    """{pid: class} for the app and every Chromium helper it started (by --type)."""
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and int(parts[1]) == app_pid:
            command = parts[2]
            if "--type=gpu-process" in command:
                kind = "gpu"
            elif "--type=renderer" in command:
                kind = "extension-renderer" if "--extension-process" in command else "renderer"
            elif "--type=utility" in command:
                kind = "utility"
            elif "--type=" in command:
                kind = "other-helper"
            else:
                continue  # daemons and other children are not this lane's
            rows[int(parts[0])] = kind
    rows[app_pid] = "app"
    return rows


def snapshot(pids):
    snap = {}
    for pid in pids:
        info = bench.rusage(pid)
        if info is not None:
            snap[pid] = (bench.cpu_ns(info), info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
                         info.ri_diskio_byteswritten, info.ri_phys_footprint, info.ri_resident_size)
    return snap


def log_size():
    try:
        return os.path.getsize(CEF_LOG)
    except OSError:
        return 0


def measure(app_pid, phase):
    rows = processes(app_pid)
    before, log_before, t0, ticks_before = snapshot(rows), log_size(), time.monotonic(), ticks[0]
    time.sleep(opts.idle_s)  # the measured idle window itself
    after, log_after, seconds = snapshot(rows), log_size(), time.monotonic() - t0
    classes = {}
    for pid, kind in rows.items():
        if pid not in before or pid not in after:
            continue
        c = classes.setdefault(kind, {"count": 0, "cpu_s": 0.0, "wakeups": 0, "bytes_written": 0, "footprint": [], "rss": []})
        c["count"] += 1
        c["cpu_s"] += (after[pid][0] - before[pid][0]) / 1e9
        c["wakeups"] += after[pid][1] - before[pid][1]
        c["bytes_written"] += after[pid][2] - before[pid][2]
        c["footprint"].append(after[pid][3])
        c["rss"].append(after[pid][4])
    for c in classes.values():
        c["cpu_percent"] = round(100 * c["cpu_s"] / seconds, 3)
        c["wakeups_per_s"] = round(c["wakeups"] / seconds, 1)
        c["footprint_total"] = sum(c["footprint"])
        c["rss_total"] = sum(c["rss"])
    dropped = sorted(set(rows) - (set(before) & set(after)))
    check("gpu" in classes and classes.get("renderer", {}).get("count", 0) >= 1
          and not any(rows[pid] in ("gpu", "renderer") for pid in dropped),
          f"{phase}: the GPU process and renderers are measured ({sorted(classes)}, unmeasured pids {dropped})")
    result = {"phase": phase, "seconds": round(seconds, 1), "classes": classes, "unmeasured_pids": dropped,
              "console_calls": ticks[0] - ticks_before,
              "pages_visible": sorted(n for n, state in visibility.items() if state == "visible"),
              "cef_log_bytes_per_min": round((log_after - log_before) * 60 / seconds),
              "total_cpu_percent": round(sum(c["cpu_percent"] for c in classes.values()), 3)}
    for name in ("debug.cef", "debug.wakeups"):
        result[name] = rpc(name)
    if not opts.no_sample:
        for pid, kind in rows.items():
            if kind in ("gpu", "app"):
                subprocess.run(["sample", str(pid), "3", "-file", os.path.join(opts.out, f"sample-{phase}-{kind}-{pid}.txt")],
                               capture_output=True, timeout=60)
    summary = ", ".join(f"{k} x{c['count']}: {c['cpu_percent']}% cpu, {c['wakeups_per_s']} wk/s, "
                        f"{c['footprint_total'] // 1048576} MB" for k, c in sorted(classes.items()))
    print(f"phase {phase} ({opts.tabs} tabs): {summary}; cef.log {result['cef_log_bytes_per_min']} B/min; "
          f"static pages that report visible: {result['pages_visible']}", flush=True)
    return result


def open_tab(url, key):
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
    wait_for(lambda: key in loaded, f"page {key} loads", 60)


def show(url):
    tabs = rpc("browser.page.tabs", {"all": True}).get("tabs") or []
    tab = next((t for t in tabs if (t.get("url") or "").startswith(url)), None)
    check(tab is not None, f"tab {url} is listed ({len(tabs)} tabs)")
    if tab:
        rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab['id']}", "focus": True})


write(CONFIG, "{}\n")
write(EMPTY_GHOSTTY, "")
teardown = TagTeardown(APP)
teardown.install()
app = None
results = {"tabs": opts.tabs, "app": APP, "env": opts.env, "phases": []}
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                                          "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY,
                                          **dict(item.split("=", 1) for item in opts.env)},
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT)
    print(f"app pid {app.pid}, origin {ORIGIN}, out {opts.out}, cef.log {CEF_LOG}", flush=True)
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)
    rpc("action.run", {"action": "workspace.selectFirst"})
    rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    for n in range(opts.tabs):
        open_tab(f"{ORIGIN}/static-{n}", str(n))
    front = f"{ORIGIN}/static-front"
    open_tab(front, "front")
    for phase in PHASES:
        if phase in ("loading", "chatty"):
            open_tab(f"{ORIGIN}/{phase}-x", phase)
            # The chatty page stays shown, as an extension's background page never freezes;
            # the loading page is hidden behind the front tab.
            show(f"{ORIGIN}/chatty-x" if phase == "chatty" else front)
        time.sleep(opts.settle_s)  # past the hidden-tab freeze, so the window is steady idle
        results["phases"].append(measure(app.pid, phase))
    lines = 0
    check(os.path.exists(CEF_LOG), f"cef.log exists at {CEF_LOG}")
    for path in (CEF_LOG, CEF_LOG.replace("cef.log", "cef.previous.log")):
        if os.path.exists(path):
            with open(path, errors="replace") as f:
                lines += sum(1 for line in f if MARKER in line)
    if "chatty" in PHASES:
        chatty = next(p for p in results["phases"] if p["phase"] == "chatty")
        check(chatty["console_calls"] >= 3 * opts.idle_s, f"the chatty page logs while measured ({chatty['console_calls']} calls)")
    results["console_marker_lines_on_disk"] = lines
    print(f"cef.log lines with the page's console marker: {lines}", flush=True)
    if opts.budget:
        with open(opts.budget) as f:
            budget = json.load(f)
        limit = budget.get("console_marker_lines_on_disk")
        if limit is not None and "chatty" in PHASES:
            check(lines <= limit, f"page console lines in cef.log: {lines} <= {limit}")
        for phase in results["phases"]:
            limits = budget.get("phases", {}).get(phase["phase"], {})
            for kind, cap in limits.get("cpu_percent", {}).items():
                got = phase["classes"].get(kind, {}).get("cpu_percent", 0)
                check(got <= cap, f"{phase['phase']}: {kind} idle CPU {got}% <= {cap}%")
            cap = limits.get("cef_log_bytes_per_min")
            if cap is not None:
                check(phase["cef_log_bytes_per_min"] <= cap, f"{phase['phase']}: cef.log {phase['cef_log_bytes_per_min']} B/min <= {cap}")
finally:
    with open(os.path.join(opts.out, f"browser-idle-cost-{opts.tabs}.json"), "w") as f:
        json.dump(results, f, indent=1, default=str)
    if app and app.poll() is None:
        rpc("action.run", {"action": "quitEndSessions"})
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            app.kill()  # the PID launched above, never a pattern
            app.wait()
    stop_serving.set()
    teardown.end()
    server.shutdown()
    server.server_close()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
