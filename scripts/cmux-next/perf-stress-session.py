#!/usr/bin/env python3
"""The standard STRESS session for cmux NEXT perf work (Performance Lead, Lawrence 2026-10-23).

Builds, through the debug socket of a tagged app:

  * 60 workspaces in all. The measured workspace is the last one, shown and focused at the end.
  * The measured workspace: 4 side-by-side columns x 3 stacked rows = 12 panes, plus nested splits
    inside columns (the middle pane of columns 2 and 4 split once more, top and bottom: 14 panes).
    Each pane holds 6 tabs: 2 terminals, 2 Chromium pages, 1 WebKit page, 1 agent chat.
    The selected tab of each pane is a terminal (--selected chromium selects a Chromium page).
  * 10 other workspaces with Chromium pages (2 pages each), 49 with one terminal.
  * 10 terminals printing output (a line every 20 ms): the selected terminals of the first 10
    panes of the measured workspace (--busy-where elsewhere: of 10 other workspaces).

Columns are side-by-side splits (`splitRight`), as pane-perf-terminal.py builds its grids, so all
panes show in the window; `newColumn` would make strip columns that scroll off screen. The same
shape on every host: the builder first sets the window to WINDOW (1600 x 1000 points,
`debug.window_frame`), which fits 4 columns of the 200 pt minimum pane width beside any sidebar,
and checks the shape it made (60 workspaces, 4 columns side by side, 14 panes, 6 tabs each) before
it returns: another shape raises StressShapeError instead of being measured as STRESS.

Use it three ways:

  1. Build STRESS in an app you launched (any script):
       stress = load_stress()          # see the snippet below
       summary = stress.Stress(rpc).build()
     `rpc(method, params=None, timeout=...)` returns the reply's result, or {"error": ...}.
     `build_background()` and `build_measured()` are the two halves (a bench that measures a light
     workspace first can build the background later).

       import importlib.util, os
       def load_stress():
           path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-stress-session.py")
           spec = importlib.util.spec_from_file_location("perf_stress_session", path)
           module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
           return module

  2. Launch a tagged Debug app and build STRESS in it (left running with --keep):
       nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
         python3 scripts/cmux-next/perf-stress-session.py --app "$NX_APP" --out "$NX_ARTIFACTS"

  3. Build STRESS in a running tagged app: --socket /tmp/cmux-debug-<tag>.sock

pane-perf-terminal.py --stress measures pane motion in it (layout name `stress`).
Prints one line `STRESS-SESSION {json}`: workspaces, the measured workspace id, its panes, tabs by
kind, busy terminals, Chromium pages elsewhere and the build time.
"""
import argparse, http.server, json, os, socket, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))

WORKSPACES = 60
COLUMNS, ROWS = 4, 3
NESTED_COLUMNS = (1, 3)  # 0-based: columns 2 and 4 get a nested side-by-side split in their middle row
CHROMIUM_WORKSPACES = 10
CHROMIUM_PER_WORKSPACE = 2
BUSY_TERMINALS = 10
WINDOW = [80, 40, 1600, 1000]  # x, y, width, height in points (debug.window_frame)
BUSY_COMMAND = 'while :; do echo "$RANDOM $RANDOM $RANDOM stress output line $(date +%s)"; sleep 0.02; done\r'


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded poll of the app's socket state in a test script
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test script: the poll interval
    return None


def socket_rpc(path):
    """An rpc callable for a debug socket path."""
    def rpc(method, params=None, timeout=60):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
        except (OSError, ValueError) as error:
            return {"error": str(error)}
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    return rpc


