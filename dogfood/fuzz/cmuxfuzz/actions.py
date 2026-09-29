"""The fuzzer's action space.

An action is data: `{"do": name, ...params}`. Params never name a pane,
surface or workspace id. They hold fractions in [0, 1) that pick one of
whatever exists when the step runs, so a replay against a fresh app, or any
subsequence the minimizer tries, still runs. Generation (random, seeded) and
execution (deterministic given the app's state) are separate.
"""

from __future__ import annotations

import json
import random
import time
from dataclasses import dataclass
from typing import Any, Callable

from .sock import SocketError, SocketTimeout


class Skip(Exception):
    """The action does not apply to the current state (nothing to close, no second pane, ...)."""


@dataclass(frozen=True)
class Kind:
    name: str
    area: str
    weight: float
    gen: Callable[[random.Random], dict]
    needs_pointer: bool = False


def pick(items: list, fraction: float):
    if not items:
        raise Skip("nothing to pick from")
    return items[min(int(fraction * len(items)), len(items) - 1)]


# ----------------------------------------------------------------- generators

# The main window's minimum content size (SessionPersistencePolicy.minimumWindowWidth/Height).
# The app raises a smaller frame to it, so a resize step below it would silently test the minimum instead.
MIN_WINDOW_WIDTH = 300
MIN_WINDOW_HEIGHT = 400
WINDOW_WIDTHS = [320, 480, 800, 1280, 1920, 2600]
WINDOW_HEIGHTS = [MIN_WINDOW_HEIGHT, 560, 700, 1080, 1600]


def _f(rng: random.Random) -> float:
    return round(rng.random(), 3)


_TEXTS = [
    "echo hello\n",
    "printf '\\e[31mred\\e[0m \\e[1mbold\\e[0m\\n'\n",
    "seq 1 4000\n",
    "yes 'wide 字 😀 text' | head -n 800\n",
    "printf '%.0s─' {1..600}; echo\n",
    "clear\n",
    "tput cup 5 5; echo moved\n",
    "printf '\\e[?1049h'; sleep 0.3; printf '\\e[?1049l'\n",
    "for i in 1 2 3; do printf '\\r%s' $i; sleep 0.05; done; echo\n",
    "cat /dev/urandom | head -c 3000 | base64\n",
    "printf '\\e]0;title %s\\a' $RANDOM\n",
    "stty size\n",
]

_TITLES = ["build", "", "  spaced  ", "שלום", "日本語のワークスペース", "🔥" * 12, "x" * 300, "a\tb", "../../etc"]

_SHORTCUTS = [
    "cmd+d", "cmd+shift+d", "cmd+shift+enter", "cmd+ctrl+=", "cmd+opt+left", "cmd+opt+right",
    "cmd+opt+up", "cmd+opt+down", "ctrl+shift+h", "ctrl+shift+l", "ctrl+shift+j", "ctrl+shift+k",
    "cmd+ctrl+w",
    "cmd+t", "cmd+w", "cmd+shift+]", "cmd+shift+[", "cmd+1", "cmd+2", "cmd+9", "cmd+b",
    "cmd+shift+p", "escape", "cmd+n", "cmd+shift+w", "cmd+k", "cmd+plus", "cmd+minus", "cmd+0",
]

_PALETTE_RUNNABLE = ["split", "new tab", "new workspace", "toggle sidebar"]


def _palette(r: random.Random) -> dict:
    query = r.choice(["", "split", "new", "zz", "work", "ä", "close", *_PALETTE_RUNNABLE])
    then = r.choice(["escape", "down", "none"] + (["enter"] if query in _PALETTE_RUNNABLE else []))
    return {"query": query, "then": then}


_WORKSPACE_ACTIONS = ["pin", "unpin", "move_up", "move_down", "move_top", "mark_read", "mark_unread", "clear_name"]

