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
shape on every host: the builder first sets the bench minimum pane size (80 x 32 pt, `settings.set`
in the tagged app's own config: run it only on bench apps with a scratch config) and the window to
WINDOW_SIZE (1600 x 1000 points, `place_window` below), aims every split at its pane by id, splits the
columns balanced (halves, then quarters) on the measured workspace shown, and checks the shape it made
(60 workspaces, 4 even columns side by side, 14 panes in even rows, 6 tabs each of the kind asked,
agent chats and no New Tab page in their place, Chromium running with no WebKit fallback; `Stress.check`)
before it returns: another shape raises StressShapeError instead of being measured as STRESS.

The window (`place_window`) goes on the main screen at WINDOW_SIZE: centered across the screen's visible
frame, its top at the visible frame's top (under the menu bar). The 1920 x 1080 main display of the fleet
(split-spring.sh --vdisplay=120) has a visible height under 1000 pt when the Dock shows at the bottom, so
a bottom Dock may cover the window's lower edge: the Dock draws over it, every pane stays on the screen
and is laid out and drawn as before. The summary records that overlap (`dock_overlap_pt`) as a bench
condition. A window past the screen's edges or under the menu bar is not STRESS. An app built before
the `visible_frame` / `screen_frame` fields (bb4ac3c2b03) gets the size check and the grid check from
debug.layers pane frames only, and the summary says `window_on_screen: "unknown"`.

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
import argparse, http.server, json, os, signal, socket, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))

WORKSPACES = 60
COLUMNS, ROWS = 4, 3
NESTED_COLUMNS = (1, 3)  # 0-based: columns 2 and 4 split their middle row once more, top and bottom
CHROMIUM_WORKSPACES = 10
CHROMIUM_PER_WORKSPACE = 2
BUSY_TERMINALS = 10
PROVISIONAL_TAB = "pending_tab_"  # ProvisionalTab.idPrefix: a tab the app shows before the daemon has it
WINDOW_SIZE = (1600, 1000)  # width, height in points (debug.window_frame)
# An app without the screen fields (before bb4ac3c2b03) cannot be placed on its screen: the window then goes
# here, bottom-left screen points, as before.
LEGACY_ORIGIN = (80, 40)
MINIMUM_PANE = {"layout.minimumPaneWidth": 80, "layout.minimumPaneHeight": 32}
WEB_DEV_CONFIG = os.path.expanduser("~/.config/cmux/web-dev.json")  # routes pages to a dev server when present
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
        self.handler = Handler
        self.server = None  # started by the first url()
        self.next = 0

    def url(self):
        if self.server is None:
            self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.handler)
            # poll_interval: how soon serve_forever sees close()'s shutdown request (stdlib default 0.5 s).
            threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        self.next += 1
        return f"http://127.0.0.1:{self.server.server_address[1]}/{self.next}"

    def close(self):
        """Stops the server, if one started, and closes its socket."""
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None


