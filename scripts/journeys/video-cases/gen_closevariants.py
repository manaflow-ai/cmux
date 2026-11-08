#!/usr/bin/env python3
"""CLOSE VARIANTS films (cmux-ad m57/m58): one Cmd-W pane close per film, the variant chosen per film through the
film-only selector of branch close-variants/film-selector-nomerge (debug.close_variant). Survivors run real TUIs (ALT and
MAIN screen). Local kit only (never pushed).

  gen_closevariants.py [--out DIR] [--variants V0,V1,V3] [--scen S1,S3,S6] [--ms 150] [--curve bezier]
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cases as G  # noqa: E402
import gen_pixel as X  # noqa: E402

LINES = "\n".join(["#!/bin/sh", "i=1", "while [ $i -le 80 ]; do",
                   "  echo \"line $i: the quick brown fox jumps over the lazy dog; this long line wraps at the pane edge, "
                   "so a resize re-wraps it (close-variants film, non-private text) $i\"", "  i=$((i+1))", "done", ""])
LONG = "\n".join(f"{i:03d} " + ("nvim long line with wrap on: the quick brown fox jumps over the lazy dog. " * 4) for i in range(1, 121)) + "\n"
CLAUDE = "\n".join(["#!/bin/sh", "cd /tmp/cv-repo || exit 1",
                    "export CLAUDE_CONFIG_DIR=/tmp/cv-claude ANTHROPIC_BASE_URL=http://100.89.225.106:31415 "
                    "ANTHROPIC_AUTH_TOKEN=film-dummy DISABLE_AUTOUPDATER=1 PATH=/opt/homebrew/bin:$PATH",
                    "exec claude", ""])
CLAUDE_CFG = json.dumps({"hasCompletedOnboarding": True, "theme": "dark", "numStartups": 5, "projects": {
    p: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True} for p in ("/tmp/cv-repo", "/private/tmp/cv-repo")}})

FILES = [{"do": "file", "path": "/tmp/cv-lines.sh", "text": LINES, "title": "set-up: the long-lines script"},
         {"do": "file", "path": "/tmp/cv-long.txt", "text": LONG, "title": "set-up: the nvim long-lines file"},
         {"do": "file", "path": "/tmp/cv-claude.sh", "text": CLAUDE, "title": "set-up: Claude Code launcher (subrouter, per-process env)"},
         {"do": "file", "path": "/tmp/cv-claude/.claude.json", "text": CLAUDE_CFG, "title": "set-up: Claude Code temp config (no onboarding)"},
         {"do": "file", "path": "/tmp/cv-repo/README.md", "text": "# throwaway repo for close-variants films\n", "title": "set-up: throwaway repo"}]

# program -> (screen mode, launch steps typed into the survivor)
def typed(text, wait):
    return [{"do": "type", "text": text, "enter": True, "title": f"set-up: run `{text}`"}, G.settle(wait)]

PROGRAMS = {
    "nvim": ("ALT", typed("PATH=/opt/homebrew/bin:$PATH nvim -u NONE -c 'set wrap number' /tmp/cv-long.txt", 2.0)),
    "htop": ("ALT", typed("/opt/homebrew/bin/htop", 2.0)),
    "claude": ("MAIN", typed("sh /tmp/cv-claude.sh", 6.0) + typed("!sh /tmp/cv-lines.sh", 3.0)),
    "zsh": ("MAIN", typed("sh /tmp/cv-lines.sh", 1.5)),
}


def film(name, variant, ms, curve, closed):
    return [X.focus(closed), {"do": "rpc", "method": "debug.close_variant", "params": {"variant": variant, "ms": ms, "curve": curve},
                              "title": f"film selector: {variant} {ms} ms {curve}"},
            G.settle(0.8),
            {"do": "video_start", "name": name, "seconds": 5.0, "mbps": 24, "rows": [], "columns": [], "require_hz": 120,
             "lead": 0.8, "title": f"start the 120 Hz movie {name}"},
            G.settle(0.4),
            {"do": "cp_close", "film": name, "i": 0, "key": "w", "modifiers": ["cmd"], "rest": 1.4, "title": f"Cmd-W ({name})"},
            G.kit_record_stop(name, 0.3)]


def scen_s1(prog, variants, ms, curve):
    """S1: 2 columns, close the LEFT one; the survivor (right) runs PROG."""
    mode, launch = PROGRAMS[prog]
    sv = f"s1-{prog}"
    steps = [{"do": "action", "action": "workspace.newAtBottom", "title": f"set-up: a new workspace (S1 {prog})"},
             {"do": "adopt_pane", "as": sv}, {"do": "neutral_prompt"}] + launch
    films = []
    for v in variants:
        name = f"cv-s1-{prog}-{v.lower()}-{ms}{'' if curve == 'bezier' else '-' + curve}"
        left = f"{sv}-l{v}"
        steps += [X.focus(sv), {"do": "action", "action": "splitLeft", "title": f"set-up: splitLeft ({left})"},
                  {"do": "adopt_pane", "as": left}, G.settle(1.0)] + film(name, v, ms, curve, left)
        films.append({"film": name, "scenario": "S1", "program": prog, "mode": mode, "variant": v, "ms": ms, "curve": curve})
    return steps, films, 10 + (12 if prog == "claude" else 4) + 11.5 * len(variants)


def scen_s3(variants, ms, curve):
    """S3: 3 columns, close the MIDDLE one; survivors nvim (ALT, left) and zsh long output (MAIN, right)."""
    a, b = "s3-nvim", "s3-zsh"
    steps = [{"do": "action", "action": "workspace.newAtBottom", "title": "set-up: a new workspace (S3)"},
             {"do": "adopt_pane", "as": a}, {"do": "neutral_prompt"}] + PROGRAMS["nvim"][1]
    steps += [X.focus(a), {"do": "action", "action": "splitRight", "title": "set-up: splitRight (S3 right)"},
              {"do": "adopt_pane", "as": b}, {"do": "neutral_prompt"}] + PROGRAMS["zsh"][1]
    films = []
    for v in variants:
        name = f"cv-s3-mix-{v.lower()}-{ms}{'' if curve == 'bezier' else '-' + curve}"
        mid = f"s3-m{v}"
        steps += [X.focus(a), {"do": "action", "action": "splitRight", "title": f"set-up: splitRight ({mid}, the middle)"},
                  {"do": "adopt_pane", "as": mid}, G.settle(1.0)] + film(name, v, ms, curve, mid)
        films.append({"film": name, "scenario": "S3", "program": "nvim+zsh", "mode": "ALT+MAIN", "variant": v, "ms": ms, "curve": curve})
    return steps, films, 20 + 11.5 * len(variants)


def scen_s6(variants, ms, curve):
    """S6: the survivor is a Chromium page (right); close the terminal at its left."""
    sv = "s6-page"
    steps = [{"do": "action", "action": "workspace.newAtBottom", "title": "set-up: a new workspace (S6)"},
             {"do": "adopt_pane", "as": sv}, {"do": "neutral_prompt"},
             {"do": "cm_browser", "pane": sv, "engine": "cef", "bg": "#FFFF00", "settle": 1.0},
             {"do": "cm_close_tab", "pane": sv, "which": "first", "title": "set-up: the terminal tab closed (the page stays)"}, G.settle(0.5)]
    films = []
    for v in variants:
        name = f"cv-s6-cef-{v.lower()}-{ms}{'' if curve == 'bezier' else '-' + curve}"
        left = f"s6-l{v}"
        steps += [X.focus(sv), {"do": "action", "action": "splitLeft", "title": f"set-up: splitLeft ({left})"},
                  {"do": "adopt_pane", "as": left}, {"do": "neutral_prompt"}, G.settle(1.0)] + film(name, v, ms, curve, left)
        films.append({"film": name, "scenario": "S6", "program": "Chromium page", "mode": "PAGE", "variant": v, "ms": ms, "curve": curve})
    return steps, films, 14 + 11.5 * len(variants)


def journey(jid, parts):
    check = [{"do": "type", "text": "echo cv-ready-${nonce}", "enter": True, "mark": "ready"},
             {"do": "expect", "title": "set-up check: the app types", "since": "ready", "timeout": 10,
              "all": [{"daemon_line": "cv-ready-${nonce}"}, {"app_text_line": "cv-ready-${nonce}"}, {"frame_text": "cv-ready-${nonce}"}]}]
    steps = G.first_pane(jid, False) + check + [X.fixture_settings()] + FILES
    est, films = 45.0, []
    for s, f, sec in parts:
        steps += s
        films += f
        est += sec
    return {"id": jid, "priority": "P1", "title": f"CLOSE VARIANTS: {', '.join(x['film'] for x in films)}",
            "why": "cmux-ad m57/m58 (Lawrence 2026-11-07): films of close-motion variants to pick from.",
            "source": "close-perf task kit (video-cases/gen_closevariants.py)", "budget_seconds": int(min(255, max(135, est))),
            "recordings": [x["film"] for x in films], "options": {"key_path": "real"}, "steps": steps,
            "finally": [X.settings_back()]}, films, est


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    ap.add_argument("--variants", default="V0,V1,V3")
    ap.add_argument("--scen", default="S1,S3,S6")
    ap.add_argument("--programs", default="nvim,htop,claude,zsh")
    ap.add_argument("--ms", type=int, default=150)
    ap.add_argument("--curve", default="bezier")
    ap.add_argument("--tag", default="a")
    o = ap.parse_args()
    vs = o.variants.split(",")
    parts = []
    if "S1" in o.scen:
        parts += [scen_s1(p, vs, o.ms, o.curve) for p in o.programs.split(",")]
    if "S3" in o.scen:
        parts.append(scen_s3(vs, o.ms, o.curve))
    if "S6" in o.scen:
        parts.append(scen_s6(vs, o.ms, o.curve))
    groups, cur, used = [], [], 45.0
    for p in parts:
        if cur and used + p[2] > 250:
            groups.append(cur)
            cur, used = [], 45.0
        cur.append(p)
        used += p[2]
    groups.append(cur)
    index = []
    for gi, g in enumerate(groups):
        jid = f"cv-{o.tag}-{gi + 1}"
        spec, films, est = journey(jid, g)
        with open(os.path.join(o.out, f"{jid}.json"), "w") as f:
            json.dump(spec, f, indent=1)
            f.write("\n")
        index += [dict(x, journey=jid) for x in films]
        print(jid, int(est), len(films), [x["film"] for x in films])
    with open(os.path.join("/work/wt/close-perf-tools/cv", f"cv-{o.tag}.films.json"), "w") as f:
        json.dump(index, f, indent=1)


if __name__ == "__main__":
    main()
