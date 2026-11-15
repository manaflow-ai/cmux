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
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import truthmatrix_claims as tc  # noqa: E402

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
    return {**{k: c[k] for k in KEYS}, "scored": scored,
            "no_action": c["no_action"] + c["harness_aim"] + c["harness_state"] + c["not_scored"] + c["judge_error"] + c["?"],
            "unsupported": c["unsupported"],
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
             "effect rate", "not scored"]


def build(arms, agent_dirs, out, videos):
    os.makedirs(out, exist_ok=True)
    md = []
    data = {}
    # ---- headline per arm
    md.append("### Engine-claim accuracy, every scored action (both scenes, 3 reps)\n")
    md.append(md_table(CONF_HEAD, [conf_row(a, conf(rs)) for a, rs in arms.items()]))
    SCENES = {"bg": "the Person app frontmost, key and typing; the target app not active (its window was not always "
                    "below the Person window: z-order was not enforced in this scene)",
              "bgc": "as bg, and the Person window above the target window (covered), checked before every cell",
              "fg": "target app frontmost, target window key"}
    for scene, what in SCENES.items():
        rows_s = {a: [r for r in rs if r["scene"] == scene] for a, rs in arms.items()}
        if not any(rows_s.values()):
            continue
        md.append(f"\n### Scene {scene}: {what}\n")
        md.append(md_table(CONF_HEAD, [conf_row(a, conf(x)) for a, x in rows_s.items() if x]))
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
    md.append("\n### Per action (outcomes over 3 reps; bg | bgc | fg)\n")
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
            for scene in ("bg", "bgc", "fg"):
                cs = Counter(r["outcome"] for r in rs if r["app"] == app and r["action"] == act and r["scene"] == scene)
                cells.append(" ".join(f"{k}{v}" for k, v in sorted(cs.items())) or "–")
            line.append(" \\| ".join(cells))
        t.append(line)
    md.append(md_table(head, t))
    # ---- routes (cmux): which route each claim came from, and how often it was true
    md.append("\n### cmux routes: claim and truth per route\n")
    t = []
    import re as _re
    for a, rs in arms.items():
        by = defaultdict(Counter)
        for r in rs:
            if r["outcome"] not in KEYS:
                continue
            m = _re.search(r'"route":"(\w+)"', (r.get("scored_call") or {}).get("result") or "")
            if not m:
                continue
            by[(m.group(1), r["claim"])][r["outcome"]] += 1
        for (route, claim), cnt in sorted(by.items()):
            t.append([a, route, claim, sum(cnt.values())] + [cnt[k] for k in KEYS])
    if t:
        md.append(md_table(["arm", "route", "claim", "n"] + list(KEYS), t))
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
    md.append("\n### Background safety (bg and bgc scenes)\n")
    t = []
    for a, rs in arms.items():
        bg = [r for r in rs if r["scene"] in ("bg", "bgc") and "background_safe" in r and r["outcome"] != "no_action"]
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
            p = os.path.join(d, "results.recheck.jsonl")  # cueval recheck's re-scored transcript checks, if run
            if not os.path.exists(p):
                p = os.path.join(d, "results.jsonl")
            if os.path.exists(p):
                rs = load(p)
                for r in rs:
                    r["arm"] = f"{r['arm']} [{os.path.basename(d)}]"
                ag += rs
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


