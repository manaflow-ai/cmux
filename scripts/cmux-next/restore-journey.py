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
launch` (scripts/cmux-next/restore-journey-slot.sh does the whole slot run), or any tagged DEV
build. It drives the app through its control socket and the tag's daemon through the bundled
`cmux` CLI.

Variants:
  quit    the Quit menu item / Cmd-Q path (`debug.quit {open: true}`; if the sheet asks, its
          default is pressed, as Return does, and the row records whether that keeps sessions);
  update  what Sparkle does before it relaunches into an update
          (`debug.updater {action: "relaunch"}`: the updater's relaunch hook, then terminate).
Each relaunch reuses the app's own launch environment (read from the running process), so a
capture slot keeps its HOME, TMPDIR, socket and config file. It never runs `defaults delete`:
UserDefaults survive, as on a person's Mac. If the slot's app copy is gone after the quit,
`--src` re-clones it the way capture-host does (same bundle id, ad-hoc signed).

The seeded state, all named `rj-*` (earlier rj-* workspaces are closed first):
  window 1: rj-term (3000 numbered lines; a counter loop with a pid file in a right split; `top`
            in a nested down split; selected at the end), rj-split (four terminals in nested
            right/down splits, two tabs in one pane, the first selected), rj-web (two browser
            tabs from a local server: a page that goes on to a second page by itself the first
            time, for Back, and a tall page that scrolls itself the first time), rj-agent (an
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
web server, pid file and chat folder live in --out. The app is left running after the last
relaunch (the caller quits it and releases the slot).
"""
import argparse, glob, hashlib, http.server, json, os, re, socket, subprocess, sys, threading, time
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the app's control socket")
parser.add_argument("--variants", default="quit,update")
parser.add_argument("--out", default="/tmp/restore-journey")
parser.add_argument("--fake-agent", default=os.path.join(HERE, "../../cmux-tui/crates/acpmux/tests/fake_agent.py"))
parser.add_argument("--src", help="staged app to re-clone from when the slot's app copy is gone after a quit")
parser.add_argument("--settle", type=float, default=90, help="seconds restore may take to settle")
parser.add_argument("--skip", default="", help="comma list of seed parts to skip: term,split,web,agent,w2")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SKIP = {s.strip() for s in opts.skip.split(",") if s.strip()}
LOG = open(os.path.join(opts.out, "journey.log"), "a")
RUN = os.urandom(3).hex()
SCROLLBACK_LINES = 3000
SCROLL = 1500


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(time.strftime("%H:%M:%S ") + line + "\n")
    LOG.flush()


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
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
        """Ends the app through its own path and waits for the exact pid to exit."""
        if variant == "update":
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
        if os.path.exists(opts.socket):
            os.unlink(opts.socket)
        args = ["/usr/bin/open", "-g", "-n", "-a", self.bundle]
        for key, value in self.env.items():
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


def configure_fake(home):
    path = os.path.join(home, "config.json")
    try:
        with open(path) as f:
            original = f.read()
    except FileNotFoundError:
        original = None
    config = json.loads(original) if original else {}
    config.setdefault("harnesses", {})["fake"] = {"argv": ["python3", os.path.abspath(opts.fake_agent)]}
    with open(path + ".rj", "w") as f:
        f.write(json.dumps(config, indent=2))
    os.replace(path + ".rj", path)
    ACPMUX_RESTORE.append((path, original))
    client = Acpmux(acpmux_socket_of(home))
    say(f"  acpmux reload_config -> {json.dumps(client.request('_acpmux/reload_config', {}))[:160]}")
    return client


def restore_acpmux_config():
    for path, original in ACPMUX_RESTORE:
        try:
            if original is None:
                os.remove(path)
            else:
                with open(path, "w") as f:
                    f.write(original)
            Acpmux(acpmux_socket_of(os.path.dirname(path))).request("_acpmux/reload_config", {}, timeout=10)
        except OSError as error:
            say("could not restore", path, error)


# ---- the local web server: pages that report their own path and scroll ---------------------

REPORTS = {}  # page name -> latest {path, scrollY, at}
SERVED = set()
LOCK = threading.Lock()


def page_html(name):
    with LOCK:
        first = name not in SERVED
        SERVED.add(name)
    body = "".join(f"<p style='height:40px;margin:0'>rj {name} row {i}</p>" for i in range(400)) if name == "tall" else ""
    act = ""
    if first and name == "tall":
        act = f"setTimeout(function(){{window.scrollTo(0,{SCROLL});}},300);"
    if first and name == "hist-a":
        act = "setTimeout(function(){location.href='/hist-b';},500);"
    # Both history pages report as one tab ("hist").
    tab = "hist" if name.startswith("hist") else name
    return f"""<!doctype html><html><head><title>rj {name}</title></head><body>
<h1>rj {name}</h1>{body}
<script>
function report(){{fetch('/report?page={tab}&path='+encodeURIComponent(location.pathname)+'&y='+Math.round(window.scrollY)).catch(function(){{}});}}
{act}
setInterval(report,1000); window.addEventListener('scroll',report); report();
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/report":
            q = parse_qs(url.query)
            with LOCK:
                REPORTS[q.get("page", [""])[0]] = {"path": q.get("path", [""])[0], "scrollY": int(q.get("y", ["0"])[0]), "at": time.time()}
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
    ws = new_workspace("rj-term")
    if not ws.get("terminal_id"):
        return
    write(ws["terminal_id"], f"cd {opts.out}; for i in $(seq 1 {SCROLLBACK_LINES}); do echo rj-line-$i-{RUN}; done; echo rj-scrollback-done\n")
    right = split(ws["pane_id"], "right")
    if right.get("terminal_id"):
        pidfile = os.path.join(opts.out, "counter.pid")
        write(right["terminal_id"], f"sh -c 'echo $$ > {pidfile}; i=0; while :; do i=$((i+1)); echo rj-tick-$i; sleep 1; done'\n")
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
    hist = value(cli("tab", "create", "browser", "--url", f"{base}/hist-a", "--workspace", ws["workspace_id"], "--pane", ws["pane_id"]))
    if hist.get("tab_id"):
        cli("tab", hist["tab_id"], "focus")
    if not wait(lambda: (REPORTS.get("hist") or {}).get("path") == "/hist-b", 40):
        say("  the history page never reported from /hist-b")
    right = split(ws["pane_id"], "right")
    tall = value(cli("tab", "create", "browser", "--url", f"{base}/tall", "--workspace", ws["workspace_id"], "--pane", right.get("pane_id") or ws["pane_id"]))
    if tall.get("tab_id"):
        cli("tab", tall["tab_id"], "focus")
    if not wait(lambda: (REPORTS.get("tall") or {}).get("scrollY", 0) >= SCROLL - 5, 40):
        say("  the tall page never reported its scroll")


AGENT = None


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
    time.sleep(3)


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


def view_panes():
    report = rpc("debug.surfaces", {"text": True}, timeout=60)
    panes = {}
    for window in report.get("windows", []) if isinstance(report, dict) else []:
        for pane in window.get("panes", []):
            panes[pane.get("pane")] = pane
    return report, panes


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
                items[f"{pp}.tabs"] = [t.get("kind") + ("" if t.get("kind") in ("terminal", "conversation") else ":" + (t.get("title") or "")) for t in tabs]
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
                    if tab.get("id") == pane.get("selected_tab") and pane.get("id") in views:
                        view = views[pane.get("id")]
                        items[f"{tp}.view.attach"] = view.get("attach")
    # Terminals: scrollback, the numbered lines, the counter.
    pid = None
    pidfile = os.path.join(opts.out, "counter.pid")
    if os.path.exists(pidfile):
        pid = int(open(pidfile).read().strip() or 0)
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
    for page in ("hist", "tall", "w2page"):
        if page in REPORTS:
            items[f"page[{page}].path"] = REPORTS[page]["path"]
    if "tall" in REPORTS:
        items["page[tall].scrollY"] = REPORTS["tall"]["scrollY"]
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
        state = rpc("debug.agent_pane", {"action": "chat_state", **({"pane": pane} if pane else {})}, timeout=60)
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
    return all(v.get("attach") == "live" for v in views.values() if v.get("kind") == "terminal" and v.get("presence") == "visible")


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


def compare(variant, before, after):
    for item in sorted(set(before) | set(after)):
        b, a = before.get(item, "<missing>"), after.get(item, "<missing>")
        if item.startswith("counter.tick_in_"):
            ok = isinstance(a, int) and isinstance(b, int) and a > b
            detail = f"{b} -> {a} (must keep counting)"
        elif item.endswith(".frame") and isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
            ok = all(abs(float(x) - float(y)) <= 2 for x, y in zip(a, b))
            detail = f"{b} -> {a}"
        elif item == "page[tall].scrollY" and isinstance(a, int) and isinstance(b, int):
            ok = abs(a - b) <= 40
            detail = f"{b} -> {a}"
        elif item.endswith(".scrollback.history_rows") and isinstance(a, int) and isinstance(b, int):
            # A view re-attaching may add a prompt line, never drop rows.
            ok = a >= b
            detail = f"{b} -> {a}"
        else:
            ok = a == b
            detail = json.dumps(a)[:100] if ok else f"{json.dumps(b)[:100]} -> {json.dumps(a)[:100]}"
        RESULTS.append((f"{variant}: {item}", ok, detail, area_of(item)))


def main():
    global APP
    APP = App()
    server, base = start_server()
    say(f"local pages at {base}; daemon {daemon_socket()}")
    seed(base)
    try:
        for variant in [v.strip() for v in opts.variants.split(",") if v.strip()]:
            before = snapshot(f"{variant}-before")
            expected = sum(len(tabs_of(w)) for w in rj_workspaces(topology()))
            started = time.time()
            if not APP.quit(variant):
                RESULTS.append((f"{variant}: app exits through its quit path", False, "still running", "app quit"))
                break
            if not APP.relaunch():
                RESULTS.append((f"{variant}: app relaunches", False, "no socket", "app quit"))
                break
            ok = wait(lambda: settled(expected), opts.settle, 1)
            took = time.time() - started
            say(f"  restore {'settled' if ok else 'did NOT settle'} {took:.1f} s after the quit")
            RESULTS.append((f"{variant}: restore settles", bool(ok), f"{took:.1f} s after the quit", "layout"))
            # Pages report every second once loaded; wait for one report from each after the reload.
            mark = time.time()
            wait(lambda: all((REPORTS.get(p) or {}).get("at", 0) > mark for p in list(REPORTS)), 30, 1)
            time.sleep(2)  # the counter's next tick
            compare(variant, before, snapshot(f"{variant}-after"))
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