KINDS: list[Kind] = [
    # splits
    Kind("split", "splits", 6, lambda r: {"dir": r.choice("rdlu"), "via": r.choice(["socket", "shortcut"])}),
    Kind("close_surface", "splits", 3, lambda r: {"f": _f(r)}),
    Kind("zoom", "splits", 1.5, lambda r: {}),
    Kind("equalize", "splits", 1.5, lambda r: {}),
    Kind("focus_pane", "splits", 2, lambda r: {"f": _f(r)}),
    Kind("resize_pane", "splits", 2, lambda r: {"f": _f(r), "dir": r.choice(["left", "right", "up", "down"]),
                                                "amount": r.choice([1, 5, 40, 400])}),
    Kind("swap_panes", "splits", 1, lambda r: {"a": _f(r), "b": _f(r)}),
    # pointer drags (cua-driver)
    Kind("drag_divider", "drag", 5, lambda r: {"f": _f(r), "delta": round(r.uniform(-0.6, 0.6), 3),
                                               "overshoot": r.random() < 0.15, "ms": r.choice([80, 300, 900])},
         needs_pointer=True),
    Kind("drag_tab", "drag", 5, lambda r: {"src": _f(r), "tab": _f(r), "dst": _f(r),
                                           "zone": r.choice(["center", "left", "right", "top", "bottom",
                                                             "tabbar", "sidebar", "outside"]),
                                           "ms": r.choice([150, 500, 1200])},
         needs_pointer=True),
    Kind("click_pane", "drag", 1, lambda r: {"f": _f(r), "x": _f(r), "y": _f(r)}, needs_pointer=True),
    # tabs
    Kind("new_tab", "tabs", 3, lambda r: {"via": r.choice(["socket", "shortcut"]), "f": _f(r)}),
    Kind("close_tab", "tabs", 2, lambda r: {}),
    Kind("focus_surface", "tabs", 2, lambda r: {"f": _f(r)}),
    Kind("move_surface", "tabs", 3, lambda r: {"s": _f(r), "p": _f(r), "i": _f(r)}),
    Kind("reorder_surface", "tabs", 1.5, lambda r: {"s": _f(r), "i": _f(r)}),
    Kind("drag_to_split", "tabs", 2, lambda r: {"s": _f(r), "dir": r.choice(["left", "right", "up", "down"])}),
    # workspaces
    Kind("workspace_create", "workspaces", 3, lambda r: {}),
    Kind("workspace_close", "workspaces", 1.5, lambda r: {"f": _f(r)}),
    Kind("workspace_select", "workspaces", 3, lambda r: {"f": _f(r)}),
    Kind("workspace_reorder", "workspaces", 1.5, lambda r: {"f": _f(r), "i": _f(r)}),
    Kind("workspace_rename", "workspaces", 1, lambda r: {"f": _f(r), "title": r.choice(_TITLES)}),
    Kind("workspace_action", "workspaces", 1, lambda r: {"f": _f(r), "action": r.choice(_WORKSPACE_ACTIONS)}),
    # sidebar
    Kind("sidebar_toggle", "sidebar", 2, lambda r: {}),
    # command palette
    # Enter runs whatever command matched; only for queries whose matches are safe to run (never close or quit).
    Kind("palette", "palette", 2, lambda r: _palette(r)),
    # terminal input
    Kind("send_text", "terminal", 4, lambda r: {"text": r.choice(_TEXTS)}),
    Kind("type_burst", "terminal", 2, lambda r: {"n": r.choice([10, 200, 3000]), "seed": r.randrange(1 << 30)}),
    Kind("send_key", "terminal", 1.5, lambda r: {"key": r.choice(["ctrl-c", "ctrl-d", "enter", "ctrl-l", "ctrl-z"])}),
    Kind("shortcut", "terminal", 3, lambda r: {"combo": r.choice(_SHORTCUTS)}),
    # window
    Kind("window_resize", "window", 2, lambda r: {"w": r.choice(WINDOW_WIDTHS), "h": r.choice(WINDOW_HEIGHTS)}),
    Kind("fullscreen", "window", 0.7, lambda r: {}),
    Kind("window_create", "window", 0.6, lambda r: {}),
    Kind("window_close", "window", 0.4, lambda r: {"f": _f(r)}),
    # browser
    Kind("browser_open", "browser", 1.5, lambda r: {"url": r.choice(["about:blank",
                                                                     "data:text/html,<h1>fuzz</h1>",
                                                                     "data:text/html,<input autofocus>"])}),
    Kind("browser_navigate", "browser", 1, lambda r: {"f": _f(r), "url": r.choice(["about:blank",
                                                                                   "data:text/html,<p>x</p>"])}),
    # settings window
    Kind("settings_open", "settings", 0.7, lambda r: {"close": r.random() < 0.8}),
]

KIND_BY_NAME = {k.name: k for k in KINDS}


