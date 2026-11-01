#!/usr/bin/env python3
"""GUI proof of the sidebar densities (Lawrence 2026-10-14: Compact / Comfortable / Expanded on
`sidebar.density`, Compact the default; Comfortable = one line on taller rows with more padding).

Launches the tagged app itself (no activation, a scratch cmux.json, an isolated Chief home) on a
GUI host and builds one sidebar:

  shell     the first workspace, a plain terminal
  done      a terminal whose program reported done over OSC 7501 (left unseen)
  working   a terminal whose program reports working (the spinner)
  web       a workspace with a browser tab on a local page (tabs stay out of the sidebar)
  pinned    a pinned workspace (the top band)
  group     two workspaces in a group, expanded

Then it captures the default (no `sidebar.density` in cmux.json), and sets each density through
the action path (`action.run sidebar.density.<name>`, the palette and Options entry, which writes
the setting): comfortable, expanded, and compact again. For each it writes `debug.sidebar_rows`
(rows-<label>.json) and a window snapshot ($NX_CAPTURE; window-<label>.png), and it checks:

  default    cmux.json has no density; Options keeps every density choice visible
  rows       Comfortable workspace rows and group headers are one line and taller than Compact's
             by the same step; Expanded rows are at least as tall as Compact's; Compact again
             matches the default
  pinned     the pinned workspace's band row scales with the same step
  setting    each action wrote `sidebar.density` to cmux.json

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  sidebar-density-live.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/density"
Stop the app afterwards with "$NX_APP_STOP".
"""
import argparse, http.server, json, os, socket, struct, subprocess, sys, tempfile, threading, time, zlib

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"sbdensity-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-debug-cli.sh")
failures = []
summary = {"captures": []}


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    summary.setdefault("checks", []).append({"ok": bool(ok), "what": what})
    if not ok:
        failures.append(what)


def png(size, rgb):
    """A solid square PNG (the test page's favicon), with no imaging library."""
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


ICON = png(32, (0x1E, 0x66, 0xF5))


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
    print("cli", " ".join(args)[:120], "->", done.returncode, (done.stdout + done.stderr).strip()[-160:], flush=True)
    return done


def wait(predicate, seconds, step=0.25):
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


def rows(kind=None, state=None):
    state = state if state is not None else sidebar()
    return [r for r in state.get("rows") or [] if kind is None or str(r.get("key", "")).startswith(kind + "(")]


def topology():
    snap = rpc("snapshot.get") or {}
    return snap.get("topology") or snap


def workspace_ids():
    return [w.get("id") for w in topology().get("workspaces") or []]


def focused_terminal():
    topo = topology()
    tab_id = (topo.get("focus") or {}).get("tab")
    for ws in topo.get("workspaces") or []:
        for screen in ws.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("id") == tab_id:
                        return next((v for v in tab.values() if isinstance(v, str) and v.startswith("term_")), None)
    return None


def new_workspace(name):
    """A new focused workspace named `name`; returns (workspace id, terminal id)."""
    before = set(workspace_ids())
    reply = action("workspace.newAtBottom") or {}
    created = reply.get("created") or []
    made = wait(lambda: next((w for w in workspace_ids() if w not in before), None), 30)
    # The action names the terminal it made; the snapshot's focus may lag behind it.
    terminal = next((c for c in created if str(c).startswith("term_")), None) or wait(focused_terminal, 15)
    cli("workspace", "current", "rename", name)
    return made, terminal


def report(terminal, state, tail=""):
    """An OSC 7501 record from the terminal's program (`tail` keeps a working program running)."""
    return cli("terminal", terminal, "write", "--text", f"printf '\\033]7501;state={state}\\033\\\\'{tail}\n")


def configured_density():
    try:
        return (json.load(open(CONFIG)).get("sidebar") or {}).get("density")
    except (OSError, ValueError):
        return None


def height(row):
    return ((row or {}).get("frame") or {}).get("height")


def measure(state, pinned_ws):
    """Heights by role: workspace rows by title, group headers, section headers, pinned band row."""
    out = {"workspace": {r.get("title"): height(r) for r in rows("workspace", state)},
           "group": [height(r) for r in rows("group", state)],
           "section": [height(r) for r in rows("section", state)],
           "pinned": None,
           # The row's leading x in the list: the sidebar's horizontal inset.
           "row_x": sorted({((r.get("frame") or {}).get("x")) for r in rows("workspace", state) if not r.get("group")} - {None})}
    item = next((i for i in state.get("items") or [] if i.get("ref_kind") == "workspace" and str(i.get("ref", "")).endswith(":" + str(pinned_ws))), None)
    if item and item.get("window_frame"):
        out["pinned"] = item["window_frame"].get("height")
    return out


def capture(label, pid, pinned_ws):
    rpc("debug.mouse", {"x": 700, "y": 400, "action": "hover"})
    time.sleep(1.5)  # hover fades and the spinner frame settle before the shot
    state = sidebar()
    with open(os.path.join(opts.out, f"rows-{label}.json"), "w") as f:
        json.dump(state, f, indent=1)
    shot = subprocess.run(["bash", os.environ["NX_CAPTURE"], "shot", "--pid", str(pid), "--out", os.path.join(opts.out, f"window-{label}.png")],
                          capture_output=True, text=True, timeout=120)
    print("shot", label, shot.returncode, (shot.stdout + shot.stderr).strip()[-300:], flush=True)
    check(shot.returncode == 0, f"{label}: the window is captured")
    m = measure(state, pinned_ws)
    glyphs = [{"title": (g.get("title") or {}).get("text"), "state": g.get("state"), "animation": g.get("animation")}
              for g in state.get("status_glyphs") or []]
    summary["captures"].append({"label": label, "density": configured_density(), "heights": m, "status_glyphs": glyphs})
    print(label, json.dumps(m), flush=True)
    return m


