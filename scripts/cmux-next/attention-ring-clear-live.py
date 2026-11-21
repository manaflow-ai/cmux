#!/usr/bin/env python3
"""Attention ring clear paths on a fleet build: every way the person goes into a ringing pane.

Downloads the build of `--job`, starts it (active, its own scratch cmux.json in the light theme, then the dark
theme), and runs each case in a fresh workspace split in two: A is the pane the split left unfocused, B the
focused one.

  click-unfocused-notify   A rings (a notification); a click in A           -> A clears
  click-unfocused-mark     A rings (Mark as Unread); a click in A           -> A clears
  right-click-unfocused    A rings; a right-click in A                       -> A clears
  drag-select-unfocused    A rings; a press and release in A                 -> A clears
  click-mouse-reporting    A rings while its program reports the mouse; click -> A clears
  keyboard-focus-notify    A rings; Focus toward A                            -> A clears (dismissal `focus`)
  keyboard-focus-mark      A rings (Mark as Unread); Focus toward A           -> A clears (it came into view)
  click-focused-mark       B (focused) marked unread; a click in B            -> B clears
  typing-focused-mark      B (focused) marked unread; a key typed into B      -> B clears
  arrive-focused-notify    B (focused) gets a notification                    -> B never rings
  tab-switch-notify        B's hidden tab notified; that tab selected         -> no ring once shown
  workspace-switch-sidebar B rings in a hidden workspace; its sidebar row clicked -> clears
  workspace-switch-key     the same, shown by Go to Workspace                 -> clears
  click-after-split        A rings; B splits; a click in A                    -> A clears
  click-during-arrival     a click in A the moment its ring arrives           -> A clears
  double-click-unfocused   A rings; a double click in A                       -> A clears
  two-rings-click-one      A and B ring; a click in each                      -> each clears, the other stays
  attention-click-unfocused   an agent's "needs you" mark on A; a click in A  -> its ring hides
  attention-typing-focused    the mark on B; a key typed into B                -> its ring hides
  attention-click-then-move   hidden by a click, then its tab moves to B       -> stays hidden
  attention-click-then-switch hidden, then away to another workspace and back -> stays hidden
  attention-click-then-rename hidden, then the tab renamed and its icon set    -> stays hidden
  attention-click-then-pane-move hidden, then its pane moves to another workspace -> stays hidden

Each case reads `debug.notifications` (the window's drawn attention marks, `layoutModel.attention`) until the
ring pane leaves it (3 s) and records CLEARED or STUCK, with window snapshots right after the action (the dismiss
flash may show) and 2.5 s later (`debug.window_snapshot`, `<theme>-<case>.png`, `<theme>-<case>-late.png`). `report.json` and `cases.md` hold the case table.

Remote terminals (SSH / Cloud machines) and a real window refocus (Cmd-Tab) need another machine or the person's
display; NotificationRingEdgeCaseTests and AppServicesKeyWindowSourceTests cover them.

Exit 1 on any STUCK case. Every process of this job's own app copy is ended on exit (tag_teardown.py, exact PIDs).
Run under nx-remote on cmux-lawrence-2:
  nx-remote --host cmux-lawrence-2 --class light --needs input --input-reason "..." --input-minutes 20 -- python3 scripts/cmux-next/attention-ring-clear-live.py --job <id> --tag <tag>
"""
import argparse, glob, json, os, plistlib, shutil, signal, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--job", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--themes", default="light,dark")
parser.add_argument("--cases", default="", help="comma-separated case names (default: all)")
opts = parser.parse_args()

OUT = os.path.realpath(os.environ.get("NX_ARTIFACTS") or "/tmp/ring-clear-live")
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "live.log"), "a")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


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

THEME_DIRS = [d for d in glob.glob(os.path.join(APP, "Contents/Resources/**/themes"), recursive=True) if os.path.isdir(d)]
SHIPPED = {name for d in THEME_DIRS for name in os.listdir(d)}


def pick_theme(candidates):
    return next((c for c in candidates if c in SHIPPED), candidates[0])


THEMES = {
    "light": pick_theme(["GitHub Light Default", "Rose Pine Dawn", "Catppuccin Latte", "Builtin Solarized Light"]),
    "dark": pick_theme(["GitHub Dark Default", "Rose Pine", "Catppuccin Mocha", "Builtin Dark"]),
}


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


def wait(predicate, seconds, step=0.2):
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


def topology():
    snap = rpc("snapshot.get") or {}
    return (snap.get("topology") or snap) if isinstance(snap, dict) else {}


