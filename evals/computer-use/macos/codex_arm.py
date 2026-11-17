# SPDX-License-Identifier: MIT
"""codex_arm.py: the Codex Computer Use arm for bgmatrix.py and truthmatrix.py (no model).

  python3 codex_arm.py --arm codex-cu --reps 3 --out DIR          (the background matrix, in a guest GUI session)
  python3 codex_truth.py --arm codex-cu --reps 3 --out DIR        (the truth matrix)

Codex Computer Use is the MCP server inside `Codex Computer Use.app` (SkyComputerUseClient mcp). The service accepts
only a host process signed by OpenAI, so, like Codex itself, `codex app-server` hosts the server and every tool runs
through `mcpServer/tool/call` on one ephemeral thread. Same tool calls an agent would make: `get_app_state` before
acting (it starts the app-use session and returns the key window's tree and a screenshot), then the action.

Codex Computer Use addresses an app, not a window: every tool acts on the app's key window. The harness picks a
target window per cell; when that window is not the app's main window, the runner (codex_select_window, before the
scene is arranged, outside the scored action) makes it main through AX without activating the app. An agent would
have to use the app's Window menu instead. Every such selection is recorded in the row's note.

Its state outline has no element frames. Pixel cells need a point to aim at, so (as for the Aside arm) the node's
frame is joined from the harness's own AX probe (same role and name). Its scroll tool takes an element, not a point:
a pixel scroll goes to the innermost scroll area under the point (else the innermost scrollable element).
"""
from __future__ import annotations

import base64
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bgmatrix as bm  # noqa: E402
import aside_arm  # noqa: E402  (registers the aside arm, sets aside_arm.CURRENT["app"] per app)
from cueval.mcp import ToolResult  # noqa: E402

HOME = os.path.expanduser("~")
CODEX = os.environ.get("CODEX_BIN", os.path.join(HOME, ".local/bin/codex"))
SKY = os.environ.get("CODEX_CUA_APP", os.path.join(HOME, ".codex/computer-use/Codex Computer Use.app"))
AXMAIN = os.path.join(HOME, "cu/axmain")
SERVER = "computer-use"

# Codex app argument per harness app name (bundle ids where a name could be ambiguous)
CODEX_APP = {"CU Eval Fixture": "dev.cmux.cueval.fixture", "System Settings": "com.apple.systempreferences",
             "Python": "Python"}

ROLE_WORDS = [("container", "group"), ("text entry area", "textarea"), ("text area", "textarea"),
              ("secure text field", "securetextfield"), ("search text field", "searchfield"),
              ("static text", "text"), ("disclosure triangle", "disclosuretriangle"),
              ("value indicator", "valueindicator"), ("increment arrow", "button"), ("decrement arrow", "button"),
              ("menu bar item", "menubaritem"), ("tab button", "tabbutton")] + aside_arm.ROLE_WORDS
FIELD = re.compile(r"(?:^|,\s|\s)(Description|Value|Help|ID|Placeholder|Shortcut|URL|Secondary Actions|Label|Title): ")
LINE = re.compile(r"^(?P<ind>\t*)(?P<id>\d+) (?P<rest>.*)$")


def parse_state(text):
    """Codex's <app_state> outline -> nodes {key, role, name, value, ident, desc, actions, flags, depth, menu_path}."""
    out, stack = [], []
    body = text.split("<app_state>", 1)[-1]
    in_menubar_depth = None
    for raw in body.splitlines():
        m = LINE.match(raw)
        if not m:
            continue
        rest, depth = m["rest"], len(m["ind"])
        fields, marks = {}, list(FIELD.finditer(rest))
        for i, mm in enumerate(marks):
            end = marks[i + 1].start() if i + 1 < len(marks) else len(rest)
            fields[mm.group(1)] = rest[mm.end():end]
        head = rest[:marks[0].start()] if marks else rest
        flags = []
        for fm in re.finditer(r"\s*\(([a-z, ]+)\)", head):
            flags += [f.strip() for f in fm.group(1).split(",")]
        head = re.sub(r"\s*\([a-z, ]+\)", "", head).strip().rstrip(",")
        role, name = "unknown", head
        for words, norm in ROLE_WORDS:
            if head == words or head.startswith(words + " "):
                role, name = norm, head[len(words):].strip()
                break
        if role == "menubar":
            in_menubar_depth = depth
        elif in_menubar_depth is not None and depth <= in_menubar_depth:
            in_menubar_depth = None
        if in_menubar_depth is not None and depth > in_menubar_depth and role == "unknown":
            role = "menubaritem" if depth == in_menubar_depth + 1 else "menuitem"
        desc = fields.get("Description")
        node = {"key": m["id"], "role": role, "name": name or desc or "", "value": fields.get("Value"),
                "ident": fields.get("ID"), "desc": desc,
                "actions": [a.strip() for a in fields.get("Secondary Actions", "").split(",") if a.strip()],
                "flags": flags, "depth": depth, "frame": None, "raw": raw.strip()}
        while stack and stack[-1][0] >= depth:
            stack.pop()
        if role in ("menubaritem", "menuitem", "menu"):
            stack.append((depth, node["name"]))
        node["menu_path"] = [n for _, n in stack] if role in ("menubaritem", "menuitem") else []
        out.append(node)
    return out