def repros(rows, outcomes=("FP", "FN", "SIDE")):
    """Every FP / FN / SIDE grouped by (app, action, scene), with one minimal repro each."""
    groups = defaultdict(list)
    for r in rows:
        if r["outcome"] in outcomes:
            groups[(r["outcome"], r["app"], r["action"], r["scene"])].append(r)
    out = []
    for (oc, app, act, scene), rs in sorted(groups.items()):
        r = rs[0]
        reps = sorted(x["rep"] for x in rs)
        sc = r.get("scored_call") or {}
        obs = [c["tool"] for c in r.get("calls", []) if c is not sc and c.get("t0", 0) < sc.get("t0", 0)]
        raw = sc.get("result") or ""
        import re
        keep = {k: m.group(1) for k in ("evidence", "route", "note", "code", "error")
                for m in [re.search(r'"%s"\s*:\s*"((?:[^"\\]|\\.)*)"' % k, raw)] if m}
        res = json.dumps(keep) if keep else raw[:300]
        evs = [e for e in r.get("events", []) if e.get("kind") == "state"]
        inputs = [e for e in r.get("events", []) if e.get("kind") == "input" and e.get("t", 0) >= sc.get("t0", 0)]
        tw = r.get("target_window") or {}
        out.append({
            "outcome": oc, "app": app, "action": act, "scene": scene, "reps": reps, "claim": r["claim"], "truth": r["truth"],
            "call": {"name": sc.get("tool"), "arguments": sc.get("args")}, "result": res[:400],
            "before": obs, "window": f"{tw.get('title')!r} (window {tw.get('wid')}), "
                                       + ("behind the frontmost, key Person window that is typing" if scene == "bg"
                                          else "frontmost and key"),
            "oracle": r.get("detail"), "events": [f"{e.get('win')}/{e.get('el')} {e.get('what')}={e.get('value', e.get('len'))} via {e.get('via')}"
                                                 for e in evs[:5]],
            "effect_ms": [x.get("effect_ms") for x in rs], "side_effects": r.get("side_effects"),
            "inputs": input_summary(inputs) if app == "lab" else None,
        })
    return out


EVT = {"1": "mouseDown", "2": "mouseUp", "3": "rightMouseDown", "4": "rightMouseUp", "6": "mouseDragged", "10": "keyDown",
       "22": "scrollWheel"}


def input_summary(inputs):
    """What input the fixture process itself received for the action (its NSEvent monitor)."""
    if not inputs:
        return "the app received no input event"
    c = Counter((EVT.get(e.get("type"), e.get("type")), "window " + repr(e.get("win")) if e.get("win") else "no window")
                for e in inputs)
    return "the app received " + ", ".join(f"{n} {k} ({w})" for (k, w), n in c.items())


def repro_md(items):
    lines = []
    for it in items:
        lines.append(f"- **{it['outcome']}** {it['app']} `{it['action']}` ({it['scene']}, reps {it['reps']}): claim `{it['claim']}`, "
                     f"truth `{it['truth']}`. Window: {it['window']}. Before it: {', '.join(it['before']) or 'nothing'}.\n"
                     f"  Call: `{json.dumps(it['call'])}`\n  Result: `{it['result'][:300]}`\n  Oracle: {it['oracle']}"
                     + (f"; events {it['events']}" if it["events"] else "") + (f"; effect at {it['effect_ms']} ms" if any(it['effect_ms']) else "")
                     + (f"; input: {it['inputs']}" if it.get("inputs") else ""))
    return "\n".join(lines)


