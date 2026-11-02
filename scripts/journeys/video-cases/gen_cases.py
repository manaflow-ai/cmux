#!/usr/bin/env python3
"""RESIZE VIDEOS suite: the layout-animation cases as journey files (one per case and variant).

  gen_cases.py --out DIR [--only CASE ...]     writes DIR/<id>.json for scripts/journeys/run.py
  gen_cases.py --list                          id and title of every case

Each case: a fresh workspace, the layout built with the app's own actions, the load started in every
pane (the TUI kit's programs, typed into the pane as a person would), the theme set, then the motion
under test played while the HARNESS kit records the window (120 Hz movie + per-frame geometry trace).
The judge reads the movie and the trace afterwards (KIT.md); this file only says what to play.

The kit step names (KIT_*) are in one place below, so they follow KIT.md when it is posted.
"""
import argparse
import json
import os
import sys

# -- the HARNESS kit's steps (KIT.md). One place to change. --------------------------------------------
def kit_record_start(name, seconds):
    return {"do": "video_start", "name": name, "seconds": seconds, "trace": True,
            "title": f"start the 120 Hz recording and the geometry trace ({name})"}


def kit_record_stop(name):
    return {"do": "video_stop", "name": name, "title": f"stop the recording ({name}); its files go to the result"}


def kit_key(key, mods, mark, title):
    # A real HID key through CuaDriver (ext_realkey real_key), as a person presses it.
    return {"do": "real_key", "key": key, "modifiers": mods, "mark": mark, "title": title}


# The TUI kit (owner 3): where its programs are on the mini, and one program per pane.
TUIKIT = "${tuikit}"
LOAD_PROGRAMS = ("gradient", "sigwinch", "top", "flood", "gradient", "mouse",
                 "agent-stream", "gradient", "vim-scroll", "top", "gradient", "flood")


def load_cmd(index, heavy):
    if not heavy:
        return None
    program = LOAD_PROGRAMS[index % len(LOAD_PROGRAMS)]
    extra = " --fps 120" if program == "gradient" else ""
    return f"python3 {TUIKIT} {program} --seed {1000 + index}{extra}"


# -- layout building blocks ---------------------------------------------------------------------------
def first_pane(case_id, heavy):
    steps = [{"do": "new_terminal", "name": case_id},
             {"do": "neutral_prompt"},
             {"do": "name_pane", "as": "p0"},
             {"do": "window_place", "title": "set-up: the window at 90% x 90% of the screen", "fraction": [0.05, 0.05, 0.9, 0.9]}]
    return steps + start_load(0, heavy)


def start_load(index, heavy):
    cmd = load_cmd(index, heavy)
    return [] if not cmd else [{"do": "type", "text": cmd, "enter": True, "title": f"set-up: load in pane p{index}"}]


def add_pane(index, action, heavy):
    """A new pane by the app's action (newColumn, splitRight, splitDown), named p<index>, its load started."""
    return [{"do": "action", "action": action, "title": f"set-up: {action}"},
            {"do": "adopt_pane", "as": f"p{index}"},
            {"do": "neutral_prompt"}] + start_load(index, heavy)


def theme(dark):
    name = "Builtin Dark" if dark else "Builtin Light"
    return {"do": "settings_file", "title": f"set-up: theme {name}, no close warning, columns a third of the window",
            "set": {"appearance": {"theme": name, "appTheme": "followTerminal"},
                    "app": {"warnBeforeClosingTab": False},
                    "layout": {"defaultColumnWidth": 0.3333}}}


def after_check():
    """After the motion: the pane p0 (it survives every case) takes keys and shows them, in the app, the daemon
    and the frame (the evidence every journey needs; also proves the layout works after the motion)."""
    return [{"do": "use_pane", "pane": "p0", "click": True, "title": "after: click into p0"},
            {"do": "key", "key": "c", "modifiers": ["control"], "title": "after: Ctrl-C ends p0's load program"},
            {"do": "type", "text": "echo rv-done-${nonce}", "enter": True, "mark": "after"},
            {"do": "expect", "title": "p0 echoes the line: app, daemon and frame", "since": "after", "timeout": 10,
             "all": [{"daemon_line": "rv-done-${nonce}"}, {"app_text_line": "rv-done-${nonce}"},
                     {"frame_text": "rv-done-${nonce}"}]}]


def settle(seconds=1.0):
    return {"do": "wait", "seconds": seconds, "title": "the layout and the load settle (nothing observable to wait on)"}