class Stress:
    """Builds STRESS through `rpc`. Progress lines go to `log`."""

    def __init__(self, rpc, log=None, selected="terminal", busy_where="measured", settle=1.0, web_dev_config=WEB_DEV_CONFIG,
                 allow_chat_fallback=False):
        self.rpc, self.log = rpc, log or (lambda line: print(line, flush=True))
        self.web_dev_config = web_dev_config  # a file here that points pages at a dev server (not STRESS)
        # A refused agent chat is replaced by the New Tab page, counted in `chat_fallbacks`. STRESS has agent
        # chats, so `check` refuses any fallback unless the caller asks for that other session.
        self.allow_chat_fallback = allow_chat_fallback
        self.window_reply = {}  # the last placement's debug.window_frame reply
        self.selected, self.busy_where, self.settle = selected, busy_where, settle
        self.pages = Pages()
        self.refusals = []
        self.chat_fallbacks = 0
        # Each tab this builder made, by pane: (asked kind, tab id); the shape check reads them back.
        self.made = {}

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
        # Focus may not follow on a loaded host, so nothing here waits for it. A caller that needs the
        # workspace on screen (the measured grid, the background pages) shows it with `show()`.
        return made

    def show(self, workspace):
        """Shows `workspace` in the window (goToWorkspace); raises StressShapeError when it does not show."""
        if self.window_showing(workspace):
            return
        self.action("goToWorkspace", {"workspace": workspace})
        if not wait(lambda: self.window_showing(workspace) is not None, 10, step=0.05):
            raise StressShapeError(f"workspace {workspace} never showed")

    def window_showing(self, workspace, topology=None):
        """The topology window that shows `workspace` (each window reports its own workspace and focused pane), or
        None. Not the top-level focus: that is the ACTIVE window's, which another window (an open panel, a window
        an earlier action left) can be while this one shows the workspace."""
        return next((w for w in (topology or self.topology()).get("windows") or [] if w.get("workspace") == workspace), None)

    def focus_pane(self, pane_id):
        """Focuses `pane_id` in the window that shows its workspace; raises StressShapeError when that window's
        focused pane does not become it."""
        self.action("pane.focus", target=f"pane:{pane_id}")

        def focused():
            topology = self.topology()
            owner = next((w["id"] for w in topology.get("workspaces") or [] for p in self.panes(w) if p.get("id") == pane_id), None)
            window = self.window_showing(owner, topology) if owner else None
            return (window or {}).get("focused_pane") == pane_id or (topology.get("focus") or {}).get("pane") == pane_id
        if not wait(focused, 10, step=0.05):
            topology = self.topology()
            raise StressShapeError(f"focus never reached pane {pane_id} (active focus {topology.get('focus')}, "
                                   f"windows {[(w.get('key'), w.get('workspace'), w.get('focused_pane')) for w in topology.get('windows') or []]})")

    def tabs(self, workspace_id, pane_id):
        pane = next((p for p in self.panes(self.workspace(workspace_id)) if p.get("id") == pane_id), None)
        return (pane or {}).get("tabs") or []

    def settled_tabs(self, workspace_id, pane_id, seconds=20):
        """`pane_id`'s tabs once none is provisional (the app shows a new tab under a `pending_tab_` id until
        the daemon has it), or as they are after `seconds`."""
        settled = wait(lambda: (lambda tabs: tabs if tabs and not any(provisional(t) for t in tabs) else None)(
            self.tabs(workspace_id, pane_id)), seconds, step=0.1)
        return settled or self.tabs(workspace_id, pane_id)

    def add_tab(self, workspace_id, pane_id, kind):
        """One tab of `kind` (terminal, chromium, webkit, chat) in `pane_id`, aimed at it by id (never at
        whatever has focus); waits for it, and for the daemon to have it."""
        # The tab before this one may still be provisional (a new agent chat is, until its conversation
        # starts): a target that names it is refused ("No tab matches pending_tab_..."), and a provisional
        # tab that goes away would hide the new one from a tab count. So: the pane settled first, the target
        # a tab the daemon has, and the new tab found by id and kind, not by count.
        tabs = self.settled_tabs(workspace_id, pane_id)
        before = {t.get("id") for t in tabs}
        target = f"pane:{pane_id}"
        # The new-tab actions (newSurface, openBrowser.*) take a tab target: the tab the new one opens
        # beside, in that tab's pane. A pane target is refused (invalid_params), and no tab opens.
        real = [t for t in tabs if t.get("id") and not provisional(t)]
        beside = next((t for t in real if t.get("selected")), real[-1] if real else None)
        tab_target = f"tab:{beside['id']}" if beside else target
        fallback = False
        if kind == "terminal":
            self.action("newSurface", target=tab_target)
        elif kind == "chromium":
            self.action("openBrowser.chromium", {"url": self.pages.url()}, target=tab_target)
        elif kind == "webkit":
            self.action("openBrowser.webkit", {"url": self.pages.url()}, target=tab_target)
        else:
            # The reply comes when the action has run. Only the app's typed refusal (an error with a code:
            # launch denied, a build without agent chats) falls back to the New Tab page; a reply that does not
            # come in time is no refusal (the chat may still open), so nothing is added and the pane's mix
            # check names the missing tab.
            # focus=False: a script's chat aimed at a pane opens as a tab in that pane (AgentHandlers
            # openTargetedChat, #23016). With focus the run takes the person's New Agent Chat path, which
            # puts the first chat in a new left chat dock and every later one in that dock
            # (NewChatPlacement): one extra pane and column, and no chat in any measured pane.
            reply = self.action("palette.newAgentChat", target=target, focus=False)
            if typed_refusal(reply):
                self.chat_fallbacks += 1
                fallback = True
                self.action("newTab.page", target=target)
        kinds = topology_kinds(kind, fallback)

        def fresh():
            return [t for t in self.tabs(workspace_id, pane_id) if t.get("id") not in before and t.get("kind") in kinds] or None
        appeared = wait(fresh, 20, step=0.1)
        if not appeared and kind in ("terminal", "chromium", "webkit"):
            # No silent go-on: a run that measures a pane without the tab it asked for measures the wrong
            # pane (the Command-pan bench over Chromium measured a terminal, 2026-10-24). A chat may still
            # open late; the pane's mix check names it.
            raise RuntimeError(f"{kind} tab did not appear in {pane_id} in 20 s (refusals: {self.refusals[-3:]})")
        # Only the daemon's id is recorded: a provisional id is replaced when the daemon has the tab, and a tab
        # the daemon never got is no STRESS tab. A terminal or page without it fails here; a chat without it is
        # recorded as missing (None), and the pane's mix check names it.
        confirmed = wait(lambda: [t for t in fresh() or [] if not provisional(t)] or None, 20, step=0.1) if appeared else None
        if appeared and not confirmed and kind in ("terminal", "chromium", "webkit"):
            raise RuntimeError(f"{kind} tab in {pane_id} stayed provisional for 20 s (the daemon never had it)")
        new = [t.get("id") for t in confirmed or []]
        self.made.setdefault(pane_id, []).append((kind, new[0] if len(new) == 1 else None, fallback))

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
                # Shown first, so the pages open live through the shown pane's controller, as a person's
                # new tab does. openBrowser.* also resolves a pane of a hidden workspace, but then opens the
                # page offscreen, which is not the load STRESS describes.
                self.show(workspace)
                pane = (self.panes(self.workspace(workspace)) or [{}])[0].get("id")
                for _ in range(CHROMIUM_PER_WORKSPACE):
                    self.add_tab(workspace, pane, "chromium")
            if (index + 1) % 10 == 0:
                self.log(f"stress: {index + 1}/{count} background workspaces")
        self.background = made
        return made

    def build_light(self, kinds=("chromium", "chromium", "webkit", "chat", "terminal")):
        """The light session (every-action-sweep.py): a new workspace, shown, split once to the right by pane id,
        its first pane with a tab of each of `kinds` after its terminal. Returns (workspace, [pane ids]); raises
        StressShapeError when the workspace never shows. Shown first, as the measured grid: focus may not follow
        a new workspace on a loaded host, and an action aimed at whatever has focus lands in another workspace."""
        workspace = self.new_workspace()
        if not workspace:
            raise StressShapeError("the light workspace did not appear")
        self.show(workspace)
        first = self.panes(self.workspace(workspace))[0]["id"]
        self.split(workspace, first, "splitRight")
        panes = [p["id"] for p in self.panes(self.workspace(workspace))]
        self.focus_pane(first)
        for kind in kinds:
            self.add_tab(workspace, first, kind)
        return workspace, panes

    def close(self):
        """Stops the local pages' server (the end of a run, or a test)."""
        self.pages.close()

    def split(self, workspace, pane, verb):
        """`verb` (splitRight, splitDown) on `pane` by id, not by focus; returns the new pane's id, or
        None (the refusal is in `refusals`)."""
        before = {p["id"] for p in self.panes(self.workspace(workspace))}
        self.action(verb, target=f"pane:{pane}")
        made = wait(lambda: next((p["id"] for p in self.panes(self.workspace(workspace)) if p["id"] not in before), None), 15, step=0.1)
        if not made:
            self.refusals.append(f"{verb} on {pane} made no pane")
        else:
            self.record_first(workspace, made)
        return made

    def record_first(self, workspace, pane):
        """Records `pane`'s first terminal (the tab a new pane comes with) as a tab this builder owns."""
        tabs = wait(lambda: self.tabs(workspace, pane), 10, step=0.05) or []
        first = next((t.get("id") for t in tabs if t.get("kind") == "terminal"), None)
        if self.made.get(pane) and self.made[pane][0][0] == "terminal" and self.made[pane][0][1] == first:
            return
        self.made.setdefault(pane, []).insert(0, ("terminal", first, False))

    def live_busy(self, measured):
        """Busy ids that are still terminal tabs: in the measured workspace (busy_where measured) or in the
        background workspaces (elsewhere)."""
        places = [measured] if self.busy_where == "measured" else [self.workspace(w) for w in getattr(self, "background", [])]
        terminals = {t.get("id") for w in places for p in self.panes(w) for t in p.get("tabs") or [] if t.get("kind") == "terminal"}
        return sum(1 for tab in getattr(self, "busy", []) if tab in terminals)

    def make_busy(self, tab_id):
        """Starts the output loop in terminal `tab_id` and records it as a busy terminal."""
        self.send(tab_id, BUSY_COMMAND)
        self.busy = getattr(self, "busy", [])
        self.busy.append(tab_id)

    def build_grid(self, workspace):
        """The measured workspace's panes: COLUMNS x ROWS plus the nested splits, each split aimed at
        its pane by id. Columns split balanced (halves, then quarters), so no column is ever narrower
        than a quarter of the window while the grid grows."""
        first = self.panes(self.workspace(workspace))[0]["id"]
        self.record_first(workspace, first)
        # Halves, then quarters: [first, b] -> [first, c, b, d].
        b = self.split(workspace, first, "splitRight")
        c = self.split(workspace, first, "splitRight")
        d = self.split(workspace, b, "splitRight") if b else None
        columns = [pane for pane in (first, c, b, d) if pane]
        for index, top in enumerate(columns):
            rows = [top]
            while len(rows) < ROWS:
                new = self.split(workspace, rows[-1], "splitDown")
                if not new:
                    break
                rows.append(new)
            if index in NESTED_COLUMNS and len(rows) > 1:
                # The middle row splits once more, top and bottom: a split nested in the column's chain.
                self.split(workspace, rows[1], "splitDown")
        self.action("equalizeSplits", target=f"pane:{first}", settle=0.8)
        return first

    def size_window(self):
        """The window at WINDOW_SIZE on the main screen (`place_window`), and the bench minimum pane size
        (MINIMUM_PANE, written to the tagged app's own config with `settings.set`: a bench app runs on a
        scratch config): the grid fits on every host, whatever its display (a fleet mini's screen can be
        smaller than WINDOW_SIZE)."""
        for key, value in MINIMUM_PANE.items():
            reply = self.rpc("settings.set", {"path": key, "value": value})
            if isinstance(reply, dict) and reply.get("error"):
                self.refusals.append(f"settings.set {key}: {str(reply['error'])[:160]}")
        # A display smaller than the window (a 1024 x 768 fleet screen, a window the screen clamped to
        # 675 pt) cannot hold 4 x 3 panes, and the app then places splits elsewhere; a window past the
        # screen's edges puts panes and Chromium pages off screen. setFrame does not keep a window on its
        # screen at once (that happens later), so the end of the build checks again (`check`, `window`).
        # Fail before building anything; on the fleet run under split-spring.sh --vdisplay=120 (a
        # 1920 x 1080 virtual main display), or launch here with --vdisplay.
        reply, problem = place_window(self.rpc)
        self.window_reply = reply if isinstance(reply, dict) else {}
        if problem:
            raise StressShapeError(f"{problem}: run with a 1920 x 1080 display (split-spring.sh --vdisplay=120, "
                                   "or --vdisplay here)")
        return reply

    def build_measured(self):
        """The measured workspace (new, last, focused): the grid, 6 tabs per pane, the busy terminals."""
        self.size_window()
        workspace = self.new_workspace()
        if not workspace:
            raise StressShapeError("the measured workspace did not appear")
        # Shown before the first split: a split of a hidden workspace's pane has no content controller,
        # so the app skips the even split sizing (each splitDown halves only the last row) and refuses
        # equalizeSplits ("not shown in any window"). A workspace that does not show raises here.
        self.show(workspace)
        self.build_grid(workspace)
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
        self.busy = []
        if self.busy_where == "measured":
            for pane in panes[:BUSY_TERMINALS]:
                tabs = self.tabs(workspace, pane)
                selected = next((t for t in tabs if t.get("kind") == "terminal" and t.get("selected")), None)
                terminal = selected or next((t for t in reversed(tabs) if t.get("kind") == "terminal"), None)
                if terminal:
                    self.make_busy(terminal["id"])
        else:
            for other in getattr(self, "background", [])[-BUSY_TERMINALS:]:
                for pane in self.panes(self.workspace(other)):
                    terminal = next((t for t in pane.get("tabs") or [] if t.get("kind") == "terminal"), None)
                    if terminal:
                        self.make_busy(terminal["id"])
                        break
        self.action("goToWorkspace", {"workspace": workspace})
        wait(lambda: self.focused_workspace() == workspace, 20)
        if panes:
            self.focus_pane(panes[0])
        self.measured = workspace
        return workspace

    def build(self, check=True):
        start = time.monotonic()
        # 60 in all: the ones the app already has, the background, and the measured one.
        self.size_window()  # a display too small for the grid fails here, before 59 workspaces are built
        existing = len(self.workspaces())
        if existing > WORKSPACES - 1:
            raise StressShapeError(f"the app already has {existing} workspaces; STRESS has {WORKSPACES} in all")
        self.build_background(count=WORKSPACES - 1 - existing)
        self.build_measured()
        time.sleep(self.settle)  # test script: first page loads and the busy output start before a measure
        summary = self.summary()
        summary["build_s"] = round(time.monotonic() - start, 1)
        if check:
            self.check(summary)
        return summary

    @staticmethod
    def check(summary):
        """Raises StressShapeError when the session is not STRESS (another layout is never measured as it):
        exactly 60 workspaces, 4 columns side by side, 14 panes laid out even (equal column widths, equal
        rows in each column), no refused split or equalizeSplits, the window at WINDOW_SIZE on its screen
        (`window_problem`), each pane exactly 2 terminals, 2 browser tabs asked as Chromium, 1 asked as
        WebKit and 1 agent chat (a New Tab page in its place only with allow_chat_fallback), each made tab of the topology kind it
        was asked as, Chromium running (debug.cef ready, no unavailable reason, no WebKit fallback, no
        refused openBrowser.chromium), 10 background workspaces with 2 Chromium pages each, 10 busy
        terminals. The engine of each browser tab is not read one by one (the topology has no engine
        field): a Chromium request that got WebKit is a debug.cef fallback, and with --selected chromium
        every shown pane's tab must be a CEF tab (debug.layers browsers)."""
        want_panes = COLUMNS * ROWS + len(NESTED_COLUMNS)
        tabs = sum((summary.get("measured_tabs") or {}).values())
        problems = list(summary.get("pane_problems") or [])
        problems += summary.get("grid_problems") or []
        if summary.get("layout_refusals"):
            problems.append(f"the grid's splits were refused: {summary.get('layout_refusals')}")
        if summary.get("window_problem"):
            problems.append(summary["window_problem"])
        if summary.get("chat_fallbacks") and not summary.get("chat_fallback_ok"):
            problems.append(f"{summary.get('chat_fallbacks')} agent chats were refused and replaced by the New Tab page "
                            "(STRESS has an agent chat in every pane)")
        if summary.get("busy_terminals") != BUSY_TERMINALS:
            problems.append(f"{summary.get('busy_terminals')} busy terminals, not {BUSY_TERMINALS}")
        if summary.get("background_chromium") != [CHROMIUM_PER_WORKSPACE] * CHROMIUM_WORKSPACES:
            problems.append(f"background Chromium pages per workspace {summary.get('background_chromium')}")
        if summary.get("chromium_unavailable"):
            problems.append(f"Chromium is not available: {summary.get('chromium_unavailable')}")
        if (summary.get("workspaces") or 0) != WORKSPACES:
            problems.append(f"{summary.get('workspaces')} workspaces, not {WORKSPACES}")
        if summary.get("measured_panes") != want_panes:
            problems.append(f"{summary.get('measured_panes')} panes, not {want_panes}")
        if summary.get("shown_columns") != COLUMNS:
            problems.append(f"{summary.get('shown_columns')} columns side by side, not {COLUMNS}")
        if tabs != want_panes * 6:
            problems.append(f"{tabs} tabs in the measured workspace, not {want_panes * 6}")
        if problems:
            raise StressShapeError("STRESS session has the wrong shape: " + "; ".join(problems)
                                   + f" (window {summary.get('window')}; refusals: {summary.get('refusals')})")

    def shown_window(self):
        """The `debug.layers` window that shows the measured workspace (topology windows carry the
        debug.layers id as `key`), or {}."""
        layers = self.rpc("debug.layers")
        windows = ((layers or {}).get("windows") or []) if isinstance(layers, dict) else []
        measured = getattr(self, "measured", None)
        key = next((w.get("key") for w in self.topology().get("windows") or [] if w.get("workspace") == measured), None)
        return next((w for w in windows if w.get("id") == key), windows[0] if windows else {})

    @staticmethod
    def shown_columns(window):
        """Columns of panes side by side in `window`: 1 + the distinct x of its vertical divider areas
        (`debug.layers` divider_areas_in_window, taller than wide); a nested split adds only horizontal
        dividers."""
        xs = {round(x + w / 2) for x, y, w, h in window.get("divider_areas_in_window") or [] if h > w}
        return len(xs) + 1 if window else None

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
        # Each measured pane's mix, from the tabs this builder made and what the topology says they are.
        want = {"terminal": 2, "chromium": 2, "webkit": 1, "chat": 1}
        pane_problems = []
        for pane in self.panes(measured):
            tabs = {t.get("id"): t.get("kind") for t in pane.get("tabs") or []}
            asked = self.made.get(pane.get("id"), [])
            got = {k: sum(1 for kind, _, _ in asked if kind == k) for k in want}
            wrong = [f"{kind} tab {tab} is {tabs.get(tab)}" for kind, tab, fallback in asked
                     if tab is None or tabs.get(tab) not in topology_kinds(kind, fallback)]
            if got != want or len(tabs) != 6 or wrong:
                pane_problems.append(f"pane {pane.get('id')}: {len(tabs)} tabs, made {got}{'; ' + ', '.join(wrong[:3]) if wrong else ''}")
        background = [sum(1 for p in self.panes(self.workspace(w)) for t in p.get("tabs") or [] if t.get("kind") not in (None, "terminal"))
                      for w in getattr(self, "background", [])[:CHROMIUM_WORKSPACES]]
        window = self.shown_window()
        on_screen = {"frame": window.get("frame"), "visible_frame": window.get("screen_visible_frame"),
                     "screen_frame": window.get("screen_frame")}
        unavailable = [r for r in self.refusals if r.startswith("openBrowser.chromium")]
        unavailable += cef_problems(self.rpc("debug.cef"), self.web_dev_config)
        if self.selected == "chromium":
            # Each shown pane's selected tab was asked as Chromium: each must be a CEF tab.
            engines = [b.get("engine") for b in window.get("browsers") or []]
            if engines.count("cef") != len(self.panes(measured)):
                unavailable.append(f"shown browser tabs by engine {engines}, not one CEF tab per pane")
        # The grid's own steps: a refused or empty split, or a refused equalizeSplits, is another layout.
        layout = [r for r in self.refusals if r.startswith(("splitRight", "splitDown", "equalizeSplits"))]
        return {"workspaces": len(workspaces), "measured": getattr(self, "measured", None),
                "shown_columns": self.shown_columns(window), "window": window.get("frame"),
                "screen_visible_frame": window.get("screen_visible_frame"),
                **window_on_screen(on_screen),
                "grid_problems": grid_problems(window),
                "measured_panes": len(self.panes(measured)), "measured_columns": len(columns) or None,
                "measured_tabs": kinds, "busy_terminals": self.live_busy(measured), "busy_where": self.busy_where,
                "selected": self.selected,
                "chromium_workspaces": sum(1 for pages in background if pages >= CHROMIUM_PER_WORKSPACE),
                "chat_fallbacks": self.chat_fallbacks, "chat_fallback_ok": self.allow_chat_fallback, "refusals": self.refusals[:10], "layout_refusals": layout[:6],
                "pane_problems": pane_problems[:6], "background_chromium": background, "chromium_unavailable": unavailable[:4]}