def fixup(rows):
    """Re-derive what a refined judge or claim mapping says from what each row stored, so older rows count the
    same as new ones: Safari cmd+a is correct only when the page's selection grew past 500 chars (a keydown alone
    selected nothing in the background); a fg cell whose target could not be made frontmost and key is reported
    as fg-unarranged; claims come from the stored result through truthmatrix_claims."""
    import re as _re
    # TextEdit cells run in a fixed order per (arm, scene, rep). In the runs before the reorder, cmd+a came before
    # cmd+s: when it worked, cmd+s's setup typing replaced the whole document with the 8-char tag, so the scroll
    # and drag cells after it had no document to act on. Those rows are not evidence (harness_state).
    te_selected = {(r["arm"], r["scene"], r["rep"]) for r in rows if r["app"] == "textedit"
                   and r["action"] == "press_key_cmd_a" and r.get("truth") == "correct"}
    te_order = {(r["arm"], r["scene"], r["rep"]): [x["action"] for x in rows if x["app"] == "textedit"
                and (x["arm"], x["scene"], x["rep"]) == (r["arm"], r["scene"], r["rep"])] for r in rows if r["app"] == "textedit"}
    for r in rows:
        if r["app"] == "safari" and r["action"] == "press_key_chord_cmd_a" and r.get("truth") in ("correct", "wrong", "none"):
            # cmd+a selects the whole page, or (focus still in the Name field from the type_text cell before it) the
            # whole field: its text is the 8-or-9-char tag. A meta+a keydown with nothing selected cannot be told
            # apart from a field selection the page does not report: not scored.
            m = _re.search(r"selection (\S+) -> (\d+) chars", r.get("detail") or "")
            if m:
                n = int(m.group(2))
                tag = len(f"CUEV{r['rep']}{r['scene']}X")
                if n > 500 or n == tag:
                    r["truth"] = "correct"
                elif "meta+a" in (r.get("detail") or ""):
                    r["outcome"] = "harness_state"
                    r["truth"] = None
                else:
                    r["truth"] = "none"
        k = (r["arm"], r["scene"], r["rep"])
        if r["app"] == "textedit" and r["action"] in ("scroll", "drag_select") and k in te_selected:
            order = te_order.get(k, [])
            if "press_key_cmd_a" in order and "press_key_cmd_s" in order and order.index("press_key_cmd_a") < order.index("press_key_cmd_s"):
                r["outcome"] = "harness_state"
        if r["scene"] == "fg" and r.get("note"):
            r["scene"] = "fg-unarranged"
        if r.get("scored_call") and r["outcome"] not in ("unsupported", "no_action", "harness_state", "judge_error"):
            r["claim"] = tc.claim_of(r["arm"], r["scored_call"])
            r["outcome"] = tc.confusion_cell(r["claim"], r["truth"], r.get("expect_none"))
            args = r["scored_call"].get("args") or {}
            pts = [args.get(k) for k in ("x", "y", "from_x", "from_y", "to_x", "to_y") if isinstance(args.get(k), (int, float))]
            if any(v < 0 for v in pts):
                # the harness aimed outside the window (an element frame converted into the wrong space):
                # not evidence about the tool's claim
                r["outcome"] = "harness_aim"
    return rows


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
        rows = fixup([r for r in load(path) if "outcome" in r])
        arms.setdefault(label, []).extend(rows)
    print(build(arms, a.agent, a.out, a.video))


if __name__ == "__main__":
    main()


# ------------------------------------------------------------------ HTML (self-contained)

CSS = """
:root{--bg:#fff;--fg:#1d1d1f;--mut:#6e6e73;--line:#d2d2d7;--code:#f5f5f7;--acc:#0A84FF;--bad:#cf222e;--ok:#1a7f37}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#1c1c1e;--fg:#f5f5f7;--mut:#a1a1a6;--line:#3a3a3c;--code:#2c2c2e;--bad:#f85149;--ok:#3fb950}}
:root[data-theme="dark"]{--bg:#1c1c1e;--fg:#f5f5f7;--mut:#a1a1a6;--line:#3a3a3c;--code:#2c2c2e;--bad:#f85149;--ok:#3fb950}
*{box-sizing:border-box}body{background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,system-ui,sans-serif;margin:0 auto;padding:24px 16px 80px;max-width:1180px}
h1{font-size:26px}h2{font-size:20px;margin-top:36px;border-bottom:1px solid var(--line);padding-bottom:4px}h3{font-size:16px;margin-top:24px}
.tw{overflow-x:auto;margin:8px 0}table{border-collapse:collapse;font-size:13px}th,td{border-bottom:1px solid var(--line);padding:5px 8px;text-align:left;vertical-align:top}
th{color:var(--mut);font-weight:600;white-space:nowrap}code{font:12.5px ui-monospace,SFMono-Regular,monospace;background:var(--code);padding:1px 4px;border-radius:4px;word-break:break-word}
pre{background:var(--code);padding:10px;border-radius:8px;overflow-x:auto;font:12px ui-monospace,monospace}li{margin:6px 0}
video{width:100%;max-width:1100px;border:1px solid var(--line);border-radius:8px;background:#000}figure{margin:16px 0}figcaption{color:var(--mut);font-size:13px}
.mut{color:var(--mut)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;margin:16px 0}
.card{border:1px solid var(--line);border-radius:10px;padding:12px 14px}.card h4{margin:0 0 6px;font-size:14px}
.big{font-size:22px;font-weight:650}.bad{color:var(--bad)}.ok{color:var(--ok)}
"""


