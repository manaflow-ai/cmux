#!/usr/bin/env python3
"""PIXEL PERFECT cases (Lawrence 2026-11-03: "resizing columns/splits is still not pixel perfect animated ... record +
rewatch videos at every single animation speed ... open both browser tabs + TUI in terminal, with like multiple pixel
border ... with different terminal/app shell background color so we can easily notice it all").

  gen_pixel.py --out DIR [--only ID ...]     writes DIR/<id>.json (scripts/journeys/journeys/video/)
  gen_pixel.py --list                        id, budget, recordings and title of every journey
  gen_pixel.py --out DIR --switch KEY --only ID ...
                                             switch variants: <case>-sw-<short> per case, KEY OFF then ON

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

Switch variants (--switch KEY, with --only): a feature switch (a boolean Debug tunable, e.g. motion.frameOwner.terminals,
PR #33956) filmed both ways in one launch, per case one journey <case>-sw-<short> (<short>: the key's last part) with 4
films: off-s1, on-s1, off-reduce, on-reduce (px_film's `switch`: set and read back before each film; a switch that does
not take makes that film "not run", never a film at the default). Split -a, -b by budget when one lease cannot hold the
4; the switch goes back to its default (null) in finally. Not written without --switch.

Cases (layouts: T terminal fixture, P page fixture, A agent pane; | a vertical divider, / stacked):
  px-col-drag-*      a vertical divider dragged 150 pt right in 1 s (slow), back in 0.1 s (fast)    T|P and T|P|(A/T)
  px-row-drag-*      the horizontal divider dragged 120 pt down in 1 s, back in 0.1 s               T|(P/T)
  px-keys-single-*   Ctrl-Shift-L, H, J, K, one press each                                         T|(T/P), 3x2 mixed
  px-keys-rk-3t      cmux-ad m6 (d): the open-P0 journey resize-keyboard's presses (Ctrl-Shift-L, H, J, K, then
                     Ctrl-Cmd-Right, Left, Down, Up on p1), read from its journey file, on terminal fixtures in its
                     places; judged by video-cases/judge_m6.py (each terminal's content edge on its pane's edge)    T|(T/T)
  px-keys-held-*     Ctrl-Shift-L held 1.5 s (debug.key repeat), then 30 real H presses 33 ms apart T|P
  px-keys-held-2-tabclose  the same, with p0 in 3 terminal tabs, every tab outlined (motion.frameOwner.tabOutline,
                     required), and p0's middle tab closed by a script 50 ms after the hold's first key-down (one tab
                     back after each film); p0's fill is blue (the outline is yellow)                   T(3 tabs)|P
  px-keys-held-2-tabclose-narrow  the same with p0 at its minimum width, its strip scrolled (30 x Ctrl-Shift-H first)
  px-new-column-*    New Column (action newColumn), then Cmd-W on the new column                   columns T|P
  px-new-row-*       New Row (action newRow) under p0, then Cmd-W on the new row                   columns T|P
  px-close-pane-3   Cmd-W on the middle split pane p1, nested with p2 (p0 | (p1 | p2)): the p0|p1 divider stays;
                     p1 comes back the same way (splitLeft on p2) before the next speed            T|T|P
  px-close-pane-3t  the same close with p1 nested with p0 ((p0 | p1) | p2): the p1|p2 divider stays, on the
                     closing pane's trailing side (stage S3d case (a)); p1 comes back by splitRight on p0  T|T|P
  px-close-column-*  Cmd-W on the middle column's only pane; it comes back before the next speed    columns T|T|A
  px-window-resize-* the window's bottom-right corner 300 x 150 pt in and back in 0.6 s each       T|P|(A/T)
  px-keys-then-drag-3, px-keys-then-split-drag-2s  stage S2b: Ctrl-Shift-L on p0, then 60 ms after its key-down a real
                     drag of the p1|p2 column edge 150 pt right (divider hit width 24 pt) or of the p1/p2 split 120 pt
                     down, in 400 ms, during the key's spring; x0.25 only (one journey, and the switch variants at it)
                     columns T|P|T and columns T|(T/P)
  px-keys-then-drag-3t, px-keys-then-split-drag-2st  the same with terminals only (columns T|T|T, T|(T/T)), at x0.125: in the
                     page layouts the press went to the page window beside the moving edge (ab-s2b-sw-3fbd40a)
The key of New Column will be Ctrl-Cmd-X after #29866; the cases run the action, as a menu item does.
"""
import argparse
import json
import os
import re
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
# Stage S2b (a drag during a key spring): a HID drag's mouse-down reaches the app 260-400 ms after its call starts (cmux22),
# when the key's spring at x1 (about 0.18 s) or under Reduce Motion (one frame) has landed. At x0.25 it still runs.
SPEEDS_S2B = (("s025", 0.25),)
# The terminal-only S2b cases: the CuaDriver drag reaches the app about 0.46 s after the key, when a x0.25 key spring has
# 2-3 pt left (ab-s2b-sw-3fbd40a). x0.125 is the slowest speed every spring takes (the tunables clamp a response to 2 s;
# settle's 0.22 s at x0.1 is 2.2 s: ab-s2bt-sw-3fbd40a); about 30 % of the edge's travel is left at the mouse-down.
SPEEDS_S2BT = (("s0125", 0.125),)
# The low-prompt case (S4 F2): x1, and x0.25 so each frame of the grow-down spring shows where the prompt row is.
SPEEDS_LOWPROMPT = (("s1", 1.0), ("s025", 0.25))
# The bar over the low prompt (a color no fixture uses): lowprompt_rows.py finds it on the scan column through the pane.
LOW_PROMPT_BAR = "#FF8000"
# Seconds, from the first rounds (cmux22, 2026-11-03: a pane's set-up took 1-3 s); MARGIN on top.
EST_BASE, EST_PANE, EST_FOCUS, EST_FILM, EST_REBUILD, EST_AFTER = 12, {"tui": 4, "page": 12, "agent": 5, "shell": 4, "shellz": 4}, 1, 9, 7, 8
EST_TAB = 5  # one more terminal tab with its fixture (px_tab_new, the neutral prompt, the TUI)
MARGIN, BUDGET_MIN = 1.2, 40
H, J, K, L = (("h", ["control", "shift"]), ("j", ["control", "shift"]), ("k", ["control", "shift"]),
              ("l", ["control", "shift"]))
NAMES = {"h": "Ctrl-Shift-H", "j": "Ctrl-Shift-J", "k": "Ctrl-Shift-K", "l": "Ctrl-Shift-L",
         "right": "Ctrl-Cmd-Right", "left": "Ctrl-Cmd-Left", "down": "Ctrl-Cmd-Down", "up": "Ctrl-Cmd-Up"}
