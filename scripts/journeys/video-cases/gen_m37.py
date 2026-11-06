#!/usr/bin/env python3
"""gen_m37.py [--out DIR]: cmux-ad m37 (the black Chromium New Tab, #36908; RESIZE OWNER 02:1xZ). One journey,
px-m37-newtab-still: dark mode (theme Builtin Dark, app theme from the terminal), a window picture (appearance.background, a
public-domain painting), two panes side by side: p1 shows the cmux New Tab (a real Cmd-T), p0 a new Chromium tab from a real
Cmd-Shift-L (key.openBrowser; browser.defaultEngine chromium). With #36908 the Chromium New Tab's page area shows the window
picture through it, as the cmux New Tab beside it does; without it the page area is an opaque near-black box. A short whole-window
recording at 120 Hz after both pages settle; the still is a frame of it (each pane's area is read in the gallery).

The variants (RESIZE OWNER 2026-11-06, cmux-ad m37: which layer paints the box): the same journey with Debug tunables set (ext_pixel
px_tunable, required) once the app is ready, before any Chromium page exists, and reset in the journey's finally:
  px-m37-v2-nohost   no layer hosting: browserResize.layerHosting AND motion.frameOwner.pages off. The app hosts a page
                     in its window's layers when either is on (CEFHostingSwitch.hostingWanted), and motion.frameOwner.pages
                     is on by default, so browserResize.layerHosting off alone leaves every page hosted.
  px-m37-v3-nospare  no spare page: browserPage.sparePage off (no page made ahead; the new tab takes none).
  px-m37-v4-both     both.
At the still (after video_stop, before the clean-up) each variant keeps the app's own reads: debug.layers and debug.cef
whole (px_keep: diag-layers.json, diag-cef.json), the browserResize and browserPage tunables as the app has them
(diag-tunresize.json, diag-tunpage.json) and one capture of each app window alone (px_window_shots: screencapture -l,
diag-win<letters>.png with the table diag-win.json)."""
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
HOSTING_OFF = (("browserResize.layerHosting", False), ("motion.frameOwner.pages", False))
SPARE_OFF = (("browserPage.sparePage", False),)
# id: (what the variant turns off, its tunables)
VARIANTS = {"px-m37-v2-nohost": ("no layer hosting", HOSTING_OFF),
            "px-m37-v3-nospare": ("no spare page", SPARE_OFF),
            "px-m37-v4-both": ("no layer hosting and no spare page", HOSTING_OFF + SPARE_OFF)}


def settings():
    return {"do": "settings_file", "title": f"set-up: dark mode (Builtin Dark, app theme from the terminal), window picture "
            f"{PAINTING}, Chromium as the default browser engine, no close warning, no hover cards",
            "set": {"sidebar": {"hoverCards": {"enabled": False}},
                    "appearance": {"theme": "Builtin Dark", "appTheme": "followTerminal", "background": PAINTING},
                    "browser": {"defaultEngine": "chromium"},
                    "app": {"warnBeforeClosingTab": False}}}


def tunables_set(tunables):
    return [{"do": "px_tunable", "key": key, "value": value, "required": True,
             "title": f"set-up: {key} = {json.dumps(value)} before any Chromium page (required)"} for key, value in tunables]


def at_still():
    """The app's own reads at the still, after the recording: never a failure (px_keep, px_window_shots)."""
    return [{"do": "px_keep", "method": "debug.layers", "name": "layers", "title": "the still: debug.layers whole (diag-layers.json)"},
            {"do": "px_keep", "method": "debug.cef", "name": "cef", "title": "the still: debug.cef whole (diag-cef.json)"},
            {"do": "px_keep", "method": "debug.tunables", "params": {"action": "list", "section": "browserResize"}, "name": "tunresize",
             "title": "the still: the browserResize tunables as the app has them (diag-tunresize.json)"},
            {"do": "px_keep", "method": "debug.tunables", "params": {"action": "list", "section": "browserPage"}, "name": "tunpage",
             "title": "the still: the browserPage tunables as the app has them (diag-tunpage.json)"},
            {"do": "px_window_shots", "name": "win",
             "title": "the still: each app window alone (screencapture -l; diag-win<letters>.png, table diag-win.json)"}]


def steps(jid=JID, tunables=()):
    s = [settings()] + G.first_pane(jid, False)
    if tunables:
        assert s[1]["do"] == "smoke_ready", s[1]
        s[2:2] = tunables_set(tunables)  # once the app is ready, before any Chromium page
    s += P.new_pane("p1", "splitRight")
    s += [P.focus("p1"), P.rest(0.4, "focus settles"),
          {"do": "rk_press", "key": "t", "modifiers": ["command"], "count": 1, "gap_ms": 0, "mark": "cmd-t",
           "title": "Cmd-T in p1: the cmux New Tab (real HID key)"}, P.rest(1.5, "the cmux New Tab shows")]
    s += [P.focus("p0"), P.rest(0.4, "focus settles"),
          {"do": "rk_press", "key": "l", "modifiers": ["command", "shift"], "count": 1, "gap_ms": 0, "mark": "cmd-shift-l",
           "title": "Cmd-Shift-L in p0: a new Chromium tab (key.openBrowser; real HID key)"}, P.rest(3.0, "the Chromium New Tab loads")]
    name = f"{jid}-still"
    s += [G.kit_record_start(name, 4.0, require_hz=120), P.rest(1.5, "the still: nothing moves"), G.kit_record_stop(name, 0.2)]
    if tunables:
        s += at_still()
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


def variant(jid):
    what, tunables = VARIANTS[jid]
    base = journey()
    keys = ", ".join(f"{k} {json.dumps(v)}" for k, v in tunables)
    return dict(base, id=jid, title=f"m37 still, {what} ({keys}): the cmux New Tab (Cmd-T) beside a new Chromium tab (Cmd-Shift-L)",
                why=f"RESIZE OWNER 2026-11-06 (cmux-ad m37): which layer paints the Chromium New Tab's opaque box: {jid[len('px-m37-'):]} is "
                    f"{JID} with {keys} set before any Chromium page, the app's debug.layers, debug.cef and tunables kept at the "
                    "still and each app window captured alone.",
                estimate_seconds=65, recordings=[f"{jid}-still"], steps=steps(jid, tunables),
                **{"finally": [{"do": "px_tunable", "key": key, "value": None, "title": f"clean-up: {key} back to its default"}
                               for key, _ in tunables] + base["finally"]})


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    o = ap.parse_args()
    for j in [journey()] + [variant(v) for v in VARIANTS]:
        with open(os.path.join(o.out, f"{j['id']}.json"), "w") as f:
            json.dump(j, f, indent=1)
        print(os.path.join(o.out, f"{j['id']}.json"))
