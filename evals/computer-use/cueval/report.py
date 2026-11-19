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
