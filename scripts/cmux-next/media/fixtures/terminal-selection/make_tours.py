#!/usr/bin/env python3
"""Writes tours/terminal-selection-copy-on-select-{false,true}.json from mouse_tui.py.

A capture runs in another checkout, so a tour carries what it needs: its first typed
command writes the Ghostty config the app watches (CMUX_NEXT_GHOSTTY_CONFIG, reloaded
when it appears) and this program, packed, then runs it. Run this after changing
mouse_tui.py or the steps here.
"""
import base64
import gzip
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOURS = HERE.parents[1] / "tours"
CONFIG = "/tmp/cmux-tour-terminal-selection.ghostty"
PROGRAM = "/tmp/cmux-tour-mouse-tui.py"
TERMINAL = ["workspace", "name:Select", "screen", "current", "pane", "current", "tab", "current", "terminal", "current", "write", "--text"]


def write(title, text, wait=1.5, shot=True):
    step = {"title": title, "daemon": True, "cmux": TERMINAL + [text], "wait": wait}
    if not shot:
        step["shot"] = False
    return step


def mouse(title, keys, wait=2.0):
    params = {"action": "drag", "pane": "focused", "by_x": 320, "by_y": 0, "steps": 24}
    if keys:
        params["modifiers"] = keys
    return {"title": title, "rpc": {"method": "debug.mouse", "params": params}, "wait": wait}


def key(title, name, keys, wait=1.5):
    return {"title": title, "rpc": {"method": "debug.key", "params": {"key": name, "modifiers": keys}}, "wait": wait}


def tour(copy_on_select):
    word = "true" if copy_on_select else "false"
    packed = base64.b64encode(gzip.compress((HERE / "mouse_tui.py").read_bytes(), mtime=0)).decode()
    steps = [
        {"title": "Launch", "wait": 3},
        {"title": "New workspace", "cmux": ["workspace", "new", "--name", "Select"], "shot": False},
        {"title": "Show it", "cmux": ["workspace", "name:Select", "focus"], "wait": 2, "shot": False},
        write(f"Ghostty config: copy-on-select = {word} (the app reloads the file it watches)",
              f"printf 'copy-on-select = {word}\\n' > {CONFIG}; echo {packed} | base64 -D | gunzip > {PROGRAM}; clear\r",
              wait=2, shot=False),
        write("A full-screen program reads the mouse (DECSET 1002, SGR); the clipboard is CLEARED", f"python3 {PROGRAM}\r", wait=3),
        mouse("Plain drag: the program gets it (press, drag, release reports); the first-use hint shows", [], wait=1.0),
        write("Plain drag copied nothing: clipboard [none]", "c"),
        mouse("Option-drag: Ghostty selects text; the program's report count does not move", ["option"]),
        write(f"copy-on-select = true: the Option-drag's release copied the selection: clipboard [exact]" if copy_on_select
              else "copy-on-select = false: the Option-drag copied nothing: clipboard [none]", "c"),
        key("Cmd-C copies the selection", "c", ["cmd"]),
        write("After Cmd-C: clipboard [exact], a piece of the marker line", "c"),
        key("Cmd-V pastes into the program (bracketed paste)", "v", ["cmd"]),
        mouse("Shift-drag selects too (Ghostty's own override)", ["shift"]),
        key("Cmd-C again", "c", ["cmd"]),
        write("After Shift-drag and Cmd-C: clipboard [exact]", "c"),
    ]
    return {
        "title": f"Terminal: Option- and Shift-drag select text while a program has the mouse; Cmd-C, paste and copy-on-select = {word}",
        "env": {"CMUX_NEXT_GHOSTTY_CONFIG": CONFIG},
        "steps": steps,
    }


for copy_on_select in (False, True):
    word = "true" if copy_on_select else "false"
    (TOURS / f"terminal-selection-copy-on-select-{word}.json").write_text(json.dumps(tour(copy_on_select), indent=2) + "\n")