# The open-P0 journey of the key resize P0 (cmux-ad 2026-11-02; gen_keys.py case 1): px-keys-rk-3t plays its presses.
RESIZE_KEYBOARD = os.path.join(os.path.dirname(HERE), "journeys", "video", "resize-keyboard.json")
BUDGET_MAX = 250  # run.py refuses over 260 (one lease: 540 s less the set-up reserve)
# The app's tab film fixture (TabFrameFixture, #33874; DEV and bench builds): a 1 device-px #FFFF00 border on every tab cell,
# so a film finds each tab's two edges on the strip row. It is a `springs` section tunable: the Reduce Motion film's reset of
# that section turns it off, so a case sets it again in each film (after the speed).
TAB_OUTLINE = "motion.frameOwner.tabOutline"
# The divider drag area's width (metrics.dividerHitWidth, 1 to 24 pt, default 7; only the hit bands use it, no pane frame):
# a HID press on a column edge the key's spring still moves lands within a few points of it.
HIT_WIDTH = "metrics.dividerHitWidth"
# A journey id is its case id, or the case id and one of these: -a.. (a sweep in parts), -s1r, -sw-<short>[-a..].
JOURNEY_SUFFIX = re.compile(r"(-[a-h]|-s1r|-sw-[a-z0-9]+(-[a-c])?)?")


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
                                            f"tab strips {STRIP}, agent ground {AGENT_FILL}, no close warning, new columns share the strip, "
                                            f"no hover cards",
            # No hover card: the panes move under a still pointer, and a tab's hover card opened over p2's page in the
            # J, J, K films (ab-s4pin-44ab81a px-keys-lowprompt-jjk-3kz-sw-terminals-on-s025 frames 264-433, R-HARNESS).
            "set": {"sidebar": {"hoverCards": {"enabled": False}},
                    "appearance": {"theme": TERMINAL_THEME, "appTheme": SHELL_THEME,
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
            "unset": ["appearance.themeEdits", "appearance.surfaces", "sidebar.hoverCards"]}


def after_check():
    """The kit's after check on the fixture: p0 focused by the app (`cmux pane focus`; a click at p0's left edge, the
    sidebar boundary, did not focus it on cmux22), the fixture colors off (text recognition did not read the echo on the
    #00FFFF ground), then gen_cases' check: a real HID Ctrl-C ends p0's fixture; the line is typed once the daemon and
    the app show the bare prompt again (typed 0.28 s after the Ctrl-C, zsh lost its first key on cmux22: "J> cho
    rv-done-..."); p0 echoes it, read by the app, the daemon and a frame."""
    check = G.after_check_hid()
    assert [st["do"] for st in check] == ["use_pane", "hid_key", "type", "expect"], check
    ready = {"do": "expect", "title": "after: the shell's prompt is back (the fixture ended)", "since": "ctrlc", "timeout": 10,
             "all": [{"daemon_prompt": True}, {"app_prompt": True}]}
    return [focus("p0"), settings_back(), check[1], ready] + check[2:]


def start_tui(name, fill, label=None):
    mark = f"tui-{name}"
    return [{"do": "type", "text": f"python3 {TUI_PATH} --fill {fill.lstrip('#')} --label {label or name}", "enter": True, "mark": mark,
             "title": f"set-up: the terminal fixture in {name} (fill {fill})"},
            {"do": "expect", "title": f"set-up: the fixture runs in {name} (its alternate screen hides the prompt)", "since": mark,
             "timeout": 8, "all": [{"daemon_lacks": "J> "}]}]


def start_low_prompt(name):
    """A shell (normal screen) in NAME with its prompt on the last row: 120 numbered lines, then a full-width #FF8000 bar
    ($COLUMNS spaces on that background), so the prompt row is the row under the bar. S4 F2 (#35470 review): a pane a key
    grows down with the cursor in its lower half keeps the surface at its final size on the bottom edge (motionAnchor
    .bottom), with motion.frameOwner.terminals OFF (S3's hold) and ON; the border fixture's alternate screen never does."""
    mark = f"low-{name}"
    r, g, b = (int(LOW_PROMPT_BAR[i:i + 2], 16) for i in (1, 3, 5))
    text = (f"clear; for i in $(seq 1 120); do echo \"line $i\"; done; "
            f"printf '\\033[48;2;{r};{g};{b}m%*s\\033[0m\\n' $COLUMNS ''")
    return [{"do": "type", "text": text, "enter": True, "mark": mark,
             "title": f"set-up: {name} fills its screen, an orange bar, then the prompt on the last row"},
            {"do": "expect", "title": f"set-up: {name}'s prompt is back on its last row, under the bar", "since": mark,
             "timeout": 8, "all": [{"daemon_line": "line 120"}, {"daemon_prompt": True}]}]


# The striped low prompt (S4 H1): every line a 3-cell #FF0000 marker, then the rest of the row on #00FF00 or #0000FF in turn,
# so a film can see a band of ground above the lines (no stripe under the tab strip) and lines cut off on the left (the marker
# narrower or gone at the pane's left edge). lowprompt_h1.py reads it.
ZEBRA_MARK, ZEBRA_A, ZEBRA_B = "#FF0000", "#00FF00", "#0000FF"


def start_low_prompt_zebra(name):
    """A shell in NAME with its prompt on the last row under the orange bar, as start_low_prompt, but every line above the bar
    striped (ZEBRA_MARK, then ZEBRA_A or ZEBRA_B across the row) and the bar starting with the text lpbar (the set-up's check)."""
    mark = f"lowz-{name}"
    rgb = lambda hexa: ";".join(str(int(hexa[i:i + 2], 16)) for i in (1, 3, 5))
    m, a, b, bar = rgb(ZEBRA_MARK), rgb(ZEBRA_A), rgb(ZEBRA_B), rgb(LOW_PROMPT_BAR)
    text = (f"clear; for i in $(seq 1 120); do if [ $((i % 2)) = 0 ]; then c='{a}'; else c='{b}'; fi; "
            f"printf '\\033[48;2;{m}m   \\033[48;2;%sm%*s\\033[0m\\n' \"$c\" $((COLUMNS - 3)) ''; done; "
            f"printf '\\033[48;2;{bar}mlpbar%*s\\033[0m\\n' $((COLUMNS - 5)) ''")
    return [{"do": "type", "text": text, "enter": True, "mark": mark,
             "title": f"set-up: {name} fills its screen with striped lines, an orange bar, then the prompt on the last row"},
            {"do": "expect", "title": f"set-up: {name}'s prompt is back on its last row, under the bar", "since": mark,
             "timeout": 8, "all": [{"daemon_contains": "lpbar"}, {"daemon_prompt": True}]}]


def new_pane(name, action):
    """A new terminal pane by the app's action (splitRight, splitDown, newColumn, newRow) on the focused pane."""
    return [{"do": "action", "action": action, "title": f"set-up: {action} ({name})"},
            {"do": "adopt_pane", "as": name},
            {"do": "neutral_prompt"}]


def focus(name):
    return {"do": "rk_focus", "pane": name, "title": f"set-up: focus {name} (cmux pane focus)"}


def new_tab(name):
    """One more terminal tab in NAME, shown and adopted (ext_pixel px_tab_new), with the neutral prompt."""
    return [{"do": "px_tab_new", "pane": name, "title": f"set-up: a new terminal tab in {name} (newSurface)"}, {"do": "neutral_prompt"}]


def make_kind(name, kind, fill):
    """Turns the new terminal pane NAME into its fixture."""
    if kind == "tui":
        return start_tui(name, fill)
    if kind == "shell":
        return start_low_prompt(name)
    if kind == "shellz":
        return start_low_prompt_zebra(name)
    if kind == "page":
        return [{"do": "px_page", "pane": name, "bg": fill, "label": name, "title": f"set-up: page.html in a browser tab of {name} ({fill})"}]
    if kind == "agent":
        # Aimed at the pane (ext_pixel px_agent): a script's untargeted chat docks in a new left column instead.
        return [{"do": "px_agent", "pane": name, "title": f"set-up: an agent chat in {name}, in that pane (target pane:<id>)"}]
    raise ValueError(kind)


class Layout:
    """The panes of a case: [(name, kind, fill, how)], how = (action, pane focused first) or None for p0. window: the
    window's fractions of its screen (window_place) instead of the first pane's 90%; widths: a column width preset given
    to each new column and, at the end, to the first one (columns layouts); tabs: {terminal pane: its number of tabs},
    each tab the pane's fixture (the last one shown)."""

    def __init__(self, key, text, panes, window=None, widths=None, tabs=None):
        self.key, self.text, self.panes, self.window, self.widths = key, text, panes, window, widths
        self.tabs = tabs or {}

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
        fills = {name: (kind, fill) for name, kind, fill, _ in self.panes}
        for name, count in self.tabs.items():
            if fills[name][0] != "tui":
                raise ValueError("more tabs only in a terminal fixture pane")
            steps.append(focus(name))
            for i in range(2, count + 1):
                steps += new_tab(name) + start_tui(name, fills[name][1], label=f"{name}.{i}")
        return steps

    def seconds(self):
        return (sum(EST_PANE[k] for k in self.kinds()) + EST_FOCUS * sum(1 for p in self.panes if p[3] and p[3][1])
                + sum(EST_FOCUS + EST_TAB * (n - 1) for n in self.tabs.values()))


T2 = Layout("2", "p0 T | p1 P", [("p0", "tui", YELLOW, None), ("p1", "page", GREEN, ("splitRight", None))])
# T2 with p0 in 3 terminal tabs. p0's fill is blue: the tab outline is #FFFF00, and a yellow fill would make an outline next
# to the strip's black and a title's white read as p0's own rings to the side judge.
T2T = Layout("2", "p0 T in 3 tabs | p1 P", [("p0", "tui", BLUE, None), ("p1", "page", GREEN, ("splitRight", None))], tabs={"p0": 3})
# Strip columns (newColumn; p3 a row under p2, newRow), every pane a fixture pane, the window at the screen's full width.
# As splits of one 1153 pt pane area, p1 and p2 get 191.5 pt each (cmux22, sweep c7cef08: the strip squeezes splits),
# so no divider had 150 pt of room. As columns sharing 1304 pt (layout.newColumnWidth fitScreen) each is about 435 pt:
# divider 0, the column edge between p0 and p1, moves 150 pt either way (235 pt above the 200 pt minimum).
T4 = Layout("4", "columns p0 T | p1 P | (p2 A / p3 T)",
            [("p0", "tui", YELLOW, None), ("p1", "page", GREEN, ("newColumn", None)), ("p2", "agent", AGENT_FILL, ("newColumn", None)),
             ("p3", "tui", YELLOW, ("newRow", "p2"))],
            window=[0.0, 0.05, 1.0, 0.9])
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
# resize-keyboard's panes (gen_keys.row2_down: p0 | (p1 over p2), p1 under test), each a terminal fixture.
T3RK = Layout("3t", "p0 T | (p1 T / p2 T)",
             [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("splitRight", None)), ("p2", "tui", YELLOW, ("splitDown", None))])
