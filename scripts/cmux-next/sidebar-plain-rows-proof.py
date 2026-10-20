#!/usr/bin/env python3
"""GUI proof of plain sidebar rows (cx-im75u, Lawrence 2026-10-14: "sidebar text should not be
bold by default"; "no icons in left sidebar of each workspace (besides website favicons) people
can bring their own icons though").

Launches the tagged app itself (no activation, a scratch cmux.json, an isolated Chief home; it
never opens Home or the Chief pane) on a GUI host and builds one sidebar:

  terminal     a plain terminal workspace
  agent        a terminal whose agent (claude) reports working
  web          a terminal tab, then a browser tab in front on a local page with a favicon
  mixed        the same, plus a second terminal tab: three tab rows; the first terminal posts
               a notification (OSC 9) while another tab is in front, so its tab row is unread
  custom icon  a workspace the user gave an icon (`workspace update --icon`)
  group        two workspaces in a group, collapsed while it holds the active workspace (the
               active member stays listed under the header with the selection fill)

Tab rows are listed (`sidebar.showWorkspaceTabs`). It captures the window with $NX_CAPTURE (the
real window server pixels) in Catppuccin Latte and Catppuccin Mocha, and writes
`debug.sidebar_rows` beside each shot. With --expect plain it checks what the rows draw: no
icon on a row except a favicon (browser rows) and the user's own icon. Run it on the base build too (no --expect) for the before shots.

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  sidebar-plain-rows-proof.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/LABEL" [--expect plain]
Stop the app afterwards with "$NX_APP_STOP".
"""
import argparse, http.server, json, os, socket, struct, subprocess, sys, tempfile, threading, time, zlib

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--expect", choices=["plain"], default=None)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"sbplain-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-debug-cli.sh")
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def png(size, rgb):
    """A solid square PNG (the test page's favicon), with no imaging library."""
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


ICON = png(32, (0xE6, 0x45, 0x53))


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/favicon"):
            body, kind = ICON, "image/png"
        else:
            body, kind = b'<!doctype html><title>Docs page</title><link rel="icon" href="/favicon.png"><h1>Docs page</h1>', "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
ORIGIN = f"http://127.0.0.1:{server.server_address[1]}"


def config(theme):
    with open(CONFIG, "w") as f:
        json.dump({"appearance": {"theme": theme}, "sidebar": {"showWorkspaceTabs": True}}, f)


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def cli(*args):
    env = dict(os.environ, CMUX_TAG=opts.tag)
    done = subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=60)
    print("cli", " ".join(args), "->", done.returncode, (done.stdout + done.stderr).strip()[-160:], flush=True)
    return done


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:  # bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def action(name, args=None, target=None, focus=True):
    params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
    if target:
        params["target"] = target
    reply = rpc("action.run", params)
    print("action", name, json.dumps(reply)[:160], flush=True)
    return reply


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def rows(kind=None):
    return [r for r in sidebar().get("rows") or [] if kind is None or str(r.get("key", "")).startswith(kind + "(")]


def workspace_ids():
    snap = rpc("snapshot.get") or {}
    topology = snap.get("topology") or snap
    return [w.get("id") for w in topology.get("workspaces") or []]


def focused_terminal():
    snap = rpc("snapshot.get") or {}
    topology = snap.get("topology") or snap
    tab_id = (topology.get("focus") or {}).get("tab")
    for ws in topology.get("workspaces") or []:
        for screen in ws.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("id") == tab_id:
                        return next((v for v in tab.values() if isinstance(v, str) and v.startswith("term_")), None)
    return None


def new_workspace(name):
    """A new focused workspace named `name`; returns its id."""
    before = set(workspace_ids())
    action("workspace.newAtBottom")
    made = wait(lambda: next((w for w in workspace_ids() if w not in before), None), 30)
    wait(focused_terminal, 15)
    cli("workspace", "current", "rename", name)
    return made


def tab_rows(title):
    """The tab rows under the workspace row titled `title` (rows key tabs by the sidebar's workspace id)."""
    key = next((str(r.get("key")) for r in rows("workspace") if r.get("title") == title), None)
    sidebar_id = key[key.find("(") + 1:key.rfind(")")] if key else None
    return [r for r in rows("tab") if sidebar_id and str(r.get("key")).startswith(f"tab({sidebar_id},")]