def topology_kinds(asked, fallback):
    """The `snapshot.get` tab kinds a tab asked as `asked` may have: a terminal, a browser tab for Chromium
    and WebKit, an agent chat (`conversation`), or the New Tab page for a counted chat fallback: an agent tab
    showing the page (`conversation`, PaneController.newTabPage), or a store page tab (`page`)."""
    if asked == "terminal":
        return {"terminal"}
    if asked in ("chromium", "webkit"):
        return {"browser"}
    return {"page", "conversation"} if fallback else {"conversation"}


def cef_problems(cef, web_dev_config=None):
    """Why `debug.cef` says the pages may not be Chromium: an error, an unavailable reason (notBundled,
    downloading, downloadFailed, startFailed, shutDown), any WebKit fallback so far, a start state other
    than `ready`, or a dev-server `web_dev_config` file on this host (measurement validity, perf-lead brief)."""
    if not isinstance(cef, dict):
        return [f"debug.cef answered {str(cef)[:80]}"]
    problems = []
    if cef.get("error") or cef.get("unavailable"):
        problems.append(f"unavailable: {str(cef.get('error') or cef.get('unavailable'))[:160]}")
    if cef.get("fallback"):
        problems.append(f"WebKit fallbacks: {str(cef.get('fallback'))[:160]}")
    if cef.get("state") != "ready":
        problems.append(f"Chromium state {cef.get('state')}, not ready")
    if web_dev_config and os.path.exists(web_dev_config):
        problems.append(f"{web_dev_config} points pages at a dev server")
    return problems