T3S = Layout("3", "p0 T | p1 T | p2 P (splits)",
             [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("splitRight", None)), ("p2", "page", YELLOW, ("splitRight", None))])
# The split tree is binary (SplitNode), so the order of the splits decides which divider a close keeps. T3S splits p1 right
# into p2: (p0 | (p1 | p2)), and closing p1 keeps the p0|p1 divider (on its leading side). T3T makes p2 first, then splits
# p0 right into p1: ((p0 | p1) | p2), and closing p1 keeps the p1|p2 divider, on the closing pane's trailing side (stage
# S3d case (a), frame-owner-s3b 2026-11-04). The app makes the three widths equal after each split and close in both.
T3T =Layout("3t", "p0 T | p1 T | p2 P (splits, p1 nested with p0)",
             [("p0", "tui", YELLOW, None), ("p2", "page", YELLOW, ("splitRight", None)), ("p1", "tui", GREEN, ("splitRight", "p0"))])
C2 = Layout("c2", "columns p0 T | p1 P", [("p0", "tui", YELLOW, None), ("p1", "page", GREEN, ("newColumn", None))])
# T3K with a shell in p1 whose prompt is on its last row (S4 F2). The judge reads tui and page panes only: p1 is
# lowprompt_rows.py's (the bar and the pane's bottom edge on the scan column through p1, per frame).
# S4 H1 (frame-owner-s4 5d22dbc42a08): the striped low prompt in p1 (J, J, K: a band of ground above the terminal), and in the
# bottom-right pane of a 2x2 grid (H, then K: the lines cut off on the left).
T3KZ = Layout("3kz", "p0 T | (p1 S / p2 P), p1 a striped shell with its prompt on the last row",
              [("p0", "tui", YELLOW, None), ("p1", "shellz", GREEN, ("splitRight", None)), ("p2", "page", YELLOW, ("splitDown", None))])
G4Z = Layout("4z", "(p0 T / p2 T) | (p1 T / p3 S), p3 a striped shell with its prompt on the last row",
             [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("splitRight", None)), ("p2", "tui", GREEN, ("splitDown", "p0")),
              ("p3", "shellz", YELLOW, ("splitDown", "p1"))])
T3KP = Layout("3kp", "p0 T | (p1 S / p2 P), p1 a shell with its prompt on the last row",
              [("p0", "tui", YELLOW, None), ("p1", "shell", GREEN, ("splitRight", None)), ("p2", "page", YELLOW, ("splitDown", None))])
# Stage S2b, the layouts of SharedEdgeDuringSpringTests (A | B | C, B split): strip columns, each a third of the viewport, a
# full-width window. 3 columns: the key on p0 springs every edge right of it (p0|p1, p1|p2). 2 columns: column 2 holds p1
# over p2 (splitDown), and the strip fits its viewport after the key.
C3P = Layout("3", "columns p0 T | p1 P | p2 T",
             [("p0", "tui", YELLOW, None), ("p1", "page", GREEN, ("newColumn", None)), ("p2", "tui", YELLOW, ("newColumn", None))],
             window=[0.0, 0.05, 1.0, 0.9], widths="column.widthOneThird")
C2S = Layout("2s", "columns p0 T | (p1 T / p2 P)",
             [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("newColumn", None)), ("p2", "page", YELLOW, ("splitDown", None))],
             window=[0.0, 0.05, 1.0, 0.9], widths="column.widthOneThird")
