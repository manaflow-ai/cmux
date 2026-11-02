#!/usr/bin/env python3
"""TYPING UNDER LOAD: seeded background load profiles for a running tagged cmux-next build. They never move
the person's focus, and they only use the socket named on the command line.

  load_profiles.py run L1|L2|L3|L4|L5|L6 --app-socket SOCK [--home HOME] [--keep PANE] [--seed N]
                   [--duration S] [--out DIR] [--rate R]
  load_profiles.py plan L1..L6 [--seed N]       what a profile would do (no app)

  L1  CLI storm: 8 workers call the bundled cmux CLI and the app socket in a seeded mix (workspace, pane, tab
      and terminal list; tab create and close; terminal write; screen read; notify; workspace status,
      progress and log) at --rate calls a second in total (50..200). The achieved rate is logged.
  L2  MCP storm: 4 clients of `cmux mcp serve --all-tools` call tools back to back: workspace_list,
      browser_profile_open (activate false, its own pane), tab_move inside that pane (never to another
      pane: that moves focus), browser_repl_eval (snapshot, click, eval). No browser.page.* tool is on
      MCP, so snapshot, click and eval go through browser_repl_eval.
  L3  Browser: 30 browser tabs. 4 are visible beside --keep: one plays a video (a canvas stream in a <video>),
      one is a heavy SPA (thousands of nodes re-rendered at each click), and two are the CSS-animation page.
      26 tabs are in the profile's own workspace. One tab navigates every 2 s, and the browser REPL
      (cmux-browser-host eval) clicks the SPA every second. --devtools opens DevTools on the SPA tab during
      set-up. The app focuses the DevTools view, so the profile then focuses --keep again, before
      LOAD-READY and before the focus guard starts.
  L4  Agents: 6 agent panes that stream (agent_stream_acp.py "stream:" prompts, tool calls included), in the
      profile's own workspace (--agents-where beside: beside --keep). A pane where the app cannot open the
      chat runs tuikit's terminal agent-stream instead; the manifest says which, and why.
  L5  HEAVY: heavy_profile.py build --no-focus (40 workspaces, 200 tabs, 12 TUI panes, browser, agent),
      then teardown at the end.
  L6  L1 to L5 at the same time, one process each (DIR/L6/L1 ... DIR/L6/L5).

Rules. Every profile follows them, and the tests check them:
  - Only --app-socket. There is no default socket, so the person's running cmux cannot be reached. A
    socket whose system.identify bundle id is com.cmuxterm.app (the shipped app) is refused.
  - No focus verb, no --focus, no activate. The profile works in its own new workspaces, which are never
    shown. Panes beside --keep come from split, and a split keeps the focus. --keep is never typed into,
    closed or split away.
  - The focus guard reads snapshot.get topology.focus and debug.focus (the key window and each window's
    first responder) when the load is ready, then every 0.5 s. It writes every change to focus.jsonl. The
    manifest says focus_changed true or false.
  - At the end (duration, SIGTERM or SIGINT), the profile closes what it made, stops what it started and
    writes the manifest.

Output in DIR/<L>/: manifest.json (seed, flags, every id it made, what runs where, start and end, the
achieved rates, refusals, focus_changed) and calls.jsonl (one line per call: t_mono, t_wall, kind, ms,
ok, worker). The profile prints `LOAD-READY <L> t_mono=<x> t_wall=<y>` when the load runs at full rate,
and `LOAD-DONE <L> ...` with the summary at the end. Exit 0: it ran; 1: refusals or a focus change;
2: no app, or a refused socket.
"""
import argparse
import json
import os
import random
import signal
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import heavy_profile  # noqa: E402
import tuikit  # noqa: E402

PROFILES = ("L1", "L2", "L3", "L4", "L5", "L6")
SHIPPED_BUNDLES = ("com.cmuxterm.app",)
L1_KINDS = (  # (kind, weight)
    ("workspace.list", 3), ("pane.list", 2), ("tab.list", 3), ("terminal.list", 2), ("snapshot.get", 2),
    ("tab.create", 2), ("tab.close", 2), ("terminal.write", 4), ("screen.read", 4), ("notify", 1),
    ("status.set", 3), ("progress.set", 3), ("log.append", 3))


class Stop(Exception):
    pass


# ---- shared machinery ----------------------------------------------------------------------------

class Calls:
    """calls.jsonl: one line per call; per-second achieved counts."""

    def __init__(self, path):
        self.f = open(path, "a", encoding="utf-8")
        self.lock = threading.Lock()
        self.count = 0
        self.failed = 0
        self.by_kind = {}
        self.load_calls = 0  # calls made between LOAD-READY and the stop (set-up and teardown left out)
        self.load_failed = 0
        self.window = None  # (ready, stop) monotonic, once the load ran

    def record(self, kind, start, ok, worker, error=None):
        now = time.monotonic()
        line = {"t_mono": round(start, 6), "t_wall": round(time.time() - (now - start), 6), "kind": kind,
                "ms": round((now - start) * 1000, 3), "ok": ok, "worker": worker}
        if error:
            line["error"] = str(error)[:200]
        with self.lock:
            self.f.write(json.dumps(line) + "\n")
            self.count += 1
            self.failed += 0 if ok else 1
            self.by_kind[kind] = self.by_kind.get(kind, 0) + 1
            if self.loading and not kind.startswith(("setup.", "teardown.")):
                self.load_calls += 1
                self.load_failed += 0 if ok else 1

    loading = False

    def summary(self):
        """achieved_per_s: the load's own calls over the load's time (LOAD-READY to the stop)."""
        with self.lock:
            span = (self.window[1] - self.window[0]) if self.window else 0.0
            return {"calls": self.load_calls, "failed": self.load_failed, "all_calls": self.count,
                    "all_failed": self.failed, "by_kind": dict(self.by_kind), "load_seconds": round(span, 3),
                    "achieved_per_s": round(self.load_calls / span, 2) if span > 0 else 0.0}

    def close(self):
        self.f.close()


