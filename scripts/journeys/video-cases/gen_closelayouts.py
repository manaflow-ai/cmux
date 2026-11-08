#!/usr/bin/env python3
"""CLOSE LAYOUTS films (cmux-ad m61, Lawrence: 'like vertical stacked panes and rows and columns'): V0 (the build's own
close, no film selector) for each layout shape, one Cmd-W per film, real TUIs in the survivors (ALT nvim/htop, MAIN zsh
with numbered lines). The closed pane is always an idle shell (no close guard). Local kit only (never pushed).

  gen_closelayouts.py [--layouts R2,R2b,R3,...] [--tag l] [--ms 150]
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cases as G  # noqa: E402
import gen_pixel as X  # noqa: E402
import gen_closevariants as CV  # noqa: E402

MODE = {"nvim": "ALT", "htop": "ALT", "zsh": "MAIN", None: None}


def run(prog):
    return CV.PROGRAMS[prog][1] if prog else []


def new_ws(name, prog, label):
    return [{"do": "action", "action": "workspace.newAtBottom", "title": f"set-up: a new workspace ({label})"},
            {"do": "adopt_pane", "as": name}, {"do": "neutral_prompt"}] + run(prog)


def split(frm, action, name, prog):
    return [X.focus(frm), {"do": "action", "action": action, "title": f"set-up: {action} from {frm} ({name})"},
            {"do": "adopt_pane", "as": name}, {"do": "neutral_prompt"}] + run(prog)


def film(name, closed, survivors):
    texts = lambda tag: [{"do": "cv_text", "pane": p, "film": name, "tag": f"{tag}{i}", "title": f"screen text of {p} ({tag})"}
                         for i, p in enumerate(survivors)]
    return [G.settle(1.0)] + texts("before") + [X.focus(closed), G.settle(0.8),
            {"do": "video_start", "name": name, "seconds": 5.0, "mbps": 24, "rows": [], "columns": [], "require_hz": 120,
             "lead": 0.8, "title": f"start the 120 Hz movie {name}"},
            G.settle(0.4),
            {"do": "cp_close", "film": name, "i": 0, "key": "w", "modifiers": ["cmd"], "rest": 1.4, "title": f"Cmd-W ({name})"},
            G.kit_record_stop(name, 0.3)] + texts("after")


def film_mouse(name, closed, focus, survivors):
    """A mouse close of CLOSED while FOCUS keeps the focus: a click on CLOSED's tab x (cp_click_close)."""
    texts = lambda tag: [{"do": "cv_text", "pane": p, "film": name, "tag": f"{tag}{i}", "title": f"screen text of {p} ({tag})"}
                         for i, p in enumerate(survivors)]
    return [G.settle(1.0)] + texts("before") + [X.focus(focus), G.settle(0.8),
            {"do": "video_start", "name": name, "seconds": 5.0, "mbps": 24, "rows": [], "columns": [], "require_hz": 120,
             "lead": 0.8, "title": f"start the 120 Hz movie {name}"},
            G.settle(0.4),
            {"do": "cp_click_close", "film": name, "i": 0, "pane": closed, "rest": 1.4, "title": f"click the x of {closed} ({name})"},
            G.kit_record_stop(name, 0.3)] + texts("after")


def label(progs):
    progs = [p for p in progs if p]
    modes = []
    for p in progs:
        if MODE[p] not in modes:
            modes.append(MODE[p])
    return "-".join(progs), "-".join(sorted(modes))