# Stage S2b with terminals only (2026-11-04): in C3P and C2S the press on the moving edge went to the Chromium page window
# beside it (the app's journal: the page took focus, no divider drag; ab-s2b-sw-3fbd40a), so those films test the catcher,
# not the shared edges. These two keep the same geometry with a terminal where the page was.
C3T = Layout("3t", "columns p0 T | p1 T | p2 T",
             [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("newColumn", None)), ("p2", "tui", YELLOW, ("newColumn", None))],
             window=[0.0, 0.05, 1.0, 0.9], widths="column.widthOneThird")
C2ST = Layout("2st", "columns p0 T | (p1 T / p2 T)",
              [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("newColumn", None)), ("p2", "tui", YELLOW, ("splitDown", None))],
              window=[0.0, 0.05, 1.0, 0.9], widths="column.widthOneThird")
# Stage S2B rule D, the clamp case (SharedEdgeDuringSpringTests.anchorPushesSplitToMinimum, frame-owner-s2 2026-11-04):
# A | B (split x: b1 | b2), terminals only, a full-width window; before each film A takes a third and B two thirds of the
# viewport (clamp_before), so B has about 460 pt above its minimum and the key's trade moves A's edge its full step (5% of
# the viewport, 65 pt; with three thirds B had 28 pt of room, the step stopped at about 33 pt and the planned press missed x
# by 26 pt: ab-s2bdf2-ddf0ac4). b1 starts at its minimum plus CLAMP_ROOM_PT, so the layout clamps x's rest place at A's rest
# edge plus b1's minimum, and at the press (about 70% of a x0.125 spring) x is about 18 pt short of it.
C2X = Layout("2x", "columns p0 T | (p1 T | p2 T)",
             [("p0", "tui", YELLOW, None), ("p1", "tui", GREEN, ("newColumn", None)), ("p2", "tui", YELLOW, ("splitRight", None))],
             window=[0.0, 0.05, 1.0, 0.9])
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

    def __init__(self, cid, title, layout, play, spring, input_kind, before=None, rebuild=None, play_seconds=None,
                 fixture_tunables=(), speeds=None):
        self.cid, self.title, self.layout, self.play, self.spring = cid, title, layout, play, spring
        self.input, self.before, self.rebuild = input_kind, before or [], rebuild or []
        self.play_seconds = play_seconds
        # The case's only speeds (one journey <case>, and its switch variants at them); None: the six speeds and -s1r.
        self.speeds = tuple(speeds) if speeds else None
        # [(key, value)]: Debug tunables the case films with (the tab outline). Required (a build that does not take one
        # is not run), set at the set-up and again in each film after its speed, back to the default in finally.
        self.fixture_tunables = list(fixture_tunables)

    def fixture_steps(self, when):
        return [{"do": "px_tunable", "key": key, "value": value, "required": True,
                 "title": f"{when}: {key} {json.dumps(value)} (the film's fixture; a build without it is not run)"}
                for key, value in self.fixture_tunables]

    def recording(self, jid, label, speed, last=False, switch=None):
        """One px_film step (the speed, the switch when given, the film and the rebuild after it) and its estimated seconds."""
        name = f"{jid}-{label}"
        expected = self.play_seconds(speed)
        # The recorder stops by itself after `seconds`: room for the lead (1 s), the steps' own overhead and the tail.
        seconds = round(1.5 * expected + 6.0, 1)
        start = {"do": "px_record_start", "name": name, "seconds": seconds, "require_hz": 120, "mbps": MOVIE_MBPS,
                 "fixture": self.layout.fixture, "spring": self.spring, "input": self.input,
                 "title": f"start the 120 Hz movie, the trace and scan lines across every pane border and tab strip ({name})"}
        if self.spring:
            start["spring_default"] = {"response": RESPONSE[self.spring], "damping": DAMPING[self.spring]}
        steps = (list(self.before) + self.fixture_steps("the film's fixture") + [G.settle(0.8), start] + self.play(speed)
                 + [G.kit_record_stop(name, 0.4)])
        rebuild = [] if last else list(self.rebuild)  # the journey's last film needs no pane back
        film = {"do": "px_film", "name": name, "steps": steps, "after": rebuild,
                "title": (f"film {name}: Reduce Motion" if speed is None else f"film {name}: every motion.spring.* response / {speed:g}")}
        film.update({"reduce": True} if speed is None else {"speed": speed})
        if switch:
            film["switch"] = {"key": switch[0], "value": switch[1]}
            film["title"] += f", {switch[0]} {'ON' if switch[1] else 'OFF'}"
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


def low_prompt_play(speed):
    """Ctrl-Shift-J on p1 (its bottom edge springs down: p1 grows down), then Ctrl-Shift-K (back up)."""
    return [press(J, "grow"), rest(land(speed)), press(K, "shrink"), rest(land(speed))]


def low_prompt_reverse_play(speed):
    """Ctrl-Shift-J on p1 (it grows down; a low prompt takes F2's bottom hold), then Ctrl-Shift-K at 40% of J's spring, before it
    lands (S4 G1, #35470 5aab4968d19: the reverse press must drop the bottom hold; before the fix it stayed through K's spring).
    debug.terminal_display per film (present counts)."""
    response = RESPONSE["move"] / (speed or 1.0)
    return [{"do": "rpc", "method": "debug.terminal_display", "params": {"action": "start"},
             "title": "debug.terminal_display start (present counters per film)"},
            press(J, "grow"), rest(round(0.4 * response, 3), "40% of J's spring"), press(K, "reverse"), rest(land(speed)),
            {"do": "rpc", "method": "debug.terminal_display", "params": {"action": "stop"}, "keep": "tdisplay",
             "title": "debug.terminal_display stop (host_present_calls, host_fresh_presents)"}]


def presses_play(keys, why):
    """KEYS [(key, label)] pressed 40% of a spring apart (the next press before the last one lands), then the landing; S4 H1.
    debug.terminal_display per film."""
    def play(speed):
        response = RESPONSE["move"] / (speed or 1.0)
        steps = [{"do": "rpc", "method": "debug.terminal_display", "params": {"action": "start"},
                  "title": "debug.terminal_display start (present counters per film)"}]
        for i, (key, label) in enumerate(keys):
            if i:
                steps.append(rest(round(0.4 * response, 3), f"40% of the spring ({why})"))
            steps.append(press(key, label))
        steps += [rest(land(speed)),
                  {"do": "rpc", "method": "debug.terminal_display", "params": {"action": "stop"}, "keep": "tdisplay",
                   "title": "debug.terminal_display stop (host_present_calls, host_fresh_presents)"}]
        return steps
    return play, (lambda s: 0.2 + 0.4 * (len(keys) - 1) * RESPONSE["move"] / (s or 1.0) + land(s))


