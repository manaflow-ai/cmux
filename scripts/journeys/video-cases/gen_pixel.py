#!/usr/bin/env python3
"""PIXEL PERFECT cases (Lawrence 2026-11-03: "resizing columns/splits is still not pixel perfect animated ... record +
rewatch videos at every single animation speed ... open both browser tabs + TUI in terminal, with like multiple pixel
border ... with different terminal/app shell background color so we can easily notice it all").

  gen_pixel.py --out DIR [--only ID ...]     writes DIR/<id>.json (scripts/journeys/journeys/video/)
  gen_pixel.py --list                        id, budget, recordings and title of every journey

Every journey: a new workspace with 2 to 6 fixture panes, the fixture colors, then one recording per animation speed.

  shell     #FF00FF  the window background in the gaps between and around panes: appearance.appTheme Nord with
                     appearance.themeEdits "Nord/background" (the app chrome's theme; terminals keep their own)
  theme     #00FFFF  the terminal's own ground (Ghostty's padding, the strip outside the whole cells):
                     appearance.surfaces.terminal.color (opacity 1), and appearance.theme Builtin Dark with
                     themeEdits "Builtin Dark/background" (the same color when the surface key is not read)
  TUI panes          pixel/tui_border.py: every cell its own background; rings of one cell (#FF0000, #FFFFFF,
                     #000000 from the outside in), a fill per pane (#FFFF00, #00FF00, #0000FF), a cell ruler
  page panes         pixel/page.html in a Chromium tab (action openBrowser, file:///tmp/jr-pixel-page.html?bg=..): 1, 2
                     and 3 CSS px borders in the same three colors, a body fill per pane, a 10 CSS px ruler
  agent panes        palette.newAgentChat, with appearance.surfaces.agentPane.color and .newTabPage.color (#0000FF) and
                     agent-pane/theme.css beside the settings file (ext_pixel px_agent_css): the same rings
  tab strips #000000 appearance.surfaces.tabBar.color (opacity 1): the strip's edges show against the shell, and the
                     selected tab's pill (the theme's selection fill over it) against the strip
  browserResize.pageBackdrop off (debug.tunables): a Chromium page that lags its pane shows the gap, not its own color;
                     where the tunable store is inactive it stays on, and each film's note says so

Speeds (ext_pixel px_film, debug.tunables): every motion.spring.<token> response = its default / S, damping its
default, with debug.motion speed fast (time scale 1): S = 0.25, 0.5, 1, 2, 4; and Reduce Motion (debug.motion reduce
true, springs at their defaults). Recording names end -s025, -s05, -s1, -s2, -s4, -reduce. In a build whose tunable
store is inactive (Release with bench hooks; `debug.tunables activate` turns it on where the build has it), the x1
and Reduce Motion films run and every other speed is one "not run: tunable store inactive" px_film result.

Each recording is one px_film step: the speed, ext_pixel px_record_start (ext_video's 120 Hz recorder, require_hz 120,
a 60 Mbps movie, a scan row through every tab strip and rows and columns at 0.3 and 0.7 of every pane, so every pane
border is crossed), the input as a person gives it (real HID drags, keys and the app's actions), video_stop, and the
rebuild of a closed pane. The judge (judge_pixel.py) reads the scan lines, the trace and the note px_record_start writes (which pane
is which fixture, the speed, the declared spring, the page backdrop). Each journey ends with the kit's after check:
p0's TUI ends on a real HID Ctrl-C and p0 echoes a line (app, daemon and frame). `finally` puts the springs, Reduce
Motion, the page backdrop tunable, the agent theme.css and the settings back.

Two journeys per case: <case> (the six speeds, for a build whose store is active; split -a, -b when too long for one
lease) and <case>-s1r (x1 and Reduce Motion only: several fit one lease, for any bench build).

Cases (layouts: T terminal fixture, P page fixture, A agent pane; | a vertical divider, / stacked):
  px-col-drag-*      a vertical divider dragged 150 pt right in 1 s (slow), back in 0.1 s (fast)    T|P and T|P|(A/T)
  px-row-drag-*      the horizontal divider dragged 120 pt down in 1 s, back in 0.1 s               T|(P/T)
  px-keys-single-*   Ctrl-Shift-L, H, J, K, one press each                                         T|(T/P), 3x2 mixed
  px-keys-held-*     Ctrl-Shift-L held 1.5 s (debug.key repeat), then 30 real H presses 33 ms apart T|P
  px-new-column-*    New Column (action newColumn), then Cmd-W on the new column                   columns T|P
  px-new-row-*       New Row (action newRow) under p0, then Cmd-W on the new row                   columns T|P
  px-close-pane-*    Cmd-W on the middle split pane; it comes back before the next speed            T|T|P
  px-close-column-*  Cmd-W on the middle column's only pane; it comes back before the next speed    columns T|T|A
  px-window-resize-* the window's bottom-right corner 300 x 150 pt in and back in 0.6 s each       T|P|(A/T)
The key of New Column will be Ctrl-Cmd-X after #29866; the cases run the action, as a menu item does.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cases as G  # noqa: E402  (the suite's set-up blocks: first pane, panes, after check, recorder stop, HID)

PIXEL = os.path.join(os.path.dirname(HERE), "pixel")
TUI_PATH = "/tmp/jr-tui-border.py"
PAGE_PATH = "/tmp/jr-pixel-page.html"
SHELL, THEME_BG = "#FF00FF", "#00FFFF"
SHELL_THEME, TERMINAL_THEME = "Nord", "Builtin Dark"
YELLOW, GREEN, BLUE = "#FFFF00", "#00FF00", "#0000FF"
AGENT_FILL = BLUE
SPEEDS = (("s025", 0.25), ("s05", 0.5), ("s1", 1.0), ("s2", 2.0), ("s4", 4.0), ("reduce", None))
# MotionTunables.springDefaults (feat-cmux-next): the tokens the inputs ride, for the waits and the judge's note when the
# store cannot be read; damping as MotionPolicy applies it (move is structural: never under 1).
RESPONSE = {"move": 0.15, "split": 0.23, "scroll": 0.2}
DAMPING = {"move": 1.0, "split": 0.95, "scroll": 0.9}
STRIP = "#000000"
# The movie's HEVC bit rate (the recorder's default is 300): flat fixture colors, and the judge reads the exact scan.
MOVIE_MBPS = 60
SPEEDS_S1R = (("s1", 1.0), ("reduce", None))
# Seconds, from the first rounds (cmux22, 2026-11-03: a pane's set-up took 1-3 s); MARGIN on top.
EST_BASE, EST_PANE, EST_FOCUS, EST_FILM, EST_REBUILD, EST_AFTER = 12, {"tui": 4, "page": 12, "agent": 5}, 1, 9, 7, 8
MARGIN, BUDGET_MIN = 1.2, 40
H, J, K, L = (("h", ["control", "shift"]), ("j", ["control", "shift"]), ("k", ["control", "shift"]),
              ("l", ["control", "shift"]))
NAMES = {"h": "Ctrl-Shift-H", "j": "Ctrl-Shift-J", "k": "Ctrl-Shift-K", "l": "Ctrl-Shift-L"}
BUDGET_MAX = 250  # run.py refuses over 260 (one lease: 540 s less the set-up reserve)


# -- fixtures -------------------------------------------------------------------------------------------------------
def fixture_files():
    with open(os.path.join(PIXEL, "tui_border.py")) as f:
        tui = f.read()
    with open(os.path.join(PIXEL, "page.html")) as f:
        page = f.read()
    return [{"do": "file", "path": TUI_PATH, "text": tui, "title": "set-up: the terminal fixture pixel/tui_border.py"},
            {"do": "file", "path": PAGE_PATH, "text": page, "title": "set-up: the browser fixture pixel/page.html"}]


def fixture_settings():
    return {"do": "settings_file", "title": f"set-up: shell {SHELL} (app theme {SHELL_THEME}), terminal ground {THEME_BG}, "
                                            f"tab strips {STRIP}, agent ground {AGENT_FILL}, no close warning, new columns share the strip",
            "set": {"appearance": {"theme": TERMINAL_THEME, "appTheme": SHELL_THEME,
                                   "themeEdits": {f"{SHELL_THEME}/background": SHELL, f"{TERMINAL_THEME}/background": THEME_BG},
                                   "surfaces": {"terminal": {"color": THEME_BG, "opacity": 1},
                                                "tabBar": {"color": STRIP, "opacity": 1},
                                                "agentPane": {"color": AGENT_FILL, "opacity": 1},
                                                "newTabPage": {"color": AGENT_FILL, "opacity": 1}}},
                    "app": {"warnBeforeClosingTab": False},
                    "layout": {"newColumnWidth": "fitScreen"}}}


def settings_back():
    return {"do": "settings_file", "title": "clean-up: the fixture colors off (the next journey's theme is its own)",
            "set": {"appearance": {"appTheme": "followTerminal"}},
            "unset": ["appearance.themeEdits", "appearance.surfaces"]}


def after_check():
    """The kit's after check on the fixture: p0 focused by the app (`cmux pane focus`; a click at p0's left edge, the
    sidebar boundary, did not focus it on cmux22), the fixture colors off (text recognition did not read the echo on the
    #00FFFF ground), then gen_cases' check: a real HID Ctrl-C ends p0's fixture, p0 echoes a line, read by the app, the
    daemon and a frame."""
    check = G.after_check_hid()
    assert check[0]["do"] == "use_pane", check[0]
    return [focus("p0"), settings_back()] + check[1:]


def start_tui(name, fill):
    mark = f"tui-{name}"
    return [{"do": "type", "text": f"python3 {TUI_PATH} --fill {fill.lstrip('#')} --label {name}", "enter": True, "mark": mark,
             "title": f"set-up: the terminal fixture in {name} (fill {fill})"},
            {"do": "expect", "title": f"set-up: the fixture runs in {name} (its alternate screen hides the prompt)", "since": mark,
             "timeout": 8, "all": [{"daemon_lacks": "J> "}]}]


def new_pane(name, action):
    """A new terminal pane by the app's action (splitRight, splitDown, newColumn, newRow) on the focused pane."""
    return [{"do": "action", "action": action, "title": f"set-up: {action} ({name})"},
            {"do": "adopt_pane", "as": name},
            {"do": "neutral_prompt"}]


def focus(name):
    return {"do": "rk_focus", "pane": name, "title": f"set-up: focus {name} (cmux pane focus)"}


def make_kind(name, kind, fill):
    """Turns the new terminal pane NAME into its fixture."""
    if kind == "tui":
        return start_tui(name, fill)
    if kind == "page":
        return [{"do": "px_page", "pane": name, "bg": fill, "label": name, "title": f"set-up: page.html in a browser tab of {name} ({fill})"}]
    if kind == "agent":
        return [{"do": "action", "action": "palette.newAgentChat", "title": f"set-up: an agent chat in {name}"},
                {"do": "wait", "seconds": 2.0, "title": "set-up: the chat shows (nothing observable to wait on)"}]
    raise ValueError(kind)


class Layout:
    """The panes of a case: [(name, kind, fill, how)], how = (action, pane focused first) or None for p0. window: the
    window's fractions of its screen (window_place) instead of the first pane's 90%; widths: a column width preset given
    to each new column and, at the end, to the first one (columns layouts)."""

    def __init__(self, key, text, panes, window=None, widths=None):
        self.key, self.text, self.panes, self.window, self.widths = key, text, panes, window, widths

    @property
    def fixture(self):
        return {name: {"kind": kind, "fill": fill} for name, kind, fill, _ in self.panes}

    def kinds(self):
        return [kind for _, kind, _, _ in self.panes]

    def build(self):
        steps = []
        for name, kind, fill, how in self.panes:
            if how is None:
                if kind != "tui":
                    raise ValueError("p0 is a terminal fixture (the after check types into it)")
                steps += start_tui(name, fill)
                continue
            action, after = how
            if after:
                steps.append(focus(after))
            steps += new_pane(name, action)
            if self.widths and action == "newColumn":
                steps.append({"do": "try_action", "action": self.widths, "title": f"set-up: {name}'s column takes its share"})
            steps += make_kind(name, kind, fill)
        if self.widths:
            steps += [focus("p0"), {"do": "try_action", "action": self.widths, "title": "set-up: p0's column takes its share"}]
        return steps

    def seconds(self):
        return sum(EST_PANE[k] for k in self.kinds()) + EST_FOCUS * sum(1 for p in self.panes if p[3] and p[3][1])


T2 = Layout("2", "p0 T | p1 P", [("p0", "tui", YELLOW, None), ("p1", "page", GREEN, ("splitRight", None))])
T4 = Layout("4", "p0 T | p1 P | (p2 A / p3 T)",
            [("p0", "tui", YELLOW, None), ("p1", "page", GREEN, ("splitRight", None)), ("p2", "agent", AGENT_FILL, ("splitRight", None)),
             ("p3", "tui", YELLOW, ("splitDown", None))])
T3R = Layout("3r", "p0 T | (p1 P / p2 T)",
             [("p0", "tui", YELLOW, None), ("p1", "page", GREEN, ("splitRight", None)), ("p2", "tui", YELLOW, ("splitDown", None))])
T3K = Layout("3k", "p0 T | (p1 T / p2 P)",
             [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("splitRight", None)), ("p2", "page", YELLOW, ("splitDown", None))])
