#!/usr/bin/env python3
"""Restore journey: quit cmux NEXT, reopen it, and check that everything came back.

The nightly consistency goal: after a quit (or an update relaunch) and a reopen, the windows,
workspaces, tabs, splits, browser pages, terminal scrollback and running programs, and agent
chats are all where they were. This script seeds that state in a running tagged build, takes a
canonical snapshot, quits through the app's own quit path, relaunches the same app with the
same environment, waits for restore to settle, snapshots again and prints a PASS/FAIL row per
item.

  scripts/cmux-next/restore-journey.py --socket /tmp/cmux-debug-<tag>-capslot<N>.sock \\
      [--variants quit,update] [--out DIR] [--fake-agent PATH] [--src STAGED_APP]

Run it on the GUI host where the app already runs: a capture slot started by `capture-host
launch` (scripts/cmux-next/restore-journey-slot.sh does the whole slot run), or another tagged DEV
build with --allow-non-slot. It refuses an installed or untagged app. It drives the app through
its control socket and the tag's daemon through the bundled `cmux` CLI.

Variants:
  quit    the Quit menu item / Cmd-Q path (`debug.quit {open: true}`; if the sheet asks, its
          default is pressed, as Return does, and the row records whether that keeps sessions);
  update  what Sparkle does before it relaunches into an update
          (`debug.updater {action: "relaunch"}`: the updater's relaunch hook, then terminate);
  crash   the app's exact pid is killed (SIGKILL), so none of its quit path runs;
  wedged  Quit and Keep Sessions over the socket (`action.run quitKeepSessions`) while the quit's
          engine stop blocks the main thread for good, as a wedged CefShutdown did (cx-ccjnn;
          `debug.quit {wedge_engine_stop: true}`, debug builds only): the app must still end within
          WEDGED_QUIT_BOUND seconds, by its quit deadline. If it never ends, its exact pid is
          killed so the restore rows still run.
Each relaunch reuses the app's own launch environment (read from the running process), so a
capture slot keeps its HOME, TMPDIR, socket and config file. It never runs `defaults delete`:
UserDefaults survive, as on a person's Mac. If the slot's app copy is gone after the quit,
`--src` re-clones it the way capture-host does (same bundle id, ad-hoc signed).

The seeded state, all named `rj-*` (earlier rj-* workspaces are closed first):
  window 1: rj-term (3000 numbered lines; a counter loop with a pid file in a right split; `top`
            in a nested down split; selected at the end), rj-split (four terminals in nested
            right/down splits, two tabs in one pane, the first selected), rj-web (two browser
            tabs from a local server: a page loaded from its address, then two link clicks
            (a -> b -> c), whose history length and Cmd-[ / Cmd-] walk are checked after
            seeding and after each reopen; and a tall page that scrolls itself the first
            time), rj-agent (an
            agent chat with the acpmux test agent: three turns and a draft); the window at a set
            frame;
  window 2: rj-w2 (a terminal with a marker line and a browser tab), at another frame.

Restore has settled when the topology is loaded with every rj-* tab back, the launch window has
handed over (`debug.windows`) and every shown terminal view is attached live (`debug.surfaces`).

Compared before vs after: windows (count, frames, workspaces in order, selection), each rj-*
workspace's panes, tabs (kind, order, selection), split tree with ratios (daemon `screen layout
export`), terminal ids, cwds and scrollback (rows, hash, the numbered lines), the view's text of
the scrollback terminal, the counter (same pid, alive, still counting in the daemon and in the
view), each page's own report of its path and scroll after the reload (no script reads a page),
and the agent chat (tab bound to its session, the session's prompts, draft and what the chat
page shows). Output: a table on stdout, `report.json`, raw dumps and window stills in --out.
Exit 0 only when every row passes.

Nothing outside the app's own tag state is changed: no settings.set (the shared config of a
capture mini); the acpmux config gets harness `fake` for the run and is put back; the local
web server, pid file and chat folder live in --out (the fake chats themselves stay in the
tag's acpmux home). The app is left running after the last
relaunch (the caller quits it and releases the slot).
"""
import argparse, atexit, glob, hashlib, http.server, json, os, re, shlex, signal, socket, subprocess, sys, threading, time
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the app's control socket")
parser.add_argument("--variants", default="quit,update,crash")
parser.add_argument("--out", default="/tmp/restore-journey")
parser.add_argument("--fake-agent", default=os.path.join(HERE, "../../cmux-tui/crates/acpmux/tests/fake_agent.py"))
parser.add_argument("--src", help="staged app to re-clone from when the slot's app copy is gone after a quit")
parser.add_argument("--settle", type=float, default=90, help="seconds restore may take to settle")
parser.add_argument("--skip", default="", help="comma list of seed parts to skip: term,split,web,agent,w2")
parser.add_argument("--max-seconds", type=int, default=0, help="stop (restoring what it changed) after this long; 0: no limit")
parser.add_argument("--activate", action="store_true",
                    help="relaunch as a person's launch does (activating, without CMUX_NEXT_NO_ACTIVATE), so window order and focus follow real key windows")
parser.add_argument("--hist-file", action="store_true",
                    help="serve the history pages as file:// pages (as a person opens a local .html), reporting to the local server")