def resize_keyboard_keys():
    """[(key, modifiers)] of the open-P0 journey resize-keyboard, in order (its rk_press steps, one press each)."""
    with open(RESIZE_KEYBOARD) as f:
        steps = json.load(f)["steps"]
    keys = [(st["key"], list(st["modifiers"])) for st in steps if st["do"] == "rk_press"]
    if not keys or any(st.get("count", 1) != 1 for st in steps if st["do"] == "rk_press"):
        raise ValueError(f"{RESIZE_KEYBOARD}: px-keys-rk-3t plays single presses; the journey has {keys}")
    return keys


def resize_keyboard_play(speed):
    steps = []
    for i, key in enumerate(resize_keyboard_keys()):
        steps += [press(key, f"key{i}"), rest(land(speed))]
    return steps


def held_play(speed):
    return [{"do": "rk_hold", "key": "l", "modifiers": ["control", "shift"], "seconds": 1.5, "mark": "hold",
             "title": "Ctrl-Shift-L held 1.5 s (debug.key auto-repeat)"}, rest(land(speed)),
            {"do": "rk_press", "key": "h", "modifiers": ["control", "shift"], "count": 30, "gap_ms": 33, "mark": "burst",
             "title": "Ctrl-Shift-H x30, 33 ms apart (real HID)"}, rest(land(speed))]


def held_start():
    """Before each held-keys film: p0 back to half the pane area (equalizeSplits, as the layout made it), so every film
    starts from the same widths. A held film ends with p0 at its minimum width; until 2026-11-04 the next film started
    there (ab-s1bt-sw-523c9f6: off-s1 began with p0 576 pt and 168 pt tabs, on-s1 with p0 200 pt and a scrolled strip of
    72 pt tabs), so a switch's OFF and ON films at x1 did not start alike."""
    return [focus("p0"), {"do": "px_equalize", "panes": ["p0", "p1"], "title": "set-up: equalize p0 | p1 (every film starts alike)"},
            G.settle(1.0)]


def held_close_play(speed):
    """held_play with p0's middle tab closed by a script 50 ms after the hold's first key-down (ext_pixel px_hold_tab_close)."""
    steps = held_play(speed)
    assert steps[0]["do"] == "rk_hold", steps[0]
    hold = dict(steps[0], do="px_hold_tab_close", close={"pane": "p0", "which": "middle", "after_ms": 50},
                title="Ctrl-Shift-L held 1.5 s (debug.key auto-repeat); 50 ms after its first key-down a script closes p0's "
                      "middle tab (action closeTab, the tab from snapshot.get)")
    return [hold] + steps[1:]


def key_then_drag_play(target, by, what, share=1.0):
    """Stage S2b: Ctrl-Shift-L on p0 (its column edge springs), then a real HID drag of TARGET by BY in 400 ms, its call
    60 ms after the key-down (ext_pixel px_key_then_drag: the press where the spring will have the edge; SHARE of the
    key's step: 0 for an edge the key does not move)."""
    def play(speed):
        return [{"do": "px_key_then_drag", "key": "l", "modifiers": ["control", "shift"], "after_ms": 60,
                 "drag": {"target": target, "by": list(by), "duration_ms": 400, "share": share},
                 "spring_default": {"response": RESPONSE["move"], "damping": DAMPING["move"]}, "mark": "kd",
                 "title": f"Ctrl-Shift-L on p0, then 60 ms after its key-down a real drag of {what} by {list(by)} pt in 400 ms"},
                rest(land(speed), "the key's spring and the drag land and rest")]
    return play, (lambda speed: 1.0 + land(speed))


# b1's width above its minimum before each clamp film. The key's step is 5% of the viewport (about 65 pt) and about 30%
# of it is left at a x0.125 mouse-down (about 20 pt), so the clamp takes the held split about 14 pt; a press that missed
# leaves b1 at this room above its minimum, a grab ends it at its minimum (px_key_then_drag: a still drag's grab).
CLAMP_ROOM_PT = 6


def clamp_before():
    """Before each clamp film: the split x (vertical divider 1) dragged left into b1's minimum, then right by CLAMP_ROOM_PT,
    so every film starts with b1 at its minimum plus the room; then p0 focused for the key."""
    # Every column back to a third of the viewport first: the key trades p0's and p1's widths (KEYS #34123) and stops at
    # p1's minimum, while the rebuild's Ctrl-Shift-H takes back a full step, so without this the next film starts with
    # other widths (ab-s2bdc-813ac15: OFF began with p0's edge at 642.5 pt, ON at 611).
    widths = []
    for name, preset, what in (("p0", "column.widthOneThird", "a third"), ("p1", "column.widthTwoThirds", "two thirds")):
        widths += [focus(name), {"do": "try_action", "action": preset, "title": f"set-up: {name}'s column to {what} of the viewport"}]
    widths.append(rest(land(SPEEDS_S2BT[0][1]), "the column widths land (their springs at the film's speed)"))
    # The set-up drags find x in the geometry trace's newest sample: before the first film no trace runs (round
    # ab-s2bd-sw-813ac15: "no vertical divider 1 (0 shown)"), and before a later one the newest sample is from the last
    # film, before its rebuild moved x. A trace started here samples the layout as it is (the film's recorder restarts it).
    return widths + [{"do": "rpc", "method": "debug.motion", "params": {"action": "trace_start", "window": 0},
             "title": "set-up: a geometry trace, so the set-up drags find x where it is now"},
            G.kit_drag({"divider": 1}, [-300, 0], 500, "minimum", "set-up: the split x 300 pt left (b1 stops at its minimum)"),
            rest(0.6, "the split rests at b1's minimum"),
            G.kit_drag({"divider": 1}, [CLAMP_ROOM_PT, 0], 300, "room", f"set-up: the split x {CLAMP_ROOM_PT} pt right"),
            rest(0.6, "the split rests at the pointer"), focus("p0")]


def key_then_clamp_play(speed, by=1, ms=1500):
    """Ctrl-Shift-L on p0 (A's edge springs right into B: the key trades A's and B's widths), then 60 ms after its key-down
    a real press on the split x as it moves, BY pt right in MS (1 pt held 1.5 s: rule D holds x where it is drawn; A's rest
    edge leaves b1 less than its minimum, so x springs to A's rest edge plus b1's minimum and stops there; 30 pt in 0.6 s:
    the pointer passes that clamp, and x never shows behind the pointer and ends under it)."""
    return [{"do": "px_key_then_drag", "key": "l", "modifiers": ["control", "shift"], "after_ms": 60,
             "drag": {"target": {"divider": 1}, "by": [by, 0], "duration_ms": ms, "less_pt": CLAMP_ROOM_PT},
             "spring_default": {"response": RESPONSE["move"], "damping": DAMPING["move"]}, "mark": "kc",
             "title": f"Ctrl-Shift-L on p0, then 60 ms after its key-down a real press on the split x, {by} pt right in {ms / 1000:g} s"},
            rest(land(speed), "A's spring and the split's clamp land and rest")]