class Bucket:
    """At most `rate` calls a second in total over every worker (a shared schedule)."""

    def __init__(self, rate):
        self.period = 1.0 / rate if rate > 0 else 0.0
        self.lock = threading.Lock()
        self.next = time.monotonic()

    def take(self, stop):
        if not self.period:
            return
        with self.lock:
            due = max(self.next, time.monotonic() - 0.25)  # behind by more than 0.25 s: do not burst to catch up
            self.next = due + self.period
        while not stop.is_set():
            left = due - time.monotonic()
            if left <= 0:
                return
            stop.wait(min(left, 0.05))


def focus_state(app):
    """What the person's focus is now: topology.focus and, when the app has it, debug.focus."""
    state = {}
    try:
        topo = app.topology()
        state["focus"] = topo.get("focus")
        state["key_windows"] = [w.get("id") for w in topo.get("windows", []) if w.get("key_window")]
    except (OSError, ValueError) as error:
        state["error"] = str(error)[:200]
    try:
        dbg = app.rpc("debug.focus", timeout=5)
        if isinstance(dbg, dict) and not dbg.get("error"):
            state["key_window"] = dbg.get("key_window")
            state["first_responders"] = sorted(
                str((w.get("appkit") or {}).get("first_responder")) for w in dbg.get("windows", []) or []
                if isinstance(w, dict))
    except (OSError, ValueError):
        pass
    return state


class FocusGuard(threading.Thread):
    def __init__(self, app, path, stop, period=0.5):
        super().__init__(daemon=True)
        self.app, self.path, self.stop, self.period = app, path, stop, period
        self.baseline = None
        self.changes = 0

    def run(self):
        with open(self.path, "a", encoding="utf-8") as f:
            self.baseline = focus_state(self.app)
            last = self.baseline
            f.write(json.dumps({"t_mono": time.monotonic(), "t_wall": time.time(), "ev": "baseline", "state": last}) + "\n")
            f.flush()
            while not self.stop.wait(self.period):
                now = focus_state(self.app)
                if "error" in now:
                    continue
                if now != last:
                    self.changes += 1 if now.get("focus") != last.get("focus") or \
                        now.get("key_window") != last.get("key_window") else 0
                    f.write(json.dumps({"t_mono": time.monotonic(), "t_wall": time.time(), "ev": "change",
                                        "state": now, "was": last}) + "\n")
                    f.flush()
                    last = now


class Profile:
    """One profile's run: its app, folder, manifest, calls log, stop event, and what to undo."""

    name = None

    def __init__(self, a, app):
        self.a, self.app = a, app
        self.rng = random.Random("%s-%d" % (self.name, a.seed))
        self.dir = os.path.join(a.out, self.name)
        os.makedirs(self.dir, exist_ok=True)
        self.calls = Calls(os.path.join(self.dir, "calls.jsonl"))
        self.stop = threading.Event()
        self.manifest = {"profile": self.name, "seed": a.seed, "duration": a.duration, "keep": a.keep,
                         "app_socket": app.app_sock, "daemon_socket": app.daemon_sock, "cli": app.cli,
                         "identity": app.identity, "made": {"workspaces": [], "panes": [], "tabs": []},
                         "processes": [], "refusals": [], "started_wall": time.time()}
        self.guard = None

    # recording
    def save(self):
        tuikit.write_atomic(os.path.join(self.dir, "manifest.json"),
                            json.dumps(self.manifest, indent=2, ensure_ascii=False, default=str) + "\n")

    def refused(self, what, error):
        self.manifest["refusals"].append({"what": what, "error": str(error)[:400], "t_mono": time.monotonic()})
        self.save()

    def cli(self, kind, *args, worker=0, timeout=30):
        """One CLI call, logged. Returns the value or None (refused, logged)."""
        start = time.monotonic()
        try:
            value = self.app.cmux(*args, timeout=timeout)
            self.calls.record(kind, start, True, worker)
            return value
        except heavy_profile.Refused as error:
            self.calls.record(kind, start, False, worker, error)
            return None

    def rpc(self, kind, method, params=None, worker=0):
        start = time.monotonic()
        try:
            reply = self.app.rpc(method, params or {}, timeout=30)
            ok = not (isinstance(reply, dict) and reply.get("error"))
            self.calls.record(kind, start, ok, worker, None if ok else reply.get("error"))
            return reply
        except (OSError, ValueError) as error:
            self.calls.record(kind, start, False, worker, error)
            return None

    def workspace(self, label):
        """A new workspace of this profile (created without focus; never shown by it)."""
        name = "tk-load-%s-%d-%s" % (self.name, self.a.seed, label)
        value = self.app.cmux("workspace", "create", "--name", name)
        entry = {"name": name, "workspace_id": value.get("workspace_id"), "pane_id": value.get("pane_id"),
                 "tab_id": value.get("tab_id"), "terminal_id": value.get("terminal_id")}
        self.manifest["made"]["workspaces"].append(entry)
        self.save()
        return entry

    def beside_keep(self, count, argv, what):
        """`count` panes in one new column right of --keep (split --right, then --down), each running argv
        (a placeholder when None). Split keeps the focus. Returns the pane records."""
        if not self.a.keep:
            raise heavy_profile.Refused("%s beside the typing pane needs --keep PANE" % what)
        made = []
        v = self.app.cmux("pane", self.a.keep, "split", "--right", "--ratio", "0.5",
                          *heavy_profile.run_args(argv or ["/bin/sleep", "86400"]))
        made.append(v)
        last = v.get("pane_id")
        for i in range(1, count):
            ratio = "%.4f" % (1.0 - 1.0 / (count - i + 1))
            v = self.app.cmux("pane", last, "split", "--down", "--ratio", ratio,
                              *heavy_profile.run_args(argv or ["/bin/sleep", "86400"]))
            made.append(v)
            last = v.get("pane_id")
        for v in made:
            self.manifest["made"]["panes"].append({"pane_id": v.get("pane_id"), "tab_id": v.get("tab_id"),
                                                   "terminal_id": v.get("terminal_id"), "for": what})
        self.save()
        return made

    def start_process(self, argv, label, env=None, stdin=None, stdout=None):
        proc = subprocess.Popen(argv, stdin=stdin, stdout=stdout or subprocess.DEVNULL,
                                stderr=open(os.path.join(self.dir, "%s.err" % label), "w"),
                                env=env, start_new_session=True)
        self.manifest["processes"].append({"pid": proc.pid, "label": label, "argv": argv})
        self.save()
        return proc

    # lifecycle
    def setup(self):
        pass

    def load(self):
        """Runs until self.stop is set."""
        self.stop.wait()

    def teardown(self):
        for proc in self.manifest["processes"]:
            try:
                os.killpg(proc["pid"], signal.SIGTERM)  # its own session (start_new_session)
            except OSError:
                pass
        for pane in reversed(self.manifest["made"]["panes"]):
            if pane.get("pane_id") and pane.get("pane_id") != self.a.keep:
                self.cli("teardown.pane.close", "pane", pane["pane_id"], "close")
        for ws in self.manifest["made"]["workspaces"]:
            if ws.get("workspace_id"):
                self.cli("teardown.workspace.close", "workspace", ws["workspace_id"], "close")


