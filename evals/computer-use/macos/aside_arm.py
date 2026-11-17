# SPDX-License-Identifier: MIT
"""bgx.py: bgmatrix.py with an `aside` arm (Aside Computer Use 1.26.1111.1046, `aside mcp --computer-use`).

  python3 bgx.py --arm aside --reps 3 --out DIR      (in a guest GUI session, through gr.sh)

Aside exposes one MCP tool, `repl`, whose JavaScript drives a `computer` API. Each harness action maps to the
smallest repl call an agent would make for it (same observation calls as the other arms: a fresh state before
acting on element ids, a screenshot before pixel actions). Everything else (scene, person fixture, 15 ms invariant
sampling, z-order, effect read-back) is bgmatrix.py unchanged.

Aside's state outline has no element frames. Pixel cells need a point to aim at, so for those the node's frame is
joined from the harness's own AX probe (same role and name), converted to the latest screenshot's pixels; the cmux
and cua-driver arms take frames from their own trees. Noted in the report.
"""
from __future__ import annotations

import base64
import json
import os
import re
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bgmatrix as bm  # noqa: E402
from cueval.mcp import McpClient  # noqa: E402

ASIDE_MCP = os.path.join(bm.HOME, "cu/aside-mcp.sh")

# Aside role words (AX role descriptions) -> the harness's normalized roles
ROLE_WORDS = [
    ("standard window", "window"), ("dialog", "window"), ("floating window", "window"),
    ("text entry area", "textarea"), ("search text field", "searchfield"), ("secure text field", "textfield"),
    ("text field", "textfield"), ("pop up button", "popupbutton"), ("menu button", "menubutton"),
    ("toggle button", "button"), ("radio button", "radiobutton"), ("check box", "checkbox"), ("checkbox", "checkbox"),
    ("increment arrow button", "button"), ("decrement arrow button", "button"), ("stepper", "stepper"),
    ("secure text field", "textfield"), ("tab", "tab"), ("popover", "popover"),
    ("close button", "closebutton"), ("minimise button", "minimizebutton"), ("minimize button", "minimizebutton"),
    ("full screen button", "fullscreenbutton"), ("zoom button", "zoombutton"), ("button", "button"),
    ("menu bar item", "menubaritem"), ("menu bar", "menubar"), ("menu item", "menuitem"), ("menu", "menu"),
    ("outline row", "row"), ("table row", "row"), ("row", "row"), ("cell", "cell"), ("column", "column"), ("outline", "outline"),
    ("table", "table"), ("list", "list"), ("scroll area", "scrollarea"), ("scroll bar", "scrollbar"),
    ("slider", "slider"), ("tab group", "tabgroup"), ("toolbar", "toolbar"), ("group", "group"),
    ("split group", "splitgroup"), ("splitter", "splitter"), ("image", "image"), ("heading", "heading"),
    ("HTML content", "webarea"), ("web area", "webarea"), ("link", "link"), ("text", "text"),
    ("sheet", "sheet"), ("alert", "sheet"), ("disclosure triangle", "disclosuretriangle"),
    ("browser", "browser"), ("grid", "grid"), ("collection", "list"), ("tab", "tab"),
]
LINE = re.compile(r"^(?P<ind>\s*)(?:[~+]\s+)?\[(?P<id>\d+)\]\s*(?P<rest>.*)$")


def parse_outline(text):
    """Aside's state text -> nodes {key, role, name, value, ident, actions, flags, depth, menu_path}."""
    out, menu_stack = [], []
    for raw in text.splitlines():
        m = LINE.match(raw)
        if not m:
            continue
        rest = m["rest"]
        fields, pos, cut = {}, 0, None
        found = []
        for key in ("Value", "Help", "ID", "Shortcut", "Secondary Actions"):
            mm = re.compile(r"(?:^|,? )" + key + r": ").search(rest, pos)
            if mm:
                found.append((key, mm))
                pos = mm.end()
        for i, (key, mm) in enumerate(found):
            end = found[i + 1][1].start() if i + 1 < len(found) else len(rest)
            fields[key] = rest[mm.end():end]
        if found:
            rest = rest[:found[0][1].start()]
        flags = []
        for fm in re.finditer(r"\s*\(([a-z, ]+)\)", rest):
            flags += [f.strip() for f in fm.group(1).split(",")]
        rest = re.sub(r"\s*\([a-z, ]+\)", "", rest).strip()
        role, name = "unknown", rest
        for words, norm in ROLE_WORDS:
            if rest == words or rest.startswith(words + " "):
                role, name = norm, rest[len(words):].strip()
                break
        depth = len(m["ind"])
        node = {"key": int(m["id"]), "role": role, "name": name, "value": fields.get("Value"),
                "ident": fields.get("ID"), "actions": [a.strip() for a in fields.get("Secondary Actions", "").split(",") if a.strip()],
                "flags": flags, "depth": depth, "frame": None, "raw": raw.strip()}
        while menu_stack and menu_stack[-1][0] >= depth:
            menu_stack.pop()
        if role in ("menubaritem", "menuitem", "menu") or (menu_stack and role == "unknown"):
            menu_stack.append((depth, name))
        node["menu_path"] = [n for _, n in menu_stack]
        out.append(node)
    return out