def provisional(tab):
    """Whether `tab` (a snapshot.get tab) is the app's stand-in for a tab the daemon does not have yet
    (ProvisionalTab.idPrefix): no action can name it."""
    return str(tab.get("id") or "").startswith(PROVISIONAL_TAB)


def typed_refusal(reply):
    """True when `reply` is the app's typed refusal of an action (an error object with a `code`), not a
    transport error (a socket timeout or a closed connection is a string)."""
    error = reply.get("error") if isinstance(reply, dict) else None
    return isinstance(error, dict) and bool(error.get("code"))


def window_target(reply):
    """WINDOW_SIZE on the screen of a `debug.window_frame` reply: centered across its visible frame, its top at
    the visible frame's top (under the menu bar), so only a bottom Dock may cover it. None without the screen
    fields (an app before bb4ac3c2b03)."""
    visible = reply.get("visible_frame") if isinstance(reply, dict) else None
    if not visible:
        return None
    vx, vy, vw, vh = visible
    width, height = WINDOW_SIZE
    return [round(vx + (vw - width) / 2), round(vy + vh - height), width, height]


def place_window(rpc):
    """Puts the app's window at WINDOW_SIZE on the main screen (`window_target`). Returns the last
    `debug.window_frame` reply and why the window cannot hold STRESS there (`window_problem`), or None."""
    # Onto the main screen (NSScreen.screens[0], the menu-bar screen) first, so the reply names its frames.
    first = rpc("debug.window_frame", {"screen": 0})
    if not isinstance(first, dict) or first.get("error"):
        return first, f"debug.window_frame: {str(first)[:160]}"
    target = window_target(first) or [*LEGACY_ORIGIN, *WINDOW_SIZE]
    reply = rpc("debug.window_frame", {"frame": target})
    if not isinstance(reply, dict) or reply.get("error"):
        return reply, f"debug.window_frame: {str(reply)[:160]}"
    return reply, window_problem(reply)


