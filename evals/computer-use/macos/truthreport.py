# SPDX-License-Identifier: MIT
"""truthreport.py: tables from truthmatrix.py rows (truth.jsonl), for RESULTS.md and report.html.

  python3 truthreport.py --in ARM_LABEL=DIR [--in ...] --out OUTDIR [--agent DIR ...] [--video NAME=FILE ...]

Definitions (per scored action; observation-only cells are not scored):
  claim positive  confirmed, delivered, or ok (success without an evidence field)
  claim negative  no_visible_change, error, refused
  TP  positive claim, intended effect, exactly, on the intended target
  FP  positive claim, no effect or the wrong effect (partial, duplicated, wrong element or window); for a cell
      whose right outcome is no effect (a disabled menu item), a positive claim
  FN  negative claim, but the intended effect happened (late effects included, with their delay)
  TN  negative claim, no effect
  SIDE  the intended effect plus a change elsewhere (counted on its own, whatever the claim)
Rates: false-success rate = FP / (TP + FP) (of the times the tool said it worked, how often it had not);
false-failure rate = FN / (FN + TN) (of the times it said it had not worked, how often it had);
side-effect rate = SIDE / scored.
"""

from __future__ import annotations

import argparse
import base64
import html
import json
import os
from collections import Counter, defaultdict

KEYS = ("TP", "FP", "FN", "TN", "SIDE")


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def conf(rows):
    c = Counter(r["outcome"] for r in rows)
    scored = sum(c[k] for k in KEYS)
    pos = c["TP"] + c["FP"]
    neg = c["FN"] + c["TN"]
    return {**{k: c[k] for k in KEYS}, "scored": scored, "no_action": c["no_action"], "unsupported": c["unsupported"],
            "fp_rate": c["FP"] / pos if pos else None, "fn_rate": c["FN"] / neg if neg else None,
            "side_rate": c["SIDE"] / scored if scored else None,
            "effect_rate": (c["TP"] + c["FN"] + c["SIDE"]) / scored if scored else None}


def pct(x):
    return "–" if x is None else f"{100 * x:.0f}%"


def md_table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def conf_row(label, c):
    return [label, c["scored"], c["TP"], c["FP"], c["FN"], c["TN"], c["SIDE"], pct(c["fp_rate"]), pct(c["fn_rate"]),
            pct(c["side_rate"]), pct(c["effect_rate"]), c["no_action"]]


CONF_HEAD = ["", "scored", "TP", "FP", "FN", "TN", "SIDE", "false-success rate", "false-failure rate", "side-effect rate",
             "effect rate", "no action"]