# 3 strip columns of 2 rows (newColumn, newRow): splits of splits did not fit the 1361 x 792 pt window (cmux22: the third
# splitDown had no room for two 200 x 64 pt panes and their chrome). The window takes the screen's full width, and each
# column one third of the viewport (the width preset; layout.minimumPaneWidth 200 pt).
T6 = Layout("6", "columns (p0 T / p3 T) | (p1 P / p4 A) | (p2 T / p5 P)",
            [("p0", "tui", YELLOW, None), ("p3", "tui", GREEN, ("newRow", None)),
             ("p1", "page", GREEN, ("newColumn", None)), ("p4", "agent", AGENT_FILL, ("newRow", None)),
             ("p2", "tui", YELLOW, ("newColumn", None)), ("p5", "page", GREEN, ("newRow", None))],
            window=[0.0, 0.05, 1.0, 0.9], widths="column.widthOneThird")
T3S = Layout("3", "p0 T | p1 T | p2 P (splits)",
             [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("splitRight", None)), ("p2", "page", YELLOW, ("splitRight", None))])
C2 = Layout("c2", "columns p0 T | p1 P", [("p0", "tui", YELLOW, None), ("p1", "page", GREEN, ("newColumn", None))])
C3 = Layout("c3", "columns p0 T | p1 T | p2 A",
            [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("newColumn", None)), ("p2", "agent", AGENT_FILL, ("newColumn", None))])


