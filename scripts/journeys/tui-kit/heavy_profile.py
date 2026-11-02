#!/usr/bin/env python3
"""HEAVY PROFILE: a seeded, heavy cmux-next session made through the bundled `cmux` CLI and the app's
control socket, with no hand steps, on a running tagged build; recorded to a manifest; torn down.

  heavy_profile.py build --tag TAG [--seed 7] [--out DIR]        make it (default: 40 workspaces, 200 tabs,
                                                                 one shown workspace with 12 TUI panes in
                                                                 mixed columns and rows, a browser pane and
                                                                 an agent pane in one more column)
  heavy_profile.py teardown --manifest DIR/heavy.json            close what build made, stop its page server
  heavy_profile.py plan [--seed 7]                                the plan only (no app): what goes where

The shown workspace's columns and rows are splits with ratios that make them even, so every pane
is on screen (not viewport columns: the first one keeps the viewport width). It runs tuikit.py's
load (gradient, sigwinch, mouse, flood, vim-scroll, top: the same
seeded choice as `tuikit.py scenario`); the browser pane loads tuikit's CSS-animation page from a local
page server; the agent pane is an agent chat on the `tuikit-stream` harness (agent_stream_acp.py, a
streaming stand-in agent), else, when the build cannot open it, tuikit's agent-stream in a terminal
(the manifest says which and why). The other workspaces hold shells, light tuikit programs and
browser tabs, so hidden work goes on while the shown one is filmed.

How it reaches the app: the app socket (--app-socket, else ~/.local/state/cmux/cmux-debug-<tag
slug>.sock, else /tmp/cmux-debug-<slug>.sock); `system.identify` gives the app's pid, so its bundle
and bundled CLI (Contents/Resources/bin/cmux); `debug.daemon` gives the daemon pid and its --socket.
--cli, --socket (the daemon's) and --home override each one (a capture slot has its own HOME).

DIR/heavy.json (written after every step, so a failed build can still be torn down): the plan, each
workspace, pane and tab id it made with the program it runs, every refusal, the page server's pid, and
a final check read from `snapshot.get` (workspaces, tabs and shown panes counted). Exit 0 when the
check matches the plan, 1 when it does not, 2 when the app could not be reached.
"""
import argparse
import json
import os
import random
import re
import shlex
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tuikit  # noqa: E402

HIDDEN_PROGRAMS = (
    ("top", ["--fps", "2"]),
    ("flood", ["--rate", "30"]),
    ("sigwinch", ["--tick", "1"]),
    ("gradient", ["--fps", "10", "--cell", "2"]),
    ("agent-stream", ["--cps", "40"]),
)


def split_rows(rng, panes, columns):
    rows = [1] * columns
    for _ in range(panes - columns):
        open_cols = [c for c in range(columns) if rows[c] < 4] or list(range(columns))
        rows[rng.choice(open_cols)] += 1
    return rows