def layout(key, ms):
    """Steps, films ([(scenario, film name, survivors' programs)]), seconds."""
    k = key.lower()
    def nm(s, progs):
        p, m = label(progs)
        return f"cl-{s.lower()}-{p}-v0-{ms}", p, m
    out = []
    if key == "R2":      # 2 stacked, close top: the survivor grows up. One ALT film, one MAIN film.
        for prog in ("nvim", "zsh"):
            a, x = f"{k}-{prog}", f"{k}-{prog}-x"
            n, p, m = nm("R2", [prog])
            out.append((new_ws(a, prog, f"R2 {prog}") + split(a, "splitUp", x, None) + film(n, x, (a,)), ("R2", n, p, m), 16))
    elif key == "R2b":   # 2 stacked, close bottom
        for prog in ("nvim", "zsh"):
            a, x = f"{k}-{prog}", f"{k}-{prog}-x"
            n, p, m = nm("R2b", [prog])
            out.append((new_ws(a, prog, f"R2b {prog}") + split(a, "splitDown", x, None) + film(n, x, (a,)), ("R2b", n, p, m), 16))
    elif key == "R3":    # 3 stacked, close middle: both neighbours grow vertically
        t, b, x = "r3-t", "r3-b", "r3-x"
        n, p, m = nm("R3", ["nvim", "zsh"])
        s = new_ws(t, "nvim", "R3") + split(t, "splitDown", b, "zsh") + split(t, "splitDown", x, None) + film(n, x, (t, b))
        out.append((s, ("R3", n, p, m), 20))
    elif key == "C2":    # 2 columns, close left and close right (MAIN survivor; S1 has the ALT ones)
        for side, act in (("C2L", "splitLeft"), ("C2R", "splitRight")):
            a, x = f"{side.lower()}-zsh", f"{side.lower()}-x"
            n, p, m = nm(side, ["zsh"])
            out.append((new_ws(a, "zsh", side) + split(a, act, x, None) + film(n, x, (a,)), (side, n, p, m), 16))
    elif key == "C3":    # 3 columns: close left, middle, right
        for side in ("C3L", "C3M", "C3R"):
            l, r, x = f"{side.lower()}-l", f"{side.lower()}-r", f"{side.lower()}-x"
            s = new_ws(l, "nvim", side) + split(l, "splitRight", r, "zsh")
            s += {"C3L": split(l, "splitLeft", x, None), "C3M": split(l, "splitRight", x, None), "C3R": split(r, "splitRight", x, None)}[side]
            n, p, m = nm(side, ["nvim", "zsh"])
            out.append((s + film(n, x, (l, r)), (side, n, p, m), 20))
    elif key == "G4":    # 2x2, close top-left
        tr, br, bl, x = "g4-tr", "g4-br", "g4-bl", "g4-x"
        s = new_ws(tr, "nvim", "G4") + split(tr, "splitDown", br, "htop") + split(br, "splitLeft", bl, "zsh") + split(tr, "splitLeft", x, None)
        n, p, m = nm("G4", ["nvim", "htop", "zsh"])
        out.append((s + film(n, x, (tr, bl, br)), ("G4", n, p, m), 24))
    elif key == "CR":    # a column of 3 stacked next to a full-height column: close the stack's middle, then the full column
        t, b, f, x = "cr-t", "cr-b", "cr-f", "cr-x"
        s = new_ws(t, "nvim", "CR") + split(t, "splitRight", f, None) + split(t, "splitDown", b, "zsh") + split(t, "splitDown", x, None)
        n1, p, m = nm("CR1", ["nvim", "zsh"])
        n2 = n1.replace("cl-cr1-", "cl-cr2-")
        s += film(n1, x, (t, b, f)) + film(n2, f, (t, b))
        out.append((s, ("CR1", n1, p, m), 22))
        out.append(([], ("CR2", n2, p, m), 10))
    elif key == "RC":    # a row of 3 columns over a full-width pane: close the row's middle, then the full-width pane
        l, r, b, x = "rc-l", "rc-r", "rc-b", "rc-x"
        s = new_ws(l, "nvim", "RC") + split(l, "splitDown", b, None) + split(l, "splitRight", r, "zsh") + split(l, "splitRight", x, None)
        n1, p, m = nm("RC1", ["nvim", "zsh"])
        n2 = n1.replace("cl-rc1-", "cl-rc2-")
        s += film(n1, x, (l, r, b)) + film(n2, b, (l, r))
        out.append((s, ("RC1", n1, p, m), 22))
        out.append(([], ("RC2", n2, p, m), 10))
    elif key == "CC":    # columns mode (newColumn): close a middle column, then an end column; widths never change
        a, c, x = "cc1-a", "cc1-c", "cc1-x"
        n, p, m = nm("CC1", ["nvim", "zsh"])
        s = new_ws(a, "nvim", "CC1") + split(a, "newColumn", x, None) + split(x, "newColumn", c, "zsh") + film(n, x, (a, c))
        out.append((s, ("CC1", n, p, m), 20))
        a, c, x = "cc2-a", "cc2-c", "cc2-x"
        n, p, m = nm("CC2", ["nvim", "zsh"])
        s = new_ws(a, "nvim", "CC2") + split(a, "newColumn", c, "zsh") + split(c, "newColumn", x, None) + film(n, x, (a, c))
        out.append((s, ("CC2", n, p, m), 20))
    elif key == "MOUSE":  # one mouse close of an unfocused pane per layout (m61)
        def mouse(scen, steps, closed, focus, survivors, progs, sec):
            n, p, m = nm(scen, progs)
            out.append((steps + film_mouse(n, closed, focus, survivors), (scen, n, p, m), sec))
        a, x = "m-r2-a", "m-r2-x"
        mouse("R2-mouse", new_ws(a, "zsh", "R2 mouse") + split(a, "splitUp", x, None), x, a, (a,), ["zsh"], 16)
        a, x = "m-r2b-a", "m-r2b-x"
        mouse("R2b-mouse", new_ws(a, "zsh", "R2b mouse") + split(a, "splitDown", x, None), x, a, (a,), ["zsh"], 16)
        t, b, x = "m-r3-t", "m-r3-b", "m-r3-x"
        mouse("R3-mouse", new_ws(t, "nvim", "R3 mouse") + split(t, "splitDown", b, "zsh") + split(t, "splitDown", x, None),
              x, b, (t, b), ["nvim", "zsh"], 20)
        l, r, x = "m-c3-l", "m-c3-r", "m-c3-x"
        mouse("C3M-mouse", new_ws(l, "nvim", "C3M mouse") + split(l, "splitRight", r, "zsh") + split(l, "splitRight", x, None),
              x, r, (l, r), ["nvim", "zsh"], 20)
        tr, br, bl, x = "m-g4-tr", "m-g4-br", "m-g4-bl", "m-g4-x"
        mouse("G4-mouse", new_ws(tr, "nvim", "G4 mouse") + split(tr, "splitDown", br, "htop") + split(br, "splitLeft", bl, "zsh")
              + split(tr, "splitLeft", x, None), x, br, (tr, bl, br), ["nvim", "htop", "zsh"], 24)
        t, b, f, x = "m-cr-t", "m-cr-b", "m-cr-f", "m-cr-x"
        mouse("CR-mouse", new_ws(t, "nvim", "CR mouse") + split(t, "splitRight", f, None) + split(t, "splitDown", b, "zsh")
              + split(t, "splitDown", x, None), x, f, (t, b, f), ["nvim", "zsh"], 22)
        l, r, b, x = "m-rc-l", "m-rc-r", "m-rc-b", "m-rc-x"
        mouse("RC-mouse", new_ws(l, "nvim", "RC mouse") + split(l, "splitDown", b, None) + split(l, "splitRight", r, "zsh")
              + split(l, "splitRight", x, None), x, b, (l, r, b), ["nvim", "zsh"], 22)
        a, c, x = "m-cc-a", "m-cc-c", "m-cc-x"
        mouse("CC-mouse", new_ws(a, "nvim", "CC mouse") + split(a, "newColumn", x, None) + split(x, "newColumn", c, "zsh"),
              x, c, (a, c), ["nvim", "zsh"], 20)
    else:
        raise SystemExit(f"unknown layout {key}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    ap.add_argument("--layouts", default="R2,R2b,R3,C2,C3,G4,CR,RC")
    ap.add_argument("--ms", type=int, default=150)
    ap.add_argument("--tag", default="l")
    o = ap.parse_args()
    parts = [x for key in o.layouts.split(",") for x in layout(key, o.ms)]
    groups, cur, used = [], [], 45.0
    for p in parts:
        if cur and used + p[2] > 225 and p[0]:
            groups.append(cur)
            cur, used = [], 45.0
        cur.append(p)
        used += p[2]
    groups.append(cur)
    index = []
    for gi, g in enumerate(groups):
        jid = f"cv-{o.tag}-{gi + 1}"
        check = [{"do": "type", "text": "echo cv-ready-${nonce}", "enter": True, "mark": "ready"},
                 {"do": "expect", "title": "set-up check: the app types", "since": "ready", "timeout": 10,
                  "all": [{"daemon_line": "cv-ready-${nonce}"}, {"app_text_line": "cv-ready-${nonce}"}, {"frame_text": "cv-ready-${nonce}"}]}]
        steps = G.first_pane(jid, False) + check + [X.fixture_settings()] + X.fixture_files() + CV.FILES
        films = []
        for s, (scen, name, prog, mode), sec in g:
            steps += s
            films.append({"film": name, "scenario": scen, "program": prog, "mode": mode, "variant": "V0", "ms": o.ms,
                          "curve": "bezier", "journey": jid})
        est = 45 + sum(x[2] for x in g)
        spec = {"id": jid, "priority": "P1", "title": f"CLOSE LAYOUTS V0: {', '.join(f['film'] for f in films)}",
                "why": "cmux-ad m61 (Lawrence 2026-11-08): close films for every layout shape.",
                "source": "close-perf task kit (video-cases/gen_closelayouts.py)", "budget_seconds": int(min(255, max(135, est + 20))),
                "recordings": [f["film"] for f in films], "options": {"key_path": "real"}, "steps": steps,
                "finally": [X.settings_back()]}
        with open(os.path.join(o.out, f"{jid}.json"), "w") as f:
            json.dump(spec, f, indent=1)
            f.write("\n")
        index += films
        print(jid, est, len(films), [f["film"] for f in films])
    with open(os.path.join("/work/wt/close-perf-tools/cv", f"cv-{o.tag}.films.json"), "w") as f:
        json.dump(index, f, indent=1)


if __name__ == "__main__":
    main()