def generate(rng: random.Random, area_weights: dict[str, float], *, pointer: bool) -> dict:
    kinds = [k for k in KINDS if pointer or not k.needs_pointer]
    weights = [k.weight * area_weights.get(k.area, 1.0) for k in kinds]
    kind = rng.choices(kinds, weights=weights, k=1)[0]
    return {"do": kind.name, **kind.gen(rng)}


# ----------------------------------------------------------------- execution


class Executor:
    """Runs one action against the live app. `ctx` is a runner.Context."""

    def __init__(self, ctx: Any):
        self.ctx = ctx
        self.sock = ctx.session.sock

    def run(self, step: dict) -> str:
        handler = getattr(self, "do_" + step["do"], None)
        if handler is None:
            raise Skip(f"unknown action {step['do']}")
        return handler(step) or ""

    # -- state helpers

    def tree(self) -> dict:
        return self.sock.call("system.tree", timeout=8)

    def current_window(self, tree: dict | None = None) -> dict:
        tree = tree or self.tree()
        windows = tree.get("windows") or []
        if not windows:
            raise Skip("no window")
        key = [w for w in windows if w.get("key")]
        return (key or windows)[0]

    def selected_workspace(self, tree: dict | None = None) -> dict:
        window = self.current_window(tree)
        spaces = window.get("workspaces") or []
        sel = [w for w in spaces if w.get("selected")]
        if not sel:
            raise Skip("no selected workspace")
        return sel[0]

    def panes(self) -> list[dict]:
        return self.selected_workspace().get("panes") or []

    def surfaces(self) -> list[dict]:
        return [s for p in self.panes() for s in (p.get("surfaces") or [])]

    def total_surfaces(self, tree: dict) -> int:
        return sum(len(p.get("surfaces") or []) for w in tree.get("windows") or []
                   for ws in w.get("workspaces") or [] for p in ws.get("panes") or [])

    def shortcut(self, combo: str) -> None:
        self.sock.call("debug.shortcut.simulate", {"combo": combo})

    # -- splits

    def do_split(self, s: dict) -> str:
        if len(self.panes()) >= 16:
            raise Skip("16 panes is plenty")
        if s["via"] == "shortcut" and s["dir"] in "rd":
            self.shortcut("cmd+d" if s["dir"] == "r" else "cmd+shift+d")
            return "shortcut"
        try:
            self.sock.call("surface.split", {"direction": s["dir"], "focus": True})
        except SocketError as error:
            # cmux refuses a split that would leave a pane below its minimum size (#15371), like tmux.
            if isinstance(error.error, dict) and error.error.get("code") == "no_space":
                raise Skip("no space for new pane") from error
            raise
        return ""

    def do_close_surface(self, s: dict) -> str:
        tree = self.tree()
        if self.total_surfaces(tree) <= 1:
            raise Skip("last surface")
        surface = pick([x for p in self.selected_workspace(tree).get("panes") or [] for x in p.get("surfaces") or []],
                       s["f"])
        self.sock.call("surface.close", {"surface_id": surface["id"]})
        return surface.get("type", "")

    def do_zoom(self, s: dict) -> str:
        self.shortcut("cmd+shift+enter")
        return ""

    def do_equalize(self, s: dict) -> str:
        self.sock.call("workspace.equalize_splits", {})
        return ""

    def do_focus_pane(self, s: dict) -> str:
        pane = pick(self.panes(), s["f"])
        self.sock.call("pane.focus", {"pane_id": pane["id"]})
        return ""

    def do_resize_pane(self, s: dict) -> str:
        panes = self.panes()
        if len(panes) < 2:
            raise Skip("one pane")
        pane = pick(panes, s["f"])
        self.sock.call("pane.resize", {"pane_id": pane["id"], "direction": s["dir"], "amount": s["amount"]})
        return ""

    def do_swap_panes(self, s: dict) -> str:
        panes = self.panes()
        if len(panes) < 2:
            raise Skip("one pane")
        a, b = pick(panes, s["a"]), pick(panes, s["b"])
        if a["id"] == b["id"]:
            b = panes[(panes.index(a) + 1) % len(panes)]
        self.sock.call("pane.swap", {"pane_id": a["id"], "target_pane_id": b["id"]})
        return ""

    # -- pointer

    def do_drag_divider(self, s: dict) -> str:
        pointer = self.ctx.pointer()
        dividers = self.ctx.dividers()
        if not dividers:
            raise Skip("no divider")
        d = pick(dividers, s["f"])
        delta = s["delta"] * (1.6 if s.get("overshoot") else 1.0)
        if d["vertical"]:  # side-by-side panes: the divider moves along x
            start = (d["x"], d["mid"])
            end = (d["x"] + delta * d["extent"], d["mid"])
        else:
            start = (d["mid"], d["y"])
            end = (d["mid"], d["y"] + delta * d["extent"])
        pointer.drag(start, end, ms=s["ms"])
        return f"{'v' if d['vertical'] else 'h'} {start} -> {end}"

    def do_drag_tab(self, s: dict) -> str:
        pointer = self.ctx.pointer()
        geometry = self.ctx.pane_geometry()
        if not geometry:
            raise Skip("no pane geometry")
        src = pick(geometry, s["src"])
        dst = pick(geometry, s["dst"])
        start = self.ctx.tab_point(src, s["tab"])
        zone = s["zone"]
        x0, y0, w, h = dst["x"], dst["y"], dst["w"], dst["h"]
        targets = {
            "center": (x0 + w / 2, y0 + h / 2),
            "left": (x0 + w * 0.08, y0 + h / 2),
            "right": (x0 + w * 0.92, y0 + h / 2),
            "top": (x0 + w / 2, y0 + h * 0.12),
            "bottom": (x0 + w / 2, y0 + h * 0.92),
            "tabbar": self.ctx.tab_point(dst, 0.99),
            "sidebar": (40, y0 + h / 2),
            "outside": (x0 + w + 400, y0 - 200),
        }
        end = targets[zone]
        pointer.drag(start, end, ms=s["ms"])
        return f"{zone} {start} -> {end}"

    def do_click_pane(self, s: dict) -> str:
        pointer = self.ctx.pointer()
        geometry = self.ctx.pane_geometry()
        if not geometry:
            raise Skip("no pane geometry")
        g = pick(geometry, s["f"])
        pointer.click((g["x"] + g["w"] * s["x"], g["y"] + g["h"] * s["y"]))
        return ""

    # -- tabs

    def do_new_tab(self, s: dict) -> str:
        if len(self.surfaces()) >= 40:
            raise Skip("40 surfaces is plenty")
        if s["via"] == "shortcut":
            self.shortcut("cmd+t")
            return "shortcut"
        pane = pick(self.panes(), s["f"])
        self.sock.call("surface.create", {"pane_id": pane["id"], "focus": True})
        return ""

    def do_close_tab(self, s: dict) -> str:
        if self.total_surfaces(self.tree()) <= 1:
            raise Skip("last surface")
        self.shortcut("cmd+w")
        return ""

    def do_focus_surface(self, s: dict) -> str:
        surface = pick(self.surfaces(), s["f"])
        self.sock.call("surface.focus", {"surface_id": surface["id"]})
        return ""

    def do_move_surface(self, s: dict) -> str:
        panes = self.panes()
        surface = pick([x for p in panes for x in p.get("surfaces") or []], s["s"])
        target = pick(panes, s["p"])
        count = len(target.get("surfaces") or [])
        self.sock.call("surface.move", {"surface_id": surface["id"], "pane_id": target["id"],
                                        "index": min(int(s["i"] * (count + 1)), count), "focus": True})
        return ""

    def do_reorder_surface(self, s: dict) -> str:
        pane = pick([p for p in self.panes() if len(p.get("surfaces") or []) > 1] or [None], s["s"])
        if pane is None:
            raise Skip("no pane with two tabs")
        surfaces = pane["surfaces"]
        surface = pick(surfaces, s["s"])
        self.sock.call("surface.reorder", {"surface_id": surface["id"],
                                           "index": min(int(s["i"] * len(surfaces)), len(surfaces) - 1)})
        return ""

    def do_drag_to_split(self, s: dict) -> str:
        surface = pick(self.surfaces(), s["s"])
        self.sock.call("surface.drag_to_split", {"surface_id": surface["id"], "direction": s["dir"]})
        return ""

    # -- workspaces

    def workspaces(self) -> list[dict]:
        return self.current_window().get("workspaces") or []

    def do_workspace_create(self, s: dict) -> str:
        if len(self.workspaces()) >= 30:
            raise Skip("30 workspaces is plenty")
        self.sock.call("workspace.create", {})
        return ""

    def do_workspace_close(self, s: dict) -> str:
        tree = self.tree()
        spaces = self.current_window(tree).get("workspaces") or []
        if len(spaces) <= 1 and len(tree.get("windows") or []) <= 1:
            raise Skip("last workspace")
        ws = pick(spaces, s["f"])
        self.sock.call("workspace.close", {"workspace_id": ws["id"]})
        return ""

    def do_workspace_select(self, s: dict) -> str:
        ws = pick(self.workspaces(), s["f"])
        self.sock.call("workspace.select", {"workspace_id": ws["id"]})
        return ""

    def do_workspace_reorder(self, s: dict) -> str:
        spaces = self.workspaces()
        if len(spaces) < 2:
            raise Skip("one workspace")
        ws = pick(spaces, s["f"])
        self.sock.call("workspace.reorder", {"workspace_id": ws["id"],
                                             "index": min(int(s["i"] * len(spaces)), len(spaces) - 1)})
        return ""

    def do_workspace_rename(self, s: dict) -> str:
        ws = pick(self.workspaces(), s["f"])
        self.sock.call("workspace.rename", {"workspace_id": ws["id"], "title": s["title"]})
        return ""

    def do_workspace_action(self, s: dict) -> str:
        ws = pick(self.workspaces(), s["f"])
        self.sock.call("workspace.action", {"workspace_id": ws["id"], "action": s["action"]})
        return ""

    # -- sidebar, palette

    def do_sidebar_toggle(self, s: dict) -> str:
        self.shortcut("cmd+b")
        return ""

    def do_palette(self, s: dict) -> str:
        window = self.current_window()
        self.sock.call("debug.command_palette.toggle", {"window_id": window["id"]})
        time.sleep(0.15)
        if s["query"]:
            self.sock.call("debug.type", {"text": s["query"]})
        if s["then"] != "none":
            self.shortcut(s["then"])
        return ""

    # -- terminal

    def do_send_text(self, s: dict) -> str:
        self.sock.call("surface.send_text", {"text": s["text"]})
        return ""

    def do_type_burst(self, s: dict) -> str:
        rng = random.Random(s["seed"])
        alphabet = "abcdefghijklmnopqrstuvwxyz ABC0123456789-_=+[]{};:'\",.<>/?|\\`~!@#$%^&*()字😀é\t"
        text = "".join(rng.choice(alphabet) for _ in range(s["n"]))
        self.sock.call("debug.type", {"text": text}, timeout=30)
        return ""

    def do_send_key(self, s: dict) -> str:
        self.sock.call("surface.send_key", {"key": s["key"]})
        return ""

    def do_shortcut(self, s: dict) -> str:
        combo = s["combo"]
        tree = self.tree()
        if combo == "cmd+w" and self.total_surfaces(tree) <= 1:
            raise Skip("last surface")
        if combo == "cmd+shift+w" and len(self.current_window(tree).get("workspaces") or []) <= 1:
            raise Skip("last workspace")  # Cmd+Shift+W closes the workspace
        if combo == "cmd+ctrl+w" and len(tree.get("windows") or []) <= 1:
            raise Skip("last window")
        self.shortcut(combo)
        return ""

    # -- window

    def do_window_resize(self, s: dict) -> str:
        window = self.current_window()
        self.sock.call("remote.tmux.test_set_frame", {"window_id": window["id"], "width": s["w"], "height": s["h"]})
        return ""

    def do_fullscreen(self, s: dict) -> str:
        self.shortcut("cmd+ctrl+f")
        time.sleep(1.0)  # the fullscreen animation
        return ""

    def do_window_create(self, s: dict) -> str:
        if len(self.tree().get("windows") or []) >= 4:
            raise Skip("4 windows is plenty")
        self.sock.call("window.create", {})
        return ""

    def do_window_close(self, s: dict) -> str:
        windows = self.tree().get("windows") or []
        if len(windows) <= 1:
            raise Skip("last window")
        window = pick(windows, s["f"])
        self.sock.call("window.close", {"window_id": window["id"]})
        return ""

    # -- browser, settings

    def do_browser_open(self, s: dict) -> str:
        if len(self.panes()) >= 16:
            raise Skip("16 panes is plenty")
        self.sock.call("browser.open_split", {"url": s["url"]})
        return ""

    def do_browser_navigate(self, s: dict) -> str:
        browsers = [x for x in self.surfaces() if x.get("type") == "browser"]
        if not browsers:
            raise Skip("no browser")
        surface = pick(browsers, s["f"])
        self.sock.call("browser.navigate", {"surface_id": surface["id"], "url": s["url"]})
        return ""

    def do_settings_open(self, s: dict) -> str:
        self.sock.call("settings.open", {})
        if s["close"]:
            time.sleep(0.4)
            self.shortcut("cmd+w")
        return ""


