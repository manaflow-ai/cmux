#!/usr/bin/env python3
"""SHORTCUT FRAMES: cases (plan.py) as journey files for scripts/journeys/run.py with the HARNESS kit's steps.

  journeys.py --cases shortcut-cases.json --out DIR [--wave 1] [--only SUBSTRING ...] [--build feat-tip]

One journey per case. Each journey: a fresh terminal workspace (the person's Ctrl-` through the key path), the
theme and animation settings, the load (none, one busy pane, 12 busy panes from the TUI kit), the context the row
needs, then the 120 Hz recording (the kit's video_start), the measured presses as REAL HID keys (the kit's real_key,
CuaDriver), each followed by its settle and its undo by the socket, then video_stop and one debug.action_budget read.

The key-down time of each press is the HID event's own time: debug.action_budget `recent` gives the run of the
pressed action with start_uptime_ns (CLOCK_UPTIME_RAW, the clock of the recorder's frames.json `t`) and input_age_ms
(the NSEvent's age at the run's start), so key-down = start_uptime_ns - input_age_ms * 1e6 (STATUS 4300).
`hid_log.py` turns a journey's result.json into the judge's --hid file.

The kit step names are in one place (KIT_*), as in the RESIZE VIDEOS suite's gen_cases.py, so they follow KIT.md.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

PRE_RECORD_S = 1.5      # the judge's --pre-ms: frames before the first press (its busy-block mask)
SETTLE_S = 1.0
REQUIRE_HZ = None       # 120 for pacing evidence (KIT.md section 2); None records at the display's rate and writes it down
TUIKIT = "${tuikit}"
LOAD_PROGRAMS = ("gradient", "sigwinch", "top", "flood", "gradient", "mouse",
                 "agent-stream", "gradient", "vim-scroll", "top", "gradient", "flood")


# -- the HARNESS kit's steps (KIT.md). One place to change. --------------------------------------------
def kit_record_start(name: str, seconds: float, require_hz: int | None = None) -> dict:
    step = {"do": "video_start", "name": name, "seconds": min(120.0, seconds), "lead": PRE_RECORD_S,
            "title": f"start the recording ({name}); its first {PRE_RECORD_S} s are the judge's frames before the press"}
    if require_hz:
        step["require_hz"] = require_hz
    return step


def kit_record_stop(name: str) -> dict:
    return {"do": "video_stop", "name": name, "tail": 0.6, "title": f"stop the recording ({name}); its files go to the result"}


def kit_key(stroke: str, mark: str) -> dict:
    key, mods = parse_stroke(stroke)
    return {"do": "hid_key", "key": key, "modifiers": mods, "mark": mark, "title": f"the measured press {stroke} ({mark})"}


# -- keys -----------------------------------------------------------------------------------------------
MOD_NAMES = {"cmd": "cmd", "shift": "shift", "opt": "option", "ctrl": "control"}


def parse_stroke(stroke: str) -> tuple[str, list[str]]:
    parts = stroke.split("+")
    if stroke.endswith("++"):
        parts = parts[:-2] + ["+"]
    return parts[-1], [MOD_NAMES[m] for m in parts[:-1]]


# -- set-up -----------------------------------------------------------------------------------------------
def wait(seconds: float, title: str) -> dict:
    return {"do": "wait", "seconds": seconds, "title": title}


def action(ident: str, **args) -> dict:
    params = {"action": ident}
    if args:
        params["args"] = args
    return {"do": "rpc", "method": "action.run", "params": params, "title": f"set-up or undo by the socket: {ident}"}


def settings(theme: str, animations: bool) -> dict:
    name = "Builtin Dark" if theme == "dark" else "Builtin Light"
    return {"do": "settings_file", "title": f"set-up: theme {name}, animations {'on' if animations else 'off'}, no close warning",
            "set": {"appearance": {"theme": name, "appTheme": "followTerminal"},
                    "app": {"warnBeforeClosingTab": False},
                    "ui": {"animations": {"enabled": animations}}}}


def load_steps(load: str) -> list[dict]:
    """Busy panes beside the focused, quiet pane p0. The press acts on p0."""
    count = {"idle": 0, "hog15g": 0, "busy1": 1, "busy12": 12}[load]
    steps: list[dict] = []
    for i in range(count):
        program = LOAD_PROGRAMS[i % len(LOAD_PROGRAMS)]
        extra = " --fps 120" if program == "gradient" else ""
        steps += [{"do": "rpc", "method": "action.run", "params": {"action": "newColumn" if i % 3 == 0 else "splitDown"},
                   "title": f"set-up: load pane {i + 1}"},
                  {"do": "focused_terminal"},
                  {"do": "type", "text": f"python3 {TUIKIT} {program} --seed {2000 + i}{extra}", "enter": True,
                   "title": f"set-up: {program} in load pane {i + 1}"}]
    if count:
        steps.append({"do": "key", "key": "1", "modifiers": ["control", "cmd"],
                      "title": "set-up: Focus Pane 1 (the quiet pane p0, first in the layout; the press acts on it)"})
        steps.append({"do": "use", "name": "p0", "title": "set-up: the driver's current terminal is p0 again"})
    return steps


def context_steps(case: dict) -> list[dict]:
    steps = []
    for s in case["setup"] if isinstance(case["setup"], list) else []:
        if "rpc" in s:
            steps.append({"do": "rpc", "method": s["rpc"], "params": s["params"], "title": f"set-up: {s['params'].get('action', s['rpc'])}"})
        elif "wait_s" in s:
            steps.append(wait(s["wait_s"], "set-up: the context settles"))
    return steps


def budget_read() -> dict:
    """The press's run (after its settle, outside the judged frames): start_uptime_ns - input_age_ms = key-down."""
    return {"do": "rpc", "method": "debug.action_budget", "params": {"limit": 16},
            "title": "the press's action run: start_uptime_ns and input_age_ms give its key-down time"}