def _inline(t):
    import re
    t = html.escape(t)
    t = re.sub(r"`([^`]+)`", lambda m: f"<code>{m.group(1)}</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    return t


def md_to_html(md):
    out, lines, i = [], md.splitlines(), 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("```"):
            j = i + 1
            buf = []
            while j < len(lines) and not lines[j].startswith("```"):
                buf.append(lines[j])
                j += 1
            out.append("<pre>" + html.escape("\n".join(buf)) + "</pre>")
            i = j + 1
            continue
        if ln.startswith("|") and i + 1 < len(lines) and set(lines[i + 1].replace("|", "").strip()) <= set("-: "):
            head = [c.strip() for c in ln.strip("|").split("|")]
            rows = []
            j = i + 2
            while j < len(lines) and lines[j].startswith("|"):
                rows.append([c.strip() for c in lines[j].strip().strip("|").replace("\\|", "│").split("|")])
                j += 1
            out.append("<div class=tw><table><tr>" + "".join(f"<th>{_inline(h)}</th>" for h in head) + "</tr>" +
                       "".join("<tr>" + "".join(f"<td>{_inline(c).replace(chr(0x2502), '|')}</td>" for c in r) + "</tr>" for r in rows) +
                       "</table></div>")
            i = j
            continue
        m = len(ln) - len(ln.lstrip("#"))
        if 0 < m <= 4 and ln[m:m + 1] == " ":
            out.append(f"<h{m}>{_inline(ln[m + 1:])}</h{m}>")
        elif ln.lstrip().startswith(("- ", "* ")):
            items = []
            while i < len(lines) and (lines[i].lstrip().startswith(("- ", "* ")) or (lines[i].startswith("  ") and items)):
                if lines[i].lstrip().startswith(("- ", "* ")):
                    items.append(lines[i].lstrip()[2:])
                else:
                    items[-1] += "\n" + lines[i].strip()
                i += 1
            out.append("<ul>" + "".join("<li>" + "<br>".join(_inline(x) for x in it.split("\n")) + "</li>" for it in items) + "</ul>")
            continue
        elif ln.strip():
            out.append(f"<p>{_inline(ln)}</p>")
        i += 1
    return "\n".join(out)


def cards_html(summary):
    """One card per arm: false-success rate, false-failure rate, side effects."""
    out = ["<div class=cards>"]
    for arm, c in summary.items():
        fp, fn = c.get("fp_rate"), c.get("fn_rate")
        out.append(f"<div class=card><h4>{html.escape(arm)}</h4>"
                   f"<div><span class='big {'bad' if (fp or 0) > 0.05 else 'ok'}'>{pct(fp)}</span> false success "
                   f"<span class=mut>({c['FP']} of {c['TP'] + c['FP']} success claims)</span></div>"
                   f"<div><span class='big {'bad' if (fn or 0) > 0.05 else 'ok'}'>{pct(fn)}</span> false failure "
                   f"<span class=mut>({c['FN']} of {c['FN'] + c['TN']} failure claims)</span></div>"
                   f"<div class=mut>side effects {c['SIDE']}; scored {c['scored']}; not scored {c['no_action']}</div></div>")
    out.append("</div>")
    return "".join(out)


def render_html(md_path, out_path, videos, title, summary=None):
    md = open(md_path).read()
    body = md_to_html(md)
    if summary:
        i = body.find("</h1>")
        cards = cards_html(summary)
        body = body[:i + 5] + cards + body[i + 5:] if i >= 0 else cards + body
    vids = []
    for spec in videos:
        cap, path = spec.split("=", 1)
        b64 = base64.b64encode(open(path, "rb").read()).decode()
        vids.append(f"<figure><video controls preload=metadata src='data:video/mp4;base64,{b64}'></video><figcaption>{html.escape(cap)}</figcaption></figure>")
    page = (f"<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            f"<title>{html.escape(title)}</title><style>{CSS}</style></head><body>{body}")
    if vids:
        page += "<h2>Videos</h2>" + "".join(vids)
    page += "</body></html>"
    with open(out_path, "w") as f:
        f.write(page)
    return out_path