# -- inputs ---------------------------------------------------------------------------------------------------------
def land(speed, token="move"):
    """Seconds for the motion to land and rest: 1.5 x the scaled response, plus 0.35 s of rest in the film."""
    response = RESPONSE[token] / (speed or 1.0)
    return round(0.35 + 1.5 * response, 2) if speed else 0.5


def rest(seconds, why="the motion lands and rests"):
    return {"do": "wait", "seconds": seconds, "title": why}


def press(key, mark):
    return {"do": "rk_press", "key": key[0], "modifiers": list(key[1]), "count": 1, "gap_ms": 0, "mark": mark, "title": NAMES[key[0]]}


def drag(target, by, ms, mark, title):
    return G.kit_drag(target, by, ms, mark, title)


class Case:
    """One case on one layout: its input per speed (play), the spring the input rides (None: the pointer or a live resize
    drives it, so no curve is declared), and its rebuild after the recording (a close)."""

    def __init__(self, cid, title, layout, play, spring, input_kind, before=None, rebuild=None, play_seconds=None):
        self.cid, self.title, self.layout, self.play, self.spring = cid, title, layout, play, spring
        self.input, self.before, self.rebuild = input_kind, before or [], rebuild or []
        self.play_seconds = play_seconds

    def recording(self, jid, label, speed, last=False):
        """One px_film step (the speed, the film and the rebuild after it) and its estimated seconds."""
        name = f"{jid}-{label}"
        expected = self.play_seconds(speed)
        # The recorder stops by itself after `seconds`: room for the lead (1 s), the steps' own overhead and the tail.
        seconds = round(1.5 * expected + 6.0, 1)
        start = {"do": "px_record_start", "name": name, "seconds": seconds, "require_hz": 120, "mbps": MOVIE_MBPS,
                 "fixture": self.layout.fixture, "spring": self.spring, "input": self.input,
                 "title": f"start the 120 Hz movie, the trace and scan lines across every pane border and tab strip ({name})"}
        if self.spring:
            start["spring_default"] = {"response": RESPONSE[self.spring], "damping": DAMPING[self.spring]}
        steps = list(self.before) + [G.settle(0.8), start] + self.play(speed) + [G.kit_record_stop(name, 0.4)]
        rebuild = [] if last else list(self.rebuild)  # the journey's last film needs no pane back
        film = {"do": "px_film", "name": name, "steps": steps, "after": rebuild,
                "title": (f"film {name}: Reduce Motion" if speed is None else f"film {name}: every motion.spring.* response / {speed:g}")}
        film.update({"reduce": True} if speed is None else {"speed": speed})
        return film, EST_FILM + 1.3 * expected + (EST_REBUILD if rebuild else 0)


