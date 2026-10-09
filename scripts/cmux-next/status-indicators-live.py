#!/usr/bin/env python3
"""Status indicators (cx-kxa2) on a fleet build, with window snapshots per icon set and theme.

Downloads the build of `--job`, then once per icon set (`--sets`, default `current,badges`,
preset through CMUX_NEXT_DEBUG_TUNABLES_FILE, the file the Debug menu > Status Icons writes):
starts the app (no-activate, automation socket, scratch cmux.json with a light theme, its own
ACPMUX_HOME and XDG_CONFIG_HOME with a fake ACP harness), and builds:

  one workspace per OSC 7501 state, named for it: working, blocked with kind permission /
  question / auth, blocked with no kind, error, done (sidebar rows);
  a workspace "tabs" with one terminal tab per state (the tab strip, focused last);
  three ACP chats on the fake agent (cmux-tui/crates/acpmux/tests/fake_agent.py): a running
  turn ("gate: <fifo>"), a pending permission ("ask: x"), and a turn that completes while no
  client is attached (the agent tab hibernated, then the gate released: acpmux `unread`).

Checks: each terminal's daemon records (`cmux terminal <id> status --json`); a banner per
blocked/error record with the daemon's title ("<title> needs approval|asks a question|needs
sign-in|needs input|failed") and a status badge attachment when the build reports one
(`debug.notifications` banners[].attachment, saved as PNGs); the acpmux session states.
Snapshots (`debug.window_snapshot`, no Screen Recording needed) in the light theme, then the
dark theme (cmux.json rewritten; the app reloads it live). Done notifications are not posted
by the daemon yet and are not checked.

Exit 1 on any failed check. Every process of this job's own app copy is ended on exit
(tag_teardown.py, exact PIDs only). Run under nx-remote on cmux-lawrence-2:
  nx-remote --class light -- python3 scripts/cmux-next/status-indicators-live.py --job <id> --tag <tag>
"""
import argparse, base64, glob, json, os, plistlib, re, shutil, signal, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--job", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--sets", default="current,badges")
parser.add_argument("--themes", default="light,dark")
parser.add_argument("--probe", action="store_true", help="one workspace and agent chat, dump the topology, quit")
opts = parser.parse_args()

OUT = os.path.realpath(os.environ.get("NX_ARTIFACTS") or "/tmp/kxa2-live")
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "live.log"), "a")
TREE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAKE_AGENT = os.path.join(TREE, "cmux-tui/crates/acpmux/tests/fake_agent.py")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown, pty_count  # noqa: E402


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


def b64(text):
    return base64.b64encode(text.encode()).decode()


# The fleet build.
zip_path = os.path.join(OUT, "app.zip")
if not os.path.exists(zip_path):
    subprocess.run([os.path.expanduser("~/.local/bin/cmux-ci"), "artifact", opts.job, zip_path], check=True,
                   env=dict(os.environ, CMUX_CI_CONTROLLER="http://100.89.225.106:18765"))
app_dir = os.path.join(OUT, "app")
if not os.path.isdir(app_dir):
    subprocess.run(["ditto", "-x", "-k", zip_path, app_dir], check=True)
APP = next(iter(glob.glob(os.path.join(app_dir, "*.app"))), None)
if not APP:
    sys.exit("no .app in the artifact")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
TAG = opts.tag
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
say("app", APP, "bundle", INFO.get("CFBundleIdentifier"))

# Theme names this build ships (Ghostty themes), first match wins.
THEME_DIRS = [d for d in glob.glob(os.path.join(APP, "Contents/Resources/**/themes"), recursive=True) if os.path.isdir(d)]
SHIPPED = {name for d in THEME_DIRS for name in os.listdir(d)}


def pick_theme(candidates):
    return next((c for c in candidates if c in SHIPPED), candidates[0])


