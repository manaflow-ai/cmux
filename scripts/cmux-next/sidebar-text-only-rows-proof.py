#!/usr/bin/env python3
"""GUI proof: workspace rows are text only by default (WORKSPACE-ROWS-NO-DEFAULT-ICON, Lawrence
2026-10-14: "no icons in left sidebar of each workspace (besides website favicons) people can bring
their own icons though"). Regression: after #20492 and 217687e89d5f rows drew their kind glyph or
their agent's brand mark.

Launches the tagged app itself (no activation, a scratch cmux.json, an isolated Chief home) and
builds: terminal (plain), claude (Claude Code reports working in its terminal), codex (the same for Codex),
web (a browser tab in front with a favicon), custom icon (`workspace update --icon`), and a pinned
workspace with a Claude session (a pinned tile). Tab rows are listed. For compact, comfortable,
expanded and minimal it writes `debug.sidebar_rows` and a window shot ($NX_CAPTURE) and checks the
workspace rows' "icon" (what the row view draws): none on terminal/claude/codex, "favicon" on web,
"emoji" on custom icon. Tab rows are recorded (not changed by the fix). Use a new tag per run: a
tag's app restores its earlier session, so a second run on one tag lists every workspace twice.

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  sidebar-text-only-rows-proof.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/LABEL"
Stop the app afterwards with "$NX_APP_STOP".
"""
import argparse, http.server, json, os, socket, struct, subprocess, sys, tempfile, threading, time, zlib

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--expect", choices=["text-only"], default="text-only")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"sbtext-{opts.tag}-")
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


def config(density=None, minimal=False):
    sidebar_config = {"showWorkspaceTabs": True, "minimal": minimal}
    if density:
        sidebar_config["density"] = density
    with open(CONFIG, "w") as f:
        json.dump({"appearance": {"theme": "Catppuccin Mocha"}, "sidebar": sidebar_config}, f)


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
    return wait(lambda: any(r.get("icon") == "favicon" for r in tab_rows(workspace)), 20)


current_title = [""]


def agent(name, source):
    new_workspace(name)
    current_title[0] = name
    terminal = focused_terminal()
    check(bool(terminal), f"{name}: the workspace has a terminal")
    hook(source, terminal)


def hook(source, terminal):
    """The agent's own hooks: a session starts and a prompt is submitted in `terminal`, so its tab
    carries the agent's brand (TabModel.agentBrand) while the turn runs."""
    payload = json.dumps({"session_id": f"proof-{source}-{terminal}", "prompt": "proof"})
    # From inside the terminal, as the agent's hook command runs (its env names the terminal and
    # the daemon), then from here with --terminal.
    exe = os.environ.get("NX_APP_CLI") or "cmux"
    line = " && ".join(f"\"$(command -v cmux || echo '{exe}')\" agent hook emit --source {source} --event {event} --payload-json '{payload}'"
                       for event in ("SessionStart", "UserPromptSubmit"))
    cli("terminal", terminal or "", "write", "--text", line + "\n")
    if wait(lambda: str((workspace_rows(sidebar()).get(current_title[0]) or {}).get("activity", "")).startswith("working"), 8):
        return
    for event in ("SessionStart", "UserPromptSubmit"):
        cli("agent", "hook", "emit", "--source", source, "--event", event, "--terminal", terminal or "", "--payload-json", payload)


def workspace_rows(state):
    return {r.get("title"): r for r in state.get("rows") or [] if str(r.get("key")).startswith("workspace(")}


EXPECT = {"terminal": None, "claude": None, "codex": None, "web": "favicon", "custom icon": "emoji"}
summary = {"captures": []}
app = None
try:
    config()
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
    check(bool(wait(lambda: any(r.get("title") == "terminal" for r in rows("workspace")), 10)), "terminal: the first workspace is renamed")
    if not rows("tab"):
        action("sidebar.workspaceTabs.toggle")
    agent("claude", "claude")
    agent("codex", "codex")
    new_workspace("web")
    check(bool(open_page("web")), "web: the page tab shows its favicon")
    new_workspace("custom icon")
    cli("workspace", "current", "update", "--icon", "\U0001F680")
    pinned = new_workspace("pinned claude")
    current_title[0] = "pinned claude"
    hook("claude", focused_terminal())
    action("palette.toggleWorkspacePin", target={"kind": "workspace", "id": pinned})
    check(bool(wait(lambda: any(str(i.get("ref", "")).endswith(":" + str(pinned)) for i in sidebar().get("items") or []), 10)),
          "pinned: the workspace shows in the pinned band")
    # Select the first workspace (the plain terminal) so the agent rows are unselected.
    action("workspace.selectFirst")
    rpc("debug.mouse", {"x": 700, "y": 400, "action": "hover"})
    time.sleep(2)  # the favicon and agent reports settle
    # The agents' turns reached the sidebar (before this fix their rows drew the brand mark here).
    check(bool(wait(lambda: all(str((workspace_rows(sidebar()).get(t) or {}).get("activity", "")).startswith("working")
                                for t in ("claude", "codex")), 15)), "claude and codex: their rows show the agent working")

    for label, density, minimal in (("1-compact", "compact", False), ("2-comfortable", "comfortable", False),
                                    ("3-expanded", "expanded", False), ("4-minimal", "compact", True)):
        config(density, minimal)
        time.sleep(2.5)  # the config watcher applies the setting
        state = sidebar()
        with open(os.path.join(opts.out, f"rows-{label}.json"), "w") as f:
            json.dump(state, f, indent=1)
        shot = subprocess.run(["bash", os.environ["NX_CAPTURE"], "shot", "--pid", str(app.pid), "--out", os.path.join(opts.out, f"window-{label}.png")],
                              capture_output=True, text=True, timeout=120)
        print("shot", label, shot.returncode, (shot.stdout + shot.stderr).strip()[-300:], flush=True)
        check(shot.returncode == 0, f"{label}: the window is captured")
        ws = workspace_rows(state)
        icons = {title: (ws.get(title) or {}).get("icon", "MISSING") for title in EXPECT}
        tabs = {title: [r.get("icon") for r in tab_rows(title)] for title in ("claude", "codex", "web")}
        print(label, "workspace icons:", icons, "tab icons:", tabs, flush=True)
        summary["captures"].append({"label": label, "density": density, "minimal": minimal, "workspace_icons": icons, "tab_icons": tabs,
                                    "pinned_items": [i for i in state.get("items") or [] if i.get("ref_kind") == "workspace"]})
        for title, want in EXPECT.items():
            check(icons[title] == want, f"{label}: {title} row icon is {want!r} (got {icons[title]!r})")
finally:
    with open(os.path.join(opts.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    server.shutdown()
    print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
