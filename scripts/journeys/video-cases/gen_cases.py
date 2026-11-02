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
def kit_record_start(name, seconds, require_hz=None):
    step = {"do": "video_start", "name": name, "seconds": seconds,
            "title": f"start the movie and the geometry trace ({name})"}
    if require_hz:
        step["require_hz"] = require_hz
    return step


def kit_record_stop(name, tail=1.0):
    return {"do": "video_stop", "name": name, "tail": tail, "title": f"the motion ends; stop the recording ({name})"}


def kit_key(key, mods, mark, title):
    # A real HID key through CuaDriver (ext_video hid_key), as a person presses it.
    return {"do": "hid_key", "key": key, "modifiers": mods, "mark": mark, "title": title}


def kit_drag(target, by, duration_ms, mark, title=None):
    # A real HID drag (ext_video hid_drag, one move per 8 ms) from the target's center.
    return {"do": "hid_drag", "target": target, "by": by, "duration_ms": duration_ms, "mark": mark,
            "title": title or f"real drag of {target} by {by} in {duration_ms} ms"}


# The TUI kit (owner 3): where its programs are on the mini, and one program per pane.
TUIKIT = "/tmp/jr-tuikit.py"
TUIKIT_REF = "3d744f43626c"  # TUI kit PR #31507 head (scripts/journeys/tui-kit/tuikit.py), written to TUIKIT by a file step


def tuikit_file():
    import subprocess
    text = subprocess.run(["git", "show", f"{TUIKIT_REF}:scripts/journeys/tui-kit/tuikit.py"], capture_output=True,
                          text=True, check=True, cwd=os.path.dirname(os.path.abspath(__file__))).stdout
    return {"do": "file", "path": TUIKIT, "text": text, "title": f"set-up: the TUI kit's tuikit.py at {TUIKIT_REF}"}
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
    steps = [{"do": "smoke_ready", "timeout": 60}, {"do": "smoke_make_key"},
             {"do": "new_terminal", "via": "key", "name": case_id},
             {"do": "neutral_prompt"},
             {"do": "name_pane", "as": "home"},
             {"do": "window_place", "title": "set-up: the window at 90% x 90% of the screen", "fraction": [0.05, 0.05, 0.9, 0.9]},
             # The launch workspace (Home) has an agent chat docked left as its main pane: the case gets a workspace of
             # its own, so its panes are the only ones on the screen.
             {"do": "action", "action": "workspace.newAtBottom", "title": "set-up: a new workspace for the case"},
             {"do": "adopt_pane", "as": "p0"},
             {"do": "neutral_prompt"}]
    return steps + ([tuikit_file()] if heavy else []) + start_load(0, heavy)


def start_load(index, heavy):
    cmd = load_cmd(index, heavy)
    if not cmd:
        return []
    # The program draws on the alternate screen: the prompt line leaves the daemon's screen once it runs.
    return [{"do": "type", "text": cmd, "enter": True, "title": f"set-up: load in pane p{index}", "mark": f"load{index}"},
            {"do": "expect", "title": f"set-up: the load program runs in p{index} (its alternate screen hides the prompt)",
             "since": f"load{index}", "timeout": 8, "all": [{"daemon_lacks": "J> "}]}]


def add_pane(index, action, heavy):
    """A new pane by the app's action (newColumn, splitRight, splitDown), named p<index>, its load started."""
    return [{"do": "action", "action": action, "title": f"set-up: {action}"},
            {"do": "adopt_pane", "as": f"p{index}"},
            {"do": "neutral_prompt"}] + start_load(index, heavy)


def theme(dark):
    name = "Builtin Dark" if dark else "Builtin Light"
    return {"do": "settings_file", "title": f"set-up: theme {name}, no close warning, new columns share the strip",
            "set": {"appearance": {"theme": name, "appTheme": "followTerminal"},
                    "app": {"warnBeforeClosingTab": False},
                    # New columns share the strip with the visible ones, so 2..4 columns all show side by side.
                    "layout": {"newColumnWidth": "fitScreen"}}}


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


WIDTH_PRESET = {1: "column.widthFull", 2: "column.widthHalf", 3: "column.widthOneThird"}


def columns(n, heavy, rows=1, start=0):
    """n strip columns (1..3, all on screen: each set to 1/n of the viewport with the app's width preset), each with
    `rows` panes stacked (splitDown). Names p0..p(n*rows-1), column-major."""
    if n not in WIDTH_PRESET:
        raise ValueError(f"{n} strip columns do not fit on screen with the width presets")
    width = {"do": "try_action", "action": WIDTH_PRESET[n], "title": f"set-up: the focused column 1/{n} of the viewport (may hold already)"}
    steps, idx = [], start
    for c in range(n):
        if c > 0 or idx > 0:
            steps += add_pane(idx, "newColumn", heavy)
        if c > 0:
            steps.append(dict(width))  # a width preset needs a second column
        idx += 1
        for _ in range(rows - 1):
            steps += add_pane(idx, "splitDown", heavy)
            idx += 1
    if n > 1:
        # Back to the first column (it still has the full width) and give it 1/n too.
        steps += [{"do": "action", "action": "focusLeft", "title": "set-up: focus the column on the left"}] * (n - 1)
        steps.append(dict(width))
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