def window_problem(reply):
    """Why the window cannot hold STRESS, or None: from a `debug.window_frame` reply (or a `debug.layers`
    window as {frame, visible_frame, screen_frame}), the window is not WINDOW_SIZE (1 pt of rounding
    allowed), or it does not lie on its screen: past the visible frame's left, right or top (a side Dock,
    the menu bar) or past the screen's bottom edge. A bottom Dock over its lower edge is allowed
    (`dock_overlap`). Without the screen fields (an app before bb4ac3c2b03) only the size is checked."""
    frame = reply.get("frame") if isinstance(reply, dict) else None
    visible = reply.get("visible_frame") if isinstance(reply, dict) else None
    screen = reply.get("screen", "?") if isinstance(reply, dict) else "?"
    if not frame:
        return f"the app gave no window frame ({str(reply)[:120]})"
    if abs(frame[2] - WINDOW_SIZE[0]) > 1 or abs(frame[3] - WINDOW_SIZE[1]) > 1:
        return (f"the window is {frame[2:]} pt, not {list(WINDOW_SIZE)}: the display ({screen}) cannot hold STRESS "
                f"(frame {frame}, visible frame {visible}, screen {reply.get('screen_frame')}). {display_advice(reply)}")
    if not visible:
        return None
    x, y, w, h = frame
    vx, vy, vw, vh = visible
    bottom = (reply.get("screen_frame") or visible)[1]
    if x < vx - 1 or x + w > vx + vw + 1 or y + h > vy + vh + 1 or y < bottom - 1:
        return (f"the window {frame} reaches past its screen (visible frame {visible}, screen "
                f"{reply.get('screen_frame')}, {screen})")
    return None


