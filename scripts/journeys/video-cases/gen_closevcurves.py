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
          "K10": "linear 100 ms"}
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


def journey(jid, variant, curve, title, v_parts, m_parts):
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
    steps += [X.fixture_settings()] + m_parts[0]
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
    o = ap.parse_args()
    view_idx, meas_idx = [], []
    pairs = [x.split(":") for x in (o.accept or o.set).split(",") if x]
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