def undo_steps(case: dict) -> list[dict]:
    effect = case["effect"]
    if effect == "new-tab":
        return [action("closeTab")]
    if effect == "new-pane":
        return [action("closePane")]
    if effect == "new-workspace":
        return [action("closeWorkspace", confirm=True)]
    if effect in ("overlay",):
        return [{"do": "key", "key": "escape", "title": "undo: Escape"}, {"do": "key", "key": "escape", "title": "undo: Escape"}]
    if effect == "chrome":
        return [action(case["action"])]
    return []


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


# Per action: steps before each press (the object the press acts on), the strokes to alternate, and steps once
# before the action's presses. Only for actions whose plain setup/undo does not give a press a fresh effect.
BEFORE_EACH = {
    "closeTab": [{"do": "rpc", "method": "action.run", "params": {"action": "newSurface"}, "title": "set-up: a tab for Cmd-W to close"},
                 {"do": "wait", "seconds": 1.0, "title": "the new tab settles"}],
    "terminal.clear": [{"do": "type", "text": "seq 1 60", "enter": True, "title": "set-up: text for Cmd-K to clear"},
                       {"do": "wait", "seconds": 0.8, "title": "the text settles"}],
}
ONCE_BEFORE = {
    "prevSurface": [{"do": "rpc", "method": "action.run", "params": {"action": "newSurface"}, "title": "set-up: a second tab"},
                    {"do": "wait", "seconds": 1.0, "title": "the tab settles"}],
    "nextSurface": [],
    "selectWorkspaceByNumber": [],
}
# Strokes to alternate (each press then switches): Cmd-1 / Cmd-2 between Home and the journey's workspace.
ALTERNATE = {"selectWorkspaceByNumber": ["cmd+1", "cmd+2"]}
NO_UNDO = {"prevSurface", "nextSurface", "selectWorkspaceByNumber", "closeTab", "terminal.clear"}


def press_block(case: dict, video: str, presses: int) -> list[dict]:
    """One recording of PRESSES presses of the case's key, each with its settle, its run read and its undo."""
    steps = [kit_record_start(video, PRE_RECORD_S + presses * 3.0 + 3, REQUIRE_HZ)]
    steps += ONCE_BEFORE.get(case["action"], [])
    strokes = ALTERNATE.get(case["action"], [case["stroke"]])
    for i in range(presses):
        steps += BEFORE_EACH.get(case["action"], [])
        stroke = strokes[i % len(strokes)]
        label = case["name"].replace(f"[{case['stroke']}]", f"[{stroke}]") + f"/{i + 1}"
        steps.append(kit_key(stroke, label))
        steps.append(wait(SETTLE_S, "settle: content that loads later fills in"))
        steps.append(budget_read())
        if case["action"] not in NO_UNDO:
            steps += undo_steps(case)
        steps.append(wait(1.0, "the undo settles before the next press"))
    steps.append(kit_record_stop(video))
    return steps