THEMES = {
    "light": pick_theme(["Rose Pine Dawn", "GitHub Light Default", "Catppuccin Latte", "Builtin Solarized Light"]),
    "dark": pick_theme(["Rose Pine", "GitHub Dark Default", "Catppuccin Mocha", "Builtin Dark"]),
}
say("themes", THEMES, "theme dirs", THEME_DIRS[:2], "shipped", len(SHIPPED))

# One record per state: (workspace name, report body, expected record check, banner title or None).
STATES = [
    ("working", "state=working:app=indexer:title=" + b64("Indexer"), "; sleep 900",
     lambda r: r.get("state") == "working", None),
    ("permission", "state=blocked:kind=permission:app=terraform:title=" + b64("Terraform") + ":msg=" + b64("Apply the plan?"),
     "; sleep 900", lambda r: r.get("state") == "blocked" and r.get("kind") == "permission", "Terraform needs approval"),
    ("question", "state=blocked:kind=question:app=setup:title=" + b64("Setup") + ":msg=" + b64("Which region?"),
     "; sleep 900", lambda r: r.get("state") == "blocked" and r.get("kind") == "question", "Setup asks a question"),
    ("auth", "state=blocked:kind=auth:app=login:title=" + b64("Login") + ":msg=" + b64("Sign in to continue"),
     "; sleep 900", lambda r: r.get("state") == "blocked" and r.get("kind") == "auth", "Login needs sign-in"),
    ("blocked", "state=blocked:app=wizard:title=" + b64("Wizard"), "; sleep 900",
     lambda r: r.get("state") == "blocked" and not r.get("kind"), "Wizard needs input"),
    ("error", "state=error:app=build:title=" + b64("Build") + ":msg=" + b64("2 tests failed"), "",
     lambda r: r.get("state") == "error", "Build failed"),
    ("done", "state=done:app=tests:title=" + b64("Tests"), "", lambda r: r.get("state") == "done", None),
]


def rpc(method, params=None, timeout=60):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(SOCKET)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
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
        time.sleep(step)  # harness wait, not app code
    return None


def daemon_socket():
    roots = {os.environ.get("TMPDIR", "/tmp"), "/tmp"}
    darwin_tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    if darwin_tmp:
        roots.add(darwin_tmp)
    for root in roots:
        found = glob.glob(os.path.join(root, "cmux-tui-*", f"cmux-app-{TAG}.sock"))
        if found:
            return found[0]
    return None