def display_advice(reply):
    """What the display gave and the remedy: AppKit keeps a window inside its screen's visible frame (under the
    menu bar, beside the Dock), so STRESS needs a visible frame of at least WINDOW_SIZE."""
    visible, screen = reply.get("visible_frame"), reply.get("screen_frame")
    if not visible or not screen:
        return f"Run on a display whose visible frame is at least {WINDOW_SIZE[0]} x {WINDOW_SIZE[1]} pt."
    sx, sy, sw, sh = screen
    vx, vy, vw, vh = visible
    gaps = {"bottom": vy - sy, "left": vx - sx, "right": (sx + sw) - (vx + vw)}
    edge = max(gaps, key=gaps.get)
    dock = f"the Dock at the {edge} takes {round(gaps[edge])} pt" if gaps[edge] > 4 else "the Dock is hidden"
    return (f"Display {round(sw)} x {round(sh)} pt, visible frame {round(vw)} x {round(vh)} pt ({dock}). Remedy: a "
            f"display whose visible frame is at least {WINDOW_SIZE[0]} x {WINDOW_SIZE[1]} pt: on the fleet a 1920x1200 "
            f"virtual display (split-spring.sh --vdisplay=120 with vdisplay.m's WIDTHxHEIGHT argument; this script's "
            f"--vdisplay asks for 1920x1200 itself).")