def state_window_title(text):
    m = re.search(r'^Window: "(.*)", App: ', text, re.M)
    return m.group(1) if m else None


class LazyNode(dict):
    """A tree node whose `frame` is joined from the harness probe on first use (the probe walk is slow on big
    windows, and only pixel cells need frames)."""

    def __init__(self, d, ensure):
        super().__init__(d)
        self._ensure = ensure

    def __getitem__(self, k):
        if k == "frame":
            self._ensure()
        return super().__getitem__(k)

    def get(self, k, default=None):
        if k == "frame":
            self._ensure()
        return super().get(k, default)


class AppServerClient:
    """codex app-server over stdio with Codex Computer Use as MCP server `computer-use`; the McpClient interface
    bgmatrix.Arm needs (call -> ToolResult, tools, close)."""

    def __init__(self, stderr_path):
        client = os.path.join(SKY, "Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")
        args = [CODEX, "app-server",
                "-c", f"mcp_servers.{SERVER}.enabled=true",
                "-c", f"mcp_servers.{SERVER}.command={json.dumps(client)}",
                "-c", f'mcp_servers.{SERVER}.args=["mcp"]',
                "-c", f"mcp_servers.{SERVER}.cwd={json.dumps(os.path.dirname(SKY))}",
                "-c", f"mcp_servers.{SERVER}.startup_timeout_sec=60",
                "-c", f"mcp_servers.{SERVER}.tool_timeout_sec=120"]
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(stderr_path, "ab"), text=True, bufsize=1)
        self.inbox, self.next_id, self.lock = queue.Queue(), 0, threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()
        self.request("initialize", {"clientInfo": {"name": "cueval-codex-arm", "version": "1"},
                                    "capabilities": {"experimentalApi": True}})
        self._write({"method": "initialized", "params": {}})
        t = self.request("thread/start", {"cwd": HOME, "ephemeral": True, "serviceName": "cueval"}, timeout=120)
        self.thread = (t.get("thread") or {}).get("id")
        if not self.thread:
            raise RuntimeError(f"thread/start returned no thread: {t}")
        self.tools = []
        st = self.request("mcpServerStatus/list", {}, timeout=120)
        for s in st.get("data", []):
            if s.get("name") == SERVER:
                self.tools = list((s.get("tools") or {}).values())
                self.server_version = (s.get("serverInfo") or {}).get("version")

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if line:
                try:
                    self.inbox.put(json.loads(line))
                except ValueError:
                    pass

    def _write(self, msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params, timeout=90):
        with self.lock:
            self.next_id += 1
            rid = self.next_id
            self._write({"id": rid, "method": method, "params": params})
            deadline = time.time() + timeout
            while time.time() < deadline:
                if self.proc.poll() is not None:
                    raise RuntimeError(f"codex app-server exited {self.proc.returncode}")
                try:
                    msg = self.inbox.get(timeout=0.5)
                except queue.Empty:
                    continue
                if msg.get("id") == rid and ("result" in msg or "error" in msg):
                    if "error" in msg:
                        raise RuntimeError(json.dumps(msg["error"])[:400])
                    return msg["result"]
                if msg.get("method") and msg.get("id") is not None:
                    self._write({"id": msg["id"], "result": {}})  # a server request (approval): acknowledge
            raise TimeoutError(f"{method} timed out after {timeout:.0f}s")

    def initialize(self):
        return {}

    def list_tools(self):
        return self.tools

    def call(self, name, arguments, timeout=90):
        r = self.request("mcpServer/tool/call", {"threadId": self.thread, "server": SERVER, "tool": name,
                                                 "arguments": arguments}, timeout=timeout)
        return ToolResult(r)

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