def set_density(name, baseline_row):
    """Runs sidebar.density.<name> and waits until cmux.json and the row heights follow."""
    check(baseline_row is not None, f"{name}: the done row is listed before the switch")
    action(f"sidebar.density.{name}", focus=False)
    check(bool(wait(lambda: configured_density() == name, 10)), f"{name}: the action writes sidebar.density = {name} to cmux.json")
    # The list relayouts from the setting: wait for the 'done' row's height to leave the old value.
    wait(lambda: height(next((r for r in rows("workspace") if r.get("title") == "done"), None)) != baseline_row, 10)


app = None
try:
    with open(CONFIG, "w") as f:
        json.dump({"appearance": {"theme": "Catppuccin Latte"}}, f)
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
    cli("workspace", "current", "rename", "shell")
    _, done_terminal = new_workspace("done")
    _, working_terminal = new_workspace("working")
    check(bool(done_terminal and working_terminal), "the done and working workspaces have terminals")
    # done is reported while another workspace is focused, so it stays unseen.
    check(report(done_terminal or "", "done").returncode == 0, "done: the program reports it")
    check(report(working_terminal or "", "working", "; sleep 900").returncode == 0, "working: the program reports it")

    new_workspace("web")
    action("openBrowser.webkit", {"url": ORIGIN + "/"})
    check(not rows("tab"), "web: browser tabs stay out of the workspace sidebar")

    pinned_ws, _ = new_workspace("pinned")
    action("palette.toggleWorkspacePin", target={"kind": "workspace", "id": pinned_ws})
    check(bool(wait(lambda: any(str(i.get("ref", "")).endswith(":" + str(pinned_ws)) for i in sidebar().get("items") or []), 10)),
          "pinned: the workspace shows in the pinned band")

    group_first, _ = new_workspace("group member A")
    action("workspace.moveToNewGroup", {"name": "group"}, target=f"workspace:{group_first}")
    group = wait(lambda: next((r.get("group") for r in rows("workspace") if r.get("title") == "group member A" and r.get("group")), None), 10)
    action("workspace.newBelow", target=f"workspace:{group_first}")
    wait(lambda: sum(1 for r in rows("workspace") if r.get("group") == group) >= 2, 15)
    cli("workspace", "current", "rename", "group member B")
    check(bool(wait(lambda: rows("group"), 10)), "group: the group header is listed")
    check(bool(wait(lambda: any((g.get("title") or {}).get("text") == "done" for g in sidebar().get("status_glyphs") or []), 15)),
          "done: the done row shows its status mark")
    check(bool(wait(lambda: any(str(g.get("state", "")).startswith("working") for g in sidebar().get("status_glyphs") or []), 15)),
          "working: a row shows the working spinner")

    pid = app.pid
    check(configured_density() is None, "default: cmux.json sets no sidebar.density")
    default = capture("1-default", pid, pinned_ws)
    hidden = (rpc("debug.sidebar_rows", {"menu_x": 120, "menu_y": 560}) or {}).get("submenus") or {}
    options = next((v for k, v in hidden.items() if "Option" in k), None)
    print("Options submenu:", options, flush=True)
    if options is None:
        check(False, f"default: the sidebar background menu has an Options folder (submenus {list(hidden)})")
    else:
        check(all(title in options for title in ("Compact Rows", "Comfortable Rows", "Expanded Rows")),
              f"default: Options keeps every density choice visible ({options})")

    base = default["workspace"].get("done")
    set_density("comfortable", base)
    comfortable = capture("2-comfortable", pid, pinned_ws)
    set_density("expanded", comfortable["workspace"].get("done"))
    expanded = capture("3-expanded", pid, pinned_ws)
    set_density("compact", expanded["workspace"].get("done"))
    compact = capture("4-compact", pid, pinned_ws)

    # Comfortable: every one-line row grows by one step, and stays one line.
    steps = {t: (comfortable["workspace"].get(t) or 0) - (h or 0) for t, h in default["workspace"].items() if h}
    print("comfortable minus default, by row:", steps, flush=True)
    step = next(iter(steps.values()), 0)
    check(step > 0 and all(s == step for s in steps.values()), f"comfortable: every workspace row is taller by the same step ({steps})")
    for role in ("group", "section"):
        a, b = default[role], comfortable[role]
        if a:
            check(len(a) == len(b) and all(y - x == step for x, y in zip(a, b)), f"comfortable: {role} rows grow by the step ({a} -> {b})")
    if default["pinned"] is not None:
        check(comfortable["pinned"] is not None and comfortable["pinned"] - default["pinned"] == step,
              f"comfortable: the pinned band row grows by the step ({default['pinned']} -> {comfortable['pinned']})")
    check(default["row_x"] and comfortable["row_x"] and comfortable["row_x"][0] > default["row_x"][0],
          f"comfortable: rows sit further in (row x {default['row_x']} -> {comfortable['row_x']})")
    check(all((expanded["workspace"].get(t) or 0) >= h for t, h in default["workspace"].items() if h),
          "expanded: no workspace row is shorter than compact")
    check(any((expanded["workspace"].get(t) or 0) > h for t, h in default["workspace"].items() if h),
          "expanded: rows gain detail lines")
    check(all(compact[k] == default[k] for k in ("workspace", "group", "section", "pinned", "row_x")),
          "compact again: the rows match the default")
finally:
    server.shutdown()
    summary["failures"] = failures
    with open(os.path.join(opts.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