def case(cid, title, build, play, seconds=20, variants=(("heavy", "dark"),), tail=1.2, sample=False):
    for load, look in variants:
        heavy, dark = load == "heavy", look == "dark"
        jid = f"rv-{cid}-{load}-{look}"
        # A click that picks the pane goes before the recording: the film holds only the motion under test.
        lead = 0
        while lead < len(play) and play[lead]["do"] == "use_pane":
            lead += 1
        # Main-thread evidence per display frame (fix owner, STATUS 4473): debug.frames (each frame's interval, the
        # main run loop's busy time and layout passes in it, raw arrays) and debug.main_budget / debug.hangs.
        probes_on = [{"do": "rpc", "method": "debug.main_budget", "params": {"reset": True}, "title": "probe: main budget reset"},
                     {"do": "rpc", "method": "debug.frames", "params": {"action": "start", "raw": True}, "title": "probe: per-frame main thread on"}]
        probes_off = [{"do": "rpc", "method": "debug.frames", "params": {"action": "stop", "raw": True}, "title": "probe: per-frame main thread (raw)"},
                      {"do": "rpc", "method": "debug.main_budget", "params": {}, "title": "probe: main budget since the reset"},
                      {"do": "rpc", "method": "debug.hangs", "params": {}, "title": "probe: hangs"}]
        steps = [theme(dark)] + first_pane(jid, heavy) + build(heavy) + play[:lead] + [settle(1.5)] + probes_on + [kit_record_start(jid, seconds)]
        # The recorder's record_start stalls the main thread 48-72 ms (STATUS 4500): 0.6 s of lead before the motion.
        steps.append({"do": "wait", "seconds": 0.6, "title": "lead: the recorder's start stall passes before the motion"})
        if sample:
            steps.append({"do": "sample_start", "name": "closesample", "seconds": 1.0, "interval_ms": 1,
                          "title": "a 1 ms main-thread sample of the app around the motion"})
        steps += play[lead:]
        if sample:
            steps.append({"do": "sample_stop", "name": "closesample"})
        steps += [kit_record_stop(jid, tail)] + probes_off + after_check()
        CASES.append({"id": jid, "priority": "P1", "title": f"{title} ({load} load, {look})",
                      "why": "Lawrence 2026-11-02: every layout animation pixel perfect at 120 Hz with a 12-pane TUI load. "
                             "The movie and trace are judged per frame (gap, overlap, stretch, stale content, jump, dropped frames).",
                      "source": "RESIZE VIDEOS suite (handoff/resize-videos/FINDINGS.md)",
                      "budget_seconds": 240, "options": {"key_path": "real"}, "steps": steps})


ALL = (("heavy", "dark"), ("heavy", "light"), ("idle", "dark"))

# 1. The first case (lead order): close the middle of 3 columns.
case("close-mid-3col", "Close the middle of 3 strip columns with Cmd-W: the right column slides left to fill",
     lambda h: columns(3, h), close("p1", "close"), variants=ALL)
case("close-mid-3col-12", "12 panes (3 strip columns of 4): Cmd-W on the 2nd pane of the middle column, the other 3 grow",
     lambda h: columns(3, h, rows=4), close("p5", "close"), variants=(("heavy", "dark"), ("heavy", "light")))
# F1 cause (lead 01:5xZ): the same closes with a 1 ms sample of the app's threads around the Cmd-W.
case("close-in-row-sampled", "Close the middle of 3 split panes in a row, with a 1 ms sample of the app (F1 cause)",
     lambda h: splits_in_row(3, h), close("p1", "close"), variants=(("heavy", "dark"), ("idle", "dark")), sample=True)
case("close-mid-3col-sampled", "Close the middle of 3 strip columns, with a 1 ms sample of the app (F1 cause)",
     lambda h: columns(3, h), close("p1", "close"), variants=(("heavy", "dark"),), sample=True)
# 2. Close a pane in a column (3 stacked): the other two grow.
case("close-in-column", "Close the middle of 3 panes stacked in one column: the other two grow to fill",
     lambda h: splits_in_column(3, h), close("p1", "close"), variants=ALL)
# 3. Close a pane in a row (3 splits side by side).
case("close-in-row", "Close the middle of 3 split panes in a row: the neighbours grow to fill",
     lambda h: splits_in_row(3, h), close("p1", "close"), variants=ALL)
# 4. The last pane of a column: middle column has 2 panes, close both (the column goes, neighbours fill).
case("close-last-of-column", "Close both panes of the middle column one after the other: the column goes, neighbours fill",
     lambda h: columns(3, h, rows=2), close("p3", "close1") + [settle(0.9)] + close("p2", "close2"))