# ---- L1: CLI storm -------------------------------------------------------------------------------

class L1(Profile):
    name = "L1"
    WORKERS = 8

    def setup(self):
        self.ws = self.workspace("storm")
        self.mine = [[] for _ in range(self.WORKERS)]  # tabs each worker made (it closes only its own)
        self.lock = threading.Lock()
        self.manifest["rate"] = self.a.rate
        self.manifest["workers"] = self.WORKERS
        self.manifest["mix"] = dict(L1_KINDS)
        self.save()

    def pick(self, rng):
        total = sum(w for _, w in L1_KINDS)
        r = rng.uniform(0, total)
        for kind, w in L1_KINDS:
            r -= w
            if r <= 0:
                return kind
        return L1_KINDS[-1][0]

    def call(self, kind, rng, worker):
        ws, pane, term = self.ws["workspace_id"], self.ws["pane_id"], self.ws["terminal_id"]
        n = rng.randrange(10 ** 6)
        if kind == "workspace.list":
            return self.cli(kind, "workspace", "list", worker=worker)
        if kind == "pane.list":
            return self.cli(kind, "pane", "list", "--workspace", ws, worker=worker)
        if kind == "tab.list":
            return self.cli(kind, "tab", "list", "--pane", pane, worker=worker)
        if kind == "terminal.list":
            return self.cli(kind, "terminal", "list", "--pane", pane, worker=worker)
        if kind == "snapshot.get":
            return self.rpc(kind, "snapshot.get", worker=worker)
        if kind == "tab.create" or (kind == "tab.close" and not self.mine[worker]):
            if len(self.mine[worker]) >= 3:
                kind = "tab.close"
            else:
                v = self.cli("tab.create", "tab", "create", "terminal", "--workspace", ws, "--pane", pane,
                             "--name", "storm-%d-%d" % (worker, n), worker=worker)
                if v and v.get("tab_id"):
                    self.mine[worker].append(v["tab_id"])
                    with self.lock:
                        self.manifest["made"]["tabs"].append(v["tab_id"])
                return v
        if kind == "tab.close":
            tab = self.mine[worker].pop(0)
            v = self.cli(kind, "tab", tab, "close", worker=worker)
            with self.lock:
                if tab in self.manifest["made"]["tabs"]:
                    self.manifest["made"]["tabs"].remove(tab)
            return v
        if kind == "terminal.write":
            return self.cli(kind, "terminal", term, "write", "--text", "echo storm %d %d\n" % (worker, n), worker=worker)
        if kind == "screen.read":
            return self.cli(kind, "terminal", term, "screen", "read", worker=worker)
        if kind == "notify":
            return self.cli(kind, "notify", "--title", "tk-load %d" % n, "--body", "storm worker %d" % worker,
                            "--workspace", ws, "--desktop", "false", worker=worker)
        if kind == "status.set":
            return self.cli(kind, "workspace", ws, "status", "set", "storm%d" % worker, "call %d" % n, worker=worker)
        if kind == "progress.set":
            return self.cli(kind, "workspace", ws, "progress", "set", "%.2f" % rng.random(), "--label", "storm",
                            worker=worker)
        return self.cli(kind, "workspace", ws, "log", "append", "storm %d call %d" % (worker, n), "--level", "info",
                        "--source", "tk-load", worker=worker)

    def load(self):
        bucket = Bucket(self.a.rate)

        def worker(index):
            rng = random.Random("L1-%d-%d" % (self.a.seed, index))
            while not self.stop.is_set():
                bucket.take(self.stop)
                if self.stop.is_set():
                    return
                self.call(self.pick(rng), rng, index)

        threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(self.WORKERS)]
        for t in threads:
            t.start()
        self.stop.wait()
        for t in threads:
            t.join(35)

    def teardown(self):
        for tab in list(self.manifest["made"]["tabs"]):
            self.cli("teardown.tab.close", "tab", tab, "close")
        super().teardown()