def col_drag_play(divider):
    def play(speed):
        return [drag({"divider": divider}, [150, 0], 1000, "slow", "slow drag: 150 pt right in 1 s"), rest(land(speed)),
                drag({"divider": divider}, [-150, 0], 100, "fast", "fast drag: 150 pt back in 0.1 s"), rest(land(speed))]
    return play, (lambda speed: 1.3 + 2 * land(speed))


def row_drag_play(speed):
    return [drag({"row_divider": 0}, [0, 120], 1000, "slow", "slow drag: 120 pt down in 1 s"), rest(land(speed)),
            drag({"row_divider": 0}, [0, -120], 100, "fast", "fast drag: 120 pt back up in 0.1 s"), rest(land(speed))]


def keys_play(speed):
    steps = []
    for i, key in enumerate((L, H, J, K)):
        steps += [press(key, f"key{i}"), rest(land(speed))]
    return steps


def held_play(speed):
    return [{"do": "rk_hold", "key": "l", "modifiers": ["control", "shift"], "seconds": 1.5, "mark": "hold",
             "title": "Ctrl-Shift-L held 1.5 s (debug.key auto-repeat)"}, rest(land(speed)),
            {"do": "rk_press", "key": "h", "modifiers": ["control", "shift"], "count": 30, "gap_ms": 33, "mark": "burst",
             "title": "Ctrl-Shift-H x30, 33 ms apart (real HID)"}, rest(land(speed))]