# 5. Several closes fast: each interrupts the last motion, which must go on from where it is.
case("close-rapid", "Four Cmd-W 60 ms apart on a 3x2 grid of columns: each motion goes on from the current frame",
     lambda h: columns(3, h, rows=2),
     [{"do": "use_pane", "pane": "p5", "click": True}] + [kit_key("w", ["cmd"], f"close{i}", f"Cmd-W {i}") for i in range(4)])
# 6. Split during a running motion.
case("split-during-close", "Cmd-W, then Cmd-D 80 ms later while the close still moves",
     lambda h: splits_in_row(3, h),
     close("p1", "close") + [{"do": "wait", "seconds": 0.08}, kit_key("d", ["cmd"], "split", "Cmd-D during the close")])
case("split-during-split", "Cmd-D, then Shift-Cmd-D 80 ms later while the first split still moves",
     lambda h: splits_in_row(2, h),
     [kit_key("d", ["cmd"], "split1", "Cmd-D"), {"do": "wait", "seconds": 0.08},
      kit_key("d", ["cmd", "shift"], "split2", "Shift-Cmd-D during the first split")])
# 7. Zoom in and out with 12 panes (4 columns x 3 rows).
case("zoom-12", "Zoom one of 12 panes (3 columns x 4 rows; Shift-Cmd-Return), then unzoom",
     lambda h: columns(3, h, rows=4),
     [{"do": "use_pane", "pane": "p4", "click": True}, kit_key("return", ["cmd", "shift"], "zoom", "zoom in"),
      {"do": "wait", "seconds": 1.0}, kit_key("return", ["cmd", "shift"], "unzoom", "zoom out")], variants=ALL)
case("zoom-interrupted", "Zoom in, then zoom out 100 ms later while the zoom still moves (12 panes)",
     lambda h: columns(3, h, rows=4),
     [{"do": "use_pane", "pane": "p4", "click": True}, kit_key("return", ["cmd", "shift"], "zoom", "zoom in"),
      {"do": "wait", "seconds": 0.1}, kit_key("return", ["cmd", "shift"], "unzoom", "zoom out mid-motion")])
# 8. Row divider drag: slow, fast, to the minimum and maximum clamp.
for speed, ms in (("slow", 1500), ("fast", 120)):
    case(f"row-drag-{speed}", f"Drag the divider between 2 stacked panes 200 points down, {speed} (real HID, {ms} ms)",
         lambda h: splits_in_column(2, h),
         [kit_drag({"row_divider": 0}, [0, 200], ms, "drag")])
case("row-drag-clamp", "Drag the row divider past the minimum pane height, then past the maximum",
     lambda h: splits_in_column(2, h),
     [kit_drag({"row_divider": 0}, [0, -900], 400, "min", "past the minimum height"), {"do": "wait", "seconds": 0.5},
      kit_drag({"row_divider": 0}, [0, 1800], 400, "max", "past the maximum height")])
# 9. Split-divider drag in a row with 2, 3 and 6 panes (the strip column edge drags are the HARNESS owner's 3 cases).
for n in (2, 3, 6):
    case(f"col-drag-{n}", f"Drag a vertical divider of {n} panes in a row 150 points right, then back, at 120 Hz",
         (lambda n: lambda h: splits_in_row(n, h))(n),
         [kit_drag({"divider": 0}, [150 if n < 6 else 60, 0], 1000, "drag", "slow, right"), {"do": "wait", "seconds": 0.4},
          kit_drag({"divider": 0}, [-150 if n < 6 else -60, 0], 100, "back", "fast, back")])
case("col-drag-clamp", "Drag a vertical divider of 3 panes past the minimum width, then past the maximum",
     lambda h: splits_in_row(3, h),
     [kit_drag({"divider": 0}, [-1500, 0], 400, "min", "past the minimum width"), {"do": "wait", "seconds": 0.5},
      kit_drag({"divider": 0}, [3000, 0], 400, "max", "past the maximum width")])
# 10. Window resize with 12 panes (bottom-right corner, out and back).
case("window-resize-12", "Live-resize the window with 12 panes: the corner 300 x 150 points in and back at 120 Hz",
     lambda h: columns(3, h, rows=4),
     [kit_drag({"window_edge": "bottom-right"}, [-300, -150], 600, "in", "window corner in"), {"do": "wait", "seconds": 0.3},
      kit_drag({"window_edge": "bottom-right"}, [300, 150], 600, "out", "window corner out")])
# 11. 1 pane against 12 panes: the same split in a 1-pane and in a 12-pane layout.
case("split-1pane", "Cmd-D in a single pane", lambda h: [], [kit_key("d", ["cmd"], "split", "Cmd-D")], variants=ALL)
# A 384 pt pane has no room for a split right (2 x 192 < layout.minimumPaneWidth 200, run 9): split down instead.
case("split-12pane", "Shift-Cmd-D in one of 12 panes (3 columns x 4 rows)", lambda h: columns(3, h, rows=4),
     [{"do": "use_pane", "pane": "p5", "click": True}, kit_key("d", ["cmd", "shift"], "split", "Shift-Cmd-D")], variants=ALL)


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