KEYS = {"cmd": "super", "command": "super", "shift": "shift", "alt": "alt", "option": "alt", "ctrl": "ctrl"}
KEYNAMES = {"return": "Return", "escape": "Escape", "tab": "Tab", "up": "Up", "down": "Down", "left": "Left",
            "right": "Right", "space": "space", "+": "plus"}
SCROLLABLE = ("scrollarea", "table", "outline", "list", "textarea", "webarea", "browser", "grid", "group")


class Codex(aside_arm.Aside):
    def __init__(self, arm_id, log_dir):  # noqa: super().__init__ starts Aside's server; not wanted here
        self.id = arm_id
        self.client = AppServerClient(os.path.join(log_dir, f"{arm_id}.server.stderr"))
        self.calls = []
        self.shot_scale = {}
        self.last = {}  # app -> (state text, nodes)
        self.selected = []

    def app_arg(self, app):
        return CODEX_APP.get(app, app)

    def state(self, app):
        r = self.call("get_app_state", {"app": self.app_arg(app)})
        if r.is_error:
            raise bm.ToolError(r.text()[:400])
        return r

    # -- windows
    def windows(self):
        """The app's windows as the harness probe sees them (Codex has no window list), with CGWindow ids."""
        app = aside_arm.CURRENT.get("app")
        if not app:
            return []
        pid = bm.app_pid(app) if app != "Python" else self.tk_pid()
        if not pid:
            return []
        _, d = bm.ax_nodes(pid, 1)
        cg = bm.probe("wins", pid)
        cg = cg if isinstance(cg, list) else cg.get("windows", []) if isinstance(cg, dict) else []
        out = []
        for win in d.get("windows", []):
            t = win.get("title") or ""
            wid = next((x.get("id") for x in cg if (x.get("name") or "") == t and x.get("layer", 0) == 0), None)
            out.append({"wid": wid if wid is not None else f"ax:{t}", "pid": pid, "title": t,
                        "app": "System Settings" if app == "System Settings" else app, "aside_app": app})
        return out

    def _look(self, w):
        r = self.state(w["aside_app"])
        txt = r.text()
        title = state_window_title(txt)
        img = base64.b64decode(r.images[0]["data"]) if r.images else None
        sz = aside_arm.img_size(img)
        geo = self._geometry(w)
        if sz and geo:
            self.shot_scale[str(w["wid"])] = (sz[0] / geo[2], sz[1] / geo[3])
        self.calls.append({"tool": "_harness_geometry", "args": {"wid": w["wid"]}, "is_error": False, "s": 0,
                           "result": json.dumps({"shot": sz, "geo": geo, "codex_window": title}), "images": 0})
        nodes = parse_state(txt)
        join = {"done": False}

        def ensure():
            if not join["done"]:
                join["done"] = True
                self._join_frames(w, nodes)
        nodes = [LazyNode(n, ensure) for n in nodes]
        self.last[w["aside_app"]] = nodes
        return img, nodes

    def screenshot(self, w):
        return self._look(w)[0]

    def tree(self, w):
        return self._look(w)[1]

    def _r(self, r):
        if r.is_error:
            raise bm.ToolError(r.text()[:400])
        return r

    def _a(self, w):
        return self.app_arg(w["aside_app"])

    # -- actions
    def click_el(self, w, n, **kw):
        a = {"app": self._a(w), "element_index": str(n["key"])}
        if kw.get("button"):
            a["mouse_button"] = kw["button"]
        if kw.get("count"):
            a["click_count"] = kw["count"]
        return self._r(self.call("click", a))

    def click_px(self, w, x, y):
        self.screenshot(w)
        return self._r(self.call("click", {"app": self._a(w), "x": round(x, 1), "y": round(y, 1)}))

    def type_text(self, w, text, n=None):
        if n:
            self._r(self.call("click", {"app": self._a(w), "element_index": str(n["key"])}))
        return self._r(self.call("type_text", {"app": self._a(w), "text": text}))

    def press_key(self, w, keys):
        parts = keys.split("+") if keys != "+" else ["+"]
        mapped = [KEYS.get(p.lower(), KEYNAMES.get(p.lower(), p)) for p in parts]
        return self._r(self.call("press_key", {"app": self._a(w), "key": "+".join(mapped)}))

    def scroll(self, w, x=None, y=None, dy=5, n=None):
        pages = max(1, round(abs(dy) / 5))
        direction = "down" if dy > 0 else "up"
        if n is None:
            nodes = self.tree(w)
            n = self._under(nodes, x, y)
            if n is None:
                raise bm.ToolError(f"no scrollable element under ({x}, {y}) in Codex's tree")
        return self._r(self.call("scroll", {"app": self._a(w), "element_index": str(n["key"]),
                                            "direction": direction, "pages": pages}))

    @staticmethod
    def _under(nodes, x, y):
        best = None
        for nd in nodes:
            f = nd.get("frame")
            if not f or nd["role"] not in SCROLLABLE:
                continue
            if f["x"] <= x <= f["x"] + f["width"] and f["y"] <= y <= f["y"] + f["height"]:
                area = f["width"] * f["height"]
                rank = ({"scrollarea": 0, "group": 2}.get(nd["role"], 1), area)
                if best is None or rank < best[0]:
                    best = (rank, nd)
        return best[1] if best else None

    def drag(self, w, fx, fy, tx, ty):
        self.screenshot(w)
        return self._r(self.call("drag", {"app": self._a(w), "from_x": round(fx, 1), "from_y": round(fy, 1),
                                          "to_x": round(tx, 1), "to_y": round(ty, 1)}))

    def set_value(self, w, n, value):
        return self._r(self.call("set_value", {"app": self._a(w), "element_index": str(n["key"]), "value": value}))

    def menu(self, w, path):
        nodes = self.tree(w)
        top = next((n for n in nodes if n["role"] == "menubaritem" and n["name"] == path[0]), None)
        if top is None:
            raise bm.ToolError(f"menu bar item {path[0]} not in Codex's state")
        r = self._r(self.call("click", {"app": self._a(w), "element_index": str(top["key"])}))
        for name in path[1:]:
            items = parse_state(r.text())  # an action's result is the new state (the open menu)
            it = next((n for n in items if n["name"] == name and n["key"] != top["key"]), None)
            if it is None:
                items = self.tree(w)
                it = next((n for n in items if n["name"] == name and n["role"] in ("menuitem", "unknown", "menubaritem")), None)
            if it is None:
                try:
                    self.call("press_key", {"app": self._a(w), "key": "Escape"})
                except bm.ToolError:
                    pass
                raise bm.ToolError(f"menu item {name} not in the open menu")
            r = self._r(self.call("click", {"app": self._a(w), "element_index": str(it["key"])}))
        return r


