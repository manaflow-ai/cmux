#!/usr/bin/env python3
"""gen_m37.py [--out DIR]: cmux-ad m37 (the black Chromium New Tab, #36908; RESIZE OWNER 02:1xZ). One journey,
px-m37-newtab-still: dark mode (theme Builtin Dark, app theme from the terminal), a window picture (appearance.background, a
public-domain painting), three panes side by side: p0 a terminal (the kit's after check), p1 the cmux New Tab (a real Cmd-T), p2 a new
Chromium tab from a real Cmd-Shift-L (key.openBrowser; browser.defaultEngine chromium). With #36908 the Chromium New Tab's page area shows the window
picture through it, as the cmux New Tab beside it does; without it the page area is an opaque near-black box. A short whole-window
recording at 120 Hz after both pages settle; the still is a frame of it (each pane's area is read in the gallery)."""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cases as G  # noqa: E402
import gen_pixel as P  # noqa: E402

JID = "px-m37-newtab-still"
PAINTING = "velde-small-ship-storm"


def settings():
    return {"do": "settings_file", "title": f"set-up: dark mode (Builtin Dark, app theme from the terminal), window picture "
            f"{PAINTING}, Chromium as the default browser engine, no close warning, no hover cards",
            "set": {"sidebar": {"hoverCards": {"enabled": False}},
                    "appearance": {"theme": "Builtin Dark", "appTheme": "followTerminal", "background": PAINTING},
                    "browser": {"defaultEngine": "chromium"},
                    "app": {"warnBeforeClosingTab": False}}}


def steps():
    s = [settings()] + G.first_pane(JID, False)
    # p0 stays a terminal for the kit's after check (its prompt); the two tabs open in p1 and p2 (a split of p1)
    s += P.new_pane("p1", "splitRight")
    s += [P.focus("p1")] + P.new_pane("p2", "splitRight")
    s += [P.focus("p1"), P.rest(0.4, "focus settles"),
          {"do": "rk_press", "key": "t", "modifiers": ["command"], "count": 1, "gap_ms": 0, "mark": "cmd-t",
           "title": "Cmd-T in p1: the cmux New Tab (real HID key)"}, P.rest(1.5, "the cmux New Tab shows")]
    s += [P.focus("p2"), P.rest(0.4, "focus settles"),
          {"do": "rk_press", "key": "l", "modifiers": ["command", "shift"], "count": 1, "gap_ms": 0, "mark": "cmd-shift-l",
           "title": "Cmd-Shift-L in p2: a new Chromium tab (key.openBrowser; real HID key)"}, P.rest(3.0, "the Chromium New Tab loads")]
    name = f"{JID}-still"
    s += [G.kit_record_start(name, 4.0, require_hz=120), P.rest(1.5, "the still: nothing moves"), G.kit_record_stop(name, 0.2)]
    return s + P.after_check()


def journey():
    return {"id": JID, "priority": "P1",
            "title": "m37 still: dark mode, a window picture, the cmux New Tab (Cmd-T) beside a new Chromium tab (Cmd-Shift-L)",
            "why": "RESIZE OWNER 02:1xZ (cmux-ad m37): the Chromium New Tab's page area must show the window picture like the cmux New "
                   "Tab beside it, not an opaque near-black box (#36908).",
            "source": "PIXEL PERFECT kit (video-cases/gen_m37.py)", "budget_seconds": 90, "estimate_seconds": 60,
            "recordings": [f"{JID}-still"], "options": {"key_path": "real"}, "steps": steps(),
            "finally": [{"do": "settings_file", "title": "clean-up: settings back",
                         "unset": ["appearance.background", "appearance.theme", "browser.defaultEngine", "sidebar.hoverCards"]}]}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    o = ap.parse_args()
    j = journey()
    with open(os.path.join(o.out, f"{JID}.json"), "w") as f:
        json.dump(j, f, indent=1)
    print(os.path.join(o.out, f"{JID}.json"))