def new_and_close_play(action, what):
    def play(speed):
        return [{"do": "action", "action": action, "mark": "new", "title": f"{what} (action {action}, as its menu item)"},
                rest(land(speed, "split")),
                {"do": "adopt_pane", "as": "pnew", "title": f"the new pane has the focus"},
                G.kit_key("w", ["cmd"], "close", f"Cmd-W closes the new pane"), rest(land(speed, "split"))]
    return play, (lambda speed: 1.5 + 2 * land(speed, "split"))


def close_play(speed):
    return [G.kit_key("w", ["cmd"], "close", "Cmd-W closes the focused pane"), rest(land(speed, "split"))]


def window_play(speed):
    # A CuaDriver drag never reached the window's corner (cmux22, 2026-11-03: no mouse-down in the app's journal): the
    # corner moves through ext_window's window_drag (debug.mouse into AppKit's live-resize tracking, as R3a does).
    return [{"do": "px_window_frame", "by": [-300, -150], "ms": 600, "mark": "in", "title": "the window corner 300 x 150 pt in, 0.6 s"},
            rest(0.6),
            {"do": "px_window_frame", "by": [300, 150], "ms": 600, "mark": "out", "title": "the window corner back out, 0.6 s"},
            rest(0.8)]


def cases():
    out = []
    # T4: divider 0 is the column edge between the stacked column and the 3-pane column (a column-edge drag that
    # pushes the strip). Divider 1 sat between two panes at their minimum width: it could not move (S2 A/B 13:4xZ).
    for layout, divider in ((T2, 0), (T4, 0)):
        play, secs = col_drag_play(divider)
        what = "the column edge" if layout is T4 else f"divider {divider}"
        out.append(Case(f"px-col-drag-{layout.key}", f"{what} dragged 150 pt right slowly and back fast ({layout.text})",
                        layout, play, None, "drag", play_seconds=secs))
    out.append(Case(f"px-row-drag-{T3R.key}", f"the row divider dragged 120 pt down slowly and back fast ({T3R.text})", T3R,
                    row_drag_play, None, "drag", play_seconds=lambda s: 1.3 + 2 * land(s)))
    for layout, under in ((T3K, "p1"), (T6, "p1")):
        out.append(Case(f"px-keys-single-{layout.key}", f"Ctrl-Shift-L, H, J, K on {under} ({layout.text})", layout, keys_play, "move",
                        "keys", before=[focus(under)], play_seconds=lambda s: 4 * (0.1 + land(s))))
    out.append(Case(f"px-keys-held-{T2.key}", f"Ctrl-Shift-L held, then Ctrl-Shift-H x30 every 33 ms, on p0 ({T2.text})", T2,
                    held_play, None, "held keys", before=[focus("p0")], play_seconds=lambda s: 2.6 + 2 * land(s)))
    play, secs = new_and_close_play("newColumn", "New Column")
    out.append(Case(f"px-new-column-{C2.key}", f"New Column on p1, then Cmd-W on it ({C2.text})", C2, play, "split", "new column",
                    before=[focus("p1")], play_seconds=secs))
    play, secs = new_and_close_play("newRow", "New Row")
    out.append(Case(f"px-new-row-{C2.key}", f"New Row under p0, then Cmd-W on it ({C2.text})", C2, play, "split", "new row",
                    before=[focus("p0")], play_seconds=secs))
    out.append(Case(f"px-close-pane-{T3S.key}", f"Cmd-W on the middle split p1; it comes back after each speed ({T3S.text})", T3S,
                    close_play, "split", "close pane", before=[focus("p1")],
                    rebuild=[focus("p0")] + new_pane("p1", "splitRight") + start_tui("p1", GREEN) + [G.settle(1.0)],
                    play_seconds=lambda s: 0.2 + land(s, "split")))
    out.append(Case(f"px-close-column-{C3.key}", f"Cmd-W on the middle column's only pane p1; it comes back after each speed ({C3.text})",
                    C3, close_play, "split", "close column", before=[focus("p1")],
                    rebuild=[focus("p0")] + new_pane("p1", "newColumn") + start_tui("p1", GREEN) + [G.settle(1.0)],
                    play_seconds=lambda s: 0.2 + land(s, "split")))
    out.append(Case(f"px-window-resize-{T4.key}", f"the window corner 300 x 150 pt in and back out ({T4.text})", T4, window_play, None,
                    "window resize (window_drag)", play_seconds=lambda s: 2.6))
    return out


