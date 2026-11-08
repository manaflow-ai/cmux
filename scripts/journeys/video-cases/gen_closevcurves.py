#!/usr/bin/env python3
"""CLOSE VARIANTS 2 curve films (cmux-ad m62-m65): each journey films one variant on one named curve of the CURVE SET
(K1-K10) through the film-only selector of branch close-variants/film-selector-nomerge (`debug.frames` action
`close_variant <V> <K>`). V0/V2 move the pane frames on the curve; V3/V4/V5 move the old picture on it; V1 is instant.
Layouts S1 (2 columns, close left) and R2 (2 stacked, close top); survivors nvim (ALT) and Claude Code (MAIN); the
closing pane runs zsh with output. A VIEW pass (default dark theme, m65) and then a MEASURE pass (detector colours).
After every close the journey reads the selector once: its answer carries the fork's grid counters for that close.
`--accept` makes the short acceptance journey instead: S1 nvim and htop, MEASURE pass only, for the given variants.
Local kit only (never pushed).

  gen_closevcurves.py --set V3:K2,V3:K6 [--tag f]
  gen_closevcurves.py --accept V1:K2,V3:K6 [--tag f]
  gen_closevcurves.py --v6stack K2 --tag s
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
import gen_closelayouts as CL  # noqa: E402
from gen_closecurves import VIEW_SETTINGS  # noqa: E402

LABELS = {"K1": "bezier 0.2,0,0,1 80 ms", "K2": "bezier 0.2,0,0,1 100 ms", "K3": "bezier 0.2,0,0,1 120 ms",
          "K4": "bezier 0.22,1,0.36,1 100 ms", "K5": "bezier 0.65,0,0.35,1 120 ms", "K6": "spring 0.15 s damping 1",
          "K7": "spring 0.18 s damping 0.9", "K8": "spring 0.2 s damping 0.8", "K9": "spring 0.25 s damping 0.7",
          "K10": "linear 100 ms", "CUR": "spring 0.23 s damping 0.95 (current)", "K11": "spring 0.12 s damping 1", "K12": "spring 0.2 s damping 1"}
MODE = {"nvim": "ALT", "claude": "MAIN", "htop": "ALT"}
RESET = {"do": "rpc", "method": "debug.frames", "params": {"action": "close_variant V0 nocurve 150 bezier"},
         "title": "clean-up: the film selector back to V0"}


def read(name):
    return {"do": "rpc", "method": "debug.frames", "params": {"action": "close_variant"},
            "title": f"read the selector and the fork's grid counters after {name}"}


def films(variant, curve, tag, view, layouts, progs):
    steps, index = [], []
    for scen, act in layouts:
        for prog in progs:
            p = "v" if view else "m"
            base = f"{p}-{variant.lower()}{curve.lower()}-{scen.lower()}-{prog}"
            name = f"cf-{variant.lower()}-{curve.lower()}-{scen.lower()}-{prog}-{'view' if view else 'meas'}"
            steps += CL.new_ws(base, prog, f"{variant} {curve} {scen} {prog}") + CL.split(base, act, base + "-x", "zsh")
            steps += CL.film(name, base + "-x", (base,)) + [read(name)]
            index.append({"film": name, "scenario": scen, "program": prog, "mode": MODE[prog], "variant": variant, "ms": 0,
                          "curve": "named", "curve_id": curve, "journey": tag,
                          "label": f"{variant} {curve} {LABELS[curve]} | {scen} {prog}"})
    return steps, index


def v6_films(curve, tag, view, layouts):
    """m67 V6 layouts: S1 (close left) and R2 (close top) once per survivor program; R3 (close middle: nvim above,
    Claude Code below) and G4 (2x2, close top-left: nvim, zsh, Claude Code) with both programs at once."""
    steps, index = [], []
    pv = "v" if view else "m"
    for scen in layouts:
        sets = [("nvim",), ("claude",)] if scen in ("S1", "R2") else [("nvim", "claude")]
        for progs in sets:
            ptag = "-".join(progs)
            base = f"{pv}-v6{curve.lower()}-{scen.lower()}-{ptag}"
            name = f"cf-v6-{curve.lower()}-{scen.lower()}-{ptag}-{'view' if view else 'meas'}"
            if scen in ("S1", "R2"):
                a, x = base, base + "-x"
                s = CL.new_ws(a, progs[0], f"V6 {curve} {scen} {ptag}") + CL.split(a, "splitLeft" if scen == "S1" else "splitUp", x, "zsh")
                surv = (a,)
            elif scen == "R3":
                t, b, x = base + "-t", base + "-b", base + "-x"
                s = (CL.new_ws(t, "nvim", f"V6 {curve} R3") + CL.split(t, "splitDown", b, "claude")
                     + CL.split(t, "splitDown", x, "zsh"))
                surv = (t, b)
            else:
                tr, br, bl, x = base + "-tr", base + "-br", base + "-bl", base + "-x"
                s = (CL.new_ws(tr, "nvim", f"V6 {curve} G4") + CL.split(tr, "splitDown", br, "claude")
                     + CL.split(br, "splitLeft", bl, None) + CL.split(tr, "splitLeft", x, "zsh"))
                surv = (tr, bl, br)
            steps += s + CL.film(name, x, surv) + [read(name)]
            mode = "+".join(dict.fromkeys(MODE[p] for p in progs))
            index.append({"film": name, "scenario": scen, "program": ptag, "mode": mode, "variant": "V6", "ms": 0,
                          "curve": "named", "curve_id": curve, "journey": tag,
                          "label": f"V6 {curve} {LABELS[curve]} | {scen} {ptag}"})
    return steps, index


def v6_stack_films(curve, tag, view):
    """m67 V6 stacked closes: a stack of nvim, three zsh panes and Claude Code. RS3: the three zsh panes closed in turn, one
    film each (a, b, c), so nvim and Claude Code grow three times. RQ3: a new stack, three Cmd-W 70 ms apart in one film
    (the focus starts on the middle zsh pane); each fading picture keeps its own progress."""
    steps, index = [], []
    pv, kind = ("v" if view else "m"), ("view" if view else "meas")
    def stack(base, label):
        t, c, x1, x2, x3 = (base + s for s in ("-t", "-c", "-x1", "-x2", "-x3"))
        s = (CL.new_ws(t, "nvim", label) + CL.split(t, "splitDown", c, "claude") + CL.split(t, "splitDown", x1, "zsh")
             + CL.split(x1, "splitDown", x2, "zsh") + CL.split(x2, "splitDown", x3, "zsh"))
        return s, t, c, (x1, x2, x3)
    base = f"{pv}-v6{curve.lower()}-rs3"
    s, t, c, xs = stack(base, f"V6 {curve} RS3")
    steps += s
    for n, x in zip("abc", xs):
        name = f"cf-v6-{curve.lower()}-rs3{n}-nvim-claude-{kind}"
        steps += CL.film(name, x, (t, c)) + [read(name)]
        index.append({"film": name, "scenario": f"RS3{n}", "program": "nvim-claude", "mode": "ALT+MAIN", "variant": "V6", "ms": 0,
                      "curve": "named", "curve_id": curve, "journey": tag,
                      "label": f"V6 {curve} {LABELS[curve]} | RS3 close {'123'['abc'.index(n)]} of 3 nvim-claude"})
    base = f"{pv}-v6{curve.lower()}-rq3"
    s, t, c, xs = stack(base, f"V6 {curve} RQ3")
    name = f"cf-v6-{curve.lower()}-rq3-nvim-claude-{kind}"
    film = CL.film(name, xs[1], (t, c))
    for st in film:
        if st.get("do") == "cp_close":
            st.update({"repeat_after": [0.07, 0.07], "rest": 1.4, "title": f"3 x Cmd-W, 70 ms apart ({name})"})
    steps += s + film + [read(name)]
    index.append({"film": name, "scenario": "RQ3", "program": "nvim-claude", "mode": "ALT+MAIN", "variant": "V6", "ms": 0,
                  "curve": "named", "curve_id": curve, "journey": tag, "label": f"V6 {curve} {LABELS[curve]} | RQ3 3 fast closes nvim-claude"})
    return steps, index


def journey(jid, variant, curve, title, v_parts, m_parts, view_only=False):
    select = {"do": "rpc", "method": "debug.frames", "params": {"action": f"close_variant {variant} {curve}"},
              "title": f"film selector: {variant} on {curve}", "required": True}
    check = [{"do": "type", "text": "echo cv-ready-${nonce}", "enter": True, "mark": "ready"},
             {"do": "expect", "title": "set-up check: the app types", "since": "ready", "timeout": 10,
              "all": [{"daemon_line": "cv-ready-${nonce}"}, {"app_text_line": "cv-ready-${nonce}"}, {"frame_text": "cv-ready-${nonce}"}]}]
    steps = G.first_pane(jid, False) + check + X.fixture_files() + CV.FILES + [select]
    films_all = []
    if v_parts:
        steps += [VIEW_SETTINGS] + v_parts[0]
        films_all += v_parts[1]
    steps += [VIEW_SETTINGS if view_only else X.fixture_settings()] + m_parts[0]
    films_all += m_parts[1]
    return {"id": jid, "priority": "P1", "title": title,
            "why": "cmux-ad m62-m65 (Lawrence 2026-11-08): close variants on the curve set, VIEW and MEASURE passes.",
            "source": "close-perf task kit (video-cases/gen_closevcurves.py)", "budget_seconds": 255,
            "recordings": [f["film"] for f in films_all], "options": {"key_path": "real"}, "steps": steps,
            "finally": [RESET, X.settings_back()]}, films_all


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    ap.add_argument("--set", default="")
    ap.add_argument("--accept", default="")
    ap.add_argument("--tag", default="f")
    ap.add_argument("--v6", default="", help="curves for V6 (m67): CUR,K2,K6,K8")
    ap.add_argument("--layouts", default="S1,R2,R3,G4")
    ap.add_argument("--v6stack", default="", help="curves for V6 RS3 + RQ3 (m67): K2")
    o = ap.parse_args()
    view_idx, meas_idx = [], []
    pairs = [x.split(":") for x in (o.accept or o.set).split(",") if x]
    lays = [x for x in o.layouts.split(",") if x]
    for curve in [c for c in o.v6.split(",") if c]:
        # One lease holds at most 260 s: the VIEW pass and the MEASURE pass are two journeys.
        for kind in ("view", "meas"):
            jid = f"cv-{o.tag}-v6-{curve.lower()}-{kind}"
            part = v6_films(curve, jid, kind == "view", lays)
            spec, _ = journey(jid, "V6", curve, f"CLOSE VARIANTS 2 m67: V6 grow + fade on {curve}, {'/'.join(lays)}, {kind.upper()}",
                              None, part, view_only=kind == "view")
            with open(os.path.join(o.out, f"{jid}.json"), "w") as fh:
                json.dump(spec, fh, indent=1)
                fh.write("\n")
            (view_idx if kind == "view" else meas_idx).extend(part[1])
            print(jid, spec["recordings"])
    for curve in [c for c in o.v6stack.split(",") if c]:
        for kind in ("view", "meas"):
            jid = f"cv-{o.tag}-v6s-{curve.lower()}-{kind}"
            part = v6_stack_films(curve, jid, kind == "view")
            spec, _ = journey(jid, "V6", curve, f"CLOSE VARIANTS 3 m67: V6 RS3 (3 closes in turn) + RQ3 (3 fast closes) on {curve}, {kind.upper()}",
                              None, part, view_only=kind == "view")
            with open(os.path.join(o.out, f"{jid}.json"), "w") as fh:
                json.dump(spec, fh, indent=1)
                fh.write("\n")
            (view_idx if kind == "view" else meas_idx).extend(part[1])
            print(jid, spec["recordings"])
    if o.accept:
        jid = f"cv-{o.tag}-acc"
        steps_all, idx_all = None, []
        spec = None
        for variant, curve in pairs:
            m = films(variant, curve, jid, False, (("S1", "splitLeft"),), ("nvim", "htop"))
            if spec is None:
                spec, f = journey(jid, variant, curve, f"CLOSE VARIANTS 2 acceptance: S1 nvim/htop {o.accept}", None, m)
                idx_all += f
            else:
                spec["steps"] += [{"do": "rpc", "method": "debug.frames", "params": {"action": f"close_variant {variant} {curve}"},
                                   "title": f"film selector: {variant} on {curve}", "required": True}] + m[0]
                spec["recordings"] += [x["film"] for x in m[1]]
                idx_all += m[1]
        with open(os.path.join(o.out, f"{jid}.json"), "w") as fh:
            json.dump(spec, fh, indent=1)
            fh.write("\n")
        meas_idx = idx_all
        print(jid, spec["recordings"])
    for variant, curve in ([] if o.accept else pairs):
        jid = f"cv-{o.tag}-{variant.lower()}-{curve.lower()}"
        lay, progs = (("S1", "splitLeft"), ("R2", "splitUp")), ("nvim", "claude")
        v = films(variant, curve, jid, True, lay, progs)
        m = films(variant, curve, jid, False, lay, progs)
        spec, _ = journey(jid, variant, curve, f"CLOSE VARIANTS 2: {variant} on {curve}, S1/R2 x nvim/Claude Code, VIEW then MEASURE", v, m)
        with open(os.path.join(o.out, f"{jid}.json"), "w") as fh:
            json.dump(spec, fh, indent=1)
            fh.write("\n")
        view_idx += v[1]
        meas_idx += m[1]
        print(jid, spec["recordings"])
    for kind, idx in (("view", view_idx), ("meas", meas_idx)):
        if idx:
            with open(os.path.join("/work/wt/close-perf-tools/cv", f"cv-{o.tag}{'-acc' if o.accept else ''}-{kind}.films.json"), "w") as fh:
                json.dump(idx, fh, indent=1)


if __name__ == "__main__":
    main()
