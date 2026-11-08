#!/usr/bin/env python3
"""ZOOM VARIANTS films (cmux-ad m64/m65, task zoom-variants): Toggle Pane Zoom (Cmd-Shift-Enter, a REAL HID key through
CuaDriver: cp_close with key return + cmd/shift) per variant and curve of the film-only selector of branch
zoom-variants/film-selector-nomerge (`debug.frames` action `zoom_variant <V> <K>`). One journey = one layout and one pass
(VIEW: the default dark theme, m65; MEASURE: the detector colours) and every variant/curve in VARIANTS; per variant two
targets (the ALT pane: nvim, the MAIN pane: Claude Code), each zoomed IN, then OUT. The other panes run real programs.
MEASURE films read the Claude Code pane's screen text before and after (duplicated or lost lines). Local kit only
(never pushed).

  gen_zoomvariants.py [--layouts C2,C3,R3,G4] [--variants V0:CUR,Z1:instant,Z2:K2,...] [--passes view,meas] [--tag z]
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

LABELS = {"CUR": "current zoom spring", "instant": "instant", "K1": "bezier 0.2,0,0,1 80 ms", "K2": "bezier 0.2,0,0,1 100 ms",
          "K3": "bezier 0.2,0,0,1 120 ms", "K4": "bezier 0.22,1,0.36,1 100 ms", "K5": "bezier 0.65,0,0.35,1 120 ms",
          "K6": "spring 0.15 s damping 1", "K7": "spring 0.18 s damping 0.9", "K8": "spring 0.2 s damping 0.8",
          "K9": "spring 0.25 s damping 0.7", "K10": "linear 100 ms",
          "K11": "spring 0.12 s damping 1", "K12": "spring 0.2 s damping 1 (= CUR)"}
VNAMES = {"Z4": "grow and fade", "V0": "current", "Z1": "instant", "Z2": "grow", "Z3": "others slide out"}
# m68 (no bounce): K8/K9 dropped; K7 overshoots 1.4 pt on 900 pt (damping 0.9), dropped; CUR is K12 (critically damped
# 0.2 s), so Z4 films K12 once.
SETS = {"z4": ("C3,R3,G4P,CR", "Z4:K2,Z4:K6,Z4:K11,Z4:K12,V0:CUR")}
DEFAULT = "V0:CUR,Z1:instant,Z2:K2,Z2:K6,Z2:K8,Z3:K2,Z3:K6,Z3:K8"
MODE = {"nvim": "ALT", "htop": "ALT", "claude": "MAIN", "zsh": "MAIN", "chromium": "PAGE", "webkit": "PAGE"}
# PAGE films only V0 and Z1: the Z2/Z3 picture copies are layers of the window; a Chromium or WebKit page draws in its own
# view or window, which the copies and masks do not hold (ScreenContentView+FilmZoom.swift).
PAGE_VARIANTS = ("V0", "Z1")
HOLD = ""  # set by --hold-note: the hold the build has (m66: "1-tick hold" until the shared hold lands)
RESET = {"do": "rpc", "method": "debug.frames", "params": {"action": "zoom_variant V0 K2"}, "title": "clean-up: the zoom selector back to V0"}


def modes(progs):
    if MODE[progs[0]] == "PAGE":
        return "PAGE"
    out = []
    for p in progs:
        if MODE[p] != "PAGE" and MODE[p] not in out:
            out.append(MODE[p])
    return "-".join(sorted(out))


def layout(key, view=True):
    """Workspaces of KEY: [(steps, [(target pane, programs: target first)])], seconds of set-up."""
    k = key.lower()
    if key == "PAGE":  # 2 columns: zoom the left pane, a page (Chromium, then WebKit); the right runs nvim
        out = []
        for engine, prog in (("cef", "chromium"), ("webkit", "webkit")):
            l, r = f"page-{engine}-l", f"page-{engine}-r"
            s = CL.new_ws(l, None, f"PAGE {engine}") + CL.split(l, "splitRight", r, "nvim")
            s += [{"do": "cm_browser", "pane": l, "engine": engine, "bg": "#1E1F22" if view else "#FFFF00",
                   "title": f"set-up: a {prog} page in {l} ({'dark' if view else 'detector yellow'})"}]
            out.append((s, [(l, [prog, "nvim"])]))
        return out, 30
    if key == "C2":    # 2 columns: zoom the left (nvim; the right runs Claude Code), then the right (Claude Code)
        l, r = "c2-l", "c2-r"
        s = CL.new_ws(l, "nvim", "C2") + CL.split(l, "splitRight", r, "claude")
        return [(s, [(l, ["nvim", "claude"]), (r, ["claude", "nvim"])])], 22
    if key in ("C3", "R3"):  # 3 columns (3 stacked): zoom the middle one
        act = "splitRight" if key == "C3" else "splitDown"
        out = []
        for tgt, a, b in (("nvim", "htop", "zsh"), ("claude", "nvim", "htop")):
            first, mid, last = f"{k}-{tgt}-1", f"{k}-{tgt}-m", f"{k}-{tgt}-3"
            s = CL.new_ws(first, a, f"{key} {tgt}") + CL.split(first, act, last, b) + CL.split(first, act, mid, tgt)
            out.append((s, [(mid, [tgt, a, b])]))
        return out, 38
    if key == "G4P":   # 2x2, a Chromium page top-right among the fading panes (m66): zoom the top-left
        out = []
        for tgt, b, c in (("nvim", "zsh", "htop"), ("claude", "nvim", "htop")):
            tl, tr, bl, br = (f"g4p-{tgt}-{x}" for x in ("tl", "tr", "bl", "br"))
            s = (CL.new_ws(tr, None, f"G4P {tgt}") + CL.split(tr, "splitDown", br, c) + CL.split(br, "splitLeft", bl, b)
                 + CL.split(tr, "splitLeft", tl, tgt)
                 + [{"do": "cm_browser", "pane": tr, "engine": "cef", "bg": "#1E1F22" if view else "#FFFF00",
                     "title": f"set-up: a Chromium page in {tr} ({'dark' if view else 'detector yellow'})"}])
            out.append((s, [(tl, [tgt, "chromium", b, c])]))
        return out, 52
    if key == "CR":    # a column of 3 stacked next to a full-height column: zoom the stack's middle
        out = []
        for tgt, a, b, c in (("nvim", "htop", "zsh", "zsh"), ("claude", "nvim", "htop", "zsh")):
            t, m, bt, f = (f"cr-{tgt}-{x}" for x in ("t", "m", "b", "f"))
            s = (CL.new_ws(t, a, f"CR {tgt}") + CL.split(t, "splitRight", f, c) + CL.split(t, "splitDown", bt, b)
                 + CL.split(t, "splitDown", m, tgt))
            out.append((s, [(m, [tgt, a, b, c])]))
        return out, 46
    if key == "G4":    # 2x2: zoom the top-left
        out = []
        for tgt, a, b, c in (("nvim", "htop", "zsh", "zsh"), ("claude", "nvim", "htop", "zsh")):
            tl, tr, bl, br = (f"g4-{tgt}-{x}" for x in ("tl", "tr", "bl", "br"))
            s = (CL.new_ws(tr, a, f"G4 {tgt}") + CL.split(tr, "splitDown", br, b) + CL.split(br, "splitLeft", bl, c)
                 + CL.split(tr, "splitLeft", tl, tgt))
            out.append((s, [(tl, [tgt, a, b, c])]))
        return out, 46
    raise SystemExit(f"unknown layout {key}")


def film(name, pane, direction, texts):
    reads = lambda tag: ([{"do": "cv_text", "pane": pane, "film": name, "tag": f"{tag}0", "title": f"screen text of {pane} ({tag})"}]
                         if texts else [])
    return [G.settle(0.5)] + reads("before") + [
        {"do": "video_start", "name": name, "seconds": 4.0, "mbps": 24, "rows": [], "columns": [], "require_hz": 120,
         "lead": 0.6, "title": f"start the 120 Hz movie {name}"},
        G.settle(0.3),
        {"do": "cp_close", "film": name, "i": 0, "key": "return", "modifiers": ["cmd", "shift"], "rest": 1.0,
         "title": f"Cmd-Shift-Enter, zoom {direction} ({name}; real HID key)"},
        G.kit_record_stop(name, 0.2)] + reads("after")


def journey(jid, key, view, variants):
    parts, setup = layout(key, view)
    if key == "PAGE":
        variants = [v for v in variants if v[0] in PAGE_VARIANTS]
    check = [{"do": "type", "text": "echo cv-ready-${nonce}", "enter": True, "mark": "ready"},
             {"do": "expect", "title": "set-up check: the app types", "since": "ready", "timeout": 10,
              "all": [{"daemon_line": "cv-ready-${nonce}"}, {"app_text_line": "cv-ready-${nonce}"}, {"frame_text": "cv-ready-${nonce}"}]}]
    steps = G.first_pane(jid, False) + check + X.fixture_files() + CV.FILES + [VIEW_SETTINGS if view else X.fixture_settings()]
    index, n_films = [], 0
    for ws_steps, targets in parts:
        steps += ws_steps + [G.settle(1.0)]
        for variant, curve in variants:
            steps.append({"do": "rpc", "method": "debug.frames", "required": True, "title": f"zoom selector: {variant} on {curve}",
                          "params": {"action": f"zoom_variant {variant} {'K2' if curve == 'instant' else curve}"}})
            for pane, progs in targets:
                for direction in ("in", "out"):
                    p = "v" if view else "m"
                    name = f"zv-{p}-{key.lower()}-{progs[0]}-{variant.lower()}-{curve.lower()}-{direction}"
                    if direction == "in":
                        steps.append(X.focus(pane))
                    steps += film(name, pane, direction, texts=(not view and progs[0] == "claude"))
                    n_films += 1
                    index.append({"film": name, "scenario": ("Z-" if variant == "V0" else "") + key, "program": "-".join(progs),
                                  "mode": modes(progs), "variant": variant, "ms": 0, "curve": "named",
                                  "curve_id": f"{curve}-{direction}", "journey": jid, "zoomed": progs[0], "direction": direction,
                                  "label": f"{variant} {VNAMES[variant]} {LABELS[curve]} | zoom {direction} | {key} zoomed {progs[0]}{HOLD}"})
    est = 50 + setup + n_films * (4.0 if view else 4.6)
    if est > 258:
        raise SystemExit(f"{jid}: {est:.0f} s is more than one lease; give fewer variants")
    spec = {"id": jid, "priority": "P1", "title": f"ZOOM VARIANTS {key} {'VIEW' if view else 'MEASURE'}: "
                                                  f"{', '.join(f'{v}:{c}' for v, c in variants)}",
            "why": "cmux-ad m64/m65 (Lawrence 2026-11-08): zoom variants, films to pick from.",
            "source": "zoom-variants task kit (video-cases/gen_zoomvariants.py)", "budget_seconds": int(min(258, est + 8)),
            "recordings": [f["film"] for f in index], "options": {"key_path": "real"}, "steps": steps,
            "finally": [RESET, X.settings_back()]}
    return spec, index


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    ap.add_argument("--layouts", default="C2,C3,R3,G4,PAGE")
    ap.add_argument("--variants", default=DEFAULT)
    ap.add_argument("--passes", default="view,meas")
    ap.add_argument("--tag", default="z")
    ap.add_argument("--films-dir", default="/work/wt/close-perf-tools/zoom/cv")
    ap.add_argument("--set", default="", help="a named film set (z4: m66 layouts and curves)")
    ap.add_argument("--hold-note", default="")
    o = ap.parse_args()
    global HOLD
    HOLD = f" | {o.hold_note}" if o.hold_note else ""
    if o.set:
        o.layouts, o.variants = SETS[o.set]
        o.tag = o.set
    variants = [tuple(x.split(":")) for x in o.variants.split(",") if x]
    for kind in o.passes.split(","):
        idx_all = []
        for key in o.layouts.split(","):
            jid = f"zv-{o.tag}-{key.lower()}-{kind}"
            spec, idx = journey(jid, key, kind == "view", variants)
            with open(os.path.join(o.out, f"{jid}.json"), "w") as fh:
                json.dump(spec, fh, indent=1)
                fh.write("\n")
            idx_all += idx
            print(jid, spec["budget_seconds"], len(spec["recordings"]))
        with open(os.path.join(o.films_dir, f"zv-{o.tag}-{kind}.films.json"), "w") as fh:
            json.dump(idx_all, fh, indent=1)


if __name__ == "__main__":
    main()
