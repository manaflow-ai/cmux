#!/usr/bin/env python3
"""Markdown tables from bench.py / aside_bench.py output (the *-rows.jsonl files in one directory).

  python3 -I report.py DIR
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import pct  # noqa: E402

PRIMS = ["goto", "state", "state_interactive", "click", "state_after_click", "type", "state_after"]


def load(directory, name):
    path = os.path.join(directory, name)
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f]


def cell(rows):
    ok = [r["ms"] for r in rows if r["ok"]]
    fail = len(rows) - len(ok)
    if not ok:
        return f"fail {fail}/{len(rows)}" if rows else ""
    text = f"{pct(ok, 0.5):.0f} / {pct(ok, 0.95):.0f}"
    return text + (f" ({fail} fail)" if fail else "")


def size(rows):
    first = sorted((r for r in rows if r.get("chars")), key=lambda r: r["run"])
    if not first:
        return ""
    c = first[0]["chars"]
    return f"{c:,} / {round(c / 4):,}"


def table(rows, tools, sites, prims, title):
    out = [f"### {title}", "", "| site | primitive | " + " | ".join(tools) + " |", "| --- | --- |" + " --- |" * len(tools)]
    for site in sites:
        for prim in prims:
            cells = [cell([r for r in rows if r["tool"] == t and r["site"] == site and r["prim"] == prim]) for t in tools]
            if any(cells):
                out.append(f"| {site} | {prim} | " + " | ".join(cells) + " |")
    out.append("")
    out.append(f"#### {title}: page-state size, first read (characters / approx tokens at 4 chars per token)")
    out.append("")
    out.append("| site | read | " + " | ".join(tools) + " |")
    out.append("| --- | --- |" + " --- |" * len(tools))
    for site in sites:
        for prim in ("state", "state_interactive", "state_after", "state_after_click"):
            cells = [size([r for r in rows if r["tool"] == t and r["site"] == site and r["prim"] == prim]) for t in tools]
            if any(cells):
                out.append(f"| {site} | {prim} | " + " | ".join(cells) + " |")
    out.append("")
    return "\n".join(out)


def ordered(values, preferred):
    seen = [v for v in preferred if v in values]
    return seen + sorted(v for v in values if v not in seen)


def main():
    d = sys.argv[1]
    order = ["cmux", "cmux-tuned", "cmux-cli", "cmux-mcp", "browser-use", "pwmcp", "pwmcp-nosnap", "stagehand", "aside"]
    for name, title, prims in (("warm-rows.jsonl", "Warm primitives, p50 / p95 ms", PRIMS),
                               ("cold-rows.jsonl", "Cold start to example.com loaded, p50 / p95 ms", ["cold_total", "cold_browser"]),
                               ("youtube-rows.jsonl", "YouTube top 5, p50 / p95 ms per step", ["site_tool", "dom_goto", "dom_state1", "dom_type_enter", "dom_state2"]),
                               ("aside-rows.jsonl", "cmux vs Aside, public pages, timed inside one REPL call, p50 / p95 ms", ["goto", "state", "state_interactive", "click", "call_wall"])):
        rows = load(d, name)
        if not rows:
            continue
        tools = ordered({r["tool"] for r in rows}, order)
        sites = list(dict.fromkeys(r["site"] for r in rows))
        print(table(rows, tools, sites, prims, title))


if __name__ == "__main__":
    main()
