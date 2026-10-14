#!/usr/bin/env python3
"""Renders results.json files of e2e runs as Markdown tables (step x result x
evidence x owner, then the latency table). Usage: matrix.py RESULTS.json...
Prints to stdout; e2e-matrix.md embeds the output between its markers."""
import json
import os
import sys

TARGETS = {"cold_connect_to_list": 1500, "cold_link_up": 1500, "warm_reconnect": 1000,
           "keystroke_echo_idle": 50, "keystroke_echo_flood": 50}


def cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def main(paths):
    runs = [(p, json.load(open(p))) for p in paths]
    out = []
    for p, d in runs:
        m = d["meta"]
        rel = os.path.relpath(os.path.dirname(p), os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
        out.append(f"### {m['ios_runtime'].split('.')[-1]} ({m['simulator']['name']}), run {m['run']}\n")
        out.append(f"iOS `{m['ios_head'][:10]}` ({m['ios_config']}); Mac `{m['mac_app']}` ({m.get('mac_source') or ''}). "
                   f"Summary: {d['summary']}. Evidence: `{rel}/`.\n")
        out.append("| Step | Result | Time | Notes | Evidence | Owner |")
        out.append("| --- | --- | --- | --- | --- | --- |")
        for r in d["steps"]:
            owner = r["owner"] if r["status"] != "pass" else ""
            res = {"pass": "Pass", "fail": "**Fail**", "blocked": "Blocked"}[r["status"]]
            out.append(f"| {cell(r['title'])} | {res} | {r['seconds']} s | {cell(r.get('notes', ''))[:420]} | "
                       f"`{r.get('screenshot') or ''}` | {owner} |")
        if d.get("hangs"):
            out.append("\nApp hangs (main thread busy, no accessibility; sampled, then relaunched):\n")
            for h in d["hangs"]:
                out.append(f"- after `{h['where']}`: {h['kind']}, CPU {h.get('cpu', '?')}%, `{h.get('sample', '')}`")
        out.append("")
        lat = d.get("latency") or {}
        if lat:
            out.append("| Metric | n | Median | p95 | Target | Evidence |")
            out.append("| --- | --- | --- | --- | --- | --- |")
            for k, v in lat.items():
                tgt = TARGETS.get(k)
                if v.get("n"):
                    ok = "" if tgt is None else (" (meets)" if v["p95_ms"] <= tgt else " (**misses**)")
                    out.append(f"| {k} | {v['n']} | {v['median_ms']} ms | {v['p95_ms']} ms | "
                               f"{(str(tgt) + ' ms') if tgt else '-'}{ok} | `latency/{v.get('video', '')}` |")
                else:
                    out.append(f"| {k} | 0 | - | - | {(str(tgt) + ' ms') if tgt else '-'} | "
                               f"{cell(v.get('blocked') or v.get('error') or 'no samples')} |")
            out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1:])