# ---- L2: MCP storm -------------------------------------------------------------------------------

class Mcp:
    """One `cmux mcp serve --all-tools` client over stdio (newline-delimited JSON-RPC)."""

    def __init__(self, profile, index):
        app = profile.app
        env = {"HOME": app.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1",
               "CMUX_AGENT_SESSION": "tk-load-L2-%d" % index}  # serve runs for an agent session (no settings edit)
        argv = [app.cli, "--socket", app.daemon_sock, "--app-socket", app.app_sock, "mcp", "serve", "--all-tools"]
        self.proc = profile.start_process(argv, "mcp-%d" % index, env=env, stdin=subprocess.PIPE,
                                          stdout=subprocess.PIPE)
        self.next = 0
        self.call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                 "clientInfo": {"name": "tk-load", "version": "1"}})
        self.notify("notifications/initialized")

    def send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def notify(self, method):
        self.send({"jsonrpc": "2.0", "method": method})

    def call(self, method, params, timeout=30):
        self.next += 1
        rid = self.next
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise OSError("mcp server ended")
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == rid:
                if "error" in msg:
                    raise heavy_profile.Refused("%s: %s" % (method, json.dumps(msg["error"])[:200]))
                return msg.get("result")
        raise heavy_profile.Refused("%s: no answer in %d s" % (method, timeout))

    def tool(self, name, arguments):
        result = self.call("tools/call", {"name": name, "arguments": arguments})
        if isinstance(result, dict) and result.get("isError"):
            raise heavy_profile.Refused("%s: %s" % (name, json.dumps(result.get("content"))[:200]))
        return result


def tool_value(result):
    """A tools/call result's JSON value (structuredContent, else the first text content parsed)."""
    if not isinstance(result, dict):
        return {}
    if isinstance(result.get("structuredContent"), dict):
        value = result["structuredContent"]
        return value.get("value", value)
    for item in result.get("content") or []:
        if item.get("type") == "text":
            try:
                value = json.loads(item["text"])
                return value.get("value", value) if isinstance(value, dict) else {}
            except ValueError:
                return {}
    return {}


class L2(Profile):
    name = "L2"
    CLIENTS = 4

    def setup(self):
        self.base = start_pages(self)
        self.lanes = []
        for i in range(self.CLIENTS):
            ws = self.workspace("mcp%d" % i)
            try:
                client = Mcp(self, i)
            except (OSError, heavy_profile.Refused) as error:
                self.refused("mcp client %d" % i, error)
                continue
            self.lanes.append({"client": client, "ws": ws, "tabs": [], "index": i})
        self.manifest["clients"] = len(self.lanes)
        self.save()

    def step(self, lane, rng):
        c, ws, i = lane["client"], lane["ws"], lane["index"]
        roll = rng.random()
        if roll < 0.2 or not lane["tabs"]:
            kind = "mcp.browser_profile_open"
            start = time.monotonic()
            try:
                value = tool_value(c.tool("browser_profile_open", {
                    "url": page_url(self.base, "anim", rng.randrange(4)), "profile": "default",
                    "pane": ws["pane_id"], "activate": False}))
                if value.get("tab_id"):
                    lane["tabs"].append(value["tab_id"])
                    self.manifest["made"]["tabs"].append(value["tab_id"])
                self.calls.record(kind, start, True, i)
            except (OSError, heavy_profile.Refused) as error:
                self.calls.record(kind, start, False, i, error)
            if len(lane["tabs"]) > 6:
                tab = lane["tabs"].pop(0)
                self.cli("mcp.tab_close(cli)", "tab", tab, "close", worker=i)
                self.manifest["made"]["tabs"].remove(tab) if tab in self.manifest["made"]["tabs"] else None
            return
        if roll < 0.35:
            name, args = "workspace_list", {}
        elif roll < 0.5 and len(lane["tabs"]) > 1:
            # Inside the same pane only: a move to another pane makes it the focused pane.
            name, args = "tab_move", {"tab": rng.choice(lane["tabs"]), "destination_pane": ws["pane_id"],
                                      "index": rng.randrange(len(lane["tabs"]))}
        else:
            tab = rng.choice(lane["tabs"])
            code = rng.choice((
                'const p = await tabs.use("%s"); return (await p.snapshot()).length' % tab,
                'const p = await tabs.use("%s"); await p.click("#bump"); return 1' % tab,
                'const p = await tabs.use("%s"); return await p.evaluate(() => document.title)' % tab))
            name, args = "browser_repl_eval", {"session": "tk-load-L2-%d" % i, "code": code, "timeoutMs": 5000}
        start = time.monotonic()
        try:
            c.tool(name, args)
            self.calls.record("mcp." + name, start, True, i)
        except (OSError, heavy_profile.Refused) as error:
            self.calls.record("mcp." + name, start, False, i, error)

    def load(self):
        def run(lane):
            rng = random.Random("L2-%d-%d" % (self.a.seed, lane["index"]))
            while not self.stop.is_set():
                self.step(lane, rng)

        threads = [threading.Thread(target=run, args=(lane,), daemon=True) for lane in self.lanes]
        for t in threads:
            t.start()
        self.stop.wait()
        for lane in self.lanes:
            try:
                lane["client"].proc.stdin.close()
            except OSError:
                pass
        for t in threads:
            t.join(35)

    def teardown(self):
        for tab in list(self.manifest["made"]["tabs"]):
            self.cli("teardown.tab.close", "tab", tab, "close")
        super().teardown()


