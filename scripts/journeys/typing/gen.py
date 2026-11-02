#!/usr/bin/env python3
"""Writes the typing key-to-photon journeys (VIDEO EXTRA item 1) into journeys/video/typing-*.json.

    python3 scripts/journeys/typing/gen.py [--check]

Each journey makes its target (a terminal, the browser address bar, a New Agent Chat composer), starts the HARNESS
recorder (ext_video video_start), types 60 real HID keys at a person's pace (ext_typing typing_keys: 90-210 ms apart,
fixed seed, each key's post time on the recorder's host clock), and stops it. typing/judge.py then counts the display
refreshes from each key to the first frame that shows its glyph. Run with video-go.py (whole host, --vdisplay 120x1).
"""
import argparse
import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "journeys" / "video"
HEAD = [{"do": "smoke_ready", "timeout": 60}, {"do": "smoke_remember_workspaces"}, {"do": "smoke_make_key"}]
FINALLY = [{"do": "video_close_open", "title": "stop a recording a failed step left open"}, {"do": "smoke_close_all"}]
KEYS = {"count": 60, "seed": 1, "gap_ms": [90, 210], "charset": "abcdefghijklmnopqrstuvwxyz"}


def terminal_setup():
    return [{"do": "smoke_key", "key": "n", "modifiers": ["cmd"], "mark": "ws"},
            {"do": "expect", "title": "set-up: Cmd-N makes a workspace", "since": "ws", "timeout": 20,
             "all": [{"smoke_workspaces": {"new": 1}}, {"smoke_frame": {}}]},
            {"do": "smoke_key", "key": "`", "modifiers": ["control"], "mark": "term"},
            {"do": "outwait_hold"},
            {"do": "smoke_type", "text": "echo ready-${nonce}", "enter": True},
            {"do": "expect", "title": "set-up: the terminal runs its line", "since": "term", "timeout": 30,
             "all": [{"smoke_daemon_lines": {"lines": ["ready-${nonce}"]}}, {"frame_screen": {"shows": ["ready-${nonce}"]}}]},
            {"do": "smoke_adopt_line", "line": "ready-${nonce}", "as": "typed"},
            {"do": "smoke_key", "key": "k", "modifiers": ["cmd"]},
            {"do": "wait", "seconds": 0.8}]


def address_bar_setup():
    # The terminal first (daemon evidence and the same workspace), then a browser tab whose address bar has the keys.
    return terminal_setup()[:-2] + [
            {"do": "smoke_key", "key": "l", "modifiers": ["cmd", "shift"], "mark": "browser"},
            {"do": "expect", "title": "set-up: Cmd-Shift-L opens a browser tab whose address bar takes the keys",
             "since": "browser", "timeout": 15,
             "all": [{"app_rpc": {"method": "debug.focus", "path": "windows.0.model.resolved", "equals": "addressBar"}},
                     {"smoke_frame": {}}]},
            {"do": "wait", "seconds": 0.8}]


def composer_setup():
    return terminal_setup()[:-2] + [
            {"do": "smoke_key", "key": "i", "modifiers": ["cmd"], "mark": "agent"},
            {"do": "expect", "title": "set-up: Cmd-I opens a New Agent Chat pane (its frame kept)", "since": "agent",
             "timeout": 20, "all": [{"smoke_frame": {}}]},
            {"do": "rpc", "method": "debug.focus", "title": "set-up: what has the keyboard (records only)"},
            {"do": "wait", "seconds": 1.5}]


def journey(ident, title, setup, target, prime="", count=60):
    name = ident
    steps = HEAD + setup + [
        {"do": "typing_rect", "target": target},
        {"do": "video_start", "name": name, "seconds": 40},
        {"do": "typing_keys", "label": name, "target": target, "prime": prime, **dict(KEYS, count=count)},
        {"do": "video_stop", "name": name, "tail": 0.8},
        {"do": "rpc", "method": "debug.focus", "title": "after the keys: what has the keyboard (records only)"},
    ]
    return {"id": ident, "priority": "P1", "title": title,
            "why": "VIDEO EXTRA item 1 (lead 2026-11-02 00:29Z): key-to-photon of a typed character, in display "
                   "refreshes, judged from the real app's screen video (typing/judge.py)",
            "source": "VIDEO EXTRA (STATUS 4271)", "budget_seconds": 150, "options": {"key_path": "real"},
            "continue_not_judged": True, "finally": FINALLY, "steps": steps}


def cases():
    return [
        journey("typing-terminal-idle", "Typing: 60 real keys into a terminal at its prompt (idle app), filmed",
                terminal_setup(), "terminal", prime="x"),
        journey("typing-address-bar-idle", "Typing: 60 real keys into the browser address bar (idle app), filmed",
                address_bar_setup(), "address_bar", prime="x", count=40),
        journey("typing-composer-idle", "Typing: 60 real keys into a New Agent Chat composer (idle app), filmed",
                composer_setup(), "composer", prime="x"),
    ]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true")
    opts = ap.parse_args()
    bad = 0
    OUT.mkdir(parents=True, exist_ok=True)
    for spec in cases():
        path = OUT / f"{spec['id']}.json"
        text = json.dumps(spec, indent=2, ensure_ascii=False) + "\n"
        if opts.check:
            if not path.is_file() or path.read_text() != text:
                print(f"differs: {path}")
                bad = 1
            continue
        path.write_text(text)
        print(f"wrote {path} ({len(spec['steps'])} steps)")
    return bad


if __name__ == "__main__":
    sys.exit(main())