def img_size(b):
    if not b:
        return None
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", b[16:24])
    if b[:2] == b"\xff\xd8":  # JPEG: walk to the first SOF marker
        i = 2
        while i < len(b) - 9:
            if b[i] != 0xFF:
                i += 1
                continue
            marker = b[i + 1]
            ln = struct.unpack(">H", b[i + 2:i + 4])[0]
            if marker in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack(">HH", b[i + 5:i + 9])
                return (w, h)
            i += 2 + ln
    return None


KEYMAP = {"cmd": "Super_L", "shift": "Shift_L", "alt": "Alt_L", "option": "Alt_L", "ctrl": "Control_L"}
KEYNAMES = {"return": "Return", "escape": "Escape", "up": "Up", "down": "Down", "left": "Left", "right": "Right",
            "tab": "Tab", "+": "plus"}

APP_NAMES = {"te.txt": "TextEdit", "Calculator": "Calculator", "CUEV Page": "Safari", "finder": "Finder"}


def probe_title_matches(ptitle, w):
    """A probe window title names Aside's window w: equal, or w's title is its prefix ("Notes" for "Notes – 4 notes"),
    or w has no title (System Settings) and the probe window is a real one (not the 66x20 "Window")."""
    t = w["title"]
    if t:
        return ptitle == t or ptitle.startswith(t + " ")
    return ptitle not in ("", "Window")


def js(s):
    return json.dumps(s)