def dock_overlap(reply):
    """Points of the window's lower edge under a bottom Dock (the visible frame starts above the screen's
    bottom), or None without the screen fields."""
    frame, visible = reply.get("frame"), reply.get("visible_frame")
    if not frame or not visible or not reply.get("screen_frame"):
        return None
    return max(0, round(visible[1] - frame[1]))


def window_on_screen(reply):
    """The summary's window fields: `window_problem`, `window_on_screen` (yes, no, or unknown without the
    screen fields: then only the size and the debug.layers pane frames are checked) and `dock_overlap_pt`
    (a bench condition)."""
    problem = window_problem(reply)
    state = "unknown" if not reply.get("visible_frame") else ("no" if problem else "yes")
    return {"window_problem": problem, "window_on_screen": state, "dock_overlap_pt": dock_overlap(reply)}


# Equal shares differ only by divider and point rounding (a few points); the uneven grids this check
# exists for (a split sized without the even sizing: rows 1/2, 1/4, 1/4) are a factor 2 apart.
EVEN_TOLERANCE = 0.1


def grid_problems(window):
    """Why the measured grid is not even, from the pane frames `debug.layers` reports (planes' rings,
    one per displayed pane, window points): not 14 panes, not 4 columns, columns of unequal width, or a
    column whose panes are not COLUMNS' row count (ROWS, ROWS + 1 in NESTED_COLUMNS) of equal height."""
    frames = {}
    for plane in window.get("planes") or []:
        for ring in plane.get("rings") or []:
            if ring.get("pane") and ring.get("frame_in_window"):
                frames[ring["pane"]] = ring["frame_in_window"]
    want = COLUMNS * ROWS + len(NESTED_COLUMNS)
    if len(frames) != want:
        return [f"{len(frames)} pane frames in debug.layers, not {want}"]
    columns = {}
    for x, y, w, h in frames.values():
        columns.setdefault(round(x), []).append((w, h))
    if len(columns) != COLUMNS:
        return [f"pane frames start at {len(columns)} x positions, not {COLUMNS} columns"]

    def even(values):
        return max(values) - min(values) <= EVEN_TOLERANCE * max(values)
    problems = []
    cells = [column for _, column in sorted(columns.items())]
    widths = [round(max(w for w, _ in column)) for column in cells]
    if not even(widths):
        problems.append(f"column widths {widths} pt are not even")
    for index, column in enumerate(cells):
        rows = ROWS + (1 if index in NESTED_COLUMNS else 0)
        heights = [round(h) for _, h in column]
        if len(column) != rows or not even(heights):
            problems.append(f"column {index + 1} rows {sorted(heights)} pt, not {rows} even rows")
    return problems