# ---- pages for L2 and L3 -------------------------------------------------------------------------

def page_video_html(seed):
    """A <video> playing a 60 fps canvas stream (no media file, no network): video compositing load."""
    return """<!doctype html><html><head><meta charset="utf-8"><title>tk-load video %(seed)d</title>
<style>html,body{margin:0;height:100%%;background:#000;overflow:hidden}video{width:100%%;height:100%%;object-fit:cover}
canvas{display:none}</style></head><body><canvas id="c" width="1280" height="720"></canvas><video id="v" autoplay muted playsinline></video>
<script>
const c = document.getElementById('c'), g = c.getContext('2d'), v = document.getElementById('v');
let f = 0;
function draw() {
  f++;
  for (let i = 0; i < 24; i++) { g.fillStyle = 'hsl(' + ((f * 3 + i * 15 + %(seed)d) %% 360) + ',80%%,50%%)';
    g.fillRect((i %% 6) * 214, Math.floor(i / 6) * 180, 214, 180); }
  g.fillStyle = '#fff'; g.font = '96px Menlo'; g.fillText('V ' + f, 40, 400);
  requestAnimationFrame(draw);
}
draw(); v.srcObject = c.captureStream(60); v.play();
</script></body></html>""" % {"seed": seed}


def page_spa_html(seed):
    """A heavy single-page app: 3000 rows re-rendered with new data at each #bump click and every 500 ms."""
    return """<!doctype html><html><head><meta charset="utf-8"><title>tk-load spa %(seed)d</title>
<style>body{margin:0;font:12px Menlo,monospace;background:#fafafa}#bar{position:sticky;top:0;background:#222;color:#fff;padding:6px}
.r{display:grid;grid-template-columns:80px 1fr 120px 60px;border-bottom:1px solid #ddd;padding:2px 6px}
.r:nth-child(odd){background:#f0f4ff}.hot{color:#c00;font-weight:700}</style></head><body>
<div id="bar"><button id="bump">bump</button> <span id="n">0</span> renders</div><div id="list"></div>
<script>
let seed = %(seed)d, renders = 0;
function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; }
function render() {
  renders++;
  const rows = [];
  for (let i = 0; i < 3000; i++) {
    const v = Math.floor(rnd() * 1000);
    rows.push('<div class="r"><span>#' + i + '</span><span>' + (v.toString(36) + 'x').repeat(1 + (v %% 7)) +
      '</span><span class="' + (v > 900 ? 'hot' : '') + '">' + v + '</span><span>' + renders + '</span></div>');
  }
  document.getElementById('list').innerHTML = rows.join('');
  document.getElementById('n').textContent = renders;
}
document.getElementById('bump').addEventListener('click', render);
render(); setInterval(render, 500);
</script></body></html>""" % {"seed": seed}


def start_pages(profile):
    """Writes the anim, video and spa pages and serves them (tuikit serve); returns the base URL."""
    folder = os.path.join(profile.dir, "www")
    os.makedirs(folder, exist_ok=True)
    for i in range(4):
        tuikit.write_atomic(os.path.join(folder, "anim-%d.html" % i), tuikit.page_html(profile.a.seed * 10 + i))
    tuikit.write_atomic(os.path.join(folder, "video.html"), page_video_html(profile.a.seed))
    tuikit.write_atomic(os.path.join(folder, "spa.html"), page_spa_html(profile.a.seed))
    proc = profile.start_process([sys.executable, os.path.join(HERE, "tuikit.py"), "serve", "--seed", "0", "--dir",
                                  folder, "--port", "0", "--duration", str(profile.a.duration + 600)],
                                 "pages", stdout=subprocess.PIPE)
    line = proc.stdout.readline().decode()
    try:
        url = json.loads(line)["url"]
    except (ValueError, KeyError):
        raise heavy_profile.Refused("page server: no url (%r)" % line[:120])
    base = url.rsplit("/", 1)[0]
    profile.manifest["pages"] = base
    profile.save()
    return base


def page_url(base, kind, n=0):
    if kind == "anim":
        return "%s/anim-%d.html" % (base, n % 4)
    return "%s/%s.html" % (base, kind)


# ---- L3: browser ---------------------------------------------------------------------------------

