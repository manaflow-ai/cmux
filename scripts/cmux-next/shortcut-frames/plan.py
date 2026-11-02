#!/usr/bin/env python3
"""SHORTCUT FRAMES case plan: every row of shortcut-list.json (enumerate.py) as video cases for the HARNESS kit.

A case is one shortcut row in one condition: arm (cold = the first press after launch; warm = repeated presses),
load (idle, one busy pane, 12 busy panes: the TUI kit's load; the 15 GB memory hog), theme (dark, light), animations
(on = the person's default; off = ui.animations.enabled false, where every change must be whole in one frame), and build
(the dogfood build and a feat-cmux-next tip build, each with the kit's debug.screen_record).

Each case carries a scenario in a small step language the kit's driver runs (no second harness here):
  {"rpc": METHOD, "params": {...}}        a debug socket call (setup and undo, never the measured key)
  {"press": STROKE, "label": LABEL}       the measured key: a real HID key-down/up through the kit (CuaDriver hotkey);
                                          the kit records its key-down time on the frames' host clock
  {"wait_s": S}                           settle
  {"repeat": N, "steps": [...]}           warm presses
Setup makes the context the row needs (a focused terminal, a page, ...); undo puts the window back so the next press
starts from the same frame. A row whose context this planner cannot set up yet gets "setup": "todo" and is listed.

Waves (the order the cases run): 1 = Cmd-T and Shift-Cmd-L, every condition; 2 = the other rows the order names,
warm and cold, idle and 12 busy panes, dark, both builds; 3 = every other row, warm idle dark on the feat tip build
(more conditions for a row only after a finding).

Usage: plan.py --list shortcut-list.json --out cases.json
"""
from __future__ import annotations

import argparse
import itertools
import json
import sys

WARM_PRESSES = 20
COLD_LAUNCHES = 5
SETTLE_S = 1.0

ARMS = ("warm", "cold")
LOADS = ("idle", "busy1", "busy12", "hog15g")
THEMES = ("dark", "light")
ANIMATIONS = ("on", "off")
BUILDS = ("feat-tip", "dogfood-f350103cc146")

# How each context is made from the base window (one workspace, one terminal pane, focused), by action.run.
SETUP = {
    "any": [],
    "terminal": [],
    "non-page": [],
    "grid": [{"rpc": "action.run", "params": {"action": "newColumn"}},
             {"rpc": "action.run", "params": {"action": "focusLeft"}}],
    "two-panes": [{"rpc": "action.run", "params": {"action": "newColumn"}},
                  {"rpc": "action.run", "params": {"action": "focusLeft"}}],
    "page": [{"rpc": "action.run", "params": {"action": "openBrowser"}}, {"wait_s": 2.0}],
    "omnibar": [{"rpc": "action.run", "params": {"action": "openBrowser"}}, {"wait_s": 2.0},
                {"rpc": "action.run", "params": {"action": "focusLocation"}}],
    "non-terminal": [{"rpc": "action.run", "params": {"action": "palette.newAgentChat"}}, {"wait_s": 2.0}],
    "agent": [{"rpc": "action.run", "params": {"action": "palette.newAgentChat"}}, {"wait_s": 2.0}],
    "palette": [{"rpc": "action.run", "params": {"action": "commandPalette"}}, {"wait_s": 0.5}],
    "sidebar-list": [{"rpc": "action.run", "params": {"action": "focusSidebar"}}],
    "canvas": [{"rpc": "action.run", "params": {"action": "toggleCanvasLayout"}}, {"wait_s": 1.0}],
}

# How the window goes back after one press (so the next press starts from the same frame).
UNDO = {
    "new-tab": [{"rpc": "action.run", "params": {"action": "closeTab"}}],
    "new-pane": [{"rpc": "action.run", "params": {"action": "closePane"}}],
    "new-workspace": [{"rpc": "action.run", "params": {"action": "closeWorkspace", "args": {"confirm": True}}}],
    "overlay": [{"rpc": "debug.key", "params": {"key": "escape"}}, {"rpc": "debug.key", "params": {"key": "escape"}}],
    "chrome": "again",     # a toggle: the same action again by the socket
    "switch": "back",      # select the item the press left, by the socket
    "focus": "back",
    "close": "remake",     # the setup makes the object the press closes
}


def case_rows(row: dict) -> list[dict]:
    if row["priority"] == 1 and row["action"] in ("newTab.default", "openBrowser"):
        wave, grid = 1, itertools.product(ARMS, LOADS, THEMES, ANIMATIONS, BUILDS)
    elif row["priority"] == 1:
        wave, grid = 2, itertools.product(ARMS, ("idle", "busy12"), ("dark",), ("on",), BUILDS)
    else:
        wave, grid = 3, [("warm", "idle", "dark", "on", "feat-tip")]
    out = []
    for arm, load, theme, anim, build in grid:
        if row["effect"] == "exit":
            continue
        name = f"{row['action']}[{row['stroke']}]/{arm}/{load}/{theme}/anim-{anim}/{build}"
        setup = SETUP.get(row["context"], "todo")
        undo = UNDO.get(row["effect"], [])
        press = {"press": row["stroke"], "label": name}
        if arm == "warm":
            steps = [{"repeat": WARM_PRESSES, "steps": [press, {"wait_s": SETTLE_S}, {"undo": undo}, {"wait_s": 1.0}]}]
        else:
            steps = [{"repeat": COLD_LAUNCHES, "steps": [{"launch": "fresh"}, {"setup": setup}, press,
                                                        {"wait_s": SETTLE_S}, {"quit": True}]}]
        out.append({"name": name, "wave": wave, "stroke": row["stroke"], "action": row["action"],
                    "effect": row["effect"], "context": row["context"], "when": row["when"], "arm": arm,
                    "load": load, "theme": theme, "animations": anim, "build": build,
                    "settings": {"ui.animations.enabled": anim == "on",
                                 "appearance.theme": "Builtin Dark" if theme == "dark" else "Builtin Light"},
                    "setup": setup, "steps": steps,
                    "judge": {"animated": anim == "on" and row["effect"] in ("new-pane", "close", "chrome",
                                                                             "new-tab", "new-workspace"),
                              "what": row["judge"]}})
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--list", required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    rows = json.load(open(a.list, encoding="utf-8"))["rows"]
    cases = [c for r in rows for c in case_rows(r)]
    todo = sorted({c["action"] + " (" + c["context"] + ")" for c in cases if c["setup"] == "todo"})
    by_wave = {w: sum(1 for c in cases if c["wave"] == w) for w in (1, 2, 3)}
    json.dump({"cases": cases, "setup_todo": todo, "by_wave": by_wave}, open(a.out, "w", encoding="utf-8"), indent=1)
    print(json.dumps({"cases": len(cases), "by_wave": by_wave, "setup_todo": len(todo)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