class StressShapeError(RuntimeError):
    """The session built is not the STRESS shape."""


def start_vdisplay(hz, out, hold):
    """A 1920 x 1200 virtual main display at `hz` (vdisplay.m, compiled here), held at most `hold` seconds
    (the helper ends by itself then, even when this script is killed); returns its process once it is
    ready and main, or raises StressShapeError with the helper's line."""
    import subprocess
    root = os.path.dirname(os.path.dirname(HERE))
    folder = os.path.join(out, "vdisplay", "VDisplay.app", "Contents", "MacOS")
    os.makedirs(folder, exist_ok=True)
    binary = os.path.join(folder, "VDisplay")
    build = subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wno-deprecated-declarations", "-framework", "AppKit",
                            "-framework", "CoreVideo", os.path.join(root, "scripts/ci/frame-pacing/vdisplay.m"), "-o", binary],
                           capture_output=True, text=True)
    if build.returncode:
        raise StressShapeError(f"the virtual display helper did not compile: {build.stderr[:300]}")
    import shutil
    shutil.copy(os.path.join(root, "scripts/ci/frame-pacing/VDisplay-Info.plist"),
                os.path.join(out, "vdisplay", "VDisplay.app", "Contents", "Info.plist"))
    log = open(os.path.join(out, "vdisplay", "out"), "w")
    process = subprocess.Popen(vdisplay_command(binary, hz, hold), stdout=log, stderr=subprocess.STDOUT)
    line = wait(lambda: next((l for l in open(log.name) if l.startswith(("ready", "error"))), None), 30, step=0.5)
    problem = vdisplay_problem(line)
    if problem:
        process.terminate()  # the helper this script started, by its process
        raise StressShapeError(f"the virtual display did not come up as main: {problem} "
                               f"({open(log.name).read()[-300:].strip()})")
    print(f"stress: virtual display {line.strip()}", flush=True)
    return process


# The builder's virtual display: 1920 x 1200 leaves a visible frame over 1000 pt under the menu bar and a
# bottom Dock (1920 x 1080 gave 965 pt: AppKit keeps windows inside the visible frame). A vdisplay.m without the
# WIDTHxHEIGHT argument ignores it and makes 1920 x 1080; the window check then says so.
VDISPLAY_SIZE = "1920x1200"


def vdisplay_command(binary, hz, hold):
    """The helper's argv: rate, hold, main, size."""
    return [binary, str(hz), str(int(hold)), "main", VDISPLAY_SIZE]


def vdisplay_problem(line):
    """Why the helper's line is not a ready virtual main display, or None. The helper prints
    `ready DISPLAY_ID p50_ms main=MAIN_ID` even when making it main failed (the CGError goes to stderr),
    so the main display's id must be the virtual display's."""
    parts = (line or "").split()
    if not parts or parts[0] != "ready" or len(parts) < 4:
        return f"helper said {line!r}"
    main = next((p[len("main="):] for p in parts if p.startswith("main=")), None)
    if main != parts[1]:
        return f"the main display is {main}, not the virtual display {parts[1]}"
    return None


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
    parser.add_argument("--vdisplay", type=float, default=0,
                        help="with --app: first make a 1920 x 1080 virtual main display at this refresh (Hz), as "
                             "split-spring.sh --vdisplay does (scripts/ci/frame-pacing/vdisplay.m)")
    parser.add_argument("--vdisplay-hold", type=float, default=1200,
                        help="the virtual display helper's own lifetime in seconds (default 1200, as split-spring.sh): "
                             "it ends by itself when this script is killed and cannot clean up")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    app = display = None
    # A fleet cancel or timeout sends SIGTERM (an SSH drop SIGHUP): exit through the finally below, so the
    # app and the virtual display this script started end with it. SIGKILL cannot be caught; the
    # helper's hold bounds that case.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    try:
        if opts.app and opts.vdisplay:
            display = start_vdisplay(opts.vdisplay, opts.out, opts.vdisplay_hold)
        if opts.app:
            app = load_activation_app()(os.path.abspath(opts.app), opts.out, 50)
            app.launch()
            rpc = app.rpc
        else:
            rpc = socket_rpc(opts.socket)
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
        if display and not opts.keep:
            display.terminate()  # the helper this script started, by its process

if __name__ == "__main__":
    main()