def open_page(workspace):
    """A browser tab on the test page in the workspace titled `workspace`; on this branch, waits for its favicon."""
    count = len(tab_rows(workspace))
    action("openBrowser.webkit", {"url": ORIGIN + "/"})
    if not opts.expect:
        return wait(lambda: len(tab_rows(workspace)) > count, 20)
    return wait(lambda: any(r.get("icon") == "favicon" for r in tab_rows(workspace)), 20)


app = None
try:
    config("Catppuccin Latte")
    open(GHOSTTY, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,980,720"}
    log = open(os.path.join(opts.out, "app.log"), "a")
    app = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print("launched pid", app.pid, flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and rows("workspace"), 180):
        sys.exit("the tagged app did not come up")
    wait(focused_terminal, 30)
    cli("workspace", "current", "rename", "terminal")

    new_workspace("agent")
    terminal = focused_terminal()
    check(bool(terminal), "the agent workspace has a terminal")
    # A Claude Code session starts in the terminal (its hook), so the row has an agent brand.
    cli("agent", "hook", "emit", "--source", "claude", "--event", "SessionStart", "--terminal", terminal or "")

    new_workspace("web")
    if not rows("tab"):
        action("sidebar.workspaceTabs.toggle")
    wait(lambda: rows("tab"), 10)
    check(bool(open_page("web")), "the web workspace shows its page (and its favicon on this branch)")

    new_workspace("mixed")
    first_terminal = focused_terminal()
    action("newSurface")
    check(bool(open_page("mixed")), "the mixed workspace has a browser tab (and its favicon on this branch)")
    # A background tab's notification: its tab row is unread (the muted dot on this branch).
    cli("terminal", first_terminal or "", "write", "--text", "printf '\\033]9;build finished\\007'\n")

    new_workspace("custom icon")
    cli("workspace", "current", "update", "--icon", "\U0001F680")

    group_first = new_workspace("group member A")
    action("workspace.moveToNewGroup", {"name": "group"}, target=f"workspace:{group_first}")
    group = wait(lambda: next((r.get("group") for r in rows("workspace") if r.get("title") == "group member A" and r.get("group")), None), 10)
    action("workspace.newBelow", target=f"workspace:{group_first}")
    wait(lambda: sum(1 for r in rows("workspace") if r.get("group") == group) >= 2, 15)
    cli("workspace", "current", "rename", "group member B")
    # The active workspace is a group member; collapsing hides it under the header.
    action("workspaceGroup.collapse", target=f"workspace-group:{group}")
    header = wait(lambda: next((r for r in rows("group") if group and group in str(r.get("key"))), None), 5)
    print("group header:", json.dumps(header), flush=True)
    # Move the pointer off the sidebar so no row shows a hover.
    rpc("debug.mouse", {"x": 700, "y": 400, "action": "hover"})
    time.sleep(2)  # the favicon and agent report settle

    pid = app.pid
    for theme, name in (("Catppuccin Latte", "latte"), ("Catppuccin Mocha", "mocha")):
        config(theme)
        time.sleep(2.5)  # the config watcher applies the theme
        state = sidebar()
        with open(os.path.join(opts.out, f"rows-{name}.json"), "w") as f:
            json.dump(state, f, indent=1)
        shot = subprocess.run(["bash", os.environ["NX_CAPTURE"], "shot", "--pid", str(pid), "--out", os.path.join(opts.out, f"window-{name}.png")],
                              capture_output=True, text=True, timeout=120)
        print("shot", name, shot.returncode, (shot.stdout + shot.stderr).strip()[-300:], flush=True)
        check(shot.returncode == 0, f"{name}: the window is captured")

    if opts.expect == "plain":
        state = sidebar()
        drawn = [(r.get("title") or r.get("key"), r.get("icon")) for r in state.get("rows") or [] if str(r.get("key")).startswith(("workspace(", "tab("))]
        print("drawn icons:", drawn, flush=True)
        check(any(d == ("agent", None) for d in drawn), "the agent workspace draws no agent mark")
        allowed = {None, "favicon"}
        stray = [d for d in drawn if d[1] not in allowed and d[0] != "custom icon"]
        check(not stray, f"no row draws a default glyph (stray {stray})")
        check(any(d[1] == "favicon" for d in drawn), "a browser row draws its favicon")
        check(any(d == ("custom icon", "emoji") for d in drawn), "the user's icon draws on its workspace")
        member = next((r for r in state.get("rows") or [] if r.get("title") == "group member B"), None)
        check(bool(member) and member.get("selected") is True and member.get("fill") is True,
              f"the collapsed group lists its active member with the selection fill ({member})")
finally:
    server.shutdown()
    print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
