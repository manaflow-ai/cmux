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
TUIKIT = "${tuikit}"
LOAD_PROGRAMS = ("gradient", "sigwinch", "top", "flood", "gradient", "mouse",
                 "agent-stream", "gradient", "vim-scroll", "top", "gradient", "flood")


# -- the HARNESS kit's steps (KIT.md). One place to change. --------------------------------------------
def kit_record_start(name: str, seconds: float) -> dict:
    return {"do": "video_start", "name": name, "seconds": seconds, "trace": True,
            "title": f"start the 120 Hz recording ({name})"}


def kit_record_stop(name: str) -> dict:
    return {"do": "video_stop", "name": name, "title": f"stop the recording ({name}); its files go to the result"}


def kit_key(stroke: str, mark: str) -> dict:
    key, mods = parse_stroke(stroke)
    return {"do": "real_key", "key": key, "modifiers": mods, "mark": mark, "title": f"the measured press {stroke} ({mark})"}


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
        steps.append({"do": "use", "name": "p0", "title": "set-up: back to the quiet pane p0"})
        steps.append({"do": "rpc", "method": "debug.focus_terminal", "params": {"name": "p0"},
                      "title": "set-up: focus p0 (the press acts on it)"})
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


def journey(case: dict) -> dict:
    slug = re.sub(r"[^a-z0-9]+", "-", case["name"].lower()).strip("-")
    jid = f"sf-{slug}"[:120]
    animations = case["animations"] == "on"
    steps = [{"do": "new_terminal", "via": "key", "name": "p0"}, {"do": "neutral_prompt"},
             settings(case["theme"], animations)] + load_steps(case["load"]) + context_steps(case)
    steps.append(wait(1.0, "the layout and the load settle (nothing observable to wait on)"))
    presses = 20 if case["arm"] == "warm" else 5
    per_press = 1.0 + 1.0 + 0.5
    if case["arm"] == "warm":
        steps.append(kit_record_start(jid, PRE_RECORD_S + presses * per_press + 5))
        steps.append(wait(PRE_RECORD_S, "frames before the first press (the judge's mask of busy blocks)"))
        for i in range(presses):
            steps.append(kit_key(case["stroke"], f"{case['name']}/{i + 1}"))
            steps.append(wait(1.0, "settle: content that loads later fills in"))
            steps.append(budget_read())
            steps += undo_steps(case)
            steps.append(wait(1.0, "the undo settles before the next press"))
        steps.append(kit_record_stop(jid))
    else:
        for i in range(presses):
            steps.append({"do": "relaunch", "how": "quit", "title": "cold: quit and open again; the next press is the first after launch"})
            steps.append({"do": "use", "name": "p0"})
            steps.append(kit_record_start(f"{jid}-{i + 1}", PRE_RECORD_S + 6))
            steps.append(wait(PRE_RECORD_S, "frames before the press"))
            steps.append(kit_key(case["stroke"], f"{case['name']}/{i + 1}"))
            steps.append(wait(1.5, "settle"))
            steps.append(budget_read())
            steps.append(kit_record_stop(f"{jid}-{i + 1}"))
            steps += undo_steps(case)
    steps.append({"do": "expect", "all": [{"app_prompt": True}, {"daemon_prompt": True}, {"frame_text": "J>"}],
                  "timeout": 10, "title": "the quiet pane p0 is back with its prompt (the journey's own evidence; the "
                                          "frames are judged by judge.py)"})
    return {"id": jid, "priority": "P1", "title": f"SHORTCUT FRAMES {case['name']}", "suite": "shortcut-frames",
            "case": {k: case[k] for k in ("name", "stroke", "action", "effect", "context", "arm", "load", "theme",
                                         "animations", "build")},
            "judge": case["judge"], "run_args": ["--hog-swap-gb", "15"] if case["load"] == "hog15g" else [],
            "budget_seconds": 600, "steps": steps}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--cases", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--wave", type=int, action="append")
    p.add_argument("--only", action="append", default=[])
    p.add_argument("--build")
    a = p.parse_args()
    cases = json.load(open(a.cases, encoding="utf-8"))["cases"]
    os.makedirs(a.out, exist_ok=True)
    n = skipped = 0
    for case in cases:
        if a.wave and case["wave"] not in a.wave:
            continue
        if a.build and case["build"] != a.build:
            continue
        if a.only and not any(s in case["name"] for s in a.only):
            continue
        if case["setup"] == "todo":
            skipped += 1
            continue
        j = journey(case)
        with open(os.path.join(a.out, j["id"] + ".json"), "w", encoding="utf-8") as f:
            json.dump(j, f, indent=1)
        n += 1
    print(json.dumps({"journeys": n, "skipped_setup_todo": skipped, "out": a.out}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
