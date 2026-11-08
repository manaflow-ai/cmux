#!/usr/bin/env python3
"""CLOSE PERF (task close-perf, cmux-ad m56): the perf of a close and the motion after it. Per cell (pane kind x case x
load) one 120 Hz movie (no scan lines) holds N real-key closes; each close has its own debug.frames / debug.motion /
grid / action-budget read (ext_closeperf cp_close). Local kit only.

  gen_closeperf.py [--out DIR] [--n 10]   writes journeys/video/cp-*.json

Kinds: term (shell panes), cef (Chromium page), wk (WebKit page). Cases:
  A        the shown tab of a pane that keeps a tab           (term: a 2nd terminal tab of p0; page: a page tab of p1)
  bsplit   the last tab of the middle split (p0 | p1 | p2)     (page: p1's only tab is the page)
  bcol     the last tab of the middle column (newColumn)
  C        the last tab of the last pane (the workspace closes)
  D        Cmd-Shift-W on a workspace of 2 panes (term | term or page)
Loads: light, stress (STRESS-lite, ext_cmdn grow_workspaces: 60 workspaces, 10 busy terminals).
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cases as G  # noqa: E402
import gen_pixel as X  # noqa: E402

W = ("w", ["cmd"])
SW = ("w", ["cmd", "shift"])
REST = 1.2


def new_ws(name):
    return [{"do": "action", "action": "workspace.newAtBottom", "title": f"set-up: a new workspace ({name})"},
            {"do": "adopt_pane", "as": name}, {"do": "neutral_prompt"}]


def page(pane, engine, only):
    s = [{"do": "cm_browser", "pane": pane, "engine": engine, "bg": "#FFFF00", "settle": 0.8}]
    if only:
        s.append({"do": "cm_close_tab", "pane": pane, "which": "first", "title": f"set-up: {pane}'s terminal tab closed (the page stays)"})
        s.append(G.settle(0.4))
    return s


def close(f, i, k):
    return {"do": "cp_close", "film": f, "i": i, "key": k[0], "modifiers": k[1], "rest": REST,
            "title": f"close {i} of {f}: {'+'.join(k[1])}-{k[0]}"}


def cell(f, kind, case, n, base=None):
    """(steps, movie seconds) of one cell: set-up once, then N times: set-up, focus, close. With `base` (full STRESS),
    A and B close in the measured workspace's pane `base` (no new workspace); C and D make their own workspaces."""
    eng = {"cef": "cef", "wk": "webkit"}.get(kind)
    once, steps = [], []
    if base and case in ("A", "bsplit", "bcol") and not eng:
        act = {"bsplit": "splitRight", "bcol": "newColumn"}.get(case)
        for i in range(n):
            if case == "A":
                steps += [X.focus(base)] + X.new_tab(base) + [X.focus(base)]
            else:
                p = f"{f}-p1-{i}"
                steps += [X.focus(base)] + X.new_pane(p, act) + [X.focus(p)]
            steps += [G.settle(0.3), close(f, i, W)]
    elif case == "A":
        once = new_ws(f"{f}-p0") + X.new_pane(f"{f}-p1", "splitRight")
        for i in range(n):
            if eng:
                steps += page(f"{f}-p1", eng, False) + [X.focus(f"{f}-p1")]
            else:
                steps += [X.focus(f"{f}-p0")] + X.new_tab(f"{f}-p0") + [X.focus(f"{f}-p0")]
            steps += [G.settle(0.3), close(f, i, W)]
    elif case in ("bsplit", "bcol"):
        act = "splitRight" if case == "bsplit" else "newColumn"
        once = new_ws(f"{f}-p0") + X.new_pane(f"{f}-p2", act)
        for i in range(n):
            p = f"{f}-p1-{i}"
            steps += [X.focus(f"{f}-p0")] + X.new_pane(p, act)
            if eng:
                steps += page(p, eng, True)
            steps += [X.focus(p), G.settle(0.3), close(f, i, W)]
    elif case == "C":
        for i in range(n):
            p = f"{f}-c{i}"
            steps += new_ws(p) + (page(p, eng, True) if eng else []) + [X.focus(p), G.settle(0.3), close(f, i, W)]
    elif case == "D":
        for i in range(n):
            p0, p1 = f"{f}-d{i}a", f"{f}-d{i}b"
            steps += new_ws(p0) + X.new_pane(p1, "splitRight") + (page(p1, eng, False) if eng else [])
            steps += [X.focus(p1), G.settle(0.3), close(f, i, SW)]
    per = (REST + 1.6 + (2.2 if eng else 0.0))
    seconds = min(115.0, 6.0 + n * per)
    start = {"do": "video_start", "name": f, "seconds": seconds, "mbps": 24, "rows": [], "columns": [], "require_hz": 120,
             "lead": 0.8, "title": f"start the 120 Hz movie of cell {f} (no scan lines)"}
    stop = G.kit_record_stop(f, 0.3)
    return once + [G.settle(0.5), start] + steps + [stop], n * per + 8