def make_plan(a):
    """Everything build makes, from the seed alone (no app)."""
    if a.visible < 1 or a.workspaces < 2:
        sys.exit("plan: --visible is at least 1 and --workspaces at least 2")
    rng = random.Random(a.seed * 1009 + 17)
    kit = a.kit or os.path.join(HERE, "tuikit.py")
    out = os.path.abspath(a.out or os.path.join(os.environ.get("TMPDIR") or "/tmp", "tk-heavy-%d" % a.seed))
    programs = tuikit.pane_programs(a.visible, a.seed)
    columns = min(a.visible, max(1, rng.randrange(3, 6) if a.visible >= 6 else (a.visible + 1) // 2))
    rows = split_rows(rng, a.visible, columns)
    shown = {"name": "tk-%d-shown" % a.seed, "columns": [], "extra_column": []}
    index = 0
    for c in range(columns):
        col = []
        for r in range(rows[c]):
            program = programs[index]
            pseed = a.seed * 100 + index + 1
            argv = tuikit.program_argv(a.python, kit, program, pseed, a.duration,
                                       os.path.join(out, "shown-p%02d-%s.jsonl" % (index, program)))
            col.append({"pane": index, "column": c, "row": r, "kind": "terminal", "program": program, "seed": pseed,
                        "argv": argv})
            index += 1
        shown["columns"].append(col)
    for b in range(a.browsers):
        shown["extra_column"].append({"kind": "browser", "page_seed": a.seed + b})
    for g in range(a.agents):
        aseed = a.seed * 100 + 90 + g
        shown["extra_column"].append({
            "kind": "agent", "seed": aseed, "prompt": "stream: %d %s %d" % (aseed, a.duration, a.agent_cps),
            "fallback_argv": tuikit.program_argv(a.python, kit, "agent-stream", aseed, a.duration,
                                                 os.path.join(out, "shown-agent-%d.jsonl" % g),
                                                 ["--cps", str(a.agent_cps)])})
    shown_tabs = a.visible + len(shown["extra_column"])
    hidden_count = a.workspaces - 1
    budget = a.tabs - shown_tabs
    if budget < hidden_count:
        sys.exit("plan: --tabs %d leaves fewer tabs than the %d other workspaces need" % (a.tabs, hidden_count))
    per = [1] * hidden_count
    for _ in range(budget - hidden_count):
        per[rng.randrange(hidden_count)] += 1
    hidden = []
    for w in range(hidden_count):
        tabs = []
        for t in range(per[w]):
            roll = rng.random()
            tseed = a.seed * 10000 + w * 100 + t
            if roll < 0.10 and t > 0:
                tabs.append({"kind": "browser", "page_seed": a.seed + 1000 + w})
            elif roll < 0.45:
                program, extra = HIDDEN_PROGRAMS[rng.randrange(len(HIDDEN_PROGRAMS))]
                tabs.append({"kind": "terminal", "program": program, "seed": tseed,
                             "argv": tuikit.program_argv(a.python, kit, program, tseed, a.duration, None, extra)})
            else:
                tabs.append({"kind": "terminal", "program": "shell", "seed": tseed, "argv": None})
        if tabs[0]["kind"] != "terminal":
            tabs[0] = {"kind": "terminal", "program": "shell", "seed": a.seed * 10000 + w * 100, "argv": None}
        hidden.append({"name": "tk-%d-w%02d" % (a.seed, w + 1), "tabs": tabs})
    pages = sorted({tab["page_seed"] for ws in hidden for tab in ws["tabs"] if tab["kind"] == "browser"}
                   | {p["page_seed"] for p in shown["extra_column"] if p["kind"] == "browser"})
    return {"version": 1, "seed": a.seed, "no_focus": bool(getattr(a, "no_focus", False)), "duration": a.duration, "kit": kit, "python": a.python, "out": out,
            "counts": {"workspaces": a.workspaces, "tabs": a.tabs, "shown_tui_panes": a.visible,
                       "shown_panes": a.visible + len(shown["extra_column"]), "columns": columns,
                       "rows_per_column": rows},
            "pages": pages, "shown": shown, "hidden": hidden}


# ---- the app -------------------------------------------------------------------------------------

class Refused(Exception):
    pass


def tag_slug(tag):
    return re.sub(r"[^a-z0-9]+", "-", (tag or "").lower()).strip("-")


class App:
    def __init__(self, a):
        self.home = a.home or os.path.expanduser("~")
        self.app_sock = a.app_socket or self.find_app_socket(a.tag)
        if not self.app_sock:
            raise Refused("no app socket for tag %r (pass --app-socket)" % a.tag)
        ident = self.rpc("system.identify", timeout=20)
        if not isinstance(ident, dict) or not ident.get("pid"):
            raise Refused("system.identify on %s: %s" % (self.app_sock, json.dumps(ident)[:300]))
        self.identity = ident
        self.app_path = a.app or self.bundle_of(int(ident["pid"]))
        self.cli = a.cli or (os.path.join(self.app_path, "Contents", "Resources", "bin", "cmux") if self.app_path else None)
        if not self.cli or not os.path.exists(self.cli):
            raise Refused("no bundled cmux CLI (app %s); pass --cli" % self.app_path)
        self.daemon_sock = a.socket or self.find_daemon_socket()
        if not self.daemon_sock:
            raise Refused("no daemon socket (debug.daemon %s); pass --socket" % json.dumps(self.daemon_state)[:300])

    def find_app_socket(self, tag):
        if not tag:
            return None
        name = "cmux-debug-%s.sock" % tag_slug(tag)
        for path in (os.path.join(self.home, ".local", "state", "cmux", name), os.path.join("/tmp", name)):
            if os.path.exists(path):
                return path
        return None

    @staticmethod
    def bundle_of(pid):
        exe = subprocess.run(["ps", "-ww", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        m = re.match(r"(.*?\.app)/", exe)
        return m.group(1) if m else None

    def find_daemon_socket(self):
        try:
            self.daemon_state = self.rpc("debug.daemon", timeout=10) or {}
        except (OSError, ValueError) as error:
            self.daemon_state = {"error": str(error)}
        pid = self.daemon_state.get("pid") if isinstance(self.daemon_state, dict) else None
        lines = []
        if pid:
            lines = subprocess.run(["ps", "-ww", "-o", "args=", "-p", str(int(pid))], capture_output=True, text=True).stdout.splitlines()
        if self.app_path and not any("--socket" in line for line in lines):
            lines = [line for line in subprocess.run(["ps", "-ww", "-ax", "-o", "args="], capture_output=True, text=True).stdout.splitlines()
                     if line.startswith(self.app_path + "/") and "--headless" in line]
        for line in lines:
            m = re.search(r"--socket[ =](\S+)", line)
            if m:
                return m.group(1)
        return None

    def rpc(self, method, params=None, timeout=30):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        try:
            conn.connect(self.app_sock)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
        finally:
            conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}

    def cmux(self, *args, timeout=60):
        env = {"HOME": self.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
        argv = [self.cli, "--socket", self.daemon_sock, "--app-socket", self.app_sock, "--json"] + list(args)
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            raise Refused("cmux %s: no answer in %d s" % (" ".join(shlex.quote(x) for x in args[:6]), timeout))
        try:
            parsed = json.loads(done.stdout) if done.stdout.strip() else None
        except ValueError:
            parsed = None
        if done.returncode != 0:
            raise Refused("cmux %s: exit %d %s" % (" ".join(shlex.quote(x) for x in args[:6]), done.returncode,
                                                   (done.stdout + done.stderr).strip()[:300]))
        return parsed.get("value", parsed) if isinstance(parsed, dict) else (parsed or {})

    def topology(self):
        snap = self.rpc("snapshot.get", timeout=30) or {}
        return (snap.get("topology") or snap) if isinstance(snap, dict) else {}


# ---- build ---------------------------------------------------------------------------------------

class Recorder:
    def __init__(self, path, data):
        self.path = path
        self.data = data

    def save(self):
        tuikit.write_atomic(self.path, json.dumps(self.data, indent=2, ensure_ascii=False) + "\n")

    def refused(self, what, error):
        self.data.setdefault("refusals", []).append({"what": what, "error": str(error)[:400]})
        self.save()


def run_args(argv):
    return ["--"] + list(argv) if argv else []


def start_page_server(plan, rec):
    """One tuikit page server for every page the plan shows; its pid goes in the manifest."""
    for seed in plan["pages"]:
        tuikit.write_atomic(os.path.join(plan["out"], "anim-%d.html" % seed), tuikit.page_html(seed))
    with open(os.path.join(plan["out"], "page-server.out"), "w") as log:
        proc = subprocess.Popen([plan["python"], plan["kit"], "serve", "--seed", str(plan["seed"]), "--dir", plan["out"],
                                 "--port", "0", "--duration", str(plan["duration"] + 600)],
                                stdout=subprocess.PIPE, stderr=log, text=True, start_new_session=True)
    line = proc.stdout.readline()
    try:
        url = json.loads(line)["url"]
    except (ValueError, KeyError):
        rec.refused("page server", "no url: %r" % line[:200])
        return None
    base = url.rsplit("/", 1)[0]
    rec.data["page_server"] = {"pid": proc.pid, "base": base}
    rec.save()
    return base


def page_url(base, plan, seed):
    if base:
        return "%s/anim-%d.html" % (base, seed)
    return "file://" + os.path.join(plan["out"], "anim-%d.html" % seed)


def make_hidden(app, plan, rec, base):
    made = rec.data.setdefault("made", {}).setdefault("hidden", [])
    for ws in plan["hidden"]:
        first = ws["tabs"][0]
        try:
            value = app.cmux("workspace", "create", "--name", ws["name"], *run_args(first["argv"]))
        except Refused as error:
            rec.refused("workspace %s" % ws["name"], error)
            continue
        entry = {"name": ws["name"], "workspace_id": value.get("workspace_id"), "pane_id": value.get("pane_id"),
                 "tabs": [{"tab_id": value.get("tab_id"), "terminal_id": value.get("terminal_id"),
                           "program": first["program"]}]}
        made.append(entry)
        for tab in ws["tabs"][1:]:
            try:
                if tab["kind"] == "browser":
                    v = app.cmux("tab", "create", "browser", "--workspace", entry["workspace_id"], "--pane",
                                 entry["pane_id"], "--url", page_url(base, plan, tab["page_seed"]))
                    entry["tabs"].append({"tab_id": v.get("tab_id"), "browser_id": v.get("browser_id"), "program": "page"})
                else:
                    v = app.cmux("tab", "create", "terminal", "--workspace", entry["workspace_id"], "--pane",
                                 entry["pane_id"], *run_args(tab["argv"]))
                    entry["tabs"].append({"tab_id": v.get("tab_id"), "terminal_id": v.get("terminal_id"),
                                          "program": tab["program"]})
            except Refused as error:
                rec.refused("tab in %s" % ws["name"], error)
        rec.save()


def write_harness(app, plan, rec):
    """The tuikit-stream ACP harness in the build's own acpmux home (never ~/.config/cmux/harnesses)."""
    home = None
    names = os.path.join(HERE, "..", "..", "cmux-next", "build_names.py")
    if app.app_path and os.path.exists(names):
        import importlib.util
        spec = importlib.util.spec_from_file_location("build_names", names)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        home = module.of_app(app.app_path, app.home).get("acpmux_home")
    if not home:
        return None
    folder = os.path.join(home, "harnesses")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "tuikit-stream.toml")
    existed = os.path.exists(path)
    if existed:
        with open(path) as f:
            before = f.read()
    acp = os.path.join(HERE, "agent_stream_acp.py")
    with open(path, "w") as f:
        f.write('id = "tuikit-stream"\nname = "tuikit stream"\ncommand = %s\nargs = [%s]\n'
                % (json.dumps(plan["python"]), json.dumps(acp)))
    os.chmod(path, 0o600)
    rec.data["harness_file"] = {"path": path, "existed": existed, "before": before if existed else None}
    rec.save()
    return path


def open_agent(app, plan, rec, pane, spec):
    """An agent chat in `pane` streaming on tuikit-stream; else the terminal stand-in. Returns the record."""
    steps = []
    try:
        if not write_harness(app, plan, rec):
            raise Refused("no acpmux home for this build")
        opened = app.rpc("action.run", {"action": "palette.newAgentChat", "target": "pane:%s" % pane,
                                        "args": {"harness": "tuikit-stream", "cwd": plan["out"]}}, timeout=60)
        steps.append({"palette.newAgentChat": opened})
        if isinstance(opened, dict) and opened.get("error"):
            raise Refused("palette.newAgentChat: %s" % json.dumps(opened)[:200])
        session = None
        deadline = time.monotonic() + 60
        sent = False
        while time.monotonic() < deadline and not session:
            if not sent:
                chat = app.rpc("debug.agent_pane", {"action": "new_chat", "pane": pane, "harness": "tuikit-stream",
                                                    "cwd": plan["out"]}, timeout=60)
                reply = app.rpc("debug.agent_pane", {"action": "send_prompt", "pane": pane, "text": spec["prompt"]},
                                timeout=60)
                steps.append({"new_chat": chat, "send_prompt": reply})
                sent = isinstance(reply, dict) and not reply.get("error")
            state = app.rpc("debug.agent_pane", {"action": "chat_state", "pane": pane}, timeout=30)
            session = state.get("sessionId") if isinstance(state, dict) else None
            if not session and sent:
                # A new folder asks for trust first; Trust sends the prompt the composer kept.
                steps.append({"trust": app.rpc("debug.agent_pane", {"action": "click", "pane": pane,
                                                                    "selector": ".acpmux-trust-ask-action"}, timeout=30)})
            if not session:
                time.sleep(2)  # the chat starts in acpmux; poll its state
        if not session:
            raise Refused("no agent session in 60 s")
        return {"mode": "acp", "pane_id": pane, "session": session, "steps": steps}
    except (Refused, OSError, ValueError) as error:
        v = app.cmux("tab", "create", "terminal", "--pane", pane, *run_args(spec["fallback_argv"]))
        return {"mode": "terminal", "why": str(error)[:300], "pane_id": pane, "tab_id": v.get("tab_id"),
                "terminal_id": v.get("terminal_id"), "steps": steps}


def tabs_of(topology, pane_id):
    for ws in topology.get("workspaces", []):
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                if pane.get("id") == pane_id:
                    return [t.get("id") for t in pane.get("tabs", [])]
    return []


def new_column(app, pane, remaining, argv):
    """The next column: `pane` holds the `remaining` columns not made yet; split --right gives the new
    pane (right) (remaining - 1) / remaining of it, so every column ends 1/N of the window wide.
    (Not --viewport-width: the first column keeps viewport width 1.0, so the other columns would sit
    off screen.)"""
    ratio = "%.4f" % (1.0 - 1.0 / remaining)
    return app.cmux("pane", pane, "split", "--right", "--ratio", ratio, *run_args(argv))


def make_shown(app, plan, rec, base):
    shown = plan["shown"]
    made = {"name": shown["name"], "panes": []}
    rec.data.setdefault("made", {})["shown"] = made
    first = shown["columns"][0][0]
    value = app.cmux("workspace", "create", "--name", shown["name"], *run_args(first["argv"]))
    made["workspace_id"] = value.get("workspace_id")
    made["panes"].append(dict(first, pane_id=value.get("pane_id"), tab_id=value.get("tab_id"),
                              terminal_id=value.get("terminal_id")))
    rec.save()
    columns = len(shown["columns"]) + (1 if shown["extra_column"] else 0)
    tops = [value.get("pane_id")]
    for col in shown["columns"][1:]:
        cell = col[0]
        v = new_column(app, tops[-1], columns - cell["column"] + 1, cell["argv"])
        tops.append(v.get("pane_id"))
        made["panes"].append(dict(cell, pane_id=v.get("pane_id"), tab_id=v.get("tab_id"), terminal_id=v.get("terminal_id")))
        rec.save()
    for c, col in enumerate(shown["columns"]):
        last = tops[c]
        for r, cell in enumerate(col[1:], start=1):
            ratio = "%.4f" % (1.0 - 1.0 / (len(col) - r + 1))  # the rows of a column end about even
            try:
                v = app.cmux("pane", last, "split", "--down", "--ratio", ratio, *run_args(cell["argv"]))
            except Refused as error:
                rec.refused("row %d of column %d" % (r, c), error)
                continue
            last = v.get("pane_id")
            made["panes"].append(dict(cell, pane_id=last, tab_id=v.get("tab_id"), terminal_id=v.get("terminal_id")))
            rec.save()
    last = None
    extras = shown["extra_column"]
    for i, spec in enumerate(extras):
        # A placeholder terminal makes the pane; the browser tab or agent chat then takes it, and the
        # placeholder tab is closed so each pane shows exactly one tab.
        try:
            if last is None:
                v = new_column(app, tops[-1], 2, ["/bin/sleep", "86400"])
            else:
                ratio = "%.4f" % (1.0 - 1.0 / (len(extras) - i + 1))
                v = app.cmux("pane", last, "split", "--down", "--ratio", ratio, "--", "/bin/sleep", "86400")
        except Refused as error:
            rec.refused("extra pane %d" % i, error)
            continue
        last = v.get("pane_id")
        placeholder = v.get("tab_id")
        if spec["kind"] == "browser":
            try:
                b = app.cmux("tab", "create", "browser", "--pane", last, "--url", page_url(base, plan, spec["page_seed"]))
                entry = {"kind": "browser", "pane_id": last, "tab_id": b.get("tab_id"), "browser_id": b.get("browser_id"),
                         "url": page_url(base, plan, spec["page_seed"])}
            except Refused as error:
                rec.refused("browser pane", error)
                continue
        else:
            entry = dict(open_agent(app, plan, rec, last, spec), kind="agent", seed=spec["seed"], prompt=spec["prompt"])
        tabs = tabs_of(app.topology(), last)
        if placeholder in tabs and len(tabs) > 1:
            try:
                app.cmux("tab", placeholder, "close")
            except Refused as error:
                rec.refused("placeholder tab %s" % placeholder, error)
        made["panes"].append(entry)
        rec.save()
    if plan.get("no_focus"):
        return  # a background load (load_profiles.py L5): the person's focus stays where it is
    try:
        app.cmux("workspace", made["workspace_id"], "focus")
    except Refused as error:
        rec.refused("focus shown workspace", error)


def check(app, plan, rec):
    topo = app.topology()
    prefix = "tk-%d-" % plan["seed"]
    ours = [ws for ws in topo.get("workspaces", []) if str(ws.get("name", "")).startswith(prefix)]
    tabs = sum(len(p.get("tabs", [])) for ws in ours for s in ws.get("screens", []) for p in s.get("panes", []))
    shown_id = rec.data.get("made", {}).get("shown", {}).get("workspace_id")
    shown_panes = sum(len(s.get("panes", [])) for ws in ours if ws.get("id") == shown_id for s in ws.get("screens", []))
    found = {"workspaces": len(ours), "tabs": tabs, "shown_panes": shown_panes,
             "focused_workspace": (topo.get("focus") or {}).get("workspace")}
    want = {"workspaces": plan["counts"]["workspaces"], "tabs": plan["counts"]["tabs"],
            "shown_panes": plan["counts"]["shown_panes"],
            "focused_workspace": found["focused_workspace"] if plan.get("no_focus") else shown_id}
    rec.data["check"] = {"found": found, "want": want, "ok": found == want}
    rec.save()
    return found == want


def cmd_build(a):
    plan = make_plan(a)
    os.makedirs(plan["out"], exist_ok=True)
    path = os.path.join(plan["out"], "heavy.json")
    rec = Recorder(path, {"plan": plan, "started": time.time(), "made": {}})
    try:
        app = App(a)
    except (Refused, OSError, ValueError) as error:
        rec.refused("app", error)
        print(json.dumps({"manifest": path, "error": str(error)}))
        return 2
    rec.data["app"] = {"socket": app.app_sock, "daemon_socket": app.daemon_sock, "cli": app.cli,
                       "app_path": app.app_path, "identity": app.identity}
    rec.save()
    base = start_page_server(plan, rec) if plan["pages"] else None
    started = time.monotonic()
    make_hidden(app, plan, rec, base)
    try:
        make_shown(app, plan, rec, base)
    except Refused as error:
        rec.refused("shown workspace", error)
    rec.data["build_seconds"] = round(time.monotonic() - started, 2)
    ok = check(app, plan, rec)
    print(json.dumps({"manifest": path, "ok": ok, "check": rec.data["check"],
                      "refusals": len(rec.data.get("refusals", []))}))
    return 0 if ok else 1


def stop_page_server(pid, out):
    """SIGTERM to the page server build started (its own session), only while that pid still runs
    `tuikit.py serve --dir OUT`: a reused pid is never signalled."""
    args = subprocess.run(["ps", "-ww", "-o", "args=", "-p", str(pid)], capture_output=True, text=True).stdout
    if "tuikit.py serve" not in args or ("--dir %s " % out) not in args + " ":
        return "not running (pid %d now runs %r)" % (pid, args.strip()[:120])
    try:
        os.killpg(pid, signal.SIGTERM)
        return "stopped"
    except OSError as error:
        return str(error)


def cmd_teardown(a):
    with open(a.manifest) as f:
        data = json.load(f)
    rec = Recorder(a.manifest, data)
    report = {"closed": [], "refused": []}
    try:
        app = App(argparse.Namespace(home=a.home, app_socket=a.app_socket or data.get("app", {}).get("socket"),
                                     tag=a.tag, app=a.app or data.get("app", {}).get("app_path"),
                                     cli=a.cli or data.get("app", {}).get("cli"),
                                     socket=a.socket or data.get("app", {}).get("daemon_socket")))
    except (Refused, OSError, ValueError) as error:
        app = None
        report["refused"].append({"what": "app", "error": str(error)[:300]})
    made = data.get("made", {})
    ids = [ws.get("workspace_id") for ws in made.get("hidden", [])]
    if made.get("shown", {}).get("workspace_id"):
        ids.append(made["shown"]["workspace_id"])
    for ws in filter(None, ids if app else []):
        try:
            app.cmux("workspace", ws, "close")
            report["closed"].append(ws)
        except Refused as error:
            try:
                reply = app.rpc("action.run", {"action": "closeWorkspace", "target": "workspace:%s" % ws,
                                               "args": {"confirm": True}})
            except (OSError, ValueError) as rpc_error:
                reply = {"error": str(rpc_error)}
            if isinstance(reply, dict) and reply.get("error"):
                report["refused"].append({"what": ws, "error": str(error)[:200], "rpc": json.dumps(reply)[:200]})
            else:
                report["closed"].append(ws)
    server = data.get("page_server") or {}
    if server.get("pid") and not server.get("stopped"):
        report["page_server"] = stop_page_server(server["pid"], data["plan"]["out"])
        server["stopped"] = True
    harness = data.get("harness_file") or {}
    if harness.get("path") and not harness.get("restored"):
        if harness.get("existed"):
            tuikit.write_atomic(harness["path"], harness.get("before") or "")
            report["harness_file"] = "put back"
        elif os.path.exists(harness["path"]):
            os.remove(harness["path"])
            report["harness_file"] = "removed"
        harness["restored"] = True
    data["teardown"] = report
    rec.save()
    print(json.dumps(report))
    return 0 if not report["refused"] else 1


def cmd_plan(a):
    print(json.dumps(make_plan(a), indent=2, ensure_ascii=False))
    return 0


def shape(p):
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--workspaces", type=int, default=40)
    p.add_argument("--tabs", type=int, default=200)
    p.add_argument("--visible", type=int, default=12, help="TUI panes in the shown workspace")
    p.add_argument("--browsers", type=int, default=1, help="browser panes beside them")
    p.add_argument("--agents", type=int, default=1, help="agent chat panes beside them")
    p.add_argument("--agent-cps", type=int, default=400)
    p.add_argument("--duration", type=float, default=1800.0, help="seconds each program runs, then exits")
    p.add_argument("--kit", help="tuikit.py on the Mac that runs the app (default beside this file)")
    p.add_argument("--python", default="/usr/bin/python3")
    p.add_argument("--out", help="manifest, logs and pages (default $TMPDIR/tk-heavy-SEED)")
    p.add_argument("--no-focus", action="store_true",
                   help="do not focus the shown workspace at the end (a background load under typing)")


def reach(p):
    p.add_argument("--tag", help="the tagged build (finds its app socket)")
    p.add_argument("--app-socket", help="the app's control socket (a capture slot's)")
    p.add_argument("--socket", help="the app daemon's socket (default: from debug.daemon)")
    p.add_argument("--cli", help="the cmux CLI (default: the app's bundled one)")
    p.add_argument("--app", help="the .app bundle (default: from system.identify's pid)")
    p.add_argument("--home", help="HOME of the app (a capture slot has its own)")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="heavy_profile.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("build")
    shape(p)
    reach(p)
    p.set_defaults(fn=cmd_build)
    p = sub.add_parser("teardown")
    p.add_argument("--manifest", required=True)
    reach(p)
    p.set_defaults(fn=cmd_teardown)
    p = sub.add_parser("plan")
    shape(p)
    p.set_defaults(fn=cmd_plan)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