parser.add_argument("--allow-non-slot", action="store_true",
                    help="drive a tagged DEV build that is not in a capture slot (it closes rj-* workspaces, quits and relaunches it)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SKIP = {s.strip() for s in opts.skip.split(",") if s.strip()}
LOG = open(os.path.join(opts.out, "journey.log"), "a")
RUN = os.urandom(3).hex()
SCROLLBACK_LINES = 3000
SCROLL = 1500
PIDFILE = os.path.join(opts.out, f"counter-{RUN}.pid")


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(time.strftime("%H:%M:%S ") + line + "\n")
    LOG.flush()


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if os.getppid() == 1:  # the run that started this one is gone (ssh dropped): stop driving the app
            sys.exit("restore-journey: parent gone; stopping")
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def rpc(method, params=None, timeout=60):
    """One request on the app's control socket; the result, or {"error": ...}."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
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


def action(name, **params):
    answer = rpc("action.run", {"action": name, **params}, timeout=90)
    say(f"  action {name} {json.dumps(params)[:120]} -> {json.dumps(answer)[:200]}")
    return answer


def dump(name, value):
    with open(os.path.join(opts.out, name), "w") as f:
        json.dump(value, f, indent=1, sort_keys=True, default=str)


# ---- the app process: identity, environment, quit, relaunch -----------------------------

# The quit deadline (QuitDeadline.engineStopLimit, 15 s) plus margin for a loaded mini.
WEDGED_QUIT_BOUND = 30


class App:
    def __init__(self):
        self.refresh()
        info = self.info
        self.bundle = info.get("app_bundle_path")
        self.cli = info.get("app_cli_path") or os.path.join(self.bundle, "Contents/Resources/bin/cmux")
        self.tag = info.get("tag")
        self.bundle_id = info.get("bundle_id")
        self.env = self.environment(self.pid)
        say(f"app pid {self.pid} tag {self.tag} bundle {self.bundle} id {self.bundle_id}")
        self.check_target()

    def check_target(self):
        """Only a tagged DEV build, never a person's cmux: the journey closes rj-* workspaces,
        quits and relaunches the app and edits its tag's acpmux config."""
        bundle_id, bundle = self.bundle_id or "", self.bundle or ""
        problems = []
        if not self.tag:
            problems.append("the app has no tag")
        if ".debug" not in bundle_id:
            problems.append(f"bundle id {bundle_id!r} is not a DEV build's")
        if not bundle or bundle.startswith("/Applications/"):
            problems.append(f"bundle {bundle!r} is an installed app")
        if not opts.allow_non_slot and "capslot" not in bundle_id and not self.env.get("CMUX_CAPTURE_SLOT"):
            problems.append("not a capture slot's app (pass --allow-non-slot for another tagged DEV build)")
        if problems:
            sys.exit("restore-journey refuses this app: " + "; ".join(problems))

    def refresh(self):
        info = rpc("system.identify")
        if not isinstance(info, dict) or "error" in info or not info.get("pid"):
            sys.exit(f"no app answers on {opts.socket}: {info}")
        self.info, self.pid = info, int(info["pid"])

    @staticmethod
    def environment(pid):
        """The app's own launch variables (`ps eww`, same user): the CMUX_* ones plus HOME and
        TMPDIR, which is what a capture slot or a test launch sets."""
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
        env = {}
        for word in out.split():
            key, sep, value = word.partition("=")
            if sep and (key.startswith("CMUX_") or key in ("HOME", "TMPDIR")):
                env[key] = value
        return env

    def alive(self):
        try:
            os.kill(self.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def quit(self, variant):
        """Ends the app (its own quit path, or a crash) and waits for the exact pid to exit."""
        if variant == "crash":
            # A crash: the app's exact pid ends at once (SIGKILL); nothing of the app's own quit runs.
            # Only the pid the slot's socket names right now, and only while it is alive.
            answer = rpc("system.identify", timeout=5)
            if not (isinstance(answer, dict) and int(answer.get("pid") or 0) == self.pid and self.alive()):
                say(f"  crash: the socket no longer names pid {self.pid}; not killing anything")
                return False
            say(f"  crash: SIGKILL pid {self.pid}")
            try:
                os.kill(self.pid, signal.SIGKILL)
            except OSError as error:
                say(f"  crash: kill failed: {error}")
                return False
        elif variant == "wedged":
            armed = rpc("debug.quit", {"wedge_engine_stop": True}, timeout=10)
            say(f"  debug.quit wedge_engine_stop -> {json.dumps(armed)[:200]}")
            if not (isinstance(armed, dict) and armed.get("wedges_engine_stop") is True):
                # A build without the seam (not a debug build) would quit normally and pass falsely.
                RESULTS.append((f"{variant}: the engine-stop wedge is armed", False, "debug.quit has no wedge_engine_stop (not a debug build?)", "harness"))
                return False
            started = time.time()
            say(f"  action.run quitKeepSessions -> {json.dumps(rpc('action.run', {'action': 'quitKeepSessions'}, timeout=30))[:200]}")
            ended = wait(lambda: not self.alive(), 60, 0.25)
            took = time.time() - started
            in_bound = bool(ended) and took <= WEDGED_QUIT_BOUND
            say(f"  app pid {self.pid} {f'exited {took:.1f} s after its quit' if ended else 'is STILL RUNNING after 60 s'}")
            RESULTS.append((f"{variant}: app ends within {WEDGED_QUIT_BOUND} s with its engine stop wedged", in_bound,
                            f"exited after {took:.1f} s" if ended else "still running after 60 s", "app quit"))
            if ended:
                return True
            # The red case: action.run is wedged too (the main thread never runs it).
            answer = rpc("action.run", {"action": "equalizeSplits"}, timeout=10)
            RESULTS.append((f"{variant}: action.run still runs while the quit hangs", isinstance(answer, dict) and "error" not in answer,
                            json.dumps(answer)[:160], "app quit"))
            identity = rpc("system.identify", timeout=5)
            if isinstance(identity, dict) and int(identity.get("pid") or 0) == self.pid and self.alive():
                say(f"  wedged: SIGKILL pid {self.pid} so the restore rows still run")
                os.kill(self.pid, signal.SIGKILL)
            return bool(wait(lambda: not self.alive(), 20, 0.25))
        elif variant == "update":
            say(f"  debug.updater relaunch -> {json.dumps(rpc('debug.updater', {'action': 'relaunch'}, timeout=30))[:200]}")
        else:
            say(f"  debug.quit open -> {json.dumps(rpc('debug.quit', {'open': True}, timeout=30))[:200]}")
            # Cmd-Q may ask about the local terminals: answer with the sheet's default, as a
            # person pressing Return does, and record what it was.
            def asking():
                if not self.alive():
                    return "gone"
                report = rpc("debug.quit", timeout=5)
                return report if isinstance(report, dict) and report.get("asking") else None
            sheet = wait(asking, 8, 0.3)
            if isinstance(sheet, dict):
                dump(f"quit-sheet-{variant}.json", sheet)
                default = str((sheet.get("prompt") or {}).get("default"))
                say(f"  quit sheet asks (default {default}, buttons {[b.get('id') for b in sheet.get('buttons') or []]}); pressing the default")
                RESULTS.append((f"{variant}: quit sheet default keeps sessions", "keep" in default, f"default {default}", "app quit"))
                rpc("debug.quit", {"press": "keep" if "keep" in default else default}, timeout=10)
        ended = wait(lambda: not self.alive(), 60, 0.25)
        say(f"  app pid {self.pid} {'exited' if ended else 'is STILL RUNNING after 60 s'}")
        return bool(ended)

    def ensure_bundle(self):
        if os.path.isdir(self.bundle):
            return True
        if not opts.src:
            say(f"  the app copy {self.bundle} is gone and no --src was given")
            return False
        say(f"  re-cloning {opts.src} -> {self.bundle} (bundle id {self.bundle_id})")
        if subprocess.run(["cp", "-cR", opts.src, self.bundle]).returncode != 0:
            subprocess.run(["cp", "-R", opts.src, self.bundle], check=True)
        plist = os.path.join(self.bundle, "Contents/Info.plist")
        subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {self.bundle_id}", plist], check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", self.bundle], capture_output=True)
        return True

    def relaunch(self):
        if not self.ensure_bundle():
            return False
        # The updater's hook may relaunch the app itself: never start a second copy beside it.
        answer = rpc("system.identify", timeout=5)
        if isinstance(answer, dict) and answer.get("pid") and int(answer["pid"]) != self.pid:
            self.refresh()
            say(f"  the app relaunched itself: pid {self.pid}")
            return True
        if os.path.exists(opts.socket):
            os.unlink(opts.socket)
        args = ["/usr/bin/open", "-n", "-a", self.bundle] if opts.activate else ["/usr/bin/open", "-g", "-n", "-a", self.bundle]
        for key, value in self.env.items():
            if opts.activate and key == "CMUX_NEXT_NO_ACTIVATE":
                continue
            args += ["--env", f"{key}={value}"]
        subprocess.run(args, check=True)
        up = wait(lambda: os.path.exists(opts.socket) and (lambda r: isinstance(r, dict) and r.get("pid"))(rpc("system.identify", timeout=5)), 60, 0.5)
        if not up:
            say("  the relaunched app never answered on its socket")
            return False
        self.refresh()
        say(f"  relaunched: pid {self.pid}")
        return True