def find_key(value, key):
    """The first string under `key` anywhere in `value`."""
    if isinstance(value, dict):
        if isinstance(value.get(key), str):
            return value[key]
        for v in value.values():
            found = find_key(v, key)
            if found:
                return found
    if isinstance(value, list):
        for v in value:
            found = find_key(v, key)
            if found:
                return found
    return None


def tab_of_terminal(term):
    """The tab dict that shows terminal `term`."""
    if not term:
        return None
    for tab in rows(cli_json("tab", "list")):
        if isinstance(tab, dict) and term in json.dumps(tab):
            return tab
    for ws in topology().get("workspaces", []):
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    if term in json.dumps(tab):
                        return tab
    return None


def notifications():
    value = rpc("debug.notifications")
    return value if isinstance(value, dict) and "error" not in value else {}


def rings():
    """The panes the focused window draws an attention ring on."""
    return {pane for window in notifications().get("windows", []) for pane in window.get("attention", [])}


def app_focus():
    return rpc("debug.focus") or {}


def focused_pane():
    value = app_focus()
    return find_key(value.get("state") if isinstance(value.get("state"), dict) else value, "pane")


def snapshot(name):
    path = os.path.join(OUT, f"{name}.png")
    result = rpc("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
    if not os.path.exists(path):
        say("snapshot", name, json.dumps(result)[:300])
    return path if os.path.exists(path) else None


class Session:
    def __init__(self):
        self.dir = os.path.join(OUT, "run")
        os.makedirs(self.dir, exist_ok=True)
        self.config = os.path.join(self.dir, "cmux.json")
        self.app = None
        self.results = []
        self.count = 0

    def write_config(self, theme):
        tmp = self.config + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"appearance": {"theme": THEMES[theme]}, "notifications": {"desktop": "never"}}, f)
        os.replace(tmp, self.config)

    def launch(self):
        for tag_state in (os.path.expanduser(f"~/Library/Application Support/cmux-next/tags/{TAG}"),
                          os.path.expanduser(f"~/Library/Application Support/cmux/tags/{TAG}")):
            if os.path.isdir(tag_state) and not os.path.islink(tag_state):
                os.rename(tag_state, f"{tag_state}.old-{int(time.time())}")
        if os.path.exists(SOCKET):
            os.unlink(SOCKET)
        self.write_config("light")
        env = dict(os.environ)
        env.pop("CMUX_NEXT_NO_ACTIVATE", None)
        env.update({"CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": self.config,
                    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,820"})
        log = open(os.path.join(self.dir, "app.log"), "a")
        self.app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        say("started app pid", self.app.pid)
        if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180, 0.5):
            raise SystemExit("the app did not come up")
        if not rpc("debug.surfaces").get("windows"):
            rpc("action.run", {"action": "newWindow", "origin": "script", "focus": True})
        wait(lambda: rpc("debug.surfaces").get("windows"), 60, 0.5)
        # The person's app is active with a key window: the `focus` dismissal reads what they look at.
        subprocess.run(["open", APP], capture_output=True)
        wait(lambda: self.active(), 20, 0.5)
        say("app focus", json.dumps(app_focus())[:600])

    def active(self):
        return '"app_active": true' in json.dumps(app_focus())

    def new_workspace(self):
        """A new workspace, shown and focused: its terminal, name, id and pane."""
        self.count += 1
        name = f"ring-{self.count}"
        made = cli_json("workspace", "create", "--name", name, "--focus")
        term, ws, pane = find_key(made, "terminal_id"), find_key(made, "workspace_id"), find_key(made, "pane_id")
        if not term:
            raise SystemExit(f"workspace create: {json.dumps(made)[:300]}")
        self.show(ws, pane)
        time.sleep(0.8)  # the shell draws its first prompt (harness wait)
        return term, name, ws, pane

    def show(self, ws, pane=None, how="action"):
        """Shows workspace `ws` in the window (its focused pane is `pane` when given)."""
        shown = lambda: focused_pane() == pane if pane else ws in json.dumps(app_focus())
        if how == "row":
            rpc("debug.mouse", {"row": ws, "action": "click"})
        elif how == "cli":
            cli("workspace", ws, "focus")
        else:
            reply = rpc("action.run", {"action": "goToWorkspace", "target": f"workspace:{ws}", "origin": "script", "focus": True})
            if not wait(shown, 3):
                cli("workspace", ws, "focus")
                rpc("action.run", {"action": "selectWorkspace", "target": f"workspace:{ws}", "origin": "script", "focus": True})
                if not wait(shown, 5):
                    say("  show", ws, "not shown:", json.dumps(reply)[:200], "focus", focused_pane())
        return wait(shown, 5)

    def split(self, pane):
        """Splits `pane` right: the new terminal and its pane (focused)."""
        made = cli_json("pane", pane, "split", "--right", "--focus")
        term, new = find_key(made, "terminal_id"), find_key(made, "pane_id")
        if not term:
            say("  split", json.dumps(made)[:300])
        wait(lambda: focused_pane() == new, 10)
        time.sleep(0.8)  # first prompt (harness wait)
        return term, new

    def two_panes(self):
        started = time.time()
        term_a, name, ws, pane_a = self.new_workspace()
        term_b, pane_b = self.split(pane_a)
        say(f"  panes {name}: A={pane_a} {term_a} B={pane_b} {term_b} focus={focused_pane()} in {time.time() - started:.1f}s")
        focus = focused_pane()
        a, b = (term_a, pane_a), (term_b, pane_b)
        focused, other, toward = (b, a, "focusLeft") if focus == pane_b else (a, b, "focusRight")
        # "a" is the unfocused pane and "b" the focused one from here on, whichever side the split left focused.
        return {"name": name, "workspace": ws, "a": other, "b": focused, "toward": toward, "split_focus": focus}

    def ring_notify(self, term):
        started = time.time()
        r = cli("notify", "--title", "ring", "--body", "clear me", "--surface", term)
        say(f"  notify {term} rc={r.returncode} {time.time() - started:.1f}s", (r.stdout + r.stderr).strip()[:300])

    def ring_mark(self, term):
        tab = tab_of_terminal(term)
        r = cli("tab", (tab or {}).get("id", term), "update", "--marked-unread", "true")
        if r.returncode != 0:
            say("mark failed", (r.stdout + r.stderr).strip()[:300])

    def ring_attention(self, term):
        tab = (tab_of_terminal(term) or {}).get("id")
        r = cli("attention", "request", "--tab", tab or term, "--reason", "Approve the deploy")
        say(f"  attention {tab} rc={r.returncode}", (r.stdout + r.stderr).strip()[:200])

    def rung(self, pane):
        return wait(lambda: pane in rings(), 5)

    def record(self, case, theme, pane, expect_ring_before=True, note=""):
        cleared = wait(lambda: pane not in rings(), 3)
        state = "CLEARED" if cleared else "STUCK"
        shot = snapshot(f"{theme}-{case}")
        time.sleep(2.5)  # past the dismiss flash (at most 2 blinks of the 1 s flash loop)
        late = snapshot(f"{theme}-{case}-late")
        row = {"case": case, "theme": theme, "pane": pane, "result": state, "note": note, "shot": shot, "late": late,
               "active": self.active(), "unread": [u.get("pane") for u in notifications().get("unread", [])]}
        self.results.append(row)
        say(f"[{theme}] {'ok   ' if cleared else 'STUCK'} {case} pane={pane} {note}")
        if not cleared:
            log = notifications().get("log", [])[-25:]
            say("  log:", json.dumps(log)[:1500])

    # The cases. Each returns after recording.

    def click_unfocused(self, theme, case, ring, how):
        p = self.two_panes()
        self.toward = p["toward"]
        term_a, pane_a = p["a"]
        ring(term_a)
        if not self.rung(pane_a):
            return self.skip(case, theme, pane_a, "the ring never showed")
        how(pane_a, term_a)
        self.record(case, theme, pane_a)

    def skip(self, case, theme, pane, why):
        self.results.append({"case": case, "theme": theme, "pane": pane, "result": "NO RING", "note": why})
        say(f"[{theme}] skip  {case}: {why}")
        state = notifications()
        say("  rings", json.dumps(state.get("windows"))[:600], "unread", json.dumps(state.get("unread"))[:600],
            "prefs", json.dumps(state.get("preferences"))[:400], "log", json.dumps(state.get("log", [])[-12:])[:1200])
        say("  focus pane", focused_pane(), "terminals", json.dumps(list(terminals()))[:300])

    def run_case(self, case, theme):
        click = lambda pane, _t: rpc("debug.mouse", {"pane": pane, "action": "click"})
        if case == "click-unfocused-notify":
            return self.click_unfocused(theme, case, self.ring_notify, click)
        if case == "click-unfocused-mark":
            return self.click_unfocused(theme, case, self.ring_mark, click)
        if case == "right-click-unfocused":
            return self.click_unfocused(theme, case, self.ring_notify,
                                        lambda pane, _t: rpc("debug.mouse", {"pane": pane, "action": "click", "button": "right"}))
        if case == "drag-select-unfocused":
            def drag(pane, _t):
                rpc("debug.mouse", {"pane": pane, "action": "down"})
                rpc("debug.mouse", {"pane": pane, "action": "up"})
            return self.click_unfocused(theme, case, self.ring_notify, drag)
        if case == "click-mouse-reporting":
            def reporting(term):
                cli("terminal", term, "write", "--text", "printf '\\033[?1000h\\033[?1006h'; cat\n")
                time.sleep(0.5)
                self.ring_notify(term)
            return self.click_unfocused(theme, case, reporting, click)
        if case in ("keyboard-focus-notify", "keyboard-focus-mark"):
            ring = self.ring_notify if case.endswith("notify") else self.ring_mark
            return self.click_unfocused(theme, case, ring,
                                        lambda _p, _t: rpc("action.run", {"action": self.toward, "origin": "script", "focus": True}))
        if case in ("click-focused-mark", "typing-focused-mark"):
            p = self.two_panes()
            term_b, pane_b = p["b"]
            self.ring_mark(term_b)
            if not self.rung(pane_b):
                return self.skip(case, theme, pane_b, "the mark drew no ring")
            if case == "click-focused-mark":
                rpc("debug.mouse", {"pane": pane_b, "action": "click"})
            else:
                rpc("debug.key", {"key": "a"})
            return self.record(case, theme, pane_b)
        if case == "arrive-focused-notify":
            p = self.two_panes()
            term_b, pane_b = p["b"]
            self.ring_notify(term_b)
            rang = wait(lambda: pane_b in rings(), 2)
            return self.record(case, theme, pane_b, note="rang once" if rang else "never rang")
        if case == "tab-switch-notify":
            p = self.two_panes()
            term_b, pane_b = p["b"]
            tab_b = (tab_of_terminal(term_b) or {}).get("id")
            made = cli_json("tab", "create", "terminal", "--workspace", p["workspace"], "--pane", pane_b)
            hidden = find_key(made, "terminal_id")
            time.sleep(0.8)
            cli("tab", tab_b, "focus")  # the first tab shows again; the new one is hidden
            time.sleep(0.8)
            self.ring_notify(hidden)
            time.sleep(1.0)
            hidden_ring = pane_b in rings()
            rpc("action.run", {"action": "nextSurface", "origin": "script", "focus": True})
            return self.record(case, theme, pane_b, note=f"hidden tab rang: {hidden_ring}")
        if case in ("workspace-switch-sidebar", "workspace-switch-key"):
            p = self.two_panes()
            term_b, pane_b = p["b"]
            ws = p["workspace"]
            self.new_workspace()  # shows another workspace
            self.ring_notify(term_b)
            time.sleep(1.0)
            self.show(p["name"] if case.endswith("sidebar") else ws, pane_b, how="row" if case.endswith("sidebar") else "action")
            return self.record(case, theme, pane_b)
        if case in ("click-during-arrival", "double-click-unfocused"):
            p = self.two_panes()
            term_a, pane_a = p["a"]
            self.ring_notify(term_a)
            if case == "click-during-arrival":
                wait(lambda: pane_a in rings(), 5, 0.02)
                rpc("debug.mouse", {"pane": pane_a, "action": "click"})
            else:
                if not self.rung(pane_a):
                    return self.skip(case, theme, pane_a, "the ring never showed")
                rpc("debug.mouse", {"pane": pane_a, "action": "double_click"})
            return self.record(case, theme, pane_a)
        if case == "two-rings-click-one":
            p = self.two_panes()
            (term_a, pane_a), (term_b, pane_b) = p["a"], p["b"]
            self.ring_notify(term_a)
            self.ring_mark(term_b)
            if not self.rung(pane_a):
                return self.skip(case, theme, pane_a, "the ring never showed")
            rpc("debug.mouse", {"pane": pane_a, "action": "click"})
            self.record(case, theme, pane_a)
            rpc("debug.mouse", {"pane": pane_b, "action": "click"})
            return self.record(case + "-second", theme, pane_b)
        if case == "attention-click-unfocused":
            return self.click_unfocused(theme, case, self.ring_attention, click)
        if case == "attention-typing-focused":
            p = self.two_panes()
            term_b, pane_b = p["b"]
            self.ring_attention(term_b)
            if not self.rung(pane_b):
                return self.skip(case, theme, pane_b, "the mark drew no ring")
            rpc("debug.key", {"key": "a"})
            return self.record(case, theme, pane_b)
        if case in ("attention-click-then-move", "attention-click-then-switch", "attention-click-then-rename",
                    "attention-click-then-pane-move"):
            p = self.two_panes()
            term_a, pane_a = p["a"]
            term_b, pane_b = p["b"]
            self.ring_attention(term_a)
            if not self.rung(pane_a):
                return self.skip(case, theme, pane_a, "the mark drew no ring")
            rpc("debug.mouse", {"pane": pane_a, "action": "click"})
            if not wait(lambda: pane_a not in rings(), 3):
                return self.record(case, theme, pane_a, note="the click left it")
            time.sleep(2.5)
            tab_a = (tab_of_terminal(term_a) or {}).get("id")
            if case.endswith("then-move"):
                row = tab_of_terminal(term_a) or {}
                screen = find_key(row, "screen_id") or find_key(row, "screen")
                say("  tab row", json.dumps(row)[:400])
                r = cli("tab", tab_a, "move", "--workspace", p["workspace"], "--screen", screen or "current", "--pane", pane_b, "--index", "1")
                say("  move", r.returncode, (r.stdout + r.stderr).strip()[:200])
                watch = pane_b
            elif case.endswith("pane-move"):
                other = self.new_workspace()
                r = cli("pane", pane_a, "move", "--to-workspace", other[2], "--focus")
                say("  pane move", r.returncode, (r.stdout + r.stderr).strip()[:200])
                self.show(other[2], None)
                time.sleep(1.0)
                watch = pane_a
            elif case.endswith("switch"):
                other = self.new_workspace()
                self.show(p["workspace"], None)
                watch = pane_a
            else:
                cli("tab", tab_a, "rename", "renamed")
                cli("tab", tab_a, "update", "--icon", "star")
                watch = pane_a
            time.sleep(2.0)
            back = watch in rings()
            return self.results.append({"case": case, "theme": theme, "pane": watch, "result": "STUCK" if back else "CLEARED",
                                        "note": "the hidden ring came back" if back else "", "shot": snapshot(f"{theme}-{case}")}) or say(
                f"[{theme}] {'STUCK' if back else 'ok   '} {case} came back={back}")
        if case == "click-after-split":
            p = self.two_panes()
            term_a, pane_a = p["a"]
            self.ring_notify(term_a)
            if not self.rung(pane_a):
                return self.skip(case, theme, pane_a, "the ring never showed")
            self.split(p["b"][1])
            rpc("debug.mouse", {"pane": pane_a, "action": "click"})
            return self.record(case, theme, pane_a)
        raise SystemExit(f"unknown case {case}")

    def quit(self):
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


CASES = ["click-unfocused-notify", "click-unfocused-mark", "right-click-unfocused",
         "drag-select-unfocused", "click-mouse-reporting", "keyboard-focus-notify", "keyboard-focus-mark",
         "click-focused-mark", "typing-focused-mark", "arrive-focused-notify", "tab-switch-notify",
         "workspace-switch-sidebar", "workspace-switch-key", "click-after-split", "click-during-arrival",
         "double-click-unfocused", "two-rings-click-one", "attention-click-unfocused", "attention-typing-focused",
         "attention-click-then-move", "attention-click-then-switch", "attention-click-then-rename", "attention-click-then-pane-move"]
chosen = [c for c in opts.cases.split(",") if c] or CASES

TagTeardown(APP).install()
session = Session()
teardown = TagTeardown(APP, log=say)
failures = []
try:
    session.launch()
    for theme in opts.themes.split(","):
        if theme != "light":
            session.write_config(theme)
            time.sleep(2)  # the app reloads cmux.json live (harness wait)
        for case in chosen:
            try:
                session.run_case(case, theme)
            except SystemExit as error:
                session.results.append({"case": case, "theme": theme, "result": "ERROR", "note": str(error)})
                say(f"[{theme}] ERROR {case}: {error}")
finally:
    session.quit()
    teardown.end()
    with open(os.path.join(OUT, "report.json"), "w") as f:
        json.dump({"job": opts.job, "tag": TAG, "themes": THEMES, "results": session.results}, f, indent=1)
    lines = ["| Case | Theme | Result | Note |", "| --- | --- | --- | --- |"]
    lines += [f"| {r['case']} | {r['theme']} | {r['result']} | {r.get('note', '')} |" for r in session.results]
    with open(os.path.join(OUT, "cases.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    say("\n".join(lines))
failures = [r for r in session.results if r["result"] in ("STUCK", "ERROR")]
say("STUCK OR ERROR" if failures else "EVERY CASE CLEARED", [f"{r['theme']}/{r['case']}" for r in failures])
shutil.rmtree(app_dir, ignore_errors=True)
sys.exit(1 if failures else 0)