def journey(case, jid, speeds, part_note):
    steps = [fixture_settings()] + G.first_pane(jid, False) + fixture_files()
    if case.layout.window:
        place = next(st for st in steps if st["do"] == "window_place")
        place.update(fraction=list(case.layout.window), title=f"set-up: the window at {case.layout.window} of the screen")
    steps.append({"do": "px_tunable", "key": "browserResize.pageBackdrop", "value": False,
                  "title": "set-up: a Chromium page that lags shows the gap (browserResize.pageBackdrop off, where the store takes it)"})
    if "agent" in case.layout.kinds():
        steps.append({"do": "px_agent_css", "fill": AGENT_FILL, "title": "set-up: agent-pane/theme.css: the agent ground and its rings"})
    steps += case.layout.build() + [G.settle(1.5)]
    seconds = EST_BASE + case.layout.seconds()
    names = []
    for n, (label, speed) in enumerate(speeds):
        film, cost = case.recording(jid, label, speed, last=n == len(speeds) - 1)
        steps.append(film)
        seconds += cost
        names.append(film["name"])
    steps += after_check()
    seconds += EST_AFTER
    budget = int(min(BUDGET_MAX, max(BUDGET_MIN, round(seconds * MARGIN))))
    final = [{"do": "px_springs", "reset": True, "title": "clean-up: springs and Reduce Motion back"},
             {"do": "px_tunable", "key": "browserResize.pageBackdrop", "value": None, "title": "clean-up: the page backdrop back"},
             {"do": "px_agent_css", "remove": True, "title": "clean-up: agent-pane/theme.css removed"},
             settings_back()]
    speeds_text = ", ".join("Reduce Motion" if s is None else f"x{s:g}" for _, s in speeds)
    return {"id": jid, "priority": "P1", "title": f"PIXEL: {case.title}, at {speeds_text}{part_note}",
            "why": "Lawrence 2026-11-03: resizing columns and splits is not pixel perfect when animated. Loud fixture colors (shell "
                   f"{SHELL}, terminal ground {THEME_BG}, tab strips {STRIP}, rings #FF0000/#FFFFFF/#000000) make any gap, overlap or "
                   "lag visible; judge_pixel.py reads every pane edge, tab strip and divider per film frame from the exact scan lines.",
            "source": "PIXEL PERFECT kit (video-cases/gen_pixel.py)", "budget_seconds": budget, "estimate_seconds": round(seconds),
            "recordings": names, "options": {"key_path": "real"}, "steps": steps, "finally": final}


