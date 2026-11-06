#!/usr/bin/env python3
"""CLOSE MOTION films (task close-motion, cmux-ad m48): every close case on its own fresh workspace, filmed whole-window at
120 Hz with the PIXEL PERFECT recorder (px_record_start: movie, trace, scan lines). Local kit only.

  gen_close.py [--out DIR]   writes journeys/video/cm-*.json

Cases (contract in /work/wt/handoff/tasks/close-motion.md):
  A  a tab of a pane that keeps other tabs           (active by Cmd-W, inactive by the socket, pinned, Reduce Motion,
                                                      Chromium and WebKit browser tabs)
  B  the last tab of a pane, other panes stay        (split, column strip, Reduce Motion, a second Cmd-W during the spring,
                                                      Chromium and WebKit page as the only tab)
  C  the last tab of the last pane                   (Cmd-W, Reduce Motion)
  D  Close Workspace (Cmd-Shift-W)                   (a workspace of two panes)
  E  rapid Cmd-W x3 (A -> B -> C), the last workspace of the window
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cases as G  # noqa: E402
import gen_pixel as X  # noqa: E402

BLUE, GREEN, YELLOW = X.BLUE, X.GREEN, X.YELLOW
CMD_W = ("w", ["cmd"])
CMD_SHIFT_W = ("w", ["cmd", "shift"])


def ws(f):
    """A fresh workspace for film F, its first pane named F-p0 with the terminal fixture (blue)."""
    return [{"do": "action", "action": "workspace.newAtBottom", "title": f"set-up {f}: a new workspace"},
            {"do": "adopt_pane", "as": f"{f}-p0"}, {"do": "neutral_prompt"}] + X.start_tui(f"{f}-p0", BLUE, label="p0")


def pane(f, n, action, fill, after=None):
    steps = [X.focus(after)] if after else []
    return steps + X.new_pane(f"{f}-p{n}", action) + X.start_tui(f"{f}-p{n}", fill, label=f"p{n}")


def tabs(f, n, count, fill=BLUE):
    steps = [X.focus(f"{f}-p{n}")]
    for i in range(2, count + 1):
        steps += X.new_tab(f"{f}-p{n}") + X.start_tui(f"{f}-p{n}", fill, label=f"p{n}.{i}")
    return steps


def key(k, mark, title):
    return G.kit_key(k[0], list(k[1]), mark, title)


def film(name, fixture, play, seconds=5.0, reduce=False, before=()):
    start = {"do": "px_record_start", "name": name, "seconds": seconds, "require_hz": 120, "mbps": X.MOVIE_MBPS,
             "fixture": fixture, "spring": None, "input": "close",
             "title": f"start the 120 Hz movie, the trace and scan lines ({name})"}
    steps = (list(before) + [G.settle(0.8), {"do": "cm_topo", "as": "before"},
                             {"do": "rpc", "method": "debug.frames", "params": {"action": "start"}, "title": "debug.frames start"},
                             {"do": "rpc", "method": "debug.motion", "params": {"action": "start"}, "title": "debug.motion spans start"},
                             start]
             + list(play) + [X.rest(1.0),
                             {"do": "rpc", "method": "debug.motion", "params": {"action": "stop"}, "keep": "spans",
                              "title": "debug.motion spans stop (<film>.spans.json)"},
                             {"do": "rpc", "method": "debug.frames", "params": {"action": "stop", "raw": True}, "keep": "frames",
                              "title": "debug.frames stop raw (<film>.frames.json)"},
                             {"do": "cm_topo", "as": "after"}, G.kit_record_stop(name, 0.4)])
    step = {"do": "px_film", "name": name, "steps": steps, "after": [],
            "title": f"film {name}" + (": Reduce Motion" if reduce else ": x1")}
    step.update({"reduce": True} if reduce else {"speed": 1.0})
    return step


def fx(f, fills):
    return {f"{f}-p{n}": {"kind": "tui", "fill": fill} for n, fill in fills.items()}


# -- the cases: (journey, film id, set-up, fixture, play, reduce) -------------------------------------------------------
def case_a(f, reduce=False):
    setup = ws(f) + pane(f, 1, "splitRight", GREEN) + tabs(f, 0, 3)
    return setup, film(f, fx(f, {0: BLUE, 1: GREEN}), [X.focus(f"{f}-p0"), key(CMD_W, "close", "Cmd-W closes p0's shown tab (of 3)")],
                       reduce=reduce)


def case_a_inactive(f):
    setup = ws(f) + pane(f, 1, "splitRight", GREEN) + tabs(f, 0, 3)
    return setup, film(f, fx(f, {0: BLUE, 1: GREEN}),
                       [{"do": "cm_close_tab", "pane": f"{f}-p0", "which": "first", "mark": "close",
                         "title": "the socket closes p0's first tab (not the shown one)"}])


def case_a_pinned(f):
    setup = ws(f) + pane(f, 1, "splitRight", GREEN) + tabs(f, 0, 3) + [{"do": "cm_pin", "pane": f"{f}-p0", "title": "pin p0's shown tab"}]
    return setup, film(f, fx(f, {0: BLUE, 1: GREEN}), [X.focus(f"{f}-p0"), key(CMD_W, "close", "Cmd-W on p0's pinned shown tab")])


def case_b_split(f, reduce=False):
    setup = ws(f) + pane(f, 1, "splitRight", GREEN) + pane(f, 2, "splitRight", YELLOW)
    return setup, film(f, fx(f, {0: BLUE, 1: GREEN, 2: YELLOW}),
                       [X.focus(f"{f}-p1"), key(CMD_W, "close", "Cmd-W closes p1's only tab (the middle split)")], reduce=reduce)


def case_b_column(f):
    setup = ws(f) + pane(f, 1, "newColumn", GREEN) + pane(f, 2, "newColumn", YELLOW)
    return setup, film(f, fx(f, {0: BLUE, 1: GREEN, 2: YELLOW}),
                       [X.focus(f"{f}-p1"), key(CMD_W, "close", "Cmd-W closes p1's only tab (the middle column)")])


def case_b_spring(f):
    setup = ws(f) + pane(f, 1, "splitRight", GREEN) + pane(f, 2, "splitRight", YELLOW)
    return setup, film(f, fx(f, {0: BLUE, 1: GREEN, 2: YELLOW}),
                       [X.focus(f"{f}-p1"),
                        {"do": "rk_press", "key": "w", "modifiers": ["cmd"], "count": 2, "gap_ms": 90, "mark": "close",
                         "title": "Cmd-W on p1, then Cmd-W again 90 ms later (during the pane-close spring)"}])


def case_c(f, reduce=False):
    setup = ws(f)
    return setup, film(f, fx(f, {0: BLUE}), [X.focus(f"{f}-p0"), key(CMD_W, "close", "Cmd-W closes the workspace's last tab")],
                       reduce=reduce)


def case_d(f):
    setup = ws(f) + pane(f, 1, "splitRight", GREEN)
    return setup, film(f, fx(f, {0: BLUE, 1: GREEN}), [X.focus(f"{f}-p0"), key(CMD_SHIFT_W, "close", "Cmd-Shift-W closes the workspace (2 panes)")])


def case_rapid(f):
    setup = ws(f) + pane(f, 1, "splitRight", GREEN) + tabs(f, 0, 2)
    return setup, film(f, fx(f, {0: BLUE, 1: GREEN}), [X.focus(f"{f}-p0"),
                               {"do": "rk_press", "key": "w", "modifiers": ["cmd"], "count": 3, "gap_ms": 150, "mark": "close",
                                "title": "Cmd-W x3, 150 ms apart: p0's tab (A), p0's last tab (B), p1's last tab (C)"}], seconds=6.0)


def case_browser(f, engine, last):
    """A browser tab of ENGINE in p1. last: p1's terminal tab is closed first, so the page is p1's only tab (B)."""
    setup = ws(f) + pane(f, 1, "splitRight", GREEN) + [{"do": "cm_browser", "pane": f"{f}-p1", "engine": engine, "bg": "#FFFF00"}]
    if last:
        setup += [{"do": "cm_close_tab", "pane": f"{f}-p1", "which": "first", "title": "set-up: p1's terminal tab closed (the page stays)"},
                  G.settle(1.0)]
    what = "p1's only tab (a page)" if last else "p1's shown page tab (p1 keeps its terminal tab)"
    return setup, film(f, fx(f, {0: BLUE}), [X.focus(f"{f}-p1"), key(CMD_W, "close", f"Cmd-W closes {what}, {engine}")])


def case_last_ws(f):
    setup = ws(f) + [{"do": "cm_close_others", "title": "set-up: every other workspace closed (this is the window's last)"}]
    return setup, film(f, fx(f, {0: BLUE}), [X.focus(f"{f}-p0"), key(CMD_W, "close", "Cmd-W closes the window's last workspace's last tab")])


JOURNEYS = {
    "cm-a": [case_a("cm-a-active"), case_a("cm-a-active-reduce", reduce=True), case_a_inactive("cm-a-inactive"),
             case_a_pinned("cm-a-pinned")],
    "cm-b": [case_b_split("cm-b-split"), case_b_split("cm-b-split-reduce", reduce=True), case_b_column("cm-b-column"),
             case_b_spring("cm-b-spring")],
    "cm-c": [case_c("cm-c-last"), case_c("cm-c-last-reduce", reduce=True), case_d("cm-d-closews"), case_rapid("cm-e-rapid")],
    "cm-br": [case_browser("cm-br-cef-tab", "cef", False), case_browser("cm-br-cef-last", "cef", True),
              case_browser("cm-br-wk-tab", "webkit", False), case_browser("cm-br-wk-last", "webkit", True)],
    "cm-last": [case_last_ws("cm-e-lastws")],
}


def journey(jid, films):
    steps = [X.fixture_settings()] + G.first_pane(jid, False) + X.fixture_files()
    names = []
    for setup, step in films:
        steps += setup + [G.settle(1.2)] + [step]
        names.append(step["name"])
    final = [{"do": "px_springs", "reset": True, "title": "clean-up: springs and Reduce Motion back"}, X.settings_back()]
    return {"id": jid, "priority": "P1", "title": f"CLOSE MOTION: {', '.join(names)}",
            "why": "cmux-ad m48 (Lawrence 2026-11-06): the close picks one case (tab / last tab of a pane / last tab of a workspace); "
                   "film every case whole-window at 120 Hz.",
            "source": "close-motion task kit (video-cases/gen_close.py)", "budget_seconds": 250,
            "recordings": names, "options": {"key_path": "real"}, "steps": steps, "finally": final}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    opts = ap.parse_args()
    for jid, films in JOURNEYS.items():
        path = os.path.join(opts.out, f"{jid}.json")
        with open(path, "w") as f:
            json.dump(journey(jid, films), f, indent=1)
            f.write("\n")
        print(path)


if __name__ == "__main__":
    main()