def cmd_col_edge_play(speed):
    """A real Command-drag of vertical divider 1 (the p1|p2 column edge) 30 pt LEFT in 0.3 s, Command down for the whole drag
    (hid_drag proves it reached cmux). Every column takes p1's width, 15 pt narrower: the strip still fits its viewport, so
    the camera has no room (the red case of CommandColumnEdgeFollowsPointerTests, -30). Read with cmd_edge.py: the edge at
    the mouse-up within 0.5 pt of the pointer, and no move after the up (on feat it slid on under the still pointer)."""
    return [{"do": "hid_drag", "target": {"divider": 1}, "by": [-30, 0], "duration_ms": 300, "hold_ms": 0,
             "modifiers": ["cmd"], "mark": "cmd", "title": "Command-drag of the p1|p2 column edge 30 pt left in 0.3 s"},
            rest(0.6 + land(speed), "the columns land and rest")]


def cmd_col_edge_rebuild():
    """Every column back to a third of the viewport for the next film (the Command drag changed every width)."""
    steps = []
    for name in ("p0", "p1", "p2"):
        steps += [focus(name), {"do": "try_action", "action": "column.widthOneThird", "title": f"set-up: {name}'s column to a third"}]
    return steps + [rest(0.8, "the column widths land"), focus("p0")]