def round_journey(group: list[dict], presses: int) -> dict:
    """One lease's journey: the cases of one condition (load, theme, animations, build, arm), one recording each."""
    first = group[0]
    cond = f"{first['arm']}-{first['load']}-{first['theme']}-anim-{first['animations']}"
    jid = f"sf-{slug('-'.join(c['action'] for c in group))[:60]}-{cond}"
    # A workspace of its own (action.run newTab: New Workspace with a terminal), not Home: Home's Chief chat streams
    # and would change frames beside the press.
    steps = [{"do": "smoke_ready", "timeout": 60}, {"do": "smoke_make_key"},
             {"do": "new_terminal", "via": "socket", "name": "p0"}, {"do": "neutral_prompt"},
             settings(first["theme"], first["animations"] == "on")] + load_steps(first["load"])
    steps.append(wait(1.0, "the layout and the load settle (nothing observable to wait on)"))
    if first["arm"] == "warm":
        # ONE recording per journey (a second recording in the same app process fails: STATUS 4418), the cases one
        # after the other in it.
        video = f"sf-{cond}"
        steps.append(kit_record_start(video, min(118.0, PRE_RECORD_S + len(group) * presses * 3.2 + 4), REQUIRE_HZ))
        for case in group:
            steps += context_steps(case)
            steps += press_block(case, video, presses)[1:-1]
        steps.append(kit_record_stop(video))
    for case in group if first["arm"] != "warm" else []:
        steps += context_steps(case)
        video = f"sf-{slug(case['action'])}-{cond}"
        if False:
            pass
        else:
            for i in range(presses):
                steps.append({"do": "relaunch", "how": "quit", "title": "cold: quit and open again; the next press is the first after launch"})
                steps.append({"do": "use", "name": "p0"})
                steps += press_block(case, f"{video}-{i + 1}", 1)
    steps.append({"do": "type", "text": "echo sf-done-${nonce}", "enter": True, "mark": "done"})
    steps.append({"do": "expect", "since": "done", "timeout": 15,
                  "title": "after the presses the app still answers: the line shows in the app, the daemon and the frame",
                  "all": [{"app_text_contains": "sf-done-${nonce}"}, {"daemon_prompt": True},
                          {"pane_frame_text": "sf-done-${nonce}"}]})
    return {"id": jid, "priority": "P0",
            "title": f"SHORTCUT FRAMES: {', '.join(c['stroke'] for c in group)} ({cond}), real HID keys, recorded every frame",
            "why": "Lawrence 2026-11-02: cmd+t and cmd shift l, literally all the keyboard shortcuts, open the new tab "
                   "instantly, the frame of; videos, pixel perfect. The judge (scripts/cmux-next/shortcut-frames/judge.py) "
                   "counts display refreshes from each HID key-down to the first changed frame and checks the frames after it.",
            "source": "handoff/resize-videos/SHORTCUT-FRAMES.md (SHORTCUT FRAMES P0)",
            "budget_seconds": min(540, 60 + len(group) * presses * 4), "options": {"key_path": "real"},
            "cases": [{k: c[k] for k in ("name", "stroke", "action", "effect", "context", "arm", "load", "theme",
                                        "animations", "build")} for c in group],
            "steps": steps}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--cases", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--wave", type=int, action="append")
    p.add_argument("--only", action="append", default=[], help="a substring of the case name (repeatable)")
    p.add_argument("--build", default="feat-tip", help="the plan's build label; journeys do not depend on it")
    p.add_argument("--presses", type=int, default=10)
    p.add_argument("--group", action="append", default=[],
                   help="comma-separated action ids that share one journey (repeatable); default: one journey per condition")
    a = p.parse_args()
    cases = json.load(open(a.cases, encoding="utf-8"))["cases"]
    os.makedirs(a.out, exist_ok=True)
    groups: dict[tuple, list[dict]] = {}
    skipped = 0
    for case in cases:
        if a.wave and case["wave"] not in a.wave:
            continue
        if case["build"] != a.build:
            continue
        if a.only and not any(s in case["name"] for s in a.only):
            continue
        if case["setup"] == "todo":
            skipped += 1
            continue
        if a.group:
            names = [i for i, g in enumerate(a.group) if case["action"] in g.split(",")]
            if not names:
                continue
            if case["action"] in ALTERNATE and case["stroke"] != ALTERNATE[case["action"]][0]:
                continue  # one case for the family: its presses alternate the strokes
            key = (names[0], case["arm"], case["load"], case["theme"], case["animations"])
        else:
            key = (case["arm"], case["load"], case["theme"], case["animations"])
        groups.setdefault(key, []).append(case)
    ids = []
    for group in groups.values():
        j = round_journey(group, a.presses)
        with open(os.path.join(a.out, j["id"] + ".json"), "w", encoding="utf-8") as f:
            json.dump(j, f, indent=1)
            f.write("\n")
        ids.append(j["id"])
    print(json.dumps({"journeys": ids, "skipped_setup_todo": skipped, "out": a.out}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