class Pages:
    """Local pages for the Chromium and WebKit tabs (no network): text, a grid of cards, a spinner on rAF."""

    def __init__(self):
        def body(index):
            return ("<!doctype html><meta charset='utf-8'><title>stress %d</title>"
                    "<style>body{margin:0;font:16px -apple-system,sans-serif;background:#f4f4f6}"
                    "header{position:sticky;top:0;height:48px;background:#20304a;color:#fff;display:flex;align-items:center;padding:0 16px}"
                    "#s{width:16px;height:16px;background:#fff;border-radius:4px;margin-right:12px}"
                    ".g{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:10px;padding:16px}"
                    ".g div{height:80px;border-radius:10px;background:#c9d4e8}</style>"
                    "<header><i id='s'></i>stress page %d</header><div class='g'>%s</div><p>%s</p>"
                    "<script>let n=0;const s=document.getElementById('s');requestAnimationFrame(function f(){n++;"
                    "s.style.transform='rotate('+(n*4%%360)+'deg)';requestAnimationFrame(f)});</script>"
                    % (index, index, "<div></div>" * 120, "lorem ipsum dolor sit amet " * 200)).encode()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                try:
                    index = int(self.path.strip("/").split("/")[-1] or 0)
                except ValueError:
                    index = 0
                data = body(index)
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.next = 0

    def url(self):
        self.next += 1
        return f"http://127.0.0.1:{self.server.server_address[1]}/{self.next}"


