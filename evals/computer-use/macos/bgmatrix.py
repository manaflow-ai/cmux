# SPDX-License-Identifier: MIT
"""bgmatrix.py: the background computer-use matrix on real macOS apps, no model.

  python3 bgmatrix.py --arm cmux-cu --reps 3 --apps textedit,calculator,... --out DIR

Runs in a cuev guest's GUI session (gr.sh). Every target window is fully covered by
the "Person" window (the harness's Tk person fixture: frontmost, key, and typing into
its own text field in-process the whole time). For each cell (app x action x rep) the
driver makes the arm's MCP tool calls the action needs (observation included), then
checks, independently of the arm (probe = AX + CGWindowList + CGEvent):

  effect   the target state really changed (read back through AX, the page, or disk)
  front    the frontmost app stayed the person's during the whole action (15 ms samples)
  key      the person's window stayed key (focused window of the front app)
  pointer  the pointer never moved
  keys     the person's field received no key events (leaked keystrokes)
  zorder   the person's window stayed on top and no window changed its stacking order
  raised   the target window was not raised

One JSON row per cell in DIR/matrix.jsonl, with every tool call (args, result head).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import signal
import struct
import subprocess
import sys
import threading
import time
import traceback

HOME = os.path.expanduser("~")
HARNESS = os.path.join(HOME, "cu/evals/computer-use")
sys.path.insert(0, HARNESS)
from cueval import arms as armsmod  # noqa: E402
from cueval.mcp import McpClient  # noqa: E402

PROBE = os.path.join(HOME, "cu/probe")
WORK = os.path.join(HOME, "cu-work")
PY = sys.executable

# ------------------------------------------------------------------ probe


def probe(*args, timeout=20):
    r = subprocess.run([PROBE, *map(str, args)], capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr)[-300:]}


def ax_nodes(pid, depth=40, menus=False):
    d = probe("ax", pid, depth, *(["menus"] if menus else []))
    out = []

    def walk(n, path, win):
        n2 = dict(n)
        kids = n2.pop("children", [])
        n2["_win"] = win
        out.append(n2)
        for k in kids:
            walk(k, path + [n.get("role")], win)

    for w in d.get("windows", []):
        walk(w, [], w.get("title"))
    if menus and d.get("menubar"):
        walk(d["menubar"], [], "__menubar__")
    return out, d


def ax_find(nodes, role=None, win=None, pred=None):
    for n in nodes:
        if role and n.get("role") != role:
            continue
        if win is not None and (n.get("_win") or "") != win:
            continue
        if pred and not pred(n):
            continue
        return n
    return None


class Watcher:
    """probe watch: a line on every change of front app, key window, pointer or top window."""

    def __init__(self):
        self.p = subprocess.Popen([PROBE, "watch", "15"], stdout=subprocess.PIPE, text=True)
        self.lines = []
        self.t = threading.Thread(target=self._read, daemon=True)
        self.t.start()
        deadline = time.monotonic() + 3
        while not self.lines and time.monotonic() < deadline:
            time.sleep(0.01)

    def _read(self):
        for line in self.p.stdout:
            try:
                self.lines.append(json.loads(line))
            except ValueError:
                pass

    def stop(self):
        time.sleep(0.05)
        self.p.terminate()
        try:
            self.p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.p.kill()
        self.t.join(timeout=2)
        return self.lines


# ------------------------------------------------------------------ arms


def norm_role(r):
    r = (r or "").lower()
    r = r[2:] if r.startswith("ax") else r
    return r.replace("_", "")


def png_size(b):
    if not b or b[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", b[16:24])


class Arm:
    def __init__(self, arm_id, log_dir):
        self.id = arm_id
        arm = armsmod.load_arm(arm_id)
        self.client = McpClient(armsmod.server_command(arm), stderr_path=os.path.join(log_dir, f"{arm_id}.server.stderr"))
        self.client.initialize()
        self.client.list_tools()
        self.calls = []

    def call(self, name, args, timeout=90):
        t0 = time.monotonic()
        try:
            r = self.client.call(name, args, timeout=timeout)
            full = r.text()
            rec = {"tool": name, "args": args, "is_error": r.is_error, "s": round(time.monotonic() - t0, 3),
                   "result": full[:1500], "images": len(r.images), "claim_fields": _claim_fields(full)}
        except Exception as e:
            rec = {"tool": name, "args": args, "is_error": True, "s": round(time.monotonic() - t0, 3),
                   "result": f"EXC {type(e).__name__}: {e}"[:1500], "images": 0}
            self.calls.append(rec)
            raise ToolError(rec["result"])
        self.calls.append(rec)
        return r

    def close(self):
        self.client.close()


class ToolError(RuntimeError):
    pass


def _claim_fields(text):
    """outcome / evidence / route / note from the full result, before it is truncated for the record."""
    try:
        d = json.loads(text)
    except (ValueError, TypeError):
        return {}
    if not isinstance(d, dict):
        return {}
    return {k: d[k][:300] for k in ("outcome", "evidence", "route", "note") if isinstance(d.get(k), str)}


def walk_dicts(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from walk_dicts(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk_dicts(v)


class Cmux(Arm):
    def windows(self):
        r = self.call("list_windows", {})
        return [{"wid": str(d["window_id"]), "pid": d.get("pid"), "title": d.get("title") or "", "app": d.get("app_id")}
                for d in walk_dicts(r.data) if "window_id" in d]

    def screenshot(self, w):
        r = self.call("screenshot", {"window_id": w["wid"], "force": True})
        if r.is_error:
            raise ToolError(r.text()[:300])
        return base64.b64decode(r.images[0]["data"]) if r.images else None

    def tree(self, w):
        r = self.call("get_ui_tree", {"window_id": w["wid"], "max_nodes": 5000})
        if r.is_error:
            raise ToolError(r.text()[:300])
        out = []

        def walk(n, menu_path):
            role = norm_role(n.get("role"))
            mp = menu_path + [n.get("name")] if role in ("menubaritem", "menuitem") else menu_path
            out.append({"key": n.get("id"), "role": role, "name": n.get("name") or "", "value": n.get("value"),
                        "frame": n.get("frame"), "actions": n.get("actions") or [], "menu_path": mp})
            for c in n.get("children", []):
                walk(c, mp)

        walk(r.data["root"], [])
        return out

    def _r(self, r):
        if r.is_error:
            raise ToolError(r.text()[:400])
        return r

    def click_el(self, w, n, **kw):
        return self._r(self.call("click", {"window_id": w["wid"], "element_id": n["key"], **kw}))

    def click_px(self, w, x, y):
        self.screenshot(w)  # coordinates are pixels of the latest screenshot of the window
        return self._r(self.call("click", {"window_id": w["wid"], "x": x, "y": y}))

    def type_text(self, w, text, n=None):
        a = {"window_id": w["wid"], "text": text}
        if n:
            a["element_id"] = n["key"]
        return self._r(self.call("type_text", a))

    def press_key(self, w, keys):
        return self._r(self.call("press_key", {"window_id": w["wid"], "keys": keys}))

    def scroll(self, w, x=None, y=None, dy=5, n=None):
        a = {"window_id": w["wid"], "dy": dy}
        if n:
            a["element_id"] = n["key"]
        else:
            self.screenshot(w)
            a.update(x=x, y=y)
        return self._r(self.call("scroll", a))

    def drag(self, w, fx, fy, tx, ty):
        self.screenshot(w)
        return self._r(self.call("drag", {"window_id": w["wid"], "from_x": fx, "from_y": fy, "to_x": tx, "to_y": ty}))

    def set_value(self, w, n, value):
        return self._r(self.call("set_value", {"window_id": w["wid"], "element_id": n["key"], "value": value}))

    def menu(self, w, path):
        nodes = self.tree(w)
        for n in nodes:
            if n["role"] == "menuitem" and [p for p in n["menu_path"] if p] == path:
                return self._r(self.call("click", {"window_id": w["wid"], "element_id": n["key"]}))
        raise ToolError(f"menu item {path} not in get_ui_tree")


class Cua(Arm):
    def windows(self):
        r = self.call("list_windows", {})
        self.last_windows_raw = r.data
        return [{"wid": int(d["window_id"]), "pid": d.get("pid"), "title": d.get("title") or "", "app": d.get("app_name"),
                 "origin": [(d.get("bounds") or {}).get("x", 0), (d.get("bounds") or {}).get("y", 0)]}
                for d in walk_dicts(r.data) if "window_id" in d and "pid" in d]

    def _state(self, w, shot):
        r = self.call("get_window_state", {"pid": w["pid"], "window_id": w["wid"], "tree_format": "elements",
                                           "include_screenshot": shot, "max_depth": 40})
        if r.is_error:
            raise ToolError(r.text()[:300])
        return r

    def screenshot(self, w):
        r = self._state(w, True)
        return base64.b64decode(r.images[0]["data"]) if r.images else None

    def tree(self, w):
        r = self._state(w, True)  # pixel actions are grounded on the latest capture
        els = (r.data or {}).get("elements") or []
        ox, oy = w.get("origin") or [0, 0]

        def local(f):
            # cua-driver's element frames are screen points; its x,y actions take window-local pixels
            if not f:
                return f
            return {"x": f.get("x", 0) - ox, "y": f.get("y", 0) - oy, "width": f.get("width", f.get("w", 0)),
                    "height": f.get("height", f.get("h", 0))}
        return [{"key": e.get("element_token"), "role": norm_role(e.get("role")), "name": e.get("label") or e.get("title") or "",
                 "value": e.get("value"), "frame": local(e.get("frame")), "actions": e.get("actions") or [], "menu_path": []}
                for e in els]

    def _t(self, w):
        return {"kind": "window", "pid": w["pid"], "window_id": w["wid"]}

    def _r(self, r):
        if r.is_error:
            raise ToolError(r.text()[:400])
        return r

    def click_el(self, w, n, **kw):
        return self._r(self.call("click", {"element_token": n["key"]}))

    def click_px(self, w, x, y):
        return self._r(self.call("click", {"target": self._t(w), "x": x, "y": y}))

    def type_text(self, w, text, n=None):
        a = {"target": self._t(w), "text": text}
        if n:
            a = {"element_token": n["key"], "text": text}
        return self._r(self.call("type_text", a))

    def press_key(self, w, keys):
        parts = keys.split("+")
        mods = {"cmd": "cmd", "shift": "shift", "alt": "option", "option": "option", "ctrl": "ctrl"}
        if len(parts) > 1:
            return self._r(self.call("hotkey", {"target": self._t(w),
                                                "keys": [mods.get(p, p) for p in parts[:-1]] + [parts[-1].lower()]}))
        key = {"Return": "return", "Escape": "escape"}.get(keys, keys)
        return self._r(self.call("press_key", {"target": self._t(w), "key": key}))

    def scroll(self, w, x=None, y=None, dy=5, n=None):
        a = {"direction": "down" if dy > 0 else "up", "amount": abs(int(dy))}
        if n:
            a["element_token"] = n["key"]
        else:
            a.update(target=self._t(w), x=x, y=y)
        return self._r(self.call("scroll", a))

    def drag(self, w, fx, fy, tx, ty):
        return self._r(self.call("drag", {"pid": w["pid"], "window_id": w["wid"], "from_x": fx, "from_y": fy,
                                          "to_x": tx, "to_y": ty}))

    def set_value(self, w, n, value):
        return self._r(self.call("set_value", {"element_token": n["key"], "value": value}))

    def menu(self, w, path):
        return self._r(self.call("invoke_menu", {"pid": w["pid"], "window_id": w["wid"], "path": path}))


def make_arm(arm_id, log_dir):
    return (Cua if arm_id.startswith("cua") else Cmux)(arm_id, log_dir)


def center(n):
    f = n["frame"] or {}
    x, y = f.get("x", 0), f.get("y", 0)
    wd, ht = f.get("width", f.get("w", 0)), f.get("height", f.get("h", 0))
    return x + wd / 2, y + ht / 2


def first(nodes, role=None, name=None, pred=None):
    for n in nodes:
        if role and n["role"] != role:
            continue
        if name is not None and (n["name"] or "") != name:
            continue
        if pred and not pred(n):
            continue
        return n
    raise ToolError(f"element role={role} name={name} not in the arm's tree")


# ------------------------------------------------------------------ the scene


class Scene:
    """Person on top, target windows covered under it."""

    def __init__(self, out):
        self.out = out
        self.person = None
        self.person_state = os.path.join(out, "person.state.json")

    def start_person(self):
        if self.person and self.person.poll() is None:
            return
        try:
            os.remove(self.person_state)
        except OSError:
            pass
        self.person = subprocess.Popen([PY, "-I", os.path.join(HARNESS, "fixtures/fixture_app.py"), "--mode", "person",
                                        "--state", self.person_state, "--geometry", "1060x740+0+40",
                                        "--type-interval-ms", "60"],
                                       stdout=subprocess.DEVNULL, stderr=open(self.person_state + ".log", "ab"))
        for _ in range(100):
            if os.path.exists(self.person_state):
                break
            time.sleep(0.1)
        time.sleep(0.5)

    def person_pid(self):
        return self.person.pid

    def person_read(self):
        for _ in range(5):
            try:
                with open(self.person_state) as f:
                    return json.load(f)
            except (OSError, ValueError):
                time.sleep(0.05)
        return {}

    def front_person(self):
        probe("activate", self.person_pid())
        for _ in range(40):
            s = probe("state")
            if s.get("front_pid") == self.person_pid() and s.get("key_window_title") == "Person":
                return True
            time.sleep(0.1)
        return False

    def stop(self):
        if self.person and self.person.poll() is None:
            self.person.terminate()


def zorder_ids(state):
    return [w["id"] for w in state.get("zorder", [])]


# ------------------------------------------------------------------ apps and cells
# Each app: setup() opens it in the background and places its window under the person;
# find(windows) picks the target; cells: name -> fn(arm, w, ctx) -> (effect_ok, detail).
# A cell fn does the observation calls it needs and the action, then reads the state back.

def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def app_pid(name):
    r = sh(f"pgrep -x '{name}' | head -1")
    return int(r.stdout.strip()) if r.stdout.strip() else None


def wait_window(pid, prefix, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        _, d = ax_nodes(pid, 1)
        for w in d.get("windows", []):
            if (w.get("title") or "").startswith(prefix):
                return True
        time.sleep(0.3)
    return False


def place(pid, prefix, x, y, w=0, h=0):
    return probe("frame", pid, prefix, x, y, w, h)


# --- TextEdit

def te_setup(ctx):
    sh("defaults write com.apple.TextEdit NSQuitAlwaysKeepsWindows -bool false; defaults write com.apple.TextEdit ApplePersistenceIgnoreState -bool true; rm -rf ~/Library/Saved\\ Application\\ State/com.apple.TextEdit.savedState")
    sh("pkill -x TextEdit; sleep 1; rm -rf ~/Library/Containers/com.apple.TextEdit/Data/Library/Autosave\\ Information/* "
       "~/Library/Containers/com.apple.TextEdit/Data/Library/Saved\\ Application\\ State/*")
    sh(f"python3 -c \"open('{WORK}/te.txt','w').write(''.join(f'line {{i}} the quick brown fox jumps over the lazy dog\\n' for i in range(1,121)))\"")
    sh(f"open -g -a TextEdit {WORK}/te.txt")
    pid = None
    for _ in range(50):
        pid = app_pid("TextEdit")
        if pid:
            break
        time.sleep(0.2)
    wait_window(pid, "te.txt")
    place(pid, "te.txt", 60, 80, 700, 560)
    return pid


def te_text(pid):
    nodes, _ = ax_nodes(pid)
    return ax_find(nodes, "AXTextArea", win="te.txt")


def te_vscroll(pid):
    nodes, _ = ax_nodes(pid)
    bars = [n for n in nodes if n.get("role") == "AXScrollBar" and n.get("_win") == "te.txt"]
    for b in bars:
        s = b.get("size") or {}
        if s.get("h", 0) > s.get("w", 0):
            return b.get("value")
    return None


def te_cells():
    def textarea(arm, w):
        return first(arm.tree(w), "textarea")

    def c_screenshot(arm, w, c):
        img = arm.screenshot(w)
        sz = png_size(img)
        if img:
            open(os.path.join(c["dir"], "shot.png"), "wb").write(img)
        return bool(sz) and abs(sz[0] - 700) < 80, f"image {sz}"

    def c_tree(arm, w, c):
        t = first(arm.tree(w), "textarea")
        return "line 1 the quick" in str(t.get("value") or ""), f"textarea value head {str(t.get('value'))[:40]!r}"

    def c_click_px(arm, w, c):
        t = textarea(arm, w)
        before = (te_text(c["pid"]) or {}).get("sel")
        # line 5 starts about 4 lines below the text area's top: aim 10 px in, at line 5
        f = t["frame"]
        x, y = f["x"] + 12, f["y"] + 4 + 13 * 4 + 6
        arm.click_px(w, x, y)
        time.sleep(0.5)
        after = (te_text(c["pid"]) or {}).get("sel")
        ok = bool(after) and after != before and 150 <= after.get("loc", -1) <= 260
        return ok, f"selection {before} -> {after} (line 5 starts at 208)"

    def c_type(arm, w, c):
        t = textarea(arm, w)
        tag = f"CUEV{c['rep']}TYPE"
        arm.type_text(w, tag, None)
        time.sleep(0.5)
        v = str((te_text(c["pid"]) or {}).get("value") or "")
        return tag in v, f"{tag} in text: {tag in v}"

    def c_cmd_a(arm, w, c):
        arm.press_key(w, "cmd+a")
        time.sleep(0.5)
        t = te_text(c["pid"]) or {}
        n = t.get("vlen") or 0
        sel = t.get("sel") or {}
        return sel.get("len") == n and n > 100, f"selection {sel} of {n} chars"

    def c_cmd_s(arm, w, c):
        tag = f"CUEV{c['rep']}SAVE"
        arm.type_text(w, tag)
        time.sleep(0.3)
        arm.press_key(w, "cmd+s")
        time.sleep(1.0)
        on_disk = open(f"{WORK}/te.txt").read()
        return tag in on_disk, f"{tag} saved to disk: {tag in on_disk}"

    def c_scroll(arm, w, c):
        def top():
            t = te_text(c["pid"]) or {}
            return (t.get("pos") or {}).get("y"), te_vscroll(c["pid"])
        before = top()
        t = textarea(arm, w)
        f = t["frame"]
        arm.scroll(w, f["x"] + 200, min(f["y"] + 200, 400), dy=10)
        time.sleep(0.6)
        after = top()
        return after[0] is not None and before[0] is not None and after[0] < before[0], f"text area top y, scroller {before} -> {after}"

    def c_drag(arm, w, c):
        arm.press_key(w, "cmd+Up") if False else None
        t = textarea(arm, w)
        f = t["frame"]
        y0 = max(f["y"], 32) + 4
        arm.drag(w, 12, y0 + 6, 300, y0 + 13 * 3 + 6)
        time.sleep(0.5)
        sel = (te_text(c["pid"]) or {}).get("sel") or {}
        return sel.get("len", 0) > 20, f"selection after drag {sel}"

    def c_set_value(arm, w, c):
        t = textarea(arm, w)
        val = f"set by set_value rep {c['rep']}\nsecond line\n"
        arm.set_value(w, t, val)
        time.sleep(0.5)
        v = str((te_text(c["pid"]) or {}).get("value") or "")
        return v == val, f"value now {v[:50]!r}"

    def c_menu(arm, w, c):
        arm.menu(w, ["Format", "Make Rich Text"])
        time.sleep(0.8)
        nodes, _ = ax_nodes(c["pid"], 6, menus=True)
        plain = ax_find(nodes, "AXMenuItem", pred=lambda n: n.get("title") == "Make Plain Text")
        return plain is not None, f"Format menu now offers Make Plain Text: {plain is not None}"

    return {"screenshot": c_screenshot, "get_ui_tree": c_tree, "click_px": c_click_px, "type_text": c_type,
            "press_key_cmd_a": c_cmd_a, "press_key_cmd_s": c_cmd_s, "scroll": c_scroll, "drag": c_drag,
            "set_value": c_set_value, "menu_item": c_menu}


# --- Calculator

def calc_setup(ctx):
    sh("pkill -x Calculator; sleep 1; open -g -a Calculator")
    pid = None
    for _ in range(50):
        pid = app_pid("Calculator")
        if pid:
            break
        time.sleep(0.2)
    wait_window(pid, "Calculator")
    place(pid, "Calculator", 300, 200)
    return pid


def calc_display(pid):
    nodes, _ = ax_nodes(pid)
    sa = None
    for n in nodes:
        if n.get("role") == "AXScrollArea" and (n.get("desc") == "Edit field" or n.get("title") == "Edit field"):
            sa = n
    # the display text is the static text inside the edit field
    for n in nodes:
        if n.get("role") == "AXStaticText" and isinstance(n.get("value"), str) and n.get("_win") == "Calculator":
            return n["value"].replace("‎", "").replace(",", "")
    return None


def calc_width(pid):
    _, d = ax_nodes(pid, 1)
    for w in d.get("windows", []):
        return (w.get("size") or {}).get("w")


def calc_cells():
    def clear(arm, w):
        arm.press_key(w, "Escape")
        time.sleep(0.2)

    def c_screenshot(arm, w, c):
        img = arm.screenshot(w)
        sz = png_size(img)
        if img:
            open(os.path.join(c["dir"], "shot.png"), "wb").write(img)
        return bool(sz) and 180 < sz[0] < 700, f"image {sz}"

    def c_tree(arm, w, c):
        nodes = arm.tree(w)
        names = {n["name"] for n in nodes if n["role"] == "button"}
        return {"7", "8", "Equals"} <= names, f"{len(nodes)} nodes, digit buttons present: {'7' in names}"

    def c_click_el(arm, w, c):
        clear(arm, w)
        n = first(arm.tree(w), "button", "7")
        arm.click_el(w, n)
        time.sleep(0.4)
        d = calc_display(c["pid"])
        return d == "7", f"display {d!r}"

    def c_click_px(arm, w, c):
        clear(arm, w)
        n = first(arm.tree(w), "button", "8")
        arm.click_px(w, *center(n))
        time.sleep(0.4)
        d = calc_display(c["pid"])
        return d == "8", f"display {d!r}"

    def c_type(arm, w, c):
        clear(arm, w)
        arm.type_text(w, "12+3=")
        time.sleep(0.6)
        d = calc_display(c["pid"])
        return d == "15", f"display {d!r} after typing 12+3="

    def c_key(arm, w, c):
        clear(arm, w)
        for k in ["4", "2"]:
            arm.press_key(w, k)
        time.sleep(0.5)
        d = calc_display(c["pid"])
        return d == "42", f"display {d!r} after keys 4 2"

    def c_return(arm, w, c):
        clear(arm, w)
        n = first(arm.tree(w), "button", "9")
        arm.click_el(w, n)
        arm.click_el(w, first(arm.tree(w), "button", "Add"))
        arm.click_el(w, first(arm.tree(w), "button", "1"))
        time.sleep(0.3)
        arm.press_key(w, "Return")
        time.sleep(0.5)
        d = calc_display(c["pid"])
        return d == "10", f"display {d!r} after 9 + 1 (buttons) then press_key Return"

    def c_chord(arm, w, c):
        before = calc_width(c["pid"])
        arm.press_key(w, "cmd+2" if before and before < 400 else "cmd+1")
        time.sleep(1.0)
        after = calc_width(c["pid"])
        if after and after > 400:
            arm.press_key(w, "cmd+1")  # back to Basic for the next cell
            time.sleep(0.8)
        return bool(before and after and before != after), f"window width {before} -> {after} (cmd+2 Scientific)"

    def c_menu(arm, w, c):
        before = calc_width(c["pid"])
        arm.menu(w, ["View", "Scientific"])
        time.sleep(1.0)
        after = calc_width(c["pid"])
        try:
            arm.menu(w, ["View", "Basic"])
            time.sleep(0.8)
        except ToolError:
            pass
        return bool(before and after and after > before), f"window width {before} -> {after} (View > Scientific)"

    return {"screenshot": c_screenshot, "get_ui_tree": c_tree, "click_element": c_click_el, "click_px": c_click_px,
            "type_text": c_type, "press_key": c_key, "press_key_return": c_return, "press_key_chord_cmd_2": c_chord, "menu_item": c_menu}


# --- Safari (a local page whose own JS reports what it saw)

def safari_setup(ctx):
    sh("pkill -x Safari; sleep 1")
    S = "~/Library/Containers/com.apple.Safari/Data/Library/Safari"
    sh(f"rm -f ~/Library/Safari/LastSession.plist {S}/LastSession.plist; rm -rf ~/Library/Saved\\ Application\\ State/com.apple.Safari.savedState")
    sh(f"cp ~/cu/page.html {WORK}/page.html; open -g -a Safari {WORK}/page.html")
    pid = None
    for _ in range(50):
        pid = app_pid("Safari")
        if pid:
            break
        time.sleep(0.2)
    wait_window(pid, "CUEV Page")
    place(pid, "CUEV Page", 40, 60, 900, 640)
    time.sleep(1.5)
    return pid


def page_status(pid):
    nodes, _ = ax_nodes(pid, 60)
    texts = [str(n.get("value") or "") for n in nodes if n.get("role") == "AXStaticText" and n.get("_win") == "CUEV Page"]
    blob = " ".join(texts)
    out = {}
    for k in ("scroll", "keys", "clicks", "slider", "w", "sel"):
        m = re.search(rf"\b{k}=\s*(\S+)", blob)
        out[k] = m.group(1) if m else None
    field = ax_find(nodes, "AXTextField", win="CUEV Page", pred=lambda n: n.get("title") == "Name" or n.get("desc") == "Name")
    out["name"] = field.get("value") if field else None
    return out, blob[:300]


def safari_cells():
    def web(nodes, role, name):
        return first(nodes, role, pred=lambda n: (n["name"] or "").startswith(name))

    def c_screenshot(arm, w, c):
        img = arm.screenshot(w)
        sz = png_size(img)
        if img:
            open(os.path.join(c["dir"], "shot.png"), "wb").write(img)
        return bool(sz) and abs(sz[0] - 900) < 100, f"image {sz}"

    def c_tree(arm, w, c):
        nodes = arm.tree(w)
        b = [n for n in nodes if n["role"] == "button" and n["name"] == "Press Me"]
        return bool(b), f"{len(nodes)} nodes; Press Me button found: {bool(b)}"

    def c_click_el(arm, w, c):
        before, _ = page_status(c["pid"])
        arm.click_el(w, web(arm.tree(w), "button", "Press Me"))
        time.sleep(0.6)
        after, blob = page_status(c["pid"])
        return after["clicks"] not in (None, before["clicks"]), f"clicks {before['clicks']} -> {after['clicks']}"

    def c_click_px(arm, w, c):
        before, _ = page_status(c["pid"])
        arm.click_px(w, *center(web(arm.tree(w), "button", "Press Me")))
        time.sleep(0.6)
        after, _ = page_status(c["pid"])
        return after["clicks"] not in (None, before["clicks"]), f"clicks {before['clicks']} -> {after['clicks']}"

    def c_type(arm, w, c):
        tag = f"cuev{c['rep']}"
        f = web(arm.tree(w), "textfield", "Name")
        arm.set_value(w, f, "") if False else None
        arm.type_text(w, tag, f)
        time.sleep(0.6)
        after, _ = page_status(c["pid"])
        return tag in str(after["name"] or ""), f"Name field {after['name']!r}"

    def c_chord(arm, w, c):
        f = web(arm.tree(w), "textfield", "Name")
        arm.click_el(w, f) if False else None
        arm.press_key(w, "cmd+a")
        time.sleep(0.5)
        after, _ = page_status(c["pid"])
        return after["keys"] == "meta+a", f"page saw keydown {after['keys']!r}"

    def c_scroll(arm, w, c):
        before, _ = page_status(c["pid"])
        nodes = arm.tree(w)
        rowtxt = first(nodes, pred=lambda n: (n["name"] or str(n["value"] or "")).startswith("Row 3"))
        arm.scroll(w, *center(rowtxt), dy=8)
        time.sleep(0.8)
        after, _ = page_status(c["pid"])
        return int(after["scroll"] or 0) > int(before["scroll"] or 0), f"scrollY {before['scroll']} -> {after['scroll']}"

    def c_drag(arm, w, c):
        before, _ = page_status(c["pid"])
        s = first(arm.tree(w), "slider")
        f = s["frame"]
        x0 = f["x"] + f["width"] * float(before["slider"] or 10) / 100
        y0 = f["y"] + f["height"] / 2
        arm.drag(w, x0, y0, x0 + f["width"] * 0.4, y0)
        time.sleep(0.6)
        after, _ = page_status(c["pid"])
        return after["slider"] not in (None, before["slider"]), f"slider {before['slider']} -> {after['slider']}"

    def c_set_value(arm, w, c):
        val = f"setval{c['rep']}"
        arm.set_value(w, web(arm.tree(w), "textfield", "Name"), val)
        time.sleep(0.6)
        after, _ = page_status(c["pid"])
        return after["name"] == val, f"Name field {after['name']!r}"

    def c_menu(arm, w, c):
        before, _ = page_status(c["pid"])
        arm.menu(w, ["View", "Zoom In"])
        time.sleep(1.0)
        after, _ = page_status(c["pid"])
        try:
            arm.menu(w, ["View", "Actual Size"])
            time.sleep(0.6)
        except ToolError:
            pass
        return after["w"] not in (None, before["w"]), f"page innerWidth {before['w']} -> {after['w']} (View > Zoom In)"

    return {"screenshot": c_screenshot, "get_ui_tree": c_tree, "click_element": c_click_el, "click_px": c_click_px,
            "type_text": c_type, "press_key_chord_cmd_a": c_chord, "scroll": c_scroll, "drag": c_drag,
            "set_value": c_set_value, "menu_item": c_menu}


# --- Finder

def finder_setup(ctx):
    sh(f"rm -rf {WORK}/finder; mkdir -p {WORK}/finder/dest; cd {WORK}/finder && for i in $(seq -w 1 40); do echo $i > file-$i.txt; done")
    # Finder always runs: close our window if open, then open the folder in the background
    sh("defaults write com.apple.finder FXPreferredViewStyle Nlsv")  # list view (test VM only)
    probe("close", app_pid("Finder"), "finder")
    time.sleep(0.5)
    sh(f"open -g {WORK}/finder")
    pid = app_pid("Finder")
    wait_window(pid, "finder")
    place(pid, "finder", 80, 100, 860, 520)
    return pid


def finder_sel(pid):
    nodes, _ = ax_nodes(pid, 30)
    for n in nodes:
        if n.get("_win") == "finder" and n.get("role") in ("AXOutline", "AXList", "AXTable") and n.get("desc") != "sidebar" \
                and n.get("title") != "sidebar":
            if "selected_rows" in n:
                return n["selected_rows"], n.get("selected_names")
    roles = {n.get("role") for n in nodes if n.get("_win") == "finder"}
    return None, ("icon" if "AXGroup" in roles and "AXOutline" not in roles else "?")


def finder_view(pid):
    nodes, _ = ax_nodes(pid, 30)
    outlines = [n for n in nodes if n.get("_win") == "finder" and n.get("role") == "AXOutline" and n.get("desc") != "sidebar"]
    return "list" if len(outlines) >= 1 and any(n.get("desc") != "sidebar" for n in outlines) else "other"


def finder_cells():
    def rows(arm, w):
        return [n for n in arm.tree(w) if n["role"] in ("row", "outlinerow") and "file-" in json.dumps(n)]

    def file_node(arm, w, name):
        nodes = arm.tree(w)
        for i, n in enumerate(nodes):
            if (n["name"] == name or str(n["value"] or "") == name) and n["frame"] and n["frame"].get("height", 0) > 0:
                return n
        raise ToolError(f"{name} not in the arm's tree")

    def c_screenshot(arm, w, c):
        img = arm.screenshot(w)
        sz = png_size(img)
        if img:
            open(os.path.join(c["dir"], "shot.png"), "wb").write(img)
        return bool(sz) and abs(sz[0] - 860) < 100, f"image {sz}"

    def c_tree(arm, w, c):
        nodes = arm.tree(w)
        hit = any("file-01" in (n["name"] or "") + str(n["value"] or "") for n in nodes)
        return hit, f"{len(nodes)} nodes; file-01 listed: {hit}"

    def c_click_el(arm, w, c):
        arm.click_el(w, file_node(arm, w, "file-03.txt"))
        time.sleep(0.5)
        sel, kind = finder_sel(c["pid"])
        return sel == 1, f"selected rows {sel} ({kind})"

    def c_click_px(arm, w, c):
        arm.click_px(w, *center(file_node(arm, w, "file-05.txt")))
        time.sleep(0.5)
        sel, kind = finder_sel(c["pid"])
        return sel == 1, f"selected rows {sel} ({kind})"

    def c_cmd_a(arm, w, c):
        arm.press_key(w, "cmd+a")
        time.sleep(0.6)
        sel, kind = finder_sel(c["pid"])
        return sel == 41, f"selected rows {sel} of 41 ({kind})"

    def c_new_folder(arm, w, c):
        arm.press_key(w, "cmd+shift+n")
        time.sleep(1.2)
        made = [d for d in os.listdir(f"{WORK}/finder") if d.startswith("untitled folder")]
        if made:
            arm.press_key(w, "Escape")
            time.sleep(0.3)
            for d in made:
                sh(f"rm -rf '{WORK}/finder/{d}'")
        return bool(made), f"new folder on disk: {made}"

    def c_type(arm, w, c):
        arm.type_text(w, "file-2")
        time.sleep(0.8)
        s, names = finder_sel(c["pid"])
        ok = s == 1 and bool(names) and str(names[0]).startswith("file-2")
        return ok, f"type-select selected {s} rows {names!r:.80}"

    def c_scroll(arm, w, c):
        nodes = arm.tree(w)
        n = file_node(arm, w, "file-03.txt")
        before = [x for x in nodes if x["role"] == "scrollbar"]
        arm.scroll(w, *center(n), dy=10)
        time.sleep(0.6)
        nodes2, _ = ax_nodes(c["pid"], 30)
        bars = [x.get("value") for x in nodes2 if x.get("_win") == "finder" and x.get("role") == "AXScrollBar"]
        return any(isinstance(b, (int, float)) and b > 0 for b in bars), f"scroll bar values {bars}"

    def c_drag(arm, w, c):
        src = file_node(arm, w, "file-07.txt")
        dst = file_node(arm, w, "dest")
        arm.drag(w, *center(src), *center(dst))
        time.sleep(1.2)
        moved = os.path.exists(f"{WORK}/finder/dest/file-07.txt")
        if moved:
            sh(f"mv {WORK}/finder/dest/file-07.txt {WORK}/finder/")
        return moved, f"file-07.txt moved into dest: {moved}"

    def c_menu(arm, w, c):
        arm.menu(w, ["View", "as Icons"])
        time.sleep(1.0)
        v = finder_view(c["pid"])
        try:
            arm.menu(w, ["View", "as List"])
            time.sleep(0.8)
        except ToolError:
            pass
        return v == "other", f"view after View > as Icons: {v}"

    return {"screenshot": c_screenshot, "get_ui_tree": c_tree, "click_element": c_click_el, "click_px": c_click_px,
            "type_text": c_type, "press_key_cmd_a": c_cmd_a, "press_key_cmd_shift_n": c_new_folder,
            "scroll": c_scroll, "drag": c_drag, "menu_item": c_menu}


# --- Notes

def notes_setup(ctx):
    sh("pkill -x Notes; sleep 1; open -g -a Notes")
    pid = None
    for _ in range(50):
        pid = app_pid("Notes")
        if pid:
            break
        time.sleep(0.2)
    wait_window(pid, "Notes")
    time.sleep(1.0)
    probe("press", pid, "Continue")  # first-run welcome sheet (setup only)
    time.sleep(1.0)
    place(pid, "Notes", 40, 60, 960, 640)
    return pid


def notes_count(pid):
    nodes, _ = ax_nodes(pid, 40)
    t = [n for n in nodes if n.get("role") in ("AXWindow",) and str(n.get("title") or "").startswith("Notes")]
    title = t[0].get("title") if t else ""
    m = re.search(r"(\d+) notes?", title or "")
    body = ax_find(nodes, "AXTextArea", pred=lambda n: True)
    return (int(m.group(1)) if m else (0 if "No notes" in (title or "") else None)), (body or {}).get("value"), title


def notes_cells():
    def c_screenshot(arm, w, c):
        img = arm.screenshot(w)
        sz = png_size(img)
        if img:
            open(os.path.join(c["dir"], "shot.png"), "wb").write(img)
        return bool(sz) and abs(sz[0] - 960) < 100, f"image {sz}"

    def c_tree(arm, w, c):
        nodes = arm.tree(w)
        return len(nodes) > 20, f"{len(nodes)} nodes"

    def c_menu(arm, w, c):
        n0, _, t0 = notes_count(c["pid"])
        arm.menu(w, ["File", "New Note"])
        time.sleep(1.2)
        n1, _, t1 = notes_count(c["pid"])
        return n1 is not None and n0 is not None and n1 > n0, f"notes {n0} -> {n1} ({t1!r})"

    def c_click_el(arm, w, c):
        n0, _, _ = notes_count(c["pid"])
        b = first(arm.tree(w), "button", pred=lambda n: "new note" in json.dumps(n).lower())
        arm.click_el(w, b)
        time.sleep(1.2)
        n1, _, t1 = notes_count(c["pid"])
        return n1 is not None and n0 is not None and n1 > n0, f"notes {n0} -> {n1}"

    def c_type(arm, w, c):
        tag = f"cuev note {c['rep']}"
        arm.type_text(w, tag)
        time.sleep(1.0)
        _, body, _ = notes_count(c["pid"])
        return tag in str(body or ""), f"note body {str(body)[:60]!r}"

    def c_cmd_a(arm, w, c):
        arm.press_key(w, "cmd+a")
        time.sleep(0.6)
        nodes, _ = ax_nodes(c["pid"], 40)
        body = ax_find(nodes, "AXTextArea")
        sel = (body or {}).get("sel") or {}
        v = str((body or {}).get("value") or "")
        return sel.get("len", 0) == len(v) and len(v) > 0, f"body selection {sel} of {len(v)}"

    def c_set_value(arm, w, c):
        b = first(arm.tree(w), "textarea")
        val = f"set value note {c['rep']}"
        arm.set_value(w, b, val)
        time.sleep(0.8)
        _, body, _ = notes_count(c["pid"])
        return str(body or "").strip() == val, f"body {str(body)[:60]!r}"

    def c_click_px(arm, w, c):
        nodes = arm.tree(w)
        b = first(nodes, "textarea")
        arm.click_px(w, *center(b))
        time.sleep(0.6)
        nodes2, _ = ax_nodes(c["pid"], 40)
        body = ax_find(nodes2, "AXTextArea")
        return bool(body and body.get("focused")), f"body focused after click: {body and body.get('focused')}"

    def c_scroll(arm, w, c):
        b = first(arm.tree(w), "textarea")
        arm.scroll(w, *center(b), dy=5)
        time.sleep(0.6)
        return None, "no readback for Notes scroll (only background invariants scored)"

    return {"screenshot": c_screenshot, "get_ui_tree": c_tree, "menu_item": c_menu, "click_element": c_click_el,
            "type_text": c_type, "press_key_cmd_a": c_cmd_a, "set_value": c_set_value, "click_px": c_click_px,
            "scroll": c_scroll}


# --- System Settings (read only: look and navigate, change nothing)

def settings_setup(ctx):
    sh("pkill -x 'System Settings'; sleep 1; open -g 'x-apple.systempreferences:com.apple.Appearance-Settings.extension'")
    pid = None
    for _ in range(50):
        pid = app_pid("System Settings")
        if pid:
            break
        time.sleep(0.2)
    wait_window(pid, "")
    time.sleep(1.5)
    _, d = ax_nodes(pid, 1)
    title = (d.get("windows") or [{}])[0].get("title") or ""
    place(pid, title, 120, 90)
    return pid


def settings_title(pid):
    nodes, _ = ax_nodes(pid, 30)
    for n in nodes:
        if n.get("role") == "AXOutline" and "selected_names" in n:
            names = n.get("selected_names") or []
            return names[0] if names else ""
    return None


def settings_cells():
    def c_screenshot(arm, w, c):
        img = arm.screenshot(w)
        sz = png_size(img)
        if img:
            open(os.path.join(c["dir"], "shot.png"), "wb").write(img)
        return bool(sz) and sz[0] > 500, f"image {sz}"

    def c_tree(arm, w, c):
        nodes = arm.tree(w)
        hit = any((n["name"] or str(n["value"] or "")) == "General" for n in nodes)
        return hit, f"{len(nodes)} nodes; sidebar General listed: {hit}"

    def c_click_el(arm, w, c):
        target = "General" if settings_title(c["pid"]) != "General" else "Appearance"
        n = first(arm.tree(w), pred=lambda n: (n["name"] or str(n["value"] or "")) == target and n["role"] in ("text", "statictext", "cell", "row", "outlinerow"))
        arm.click_el(w, n)
        time.sleep(1.2)
        t = settings_title(c["pid"])
        return t == target, f"pane {t!r}, wanted {target!r}"

    def c_click_px(arm, w, c):
        target = "Accessibility" if settings_title(c["pid"]) != "Accessibility" else "Appearance"
        n = first(arm.tree(w), pred=lambda n: (n["name"] or str(n["value"] or "")) == target and (n["frame"] or {}).get("height", 0) > 0)
        arm.click_px(w, *center(n))
        time.sleep(1.2)
        t = settings_title(c["pid"])
        return t == target, f"pane {t!r}, wanted {target!r}"

    def c_scroll(arm, w, c):
        n = first(arm.tree(w), pred=lambda n: (n["name"] or str(n["value"] or "")) == "Network" and (n["frame"] or {}).get("height", 0) > 0)
        before = [x.get("value") for x in ax_nodes(c["pid"], 30)[0] if x.get("role") == "AXScrollBar"]
        arm.scroll(w, *center(n), dy=10)
        time.sleep(0.8)
        after = [x.get("value") for x in ax_nodes(c["pid"], 30)[0] if x.get("role") == "AXScrollBar"]
        return before != after, f"scroll bars {before} -> {after}"

    def c_type(arm, w, c):
        f = first(arm.tree(w), pred=lambda n: n["role"] in ("textfield", "searchfield"))
        arm.type_text(w, "disp", f)
        time.sleep(0.8)
        nodes, _ = ax_nodes(c["pid"], 30)
        sf = ax_find(nodes, "AXTextField")
        v = (sf or {}).get("value")
        try:
            arm.set_value(w, f, "")
        except ToolError:
            pass
        return v == "disp", f"search field {v!r}"

    return {"screenshot": c_screenshot, "get_ui_tree": c_tree, "click_element": c_click_el, "click_px": c_click_px,
            "scroll": c_scroll, "type_text": c_type}


# --- the harness's Tk fixture form

def tk_setup(ctx):
    sh("pkill -f 'fixture_app.py --mode form'")
    state = os.path.join(ctx["out"], "tkform.state.json")
    try:
        os.remove(state)
    except OSError:
        pass
    ctx["tk_state"] = state
    ctx["tk_proc"] = subprocess.Popen([PY, "-I", os.path.join(HARNESS, "fixtures/fixture_app.py"), "--mode", "form",
                                       "--state", state, "--geometry", "420x520+100+120"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if os.path.exists(state):
            break
        time.sleep(0.1)
    time.sleep(0.8)
    return ctx["tk_proc"].pid


def tk_cells():
    TB = 32  # macOS title bar: widget frames are content-relative, screenshots include the title bar

    def st(c):
        return json.load(open(c["ctx"]["tk_state"]))

    def pt(c, name, dx=0.5):
        f = st(c)["widgets"][name]
        return f["x"] + f["w"] * dx, f["y"] + f["h"] / 2 + TB

    def c_screenshot(arm, w, c):
        img = arm.screenshot(w)
        sz = png_size(img)
        if img:
            open(os.path.join(c["dir"], "shot.png"), "wb").write(img)
        return bool(sz) and abs(sz[0] - 420) < 40, f"image {sz}"

    def c_tree(arm, w, c):
        nodes = arm.tree(w)
        widgets = [n for n in nodes if n["role"] in ("checkbox", "textfield", "button", "slider", "list")
                   and "close" not in n["role"]]
        return len(widgets) >= 3, f"{len(nodes)} nodes; form widgets exposed: {[n['role'] for n in widgets][:6]}"

    def c_click_px(arm, w, c):
        arm.screenshot(w)
        before = st(c)["subscribe"]
        arm.click_px(w, *pt(c, "subscribe", 0.15))
        time.sleep(0.6)
        after = st(c)["subscribe"]
        return after != before, f"subscribe {before} -> {after}"

    def c_type(arm, w, c):
        arm.screenshot(w)
        arm.click_px(w, *pt(c, "name"))
        arm.type_text(w, f"Ada {c['rep']}")
        time.sleep(0.6)
        v = st(c)["name"]
        return f"Ada {c['rep']}" in v, f"name {v!r}"

    def c_key(arm, w, c):
        arm.press_key(w, "Return")
        time.sleep(0.6)
        s = st(c)
        return s["saved"], f"saved {s['saved']}"

    def c_scroll(arm, w, c):
        arm.screenshot(w)
        before = st(c)["first_visible"]
        arm.scroll(w, *pt(c, "list"), dy=5)
        time.sleep(0.6)
        after = st(c)["first_visible"]
        return after > before, f"first_visible {before} -> {after}"

    def c_drag(arm, w, c):
        arm.screenshot(w)
        before = st(c)["slider"]
        f = st(c)["widgets"]["slider"]
        y = f["y"] + f["h"] * 0.65 + TB
        arm.drag(w, f["x"] + 12, y, f["x"] + f["w"] * 0.6, y)
        time.sleep(0.6)
        after = st(c)["slider"]
        return after != before, f"slider {before} -> {after}"

    return {"screenshot": c_screenshot, "get_ui_tree": c_tree, "click_px": c_click_px, "type_text": c_type,
            "press_key": c_key, "scroll": c_scroll, "drag": c_drag}


APPS = {
    "textedit": (te_setup, lambda ws: next(w for w in ws if w["title"] == "te.txt"), te_cells),
    "calculator": (calc_setup, lambda ws: next(w for w in ws if w["title"] == "Calculator"), calc_cells),
    "safari": (safari_setup, lambda ws: next(w for w in ws if w["title"] == "CUEV Page"), safari_cells),
    "finder": (finder_setup, lambda ws: next(w for w in ws if w["title"] == "finder"), finder_cells),
    "notes": (notes_setup, lambda ws: next(w for w in ws if w["title"].startswith("Notes")), notes_cells),
    "settings": (settings_setup, lambda ws: next(w for w in ws if w["app"] in ("com.apple.systempreferences", "System Settings")), settings_cells),
    "tk": (tk_setup, lambda ws: next(w for w in ws if w["title"] == "CU Eval Form"), tk_cells),
}


# ------------------------------------------------------------------ run


def run_cell(arm, scene, app, action, fn, w, rep, ctx, out):
    cdir = os.path.join(out, "cells", f"{arm.id}-{app}-{action}-r{rep}")
    os.makedirs(cdir, exist_ok=True)
    if not scene.front_person():
        note = "person could not be made frontmost before the cell"
    else:
        note = ""
    pre = probe("state")
    p_pre = scene.person_read()
    arm.calls = []
    watch = Watcher()
    t0 = time.monotonic()
    err = None
    effect, detail = None, ""
    try:
        effect, detail = fn(arm, w, {"pid": ctx["pid"], "rep": rep, "dir": cdir, "ctx": ctx})
    except ToolError as e:
        err = f"tool error: {e}"
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
        detail = traceback.format_exc()[-600:]
    wall = time.monotonic() - t0
    time.sleep(0.4)
    samples = watch.stop()
    post = probe("state")
    p_post = scene.person_read()
    ppid = scene.person_pid()
    fronts = sorted({s["front_pid"] for s in samples})
    keys = sorted({s["key"] for s in samples})
    ptrs = sorted({tuple(s["ptr"]) for s in samples})
    tops = sorted({s["top_window"] for s in samples})
    leaked = p_post.get("keys_received", [])[len(p_pre.get("keys_received", [])):]
    lost = p_post.get("focus_lost", 0) - p_pre.get("focus_lost", 0)
    zpre, zpost = zorder_ids(pre), zorder_ids(post)
    common = [i for i in zpre if i in zpost]
    z_ok = [i for i in zpost if i in common] == common and (zpost[:1] == zpre[:1])
    target_raised = False
    tid = int(w["wid"]) if str(w["wid"]).isdigit() else None
    if tid in zpre and tid in zpost:
        target_raised = zpost.index(tid) < zpre.index(tid)
    row = {
        "arm": arm.id, "app": app, "action": action, "rep": rep,
        "tool_ok": err is None and not any(c["is_error"] for c in arm.calls),
        "effect": effect if err is None else False,
        "detail": detail if err is None else err,
        "front_ok": fronts == [ppid], "key_ok": keys == ["Person"], "pointer_ok": len(ptrs) == 1,
        "keys_ok": not leaked, "person_focus_lost": lost, "zorder_ok": z_ok, "raised": target_raised,
        "fronts_seen": fronts, "keys_seen": keys, "pointers_seen": [list(p) for p in ptrs][:5], "top_windows_seen": tops,
        "leaked_keys": leaked[:40], "z_before": zpre[:8], "z_after": zpost[:8], "person_pid": ppid,
        "target_window": w, "samples": samples[:40], "calls": arm.calls, "wall_s": round(wall, 2), "note": note,
    }
    row["background_safe"] = row["front_ok"] and row["key_ok"] and row["pointer_ok"] and row["keys_ok"] and row["zorder_ok"] and not row["raised"]
    with open(os.path.join(out, "matrix.jsonl"), "a") as f:
        f.write(json.dumps(row) + "\n")
    mark = "PASS" if row["effect"] else ("N/A " if row["effect"] is None and err is None else "FAIL")
    bg = "bg-ok" if row["background_safe"] else "BG-FAIL[" + ",".join(k for k in ("front_ok", "key_ok", "pointer_ok", "keys_ok", "zorder_ok") if not row[k]) + ("raised" if row["raised"] else "") + "]"
    print(f"{mark} {bg:30} {arm.id:18} {app:10} {action:24} r{rep} {row['wall_s']}s  {(row['detail'] or '')[:150]}", flush=True)
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--apps", default="textedit,calculator,safari,finder,notes,settings,tk")
    ap.add_argument("--actions", default="")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--rep-start", type=int, default=1)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    os.makedirs(WORK, exist_ok=True)
    scene = Scene(a.out)
    arm = make_arm(a.arm, a.out)
    only = set(filter(None, a.actions.split(",")))
    try:
        for app in a.apps.split(","):
            setup, pick, cells = APPS[app]
            ctx = {"out": a.out}
            for rep in range(a.rep_start, a.rep_start + a.reps):
                scene.start_person()
                scene.front_person()
                try:
                    ctx["pid"] = setup(ctx)
                    scene.front_person()
                    time.sleep(0.5)
                    w = pick(arm.windows())
                except Exception as e:
                    print(f"SETUP-FAIL {a.arm} {app} r{rep}: {type(e).__name__}: {e}", flush=True)
                    with open(os.path.join(a.out, "matrix.jsonl"), "a") as f:
                        f.write(json.dumps({"arm": a.arm, "app": app, "rep": rep, "setup_error": f"{type(e).__name__}: {e}"}) + "\n")
                    continue
                for action, fn in cells().items():
                    if only and action not in only:
                        continue
                    try:
                        w = pick(arm.windows())
                    except StopIteration:
                        pass
                    run_cell(arm, scene, app, action, fn, w, rep, ctx, a.out)
            if app == "tk" and ctx.get("tk_proc"):
                ctx["tk_proc"].terminate()
    finally:
        arm.close()
        scene.stop()


if __name__ == "__main__":
    main()
