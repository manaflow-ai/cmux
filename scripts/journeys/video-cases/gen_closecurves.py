#!/usr/bin/env python3
"""CLOSE CURVES films (cmux-ad m62/m63/m64): V0 (the build's own close) with the close spring set per film through the
`motion.spring.split` tunable (a pane close takes the split spring, PaneMotionVariant.standard). Layouts S1 (2 columns,
close left) and R2 (2 stacked, close top); survivors nvim (ALT) and Claude Code (MAIN); the closing pane runs zsh with
output. Each journey films one curve twice: a VIEW pass (default theme, no detector colours) and then a MEASURE pass
(detector colours). The bezier curves (K1-K5, K10) have no V0 path in the app; only the springs are filmed here.
Local kit only (never pushed).

  gen_closecurves.py [--curves K6,K8,CUR,K7,K9] [--tag k]
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

CURVES = {  # m63: id -> (response s, damping, label)
    "K6": (0.15, 1.0, "K6 spring critical, response 0.15 s"),
    "K7": (0.18, 0.9, "K7 spring damping 0.9, response 0.18 s"),
    "K8": (0.2, 0.8, "K8 spring damping 0.8, response 0.2 s"),
    "K9": (0.25, 0.7, "K9 spring damping 0.7, response 0.25 s"),
    "CUR": (None, None, "current split spring (0.23 s, damping 0.95)"),
}
MODE = {"nvim": "ALT", "claude": "MAIN"}
VIEW_SETTINGS = {"do": "settings_file", "title": "set-up: VIEW pass: the default theme, no close warning, no hover cards",
                 "set": {"sidebar": {"hoverCards": {"enabled": False}}, "app": {"warnBeforeClosingTab": False},
                         "appearance": {"appTheme": "followTerminal"}},
                 "unset": ["appearance.theme", "appearance.themeEdits", "appearance.surfaces"]}


def films(curve, tag, view):
    steps, index = [], []
    for scen, act in (("S1", "splitLeft"), ("R2", "splitUp")):
        for prog in ("nvim", "claude"):
            p = "v" if view else "m"
            a, x = f"{p}-{curve.lower()}-{scen.lower()}-{prog}", f"{p}-{curve.lower()}-{scen.lower()}-{prog}-x"
            name = f"cl-{curve.lower()}-{scen.lower()}-{prog}-{'view' if view else 'meas'}"
            steps += CL.new_ws(a, prog, f"{curve} {scen} {prog}") + CL.split(a, act, x, "zsh") + CL.film(name, x, (a,))
            index.append({"film": name, "scenario": scen, "program": prog, "mode": MODE[prog], "variant": "V0", "ms": 0,
                          "curve": "spring", "curve_id": curve, "journey": tag,
                          "label": f"V0 {scen} {CURVES[curve][2]}"})
    return steps, index


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    ap.add_argument("--curves", default="K6,K8,CUR,K7,K9")
    ap.add_argument("--tag", default="k")
    o = ap.parse_args()
    view_idx, meas_idx = [], []
    for curve in o.curves.split(","):
        jid = f"cv-{o.tag}-{curve.lower()}"
        response, damping, _ = CURVES[curve]
        tune = [{"do": "px_tunable", "key": "motion.spring.split", "required": True,
                 "value": None if response is None else {"response": response, "dampingFraction": damping},
                 "title": f"the close spring for {curve}"}]
        check = [{"do": "type", "text": "echo cv-ready-${nonce}", "enter": True, "mark": "ready"},
                 {"do": "expect", "title": "set-up check: the app types", "since": "ready", "timeout": 10,
                  "all": [{"daemon_line": "cv-ready-${nonce}"}, {"app_text_line": "cv-ready-${nonce}"}, {"frame_text": "cv-ready-${nonce}"}]}]
        v_steps, v_idx = films(curve, jid, True)
        m_steps, m_idx = films(curve, jid, False)
        steps = (G.first_pane(jid, False) + check + [VIEW_SETTINGS] + X.fixture_files() + CV.FILES + tune + v_steps
                 + [X.fixture_settings()] + m_steps)
        spec = {"id": jid, "priority": "P1", "title": f"CLOSE CURVES V0 {curve}: S1/R2 x nvim/Claude Code, VIEW then MEASURE",
                "why": "cmux-ad m62/m63/m64 (Lawrence 2026-11-08): close curves, VIEW and MEASURE passes.",
                "source": "close-perf task kit (video-cases/gen_closecurves.py)", "budget_seconds": 255,
                "recordings": [f["film"] for f in v_idx + m_idx], "options": {"key_path": "real"}, "steps": steps,
                "finally": [{"do": "px_tunable", "key": "motion.spring.split", "value": None, "title": "clean-up: the close spring back"},
                            X.settings_back()]}
        with open(os.path.join(o.out, f"{jid}.json"), "w") as f:
            json.dump(spec, f, indent=1)
            f.write("\n")
        view_idx += v_idx
        meas_idx += m_idx
        print(jid, [f["film"] for f in v_idx + m_idx])
    for kind, idx in (("view", view_idx), ("meas", meas_idx)):
        with open(os.path.join("/work/wt/close-perf-tools/cv", f"cv-{o.tag}-{kind}.films.json"), "w") as f:
            json.dump(idx, f, indent=1)


if __name__ == "__main__":
    main()
