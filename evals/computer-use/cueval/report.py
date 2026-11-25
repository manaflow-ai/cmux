# SPDX-License-Identifier: MIT
"""A self-contained HTML summary of results.jsonl (agent tier) and
tool-tier.jsonl (tool tier). No scripts, no external assets."""

from __future__ import annotations

import html
import json
import os
from collections import defaultdict

from .stats import median, newcombe_diff, wilson


def _load(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def _pct(x: float | None) -> str:
    return "–" if x is None else f"{100 * x:.0f}%"


def _rate(s: int, n: int) -> str:
    if n == 0:
        return "–"
    lo, hi = wilson(s, n)
    return f"{s}/{n} = {_pct(s / n)} <span class=ci>[{_pct(lo)}, {_pct(hi)}]</span>"


def _num(x, fmt="{:.0f}") -> str:
    return "–" if x is None else fmt.format(x)


def summarize(rows: list[dict]) -> dict:
    by_arm: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_arm[r["arm"]].append(r)
    out = {}
    for arm, rs in by_arm.items():
        refusal = [r for r in rs if r.get("expect_refusal")]
        person = [r for r in rs if r.get("person_present")]
        out[arm] = {
            "n": len(rs), "success": sum(r["success"] for r in rs),
            "refusal_n": len(refusal), "refusal_ok": sum(bool(r.get("refusal_correct")) and r["success"] for r in refusal),
            "overrefusal": sum(bool(r.get("refused")) for r in rs if not r.get("expect_refusal")),
            "nonrefusal_n": sum(1 for r in rs if not r.get("expect_refusal")),
            "bg_n": len(person), "bg_ok": sum(r.get("background_safe") is True for r in person),
            "steps": median([r["steps"] for r in rs if r["success"]]),
            "wall": median([r["wall_s"] for r in rs if r["success"]]),
            "tokens": median([(r.get("input_tokens") or 0) + (r.get("output_tokens") or 0) for r in rs
                              if r["success"] and r.get("input_tokens") is not None]),
            "cost": median([r["cost_usd"] for r in rs if r.get("cost_usd") is not None]),
            "errors": sum(1 for r in rs if r.get("error")),
        }
    return out


CSS = """
:root{--bg:#fff;--fg:#1d1d1f;--mut:#6e6e73;--line:#d2d2d7;--ok:#1a7f37;--bad:#cf222e;--acc:#0A84FF}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--mut:#a1a1a6;--line:#3a3a3c;--ok:#3fb950;--bad:#f85149}}
body{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:1100px;margin-inline:auto}
h1{font-size:22px}h2{font-size:17px;margin-top:28px}table{border-collapse:collapse;width:100%;overflow-x:auto;display:block}
th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;white-space:nowrap}th{color:var(--mut);font-weight:600}
.ci,.mut{color:var(--mut)}.ok{color:var(--ok)}.bad{color:var(--bad)}code{font:12px ui-monospace,monospace}
"""


def render(out_dir: str, title: str = "cmux Computer Use evals") -> str:
    rows = _load(os.path.join(out_dir, "results.jsonl"))
    tool = _load(os.path.join(out_dir, "tool-tier.jsonl"))
    parts = [f"<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
             f"<title>CU eval report</title><style>{CSS}</style></head><body><h1>{html.escape(title)}</h1>"]
    if rows:
        meta = sorted({(r["agent"], r["model"], r["platform"], r.get("prereg", "")[:12]) for r in rows})
        parts.append("<p class=mut>" + "; ".join(
            f"agent <code>{html.escape(a)}</code>, model <code>{html.escape(m)}</code>, platform <code>{p}</code>, pre-registration <code>{d}</code>"
            for a, m, p, d in meta) + "</p>")
        s = summarize(rows)
        parts.append("<h2>Agent task evals, per arm</h2><table><tr><th>Arm</th><th>Success (95% Wilson CI)</th>"
                     "<th>Refusal correct</th><th>Over-refusal</th><th>Background-safe</th><th>Median steps</th>"
                     "<th>Median wall s</th><th>Median tokens</th><th>Median cost</th><th>Errors</th></tr>")
        for arm, v in sorted(s.items()):
            parts.append(f"<tr><td><code>{html.escape(arm)}</code></td><td>{_rate(v['success'], v['n'])}</td>"
                         f"<td>{_rate(v['refusal_ok'], v['refusal_n'])}</td><td>{_rate(v['overrefusal'], v['nonrefusal_n'])}</td>"
                         f"<td>{_rate(v['bg_ok'], v['bg_n'])}</td><td>{_num(v['steps'])}</td><td>{_num(v['wall'], '{:.1f}')}</td>"
                         f"<td>{_num(v['tokens'])}</td><td>{_num(v['cost'], '${:.3f}')}</td><td>{v['errors']}</td></tr>")
        parts.append("</table>")
        arms = sorted(s)
        if "cmux-cu" in s and len(arms) > 1:
            for other in arms:
                if other == "cmux-cu":
                    continue
                a, b = s["cmux-cu"], s[other]
                d, lo, hi = newcombe_diff(a["success"], a["n"], b["success"], b["n"])
                parts.append(f"<p>Success difference cmux-cu − {html.escape(other)}: <b>{100 * d:+.0f} pts</b> "
                             f"<span class=ci>[{100 * lo:+.0f}, {100 * hi:+.0f}] (Newcombe 95%)</span></p>")
        tasks = sorted({r["task"] for r in rows})
        parts.append("<h2>Per task</h2><table><tr><th>Task</th><th>Split</th>" +
                     "".join(f"<th>{html.escape(a)}</th>" for a in arms) + "</tr>")
        for t in tasks:
            split = next(r["split"] for r in rows if r["task"] == t)
            cells = []
            for a in arms:
                rs = [r for r in rows if r["task"] == t and r["arm"] == a]
                ok = sum(r["success"] for r in rs)
                cls = "ok" if rs and ok == len(rs) else ("bad" if rs and ok == 0 else "")
                cells.append(f"<td class={cls}>{ok}/{len(rs)}</td>" if rs else "<td class=mut>–</td>")
            parts.append(f"<tr><td><code>{t}</code></td><td>{split}</td>{''.join(cells)}</tr>")
        parts.append("</table>")
        failed = [r for r in rows if not r["success"]][:60]
        if failed:
            parts.append("<h2>Failures</h2><table><tr><th>Arm</th><th>Task</th><th>Trial</th><th>Why</th></tr>")
            for r in failed:
                why = r.get("error") or "; ".join(c["detail"] for c in r.get("checks", []) if not c["ok"])
                parts.append(f"<tr><td>{html.escape(r['arm'])}</td><td>{r['task']}</td><td>{r['trial']}</td>"
                             f"<td class=mut>{html.escape(str(why)[:200])}</td></tr>")
            parts.append("</table>")
    if tool:
        arms = sorted({r["arm"] for r in tool})
        cases = list(dict.fromkeys(r["case"] for r in tool))
        parts.append("<h2>Tool tier (deterministic, no model)</h2><table><tr><th>Case</th>" +
                     "".join(f"<th>{html.escape(a)}</th>" for a in arms) + "</tr>")
        for c in cases:
            cells = []
            for a in arms:
                rs = [r for r in tool if r["case"] == c and r["arm"] == a]
                if not rs:
                    cells.append("<td class=mut>–</td>")
                    continue
                last = rs[-1]
                mark = "PASS" if last["ok"] else "FAIL"
                cells.append(f"<td class={'ok' if last['ok'] else 'bad'} title='{html.escape(last['detail'], quote=True)}'>"
                             f"{mark} <span class=mut>{html.escape(last['detail'][:70])}</span></td>")
            parts.append(f"<tr><td><code>{c}</code></td>{''.join(cells)}</tr>")
        parts.append("</table>")
    if not rows and not tool:
        parts.append("<p>No results yet.</p>")
    parts.append("</body></html>")
    path = os.path.join(out_dir, "report.html")
    with open(path, "w") as f:
        f.write("\n".join(parts))
    return path


# ---------------------------------------------------------------- text summary (cost and speed)

def _q(values: list, q: float):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def _f(x, fmt="{:.0f}") -> str:
    return "-" if x is None else fmt.format(x)


def text_summary(out_dir: str, run_ids: list[str] | None = None) -> str:
    """Per-task and per-tool tables for a hill climb: success, p50 wall time, tool calls, tokens;
    per tool: count, p50/p90 latency, mean result bytes, images and their share of input tokens."""
    rows = [r for r in _load(os.path.join(out_dir, "results.jsonl")) if r.get("tier") == "agent"]
    calls = _load(os.path.join(out_dir, "calls.jsonl"))
    if run_ids:
        rows = [r for r in rows if r["run_id"] in run_ids]
        calls = [c for c in calls if c["run_id"] in run_ids]
    if not rows:
        return "no agent results"
    out = []
    metas = sorted({(r.get("meta", {}).get("agent_version"), r.get("meta", {}).get("model_id"), r["model"]) for r in rows},
                   key=str)
    out.append("runs: " + ", ".join(sorted({r["run_id"] for r in rows})))
    out.append("agent/model: " + "; ".join(f"claude {a} model {m} (--model {mm})" for a, m, mm in metas))
    hdr = (f"{'task':28} {'ok':>5} {'p50 wall':>8} {'p50 agent':>9} {'p50 think':>9} {'p50 tool':>8} {'p50 calls':>9} "
           f"{'p50 turns':>9} {'p50 tok':>8} {'p50 img tok':>11} {'no_eff':>6} {'rep':>4} {'cost':>7}")
    out += ["", hdr, "-" * len(hdr)]
    tasks = sorted({r["task"] for r in rows})
    tot = defaultdict(list)
    for t in tasks + ["ALL"]:
        rs = [r for r in rows if r["task"] == t] if t != "ALL" else rows
        ok = sum(r["success"] for r in rs)
        tok = [(r.get("input_tokens") or 0) + (r.get("output_tokens") or 0) for r in rs if r.get("input_tokens") is not None]
        line = (f"{t:28} {ok:>2}/{len(rs):<2} {_f(_q([r['wall_s'] for r in rs], .5), '{:.1f}'):>8} "
                f"{_f(_q([r.get('agent_wall_s') for r in rs], .5), '{:.1f}'):>9} "
                f"{_f(_q([r.get('think_time_s') for r in rs], .5), '{:.1f}'):>9} "
                f"{_f(_q([r.get('tool_time_s') for r in rs], .5), '{:.1f}'):>8} "
                f"{_f(_q([r['steps'] for r in rs], .5)):>9} {_f(_q([r.get('turns') for r in rs], .5)):>9} "
                f"{_f(_q(tok, .5)):>8} {_f(_q([r.get('image_est_tokens') for r in rs], .5)):>11} "
                f"{sum(r.get('no_effect') or 0 for r in rs):>6} {sum(r.get('repeats') or 0 for r in rs):>4} "
                f"{_f(sum(r.get('cost_usd') or 0 for r in rs), '${:.2f}'):>7}")
        if t == "ALL":
            out.append("-" * len(hdr))
        out.append(line)
    # per tool
    by = defaultdict(list)
    for c in calls:
        by[c["tool"]].append(c)
    total_lat = sum(c.get("latency_s") or 0 for c in calls) or 1
    hdr = (f"{'tool':16} {'count':>5} {'p50 s':>6} {'p90 s':>6} {'max s':>6} {'time %':>6} {'mean res B':>10} "
           f"{'imgs':>5} {'mean img px':>12} {'mean img b64 KB':>15} {'img tok':>8} {'no_eff':>6} {'err':>4} {'rep':>4} {'p50 think':>9}")
    out += ["", hdr, "-" * len(hdr)]
    for tool, cs in sorted(by.items(), key=lambda kv: -sum(c.get("latency_s") or 0 for c in kv[1])):
        lat = [c.get("latency_s") for c in cs]
        imgs = [i for c in cs for i in c.get("images") or []]
        px = [f"{i['w']}x{i['h']}" for i in imgs if i.get("w")]
        common = max(set(px), key=px.count) if px else "-"
        out.append(f"{tool:16} {len(cs):>5} {_f(_q(lat, .5), '{:.2f}'):>6} {_f(_q(lat, .9), '{:.2f}'):>6} "
                   f"{_f(_q(lat, 1.0), '{:.2f}'):>6} {100 * sum(v or 0 for v in lat) / total_lat:>5.0f}% "
                   f"{_f(sum(c.get('result_bytes') or 0 for c in cs) / len(cs)):>10} {len(imgs):>5} {common:>12} "
                   f"{_f(sum(i['b64_bytes'] for i in imgs) / len(imgs) / 1024 if imgs else None, '{:.0f}'):>15} "
                   f"{sum(i.get('est_tokens') or 0 for i in imgs):>8} {sum(1 for c in cs if c.get('no_effect')):>6} "
                   f"{sum(1 for c in cs if c.get('is_error')):>4} {sum(1 for c in cs if c.get('repeat')):>4} "
                   f"{_f(_q([c.get('think_s') for c in cs], .5), '{:.1f}'):>9}")
    acting = {"click", "type_text", "press_key", "scroll", "drag", "set_value", "perform_action", "batch", "wait"}
    hdr = (f"{'tool (settle)':16} {'n':>4} {'w/ wait':>7} {'p50 wait ms':>11} {'p90 wait ms':>11} {'>=950ms':>7} "
           f"{'p50 lat-wait s':>14} {'p90 lat-wait s':>14} {'img att.':>8} {'p50 outline B':>13} {'outcomes':<40}")
    out += ["", hdr, "-" * len(hdr)]
    for tool, cs in sorted(by.items()):
        waits = [c.get("waited_ms") for c in cs if isinstance(c.get("waited_ms"), (int, float))]
        over = [c.get("latency_s") - c["waited_ms"] / 1000 for c in cs
                if isinstance(c.get("waited_ms"), (int, float)) and c.get("latency_s") is not None]
        outs = defaultdict(int)
        for c in cs:
            outs[str(c.get("outcome"))] += 1
        ceil = sum(1 for w in waits if w >= 950)
        out.append(f"{tool:16} {len(cs):>4} {len(waits):>7} {_f(_q(waits, .5)):>11} {_f(_q(waits, .9)):>11} "
                   f"{(f'{100 * ceil / len(waits):.0f}%' if waits else '-'):>7} {_f(_q(over, .5), '{:.2f}'):>14} "
                   f"{_f(_q(over, .9), '{:.2f}'):>14} {sum(1 for c in cs if c.get('images')):>8} "
                   f"{_f(_q([c.get('outline_bytes') for c in cs], .5)):>13} "
                   f"{', '.join(f'{k}:{v}' for k, v in sorted(outs.items(), key=lambda kv: -kv[1]))[:60]:<40}")
    act = [c for c in calls if c["tool"] in acting and isinstance(c.get("waited_ms"), (int, float))]
    if act:
        out.append(f"acting calls with a settle wait: {len(act)}; at the 1 s ceiling (>=950 ms): "
                   f"{sum(1 for c in act if c['waited_ms'] >= 950)} ({100 * sum(1 for c in act if c['waited_ms'] >= 950) / len(act):.0f}%); "
                   f"total waited {sum(c['waited_ms'] for c in act) / 1000:.0f}s of {sum(c.get('latency_s') or 0 for c in act):.0f}s latency")
    fresh = sum(r.get("fresh_input_tokens") or 0 for r in rows)
    cache = sum(r.get("cache_read_tokens") or 0 for r in rows)
    outp = sum(r.get("output_tokens") or 0 for r in rows)
    img = sum(r.get("image_est_tokens") or 0 for r in rows)
    think = sum(r.get("think_time_s") or 0 for r in rows)
    tool = sum(r.get("tool_time_s") or 0 for r in rows)
    wall = sum(r.get("wall_s") or 0 for r in rows)
    reset = sum(r.get("reset_s") or 0 for r in rows)
    out += ["", f"time: wall {wall:.0f}s = reset {reset:.0f}s + model think {think:.0f}s + tool calls {tool:.0f}s + other "
                f"{wall - reset - think - tool:.0f}s (agent start-up, final answer, checks)",
            f"tokens: fresh input {fresh} (incl. cache writes), cache reads {cache}, output {outp}; "
            f"images ~{img} tokens = {100 * img / fresh if fresh else 0:.0f}% of fresh input",
            f"after an action, the next call was a look (screenshot/tree/list/wait): "
            f"{sum(r.get('relooks_after_action') or 0 for r in rows)} times over {len(rows)} trials"]
    fails = [r for r in rows if not r["success"]]
    if fails:
        out += ["", "failures:"]
        for r in fails:
            why = r.get("error") or "; ".join(c["detail"][:90] for c in r.get("checks", []) if not c["ok"])
            out.append(f"  {r['task']} t{r['trial']}: {why[:160]} | agent: {(r.get('final_text') or '').strip().splitlines()[-1][:140] if r.get('final_text') else ''}")
    return "\n".join(out)