def sweep(case):
    """The six speeds in as few journeys as fit one lease each (-a, -b, ... when split)."""
    groups = [list(SPEEDS)]
    while True:
        built = [journey(case, case.cid, g, "") for g in groups] if len(groups) == 1 else \
            [journey(case, f"{case.cid}-{'abcdefgh'[i]}", g, f" (part {'abcdefgh'[i]})") for i, g in enumerate(groups)]
        if all(j["estimate_seconds"] * MARGIN <= BUDGET_MAX for j in built) or max(len(g) for g in groups) == 1:
            return built
        size = -(-len(SPEEDS) // (len(groups) + 1))
        groups = [list(SPEEDS[i:i + size]) for i in range(0, len(SPEEDS), size)]


def journeys():
    out = []
    for case in cases():
        out += sweep(case)
        out.append(journey(case, f"{case.cid}-s1r", list(SPEEDS_S1R), " (x1 and Reduce Motion: any bench build)"))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--out")
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--list", action="store_true")
    opts = ap.parse_args()
    chosen = [j for j in journeys() if not opts.only or any(j["id"] == o or j["id"].startswith(o + "-") for o in opts.only)]
    if opts.list or not opts.out:
        for j in chosen:
            print(f"{j['id']:28} {j['budget_seconds']:4} s  {len(j['recordings'])} rec  {j['title']}")
        return 0
    os.makedirs(opts.out, exist_ok=True)
    for j in chosen:
        with open(os.path.join(opts.out, j["id"] + ".json"), "w") as f:
            json.dump(j, f, indent=1)
            f.write("\n")
    removed = [] if opts.only else prune(opts.out, {j["id"] for j in chosen})
    print(f"{len(chosen)} journeys in {opts.out}" + (f"; removed {len(removed)} this generator no longer makes: {', '.join(removed)}"
                                                     if removed else ""))
    return 0


def prune(out, keep):
    """Removes px-*.json files in OUT that this generator wrote (their source says so) and no longer makes."""
    removed = []
    for name in sorted(os.listdir(out)):
        if not (name.startswith("px-") and name.endswith(".json")) or name[:-5] in keep:
            continue
        path = os.path.join(out, name)
        try:
            with open(path) as f:
                ours = json.load(f).get("source", "").startswith("PIXEL PERFECT kit (video-cases/gen_pixel.py)")
        except (OSError, ValueError):
            ours = False
        if ours:
            os.remove(path)
            removed.append(name[:-5])
    return removed


if __name__ == "__main__":
    sys.exit(main())