EXPECTED_ERRORS = (SocketError, Skip)
TIMEOUTS = (SocketTimeout,)


# ----------------------------------------------------------------- words, for issues

def _nth(fraction: float, what: str) -> str:
    return f"the {what} at {round(fraction * 100)}% of the list"


def describe(step: dict) -> str:
    """One step in words a person can follow by hand, with its JSON after."""
    d = step.get("do", "")
    text = {
        "split": lambda s: f"Split the focused pane {dict(r='right', d='down', l='left', u='up')[s['dir']]}"
                           + (" (keyboard shortcut)" if s.get("via") == "shortcut" and s["dir"] in "rd" else ""),
        "close_surface": lambda s: f"Close {_nth(s['f'], 'tab')} in the workspace",
        "zoom": lambda s: "Toggle pane zoom (Cmd+Shift+Enter)",
        "equalize": lambda s: "Equalize splits",
        "focus_pane": lambda s: f"Focus {_nth(s['f'], 'pane')}",
        "resize_pane": lambda s: f"Resize {_nth(s['f'], 'pane')} {s['dir']} by {s['amount']}",
        "swap_panes": lambda s: "Swap two panes",
        "drag_divider": lambda s: f"Drag {_nth(s['f'], 'split divider')} by {round(s['delta'] * 100)}% of its span"
                                  f" over {s['ms']} ms",
        "drag_tab": lambda s: f"Drag a tab to the {s['zone']} of {_nth(s['dst'], 'pane')} over {s['ms']} ms",
        "click_pane": lambda s: f"Click inside {_nth(s['f'], 'pane')}",
        "new_tab": lambda s: "New terminal tab" + (" (Cmd+T)" if s.get("via") == "shortcut" else ""),
        "close_tab": lambda s: "Close the focused tab (Cmd+W)",
        "focus_surface": lambda s: f"Focus {_nth(s['f'], 'tab')}",
        "move_surface": lambda s: f"Move {_nth(s['s'], 'tab')} into {_nth(s['p'], 'pane')}",
        "reorder_surface": lambda s: "Reorder a tab within its pane",
        "drag_to_split": lambda s: f"Drag {_nth(s['s'], 'tab')} out into a new split {s['dir']}",
        "workspace_create": lambda s: "New workspace",
        "workspace_close": lambda s: f"Close {_nth(s['f'], 'workspace')}",
        "workspace_select": lambda s: f"Select {_nth(s['f'], 'workspace')}",
        "workspace_reorder": lambda s: f"Move {_nth(s['f'], 'workspace')} in the sidebar",
        "workspace_rename": lambda s: f"Rename {_nth(s['f'], 'workspace')} to {json.dumps(s['title'])}",
        "workspace_action": lambda s: f"Workspace action {s['action']} on {_nth(s['f'], 'workspace')}",
        "sidebar_toggle": lambda s: "Toggle the sidebar (Cmd+B)",
        "palette": lambda s: f"Open the command palette, type {json.dumps(s['query'])}, then {s['then']}",
        "send_text": lambda s: f"Type into the terminal: {json.dumps(s['text'])}",
        "type_burst": lambda s: f"Type {s['n']} random characters",
        "send_key": lambda s: f"Press {s['key']} in the terminal",
        "shortcut": lambda s: f"Press {s['combo']}",
        "window_resize": lambda s: f"Resize the window to {s['w']}x{s['h']} points",
        "fullscreen": lambda s: "Toggle full screen (Cmd+Ctrl+F)",
        "window_create": lambda s: "New window",
        "window_close": lambda s: f"Close {_nth(s['f'], 'window')}",
        "browser_open": lambda s: f"Open a browser split at {s['url']}",
        "browser_navigate": lambda s: f"Navigate a browser to {s['url']}",
        "settings_open": lambda s: "Open Settings" + (" and close it" if s.get("close") else ""),
    }.get(d)
    try:
        words = text(step) if text else d
    except (KeyError, TypeError):
        words = d
    return f"{words} `{json.dumps(step, ensure_ascii=False)}`"