def columns(n, heavy, rows=1, start=0):
    """n strip columns, each with `rows` panes stacked (splitDown). Names p0..p(n*rows-1), column-major."""
    steps, idx = [], start
    for c in range(n):
        if c > 0 or idx > 0:
            steps += add_pane(idx, "newColumn", heavy)
        idx += 1
        for _ in range(rows - 1):
            steps += add_pane(idx, "splitDown", heavy)
            idx += 1
    return steps


def splits_in_row(n, heavy):
    steps = []
    for i in range(1, n):
        steps += add_pane(i, "splitRight", heavy)
    return steps


def splits_in_column(n, heavy):
    steps = []
    for i in range(1, n):
        steps += add_pane(i, "splitDown", heavy)
    return steps


def close(pane, mark, title=None):
    return [{"do": "use_pane", "pane": pane, "click": True, "title": f"focus {pane} (a click)"},
            kit_key("w", ["cmd"], mark, title or f"Cmd-W closes {pane}")]


# -- the cases -----------------------------------------------------------------------------------------
CASES = []


def case(cid, title, build, play, seconds=4, variants=(("heavy", "dark"),)):
    for load, look in variants:
        heavy, dark = load == "heavy", look == "dark"
        jid = f"rv-{cid}-{load}-{look}"
        # A click that picks the pane goes before the recording: the film holds only the motion under test.
        lead = 0
        while lead < len(play) and play[lead]["do"] == "use_pane":
            lead += 1
        steps = [theme(dark)] + first_pane(jid, heavy) + build(heavy) + play[:lead] + [settle(1.5), kit_record_start(jid, seconds)]
        steps += play[lead:] + [settle(seconds - 0.5), kit_record_stop(jid)] + after_check()
        CASES.append({"id": jid, "priority": "P1", "title": f"{title} ({load} load, {look})",
                      "why": "Lawrence 2026-11-02: every layout animation pixel perfect at 120 Hz with a 12-pane TUI load. "
                             "The movie and trace are judged per frame (gap, overlap, stretch, stale content, jump, dropped frames).",
                      "source": "RESIZE VIDEOS suite (handoff/resize-videos/FINDINGS.md)",
                      "budget_seconds": 240, "steps": steps})


ALL = (("heavy", "dark"), ("heavy", "light"), ("idle", "dark"))

# 1. The first case (lead order): close the middle of 3 columns.
case("close-mid-3col", "Close the middle of 3 strip columns with Cmd-W: the right column slides left to fill",
     lambda h: columns(3, h), close("p1", "close"), variants=ALL)
case("close-mid-3col-12", "12 panes (3 strip columns of 4): Cmd-W on the 2nd pane of the middle column, the other 3 grow",
     lambda h: columns(3, h, rows=4), close("p5", "close"), variants=(("heavy", "dark"), ("heavy", "light")))
# 2. Close a pane in a column (3 stacked): the other two grow.
case("close-in-column", "Close the middle of 3 panes stacked in one column: the other two grow to fill",
     lambda h: splits_in_column(3, h), close("p1", "close"), variants=ALL)
# 3. Close a pane in a row (3 splits side by side).
case("close-in-row", "Close the middle of 3 split panes in a row: the neighbours grow to fill",
     lambda h: splits_in_row(3, h), close("p1", "close"), variants=ALL)
# 4. The last pane of a column: middle column has 2 panes, close both (the column goes, neighbours fill).
case("close-last-of-column", "Close both panes of the middle column one after the other: the column goes, neighbours fill",
     lambda h: columns(3, h, rows=2), close("p3", "close1") + [settle(0.9)] + close("p2", "close2"), seconds=5)
# 5. Several closes fast: each interrupts the last motion, which must go on from where it is.
case("close-rapid", "Four Cmd-W 60 ms apart on a 3x2 grid of columns: each motion goes on from the current frame",
     lambda h: columns(3, h, rows=2),
     [{"do": "use_pane", "pane": "p5", "click": True}] + [kit_key("w", ["cmd"], f"close{i}", f"Cmd-W {i}") for i in range(4)],
     seconds=5)
# 6. Split during a running motion.
case("split-during-close", "Cmd-W, then Cmd-D 80 ms later while the close still moves",
     lambda h: splits_in_row(3, h),
     close("p1", "close") + [{"do": "wait", "seconds": 0.08}, kit_key("d", ["cmd"], "split", "Cmd-D during the close")])
case("split-during-split", "Cmd-D, then Shift-Cmd-D 80 ms later while the first split still moves",
     lambda h: splits_in_row(2, h),
     [kit_key("d", ["cmd"], "split1", "Cmd-D"), {"do": "wait", "seconds": 0.08},
      kit_key("d", ["cmd", "shift"], "split2", "Shift-Cmd-D during the first split")])
