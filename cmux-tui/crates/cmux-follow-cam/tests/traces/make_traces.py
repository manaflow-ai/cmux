"""Writes the synthetic follow-camera traces in this folder.

Run: python3 make_traces.py OUT_DIR
"""

import json
import sys
from pathlib import Path


def ev(t, kind, **fields):
    return {"t_us": int(t), "kind": kind, **fields}


def write(out, name, events):
    events.sort(key=lambda e: e["t_us"])
    (out / name).write_text("".join(json.dumps(e) + "\n" for e in events))


def caret(t, x, y):
    return ev(t, "caret", x=x, y=y, w=9, h=18)


def main(out):
    # Typing along one terminal line: every caret move stays in the dead zone.
    e = [ev(0, "window", id=1, x=100, y=80, w=2000, h=1200), ev(0, "pointer", x=1500, y=900), caret(50_000, 1000, 600)]
    for i in range(1, 26):
        t = 50_000 + i * 120_000
        x = 1000 + 9 * i
        e += [caret(t, x, 600), ev(t + 2_000, "damage", x=x - 9, y=600, w=18, h=18)]
    write(out, "terminal_typing.jsonl", e)

    # Typing in window 1, then a switch to window 2 far to the right.
    e = [ev(0, "window", id=1, x=100, y=80, w=1200, h=1200), caret(50_000, 600, 500)]
    e += [caret(50_000 + i * 120_000, 600 + 9 * i, 500) for i in range(1, 8)]
    e.append(ev(1_000_000, "window", id=2, x=1600, y=150, w=900, h=1100))
    e.append(caret(1_060_000, 1900, 400))
    e += [caret(1_060_000 + i * 120_000, 1900 + 9 * i, 400) for i in range(1, 8)]
    write(out, "window_switch.jsonl", e)

    # One window; the caret jumps to a far pane (a click), then types there.
    e = [ev(0, "window", id=1, x=0, y=0, w=2560, h=1440), caret(50_000, 500, 700)]
    e += [caret(50_000 + i * 120_000, 500 + 9 * i, 700) for i in range(1, 8)]
    e.append(caret(1_000_000, 2000, 700))
    e += [caret(1_000_000 + i * 120_000, 2000 + 9 * i, 700) for i in range(1, 10)]
    write(out, "far_jump.jsonl", e)

    # No caret, no pointer: an agent's output scrolling in one region, and
    # one full-screen redraw that must not move the camera.
    e = [ev(0, "window", id=1, x=0, y=0, w=2560, h=1440)]
    e += [ev(i * 100_000, "damage", x=1800, y=300 + 4 * (i % 5), w=100, h=40) for i in range(3, 30)]
    e.append(ev(400_000, "damage", x=0, y=0, w=2560, h=1440))
    write(out, "damage_only.jsonl", e)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
