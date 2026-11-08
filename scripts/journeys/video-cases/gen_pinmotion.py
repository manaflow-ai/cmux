#!/usr/bin/env python3
"""PIN MOTION films (cmux-ad m70, task pin-motion): pin and unpin of a sidebar workspace row and of a tab in a pane's tab
strip, each from a REAL HID key (ext_pinmotion pm_keys). Workspace pin has no default key: the film's own settings bind
Pin/Unpin Workspace (palette.toggleWorkspacePin, the action the row menu, the palette and the hover pin run) to
Ctrl-Opt-Cmd-P for the run (settings_back-style clean-up removes it). Tab pin is its default key Opt-Cmd-P.

Cases: SB-PIN (sidebar row 6 to the pinned group), SB-UNPIN (back), TAB-PIN (4th tab of 6), TAB-UNPIN, RAPID
(pin-unpin-pin on the row, 90 ms apart), GRP (pin a row below a collapsed group). One journey = one pass (VIEW: dark,
MEASURE: fixture colours) and one curve of the film selector (`debug.frames` action `pin_curve <K>`; V0 has none).

  gen_pinmotion.py --prefix p0 --curves V0 [--passes view,meas]
  gen_pinmotion.py --prefix p1 --curves K2,K6,K12
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cases as G  # noqa: E402
import gen_pixel as X  # noqa: E402
import gen_closelayouts as CL  # noqa: E402
from gen_closecurves import VIEW_SETTINGS  # noqa: E402

WS_KEY = {"key": "p", "modifiers": ["control", "option", "cmd"]}
TAB_KEY = {"key": "p", "modifiers": ["option", "cmd"]}
BIND = {"do": "settings_file", "title": "set-up: bind Pin/Unpin Workspace to Ctrl-Opt-Cmd-P for the film (no default key)",
        "set": {"shortcuts": {"bindings": {"palette.toggleWorkspacePin": "ctrl+opt+cmd+p"}}}}
UNBIND = {"do": "settings_file", "title": "clean-up: the film's workspace pin key off", "unset": ["shortcuts.bindings"]}
LABELS = {"V0": "current", "CUR": "current curve", "K2": "ease-out 100 ms", "K6": "critically damped 0.15 s",
          "K12": "critically damped 0.2 s"}
# K6 is the shipped .move (response 0.15, damping 1): None keeps the default. K2 (ease-out 100 ms) is a bezier, which
# the spring tunable cannot express: not filmed.
CURVES = {"CUR": None, "K6": None, "K12": {"response": 0.2, "dampingFraction": 1.0}}
CASES = {"SB-PIN": "sidebar row 6 to the pinned group", "SB-UNPIN": "the row back out of the pinned group",
         "TAB-PIN": "4th tab of 6 pinned", "TAB-UNPIN": "the tab unpinned", "RAPID": "pin, unpin, pin 90 ms apart",
         "GRP": "pin a row below a collapsed group"}


def ws(name, label):
    return [{"do": "action", "action": "workspace.newAtBottom", "title": f"set-up: a new workspace ({label})"},
            {"do": "adopt_pane", "as": name}, {"do": "neutral_prompt"},
            {"do": "try_action", "action": "renameWorkspace", "args": {"name": label}, "title": f"set-up: name it {label}"}]


def pin_now(name):
    return [X.focus(name), {"do": "action", "action": "palette.toggleWorkspacePin", "args": {"pinned": True},
                            "title": f"set-up: pin {name} (the pinned group exists before the films)"}]


def film(name, i, keys, probe, focus=None, pre=()):
    steps = [G.settle(0.6)]
    if focus:
        steps += [X.focus(focus), G.settle(0.6)]
    steps += list(pre)
    steps += [{"do": "video_start", "name": name, "seconds": 3.0, "mbps": 24, "rows": [], "columns": [], "require_hz": 120,
               "lead": 0.6, "title": f"start the 120 Hz movie {name}"},
              G.settle(0.2),
              {"do": "pm_keys", "film": name, "i": i, "keys": keys, "probe": probe, "rest": 1.1, "title": f"pin key(s) ({name})"},
              G.kit_record_stop(name, 0.2)]
    return steps


def journey(jid, prefix, curve, view):
    p = "v" if view else "m"
    check = [{"do": "type", "text": "echo pm-ready-${nonce}", "enter": True, "mark": "ready"},
             {"do": "expect", "title": "set-up check: the app types", "since": "ready", "timeout": 10,
              "all": [{"daemon_line": "pm-ready-${nonce}"}, {"app_text_line": "pm-ready-${nonce}"}, {"frame_text": "pm-ready-${nonce}"}]}]
    steps = G.first_pane(jid, False) + check + [VIEW_SETTINGS if view else X.fixture_settings(), BIND]
    if curve in CURVES:
        # The rows' and the flight's one spring is `.move` (motion.spring.move): the curve under test is that tunable.
        steps.append({"do": "px_tunable", "key": "motion.spring.move", "value": CURVES[curve], "required": True,
                      "title": f"pin curve: {curve} ({LABELS.get(curve, curve)})"})
    # Rows: p0 (first_pane), w1..w6, a group of two (collapsed), w7. p0 and w1 are pinned first: the pinned group.
    steps += [{"do": "try_action", "action": "renameWorkspace", "args": {"name": "alpha"}, "title": "set-up: name p0 alpha"}]
    names = ["bravo", "charlie", "delta", "echo", "foxtrot", "golf"]
    for n, label in enumerate(names, 1):
        steps += ws(f"w{n}", label)
    steps += [{"do": "action", "action": "workspace.newInNewGroup", "args": {"name": "group"}, "title": "set-up: a group"},
              {"do": "adopt_pane", "as": "g1"}, {"do": "neutral_prompt"},
              {"do": "try_action", "action": "renameWorkspace", "args": {"name": "hotel"}, "title": "set-up: name it hotel"},
              {"do": "action", "action": "workspaceGroup.newWorkspace", "title": "set-up: a second workspace in the group"},
              {"do": "adopt_pane", "as": "g2"}, {"do": "neutral_prompt"},
              {"do": "try_action", "action": "renameWorkspace", "args": {"name": "india"}, "title": "set-up: name it india"}]
    steps += ws("w7", "juliet")
    steps += [{"do": "try_action", "action": "workspaceGroup.collapseAll", "title": "set-up: the group collapsed"}]
    steps += pin_now("p0") + pin_now("w1")
    # Tabs: six terminal tabs in w6's pane (golf), the 1st pinned, the 4th selected.
    for _ in range(5):
        steps += X.new_tab("w6")
    films, index = [], []

    def add(case, i, keys, probe, focus=None, pre=()):
        name = f"pm-{p}-{prefix}-{case.lower()}-{curve.lower()}"
        films.extend(film(name, i, keys, probe, focus, pre))
        index.append({"film": name, "case": case, "curve_id": curve, "prefix": prefix, "journey": jid,
                      "label": f"{prefix} {case} {LABELS.get(curve, curve)} | {CASES[case]}"})

    # Row 6 from the top: alpha, bravo (pinned), then the list: (Home), charlie, delta, echo ... the film notes the order.
    add("SB-PIN", 0, [WS_KEY], "sidebar", focus="w5")
    add("SB-UNPIN", 1, [WS_KEY], "sidebar", focus="w5")
    add("RAPID", 2, [WS_KEY, dict(WS_KEY, gap=0.09), dict(WS_KEY, gap=0.09)], "sidebar", focus="w4")
    add("GRP", 3, [WS_KEY], "sidebar", focus="w7")
    pre_tab = [{"do": "hid_key", "key": "1", "modifiers": ["control"], "title": "set-up: tab 1"},
               {"do": "hid_key", "key": "p", "modifiers": ["option", "cmd"], "title": "set-up: pin tab 1 (the pinned group)"},
               G.settle(0.6),
               {"do": "hid_key", "key": "4", "modifiers": ["control"], "title": "set-up: select the 4th tab (Ctrl-4)"}]
    add("TAB-PIN", 4, [TAB_KEY], "tabs", focus="w6", pre=pre_tab)
    add("TAB-UNPIN", 5, [TAB_KEY], "tabs")
    steps += films
    spec = {"id": jid, "priority": "P1", "title": f"PIN MOTION {prefix} {curve} {'VIEW' if view else 'MEASURE'}: "
                                                  + ", ".join(CASES),
            "why": "cmux-ad m70 (Lawrence 2026-11-08): pin and unpin must translate from the old position to the new slot.",
            "source": "pin-motion task kit (video-cases/gen_pinmotion.py)", "budget_seconds": 250,
            "recordings": [f["film"] for f in index], "options": {"key_path": "real"}, "steps": steps,
            "finally": [UNBIND, X.settings_back()]
            + ([{"do": "px_tunable", "key": "motion.spring.move", "value": None, "title": "clean-up: .move back to its default"}]
               if curve in CURVES else [])}
    return spec, index


def prof_journey(jid, runs):
    """Step 3 (pin-motion-4): RUNS pin/unpin keys on w5 under one time profile (ext_pmprof), fixture colours, K6."""
    check = [{"do": "type", "text": "echo pm-ready-${nonce}", "enter": True, "mark": "ready"},
             {"do": "expect", "title": "set-up check: the app types", "since": "ready", "timeout": 10,
              "all": [{"daemon_line": "pm-ready-${nonce}"}, {"app_text_line": "pm-ready-${nonce}"}, {"frame_text": "pm-ready-${nonce}"}]}]
    steps = G.first_pane(jid, False) + check + [X.fixture_settings(), BIND]
    steps += [{"do": "try_action", "action": "renameWorkspace", "args": {"name": "alpha"}, "title": "set-up: name p0 alpha"}]
    for n, label in enumerate(["bravo", "charlie", "delta", "echo", "foxtrot", "golf"], 1):
        steps += ws(f"w{n}", label)
    steps += pin_now("p0") + pin_now("w1")
    steps += [G.settle(0.6), X.focus("w5"), G.settle(1.0),
              {"do": "pm_xctrace_pins", "runs": runs, "gap": 1.0, "rest": 0.6, "window_ms": 150, "key": WS_KEY,
               "title": f"{runs} pin/unpin keys of w5 under one time profile"}]
    return {"id": jid, "priority": "P1", "title": f"PIN MOTION profile: {runs} sidebar pin/unpin keys under xctrace",
            "why": "pin-motion-4 step 3: name the work behind 1-2 missed refreshes per pin at 120 Hz.",
            "source": "pin-motion task kit (video-cases/gen_pinmotion.py --prof)", "budget_seconds": 400,
            "recordings": [], "options": {"key_path": "real"}, "steps": steps, "finally": [UNBIND, X.settings_back()]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prof", type=int, default=0, help="write pm-prof (this many pin keys under xctrace) and stop")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    ap.add_argument("--prefix", default="p0")
    ap.add_argument("--curves", default="V0")
    ap.add_argument("--passes", default="view,meas")
    ap.add_argument("--films-dir", default="/work/wt/close-perf-tools/pin")
    o = ap.parse_args()
    if o.prof:
        with open(os.path.join(o.out, "pm-prof.json"), "w") as fh:
            json.dump(prof_journey("pm-prof", o.prof), fh, indent=1)
            fh.write("\n")
        print("pm-prof", o.prof)
        return
    os.makedirs(o.films_dir, exist_ok=True)
    for kind in o.passes.split(","):
        idx_all = []
        for curve in o.curves.split(","):
            jid = f"pm-{o.prefix}-{curve.lower()}-{kind}"
            spec, idx = journey(jid, o.prefix, curve, kind == "view")
            with open(os.path.join(o.out, f"{jid}.json"), "w") as fh:
                json.dump(spec, fh, indent=1)
                fh.write("\n")
            idx_all += idx
            print(jid, len(spec["steps"]), len(spec["recordings"]))
        with open(os.path.join(o.films_dir, f"pm-{o.prefix}-{kind}.films.json"), "w") as fh:
            json.dump(idx_all, fh, indent=1)


if __name__ == "__main__":
    main()