# 7. Zoom in and out with 12 panes (4 columns x 3 rows).
case("zoom-12", "Zoom one of 12 panes (Shift-Cmd-Return), then unzoom",
     lambda h: columns(4, h, rows=3),
     [{"do": "use_pane", "pane": "p4", "click": True}, kit_key("return", ["cmd", "shift"], "zoom", "zoom in"),
      {"do": "wait", "seconds": 1.0}, kit_key("return", ["cmd", "shift"], "unzoom", "zoom out")], seconds=4, variants=ALL)
case("zoom-interrupted", "Zoom in, then zoom out 100 ms later while the zoom still moves (12 panes)",
     lambda h: columns(4, h, rows=3),
     [{"do": "use_pane", "pane": "p4", "click": True}, kit_key("return", ["cmd", "shift"], "zoom", "zoom in"),
      {"do": "wait", "seconds": 0.1}, kit_key("return", ["cmd", "shift"], "unzoom", "zoom out mid-motion")])
# 8. Row divider drag: slow, fast, to the minimum and maximum clamp.
for speed, events in (("slow", 90), ("fast", 8)):
    case(f"row-drag-{speed}", f"Drag the divider between 2 stacked panes 200 points down, {speed} ({events} events at 120 Hz)",
         lambda h: splits_in_column(2, h),
         [{"do": "divider_drag", "between": ["p0", "p1"], "by": 200, "events": events, "hz": 120, "mark": "drag"}])
case("row-drag-clamp", "Drag the row divider past the minimum pane height, then past the maximum",
     lambda h: splits_in_column(2, h),
     [{"do": "divider_drag", "between": ["p0", "p1"], "by": -2000, "events": 40, "hz": 120, "mark": "min"},
      {"do": "wait", "seconds": 0.5},
      {"do": "divider_drag", "between": ["p0", "p1"], "by": 4000, "events": 40, "hz": 120, "mark": "max"}], seconds=5)
# 9. Split-divider drag in a row with 2, 3 and 6 panes (the strip column edge drags are the HARNESS owner's 3 cases).
for n in (2, 3, 6):
    case(f"col-drag-{n}", f"Drag a vertical divider of {n} panes in a row 150 points right, then back, at 120 Hz",
         (lambda n: lambda h: splits_in_row(n, h))(n),
         [{"do": "divider_drag", "between": ["p0", "p1"], "by": 150 if n < 6 else 60, "events": 40, "hz": 120, "mark": "drag"},
          {"do": "divider_drag", "between": ["p0", "p1"], "by": -150 if n < 6 else -60, "events": 8, "hz": 120, "mark": "back"}],
         seconds=4)
case("col-drag-clamp", "Drag a vertical divider of 3 panes past the minimum width, then past the maximum",
     lambda h: splits_in_row(3, h),
     [{"do": "divider_drag", "between": ["p0", "p1"], "by": -2000, "events": 40, "hz": 120, "mark": "min"},
      {"do": "wait", "seconds": 0.5},
      {"do": "divider_drag", "between": ["p0", "p1"], "by": 4000, "events": 40, "hz": 120, "mark": "max"}], seconds=5)
# 10. Window resize with 12 panes (bottom-right corner, out and back).
case("window-resize-12", "Live-resize the window with 12 panes: the corner 300 x 150 points in and back at 120 Hz",
     lambda h: columns(4, h, rows=3),
     [{"do": "window_drag", "edge": "bottom-right", "by": [-300, -150], "events": 60, "hz": 120, "release": False, "mark": "in"},
      {"do": "window_drag", "edge": "bottom-right", "by": [300, 150], "events": 60, "hz": 120, "press": False, "mark": "out"}],
     seconds=4)
# 11. 1 pane against 12 panes: the same split in a 1-pane and in a 12-pane layout.
case("split-1pane", "Cmd-D in a single pane", lambda h: [], [kit_key("d", ["cmd"], "split", "Cmd-D")], variants=ALL)
case("split-12pane", "Cmd-D in one of 12 panes", lambda h: columns(4, h, rows=3),
     [{"do": "use_pane", "pane": "p5", "click": True}, kit_key("d", ["cmd"], "split", "Cmd-D")], variants=ALL)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out")
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--list", action="store_true")
    opts = ap.parse_args()
    chosen = [c for c in CASES if not opts.only or any(c["id"].startswith(o) or c["id"] == o for o in opts.only)]
    if opts.list or not opts.out:
        for c in chosen:
            print(f"{c['id']:40} {c['title']}")
        return 0
    os.makedirs(opts.out, exist_ok=True)
    for c in chosen:
        with open(os.path.join(opts.out, c["id"] + ".json"), "w") as f:
            json.dump(c, f, indent=1)
            f.write("\n")
    print(f"{len(chosen)} cases in {opts.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
