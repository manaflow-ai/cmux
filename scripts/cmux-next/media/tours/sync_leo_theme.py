#!/usr/bin/env python3
"""Write the capture tour leo-theme.json from examples/customize/leo/*.json.

The capture ships no examples/ folder, so the tour types each profile into the Tour
terminal (base64) before it uses it. Run it after changing a variant:

    python3 scripts/cmux-next/media/tours/sync_leo_theme.py
"""
from __future__ import annotations

import base64
import json
import pathlib

repo = pathlib.Path(__file__).resolve().parents[4]
leo = repo / "examples/customize/leo"
TARGET = ["workspace", "name:Tour", "screen", "current", "pane", "current",
          "tab", "current", "terminal", "current", "write", "--text"]
PALETTE = ("clear; for i in 0 1 2 3 4 5 6 7; do printf '\\033[4%sm      ' $i; done; printf '\\033[0m\\n'; "
           "for i in 0 1 2 3 4 5 6 7; do printf '\\033[10%sm      ' $i; done; printf '\\033[0m\\n\\n'; "
           "printf '\\033[32msuccess\\033[0m  \\033[33mwarning\\033[0m  \\033[31mdanger\\033[0m  "
           "\\033[34mhighlight\\033[0m  \\033[35mmagenta\\033[0m  \\033[36mcyan\\033[0m\\n\\n'")
VARIANTS = ["dusk", "daylight", "neon"]


def path(variant: str) -> str:
    # $LEO_DIR is a `mktemp -d` folder the tour makes in the Tour terminal: no shared-temp names.
    return f'"$LEO_DIR/{variant}.json"'


steps = [
    {"title": "Launch", "wait": 2, "shot": False},
    {"title": "New workspace", "cmux": ["workspace", "new", "--name", "Tour"], "shot": False},
    {"title": "Show the Tour workspace", "cmux": ["workspace", "name:Tour", "focus"], "shot": False},
    {"title": "Make a private folder for the profiles", "daemon": True,
     "cmux": TARGET + ['clear; LEO_DIR="$(mktemp -d)" && echo made "$LEO_DIR"\r'], "wait": 2, "shot": False},
]
for v in VARIANTS:
    b64 = base64.b64encode((leo / f"{v}.json").read_bytes()).decode()
    steps.append({"title": f"Copy {v}.json to the capture Mac", "daemon": True,
                  "cmux": TARGET + [f"clear; echo {b64} | base64 -d > {path(v)} && echo saved {v}\r"],
                  "wait": 2, "shot": False})
steps.append({"title": "Before: cmux as it ships", "daemon": True, "cmux": TARGET + [PALETTE + "\r"], "wait": 2})
steps.append({"title": "dusk: cmux customize use dusk.json", "daemon": True,
              "cmux": TARGET + [PALETTE + f"; cmux customize use {path('dusk')} | head -n 1\r"], "wait": 4})
for v in VARIANTS[1:]:
    steps.append({"title": f"{v}: cmux customize discard, then use {v}.json", "daemon": True,
                  "cmux": TARGET + [PALETTE + f"; cmux customize discard >/dev/null; cmux customize use {path(v)} | head -n 1\r"],
                  "wait": 4})
steps.append({"title": "Off again: cmux customize discard", "daemon": True,
              "cmux": TARGET + [PALETTE + "; cmux customize discard | head -n 1\r"], "wait": 3})
tour = {"title": "The Leo look: dusk, daylight and neon, on and off live", "customize": True, "steps": steps}
out = repo / "scripts/cmux-next/media/tours/leo-theme.json"
out.write_text(json.dumps(tour, indent=2) + "\n")
print(out, out.stat().st_size)