# ---- the tag's daemon (bundled CLI) and acpmux ----------------------------------------------

def daemon_socket():
    """The headless daemon this app started (`cmux-tui --headless --session cmux-app-<tag>
    --socket <path>`, run from the app bundle): its socket, from its own arguments."""
    out = subprocess.run(["ps", "axo", "args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith(APP.bundle + "/") and "--headless" in line and f"--session cmux-app-{APP.tag}" in line:
            m = re.search(r"--socket (\S+)", line)
            if m:
                return m.group(1)
    return None


def cli(*args, timeout=60, quiet=False):
    """The bundled `cmux` on the tag's daemon, `--json`; the parsed answer, or {"error": ...}."""
    sock = daemon_socket()
    if not sock:
        return {"error": "no daemon socket"}
    env = {"HOME": APP.env.get("HOME", os.environ["HOME"]), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
    r = subprocess.run([APP.cli, "--socket", sock, "--json", *args], capture_output=True, text=True, timeout=timeout, env=env)
    try:
        answer = json.loads(r.stdout)
    except ValueError:
        answer = {"error": (r.stdout + r.stderr).strip()[:400]}
    if not quiet:
        say(f"  cli {' '.join(args)[:120]} -> {json.dumps(answer)[:200]}")
    return answer


def value(answer):
    return answer.get("value", {}) if isinstance(answer, dict) else {}


def acpmux_socket_of(home):
    """acpmux `config::socket_path()`: `<home>/acpmux.sock`, or `/tmp/acpmux-<uid>/<fnv1a64>.sock`
    when that is too long for sun_path."""
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred.encode()) < 96:
        return preferred
    h = 0xcbf29ce484222325
    for byte in home.encode():
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{h:016x}.sock"


def acpmux_home():
    """The app's acpmux home: <account home>/.acpmux/tags/<tag slug> (the account's real home,
    not a slot HOME). Never /tmp/acpmux-<uid> as such: other apps' daemons live there."""
    slug = re.sub(r"[^a-z0-9]+", "-", (APP.tag or "").lower()).strip("-")
    for base in {os.path.expanduser("~"), APP.env.get("HOME", "")}:
        home = os.path.join(base, ".acpmux", "tags", slug)
        if base and os.path.exists(acpmux_socket_of(home)):
            return home
    return None


class Acpmux:
    """One request/answer connection to acpmux (JSON-RPC lines); notifications are dropped."""

    def __init__(self, path):
        self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.conn.settimeout(60)
        self.conn.connect(path)
        self.next, self.buf = 0, b""
        self.request("initialize", {"protocolVersion": 1, "clientInfo": {"name": "restore-journey"}})

    def request(self, method, params, timeout=60):
        self.next += 1
        rid = self.next
        self.conn.settimeout(timeout)
        self.conn.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        while True:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == rid and ("result" in message or "error" in message):
                    return message
            chunk = self.conn.recv(1 << 20)
            if not chunk:
                return {"error": {"message": "closed"}}
            self.buf += chunk


ACPMUX_RESTORE = []
atexit.register(lambda: restore_acpmux_config())
for _sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGALRM):
    signal.signal(_sig, lambda *_: sys.exit(1))  # runs finally blocks and atexit
if opts.max_seconds:
    signal.alarm(opts.max_seconds)


def configure_fake(home):
    path = os.path.join(home, "config.json")
    try:
        with open(path) as f:
            original = f.read()
    except FileNotFoundError:
        original = None
    config = json.loads(original) if original else {}
    config.setdefault("harnesses", {})["fake"] = {"argv": ["python3", os.path.abspath(opts.fake_agent)]}
    ACPMUX_RESTORE.append((path, original))  # first, so an exit at any point after puts it back
    with open(path + ".rj", "w") as f:
        f.write(json.dumps(config, indent=2))
    os.replace(path + ".rj", path)
    client = Acpmux(acpmux_socket_of(home))
    say(f"  acpmux reload_config -> {json.dumps(client.request('_acpmux/reload_config', {}))[:160]}")
    return client


def restore_acpmux_config():
    for path, original in ACPMUX_RESTORE:
        try:
            if original is None:
                os.remove(path)
            else:
                with open(path + ".rj", "w") as f:
                    f.write(original)
                os.replace(path + ".rj", path)
        except OSError as error:
            print("could not restore", path, error, file=sys.stderr)
            continue
        try:
            Acpmux(acpmux_socket_of(os.path.dirname(path))).request("_acpmux/reload_config", {}, timeout=10)
        except Exception as error:  # restored on disk; acpmux reads it at its next start
            print("could not reload acpmux config", path, error, file=sys.stderr)
    ACPMUX_RESTORE.clear()


# ---- the local web server: pages that report their own path and scroll ---------------------

REPORTS = {}  # page name -> latest {path, scrollY, at}
SINCE = 0.0  # when the last quit started: reports older than this are stale
SERVED = set()
LOCK = threading.Lock()


def page_html(name, base=""):
    with LOCK:
        first = name not in SERVED
        SERVED.add(name)
    body = "".join(f"<p style='height:40px;margin:0'>rj {name} row {i}</p>" for i in range(400)) if name == "tall" else ""
    act = ""
    if first and name == "tall":
        act = f"setTimeout(function(){{window.scrollTo(0,{SCROLL});}},300);"
    # The history pages link on (a -> b -> c), for link-click navigation as a person's.
    nxt = {"hist-a": "hist-b", "hist-b": "hist-c"}.get(name)
    href = f"{nxt}.html" if opts.hist_file else f"/{nxt}"
    link = f"<a id='next' href='{href}'>next</a>" if nxt else ""
    # Both history pages report as one tab ("hist").
    tab = "hist" if name.startswith("hist") else name
    return f"""<!doctype html><html><head><title>rj {name}</title></head><body>
<h1>rj {name}</h1>{link}{body}
<script>
function report(){{var p=location.pathname.replace(/^.*\\//,'/').replace(/\\.html$/,'');
new Image().src='{base}/report?page={tab}&path='+encodeURIComponent(p)+'&y='+Math.round(window.scrollY)+'&h='+history.length+'&t='+Date.now();}}
{act}
setInterval(report,1000); window.addEventListener('scroll',report); window.addEventListener('pageshow',report); report();
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/report":
            q = parse_qs(url.query)
            with LOCK:
                REPORTS[q.get("page", [""])[0]] = {"path": q.get("path", [""])[0], "scrollY": int(q.get("y", ["0"])[0]),
                                                   "history": int(q.get("h", ["0"])[0]), "at": time.time()}
            self.send_response(204)
            self.end_headers()
            return
        data = page_html(url.path.strip("/") or "index").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def start_server():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


# ---- seeding ---------------------------------------------------------------------------------

def topology():
    snap = rpc("snapshot.get")
    return (snap or {}).get("topology") if isinstance(snap, dict) else None


def rj_workspaces(topo):
    return [w for w in (topo or {}).get("workspaces", []) if (w.get("name") or "").startswith("rj-")]


def workspace_named(name, topo=None):
    return next((w for w in (topo or topology() or {}).get("workspaces", []) if w.get("name") == name), None)


def tabs_of(ws):
    return [tab for screen in (ws or {}).get("screens", []) for pane in screen.get("panes", []) for tab in pane.get("tabs", [])]


def write(term, text):
    return cli("terminal", term, "write", "--text", text)


def split(pane, direction):
    return value(cli("pane", pane, "split", f"--{direction}"))


def new_workspace(name):
    created = value(cli("workspace", "create", "--name", name))
    if not created.get("workspace_id"):
        say(f"  workspace {name} was not created")
    return created


def seed_term():
    if os.path.exists(PIDFILE):
        os.remove(PIDFILE)
    ws = new_workspace("rj-term")
    if not ws.get("terminal_id"):
        return
    write(ws["terminal_id"], f"cd {shlex.quote(opts.out)}; for i in $(seq 1 {SCROLLBACK_LINES}); do echo rj-line-$i-{RUN}; done; echo rj-scrollback-done\n")
    right = split(ws["pane_id"], "right")
    if right.get("terminal_id"):
        write(right["terminal_id"], f"sh -c 'echo $$ > {shlex.quote(PIDFILE)}; i=0; while :; do i=$((i+1)); echo rj-tick-$i; sleep 1; done'\n")
        down = split(right["pane_id"], "down")
        if down.get("terminal_id"):
            write(down["terminal_id"], "top -s 1\n")


def seed_split():
    ws = new_workspace("rj-split")
    if not ws.get("terminal_id"):
        return
    write(ws["terminal_id"], "echo rj-split-a\n")
    b = split(ws["pane_id"], "right")
    c = b.get("pane_id") and split(b["pane_id"], "down")
    d = c and c.get("pane_id") and split(c["pane_id"], "right")
    for made, label in ((b, "b"), (c, "c"), (d, "d")):
        if made and made.get("terminal_id"):
            write(made["terminal_id"], f"echo rj-split-{label}\n")
    # A second tab in pane A, then A's first tab selected again.
    e = value(cli("tab", "create", "terminal", "--workspace", ws["workspace_id"], "--pane", ws["pane_id"]))
    if e.get("terminal_id"):
        write(e["terminal_id"], "echo rj-split-e\n")
    cli("tab", ws["tab_id"], "focus")


def seed_web(base):
    ws = new_workspace("rj-web")
    if not ws.get("workspace_id"):
        return
    cli("workspace", ws["workspace_id"], "focus")
    # Each page in its own pane and selected there, so both load now and after the relaunch.
    first = f"{base}/hist-a"
    if opts.hist_file:
        folder = os.path.join(opts.out, "pages")
        os.makedirs(folder, exist_ok=True)
        for name in ("hist-a", "hist-b", "hist-c"):
            with open(os.path.join(folder, f"{name}.html"), "w") as f:
                f.write(page_html(name, base))
        first = "file://" + os.path.join(folder, "hist-a.html")
    hist = value(cli("tab", "create", "browser", "--url", first, "--workspace", ws["workspace_id"], "--pane", ws["pane_id"]))
    if hist.get("tab_id"):
        cli("tab", hist["tab_id"], "focus")
        HIST["tab"] = hist["tab_id"]
    # A person's history: the first page loaded from the address, then two link clicks (a -> b -> c).
    for here, there in (("/hist-a", "/hist-b"), ("/hist-b", "/hist-c")):
        if not wait(lambda: (REPORTS.get("hist") or {}).get("path") == here, 40):
            say(f"  the history page never reported from {here}")
            break
        clicked = wait(lambda: (lambda r: r if isinstance(r, dict) and r.get("value") is True else None)(
            rpc("browser.page.eval", {"tab": HIST.get("tab"), "script": CLICK_NEXT})), 20, 0.5)
        say(f"  click the link on {here} -> {json.dumps(clicked)[:120]}")
    if not wait(lambda: (REPORTS.get("hist") or {}).get("path") == "/hist-c", 40):
        say("  the history page never reported from /hist-c")
    right = split(ws["pane_id"], "right")
    tall = value(cli("tab", "create", "browser", "--url", f"{base}/tall", "--workspace", ws["workspace_id"], "--pane", right.get("pane_id") or ws["pane_id"]))
    if tall.get("tab_id"):
        cli("tab", tall["tab_id"], "focus")
    if not wait(lambda: (REPORTS.get("tall") or {}).get("scrollY", 0) >= SCROLL - 5, 40):
        say("  the tall page never reported its scroll")


AGENT = None
HIST = {}  # the history tab: {"tab": its id}
SEEDED = {}  # values from the first before-snapshot that later variants must keep
# Clicks the page's link once it has loaded (a click before load can replace the entry instead of adding one).
CLICK_NEXT = "document.readyState === 'complete' ? (document.getElementById('next').click(), true) : false"


def seed_agent():
    global AGENT
    ws = new_workspace("rj-agent")
    if not ws.get("workspace_id"):
        return
    cli("workspace", ws["workspace_id"], "focus")
    action("palette.newAgentChat", focus=True)
    home = wait(acpmux_home, 60)
    if not home:
        say("  no acpmux home for this tag; the agent chat is not seeded")
        return
    client = configure_fake(home)
    created = client.request("session/new", {"cwd": opts.out, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}})
    sid = (created.get("result") or {}).get("sessionId")
    say(f"  fake chat {sid}: {json.dumps(created)[:160]}")
    if not sid:
        return
    for i, text in enumerate(["rj hello one", "rj hello two", "rj hello three"]):
        client.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": f"{text} {RUN}"}],
                                          "_meta": {"acpmux": {"promptId": f"rj-{RUN}-{i}"}}}, timeout=60)
    client.request("_acpmux/draft_set", {"sessionId": sid, "text": f"rj unsent draft {RUN}"})
    pane = next((p.get("id") for s_ in (workspace_named("rj-agent") or {}).get("screens", []) for p in s_.get("panes", [])
                 if any(t.get("kind") == "conversation" for t in p.get("tabs", []))), None)
    for _ in range(3):
        params = {"action": "select_session", "session": sid, **({"pane": pane} if pane else {})}
        say(f"  select_session -> {json.dumps(rpc('debug.agent_pane', params, timeout=60))[:160]}")
        if wait(lambda: any(t.get("agent_session") == sid for t in tabs_of(workspace_named("rj-agent"))), 30, 1):
            break
    else:
        say("  the chat tab's record never named the session (the page has it selected)")
        # Evidence for the gap: the app's own log about the bind and the page's session report.
        log = subprocess.run(["log", "show", "--last", "4m", "--style", "compact", "--predicate",
                              f"processID == {APP.pid} AND (eventMessage CONTAINS[c] 'conversation-tab' "
                              "OR eventMessage CONTAINS[c] 'session' OR eventMessage CONTAINS[c] 'bind')"],
                             capture_output=True, text=True, timeout=120).stdout
        with open(os.path.join(opts.out, "agent-bind-log.txt"), "w") as f:
            f.write(log)
        state = rpc("debug.agent_pane", {"action": "chat_state", **({"pane": pane} if pane else {})}, timeout=30)
        dump("agent-bind-chat-state.json", state)
        say(f"  bind log: {len(log.splitlines())} lines in agent-bind-log.txt")
    AGENT = {"session": sid, "home": home, "pane": pane}


def seed_w2(base):
    ws = new_workspace("rj-w2")
    if not ws.get("workspace_id"):
        return
    write(ws["terminal_id"], f"echo rj-w2-marker-{RUN}\n")
    cli("tab", "create", "browser", "--url", f"{base}/w2page", "--workspace", ws["workspace_id"], "--pane", ws["pane_id"])
    action("moveWorkspaceToNewWindow", target=f"workspace:{ws['workspace_id']}")
    window = wait(lambda: next((w for w in (topology() or {}).get("windows", []) if w.get("workspace") == ws["workspace_id"]), None), 20)
    if window:
        rpc("debug.window_frame", {"window": window.get("key"), "frame": FRAMES[1]})


# Window frames (AppKit points, bottom-left origin), inside a 1080p screen's visible frame (above
# the Dock), so a restore that keeps a window on screen has no reason to move them.
FRAMES = [[80, 220, 1100, 700], [260, 280, 820, 560]]


def cleanup_earlier():
    """Closes rj-* workspaces an earlier run left (slot state persists per tag), ending their terminals."""
    for ws in rj_workspaces(topology()):
        cli("workspace", ws["id"], "close")
    wait(lambda: not rj_workspaces(topology()), 20)


def seed(base):
    say("seeding")
    cleanup_earlier()
    for part, run in (("term", seed_term), ("split", seed_split), ("web", lambda: seed_web(base)),
                      ("agent", seed_agent), ("w2", lambda: seed_w2(base))):
        if part not in SKIP:
            try:
                run()
            except Exception as error:  # one part failing still leaves the others to check
                say(f"  seed {part} failed: {error!r}")
    term = workspace_named("rj-term")
    first = term and next((w for w in (topology() or {}).get("windows", []) if term["id"] in w.get("workspaces", [])), None)
    if term:
        cli("workspace", term["id"], "focus")
    if first:
        rpc("debug.window_frame", {"window": first.get("key"), "frame": FRAMES[0]})
        # The window a person used last: key and first in the app's window recency.
        say(f"  window.focus -> {json.dumps(rpc('debug.window.focus', {'window': first.get('key')}))[:160]}")
    # The scrollback writer is done and the counter has ticked a few times.
    wait(lambda: "rj-scrollback-done" in json.dumps(rpc("debug.surfaces", {"text": True})), 40, 1)
    if "term" not in SKIP:
        wait(lambda: view_tick() >= 3, 20, 0.5)


# ---- the canonical snapshot ------------------------------------------------------------------

def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def history(term):
    """Every scrollback row of `term` (oldest first), paged back from the newest."""
    rows, before = [], None
    for _ in range(100):
        args = ["terminal", term, "history", "read", "--limit", "1000"] + (["--before", str(before)] if before is not None else [])
        page = cli(*args, quiet=True)
        if not isinstance(page, dict) or "rows" not in page:
            return None
        chunk = ["".join(run.get("text", "") for run in row.get("runs", [])).rstrip() for row in page["rows"]]
        rows = chunk + rows
        start = int(page.get("start") or 0)
        if not chunk or start <= 0:
            break
        before = start
    return rows


def terminal_items(term):
    rows = history(term)
    screen = cli("terminal", term, "screen", "read", quiet=True)
    text = "\n".join(rows or []) + "\n" + (screen.get("text", "") if isinstance(screen, dict) else "")
    numbered = [int(n) for n in re.findall(rf"rj-line-(\d+)-{RUN}", text)]
    return {"history_rows": len(rows) if rows is not None else None, "history_sha": sha("\n".join(rows or [])),
            "numbered_lines": len(set(numbered)), "numbered_max": max(numbered) if numbered else 0,
            "ticks": [int(t) for t in re.findall(r"rj-tick-(\d+)", text)]}


def layout_shape(screen_id, pane_index):
    """The screen's split tree from the daemon, with pane ids replaced by their index and ratios rounded."""
    exported = cli("screen", screen_id, "layout", "export", quiet=True)
    tree = exported.get("value", exported) if isinstance(exported, dict) else exported

    def walk(node):
        if isinstance(node, dict):
            out = {}
            for key, item in node.items():
                if key in ("id", "pane_id", "pane", "split_id") and isinstance(item, str) and item in pane_index:
                    out[key] = f"pane#{pane_index[item]}"
                elif key in ("id", "split_id", "tab_id", "terminal_id", "browser_id", "revision", "generation") and isinstance(item, str):
                    continue
                elif isinstance(item, float):
                    out[key] = round(item, 2)
                else:
                    out[key] = walk(item)
            return out
        if isinstance(node, list):
            return [walk(item) for item in node]
        return node

    return walk(tree)


def view_tick():
    """The counter's newest tick that a terminal view shows (0 when none)."""
    _, views = view_panes()
    ticks = [int(t) for t in re.findall(r"rj-tick-(\d+)", "\n".join(v.get("text") or "" for v in views.values()))]
    return max(ticks) if ticks else 0


def view_panes():
    report = rpc("debug.surfaces", {"text": True}, timeout=60)
    panes = {}
    for window in report.get("windows", []) if isinstance(report, dict) else []:
        for pane in window.get("panes", []):
            panes[pane.get("pane")] = pane
    return report, panes


PAGE_WORKSPACE = {"hist": "rj-web", "tall": "rj-web", "w2page": "rj-w2"}


class visiting:
    """Shows workspace `name` for a read, then the workspace that was focused before again (so
    the focus rows and the next variant see what the person left)."""

    def __init__(self, name):
        self.name, self.back = name, None

    def __enter__(self):
        topo = topology() or {}
        self.back = (topo.get("focus") or {}).get("workspace")
        target = workspace_named(self.name, topo) if self.name else None
        if target and target.get("id") != self.back:
            cli("workspace", target["id"], "focus", quiet=True)
        else:
            self.back = None
        return self

    def __exit__(self, *_):
        if self.back:
            cli("workspace", self.back, "focus", quiet=True)
            wait(lambda: ((topology() or {}).get("focus") or {}).get("workspace") == self.back, 10, 0.3)


def snapshot(label):
    """Raw dumps plus the canonical items: {item: value}."""
    say(f"snapshot {label}")
    topo = topology() or {}
    surfaces, views = view_panes()
    raw = {"topology": topo, "debug.windows": rpc("debug.windows"), "debug.screens": rpc("debug.screens"),
           "debug.surfaces": surfaces, "reports": dict(REPORTS), "debug.timings": rpc("debug.timings")}
    items = {}
    ws_by_id = {w.get("id"): w for w in topo.get("workspaces", [])}
    rj = lambda name: (name or "").startswith("rj-")
    # Windows that hold rj-* workspaces, in topology order.
    rj_windows = [w for w in topo.get("windows", []) if any(rj(ws_by_id.get(i, {}).get("name")) for i in w.get("workspaces", []))]
    items["windows.count"] = len(rj_windows)
    # A window is named by its rj-* workspaces (window ids are compared separately).
    names = {w.get("key"): "+".join(sorted(n for n in (ws_by_id.get(i, {}).get("name") for i in w.get("workspaces", [])) if rj(n)))
             for w in rj_windows}
    recency = (raw["debug.windows"] or {}).get("recency") if isinstance(raw["debug.windows"], dict) else None
    items["windows.recency"] = [names[key] for key in recency or [] if key in names]
    for index, window in enumerate(rj_windows):
        p = f"window[{names[window.get('key')]}]"
        items[f"{p}.id"] = window.get("id")
        items[f"{p}.workspaces"] = [n for n in (ws_by_id.get(i, {}).get("name") for i in window.get("workspaces", [])) if rj(n)]
        items[f"{p}.selected_workspace"] = ws_by_id.get(window.get("workspace"), {}).get("name")
        # With no `frame`, debug.window_frame sets the window's own frame again and returns it.
        framed = rpc("debug.window_frame", {"window": window.get("key")})
        items[f"{p}.frame"] = framed.get("frame") if isinstance(framed, dict) else None
        raw[f"{p}.snapshot"] = rpc("debug.window_snapshot", {"window": window.get("key"), "path": os.path.join(opts.out, f"{label}-window{index}.png")}, timeout=60)
    focus = topo.get("focus", {})
    items["focus.workspace"] = ws_by_id.get(focus.get("workspace"), {}).get("name")
    items["focus.window"] = next((names.get(w.get("key")) for w in rj_windows if w.get("id") == focus.get("window")), focus.get("window"))
    # The most recent window is the focused one (cx-ppw2w): a window opened
    # behind, never key, must not lead the recency the next launch restores.
    front = items["windows.recency"][0] if items["windows.recency"] else None
    RESULTS.append((f"{label}: windows.recency front is focus.window", front == items["focus.window"],
                    f"recency front {json.dumps(front)}, focus {json.dumps(items['focus.window'])}", "windows"))
    terms = {}
    for ws in topo.get("workspaces", []):
        name = ws.get("name")
        if not rj(name):
            continue
        p = f"ws[{name}]"
        items[f"{p}.title"] = ws.get("title")
        items[f"{p}.screens"] = len(ws.get("screens", []))
        for s_index, screen in enumerate(ws.get("screens", [])):
            panes = screen.get("panes", [])
            pane_index = {pane.get("id"): i for i, pane in enumerate(panes)}
            items[f"{p}.s{s_index}.layout"] = layout_shape(screen.get("id"), pane_index)
            items[f"{p}.s{s_index}.zoomed"] = screen.get("zoomed_pane")
            for p_index, pane in enumerate(panes):
                pp = f"{p}.s{s_index}.pane{p_index}"
                tabs = pane.get("tabs", [])
                items[f"{pp}.tabs"] = [t.get("kind") for t in tabs]  # titles load late; URLs are their own rows
                items[f"{pp}.selected_tab"] = next((i for i, t in enumerate(tabs) if t.get("id") == pane.get("selected_tab")), None)
                for t_index, tab in enumerate(tabs):
                    tp = f"{pp}.tab{t_index}"
                    kind = tab.get("kind")
                    items[f"{tp}.id"] = tab.get("id")
                    if kind == "terminal":
                        items[f"{tp}.terminal"] = tab.get("terminal")
                        items[f"{tp}.cwd"] = tab.get("cwd")
                        items[f"{tp}.dead"] = tab.get("dead")
                        terms[tp] = tab.get("terminal")
                    elif kind == "browser":
                        items[f"{tp}.url"] = tab.get("url")
                    elif kind == "conversation":
                        items[f"{tp}.agent_session"] = tab.get("agent_session")
                    if kind == "terminal" and tab.get("id") == pane.get("selected_tab") and pane.get("id") in views:
                        view = views[pane.get("id")]
                        items[f"{tp}.view.attach"] = view.get("attach")
    # Terminals: scrollback, the numbered lines, the counter.
    pid = None
    if os.path.exists(PIDFILE):
        pid = int(open(PIDFILE).read().strip() or 0)
    for tp, term in terms.items():
        info = terminal_items(term)
        raw[f"terminal {tp}"] = info
        if info["numbered_lines"]:
            items[f"{tp}.scrollback.numbered_lines"] = info["numbered_lines"]
            items[f"{tp}.scrollback.numbered_max"] = info["numbered_max"]
            items[f"{tp}.scrollback.history_rows"] = info["history_rows"]
            items[f"{tp}.scrollback.history_sha"] = info["history_sha"]
        if info["ticks"]:
            items["counter.tick_in_daemon"] = max(info["ticks"])
    if pid:
        try:
            os.kill(pid, 0)
            alive = True
        except OSError:
            alive = False
        items["counter.pid"] = pid
        items["counter.alive"] = alive
    view_text = "\n".join(v.get("text") or "" for v in views.values())
    ticks = [int(t) for t in re.findall(r"rj-tick-(\d+)", view_text)]
    items["counter.tick_in_view"] = max(ticks) if ticks else None
    items["view.scrollback_tail"] = [line.strip() for line in view_text.splitlines() if f"rj-line-" in line][-3:]
    # Browser pages: what each page reports about itself.
    # Only reports sent since the last quit count: an older one says nothing about the reopened page.
    # A page in a workspace nobody shows loads when it is shown, as for a person: visit it.
    stale = lambda: [p for p in REPORTS if REPORTS[p].get("at", 0) <= SINCE]
    for page in stale():
        with visiting(PAGE_WORKSPACE.get(page)):
            wait(lambda: page not in stale(), 30, 0.5)
            if page == "tall":  # its scroll comes back after it loads
                wait(lambda: REPORTS["tall"].get("scrollY", 0) >= SCROLL - 40, 8, 0.5)
    if "tall" in REPORTS and REPORTS["tall"].get("at", 0) > SINCE:
        wait(lambda: REPORTS["tall"].get("scrollY", 0) >= SCROLL - 40, 8, 0.5)
    fresh = {page: r for page, r in REPORTS.items() if r.get("at", 0) > SINCE}
    for page in ("hist", "tall", "w2page"):
        if page in fresh:
            items[f"page[{page}].path"] = fresh[page]["path"]
    if "hist" in fresh:
        # WebKit's own back list, as the page sees it (a person's link clicks: 3 entries).
        items["page[hist].history_length"] = fresh["hist"].get("history")
    if "tall" in fresh:
        items["page[tall].scrollY"] = fresh["tall"]["scrollY"]
    # The agent chat: its acpmux record, its tab, and what its page shows.
    if AGENT:
        sid = AGENT["session"]
        try:
            client = Acpmux(acpmux_socket_of(AGENT["home"]))
            page = client.request("_acpmux/events", {"sessionId": sid, "afterSeq": 0, "limit": 5000})
            events = ((page.get("result") or {}).get("events")) or []
            items["agent.prompts"] = [e.get("msg", {}).get("text") for e in events if e.get("kind") == "user_message"]
            items["agent.draft"] = (client.request("_acpmux/draft_get", {"sessionId": sid}).get("result") or {}).get("draft")
            items["agent.status"] = (client.request("_acpmux/info", {"sessionId": sid}).get("result") or {}).get("status")
        except OSError as error:
            items["agent.acpmux"] = f"unreachable: {error}"
        items["agent.tabs_bound"] = sum(1 for ws in rj_workspaces(topo) for t in tabs_of(ws) if t.get("agent_session") == sid)
        pane = next((p.get("id") for ws in rj_workspaces(topo) for s_ in ws.get("screens", []) for p in s_.get("panes", [])
                     if any(t.get("agent_session") == sid or t.get("kind") == "conversation" for t in p.get("tabs", []))), AGENT.get("pane"))
        # The chat's page shows only while its workspace is shown: visit it.
        with visiting("rj-agent"):
            state = wait(lambda: (lambda r: r if isinstance(r, dict) and "error" not in r else None)(
                rpc("debug.agent_pane", {"action": "chat_state", **({"pane": pane} if pane else {})}, timeout=60)), 20, 1) \
                or rpc("debug.agent_pane", {"action": "chat_state", **({"pane": pane} if pane else {})}, timeout=60)
        raw["agent_pane.chat_state"] = state
        if isinstance(state, dict) and "error" not in state:
            items["agent.page.session"] = state.get("sessionId")
            items["agent.page.last_assistant"] = state.get("lastAssistant")
            items["agent.page.missing_session"] = state.get("missingSession")
        else:
            items["agent.page"] = f"chat_state: {json.dumps(state)[:120]}"
    dump(f"{label}-raw.json", raw)
    dump(f"{label}-items.json", items)
    return items


# ---- settle and compare ----------------------------------------------------------------------

def settled(expected_tabs):
    """Restore has settled when the topology is loaded with every rj-* tab back, the launch
    window has handed over (`debug.windows`: no launch_window, no window awaiting content,
    consistent), and every shown terminal view is attached live (`debug.surfaces`)."""
    topo = topology()
    if not topo or not topo.get("loaded"):
        return False
    if sum(len(tabs_of(w)) for w in rj_workspaces(topo)) < expected_tabs:
        return False
    windows = rpc("debug.windows")
    if not isinstance(windows, dict) or windows.get("launch_window") or windows.get("consistent") is False:
        return False
    if any(w.get("awaiting_content") for w in windows.get("windows", [])):
        return False
    _, views = view_panes()
    shown = [v for v in views.values() if v.get("kind") == "terminal" and v.get("presence") == "visible"]
    return bool(shown) and all(v.get("attach") == "live" for v in shown)


RESULTS = []  # (item, ok, detail, area)


def area_of(item):
    if item.startswith(("window", "focus")):
        return "windows"
    if item.startswith("agent") or ".agent_session" in item:
        return "agent chat"
    if item.startswith(("counter", "view.")) or any(k in item for k in (".scrollback", ".terminal", ".dead", ".cwd", ".view.attach")):
        return "terminal"
    if item.startswith("page[") or ".url" in item:
        return "browser"
    return "layout"


def broken(v, item=""):
    """A probe that answered nothing usable: missing, empty, or an error."""
    if v in (None, "<missing>", [], {}):
        return True
    if item == "agent.tabs_bound":
        return v == 0
    if isinstance(v, str):
        return v.startswith(("chat_state:", "unreachable"))
    return isinstance(v, dict) and ("error" in v or "code" in v and "message" in v)


def must_have(item):
    """Rows whose value is always present on a working app; for these, equal emptiness is a FAIL."""
    return (item.endswith((".frame", ".layout", ".view.attach", ".selected_workspace", ".id", ".url", ".tabs"))
            or item.endswith(".agent_session")
            or item in ("windows.recency", "focus.window", "focus.workspace", "agent.page", "agent.acpmux", "agent.prompts",
                        "agent.page.session", "agent.tabs_bound")
            or item.startswith("page["))


def seeded(before):
    """FAIL rows for seed parts the before-snapshot does not show, so a seed that failed cannot
    leave an empty comparison that passes."""
    def has(cond):
        return any(cond(k, v) for k, v in before.items())
    checks = {
        "term": [("3000 numbered lines", has(lambda k, v: k.endswith(".scrollback.numbered_lines") and v == SCROLLBACK_LINES)),
                 ("counter running", before.get("counter.alive") is True and isinstance(before.get("counter.tick_in_daemon"), int))],
        "web": [("history page at /hist-c after two link clicks", before.get("page[hist].path") == "/hist-c"),
                ("history page has three entries", before.get("page[hist].history_length") == 3),
                ("tall page scrolled", (before.get("page[tall].scrollY") or 0) >= SCROLL - 5)],
        "agent": [("three turns", len(before.get("agent.prompts") or []) == 3),
                  ("chat tab bound to the session", (before.get("agent.tabs_bound") or 0) >= 1
                   and bool(AGENT) and before.get("agent.page.session") == AGENT["session"])],
        "w2": [("second window", before.get("windows.count") == 2), ("w2 page", before.get("page[w2page].path") == "/w2page")],
        "split": [("rj-split workspace", has(lambda k, v: k.startswith("ws[rj-split].")))],
    }
    for part, rows in checks.items():
        if part in SKIP:
            continue
        for what, ok in rows:
            RESULTS.append((f"seed {part}: {what}", bool(ok), "seeded" if ok else "missing before the quit", "seed"))


def compare(variant, before, after):
    for item in sorted(set(before) | set(after)):
        b, a = before.get(item, "<missing>"), after.get(item, "<missing>")
        if item.startswith("counter.tick_in_"):
            ok = isinstance(a, int) and isinstance(b, int) and a > b
            detail = f"{b} -> {a} (must keep counting)"
        elif item.endswith(".frame") and isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
            ok = all(abs(float(x) - float(y)) <= 2 for x, y in zip(a, b))
            detail = f"{b} -> {a}"
        elif item == "page[tall].scrollY" and isinstance(a, int):
            # Against what was seeded, not the last reopen: a lost scroll must not pass the next variant.
            ok = abs(a - SCROLL) <= 40
            detail = f"{b} -> {a} (seeded {SCROLL})"
        elif item == "page[hist].history_length":
            seeded_length = SEEDED.get(item, 3)
            ok = a == seeded_length
            detail = f"{b} -> {a} (seeded {seeded_length}: the address load and two link clicks)"
        elif item.endswith(".scrollback.history_rows") and isinstance(a, int) and isinstance(b, int):
            # A view re-attaching may add a prompt line, never drop rows.
            ok = a >= b
            detail = f"{b} -> {a}"
        else:
            ok = a == b
            detail = json.dumps(a)[:100] if ok else f"{json.dumps(b)[:100]} -> {json.dumps(a)[:100]}"
        if ok and must_have(item) and (broken(a, item) or broken(b, item)):
            ok, detail = False, f"no value: {json.dumps(b)[:80]} -> {json.dumps(a)[:80]}"
        RESULTS.append((f"{variant}: {item}", ok, detail, area_of(item)))


def back_walk(label):
    """A person's Back and Forward (Cmd-[ / Cmd-], `browserBack` / `browserForward`) on the
    history tab: c -> b -> a -> b -> c. Each step must bring a report sent after that step, from
    the page it should reach. Run once after seeding (label `seed`: a failure there is the live
    Back bug, not restore) and after each reopen. Puts the page back on c if a step fails, so the
    next variant starts where the seed did."""
    if "web" in SKIP or not HIST.get("tab"):
        return
    hist = lambda: REPORTS.get("hist") or {}
    def reached(path, since):
        return hist().get("path") == path and hist().get("at", 0) > since
    pane = next((p.get("id") for ws in rj_workspaces(topology()) for s_ in ws.get("screens", []) for p in s_.get("panes", [])
                 if any(t.get("id") == HIST["tab"] for t in p.get("tabs", []))), None)
    with visiting("rj-web"):
        focused = rpc("action.run", {"action": "tab.focus", "target": f"tab:{HIST['tab']}", "focus": True})
        start = time.time()
        if not wait(lambda: reached("/hist-c", SINCE), 20, 0.5):
            RESULTS.append((f"{label}: the history tab shows /hist-c before Back", False,
                            f"at {hist().get('path')}; focus {json.dumps(focused)[:80]}", "browser"))
            return
        target = {"target_kind": "pane", "target_id": pane} if pane else {}
        steps = [("browserBack", "/hist-b"), ("browserBack", "/hist-a"), ("browserForward", "/hist-b"), ("browserForward", "/hist-c")]
        for action_id, path in steps:
            step = time.time()
            reply = rpc("debug.toast", {"perform": action_id, **target})
            ok = bool(wait(lambda: reached(path, step), 15, 0.3))
            RESULTS.append((f"{label}: {action_id} reaches {path}", ok,
                            f"performed {reply.get('performed') if isinstance(reply, dict) else reply}; at {hist().get('path')}", "browser"))
            if not ok:
                break
        if hist().get("path") != "/hist-c":
            for _ in range(2):  # back to c: Forward first (keeps the list), the address last
                step = time.time()
                rpc("debug.toast", {"perform": "browserForward", **target})
                if wait(lambda: reached("/hist-c", step), 5, 0.3):
                    break
            else:
                rpc("browser.page.eval", {"tab": HIST["tab"], "script": f"location.href = '{'hist-c.html' if opts.hist_file else '/hist-c'}'; true"})
                wait(lambda: hist().get("path") == "/hist-c" and hist().get("at", 0) > start, 10, 0.3)
                RESULTS.append((f"{label}: page put back on /hist-c by its address", False,
                                "Forward could not return; the next variant's history length counts from here", "browser"))


def journey(base):
    global SINCE
    seed(base)
    back_walk("seed")  # before any reopen: tells the live Back bug apart from a restore loss
    for n, variant in enumerate(v.strip() for v in opts.variants.split(",") if v.strip()):
        before = snapshot(f"{variant}-before")
        if n == 0:
            seeded(before)
            SEEDED.update({k: v for k, v in before.items() if k == "page[hist].history_length"})
        if variant == "crash":
            # A crash comes after the last change has been saved (the browser history and record
            # writers debounce 500 ms); the rows check what was saved, not what was still in flight.
            time.sleep(2)
        expected = sum(len(tabs_of(w)) for w in rj_workspaces(topology()))
        started = SINCE = time.time()
        if not APP.quit(variant):
            RESULTS.append((f"{variant}: app ends ({'killed' if variant == 'crash' else 'its quit path'})", False, "still running", "app quit"))
            return
        if not APP.relaunch():
            RESULTS.append((f"{variant}: app relaunches", False, "no socket", "app quit"))
            return
        ok = wait(lambda: settled(expected), opts.settle, 1)
        took = time.time() - started
        say(f"  restore {'settled' if ok else 'did NOT settle'} {took:.1f} s after the quit")
        RESULTS.append((f"{variant}: restore settles", bool(ok), f"{took:.1f} s after the quit", "layout"))
        # The counter's next tick, in the view (it must keep counting after the reopen).
        if isinstance(before.get("counter.tick_in_view"), int):
            wait(lambda: view_tick() > before["counter.tick_in_view"], 10, 0.5)
        compare(variant, before, snapshot(f"{variant}-after"))
        back_walk(f"{variant} after the reopen")


def main():
    global APP
    APP = App()
    server, base = start_server()
    say(f"local pages at {base}; daemon {daemon_socket()}")
    try:
        journey(base)
    except SystemExit as stop:  # --max-seconds, a signal, or the parent gone: keep the rows so far
        RESULTS.append(("journey finished", False, f"stopped early: {stop.code}", "harness"))
    finally:
        restore_acpmux_config()
        server.shutdown()
    width = max((len(r[0]) for r in RESULTS), default=10)
    print("\n" + "-" * (width + 40))
    for item, ok, detail, area in RESULTS:
        print(f"{'PASS' if ok else 'FAIL'}  {item:<{width}}  [{area}] {detail}")
    failed = [r for r in RESULTS if not r[1]]
    print(f"RESULT {'PASS' if not failed else 'FAIL'}: {len(RESULTS) - len(failed)}/{len(RESULTS)} rows pass; out {opts.out}")
    dump("report.json", [{"item": r[0], "ok": r[1], "detail": r[2], "area": r[3]} for r in RESULTS])
    sys.exit(1 if failed else 0)


APP = None
if __name__ == "__main__":
    main()