def key_then_drag_rebuild(target, by, speed=None):
    """The layout back for the next film: the dragged edge back by -BY (at rest now), then Ctrl-Shift-H on p0 (its spring at
    the films' SPEED, x0.25 unless named)."""
    return [G.kit_drag(target, [-v for v in by], 400, "back", f"the dragged edge back by {[-v for v in by]} pt"),
            rest(0.6, "the edge rests at the pointer"), focus("p0"), press(H, "unkey"),
            rest(land(speed or SPEEDS_S2B[0][1]), "p0's column back (its key spring lands)")]


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
    # T4: divider 0 is the column edge between p0's and p1's columns (a column-edge drag that pushes the strip; 235 pt of
    # room each way). Before, as splits, divider 1 sat between two panes at their minimum width (S2 A/B 13:4xZ).
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
    # S4 F2 (frame-owner-s4 30eccfc5903): the low prompt rides the bottom of a pane a key grows down. The cases above never
    # show it (their terminals run the border fixture on the alternate screen, where motionAnchor answers .top).
    out.append(Case(f"px-keys-lowprompt-{T3KP.key}", f"Ctrl-Shift-J, then K, on p1, a shell with its prompt on the last row "
                    f"under an orange bar ({T3KP.text})", T3KP, low_prompt_play, "move", "keys", before=[focus("p1")],
                    play_seconds=lambda s: 2 * (0.1 + land(s)), speeds=SPEEDS_LOWPROMPT))
    out.append(Case(f"px-keys-lowprompt-reverse-{T3KP.key}", f"Ctrl-Shift-J on p1, then Ctrl-Shift-K at 40% of J's spring, a shell with "
                    f"its prompt on the last row under an orange bar ({T3KP.text})", T3KP, low_prompt_reverse_play, "move", "keys (reverse)",
                    before=[focus("p1")], play_seconds=lambda s: 0.2 + 0.4 * RESPONSE["move"] / (s or 1.0) + land(s),
                    speeds=(("s025", 0.25),)))
    # S4 H1 (frame-owner-s4 5d22dbc42a08, fix 03c050e893fc; switch on only): the bottom hold of a low prompt after a press on
    # the other axis (H then K on the bottom-right pane: lines cut off on the left) and after two grow presses and a shrink
    # (J, J, K: a band of ground above the terminal). The reverse case above (J then K) shows neither.
    play, secs = presses_play([(J, "grow1"), (J, "grow2"), (K, "shrink")], "J, J, K")
    out.append(Case(f"px-keys-lowprompt-jjk-{T3KZ.key}", f"Ctrl-Shift-J twice, then Ctrl-Shift-K, each at 40% of the last spring, on p1 "
                    f"({T3KZ.text})", T3KZ, play, "move", "keys (J, J, K)", before=[focus("p1")], play_seconds=secs,
                    speeds=(("s025", 0.25),)))
    play, secs = presses_play([(H, "wider"), (K, "taller")], "H, K")
    out.append(Case(f"px-keys-lowprompt-hk-{G4Z.key}", f"Ctrl-Shift-H, then Ctrl-Shift-K at 40% of its spring, on the bottom-right "
                    f"pane p3 ({G4Z.text})", G4Z, play, "move", "keys (H, K)", before=[focus("p3")], play_seconds=secs,
                    speeds=(("s025", 0.25),)))
    # cmux-ad m6 (d): resize-keyboard's presses on terminal fixtures, so judge_m6.py reads each terminal's edge per frame.
    out.append(Case(f"px-keys-rk-{T3RK.key}", f"the resize-keyboard presses (Ctrl-Shift-L, H, J, K, Ctrl-Cmd-Right, Left, Down, "
                    f"Up) on p1 ({T3RK.text})", T3RK, resize_keyboard_play, "move", "keys", before=[focus("p1")],
                    play_seconds=lambda s: len(resize_keyboard_keys()) * (0.1 + land(s))))
    out.append(Case(f"px-keys-held-{T2.key}", f"Ctrl-Shift-L held, then Ctrl-Shift-H x30 every 33 ms, on p0 ({T2.text})", T2,
                    held_play, None, "held keys", before=held_start(), play_seconds=lambda s: 2.6 + 2 * land(s)))
    # Stage S1B 1b (frame-owner-s1b): a tab closes while the held key resizes its pane; every tab outlined, so the judge can
    # read each tab cell against its strip. One tab back in p0 after each film, so the next starts with 3 tabs again.
    out.append(Case(f"px-keys-held-{T2T.key}-tabclose",
                    f"Ctrl-Shift-L held with p0's middle tab closed 50 ms after its first key-down, then Ctrl-Shift-H x30 every "
                    f"33 ms, on p0 ({T2T.text})", T2T, held_close_play, None, "held keys (a tab closes during the hold)",
                    before=held_start(), rebuild=[focus("p0")] + new_tab("p0") + start_tui("p0", BLUE) + [G.settle(1.0)],
                    play_seconds=lambda s: 2.6 + 2 * land(s), fixture_tunables=[(TAB_OUTLINE, True)]))
    # The same close in a narrow p0 whose strip overflows (p0 at its minimum width, three tabs wider than the strip, the
    # strip scrolled): the first S1B 1b round filmed it by accident (ab-s1bt-sw-523c9f6 on-s1, a start line that stayed and
    # faded, a left edge 1-2 samples early). Before each film: p0 back to half, then 30 x Ctrl-Shift-H to its minimum.
    out.append(Case(f"px-keys-held-{T2T.key}-tabclose-narrow",
                    f"the tab-close held keys with p0 at its minimum width and its strip scrolled ({T2T.text})", T2T, held_close_play,
                    None, "held keys (a tab closes during the hold, scrolled strip)",
                    before=held_start() + [{"do": "rk_press", "key": "h", "modifiers": ["control", "shift"], "count": 30, "gap_ms": 33,
                                            "title": "set-up: p0 to its minimum width (30 x Ctrl-Shift-H, real HID)"},
                                           G.settle(2.0)],
                    rebuild=[focus("p0")] + new_tab("p0") + start_tui("p0", BLUE) + [G.settle(1.0)],
                    play_seconds=lambda s: 2.6 + 2 * land(s), fixture_tunables=[(TAB_OUTLINE, True)]))
    play, secs = new_and_close_play("newColumn", "New Column")
    out.append(Case(f"px-new-column-{C2.key}", f"New Column on p1, then Cmd-W on it ({C2.text})", C2, play, "split", "new column",
                    before=[focus("p1")], play_seconds=secs))
    play, secs = new_and_close_play("newRow", "New Row")
    out.append(Case(f"px-new-row-{C2.key}", f"New Row under p0, then Cmd-W on it ({C2.text})", C2, play, "split", "new row",
                    before=[focus("p0")], play_seconds=secs))
    # p1 comes back nested with p2, as the layout built it (splitLeft on p2: split right, then swap), so every film closes the
    # same split. Until 2026-11-04 the rebuild split p0, so every film after the first closed p1 nested with p0 and kept the
    # other divider (ab-s3-sw-a6d4037: off-s1 kept the divider at x 589, the other 3 films the one at x 973).
    out.append(Case(f"px-close-pane-{T3S.key}", f"Cmd-W on the middle split p1, nested with p2 (the p0|p1 divider stays); it comes "
                    f"back after each speed ({T3S.text})", T3S,
                    close_play, "split", "close pane", before=[focus("p1")],
                    rebuild=[focus("p2")] + new_pane("p1", "splitLeft") + start_tui("p1", GREEN) + [G.settle(1.0)],
                    play_seconds=lambda s: 0.2 + land(s, "split")))
    # Stage S3d case (a): the divider on the closing pane's trailing side stays.
    out.append(Case(f"px-close-pane-{T3T.key}", f"Cmd-W on the middle split p1, nested with p0 (the p1|p2 divider stays, S3d case "
                    f"(a)); it comes back after each speed ({T3T.text})", T3T,
                    close_play, "split", "close pane (the trailing divider stays)", before=[focus("p1")],
                    rebuild=[focus("p0")] + new_pane("p1", "splitRight") + start_tui("p1", GREEN) + [G.settle(1.0)],
                    play_seconds=lambda s: 0.2 + land(s, "split")))
    out.append(Case(f"px-close-column-{C3.key}", f"Cmd-W on the middle column's only pane p1; it comes back after each speed ({C3.text})",
                    C3, close_play, "split", "close column", before=[focus("p1")],
                    rebuild=[focus("p0")] + new_pane("p1", "newColumn") + start_tui("p1", GREEN) + [G.settle(1.0)],
                    play_seconds=lambda s: 0.2 + land(s, "split")))
    out.append(Case(f"px-window-resize-{T4.key}", f"the window corner 300 x 150 pt in and back out ({T4.text})", T4, window_play, None,
                    "window resize (window_drag)", play_seconds=lambda s: 2.6))
    # Stage S2b (frame-owner-s2): a drag during a key spring. The shared edges keep their rest gaps, the dragged edge follows
    # the pointer; at x0.25 only (SPEEDS_S2B), a film whose spring had landed at the mouse-down is "not run".
    # Since KEYS (#34123) Ctrl-Shift-L on p0 trades width between p0's and p1's columns: the p1|p2 column edge stays where
    # it rests (share 0), while p1's left edge springs; a split divider in p1's column spans it (its middle moves less
    # than the key's step, inside its span).
    for layout, target, by, what, name, hit, share in ((C3P, {"divider": 1}, (150, 0), "the p1|p2 column edge", "drag", True, 0.0),
                                                       (C2S, {"row_divider": 0}, (0, 120), "the p1/p2 split divider", "split-drag", False, 1.0)):
        play, secs = key_then_drag_play(target, by, what, share)
        out.append(Case(f"px-keys-then-{name}-{layout.key}", f"Ctrl-Shift-L on p0, then {what} dragged {list(by)} pt during its "
                        f"spring ({layout.text})", layout, play, "move", "key then drag", before=[focus("p0")],
                        rebuild=key_then_drag_rebuild(target, by), play_seconds=secs,
                        fixture_tunables=[(HIT_WIDTH, 24)] if hit else [], speeds=SPEEDS_S2B))
    for layout, target, by, what, name, hit, share in ((C3T, {"divider": 1}, (150, 0), "the p1|p2 column edge", "drag", True, 0.0),
                                                       (C2ST, {"row_divider": 0}, (0, 120), "the p1/p2 split divider", "split-drag", False, 1.0)):
        play, secs = key_then_drag_play(target, by, what, share)
        out.append(Case(f"px-keys-then-{name}-{layout.key}", f"Ctrl-Shift-L on p0, then {what} dragged {list(by)} pt during its "
                        f"spring ({layout.text}; terminals only)", layout, play, "move", "key then drag", before=[focus("p0")],
                        rebuild=key_then_drag_rebuild(target, by, speed=SPEEDS_S2BT[0][1]), play_seconds=secs,
                        fixture_tunables=[(HIT_WIDTH, 24)] if hit else [], speeds=SPEEDS_S2BT))
    out.append(Case(f"px-keys-then-clamp-{C2X.key}", f"Ctrl-Shift-L on p0, then the split x in B held still during its spring: A's "
                    f"rest edge leaves b1 under its minimum, x stops at A's rest edge plus b1's minimum ({C2X.text}; terminals only)",
                    C2X, key_then_clamp_play, "move", "key then held split (clamp)", before=clamp_before(),
                    rebuild=[focus("p0"), press(H, "unkey"), rest(land(SPEEDS_S2BT[0][1]), "p0's column back (its key spring lands)")],
                    play_seconds=lambda s: 2.0 + land(s), fixture_tunables=[(HIT_WIDTH, 24)], speeds=SPEEDS_S2BT))
    # S2B Command column edge (frame-owner-s2 #36017, CommandColumnEdgeFollowsPointerTests): with Command held, a column-edge
    # drag gives every column the dragged column's width; the dragged edge must still follow the pointer. Three columns at a
    # third each fit the viewport (no camera room): on feat a 30 pt drag of c1's right edge (vertical divider 1) showed 31 pt,
    # then slid on to 56 pt under a still pointer. Left, so the strip still fits after the drag (right would make it scroll).
    out.append(Case(f"px-cmd-col-edge-{C3T.key}", f"the p1|p2 column edge dragged 30 pt left with Command held "
                    f"({C3T.text}; terminals only; every column takes p1's width; the strip still fits)", C3T, cmd_col_edge_play, None,
                    "command drag",
                    before=[focus("p0")], rebuild=cmd_col_edge_rebuild(), play_seconds=lambda s: 1.8 + land(s),
                    fixture_tunables=[(HIT_WIDTH, 24)], speeds=SPEEDS_S1R))
    # The pointer chases the clamp (frame-owner-s2's SharedEdgeClamp.follow, #35775 ddf0ac45b40): 30 pt right in 0.6 s, past
    # the clamp (8-18 pt away at x0.125).
    out.append(Case(f"px-keys-then-clamp-chase-{C2X.key}", f"Ctrl-Shift-L on p0, then the split x in B dragged 30 pt right in 0.6 s during "
                    f"its spring, past the clamp at A's rest edge plus b1's minimum ({C2X.text}; terminals only)",
                    C2X, lambda s: key_then_clamp_play(s, by=30, ms=600), "move", "key then drag past the clamp", before=clamp_before(),
                    rebuild=[focus("p0"), press(H, "unkey"), rest(land(SPEEDS_S2BT[0][1]), "p0's column back (its key spring lands)")],
                    play_seconds=lambda s: 1.1 + land(s), fixture_tunables=[(HIT_WIDTH, 24)], speeds=SPEEDS_S2BT))
    return out