def cli(*args, timeout=30):
    sock = daemon_socket()
    target = ["--socket", sock] if sock else ["--app-socket", SOCKET]
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
    try:
        return subprocess.run([CLI, *target, *args], capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired as error:
        return subprocess.CompletedProcess(error.cmd, 124, "", "timeout")


def cli_json(*args):
    r = cli("--json", *args)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def rows(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for k in ("items", "terminals", "result", "data"):
            if isinstance(value.get(k), list):
                return value[k]
    return []


def terminals():
    return {row["id"]: row for row in rows(cli_json("terminal", "list")) if isinstance(row, dict) and row.get("id")}


def status(terminal):
    value = cli_json("terminal", terminal, "status")
    return value if isinstance(value, list) else None


def topology():
    snap = rpc("snapshot.get") or {}
    return (snap.get("topology") or snap) if isinstance(snap, dict) else {}


def tabs_of(workspace_id=None):
    """(workspace id, pane id, tab dict) for every tab, optionally of one workspace."""
    found = []
    for ws in topology().get("workspaces", []):
        if workspace_id and ws.get("id") != workspace_id:
            continue
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    found.append((ws.get("id"), pane.get("id"), tab))
    return found


def focus():
    """The topology's focus: window, workspace, pane, tab ids."""
    return topology().get("focus") or {}


def focused_workspace():
    return focus().get("workspace")


def focused_pane():
    return focus().get("pane")


def focused_window_key():
    """The focused window's control id (`debug.window_snapshot` window)."""
    win = focus().get("window")
    return next((w.get("key") for w in topology().get("windows", []) if w.get("id") == win), None)


def workspace_named(name):
    """The daemon's workspace id for `name` (`cmux workspace list`)."""
    return next((ws.get("id") for ws in rows(cli_json("workspace", "list")) if isinstance(ws, dict) and ws.get("name") == name), None)


def agent_tabs(workspace_id):
    return [t for _, _, t in tabs_of(workspace_id) if t.get("agent_session")]


def write(terminal, text):
    return cli("terminal", terminal, "write", "--text", text)


def report(terminal, body, tail=""):
    write(terminal, f"printf '\\033]7501;{body}\\033\\\\'{tail}\n")


def snapshot(name):
    path = os.path.join(OUT, f"{name}.png")
    window = focused_window_key()
    params = {"window": window, "path": path} if window else {"kind": "main", "path": path}
    result = rpc("debug.window_snapshot", params, timeout=60)
    say("snapshot", name, json.dumps(result)[:300])
    return path if os.path.exists(path) else None


class Run:
    """One app launch for one icon set."""

    def __init__(self, icon_set):
        self.set = icon_set
        self.dir = os.path.join(OUT, f"run-{icon_set}")
        os.makedirs(self.dir, exist_ok=True)
        self.failures, self.notes, self.evidence = [], [], {"set": icon_set, "checks": {}}
        self.config = os.path.join(self.dir, "cmux.json")
        self.acp_home = os.path.join(self.dir, "acpmux-home")
        self.acp_socket = f"/tmp/kxa2-acp-{os.getpid()}-{icon_set}.sock"
        self.xdg = os.path.join(self.dir, "xdg")
        self.app = None
        self.terms = {}
        self.fifos = []

    def check(self, name, ok, detail):
        self.evidence["checks"][name] = {"ok": bool(ok), "detail": detail}
        say(f"[{self.set}] {'ok  ' if ok else 'FAIL'} {name}: {json.dumps(detail)[:600]}")
        if not ok:
            self.failures.append(f"{self.set}/{name}")
        return ok

    def write_config(self, theme):
        tmp = self.config + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"appearance": {"theme": THEMES[theme]}}, f)
        os.replace(tmp, self.config)

    def acp(self, method, params=None, timeout=10):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(timeout)
                conn.connect(self.acp_socket)
                conn.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}) + "\n").encode())
                buf = b""
                while b"\n" not in buf:
                    chunk = conn.recv(1 << 22)
                    if not chunk:
                        break
                    buf += chunk
            return json.loads(buf.split(b"\n")[0])
        except (OSError, ValueError) as error:
            return {"error": str(error)}

    def sessions(self):
        reply = self.acp("_acpmux/watch") or {}
        result = reply.get("result") or {}
        found = result.get("sessions") if isinstance(result, dict) else None
        if found is None:
            status_reply = (self.acp("_acpmux/status") or {}).get("result") or {}
            found = status_reply.get("sessions") or []
        return {s.get("sessionId"): s for s in found if isinstance(s, dict)}

    def launch(self):
        tag_state = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{TAG}")
        if os.path.isdir(tag_state) and not os.path.islink(tag_state):
            os.rename(tag_state, f"{tag_state}.old-{int(time.time())}")
        if os.path.exists(SOCKET):
            os.unlink(SOCKET)
        os.makedirs(self.acp_home, exist_ok=True)
        harnesses = os.path.join(self.xdg, "cmux", "harnesses")
        os.makedirs(harnesses, exist_ok=True)
        profile = os.path.join(harnesses, "fake.toml")
        with open(profile, "w") as f:
            f.write(f'id = "fake"\nname = "Fake"\ncommand = "/usr/bin/python3"\nargs = [{json.dumps(FAKE_AGENT)}]\n')
        os.chmod(profile, 0o600)
        tunables = os.path.join(self.dir, "debug-tunables.json")
        with open(tunables, "w") as f:
            json.dump({"version": 1, "values": {} if self.set == "current" else {"status.iconSet": self.set}}, f)
        self.write_config("light")
        env = dict(os.environ)
        env.update({"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
                    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": self.config,
                    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,820", "CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables,
                    "ACPMUX_HOME": self.acp_home, "ACPMUX_SOCKET": self.acp_socket, "XDG_CONFIG_HOME": self.xdg})
        log = open(os.path.join(self.dir, "app.log"), "a")
        self.app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        say(f"[{self.set}] started app pid {self.app.pid}")
        if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180, 0.5):
            raise SystemExit("the app did not come up")
        if not rpc("debug.surfaces").get("windows"):
            rpc("action.run", {"action": "newWindow", "origin": "script", "focus": True})
        wait(lambda: rpc("debug.surfaces").get("windows"), 60, 0.5)

    def new_workspace(self, name):
        before = set(terminals())
        rpc("action.run", {"action": "workspace new", "args": {"focus": True}, "origin": "script"})
        new = wait(lambda: sorted(set(terminals()) - before), 30)
        if not new:
            raise SystemExit(f"no terminal after workspace new ({name})")
        renamed = cli("workspace", "current", "rename", name)
        if not wait(lambda: workspace_named(name), 10):
            say(f"[{self.set}] rename to {name} not seen:", (renamed.stdout + renamed.stderr).strip()[:200])
        time.sleep(1.0)  # the shell draws its first prompt (harness wait)
        return new[0]

    def new_tab(self):
        before = set(terminals())
        # A terminal tab in the focused pane (`newSurface`; `newTab` makes a workspace).
        tab = focus().get("tab")
        made = rpc("action.run", {"action": "newSurface", "target": f"tab:{tab}", "origin": "script", "focus": True})
        if isinstance(made, dict) and made.get("error"):
            say(f"[{self.set}] newSurface beside {tab}:", json.dumps(made)[:300])
        new = wait(lambda: sorted(set(terminals()) - before), 30)
        if new:
            time.sleep(1.0)  # first prompt (harness wait)
        return new[0] if new else None

    def osc_workspaces(self):
        for name, body, tail, _, _ in STATES:
            term = self.new_workspace(name)
            self.terms[name] = term
            report(term, body, tail)
        # The tab strip: one workspace with a terminal tab per state.
        first = self.new_workspace("tabs")
        tab_terms = [first] + [self.new_tab() for _ in STATES[1:]]
        for term, (name, body, tail, _, _) in zip(tab_terms, STATES):
            if term:
                self.terms[f"tabs/{name}"] = term
                report(term, body, tail)
        self.evidence["terminals"] = self.terms

    def check_records(self):
        for key, term in self.terms.items():
            name = key.split("/")[-1]
            predicate = next(s[3] for s in STATES if s[0] == name)
            got = wait(lambda: (lambda recs: recs if recs and any(predicate(r) for r in recs) else None)(status(term)), 15)
            self.check(f"record {key}", got, status(term))

    def check_banners(self):
        expected = [s[4] for s in STATES if s[4]]

        def banners():
            value = rpc("debug.notifications")
            return value.get("banners", []) if isinstance(value, dict) else []
        wait(lambda: all(any(b.get("title") == t for b in banners()) for t in expected), 20)
        found = banners()
        notes = rpc("debug.notifications")
        with open(os.path.join(self.dir, "notifications.json"), "w") as f:
            json.dump(notes, f, indent=1)
        for title in expected:
            hits = [b for b in found if b.get("title") == title]
            self.check(f"banner {title}", hits, [{k: b.get(k) for k in ("title", "subtitle", "body")} for b in hits])
            for i, banner in enumerate(hits):
                attachment = banner.get("attachment")
                if "attachment" not in banner:
                    note = "this build's debug.notifications has no attachment field"
                    if note not in self.notes:
                        self.notes.append(note)
                    continue
                ok = isinstance(attachment, dict) and attachment.get("bytes", 0) > 0
                if ok:
                    path = os.path.join(OUT, f"badge-{self.set}-{title.split()[0].lower()}-{i}.png")
                    with open(path, "wb") as f:
                        f.write(base64.b64decode(attachment["png_base64"]))
                    ok = open(path, "rb").read(4) == b"\x89PNG"
                self.check(f"badge {title} #{i}", ok, {"bytes": (attachment or {}).get("bytes")})
        others = [b.get("title") for b in found if b.get("title") not in expected]
        self.evidence["other_banners"] = others
        done_banners = [t for t in others if t and "Tests" in t]
        if done_banners:
            self.notes.append(f"done banners seen: {done_banners}")

    def agent_chat(self, name, prompt):
        """A workspace with an agent tab on the fake harness and one prompt sent; returns (pane, session)."""
        term = self.new_workspace(name)
        ws = focused_workspace()
        pane_id = focused_pane()
        opened = rpc("action.run", {"action": "palette.newAgentChat", "target": f"pane:{pane_id}", "focus": True})
        say(f"[{self.set}] {name}: open agent chat in {pane_id} ws {ws}", json.dumps(opened)[:300])

        def agent_pane():
            for _, p, tab in tabs_of(ws):
                if tab.get("kind") == "conversation" and p:
                    st = rpc("debug.agent_pane", {"action": "chat_state", "pane": p}, timeout=40)
                    if isinstance(st, dict) and "error" not in st:
                        return p
            st = rpc("debug.agent_pane", {"action": "chat_state"}, timeout=40)
            return pane_id if isinstance(st, dict) and "error" not in st else None
        p = wait(agent_pane, 60, 1)
        # The page takes chat.new once it is ready; a chat on another harness never gets a prompt.
        def fake_chat():
            reply = rpc("debug.agent_pane", {"action": "new_chat", "pane": p, "harness": "fake"}, timeout=60)
            sid = reply.get("sessionId") if isinstance(reply, dict) else None
            return sid and self.sessions().get(sid, {}).get("harness") in ("fake", None) and reply
        new_chat = wait(fake_chat, 60, 2)
        say(f"[{self.set}] {name}: new_chat", json.dumps(new_chat)[:400],
            "harness", self.sessions().get((new_chat or {}).get("sessionId"), {}).get("harness"))
        if not new_chat:
            self.check(f"{name}: fake chat opened", False, "chat.new refused or not the fake harness")
            return p, ws, None
        time.sleep(2)  # the page shows the new chat (harness wait)
        rpc("debug.mouse", {"pane": p, "action": "click"})
        time.sleep(0.3)
        sent = rpc("debug.agent_pane", {"action": "send_prompt", "pane": p, "text": prompt}, timeout=60)
        say(f"[{self.set}] {name}: send_prompt", json.dumps(sent)[:400])

        def session():
            st = rpc("debug.agent_pane", {"action": "chat_state", "pane": p}, timeout=40)
            res = st.get("result") if isinstance(st, dict) else None
            if isinstance(res, str):
                try:
                    res = json.loads(res)
                except ValueError:
                    res = None
            res = res if isinstance(res, dict) else (st if isinstance(st, dict) else {})
            return res.get("sessionId")
        sid = wait(session, 30, 0.5)
        return p, ws, sid

    def acp_chats(self):
        if not os.path.exists(FAKE_AGENT):
            self.check("acp fake agent present", False, FAKE_AGENT)
            return
        fifo_run = os.path.join(self.dir, "gate-running")
        fifo_done = os.path.join(self.dir, "gate-done")
        for fifo in (fifo_run, fifo_done):
            if not os.path.exists(fifo):
                os.mkfifo(fifo)
        self.fifos = [fifo_run, fifo_done]
        chats = {}
        chats["acp working"] = self.agent_chat("acp working", f"gate: {fifo_run}")
        chats["acp waiting"] = self.agent_chat("acp waiting", "ask: may I run the tests?")
        chats["acp done"] = self.agent_chat("acp done", f"gate: {fifo_done}")
        self.evidence["acp"] = {k: {"pane": v[0], "workspace": v[1], "session": v[2]} for k, v in chats.items()}
        # Detach the "acp done" chat: hide its tab behind a terminal tab and hibernate it.
        _, ws_done, sid_done = chats["acp done"]
        before_tabs = agent_tabs(ws_done)
        with open(os.path.join(self.dir, "topology-acp-done.json"), "w") as f:
            json.dump(topology(), f, indent=1)
        # Select the workspace's terminal tab, so the agent tab is hidden in a shown pane and
        # can hibernate (a tab of a workspace no window shows cannot).
        terminal_tabs = [t for _, _, t in tabs_of(ws_done) if t.get("kind") == "terminal"]
        if terminal_tabs:
            picked = cli("tab", terminal_tabs[0]["id"], "focus")
            say(f"[{self.set}] select terminal tab {terminal_tabs[0]['id']}:", (picked.stdout + picked.stderr).strip()[:200])
            wait(lambda: focus().get("tab") == terminal_tabs[0]["id"], 10)
        say(f"[{self.set}] acp done tabs:", json.dumps(before_tabs)[:600])
        for tab in before_tabs:
            wait(lambda: not (lambda r: isinstance(r, dict) and r.get("error"))(
                rpc("action.run", {"action": "hibernateTab", "target": f"tab:{tab.get('id')}", "origin": "script"})), 10, 1)
            hib = rpc("action.run", {"action": "hibernateTab", "target": f"tab:{tab.get('id')}", "origin": "script"})
            say(f"[{self.set}] hibernate agent tab {tab.get('id')}:", json.dumps(hib)[:300])
        time.sleep(2)  # the page unloads (harness wait)
        before = self.sessions().get(sid_done, {})
        say(f"[{self.set}] acp done before release: attached?", json.dumps(before)[:600])
        def release():  # the gate's reader is the fake agent; never block on a FIFO without one
            try:
                fd = os.open(fifo_done, os.O_WRONLY | os.O_NONBLOCK)
            except OSError:
                return False
            os.write(fd, b"go\n")
            os.close(fd)
            return True
        self.check("acp done: gate released", wait(release, 15, 0.5), fifo_done)
        done = wait(lambda: (lambda s: s if s.get("unread") else None)(self.sessions().get(sid_done, {})), 20, 0.5)
        sessions = self.sessions()
        with open(os.path.join(self.dir, "acpmux-sessions.json"), "w") as f:
            json.dump(sessions, f, indent=1)
        work = sessions.get(chats["acp working"][2], {})
        ask = sessions.get(chats["acp waiting"][2], {})
        self.check("acp working: running", work.get("status") == "running",
                   {k: work.get(k) for k in ("status", "pendingPermissions", "unread")})
        self.check("acp waiting: permission pending",
                   (ask.get("pendingPermissions") or 0) > 0 or ask.get("status") == "waiting",
                   {k: ask.get(k) for k in ("status", "pendingPermissions", "unread")})
        detail = {k: (done or sessions.get(sid_done, {})).get(k) for k in ("status", "unread", "lastTurn")}
        if before.get("attached", 0) > 0:
            # No app path detached the chat (hibernate refuses the agent tab; a hidden workspace's
            # agent page stays attached), so acpmux cannot mark the turn unread: not shown, not failed.
            note = f"acp done UNVERIFIED: the agent tab stayed attached ({before.get('attached')} clients), so no unread turn"
            self.notes.append(note)
            say(f"[{self.set}] note {note}: {json.dumps(detail)[:300]}")
        else:
            self.check("acp done: completed while detached (unread)", bool(done), detail)

    def quit(self):
        for fifo in self.fifos:  # a gate still closed: release it so the turn ends
            try:
                fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
                os.write(fd, b"end\n")
                os.close(fd)
            except OSError:
                pass
        for term in self.terms.values():  # end the foreground sleeps (no terminal with a running job is left)
            cli("terminal", term, "keys", "ctrl+c")
        if self.app and self.app.poll() is None:
            rpc("action.run", {"action": "quitEndSessions", "origin": "script"}, timeout=10)
            try:
                self.app.wait(30)
            except subprocess.TimeoutExpired:
                self.app.send_signal(signal.SIGTERM)  # the PID this script started
                try:
                    self.app.wait(20)
                except subprocess.TimeoutExpired:
                    self.app.kill()
                    self.app.wait()

    def go(self):
        teardown = TagTeardown(APP, acpmux_home=self.acp_home, acpmux_socket=self.acp_socket, log=say)
        try:
            self.launch()
            if opts.probe:
                self.new_workspace("probe")
                self.agent_chat("probe chat", "hello")
                for name, value in (("topology", rpc("snapshot.get")), ("focus", rpc("debug.focus")),
                                    ("workspaces", cli_json("workspace", "list")), ("tabs", cli_json("tab", "list")),
                                    ("sessions", self.sessions())):
                    with open(os.path.join(self.dir, f"probe-{name}.json"), "w") as f:
                        json.dump(value, f, indent=1)
                return self.evidence
            self.osc_workspaces()
            self.acp_chats()
            # Show the "tabs" workspace: its tab strip has every state, the sidebar every row.
            tab_ws = workspace_named("tabs")
            went = cli("workspace", tab_ws or "tabs", "focus")
            if not wait(lambda: focused_workspace() == tab_ws, 10):
                went = rpc("action.run", {"action": "goToWorkspace", "target": f"workspace:{tab_ws}", "origin": "script"})
            self.check("tabs workspace shown", wait(lambda: focused_workspace() == tab_ws, 10),
                       {"workspace": tab_ws, "reply": str(went)[:200]})
            time.sleep(2)  # settle the redraw (harness wait)
            self.check_records()
            self.check_banners()
            rows_report = rpc("debug.sidebar_rows")
            with open(os.path.join(self.dir, "sidebar-rows.json"), "w") as f:
                json.dump(rows_report, f, indent=1)
            for theme in opts.themes.split(","):
                if theme != "light":
                    self.write_config(theme)
                    want_dark = theme == "dark"
                    applied = wait(lambda: (lambda t: t if t.get("terminals") and all(x.get("is_dark") == want_dark for x in t["terminals"]) else None)(rpc("debug.themes") or {}), 20, 0.5)
                    self.check(f"theme {theme} applied", applied, {"theme": THEMES[theme], "background": (applied or {}).get("ghostty_background")})
                    time.sleep(2)  # redraw after the theme change (harness wait)
                with open(os.path.join(self.dir, f"themes-{theme}.json"), "w") as f:
                    json.dump(rpc("debug.themes"), f, indent=1)
                self.evidence[f"snapshot {theme}"] = snapshot(f"status-{self.set}-{theme}")
        except SystemExit as error:
            self.failures.append(f"{self.set}: {error}")
            say(f"[{self.set}] FAIL stopped: {error}")
        finally:
            self.quit()
            teardown.end()
            self.evidence["failures"], self.evidence["notes"] = self.failures, self.notes
            with open(os.path.join(self.dir, "report.json"), "w") as f:
                json.dump(self.evidence, f, indent=1, default=str)
        return self.evidence


TagTeardown(APP).install()
PTYS_BEFORE = pty_count()
summary = {"job": opts.job, "tag": TAG, "themes": THEMES, "runs": []}
for icon_set in opts.sets.split(","):
    summary["runs"].append(Run(icon_set).go())
summary["ptys"] = {"before": PTYS_BEFORE, "after": pty_count()}
failures = [f for run in summary["runs"] for f in run["failures"]]
summary["failures"] = failures
with open(os.path.join(OUT, "summary.json"), "w") as f:
    json.dump(summary, f, indent=1, default=str)
say("PTYs before", PTYS_BEFORE, "after", summary["ptys"]["after"])
say("FAILURES" if failures else "ALL CHECKS PASSED", failures)
shutil.rmtree(app_dir, ignore_errors=True)
sys.exit(1 if failures else 0)