class Aside(bm.Arm):
    def __init__(self, arm_id, log_dir):
        self.id = arm_id
        self.client = McpClient([ASIDE_MCP], stderr_path=os.path.join(log_dir, f"{arm_id}.server.stderr"))
        self.client.initialize()
        self.client.list_tools()
        self.calls = []
        self.handles = {}  # app name -> (JS variable, pid)
        self.gen = 0
        self.shot_scale = {}  # wid -> (sx, sy) screenshot px per window point
        self.win_origin = {}

    # -- plumbing
    def repl(self, code, title=None, timeout=90):
        a = {"code": code}
        if title:
            a["title"] = title
        r = self.call("repl", a, timeout=timeout)
        if r.is_error or re.match(r"^\s*(Uncaught\s+)?Error\b", r.text() or ""):
            raise bm.ToolError((r.text() or "")[:400])
        return r

    def h(self, app):
        """The JS handle for app: getApp once per process (the guide: getApp again returns the same handle);
        a relaunched app (new pid) is acquired again under a new variable."""
        pid = bm.app_pid(app) if app != "Python" else self.tk_pid()
        held = self.handles.get(app)
        if held and held[1] == pid:
            return held[0]
        self.gen += 1
        var = "h" + re.sub(r"\W", "", app) + str(self.gen)
        target = js(app)
        if app == "Python":  # two Python apps run (the person and the Tk form): target the form by pid
            target = "{ appId: %s, access: 'control' }" % js(self.tk_app_id())
        else:
            target = "{ name: %s, access: 'control' }" % target
        self.repl(f"globalThis.{var} = await computer.getApp({target});", title=f"Get {app}")
        self.handles[app] = (var, pid)
        return var

    def tk_pid(self):
        out = bm.sh("pgrep -f 'fixture_app.py --mode form'").stdout.split()
        return int(out[0]) if out else None

    def tk_app_id(self):
        """Two Python apps run (the person fixture and the Tk form); listApps has no pid, so read each
        Python app's windows (read access) and take the one showing the form."""
        r = self.repl("console.log(JSON.stringify(await computer.listApps({ emit: false })));", title="List apps")
        apps = json.loads(r.text().strip().splitlines()[-1])
        for a in apps:
            if "python" not in (a.get("name") or "").lower():
                continue
            r = self.repl("{ const t = await computer.getApp({ appId: %s, access: 'read' }); "
                          "console.log(JSON.stringify(await t.listWindows({ emit: false }))); }" % js(a["appId"]),
                          title="Read Python windows")
            if "CU Eval Form" in r.text():
                return a["appId"]
        raise bm.ToolError(f"no Python app shows CU Eval Form: {json.dumps(apps)[:300]}")

    # -- windows
    def windows(self):
        out = []
        apps = [CURRENT["app"]] if CURRENT.get("app") else []
        for app in apps:
            try:
                var = self.h(app)
                r = self.repl(f"console.log(JSON.stringify(await {var}.listWindows({{ emit: false }})));", title="List windows")
            except bm.ToolError:
                continue
            txt = r.text().strip()
            try:
                ws = json.loads(txt.splitlines()[-1])
            except ValueError:
                ws = []
            for d in ws if isinstance(ws, list) else []:
                aw = str(d.get("windowId", d.get("id")))
                wid = int(aw[1:]) if re.fullmatch(r"w\d+", aw) else aw  # Aside's "w105" is CGWindowID 105
                out.append({"wid": wid, "aside_wid": aw, "pid": bm.app_pid(app) if app != "Python" else self.tk_pid(),
                            "title": d.get("title") or "", "app": app, "aside_app": app, "raw": d})
        return out

    def _select(self, w):
        """Select w as the handle's window (state follows it) and return the full, undiffed state text."""
        var = self.h(w["aside_app"])
        r = self.repl(f"console.log(await {var}.getAXState({{ windowId: {js(w['aside_wid'])}, disableDiffing: true, emit: false }}));",
                      title="Read window")
        return r.text()

    def screenshot(self, w):
        var = self.h(w["aside_app"])
        self._select(w)
        r = self.repl(f"await {var}.getScreenshot();", title="Screenshot")
        img = base64.b64decode(r.images[0]["data"]) if r.images else None
        sz = img_size(img)
        geo = self._geometry(w)
        if sz and geo:
            self.shot_scale[str(w["wid"])] = (sz[0] / geo[2], sz[1] / geo[3])
        self.calls.append({"tool": "_harness_geometry", "args": {"wid": w["wid"]}, "is_error": False, "s": 0,
                           "result": json.dumps({"shot": sz, "geo": geo, "aside_bounds": (w.get("raw") or {}).get("bounds")}),
                           "images": 0})
        return img

    def _geometry(self, w):
        """The target window's screen frame in points, from the harness probe (the frame space of its AX nodes);
        Aside's listWindows bounds as a fallback."""
        pid = w.get("pid")
        if pid:
            _, d = bm.ax_nodes(pid, 1)
            for win in d.get("windows", []):
                if probe_title_matches(win.get("title") or "", w):
                    p, s = win.get("pos") or {}, win.get("size") or {}
                    return p.get("x", 0), p.get("y", 0), s.get("w", 1), s.get("h", 1)
        b = (w.get("raw") or {}).get("bounds")
        if b:
            return b["x"], b["y"], b["width"], b["height"]
        return None

    def tree(self, w):
        nodes = parse_outline(self._select(w))
        self._join_frames(w, nodes)
        return nodes

    def _join_frames(self, w, nodes):
        """Attach window-local screenshot-pixel frames from the harness probe (same role + name, in order)."""
        geo = self._geometry(w)
        pid = w.get("pid")
        if not geo or not pid:
            return
        sx, sy = self.shot_scale.get(str(w["wid"]), (1.0, 1.0))
        ax, _ = bm.ax_nodes(pid, 40)
        pool = {}
        for n in ax:
            if not probe_title_matches(n.get("_win") or "", w):
                continue
            p, s = n.get("pos"), n.get("size")
            if not p or not s:
                continue
            role = bm.norm_role(n.get("role"))
            role = {"statictext": "text", "outlinerow": "row"}.get(role, role)
            names = {str(n.get(k)) for k in ("title", "desc", "value") if n.get(k) not in (None, "")}
            pool.setdefault(role, []).append((names, {"x": (p["x"] - geo[0]) * sx, "y": (p["y"] - geo[1]) * sy,
                                                      "width": s["w"] * sx, "height": s["h"] * sy}))
        used = set()
        for nd in nodes:
            cands = pool.get(nd["role"], [])
            for i, (names, fr) in enumerate(cands):
                if (nd["role"], i) in used:
                    continue
                if (nd["name"] and nd["name"] in names) or (nd["value"] and str(nd["value"]) in names) or (not nd["name"] and not names):
                    nd["frame"] = fr
                    used.add((nd["role"], i))
                    break
            if nd["frame"] is None and nd["name"]:
                # a container whose label is its child (a sidebar row and its text): the frame of the probe node of
                # any role that carries the name (the label sits inside the container, so its center hits it)
                for role2, cands2 in pool.items():
                    hit = next((fr for names, fr in cands2 if nd["name"] in names), None)
                    if hit:
                        nd["frame"] = hit
                        break
            if nd["frame"] is None and not nd["name"]:
                # unnamed node (e.g. a text area whose value Aside abbreviates): the next unused node of its role
                for i, (names, fr) in enumerate(cands):
                    if (nd["role"], i) not in used:
                        nd["frame"] = fr
                        used.add((nd["role"], i))
                        break

    # -- actions
    def click_el(self, w, n, **kw):
        var = self.h(w["aside_app"])
        return self.repl(f"await {var}.click({n['key']}); await {var}.getAXState();", title="Click")

    def click_px(self, w, x, y):
        var = self.h(w["aside_app"])
        self.screenshot(w)
        return self.repl(f"await {var}.click([{round(x)}, {round(y)}]);", title="Click point")

    def type_text(self, w, text, n=None):
        var = self.h(w["aside_app"])
        pre = f"await {var}.click({n['key']}); " if n else ""
        return self.repl(f"{pre}await {var}.typeText({js(text)});", title="Type")

    def press_key(self, w, keys):
        var = self.h(w["aside_app"])
        parts = keys.split("+") if keys != "+" else ["+"]
        mapped = [KEYMAP.get(p.lower(), KEYNAMES.get(p.lower(), p)) for p in parts]
        return self.repl(f"await {var}.pressKey({js('+'.join(mapped))});", title="Press key")

    def scroll(self, w, x=None, y=None, dy=5, n=None):
        var = self.h(w["aside_app"])
        pages = max(1, round(abs(dy) / 5))
        direction = "down" if dy > 0 else "up"
        if n:
            return self.repl(f"await {var}.scroll({n['key']}, '{direction}', {pages});", title="Scroll")
        self.screenshot(w)
        return self.repl(f"await {var}.scroll([{round(x)}, {round(y)}], '{direction}', {pages});", title="Scroll")

    def drag(self, w, fx, fy, tx, ty):
        var = self.h(w["aside_app"])
        self.screenshot(w)
        return self.repl(f"await {var}.drag([{round(fx)}, {round(fy)}], [{round(tx)}, {round(ty)}]);", title="Drag")

    def set_value(self, w, n, value):
        var = self.h(w["aside_app"])
        return self.repl(f"await {var}.setValue({n['key']}, {js(value)});", title="Set value")

    def menu(self, w, path):
        var = self.h(w["aside_app"])
        nodes = self.tree(w)
        top = next((n for n in nodes if n["role"] in ("menubaritem", "unknown") and n["name"] == path[0]
                    and any(p["role"] == "menubar" for p in nodes)), None)
        if top is None:
            raise bm.ToolError(f"menu bar item {path[0]} not in state")
        r = self.repl(f"await {var}.click({top['key']}); console.log(await {var}.getAXState({{ emit: false, disableDiffing: true }}));",
                      title=f"Open {path[0]} menu")
        items = parse_outline(r.text())
        for name in path[1:]:
            it = next((n for n in items if n["name"] == name), None)
            if it is None:
                self.repl(f"await {var}.pressKey('Escape');", title="Escape menu")
                raise bm.ToolError(f"menu item {name} not in the open menu")
            r = self.repl(f"await {var}.click({it['key']}); console.log(await {var}.getAXState({{ emit: false, disableDiffing: true }}));",
                          title=f"Click {name}")
            items = parse_outline(r.text())
        return r