def select_window(arm, w):
    """Before a Codex cell (outside the scored action and before the scene is arranged): make the target the app's
    main window through AX without activating the app (Codex acts on the key window only). Returns a note."""
    if not isinstance(arm, Codex) or not w or not w.get("pid") or not w.get("title"):
        return ""
    r = subprocess.run([AXMAIN, str(w["pid"]), w["title"]], capture_output=True, text=True, timeout=20)
    try:
        d = json.loads(r.stdout or "{}")
    except ValueError:
        d = {"err": r.stdout[:100]}
    if d.get("changed"):
        arm.selected.append(w["title"])
        return f"harness made {w['title']!r} the app's main window for Codex (was {d.get('was')!r})"
    return ""


_orig_make_arm = bm.make_arm


def make_arm(arm_id, log_dir):
    return Codex(arm_id, log_dir) if arm_id.startswith("codex") else _orig_make_arm(arm_id, log_dir)


bm.make_arm = make_arm

_orig_bm_run_cell = bm.run_cell


def _bm_run_cell(arm, scene, app, action, fn, w, rep, ctx, out):
    note = select_window(arm, w)
    row = _orig_bm_run_cell(arm, scene, app, action, fn, w, rep, ctx, out)
    if note:
        row["codex_window_select"] = note
    return row


bm.run_cell = _bm_run_cell

if __name__ == "__main__":
    bm.main()