CASES = ["A", "bsplit", "bcol", "C", "D"]
LIMIT = 250.0


def journeys(n):
    """Cells packed into journeys of at most LIMIT s (estimate), one journey per lease (budget >= 135 s)."""
    out = {}
    for kind in ("term", "cef", "wk"):
        for load in ("light", "stress") + (("full",) if kind == "term" else ()):
            base = 40.0 + {"stress": 50.0, "full": 110.0}.get(load, 0.0)
            groups, cur, used = [], [], base
            for c in CASES:
                sec = cell(f"x", kind, c, n)[1]
                if cur and used + sec > LIMIT:
                    groups.append(cur)
                    cur, used = [], base
                cur.append(c)
                used += sec
            groups.append(cur)
            for gi, cases in enumerate(groups):
                jid = f"cp-{kind}-{load}" + (f"-{gi + 1}" if len(groups) > 1 else "")
                out[jid] = (kind, load, [(f"cp-{kind}-{load}-{c.lower()}", c) for c in cases])
    return out


def journey(jid, kind, load, cells, n):
    check = [{"do": "type", "text": "echo cp-ready-${nonce}", "enter": True, "mark": "ready"},
             {"do": "expect", "title": "set-up check: the app types", "since": "ready", "timeout": 10,
              "all": [{"daemon_line": "cp-ready-${nonce}"}, {"app_text_line": "cp-ready-${nonce}"},
                      {"frame_text": "cp-ready-${nonce}"}]}]
    steps = G.first_pane(jid, False) + check + [X.fixture_settings()] + X.fixture_files()
    est = 40.0
    if load == "stress":
        steps += [{"do": "grow_workspaces", "count": 60, "busy": 10, "settle": 2.0,
                   "title": "STRESS-lite: 60 workspaces, 10 busy terminals (perf-stress-session.py BUSY_COMMAND)"}]
        est += 50.0
    if load == "full":
        steps += [{"do": "stress_full", "settle": 2.0, "title": "STRESS (perf-lead.md, perf-stress-session.py): 60 workspaces, "
                   "measured 4x3 workspace of 14 panes x 6 tabs, 10 Chromium workspaces, 10 busy terminals"},
                  {"do": "adopt_pane", "as": "stress-m", "title": "the measured workspace's focused terminal pane"}]
        est += 110.0
    names = []
    for f, case in cells:
        s, sec = cell(f, kind, case, n, "stress-m" if load == "full" else None)
        steps += s
        est += sec
        names.append(f)
    final = [X.settings_back()]
    return {"id": jid, "priority": "P1", "title": f"CLOSE PERF {kind} {load}: {', '.join(names)}",
            "why": "cmux-ad m56 (Lawrence 2026-11-07): measure the perf of a close and the motion after it (light and STRESS-lite).",
            "source": "close-perf task kit (video-cases/gen_closeperf.py)", "budget_seconds": int(min(255, max(135, est))),
            "recordings": names, "options": {"key_path": "real"}, "steps": steps, "finally": final}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    ap.add_argument("--n", type=int, default=10)
    opts = ap.parse_args()
    for jid, (kind, load, cells) in journeys(opts.n).items():
        spec = journey(jid, kind, load, cells, opts.n)
        path = os.path.join(opts.out, f"{jid}.json")
        with open(path, "w") as f:
            json.dump(spec, f, indent=1)
            f.write("\n")
        print(path, spec["budget_seconds"], len(spec["steps"]))


if __name__ == "__main__":
    main()