class Stress:
    """Builds STRESS through `rpc`. Progress lines go to `log`."""

    def __init__(self, rpc, log=None, selected="terminal", busy_where="measured", settle=1.0):
        self.rpc, self.log = rpc, log or (lambda line: print(line, flush=True))
        self.selected, self.busy_where, self.settle = selected, busy_where, settle
        self.pages = Pages()
        self.refusals = []

    # Socket helpers.

    def action(self, name, args=None, target=None, focus=True, timeout=120, settle=0.0):
        params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
        if target:
            params["target"] = target
        reply = self.rpc("action.run", params, timeout=timeout)
        if isinstance(reply, dict) and reply.get("error"):
            self.refusals.append(f"{name}: {str(reply['error'])[:160]}")
        if settle:
            time.sleep(settle)  # test script: the layout settles before the next step
        return reply

    def topology(self):
        reply = self.rpc("snapshot.get")
        return (reply.get("topology") or {}) if isinstance(reply, dict) else {}

    def workspaces(self):
        return [w for w in self.topology().get("workspaces") or [] if w.get("id")]

    def workspace(self, workspace_id):
        return next((w for w in self.workspaces() if w.get("id") == workspace_id), None)

    def focused_workspace(self):
        return (self.topology().get("focus") or {}).get("workspace")

    @staticmethod
    def panes(workspace):
        return [p for s in (workspace or {}).get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]

    def new_workspace(self):
        before = {w["id"] for w in self.workspaces()}
        self.action("workspace.newAtBottom")
        made = wait(lambda: next((w["id"] for w in self.workspaces() if w["id"] not in before), None), 30)
        if made:
            wait(lambda: self.focused_workspace() == made, 10)
        return made

    def focus_pane(self, pane_id):
        self.action("pane.focus", target=f"pane:{pane_id}")
        wait(lambda: (self.topology().get("focus") or {}).get("pane") == pane_id, 5, step=0.05)

    def tabs(self, workspace_id, pane_id):
        pane = next((p for p in self.panes(self.workspace(workspace_id)) if p.get("id") == pane_id), None)
        return (pane or {}).get("tabs") or []

    def add_tab(self, workspace_id, pane_id, kind):
        """One tab of `kind` (terminal, chromium, webkit, chat) in the focused pane; waits for it."""
        count = len(self.tabs(workspace_id, pane_id))
        if kind == "terminal":
            self.action("newSurface")
        elif kind == "chromium":
            self.action("openBrowser.chromium", {"url": self.pages.url()})
        elif kind == "webkit":
            self.action("openBrowser.webkit", {"url": self.pages.url()})
        else:
            reply = self.action("palette.newAgentChat")
            if isinstance(reply, dict) and reply.get("error"):
                self.action("newTab.page")  # no agent chat in this build: the New Tab page stands in
        wait(lambda: len(self.tabs(workspace_id, pane_id)) > count, 20, step=0.1)

    def send(self, tab_id, text):
        self.action("terminal.sendText", {"text": text}, target=f"tab:{tab_id}", focus=False)

    # The two halves.

    def build_background(self, count=WORKSPACES - 1, chromium=CHROMIUM_WORKSPACES):
        """`count` workspaces besides the measured one: the first `chromium` with Chromium pages."""
        made = []
        for index in range(count):
            workspace = self.new_workspace()
            if not workspace:
                self.log(f"stress: workspace {index + 1} did not appear")
                continue
            made.append(workspace)
            if index < chromium:
                pane = (self.panes(self.workspace(workspace)) or [{}])[0].get("id")
                for _ in range(CHROMIUM_PER_WORKSPACE):
                    self.add_tab(workspace, pane, "chromium")
            if (index + 1) % 10 == 0:
                self.log(f"stress: {index + 1}/{count} background workspaces")
        self.background = made
        return made

    def build_grid(self):
        """The measured workspace's panes: COLUMNS x ROWS with the nested splits. Ends on the top-left pane."""
        for _ in range(COLUMNS - 1):
            self.action("splitRight", settle=0.5)
        # Right to left: the rows of each column, then its nested split, back to its top, one column left.
        for column in reversed(range(COLUMNS)):
            for _ in range(ROWS - 1):
                self.action("splitDown", settle=0.5)
            for _ in range(ROWS - 1):
                self.action("focusUp", settle=0.15)
            if column in NESTED_COLUMNS:
                # The middle pane splits once more, top and bottom: a split nested in the column's
                # chain, which needs no more width than the column has.
                self.action("focusDown", settle=0.15)
                self.action("splitDown", settle=0.5)
                self.action("focusUp", settle=0.15)
                self.action("focusUp", settle=0.15)
            if column > 0:
                self.action("focusLeft", settle=0.15)
        self.action("equalizeSplits", settle=0.8)

    def size_window(self):
        """The window at WINDOW: the grid fits it on every host, whatever the display."""
        reply = self.rpc("debug.window_frame", {"frame": WINDOW})
        if isinstance(reply, dict) and reply.get("error"):
            self.refusals.append(f"debug.window_frame: {str(reply['error'])[:160]}")
        return reply

    def build_measured(self):
        """The measured workspace (new, last, focused): the grid, 6 tabs per pane, the busy terminals."""
        self.size_window()
        workspace = self.new_workspace()
        self.build_grid()
        panes = [p["id"] for p in self.panes(self.workspace(workspace))]
        # Each pane has its first terminal; Chromium, Chromium, WebKit and chat follow, and the last
        # one made is the selected one (a terminal, or a Chromium page with --selected chromium).
        order = ["chromium", "chromium", "webkit", "chat", "terminal"]
        if self.selected == "chromium":
            order = ["terminal", "chromium", "webkit", "chat", "chromium"]
        for index, pane in enumerate(panes):
            self.focus_pane(pane)
            for kind in order:
                self.add_tab(workspace, pane, kind)
            self.log(f"stress: pane {index + 1}/{len(panes)} has {len(self.tabs(workspace, pane))} tabs")
        busy = []
        if self.busy_where == "measured":
            for pane in panes[:BUSY_TERMINALS]:
                tabs = self.tabs(workspace, pane)
                selected = next((t for t in tabs if t.get("kind") == "terminal" and t.get("selected")), None)
                terminal = selected or next((t for t in reversed(tabs) if t.get("kind") == "terminal"), None)
                if terminal:
                    self.send(terminal["id"], BUSY_COMMAND)
                    busy.append(terminal["id"])
        else:
            for other in getattr(self, "background", [])[-BUSY_TERMINALS:]:
                for pane in self.panes(self.workspace(other)):
                    terminal = next((t for t in pane.get("tabs") or [] if t.get("kind") == "terminal"), None)
                    if terminal:
                        self.send(terminal["id"], BUSY_COMMAND)
                        busy.append(terminal["id"])
                        break
        self.action("goToWorkspace", {"workspace": workspace})
        wait(lambda: self.focused_workspace() == workspace, 20)
        if panes:
            self.focus_pane(panes[0])
        self.measured, self.busy = workspace, busy
        return workspace

    def build(self, check=True):
        start = time.monotonic()
        self.build_background()
        self.build_measured()
        time.sleep(self.settle)  # test script: first page loads and the busy output start before a measure
        summary = self.summary()
        summary["build_s"] = round(time.monotonic() - start, 1)
        if check:
            self.check(summary)
        return summary

    @staticmethod
    def check(summary):
        """Raises StressShapeError when the session is not STRESS (another layout is never measured as it)."""
        want_panes = COLUMNS * ROWS + len(NESTED_COLUMNS)
        tabs = sum((summary.get("measured_tabs") or {}).values())
        problems = []
        if (summary.get("workspaces") or 0) < WORKSPACES:
            problems.append(f"{summary.get('workspaces')} workspaces, not {WORKSPACES}")
        if summary.get("measured_panes") != want_panes:
            problems.append(f"{summary.get('measured_panes')} panes, not {want_panes}")
        if summary.get("shown_columns") != COLUMNS:
            problems.append(f"{summary.get('shown_columns')} columns side by side, not {COLUMNS}")
        if tabs < want_panes * 6:
            problems.append(f"{tabs} tabs in the measured workspace, not {want_panes * 6}")
        if problems:
            raise StressShapeError("STRESS session has the wrong shape: " + "; ".join(problems)
                                   + f" (window {summary.get('window')}; refusals: {summary.get('refusals')})")

    def shown_columns(self):
        """Columns of panes side by side in the shown workspace: distinct left edges of its pane rings in
        the window (`debug.layers`); a nested split shares its column's left edge."""
        layers = self.rpc("debug.layers")
        window = ((layers or {}).get("windows") or [{}])[0] if isinstance(layers, dict) else {}
        rings = [r for plane in window.get("planes") or [] for r in plane.get("rings") or []]
        edges = {round(r["frame_in_window"][0]) for r in rings if r.get("frame_in_window")}
        return (len(edges) or None), window.get("frame")

    def summary(self):
        workspaces = self.workspaces()
        measured = next((w for w in workspaces if w.get("id") == getattr(self, "measured", None)), None)
        kinds = {}
        for pane in self.panes(measured):
            for tab in pane.get("tabs") or []:
                kind = tab.get("kind") or "?"
                if kind == "page":
                    kind = f"page:{tab.get('page')}"
                kinds[kind] = kinds.get(kind, 0) + 1
        columns = sorted({p.get("column") for p in self.panes(measured) if p.get("column") is not None})
        shown, frame = self.shown_columns()
        return {"workspaces": len(workspaces), "measured": getattr(self, "measured", None), "shown_columns": shown, "window": frame,
                "measured_panes": len(self.panes(measured)), "measured_columns": len(columns) or None,
                "measured_tabs": kinds, "busy_terminals": len(getattr(self, "busy", [])), "busy_where": self.busy_where,
                "selected": self.selected, "chromium_workspaces": min(CHROMIUM_WORKSPACES, len(getattr(self, "background", []))),
                "refusals": self.refusals[:10]}