class L3(Profile):
    name = "L3"
    VISIBLE = ("video", "spa", "anim", "anim")
    HIDDEN = 26

    def browser_tab(self, pane, url, what):
        v = self.app.cmux("tab", "create", "browser", "--pane", pane, "--url", url)
        rec = {"tab_id": v.get("tab_id"), "browser_id": v.get("browser_id"), "pane_id": pane, "url": url, "for": what}
        self.manifest["made"]["tabs"].append(rec["tab_id"])
        self.manifest.setdefault("browser_tabs", []).append(rec)
        self.save()
        return rec

    def setup(self):
        self.base = start_pages(self)
        self.visible = []
        panes = self.beside_keep(len(self.VISIBLE), None, "L3 visible browser")
        for pane, kind in zip(panes, self.VISIBLE):
            rec = self.browser_tab(pane["pane_id"], page_url(self.base, kind, len(self.visible)), "visible " + kind)
            self.visible.append(rec)
            if pane.get("tab_id"):
                self.cli("setup.placeholder.close", "tab", pane["tab_id"], "close")
        ws = self.workspace("tabs")
        self.hidden = [self.browser_tab(ws["pane_id"], page_url(self.base, "anim", i), "hidden")
                       for i in range(self.HIDDEN)]
        self.spa = self.visible[1]
        if self.a.devtools:
            self.open_devtools(self.spa)
        self.host = os.path.join(self.app.app_path or "", "Contents", "Resources", "bin", "cmux-browser-host")
        self.manifest["repl"] = self.host if os.path.exists(self.host) else None
        self.save()

    def open_devtools(self, tab):
        """DevTools needs the web view focused, and opening it focuses the DevTools view, so this happens in
        set-up, before LOAD-READY. Then the person's pane --keep is focused again, and the result is checked."""
        steps = {}
        steps["focus_spa"] = self.app.rpc("action.run", {"action": "tab.focus", "target": "tab:%s" % tab["tab_id"],
                                                         "focus": True})
        time.sleep(0.5)  # set-up: the web view takes the first responder
        steps["toggle"] = self.app.rpc("action.run", {"action": "toggleBrowserDeveloperTools",
                                                      "target": "tab:%s" % tab["tab_id"]})
        time.sleep(1.0)  # set-up: DevTools opens docked
        steps["refocus_keep"] = self.app.rpc("action.run", {"action": "pane.focus", "target": "pane:%s" % self.a.keep,
                                                            "focus": True})
        time.sleep(0.3)
        focus = (self.app.topology().get("focus") or {})
        steps["keep_focused"] = focus.get("pane") == self.a.keep
        self.manifest["devtools"] = steps
        if not steps["keep_focused"]:
            self.refused("devtools set-up", "the typing pane %s is not focused after DevTools: %s" % (self.a.keep, focus))
        self.save()

    def repl_click(self):
        start = time.monotonic()
        code = 'const p = await tabs.use("%s"); await p.click("#bump"); return 1' % self.spa["tab_id"]
        env = {"HOME": self.app.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_SOCKET_PATH": self.app.app_sock}
        try:
            done = subprocess.run([self.host, "eval", "--session", "tk-load-L3", "--timeout-ms", "5000", "-"],
                                  input=code, capture_output=True, text=True, timeout=15, env=env)
            ok = done.returncode == 0
            self.calls.record("repl.click", start, ok, 1, None if ok else (done.stderr or done.stdout)[:200])
        except (OSError, subprocess.TimeoutExpired) as error:
            self.calls.record("repl.click", start, False, 1, error)

    def load(self):
        tabs = self.visible + self.hidden
        rng = self.rng
        next_load = next_click = time.monotonic()
        while not self.stop.is_set():
            now = time.monotonic()
            if now >= next_load:
                next_load += 2.0
                tab = rng.choice([t for t in tabs if t is not self.spa and "video" not in t["for"]])
                self.cli("browser.navigate", "browser", tab["tab_id"], "navigate",
                         page_url(self.base, "anim", rng.randrange(4)) + "?n=%d" % rng.randrange(10 ** 6), worker=0)
            if self.manifest.get("repl") and now >= next_click:
                next_click += 1.0
                self.repl_click()
            self.stop.wait(max(0.0, min(next_load, next_click if self.manifest.get("repl") else next_load)
                               - time.monotonic()))

    def teardown(self):
        for tab in list(self.manifest["made"]["tabs"]):
            self.cli("teardown.tab.close", "tab", tab, "close")
        super().teardown()


# ---- L4: agents ----------------------------------------------------------------------------------

class L4(Profile):
    name = "L4"
    AGENTS = 6

    def setup(self):
        plan = {"out": self.dir, "python": sys.executable, "kit": os.path.join(HERE, "tuikit.py"),
                "duration": self.a.duration}
        rec = heavy_profile.Recorder(os.path.join(self.dir, "agents.json"), {"made": {}})
        if self.a.agents_where == "beside":
            panes = [p["pane_id"] for p in self.beside_keep(self.AGENTS, None, "L4 agent")]
        else:
            ws = self.workspace("agents")
            panes, last = [ws["pane_id"]], ws["pane_id"]
            for i in range(1, self.AGENTS):
                ratio = "%.4f" % (1.0 - 1.0 / (self.AGENTS - i + 1))
                v = self.app.cmux("pane", last, "split", "--down", "--ratio", ratio, "--", "/bin/sleep", "86400")
                last = v.get("pane_id")
                panes.append(last)
        self.manifest["agents"] = []
        for i, pane in enumerate(panes):
            seed = self.a.seed * 100 + i
            spec = {"prompt": "stream: %d %s %d" % (seed, self.a.duration, self.a.agent_cps),
                    "fallback_argv": tuikit.program_argv(sys.executable, plan["kit"], "agent-stream", seed,
                                                         self.a.duration, None, ["--cps", str(self.a.agent_cps)])}
            try:
                entry = heavy_profile.open_agent(self.app, plan, rec, pane, spec)
            except heavy_profile.Refused as error:
                self.refused("agent pane %d" % i, error)
                continue
            entry["steps"] = len(entry.get("steps") or [])
            self.manifest["agents"].append(dict(entry, seed=seed))
        self.manifest["harness_file"] = rec.data.get("harness_file")
        self.save()

    def teardown(self):
        super().teardown()
        harness = self.manifest.get("harness_file") or {}
        if harness.get("path") and not harness.get("existed") and os.path.exists(harness["path"]):
            os.remove(harness["path"])


# ---- L5: heavy, L6: all --------------------------------------------------------------------------

class L5(Profile):
    name = "L5"

    def setup(self):
        reach = ["--app-socket", self.app.app_sock, "--socket", self.app.daemon_sock, "--cli", self.app.cli,
                 "--home", self.app.home] + (["--app", self.app.app_path] if self.app.app_path else [])
        self.heavy_out = os.path.join(self.dir, "heavy")
        argv = [sys.executable, os.path.join(HERE, "heavy_profile.py"), "build", "--seed", str(self.a.seed),
                "--duration", str(self.a.duration + 60), "--out", self.heavy_out, "--no-focus"] + reach
        workspaces, tabs, visible = self.a.heavy_shape.split(",")
        argv += ["--workspaces", workspaces, "--tabs", tabs, "--visible", visible]
        done = subprocess.run(argv, capture_output=True, text=True, timeout=1800)
        self.manifest["heavy"] = {"argv": argv, "exit": done.returncode, "stdout": done.stdout.strip()[-600:],
                                  "manifest": os.path.join(self.heavy_out, "heavy.json"), "reach": reach}
        if done.returncode != 0:
            self.refused("heavy build", "exit %d: %s" % (done.returncode, (done.stdout + done.stderr).strip()[-300:]))
        self.save()

    def teardown(self):
        heavy = self.manifest.get("heavy") or {}
        if os.path.exists(heavy.get("manifest", "")):
            done = subprocess.run([sys.executable, os.path.join(HERE, "heavy_profile.py"), "teardown", "--manifest",
                                   heavy["manifest"]] + heavy.get("reach", []), capture_output=True, text=True,
                                  timeout=600)
            self.manifest["heavy"]["teardown"] = {"exit": done.returncode, "stdout": done.stdout.strip()[-400:]}
        super().teardown()


def run_l6(a):
    """L1..L5 at the same time, one child process each; LOAD-READY L6 once every child is ready."""
    folder = os.path.join(a.out, "L6")
    os.makedirs(folder, exist_ok=True)
    children = {}
    for name in PROFILES[:5]:
        argv = [sys.executable, os.path.abspath(__file__), "run", name, "--out", folder] + passthrough(a)
        children[name] = subprocess.Popen(argv, stdout=subprocess.PIPE, text=True)
    manifest = {"profile": "L6", "seed": a.seed, "duration": a.duration, "children": {}, "started_wall": time.time()}
    ready, done_lines, lock = {}, {}, threading.Lock()

    def follow(name, proc):
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            with lock:
                if line.startswith("LOAD-READY %s " % name):
                    ready[name] = line.strip()
                if line.startswith("LOAD-DONE %s " % name):
                    done_lines[name] = line.strip()

    threads = [threading.Thread(target=follow, args=item, daemon=True) for item in children.items()]
    for t in threads:
        t.start()

    def forward(signum, _frame):
        for proc in children.values():
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    announced = False
    while any(p.poll() is None for p in children.values()):
        with lock:
            if not announced and len(ready) == len(children):
                announced = True
                print("LOAD-READY L6 t_mono=%.6f t_wall=%.6f" % (time.monotonic(), time.time()), flush=True)
        time.sleep(0.1)
    for t in threads:
        t.join(5)
    codes = {name: p.returncode for name, p in children.items()}
    for name in children:
        manifest["children"][name] = {"exit": codes[name], "dir": os.path.join(folder, name), "ready": ready.get(name),
                                      "done": done_lines.get(name)}
    manifest["ended_wall"] = time.time()
    manifest["all_ready"] = announced
    tuikit.write_atomic(os.path.join(folder, "manifest.json"), json.dumps(manifest, indent=2) + "\n")
    print("LOAD-DONE L6 exits=%s" % json.dumps(codes, sort_keys=True), flush=True)
    return max(codes.values()) if codes else 2


def passthrough(a):
    out = ["--app-socket", a.app_socket, "--seed", str(a.seed), "--duration", str(a.duration), "--rate", str(a.rate),
           "--agent-cps", str(a.agent_cps), "--agents-where", a.agents_where, "--heavy-shape", a.heavy_shape]
    for flag, value in (("--home", a.home), ("--keep", a.keep), ("--socket", a.socket), ("--cli", a.cli),
                        ("--app", a.app)):
        if value:
            out += [flag, value]
    if not a.devtools:
        out.append("--no-devtools")
    return out


CLASSES = {"L1": L1, "L2": L2, "L3": L3, "L4": L4, "L5": L5}


def reach_app(a):
    app = heavy_profile.App(argparse.Namespace(home=a.home, app_socket=a.app_socket, tag=None, app=a.app, cli=a.cli,
                                               socket=a.socket))
    bundle = str(app.identity.get("bundle_id") or "")
    if bundle in SHIPPED_BUNDLES:
        raise heavy_profile.Refused("refused: %s is the shipped cmux (%s), never a load target" % (a.app_socket, bundle))
    return app


def cmd_run(a):
    if not a.app_socket:
        print("load_profiles: --app-socket is required (no default: the person's cmux is never a target)",
              file=sys.stderr)
        return 2
    if not 1 <= a.rate <= 1000:
        print("load_profiles: --rate is 1..1000", file=sys.stderr)
        return 2
    a.out = os.path.abspath(a.out or os.path.join(os.environ.get("TMPDIR") or "/tmp", "tk-load-%d" % a.seed))
    if a.profile == "L6":
        return run_l6(a)
    try:
        app = reach_app(a)
    except (heavy_profile.Refused, OSError, ValueError) as error:
        print("LOAD-REFUSED %s %s" % (a.profile, error), flush=True)
        return 2
    profile = CLASSES[a.profile](a, app)
    stopping = []

    def on_signal(signum, _frame):
        stopping.append(signum)
        profile.stop.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    code = 0
    try:
        profile.setup()
        if stopping:
            raise Stop()
        profile.guard = FocusGuard(app, os.path.join(profile.dir, "focus.jsonl"), profile.stop)
        profile.guard.start()
        while profile.guard.baseline is None and profile.guard.is_alive():
            time.sleep(0.01)  # the baseline is read before the load starts
        ready = (time.monotonic(), time.time())
        profile.manifest["ready"] = {"t_mono": ready[0], "t_wall": ready[1]}
        profile.save()
        profile.calls.loading = True
        print("LOAD-READY %s t_mono=%.6f t_wall=%.6f" % (profile.name, ready[0], ready[1]), flush=True)
        timer = threading.Timer(a.duration, profile.stop.set) if a.duration else None
        if timer:
            timer.daemon = True
            timer.start()
        profile.load()
    except Stop:
        pass
    except (heavy_profile.Refused, OSError, ValueError) as error:
        profile.refused("run", error)
        code = 1
    finally:
        profile.stop.set()
        if profile.calls.loading:
            profile.calls.window = (profile.manifest["ready"]["t_mono"], time.monotonic())
        profile.calls.loading = False
        if profile.guard:
            profile.guard.join(5)
        try:
            profile.teardown()
        except (heavy_profile.Refused, OSError, ValueError) as error:
            profile.refused("teardown", error)
        summary = profile.calls.summary()
        profile.calls.close()
        changed = bool(profile.guard and profile.guard.changes)
        profile.manifest.update({"ended_wall": time.time(), "calls": summary, "focus_changed": changed,
                                 "focus_changes": profile.guard.changes if profile.guard else None,
                                 "stopped_by": stopping[0] if stopping else "duration"})
        profile.save()
        if changed or profile.manifest["refusals"]:
            code = code or 1
        print("LOAD-DONE %s calls=%d failed=%d achieved_per_s=%.2f focus_changed=%s refusals=%d" % (
            profile.name, summary["calls"], summary["failed"], summary["achieved_per_s"], changed,
            len(profile.manifest["refusals"])), flush=True)
    return code


def cmd_plan(a):
    plan = {"profile": a.profile, "seed": a.seed}
    if a.profile == "L1":
        rng = random.Random("L1-%d-0" % a.seed)
        plan["first_calls_worker0"] = [L1.pick(None, rng) for _ in range(20)]
        plan["workers"], plan["rate"] = L1.WORKERS, a.rate
    elif a.profile == "L3":
        plan["visible"], plan["hidden"] = list(L3.VISIBLE), L3.HIDDEN
    elif a.profile == "L4":
        plan["agents"] = L4.AGENTS
    elif a.profile == "L6":
        plan["children"] = list(PROFILES[:5])
    print(json.dumps(plan, indent=2))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="load_profiles.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run")
    p.add_argument("profile", choices=PROFILES)
    p.add_argument("--app-socket", help="the tagged build's app control socket (required)")
    p.add_argument("--home", help="HOME of that app (a capture slot has its own)")
    p.add_argument("--socket", help="the app daemon's socket (default: from debug.daemon)")
    p.add_argument("--cli", help="the cmux CLI (default: the app's bundled one)")
    p.add_argument("--app", help="the .app bundle (default: from system.identify's pid)")
    p.add_argument("--keep", help="the typing pane: never focused, typed into, closed or split away; L3 sits beside it")
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--duration", type=float, default=120.0, help="seconds of load after LOAD-READY (0: until SIGTERM)")
    p.add_argument("--out", help="folder (default $TMPDIR/tk-load-SEED)")
    p.add_argument("--rate", type=int, default=100, help="L1: CLI and socket calls a second in total")
    p.add_argument("--agent-cps", type=int, default=400, help="L4: characters a second each agent streams")
    p.add_argument("--agents-where", choices=("hidden", "beside"), default="hidden")
    p.add_argument("--no-devtools", dest="devtools", action="store_false", help="L3: no DevTools set-up")
    p.add_argument("--heavy-shape", default="40,200,12", help="L5: workspaces,tabs,visible TUI panes")
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser("plan")
    p.add_argument("profile", choices=PROFILES)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--rate", type=int, default=100)
    p.set_defaults(fn=cmd_plan)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