CURRENT = {}
AP_NAME = {"textedit": "TextEdit", "calculator": "Calculator", "safari": "Safari", "finder": "Finder", "notes": "Notes",
           "settings": "System Settings", "tk": "Python"}


def _wrap(key, entry):
    setup, pick, cells = entry

    def setup2(ctx):
        CURRENT["app"] = AP_NAME[key]
        return setup(ctx)
    return (setup2, pick, cells)


for _k in list(bm.APPS):
    bm.APPS[_k] = _wrap(_k, bm.APPS[_k])

_orig_make_arm = bm.make_arm


def make_arm(arm_id, log_dir):
    return Aside(arm_id, log_dir) if arm_id.startswith("aside") else _orig_make_arm(arm_id, log_dir)


bm.make_arm = make_arm
bm.png_size = img_size  # screenshot cells: Aside returns JPEG


def calc_width(pid):
    """Read back the Calculator window's width by title: during Aside's actions a 66x20 window titled "Window"
    can be first in the app's AX window list, which bgmatrix's calc_width would read instead."""
    _, d = bm.ax_nodes(pid, 1)
    for w in d.get("windows", []):
        if w.get("title") == "Calculator":
            return (w.get("size") or {}).get("w")
    return None


bm.calc_width = calc_width

if __name__ == "__main__":
    bm.main()
