# SPDX-License-Identifier: MIT
"""truthmatrix.py: does a computer-use tool tell the truth about what its actions did?

  python3 truthmatrix.py --arm cmux-cu --reps 3 --scenes bg,fg --out DIR [--apps lab,textedit,...]

Runs in a disposable macOS guest's GUI session (gr.sh), no model. For every cell (app x action x
scene x rep) the driver makes the MCP calls an agent would (observe, then act), and records:

  claim   what the tool said about the scored action: confirmed / delivered / ok (success with no
          evidence field) / no_visible_change / error / refused
  truth   what really happened, read independently of the tool:
            lab      the native fixture's oracle (fixtures/macos): every state change it logs with a
                     timestamp, plus its full state over a socket
            real     TextEdit, Calculator, Safari (a local page whose JS reports), Finder, Notes,
                     System Settings (read only): AX read by a separate process (probe), files on disk
          correct  the intended effect, exactly once, on the intended element
          none     no effect
          wrong    an effect, but not the intended one (wrong element or window, partial, wrong value,
                   duplicated)
          extra    the intended effect plus a side effect elsewhere (another element or window changed)
  timing  first intended effect relative to the moment the tool returned (negative: before it returned),
          polled up to --late seconds after the result, so late effects are seen and timed
  bg      the background invariants of bgmatrix.py (front app, key window, pointer, leaked keys, z-order)

Scenes: bg = the "Person" app (fixtures/macos, person mode) is frontmost, key, covers every target window
and types in-process the whole time; fg = the target app is frontmost and the target window key.

One JSON row per cell in DIR/truth.jsonl. Rows with outcome "no_action" never reached a scored action
(the arm could not find the element, or an observation call failed); they are not claim evidence and
are counted separately.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bgmatrix as bm  # noqa: E402
import aside_arm  # noqa: E402,F401  (registers the aside arm with bgmatrix)
from truthmatrix_claims import POLICY_RE, POSITIVE, claim_of, confusion_cell  # noqa: E402,F401

HOME = os.path.expanduser("~")
FIXTURE_DIR = os.environ.get("CUEVAL_MACOS_FIXTURES", os.path.join(HOME, "cu/fixture-build"))
LAB_APP = "CU Eval Fixture"
ACTING = {"click", "type_text", "press_key", "hotkey", "scroll", "drag", "set_value", "perform_action",
          "invoke_menu", "repl"}
LATE_DEFAULT = 3.5
# Aside has one tool (repl); its observation calls (titles set by aside_arm.py) are not actions
ASIDE_OBSERVE = {"Read window", "Screenshot", "List windows", "List apps", "Read Python windows"}


def is_acting(call):
    if call["tool"] not in ACTING:
        return False
    if call["tool"] == "repl":
        t = (call.get("args") or {}).get("title") or ""
        return t not in ASIDE_OBSERVE and not t.startswith("Get ")
    return True


def fixture_bin(bundle):
    return os.path.join(FIXTURE_DIR, f"{bundle}.app/Contents/MacOS/cueval-fixture")


# ------------------------------------------------------------------ wall-clock call records

_orig_call = bm.Arm.call


def _timed_call(self, name, args, timeout=90):
    t0 = time.time()
    try:
        return _orig_call(self, name, args, timeout=timeout)
    finally:
        if self.calls:
            self.calls[-1]["t0"] = t0
            self.calls[-1]["t1"] = time.time()


bm.Arm.call = _timed_call

_orig_app_pid = bm.app_pid
LAB_PID = {}


def _app_pid(name):
    if name == LAB_APP and LAB_PID.get("pid"):
        return LAB_PID["pid"]
    return _orig_app_pid(name)


bm.app_pid = _app_pid


# ------------------------------------------------------------------ the lab fixture

class Lab:
    def __init__(self, out):
        self.out = out
        self.state_path = os.path.join(out, "lab.state.json")
        self.events = os.path.join(out, "lab.events.jsonl")
        self.sock = os.path.join("/tmp", f"cuev-lab-{os.getpid()}.sock")
        self.proc = None

    def start(self):
        if self.proc and self.proc.poll() is None:
            return self.proc.pid
        sh_kill = subprocess.run(["pkill", "-f", "cueval-fixture --mode lab"], capture_output=True)
        del sh_kill
        self.proc = subprocess.Popen([fixture_bin(LAB_APP), "--mode", "lab", "--state", self.state_path,
                                      "--events", self.events, "--sock", self.sock],
                                     stdout=subprocess.DEVNULL, stderr=open(self.state_path + ".log", "ab"))
        LAB_PID["pid"] = self.proc.pid
        for _ in range(100):
            if self.cmd("ping").get("ok"):
                break
            time.sleep(0.1)
        time.sleep(0.8)
        return self.proc.pid

    def cmd(self, c, timeout=5):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(self.sock)
            s.sendall((c + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                d = s.recv(65536)
                if not d:
                    break
                buf += d
            s.close()
            return json.loads(buf or b"{}")
        except (OSError, ValueError):
            return {}

    def state(self):
        return self.cmd("state")

    def mark(self):
        try:
            return os.path.getsize(self.events)
        except OSError:
            return 0

    def since(self, off):
        out = []
        try:
            with open(self.events) as f:
                f.seek(off)
                for line in f:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
        except OSError:
            pass
        return out

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


# ------------------------------------------------------------------ the scene (native person)

class Scene(bm.Scene):
    def start_person(self):
        if self.person and self.person.poll() is None:
            return
        try:
            os.remove(self.person_state)
        except OSError:
            pass
        self.person = subprocess.Popen([fixture_bin("Person"), "--mode", "person", "--state", self.person_state,
                                        "--geometry", "1400x830+20+30", "--type-interval-ms", "60"],
                                       stdout=subprocess.DEVNULL, stderr=open(self.person_state + ".log", "ab"))
        for _ in range(100):
            if os.path.exists(self.person_state):
                break
            time.sleep(0.1)
        time.sleep(0.8)

    def cover(self):
        """The covered scene: the Person window above every other window (window-server z-order), Person frontmost
        and key. Re-activating an app that is already active does not reorder its windows, so raise the window."""
        ppid = self.person_pid()
        s = {}
        for _ in range(30):
            bm.probe("raise", ppid, "Person")
            s = bm.probe("state")
            z = s.get("zorder") or []
            if z and z[0].get("pid") == ppid and s.get("front_pid") == ppid and s.get("key_window_title") == "Person":
                return True
            time.sleep(0.15)
        self.last_front = f"top window {((s.get('zorder') or [{}])[0]).get('owner')!r}, front {s.get('front_name')!r}"
        return False

    def front_target(self, pid, title):
        s = {}
        for _ in range(30):
            bm.probe("raise", pid, title)
            s = bm.probe("state")
            if s.get("front_pid") == pid and (s.get("key_window_title") or "").startswith(title):
                return True
            time.sleep(0.15)
        self.last_front = f"front {s.get('front_name')!r} pid {s.get('front_pid')}, key window {s.get('key_window_title')!r}"
        return False


# ------------------------------------------------------------------ arm helpers

def find(nodes, name=None, roles=None, pred=None, contains=False):
    for n in nodes:
        if roles and n["role"] not in roles:
            continue
        nm = n.get("name") or ""
        val = str(n.get("value") or "")
        if name is not None:
            if contains:
                if name not in nm and name not in val:
                    continue
            elif nm != name and val != name:
                continue
        if pred and not pred(n):
            continue
        return n
    seen = [f"{n['role']}:{(n.get('name') or str(n.get('value') or ''))[:20]}" for n in nodes
            if not roles or n["role"] in roles or n["role"] in ("tab", "tabgroup", "radio", "unknown")][:40]
    raise bm.ToolError(f"element name={name!r} roles={roles} not in the arm's tree ({len(nodes)} nodes; {seen})")


def right_click_el(arm, w, n):
    if isinstance(arm, bm.Cmux):
        return arm._r(arm.call("click", {"window_id": w["wid"], "element_id": n["key"], "button": "right"}))
    if arm.id.startswith("aside"):
        var = arm.h(w["aside_app"])
        return arm.repl(f"await {var}.click({n['key']}, {{ mouseButton: 'right' }});", title="Right click")
    props = arm_tool_props(arm, "click")
    if "button" in props:
        return arm._r(arm.call("click", {"element_token": n["key"], "button": "right"}))
    if "mouse_button" in props:
        return arm._r(arm.call("click", {"element_token": n["key"], "mouse_button": "right"}))
    raise Unsupported("no right-click in this arm's click tool")


def arm_tool_props(arm, tool):
    for t in getattr(arm.client, "tools", []) or []:
        if t.get("name") == tool:
            return set(((t.get("inputSchema") or {}).get("properties") or {}).keys())
    return set()


class Unsupported(Exception):
    pass


def shot_scale(arm, w, win_w):
    img = arm.screenshot(w)
    sz = bm.png_size(img)
    return (sz[0] / win_w) if sz and win_w else 1.0


def wpt(st_win, widget, fx=0.5, fy=0.5, scale=1.0):
    f = st_win["widgets"][widget]
    return ((f["x"] + f["w"] * fx) * scale, (f["y"] + f["h"] * fy) * scale)


# ------------------------------------------------------------------ cells
# A cell: pre(arm, w, c) (unscored setup actions), act(arm, w, c) (observe, then the scored action: the
# last acting call it makes), read(c) -> a snapshot, judge(before, after, c) -> (truth, detail),
# done(after, c) -> True once the intended effect is complete (polling stops early), post(arm, w, c)
# (cleanup, unscored). expect_none: the right outcome is no effect.

class Cell:
    def __init__(self, name, act, judge, read=None, pre=None, post=None, expect_none=False, done=None):
        self.name, self.act, self.judge, self.read = name, act, judge, read
        self.pre, self.post, self.expect_none, self.done = pre, post, expect_none, done


# ---- lab judges, on oracle events

def st_events(c, win=None, el=None, what=None):
    return [e for e in c["evs"] if e.get("kind") == "state" and (win is None or e.get("win") == win)
            and (el is None or e.get("el") == el) and (what is None or e.get("what") == what)]


def lab_judge(win, touches, ok_final, label):
    """touches: (win, el) pairs the intended effect may change. ok_final(after_state) says the intended
    effect is complete and exact. Other state changes are side effects (extra) or the wrong target."""
    touches = set(touches)

    def j(before, after, c):
        evs = [e for e in c["evs"] if e.get("kind") == "state"]
        inside = [e for e in evs if (e.get("win"), e.get("el")) in touches]
        outside = [e for e in evs if (e.get("win"), e.get("el")) not in touches]
        ok = ok_final(after)
        c["effect_events"] = inside
        side = sorted({f"{e.get('win')}/{e.get('el')}" for e in outside})
        c["side_effects"] = side
        if ok and (inside or not outside):
            # ok with no event at all: the value changed under the app (an AX value set the control's delegate
            # never heard about). Visible, so correct, but flagged: an app's model may not know.
            c["silent"] = not inside
            sfx = " (silent: no app notification)" if not inside else ""
            return ("extra" if outside else "correct"), (f"{label}: ok; side effects {side}" if outside else f"{label}: ok") + sfx
        if inside or outside:
            return "wrong", f"{label}: changed but not right ({_brief(inside + outside)})"
        return "none", f"{label}: no change"
    return j


def _brief(evs):
    return "; ".join(f"{e.get('win')}/{e.get('el')}:{e.get('what')}={str(e.get('value', e.get('len', '')))[:30]}"
                     for e in evs[:6])


def F(s):
    return s.get("form") or {}


def T(s):
    return s.get("text") or {}


def CV(s):
    return s.get("canvas") or {}


def TW(s):
    return s.get("twin") or {}


FORM, TEXT, CANVAS, TWIN = "Truth Form", "Truth Text", "Truth Canvas", "Truth Twin"
LINE_LEN = [len(f"line {i} the quick brown fox jumps over the lazy dog") + 1 for i in range(1, 61)]


def lab_cells():
    cells = []

    def add(name, act, judge, **kw):
        cells.append(Cell(name, act, judge, **kw))

    def tree(arm, w):
        arm.screenshot(w)  # an agent looks first; cmux's settle check compares against the last capture
        return arm.tree(w)

    def el(arm, w, name, roles=None, contains=False):
        return find(tree(arm, w), name, roles, contains=contains)

    def textfield(arm, w, label):
        nodes = tree(arm, w)
        for n in nodes:
            if n["role"] in ("textfield", "securetextfield") and (n["name"] == label or label in (n["name"] or "")):
                return n
        return find(nodes, label, contains=True)

    # Form: checkbox, button, fields
    add("click_el_checkbox", lambda a, w, c: a.click_el(w, el(a, w, "Subscribe to updates")),
        lab_judge(FORM, [(FORM, "subscribe")], lambda s: F(s).get("subscribe") is True, "subscribe"),
        done=lambda s, c: F(s).get("subscribe") is True)

    def px(a, w, c, widget, fx=0.5, fy=0.5, sub=F, win_w=None):
        st = sub(c["lab"].state())
        sc = shot_scale(a, w, st["window"]["w"])
        return a.click_px(w, *wpt(st, widget, fx, fy, sc))

    add("click_px_checkbox", lambda a, w, c: px(a, w, c, "subscribe", 0.06),
        lab_judge(FORM, [(FORM, "subscribe")], lambda s: F(s).get("subscribe") is True, "subscribe"),
        done=lambda s, c: F(s).get("subscribe") is True)
    add("click_el_button_once", lambda a, w, c: a.click_el(w, el(a, w, "Increment", ["button"])),
        lab_judge(FORM, [(FORM, "increment")], lambda s: F(s).get("counter") == 1, "counter==1"),
        done=lambda s, c: F(s).get("counter", 0) >= 1)
    add("click_px_button_once", lambda a, w, c: px(a, w, c, "increment"),
        lab_judge(FORM, [(FORM, "increment")], lambda s: F(s).get("counter") == 1, "counter==1"),
        done=lambda s, c: F(s).get("counter", 0) >= 1)
    add("type_text_el_field", lambda a, w, c: a.type_text(w, "Ada Lovelace", textfield(a, w, "Name")),
        lab_judge(FORM, [(FORM, "name")], lambda s: F(s).get("name") == "Ada Lovelace", "name=='Ada Lovelace'"),
        done=lambda s, c: F(s).get("name") == "Ada Lovelace")
    add("type_text_secure_field", lambda a, w, c: a.type_text(w, "s3cret!", textfield(a, w, "Password")),
        lab_judge(FORM, [(FORM, "password")], lambda s: F(s).get("password") == "s3cret!", "password=='s3cret!'"),
        done=lambda s, c: F(s).get("password") == "s3cret!")
    add("set_value_field", lambda a, w, c: a.set_value(w, textfield(a, w, "Name"), "Grace Hopper"),
        lab_judge(FORM, [(FORM, "name")], lambda s: F(s).get("name") == "Grace Hopper", "name=='Grace Hopper'"),
        done=lambda s, c: F(s).get("name") == "Grace Hopper")

    def pre_focus_name(a, w, c):
        a.click_el(w, textfield(a, w, "Name"))
        time.sleep(0.3)

    add("type_text_focused", lambda a, w, c: (tree(a, w), a.type_text(w, "Zed"))[1],
        lab_judge(FORM, [(FORM, "name")], lambda s: F(s).get("name") == "Zed", "name=='Zed' (focused field)"),
        pre=pre_focus_name, done=lambda s, c: F(s).get("name") == "Zed")

    def pre_type_ada(a, w, c):
        a.type_text(w, "Ada", textfield(a, w, "Name"))
        time.sleep(0.4)

    add("press_key_return", lambda a, w, c: (tree(a, w), a.press_key(w, "Return"))[1],
        lab_judge(FORM, [(FORM, "save"), (FORM, "name")], lambda s: F(s).get("saved") is True and F(s).get("saved_name") == "Ada",
                  "saved with 'Ada'"), pre=pre_type_ada, done=lambda s, c: F(s).get("saved") is True)
    add("radio_click_el", lambda a, w, c: a.click_el(w, el(a, w, "Large", ["radio", "radiobutton", "button"])),
        lab_judge(FORM, [(FORM, "size")], lambda s: F(s).get("size") == "Large", "size==Large"),
        done=lambda s, c: F(s).get("size") == "Large")
    add("popup_set_value", lambda a, w, c: a.set_value(w, find(tree(a, w), roles=["popupbutton"]), "Blue"),
        lab_judge(FORM, [(FORM, "color")], lambda s: F(s).get("color") == "Blue", "color==Blue"),
        done=lambda s, c: F(s).get("color") == "Blue")
    add("slider_set_value", lambda a, w, c: a.set_value(w, find(tree(a, w), roles=["slider"]), "42"),
        lab_judge(FORM, [(FORM, "volume")], lambda s: F(s).get("volume") == 42, "volume==42"),
        done=lambda s, c: F(s).get("volume") == 42)

    def slider_drag(a, w, c):
        st = F(c["lab"].state())
        sc = shot_scale(a, w, st["window"]["w"])
        x0, y0 = wpt(st, "volume", 0.02, 0.5, sc)
        x1, _ = wpt(st, "volume", 0.6, 0.5, sc)
        return a.drag(w, x0, y0, x1, y0)

    add("slider_drag_px", slider_drag,
        lab_judge(FORM, [(FORM, "volume")], lambda s: 35 <= (F(s).get("volume") or 0) <= 85, "volume moved to ~60"),
        done=lambda s, c: (F(s).get("volume") or 0) >= 35)
    add("stepper_click_px", lambda a, w, c: px(a, w, c, "copies", 0.5, 0.25),
        lab_judge(FORM, [(FORM, "copies")], lambda s: F(s).get("copies") == 1, "copies==1"),
        done=lambda s, c: (F(s).get("copies") or 0) >= 1)
    add("tab_click_el", lambda a, w, c: a.click_el(w, el(a, w, "Advanced", ["radio", "radiobutton", "tab", "button"])),
        lab_judge(FORM, [(FORM, "tabs")], lambda s: F(s).get("tab") == "Advanced", "tab==Advanced"),
        done=lambda s, c: F(s).get("tab") == "Advanced")
    add("sheet_open", lambda a, w, c: a.click_el(w, el(a, w, "Show Sheet", ["button"])),
        lab_judge(FORM, [(FORM, "sheet")], lambda s: F(s).get("sheet_open") is True, "sheet open"),
        done=lambda s, c: F(s).get("sheet_open") is True)

    def pre_sheet(a, w, c):
        a.click_el(w, el(a, w, "Show Sheet", ["button"]))
        time.sleep(0.8)

    add("sheet_button", lambda a, w, c: a.click_el(w, el(a, w, "OK", ["button"])),
        lab_judge(FORM, [(FORM, "sheet")], lambda s: F(s).get("sheet_result") == "ok", "sheet closed with OK"),
        pre=pre_sheet, done=lambda s, c: F(s).get("sheet_result") == "ok")
    add("popover_open", lambda a, w, c: a.click_el(w, el(a, w, "Show Popover", ["button"])),
        lab_judge(FORM, [(FORM, "popover")], lambda s: F(s).get("popover_open") is True, "popover shown"),
        done=lambda s, c: F(s).get("popover_open") is True)

    def pre_popover(a, w, c):
        a.click_el(w, el(a, w, "Show Popover", ["button"]))
        time.sleep(0.8)

    add("popover_button", lambda a, w, c: a.click_el(w, el(a, w, "Popover Action", ["button"])),
        lab_judge(FORM, [(FORM, "popover_action"), (FORM, "popover")], lambda s: F(s).get("popover_actions") == 1,
                  "popover action once"), pre=pre_popover, done=lambda s, c: (F(s).get("popover_actions") or 0) >= 1)
    add("context_menu_open", lambda a, w, c: right_click_el(a, w, el(a, w, "Context Target", contains=True)),
        lab_judge(FORM, [(FORM, "context_menu")], lambda s: F(s).get("context_open") is True or
                  any(e.get("what") == "open" and e.get("value") is True for e in []), "context menu opened"),
        done=lambda s, c: bool(st_events(c, FORM, "context_menu", "open")))

    def menu_judge_counter(s):
        f = F(s)
        return f.get("counter") == 1 and f.get("menu_count") == 1

    add("menu_item", lambda a, w, c: (a.screenshot(w), a.menu(w, ["Truth", "Increment Counter"]))[1],
        lab_judge(FORM, [(FORM, "menu_increment")], menu_judge_counter, "Truth > Increment Counter once"),
        done=lambda s, c: (F(s).get("menu_count") or 0) >= 1)
    add("menu_submenu", lambda a, w, c: (a.screenshot(w), a.menu(w, ["Truth", "More", "Nested Action"]))[1],
        lab_judge(FORM, [(FORM, "menu_nested")], lambda s: F(s).get("nested") == 1, "Truth > More > Nested Action once"),
        done=lambda s, c: (F(s).get("nested") or 0) >= 1)
    add("menu_disabled_item", lambda a, w, c: (a.screenshot(w), a.menu(w, ["Truth", "Disabled Item"]))[1],
        lab_judge(FORM, [], lambda s: False, "disabled item must not run"), expect_none=True)
    add("key_chord_menu_equivalent", lambda a, w, c: (a.screenshot(w), a.press_key(w, "cmd+shift+k"))[1],
        lab_judge(FORM, [(FORM, "menu_increment")], menu_judge_counter, "cmd+shift+k ran Increment Counter once"),
        done=lambda s, c: (F(s).get("menu_count") or 0) >= 1)

    def row_node(a, w, label):
        nodes = tree(a, w)
        for n in nodes:
            if (n["name"] == label or str(n["value"] or "") == label) and n["role"] in ("row", "cell", "text", "statictext", "textfield"):
                return n
        return find(nodes, label)

    add("table_click_el_row", lambda a, w, c: a.click_el(w, row_node(a, w, "Row 5")),
        lab_judge(FORM, [(FORM, "table")], lambda s: F(s).get("selected") == 5, "row 5 selected"),
        done=lambda s, c: F(s).get("selected") == 5)

    def table_scroll(a, w, c):
        st = F(c["lab"].state())
        sc = shot_scale(a, w, st["window"]["w"])
        return a.scroll(w, *wpt(st, "table", 0.5, 0.5, sc), dy=5)

    add("table_scroll_px", table_scroll,
        lab_judge(FORM, [(FORM, "table")], lambda s: (F(s).get("first_visible") or 1) > 1, "table scrolled down"),
        done=lambda s, c: (F(s).get("first_visible") or 1) > 1)

    # Text window
    init_len = sum(LINE_LEN)
    add("text_type_el", lambda a, w, c: a.type_text(w, "CUEV", find(tree(a, w), roles=["textarea"])),
        lab_judge(TEXT, [(TEXT, "text")], lambda s: T(s).get("len") == init_len + 4 and T(s).get("text", "").count("CUEV") == 1,
                  "'CUEV' inserted once, nothing else"), done=lambda s, c: "CUEV" in T(s).get("text", ""))
    add("text_cmd_a", lambda a, w, c: (tree(a, w), a.press_key(w, "cmd+a"))[1],
        lab_judge(TEXT, [(TEXT, "text")], lambda s: (T(s).get("sel") or {}).get("len") == T(s).get("len"), "all text selected"),
        done=lambda s, c: (T(s).get("sel") or {}).get("len") == T(s).get("len"))

    def text_click(a, w, c):
        st = T(c["lab"].state())
        sc = shot_scale(a, w, st["window"]["w"])
        f = st["widgets"]["text"]
        # line 5: the text view's line height for 12 pt monospaced is about 14-15 pt; aim inside line 5
        return a.click_px(w, (f["x"] + 30) * sc, (f["y"] + 5 + 14.5 * 4 + 7) * sc)

    l5 = sum(LINE_LEN[:4])
    add("text_click_px", text_click,
        lab_judge(TEXT, [(TEXT, "text")], lambda s: l5 <= (T(s).get("sel") or {}).get("loc", -1) <= l5 + LINE_LEN[4], "caret in line 5"),
        done=lambda s, c: (T(s).get("sel") or {}).get("loc", 0) > 0)

    def text_scroll(a, w, c):
        st = T(c["lab"].state())
        sc = shot_scale(a, w, st["window"]["w"])
        return a.scroll(w, *wpt(st, "text", 0.5, 0.5, sc), dy=8)

    add("text_scroll_px", text_scroll,
        lab_judge(TEXT, [(TEXT, "text")], lambda s: (T(s).get("scroll_top") or 0) > 0, "text scrolled down"),
        done=lambda s, c: (T(s).get("scroll_top") or 0) > 0)
    add("text_set_value", lambda a, w, c: a.set_value(w, find(tree(a, w), roles=["textarea"]), "set by set_value\n"),
        lab_judge(TEXT, [(TEXT, "text")], lambda s: T(s).get("text") == "set by set_value\n", "text replaced exactly"),
        done=lambda s, c: T(s).get("text") == "set by set_value\n")

    # Canvas: no AX element; pixel only
    def canvas_xy(a, w, c, cx, cy):
        st = CV(c["lab"].state())
        sc = shot_scale(a, w, st["window"]["w"])
        f = st["widgets"]["canvas"]
        return (f["x"] + cx) * sc, (f["y"] + cy) * sc

    def canvas_click_ok(s):
        cl = CV(s).get("canvas_clicks") or []
        return len(cl) == 1 and abs(cl[0]["x"] - 120) <= 4 and abs(cl[0]["y"] - 100) <= 4

    add("canvas_click_px", lambda a, w, c: a.click_px(w, *canvas_xy(a, w, c, 120, 100)),
        lab_judge(CANVAS, [(CANVAS, "canvas")], canvas_click_ok, "one click at canvas (120,100) +-4"),
        done=lambda s, c: bool(CV(s).get("canvas_clicks")))
    add("canvas_press_key", lambda a, w, c: (a.screenshot(w), a.press_key(w, "x"))[1],
        lab_judge(CANVAS, [(CANVAS, "canvas")], lambda s: (CV(s).get("canvas_keys") or []) == ["x"], "canvas got 'x' once"),
        pre=lambda a, w, c: (a.click_px(w, *canvas_xy(a, w, c, 300, 200)), time.sleep(0.3)),
        done=lambda s, c: bool(CV(s).get("canvas_keys")))

    def stroke_ok(s):
        evs = [e for e in (s.get("_evs") or []) if e.get("what") == "stroke"]
        return CV(s).get("strokes") == 1

    add("canvas_drag_px", lambda a, w, c: a.drag(w, *canvas_xy(a, w, c, 50, 50), *canvas_xy(a, w, c, 250, 150)),
        lab_judge(CANVAS, [(CANVAS, "canvas")], stroke_ok, "one stroke"),
        done=lambda s, c: (CV(s).get("strokes") or 0) >= 1)

    def dnd(a, w, c):
        st = CV(c["lab"].state())
        sc = shot_scale(a, w, st["window"]["w"])
        return a.drag(w, *wpt(st, "chip", 0.5, 0.5, sc), *wpt(st, "drop", 0.5, 0.5, sc))

    add("drag_and_drop_px", dnd,
        lab_judge(CANVAS, [(CANVAS, "chip"), (CANVAS, "drop")], lambda s: CV(s).get("drops") == 1 and CV(s).get("drop_value") == "truth-chip",
                  "chip dropped once"), done=lambda s, c: (CV(s).get("drops") or 0) >= 1)

    # Twin: same controls as the form, in another window of the same app
    add("twin_type_el", lambda a, w, c: a.type_text(w, "Twin Only", textfield(a, w, "Name")),
        lab_judge(TWIN, [(TWIN, "name")], lambda s: TW(s).get("name") == "Twin Only", "only the twin's name"),
        done=lambda s, c: TW(s).get("name") == "Twin Only")
    add("twin_click_el_checkbox", lambda a, w, c: a.click_el(w, el(a, w, "Subscribe to updates")),
        lab_judge(TWIN, [(TWIN, "subscribe")], lambda s: TW(s).get("subscribe") is True, "only the twin's subscribe"),
        done=lambda s, c: TW(s).get("subscribe") is True)
    return cells


LAB_WINDOW = {
    "text_": TEXT, "canvas_": CANVAS, "drag_and_drop": CANVAS, "twin_": TWIN,
}


def lab_window_for(cell):
    for p, t in LAB_WINDOW.items():
        if cell.startswith(p):
            return t
    return FORM


# ------------------------------------------------------------------ real apps (ground truth by AX / disk)

def tri(ok, changed, extra=False, detail=""):
    if ok:
        return ("extra" if extra else "correct"), detail
    return ("wrong" if changed else "none"), detail


def te_cells():
    W = bm.WORK

    def ta(a, w):
        a.screenshot(w)
        return find(a.tree(w), roles=["textarea"])

    def sel(c):
        return (bm.te_text(c["pid"]) or {}).get("sel")

    def val(c):
        return str((bm.te_text(c["pid"]) or {}).get("value") or "")

    def click(a, w, c):
        f = ta(a, w)["frame"]
        return a.click_px(w, f["x"] + 12, f["y"] + 4 + 13 * 4 + 6)

    def j_click(b, a, c):
        loc = (a or {}).get("loc", -1)
        return tri(a != b and 150 <= loc <= 260, a != b, detail=f"selection {b} -> {a} (line 5 starts at 208)")

    def typ(a, w, c):
        ta(a, w)
        return a.type_text(w, c["tag"])

    def j_type(b, a, c):
        n = a.count(c["tag"])
        return tri(n == 1 and len(a) == len(b) + len(c["tag"]), a != b, extra=False,
                   detail=f"{c['tag']} x{n}, length {len(b)} -> {len(a)}") if n <= 1 else ("wrong", f"{c['tag']} typed {n} times")

    def cmda(a, w, c):
        a.screenshot(w)
        return a.press_key(w, "cmd+a")

    def read_sel(c):
        t = bm.te_text(c["pid"]) or {}
        return (t.get("sel") or {}).get("len"), t.get("vlen")

    def j_cmda(b, a, c):
        return tri(a[0] == a[1] and (a[1] or 0) > 100, a != b, detail=f"selection {b} -> {a}")

    def pre_s(a, w, c):
        ta(a, w)
        a.type_text(w, c["tag"])
        time.sleep(0.4)

    def cmds(a, w, c):
        a.screenshot(w)
        return a.press_key(w, "cmd+s")

    def disk(c):
        return open(f"{W}/te.txt").read()

    def j_save(b, a, c):
        return tri(c["tag"] in a, a != b, detail=f"{c['tag']} saved to disk: {c['tag'] in a}")

    def scr(a, w, c):
        f = ta(a, w)["frame"]
        return a.scroll(w, f["x"] + 200, min(f["y"] + 200, 400), dy=10)

    def top(c):
        t = bm.te_text(c["pid"]) or {}
        return (t.get("pos") or {}).get("y")

    def j_scr(b, a, c):
        return tri(a is not None and b is not None and a < b, a != b, detail=f"text area top y {b} -> {a}")

    def drg(a, w, c):
        f = ta(a, w)["frame"]
        y0 = max(f["y"], 32) + 4
        return a.drag(w, 12, y0 + 6, 300, y0 + 13 * 3 + 6)

    def j_drg(b, a, c):
        return tri((a or {}).get("len", 0) > 20, a != b, detail=f"selection {b} -> {a}")

    def setv(a, w, c):
        return a.set_value(w, ta(a, w), c["val"])

    def j_setv(b, a, c):
        return tri(a == c["val"], a != b, detail=f"value {a[:40]!r}")

    def menu(a, w, c):
        a.screenshot(w)
        return a.menu(w, ["Format", "Make Rich Text"])

    def rich(c):
        nodes, _ = bm.ax_nodes(c["pid"], 6, menus=True)
        return bm.ax_find(nodes, "AXMenuItem", pred=lambda n: n.get("title") == "Make Plain Text") is not None

    return [
        Cell("click_px", click, j_click, read=sel),
        Cell("type_text", typ, j_type, read=val, done=lambda s, c: c["tag"] in s),
        Cell("press_key_cmd_a", cmda, j_cmda, read=read_sel, done=lambda s, c: s[0] == s[1]),
        Cell("press_key_cmd_s", cmds, j_save, read=disk, pre=pre_s, done=lambda s, c: c["tag"] in s),
        Cell("scroll", scr, j_scr, read=top),
        Cell("drag_select", drg, j_drg, read=sel, done=lambda s, c: (s or {}).get("len", 0) > 20),
        Cell("set_value", setv, j_setv, read=val, done=lambda s, c: s == c["val"]),
        Cell("menu_item", menu, lambda b, a, c: tri(a and not b, a != b, detail=f"Make Plain Text offered: {a}"), read=rich,
             done=lambda s, c: s),
    ]


def calc_cells():
    def clear(a, w, c):
        a.press_key(w, "Escape")
        time.sleep(0.3)

    def disp(c):
        return bm.calc_display(c["pid"])

    def jd(want):
        def j(b, a, c):
            if a == want:
                return "correct", f"display {b!r} -> {a!r}"
            if a and want and a == want * 2:
                return "wrong", f"display {a!r}: duplicated"
            return ("wrong" if a != b else "none"), f"display {b!r} -> {a!r}, want {want!r}"
        return j

    def btn(a, w, name):
        a.screenshot(w)
        return find(a.tree(w), name, ["button"])

    def ret_pre(a, w, c):
        clear(a, w, c)
        for n in ("9", "Add", "1"):
            a.click_el(w, btn(a, w, n))
        time.sleep(0.3)

    def width(c):
        return aside_arm.calc_width(c["pid"])

    def restore_basic(a, w, c):
        if (width(c) or 0) > 400:
            try:
                a.press_key(w, "cmd+1")
            except bm.ToolError:
                pass
            time.sleep(0.8)

    def jw(b, a, c):
        return tri(bool(b and a and a > b), a != b, detail=f"window width {b} -> {a}")

    return [
        Cell("click_element", lambda a, w, c: a.click_el(w, btn(a, w, "7")), jd("7"), read=disp, pre=clear,
             done=lambda s, c: s == "7"),
        Cell("click_px", lambda a, w, c: a.click_px(w, *bm.center(btn(a, w, "8"))), jd("8"), read=disp, pre=clear,
             done=lambda s, c: s == "8"),
        Cell("type_text", lambda a, w, c: (a.screenshot(w), a.type_text(w, "12+3="))[1], jd("15"), read=disp, pre=clear,
             done=lambda s, c: s == "15"),
        Cell("press_key", lambda a, w, c: (a.screenshot(w), a.press_key(w, "4"))[1], jd("4"), read=disp, pre=clear,
             done=lambda s, c: s == "4"),
        Cell("press_key_return", lambda a, w, c: (a.screenshot(w), a.press_key(w, "Return"))[1], jd("10"), read=disp,
             pre=ret_pre, done=lambda s, c: s == "10"),
        Cell("press_key_chord_cmd_2", lambda a, w, c: (a.screenshot(w), a.press_key(w, "cmd+2"))[1], jw, read=width,
             pre=restore_basic, post=restore_basic, done=lambda s, c: (s or 0) > 400),
        Cell("menu_item", lambda a, w, c: (a.screenshot(w), a.menu(w, ["View", "Scientific"]))[1], jw, read=width,
             pre=restore_basic, post=restore_basic, done=lambda s, c: (s or 0) > 400),
    ]


def safari_cells():
    def web(a, w, role, name):
        a.screenshot(w)
        return find(a.tree(w), roles=[role], pred=lambda n: (n["name"] or "").startswith(name))

    def page(c):
        return bm.page_status(c["pid"])[0]

    def jclicks(b, a, c):
        try:
            d = int(a["clicks"] or 0) - int(b["clicks"] or 0)
        except (TypeError, ValueError):
            d = 0
        return ("correct" if d == 1 else "wrong" if d > 1 else "none"), f"clicks {b['clicks']} -> {a['clicks']}"

    def jname(key, exact):
        def j(b, a, c):
            want = c[key]
            v = str(a.get("name") or "")
            ok = (v == want) if exact else (v.count(want) == 1)
            return tri(ok, a.get("name") != b.get("name"), detail=f"Name field {b.get('name')!r} -> {v!r}")
        return j

    def scroll(a, w, c):
        a.screenshot(w)
        n = find(a.tree(w), pred=lambda n: (n["name"] or str(n["value"] or "")).startswith("Row 3"))
        return a.scroll(w, *bm.center(n), dy=8)

    def drag(a, w, c):
        s = web(a, w, "slider", "")
        f = s["frame"]
        x0 = f["x"] + f["width"] * float(page(c)["slider"] or 10) / 100
        y0 = f["y"] + f["height"] / 2
        return a.drag(w, x0, y0, x0 + f["width"] * 0.4, y0)

    def zoom_back(a, w, c):
        try:
            a.menu(w, ["View", "Actual Size"])
        except bm.ToolError:
            pass
        time.sleep(0.6)

    return [
        Cell("click_element", lambda a, w, c: a.click_el(w, web(a, w, "button", "Press Me")), jclicks, read=page,
             done=lambda s, c: s["clicks"] not in (None, c["before"]["clicks"])),
        Cell("click_px", lambda a, w, c: a.click_px(w, *bm.center(web(a, w, "button", "Press Me"))), jclicks, read=page,
             done=lambda s, c: s["clicks"] not in (None, c["before"]["clicks"])),
        Cell("type_text", lambda a, w, c: a.type_text(w, c["tag"], web(a, w, "textfield", "Name")), jname("tag", False),
             read=page, done=lambda s, c: c["tag"] in str(s.get("name") or "")),
        Cell("press_key_chord_cmd_a", lambda a, w, c: (a.screenshot(w), a.press_key(w, "cmd+a"))[1],
             # the effect of cmd+a is the selection (Select All); the keydown is how the page saw it, if it did
             lambda b, a, c: tri(int(a.get("sel") or 0) > 500, a != b,
                                 detail=f"page keydown {a['keys']!r}, selection {b.get('sel')} -> {a.get('sel')} chars"),
             read=page, done=lambda s, c: int(s.get("sel") or 0) > 500),
        Cell("scroll", scroll, lambda b, a, c: tri(int(a["scroll"] or 0) > int(b["scroll"] or 0), a["scroll"] != b["scroll"],
                                                   detail=f"scrollY {b['scroll']} -> {a['scroll']}"), read=page,
             done=lambda s, c: int(s["scroll"] or 0) > int(c["before"]["scroll"] or 0)),
        Cell("drag_slider", drag, lambda b, a, c: tri(a["slider"] not in (None, b["slider"]), False,
                                                      detail=f"slider {b['slider']} -> {a['slider']}"), read=page,
             done=lambda s, c: s["slider"] not in (None, c["before"]["slider"])),
        Cell("set_value", lambda a, w, c: a.set_value(w, web(a, w, "textfield", "Name"), c["val"]), jname("val", True),
             read=page, done=lambda s, c: s.get("name") == c["val"]),
        Cell("menu_item", lambda a, w, c: (a.screenshot(w), a.menu(w, ["View", "Zoom In"]))[1],
             lambda b, a, c: tri(a["w"] not in (None, b["w"]), False, detail=f"page innerWidth {b['w']} -> {a['w']}"),
             read=page, post=zoom_back, done=lambda s, c: s["w"] not in (None, c["before"]["w"])),
    ]


def finder_cells():
    W = bm.WORK

    def fnode(a, w, name):
        a.screenshot(w)
        for n in a.tree(w):
            if (n["name"] == name or str(n["value"] or "") == name) and n["frame"] and n["frame"].get("height", 0) > 0:
                return n
        raise bm.ToolError(f"{name} not in the arm's tree")

    def sel(c):
        return bm.finder_sel(c["pid"])

    def jsel(want):
        def j(b, a, c):
            n, names = a
            ok = n == 1 and bool(names) and str(names[0]) == want
            return tri(ok, a != b, detail=f"selected {n} {str(names)[:60]}")
        return j

    def folders(c):
        return sorted(d for d in os.listdir(f"{W}/finder") if d.startswith("untitled folder"))

    def jfolder(b, a, c):
        k = len(a) - len(b)
        return ("correct" if k == 1 else "wrong" if k > 1 else "none"), f"new folders on disk {a}"

    def rm_folders(a, w, c):
        if folders(c):
            try:
                a.press_key(w, "Escape")
            except bm.ToolError:
                pass
            time.sleep(0.3)
            for d in folders(c):
                bm.sh(f"rm -rf '{W}/finder/{d}'")

    def bars(c):
        nodes, _ = bm.ax_nodes(c["pid"], 30)
        return [x.get("value") for x in nodes if x.get("_win") == "finder" and x.get("role") == "AXScrollBar"]

    def moved(c):
        return os.path.exists(f"{W}/finder/dest/file-07.txt")

    def mv_back(a, w, c):
        if moved(c):
            bm.sh(f"mv {W}/finder/dest/file-07.txt {W}/finder/")

    def view(c):
        return bm.finder_view(c["pid"])

    def as_list(a, w, c):
        try:
            a.menu(w, ["View", "as List"])
        except bm.ToolError:
            pass
        time.sleep(0.8)

    return [
        Cell("click_element", lambda a, w, c: a.click_el(w, fnode(a, w, "file-03.txt")), jsel("file-03.txt"), read=sel,
             done=lambda s, c: s[0] == 1),
        Cell("click_px", lambda a, w, c: a.click_px(w, *bm.center(fnode(a, w, "file-05.txt"))), jsel("file-05.txt"), read=sel,
             done=lambda s, c: s[0] == 1),
        Cell("press_key_cmd_a", lambda a, w, c: (a.screenshot(w), a.press_key(w, "cmd+a"))[1],
             lambda b, a, c: tri(a[0] == 41, a != b, detail=f"selected {a[0]} of 41"), read=sel, done=lambda s, c: s[0] == 41),
        Cell("press_key_cmd_shift_n", lambda a, w, c: (a.screenshot(w), a.press_key(w, "cmd+shift+n"))[1], jfolder,
             read=folders, post=rm_folders, done=lambda s, c: len(s) > len(c["before"])),
        Cell("type_text_select", lambda a, w, c: (a.screenshot(w), a.type_text(w, "file-2"))[1],
             lambda b, a, c: tri(a[0] == 1 and bool(a[1]) and str(a[1][0]).startswith("file-2"), a != b,
                                 detail=f"type-select {a[0]} {str(a[1])[:60]}"), read=sel, done=lambda s, c: s[0] == 1),
        Cell("scroll", lambda a, w, c: a.scroll(w, *bm.center(fnode(a, w, "file-03.txt")), dy=10),
             lambda b, a, c: tri(any(isinstance(x, (int, float)) and isinstance(y, (int, float)) and x > y for x, y in zip(a, b)),
                                 a != b, detail=f"scroll bars {b} -> {a}"),
             read=bars),
        Cell("drag_file_to_folder", lambda a, w, c: a.drag(w, *bm.center(fnode(a, w, "file-07.txt")), *bm.center(fnode(a, w, "dest"))),
             lambda b, a, c: tri(a, False, detail=f"file-07 moved into dest: {a}"), read=moved, post=mv_back, done=lambda s, c: s),
        Cell("menu_item", lambda a, w, c: (a.screenshot(w), a.menu(w, ["View", "as Icons"]))[1],
             lambda b, a, c: tri(a == "other", a != b, detail=f"view {b} -> {a}"), read=view, post=as_list,
             done=lambda s, c: s == "other"),
    ]


def notes_cells():
    def count(c):
        return bm.notes_count(c["pid"])

    def jn(b, a, c):
        if a[0] is None or b[0] is None:
            return "none", f"notes {b[0]} -> {a[0]}"
        k = a[0] - b[0]
        return ("correct" if k == 1 else "wrong" if k > 1 else "none"), f"notes {b[0]} -> {a[0]}"

    def body(c):
        return bm.notes_count(c["pid"])[1]

    def bodysel(c):
        nodes, _ = bm.ax_nodes(c["pid"], 40)
        b = bm.ax_find(nodes, "AXTextArea")
        return ((b or {}).get("sel") or {}).get("len", 0), len(str((b or {}).get("value") or ""))

    def focused(c):
        nodes, _ = bm.ax_nodes(c["pid"], 40)
        b = bm.ax_find(nodes, "AXTextArea")
        return bool(b and b.get("focused"))

    def ta(a, w):
        a.screenshot(w)
        return find(a.tree(w), roles=["textarea"])

    return [
        Cell("menu_item", lambda a, w, c: (a.screenshot(w), a.menu(w, ["File", "New Note"]))[1], jn, read=count,
             done=lambda s, c: (s[0] or 0) > (c["before"][0] or 0)),
        Cell("click_element", lambda a, w, c: a.click_el(w, (a.screenshot(w), find(a.tree(w), roles=["button"],
                                                                                     pred=lambda n: "new note" in json.dumps(n).lower()))[1]),
             jn, read=count, done=lambda s, c: (s[0] or 0) > (c["before"][0] or 0)),
        Cell("type_text", lambda a, w, c: (ta(a, w), a.type_text(w, c["tag"]))[1],
             lambda b, a, c: tri(str(a or "").count(c["tag"]) == 1, a != b, detail=f"body {str(a)[:50]!r}"), read=body,
             done=lambda s, c: c["tag"] in str(s or "")),
        Cell("press_key_cmd_a", lambda a, w, c: (ta(a, w), a.press_key(w, "cmd+a"))[1],
             lambda b, a, c: tri(a[0] == a[1] and a[1] > 0, a != b, detail=f"body selection {a}"), read=bodysel,
             done=lambda s, c: s[0] == s[1] and s[1] > 0),
        Cell("set_value", lambda a, w, c: a.set_value(w, ta(a, w), c["val"]),
             lambda b, a, c: tri(str(a or "").strip() == c["val"], a != b, detail=f"body {str(a)[:50]!r}"), read=body,
             done=lambda s, c: str(s or "").strip() == c["val"]),
        Cell("click_px_new_note", lambda a, w, c: a.click_px(w, *bm.center((a.screenshot(w), find(a.tree(w), roles=["button"],
             pred=lambda n: "new note" in json.dumps(n).lower()))[1])), jn, read=count,
             done=lambda s, c: (s[0] or 0) > (c["before"][0] or 0)),
    ]


def settings_cells():
    def pane(c):
        return bm.settings_title(c["pid"])

    def target_of(c, first, other):
        return first if c["before"] != first else other

    def side(a, w, name):
        a.screenshot(w)
        return find(a.tree(w), pred=lambda n: (n["name"] or str(n["value"] or "")) == name and (n["frame"] or {}).get("height", 0) > 0)

    def jp(b, a, c):
        return tri(a == c["want"], a != b, detail=f"pane {b!r} -> {a!r}, want {c['want']!r}")

    def ce(a, w, c):
        c["want"] = target_of(c, "General", "Appearance")
        return a.click_el(w, side(a, w, c["want"]))

    def cp(a, w, c):
        c["want"] = target_of(c, "Accessibility", "Appearance")
        return a.click_px(w, *bm.center(side(a, w, c["want"])))

    def bars(c):
        return [x.get("value") for x in bm.ax_nodes(c["pid"], 30)[0] if x.get("role") == "AXScrollBar"]

    def search(c):
        nodes, _ = bm.ax_nodes(c["pid"], 30)
        return (bm.ax_find(nodes, "AXTextField") or {}).get("value")

    def clear_search(a, w, c):
        try:
            a.set_value(w, find(a.tree(w), roles=["textfield", "searchfield"]), "")
        except bm.ToolError:
            pass

    return [
        Cell("click_element", ce, jp, read=pane, done=lambda s, c: s == c.get("want")),
        Cell("click_px", cp, jp, read=pane, done=lambda s, c: s == c.get("want")),
        Cell("scroll", lambda a, w, c: a.scroll(w, *bm.center(side(a, w, "Network")), dy=10),
             lambda b, a, c: tri(a != b, False, detail=f"scroll bars {b} -> {a}"), read=bars),
        Cell("type_text", lambda a, w, c: a.type_text(w, "disp", (a.screenshot(w), find(a.tree(w), roles=["textfield", "searchfield"]))[1]),
             lambda b, a, c: tri(a == "disp", a != b, detail=f"search field {b!r} -> {a!r}"), read=search, post=clear_search,
             done=lambda s, c: s == "disp"),
    ]


REAL = {
    "textedit": (bm.te_setup, lambda ws: next(w for w in ws if w["title"] == "te.txt"), te_cells, "TextEdit", "te.txt"),
    "calculator": (bm.calc_setup, lambda ws: next(w for w in ws if w["title"] == "Calculator"), calc_cells, "Calculator", "Calculator"),
    "safari": (bm.safari_setup, lambda ws: next(w for w in ws if w["title"] == "CUEV Page"), safari_cells, "Safari", "CUEV Page"),
    "finder": (bm.finder_setup, lambda ws: next(w for w in ws if w["title"] == "finder"), finder_cells, "Finder", "finder"),
    "notes": (bm.notes_setup, lambda ws: next(w for w in ws if w["title"].startswith("Notes")), notes_cells, "Notes", "Notes"),
    "settings": (bm.settings_setup, lambda ws: next(w for w in ws if w["app"] in ("com.apple.systempreferences", "System Settings")),
                 settings_cells, "System Settings", ""),
}


# ------------------------------------------------------------------ one cell

def run_cell(arm, scene, app, cell, w, rep, scene_kind, ctx, out, late):
    cdir = os.path.join(out, "cells", f"{arm.id}-{app}-{scene_kind}-{cell.name}-r{rep}")
    os.makedirs(cdir, exist_ok=True)
    lab = ctx.get("lab")
    c = {"pid": ctx["pid"], "rep": rep, "dir": cdir, "lab": lab, "tag": f"CUEV{rep}{scene_kind}X",
         "val": f"set value {rep} {scene_kind}", "evs": []}
    note = ""
    if lab:
        lab.cmd("reset")
        time.sleep(0.25)
    # arrange the scene
    if scene_kind in ("bg", "bgc"):
        if not scene.front_person():
            note = "person could not be made frontmost"
        elif scene_kind == "bgc" and not scene.cover():
            note = "person window could not be put above the target: " + getattr(scene, "last_front", "")
    else:
        if not scene.front_target(ctx["pid"], ctx["title"] if not lab else lab_window_for(cell.name)):
            note = "target could not be made frontmost and key: " + getattr(scene, "last_front", "")
    arm.calls = []
    read = cell.read or (lambda c: lab.state())
    err = None
    truth, detail = None, ""
    pre_calls = 0
    try:
        if cell.pre:
            cell.pre(arm, w, c)
            if any(x.get("is_error") for x in arm.calls):
                raise bm.ToolError("a setup call failed: " + next(x["result"] for x in arm.calls if x.get("is_error"))[:200])
        pre_calls = len(arm.calls)
        c["before"] = read(c)
    except (bm.ToolError, Unsupported) as e:
        err = f"pre: {e}"
    except Exception as e:
        err = f"pre: {type(e).__name__}: {e}"
    mark = lab.mark() if lab else 0
    pre_state = bm.probe("state")
    p_pre = scene.person_read()
    watch = bm.Watcher()
    t_start = time.time()
    unsupported = False
    if err is None:
        try:
            cell.act(arm, w, c)
        except Unsupported as e:
            unsupported, err = True, f"unsupported: {e}"
        except bm.ToolError as e:
            err = f"tool error: {e}"
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
            detail = traceback.format_exc()[-600:]
    acts = [x for x in arm.calls[pre_calls:] if is_acting(x)] if not (err or "").startswith("pre:") else []
    scored = acts[-1] if acts else None
    claim = claim_of(arm.id, scored) if scored else None
    t_result = (scored or {}).get("t1") or time.time()
    # poll the ground truth until the intended effect is complete (then a short grace for extras) or the late window ends
    after, first_ok_t = None, None
    deadline = t_result + late if scored else time.time()
    while True:
        after = read(c) if err is None or scored else None
        if lab:
            c["evs"] = lab.since(mark)
        if after is not None and cell.done:
            try:
                if cell.done(after, c) and first_ok_t is None:
                    first_ok_t = time.time()
            except Exception:
                pass
        now = time.time()
        if first_ok_t and now > first_ok_t + 0.6:
            break
        if now > deadline:
            break
        time.sleep(0.12)
    samples = watch.stop()
    if scored is not None and "before" in c:
        try:
            truth, detail = cell.judge(c["before"], after, c)
        except Exception as e:
            truth, detail = "none", f"judge failed: {type(e).__name__}: {e}"
    # effect timing: lab events give exact times; real apps the poll time when the effect was first complete
    effect_t = None
    if lab and c.get("effect_events"):
        effect_t = min(e["t"] for e in c["effect_events"])
    elif first_ok_t:
        effect_t = first_ok_t
    obs_side = [e for e in c["evs"] if e.get("kind") == "state" and scored and e["t"] < scored.get("t0", 0)]
    post_state = bm.probe("state")
    p_post = scene.person_read()
    if cell.post:
        try:
            cell.post(arm, w, c)
        except Exception:
            pass
    ppid = scene.person_pid()
    fronts = sorted({s["front_pid"] for s in samples})
    keys = sorted({s["key"] for s in samples})
    ptrs = sorted({tuple(s["ptr"]) for s in samples})
    leaked = p_post.get("keys_received", [])[len(p_pre.get("keys_received", [])):]
    zpre, zpost = bm.zorder_ids(pre_state), bm.zorder_ids(post_state)
    common = [i for i in zpre if i in zpost]
    z_ok = [i for i in zpost if i in common] == common and (zpost[:1] == zpre[:1])
    focus_evs = [e for e in c["evs"] if e.get("kind") == "focus" and e.get("what") == "became_active"]
    outcome = "unsupported" if unsupported else confusion_cell(claim, truth, cell.expect_none) if scored else "no_action"
    row = {
        "arm": arm.id, "app": app, "action": cell.name, "scene": scene_kind, "rep": rep, "claim": claim, "truth": truth,
        "outcome": outcome, "expect_none": cell.expect_none, "detail": detail if not err or scored else err, "error": err,
        "effect_ms": round((effect_t - t_result) * 1000) if effect_t else None,
        "late": bool(effect_t and effect_t - t_result > 0.5),
        "result_ms": round(((scored or {}).get("t1", 0) - (scored or {}).get("t0", 0)) * 1000) if scored else None,
        "scored_call": scored, "calls": arm.calls, "events": c["evs"][:80], "obs_side_effects": obs_side[:10],
        "silent": bool(c.get("silent")), "side_effects": c.get("side_effects", []), "note": note, "target_window": {k: v for k, v in w.items() if k != "raw"},
    }
    tw = int(w["wid"]) if str(w.get("wid", "")).isdigit() else None
    zids = bm.zorder_ids(pre_state)
    row.update(z_top_before=(pre_state.get("zorder") or [{}])[0].get("owner"), z_before=zids[:8], z_after=bm.zorder_ids(post_state)[:8],
               target_covered=bool(tw in zids and zids.index(tw) > 0 and (pre_state.get("zorder") or [{}])[0].get("pid") == scene.person_pid()))
    if scene_kind in ("bg", "bgc"):
        row.update(front_ok=fronts == [ppid], key_ok=keys == ["Person"], pointer_ok=len(ptrs) == 1, keys_ok=not leaked,
                   zorder_ok=z_ok, fixture_focus_events=focus_evs[:5], leaked_keys=leaked[:20], fronts_seen=fronts,
                   keys_seen=keys)
        row["background_safe"] = row["front_ok"] and row["key_ok"] and row["pointer_ok"] and row["keys_ok"] and z_ok and not focus_evs
    with open(os.path.join(out, "truth.jsonl"), "a") as f:
        f.write(json.dumps(row, default=str) + "\n")
    print(f"{outcome:11} claim={str(claim):17} truth={str(truth):8} {arm.id:10} {app:10} {scene_kind} {cell.name:28} r{rep} "
          f"eff={row['effect_ms']}ms {(row['detail'] or '')[:110]}", flush=True)
    return row


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--apps", default="lab,textedit,calculator,safari,finder,notes,settings")
    ap.add_argument("--actions", default="")
    ap.add_argument("--scenes", default="bg,fg")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--rep-start", type=int, default=1)
    ap.add_argument("--late", type=float, default=LATE_DEFAULT)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    os.makedirs(bm.WORK, exist_ok=True)
    scene = Scene(a.out)
    arm = bm.make_arm(a.arm, a.out)
    with open(os.path.join(a.out, f"tools-{a.arm}.json"), "w") as f:
        json.dump(getattr(arm.client, "tools", None), f, indent=1, default=str)
    only = set(filter(None, a.actions.split(",")))
    lab = None
    try:
        for app in a.apps.split(","):
            for rep in range(a.rep_start, a.rep_start + a.reps):
                for scene_kind in a.scenes.split(","):
                    scene.start_person()
                    scene.front_person()
                    ctx = {"out": a.out}
                    try:
                        if app == "lab":
                            lab = lab or Lab(a.out)
                            ctx["pid"] = lab.start()
                            ctx["lab"] = lab
                            aside_arm.CURRENT["app"] = LAB_APP
                            cells = lab_cells()
                            pick = None
                        else:
                            setup, pick, mk, aname, title = REAL[app]
                            aside_arm.CURRENT["app"] = aname
                            ctx["pid"] = setup(ctx)
                            ctx["title"] = title
                            cells = mk()
                        scene.front_person()
                        time.sleep(0.5)
                        wins = arm.windows()
                    except Exception as e:
                        print(f"SETUP-FAIL {a.arm} {app} r{rep} {scene_kind}: {type(e).__name__}: {e}", flush=True)
                        with open(os.path.join(a.out, "truth.jsonl"), "a") as f:
                            f.write(json.dumps({"arm": a.arm, "app": app, "rep": rep, "scene": scene_kind,
                                                "setup_error": f"{type(e).__name__}: {e}"}) + "\n")
                        continue
                    for cell in cells:
                        if only and cell.name not in only:
                            continue
                        try:
                            wins = arm.windows()
                            if app == "lab":
                                title = lab_window_for(cell.name)
                                w = next(x for x in wins if x["title"] == title)
                            else:
                                w = pick(wins)
                        except (StopIteration, bm.ToolError) as e:
                            print(f"NO-WINDOW {a.arm} {app} {cell.name} r{rep}: {e}", flush=True)
                            continue
                        run_cell(arm, scene, app, cell, w, rep, scene_kind, ctx, a.out, a.late)
    finally:
        arm.close()
        scene.stop()
        if lab:
            lab.stop()


if __name__ == "__main__":
    main()