def build(arms, agent_dirs, out, videos):
    os.makedirs(out, exist_ok=True)
    md = []
    data = {}
    # ---- headline per arm
    md.append("### Engine-claim accuracy, every scored action (both scenes, 3 reps)\n")
    md.append(md_table(CONF_HEAD, [conf_row(a, conf(rs)) for a, rs in arms.items()]))
    for scene in ("bg", "fg"):
        md.append(f"\n### Scene {scene} ({'person in front, target covered' if scene == 'bg' else 'target frontmost and key'})\n")
        md.append(md_table(CONF_HEAD, [conf_row(a, conf([r for r in rs if r["scene"] == scene])) for a, rs in arms.items()]))
    md.append("\n### Lab fixture (oracle) vs real apps\n")
    t = []
    for a, rs in arms.items():
        t.append(conf_row(f"{a} lab", conf([r for r in rs if r["app"] == "lab"])))
        t.append(conf_row(f"{a} real apps", conf([r for r in rs if r["app"] != "lab"])))
    md.append(md_table(CONF_HEAD, t))
    # ---- claim kinds
    md.append("\n### What each claim kind meant (claim -> truth)\n")
    rows = []
    for a, rs in arms.items():
        by = defaultdict(Counter)
        for r in rs:
            if r["outcome"] in KEYS:
                by[r["claim"]][r["truth"] if not r.get("expect_none") else ("none (right)" if r["truth"] == "none" else r["truth"])] += 1
        for cl, cnt in sorted(by.items()):
            rows.append([a, cl, sum(cnt.values()), cnt["correct"], cnt["none"] + cnt["none (right)"], cnt["wrong"], cnt["extra"]])
    md.append(md_table(["arm", "claim", "n", "correct", "none", "wrong", "extra"], rows))
    # ---- per app
    md.append("\n### Per app\n")
    apps = sorted({r["app"] for rs in arms.values() for r in rs})
    t = []
    for app in apps:
        for a, rs in arms.items():
            c = conf([r for r in rs if r["app"] == app])
            if c["scored"] or c["no_action"]:
                t.append(conf_row(f"{app} / {a}", c))
    md.append(md_table(CONF_HEAD, t))
    # ---- per action matrix: outcome counts
    md.append("\n### Per action (outcomes over 3 reps; bg | fg)\n")
    acts = []
    for r in (r for rs in arms.values() for r in rs):
        k = (r["app"], r["action"])
        if k not in acts:
            acts.append(k)
    head = ["app", "action"] + list(arms)
    t = []
    for app, act in acts:
        line = [app, act]
        for a, rs in arms.items():
            cells = []
            for scene in ("bg", "fg"):
                cs = Counter(r["outcome"] for r in rs if r["app"] == app and r["action"] == act and r["scene"] == scene)
                cells.append(" ".join(f"{k}{v}" for k, v in sorted(cs.items())) or "–")
            line.append(" \\| ".join(cells))
        t.append(line)
    md.append(md_table(head, t))
    # ---- timing
    md.append("\n### Effect timing (ms from the tool's result; negative = before it returned)\n")
    t = []
    for a, rs in arms.items():
        ms = sorted(r["effect_ms"] for r in rs if r.get("effect_ms") is not None and r["truth"] in ("correct", "extra", "wrong"))
        late = [r for r in rs if r.get("late")]
        fn_late = [r for r in rs if r["outcome"] == "FN"]
        q = lambda p: ms[min(len(ms) - 1, int(p * len(ms)))] if ms else None  # noqa: E731
        t.append([a, len(ms), q(0.05), q(0.5), q(0.95), max(ms) if ms else None, len(late),
                  ", ".join(f"{r['action']}({r['scene']}) {r['effect_ms']}ms" for r in fn_late[:6]) or "–"])
    md.append(md_table(["arm", "effects", "p5", "p50", "p95", "max", "after +500 ms", "FN effects"], t))
    # ---- background safety
    md.append("\n### Background safety (bg scene)\n")
    t = []
    for a, rs in arms.items():
        bg = [r for r in rs if r["scene"] == "bg" and "background_safe" in r and r["outcome"] != "no_action"]
        bad = [r for r in bg if not r["background_safe"]]
        why = Counter()
        for r in bad:
            for k in ("front_ok", "key_ok", "pointer_ok", "keys_ok", "zorder_ok"):
                if not r.get(k):
                    why[k] += 1
            if r.get("fixture_focus_events"):
                why["target app activated"] += 1
        t.append([a, len(bg), len(bg) - len(bad), ", ".join(f"{k} {v}" for k, v in why.items()) or "–"])
    md.append(md_table(["arm", "cells", "background-safe", "violations"], t))
    # ---- silent AX changes
    md.append("\n### Silent changes (value visible, app never notified)\n")
    t = []
    for a, rs in arms.items():
        sil = Counter(r["action"] for r in rs if r.get("silent"))
        t.append([a, sum(sil.values()), ", ".join(f"{k} {v}" for k, v in sil.items()) or "–"])
    md.append(md_table(["arm", "silent", "actions"], t))
    data["arms"] = {a: conf(rs) for a, rs in arms.items()}
    # ---- agent tier
    if agent_dirs:
        import sys
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        from cueval import claims
        ag = []
        for d in agent_dirs:
            p = os.path.join(d, "results.jsonl")
            if os.path.exists(p):
                ag += load(p)
        for r in ag:
            r.update(claims.label_row(r))
        cs = claims.summarize(ag)
        md.append("\n### Agent-claim accuracy\n")
        md.append(md_table(["arm", "n", "success"] + list(claims.LABELS),
                           [[a, d["n"], sum(r["success"] for r in ag if r["arm"] == a)] + [d[k] for k in claims.LABELS]
                            for a, d in sorted(cs.items())]))
        t = []
        for r in ag:
            if r["claim_label"] in ("false_done", "false_fail", "wrong_refusal", "missed_refusal"):
                why = "; ".join(c["detail"] for c in r.get("checks", []) if not c["ok"])[:140]
                t.append([r["arm"], r["task"], r["trial"], r["claim_label"], (r.get("final_text") or "").strip().splitlines()[-1][:80] if r.get("final_text") else "", why])
        md.append("\n" + md_table(["arm", "task", "trial", "label", "final line", "check that failed"], t))
        data["agent"] = cs
    text = "\n".join(md) + "\n"
    with open(os.path.join(out, "tables.md"), "w") as f:
        f.write(text)
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(data, f, indent=1)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="ins", action="append", required=True, help="ARM_LABEL=path/to/truth.jsonl (repeatable)")
    ap.add_argument("--agent", action="append", default=[])
    ap.add_argument("--video", action="append", default=[])
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    arms = {}
    for spec in a.ins:
        label, path = spec.split("=", 1)
        arms.setdefault(label, []).extend(r for r in load(path) if "outcome" in r)
    print(build(arms, a.agent, a.out, a.video))


if __name__ == "__main__":
    main()