def journey(case, jid, speeds, part_note, switch_key=None):
    """One journey of CASE: its set-up, one film per (label, speed) or (label, speed, (key, value)) of SPEEDS, the after
    check. With SWITCH_KEY the switch goes back to its default in finally."""
    steps = [fixture_settings()] + G.first_pane(jid, False) + fixture_files()
    if case.layout.window:
        place = next(st for st in steps if st["do"] == "window_place")
        place.update(fraction=list(case.layout.window), title=f"set-up: the window at {case.layout.window} of the screen")
    steps.append({"do": "px_tunable", "key": "browserResize.pageBackdrop", "value": False,
                  "title": "set-up: a Chromium page that lags shows the gap (browserResize.pageBackdrop off, where the store takes it)"})
    if "agent" in case.layout.kinds():
        steps.append({"do": "px_agent_css", "fill": AGENT_FILL, "title": "set-up: agent-pane/theme.css: the agent ground and its rings"})
    steps += case.fixture_steps("set-up")
    steps += case.layout.build() + [G.settle(1.5)]
    seconds = EST_BASE + case.layout.seconds()
    names = []
    for n, spec in enumerate(speeds):
        label, speed = spec[0], spec[1]
        film, cost = case.recording(jid, label, speed, last=n == len(speeds) - 1, switch=spec[2] if len(spec) > 2 else None)
        if switch_key == "motion.frameOwner.pages" and "page" in case.layout.kinds():
            # S5 (cmux-ad m16 item 4): whether the page is hosted in cmux's layer tree, before and after each film
            # (debug.cef tracker.hosted_pages, hosting_refused), next to the pixels that show it follows its pane.
            film["steps"].insert(0, {"do": "rpc", "method": "debug.cef", "params": {}, "keep": "cef-before",
                                     "title": "debug.cef before the film (tracker.hosted_pages, hosting_refused)"})
            film["steps"].append({"do": "rpc", "method": "debug.cef", "params": {}, "keep": "cef-after",
                                  "title": "debug.cef after the film (tracker.hosted_pages, hosting_refused)"})
            cost += 0.2
        steps.append(film)
        seconds += cost
        names.append(film["name"])
    steps += after_check()
    seconds += EST_AFTER
    budget = int(min(BUDGET_MAX, max(BUDGET_MIN, round(seconds * MARGIN))))
    final = ([{"do": "px_tunable", "key": switch_key, "value": None, "title": f"clean-up: {switch_key} back to its default"}]
             if switch_key else []) + [
             {"do": "px_tunable", "key": key, "value": None, "title": f"clean-up: {key} back to its default"}
             for key, _ in case.fixture_tunables] + [
             {"do": "px_springs", "reset": True, "title": "clean-up: springs and Reduce Motion back"},
             {"do": "px_tunable", "key": "browserResize.pageBackdrop", "value": None, "title": "clean-up: the page backdrop back"},
             {"do": "px_agent_css", "remove": True, "title": "clean-up: agent-pane/theme.css removed"},
             settings_back()]
    speeds_text = ", ".join(("Reduce Motion" if sp[1] is None else f"x{sp[1]:g}")
                            + (f" {'ON' if sp[2][1] else 'OFF'}" if len(sp) > 2 else "") for sp in speeds)
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


def switch_short(key):
    """The journey suffix of a switch key: its last dotted part, lowercase letters and digits (motion.frameOwner.terminals:
    terminals)."""
    return "".join(c for c in key.split(".")[-1].lower() if c.isalnum()) or "switch"


def switch_variants(case, key):
    """CASE filmed with KEY OFF then ON, at x1 and under Reduce Motion: off-s1, on-s1, off-reduce, on-reduce, in as few
    journeys <case>-sw-<short>[-a|-b] as fit one lease each."""
    films = [(f"{state}-{label}", speed, (key, state == "on")) for label, speed in (case.speeds or SPEEDS_S1R)
             for state in ("off", "on")]
    base = f"{case.cid}-sw-{switch_short(key)}"
    groups = [films]
    while True:
        built = [journey(case, base, groups[0], f" ({key} OFF and ON)", key)] if len(groups) == 1 else \
            [journey(case, f"{base}-{'abc'[i]}", g, f" ({key} OFF and ON, part {'abc'[i]})", key) for i, g in enumerate(groups)]
        if all(j["estimate_seconds"] * MARGIN <= BUDGET_MAX for j in built) or len(groups) >= len(films):
            return built
        size = -(-len(films) // (len(groups) + 1))
        groups = [films[i:i + size] for i in range(0, len(films), size)]


def journeys(switch=None):
    out = []
    for case in cases():
        if case.speeds:
            labels = ", ".join(("Reduce Motion" if sp is None else f"x{sp:g}") for _, sp in case.speeds)
            out.append(journey(case, case.cid, list(case.speeds), f" ({labels} only)"))
        else:
            out += sweep(case)
            out.append(journey(case, f"{case.cid}-s1r", list(SPEEDS_S1R), " (x1 and Reduce Motion: any bench build)"))
        if switch:
            out += switch_variants(case, switch)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--out")
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--switch", help="a boolean Debug tunable: each chosen case filmed with it OFF and ON (<case>-sw-<short>)")
    opts = ap.parse_args()
    if opts.switch and not opts.only:
        ap.error("--switch needs --only (the cases to film with the switch OFF and ON)")
    every = journeys(opts.switch)
    if opts.switch:
        # The switch journeys of the chosen cases only: --only px-col-drag-2 matches px-col-drag-2-sw-terminals[-a|-b].
        every = [j for j in every if "-sw-" in j["id"]]
    chosen = [j for j in every if not opts.only or any(of_case(j["id"], o) for o in opts.only)]
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


def of_case(jid, only):
    """Whether journey JID is ONLY's (a case id or a journey id): ONLY itself, or ONLY and a journey suffix. A case id that
    starts another one (px-keys-held-2, px-keys-held-2-tabclose) never takes the other's journeys."""
    return jid.startswith(only) and JOURNEY_SUFFIX.fullmatch(jid[len(only):]) is not None


def prune(out, keep):
    """Removes px-*.json files in OUT that this generator wrote (their source says so) and no longer makes. Switch
    journeys (<case>-sw-<short>) come only from a --switch run, so a plain run keeps them."""
    removed = []
    for name in sorted(os.listdir(out)):
        if not (name.startswith("px-") and name.endswith(".json")) or name[:-5] in keep or "-sw-" in name:
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