class StressShapeError(RuntimeError):
    """The session built is not the STRESS shape."""


def load_activation_app():
    import importlib.util
    spec = importlib.util.spec_from_file_location("activation_perf", os.path.join(HERE, "activation-perf.py"))
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, HERE)
    spec.loader.exec_module(module)
    return module.App


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="a Debug `cmux DEV <tag>.app` to launch (not running)")
    where.add_argument("--socket", help="the debug socket of a running tagged app")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="cmux-stress-"))
    parser.add_argument("--selected", choices=["terminal", "chromium"], default="terminal")
    parser.add_argument("--busy-where", choices=["measured", "elsewhere"], default="measured")
    parser.add_argument("--keep", action="store_true", help="leave the launched app running")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    app = None
    if opts.app:
        app = load_activation_app()(os.path.abspath(opts.app), opts.out, 50)
        app.launch()
        rpc = app.rpc
    else:
        rpc = socket_rpc(opts.socket)
    try:
        summary = Stress(rpc, selected=opts.selected, busy_where=opts.busy_where).build()
        print("STRESS-SESSION " + json.dumps(summary), flush=True)
        with open(os.path.join(opts.out, "stress-session.json"), "w") as f:
            json.dump(summary, f, indent=1)
        if app and opts.keep:
            print(f"stress: app left running, socket {app.socket}", flush=True)
            while True:
                time.sleep(3600)  # test script: keep the pages' server up for the kept app
    finally:
        if app and not opts.keep:
            app.stop()


if __name__ == "__main__":
    main()
