#!/usr/bin/env python3
"""HTML table from bench_pane_scale.py results.

Usage:
  scripts/cmux-next/pane_scale_report.py OUT.html RESULT.json [RESULT.json ...]
      [--title TEXT] [--note TEXT]

Each result is one column group (its label); rows are metrics per
checkpoint N. Per-pane memory is the slope between consecutive checkpoints
((footprint at N2 - footprint at N1) / (panes at N2 - panes at N1)).
"""
from __future__ import annotations

import argparse
import html
import json

PHASES = ["focus", "resize", "window", "churn", "tabs"]


def get(obj, *path):
    for key in path:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(key)
    return obj


def proc(cp, section, kind, field):
    return get(cp, section, "processes", kind, field)


def metrics():
    """(group, label, function(checkpoint, previous) -> value, unit)."""
    rows = [
        ("layout", "panes / tabs / terminals", lambda c, p: f"{c.get('panes')} / {c.get('tabs')} / {c.get('terminals')}", ""),
        ("create", "build time for this step", lambda c, p: get(c, "build", "seconds"), "s"),
        ("create", "create round trip p50", lambda c, p: get(c, "build", "rtt_ms", "p50"), "ms"),
        ("create", "create round trip p99", lambda c, p: get(c, "build", "rtt_ms", "p99"), "ms"),
        ("create", "create to visible in snapshot p50", lambda c, p: get(c, "build", "visible_ms", "p50"), "ms"),
        ("create", "app CPU while building", lambda c, p: get(c, "build", "window", "processes", "app", "cpu_percent"), "%"),
        ("memory", "app footprint", lambda c, p: proc(c, "idle", "app", "footprint_mb"), "MB"),
        ("memory", "app per added pane", lambda c, p: slope(c, p, "app"), "MB"),
        ("memory", "daemon footprint", lambda c, p: proc(c, "idle", "daemon", "footprint_mb"), "MB"),
        ("memory", "terminal hosts (sum)", lambda c, p: proc(c, "idle", "terminal-host", "footprint_mb"), "MB"),
        ("memory", "terminal host per added pane", lambda c, p: slope(c, p, "terminal-host"), "MB"),
        ("memory", "Chromium helpers (sum)", lambda c, p: sum_kinds(c, "idle", "footprint_mb", "cef"), "MB"),
        ("idle", "app CPU", lambda c, p: proc(c, "idle", "app", "cpu_percent"), "%"),
        ("idle", "app wakeups", lambda c, p: proc(c, "idle", "app", "wakeups_per_s"), "/s"),
        ("idle", "daemon CPU", lambda c, p: proc(c, "idle", "daemon", "cpu_percent"), "%"),
        ("idle", "daemon wakeups", lambda c, p: proc(c, "idle", "daemon", "wakeups_per_s"), "/s"),
        ("idle", "terminal hosts CPU (sum)", lambda c, p: proc(c, "idle", "terminal-host", "cpu_percent"), "%"),
        ("idle", "terminal hosts wakeups (sum)", lambda c, p: proc(c, "idle", "terminal-host", "wakeups_per_s"), "/s"),
        ("idle", "active frame clients", lambda c, p: ", ".join(get(c, "idle", "active_frame_clients") or []) or "none", ""),
        ("idle", "ledger owners awake", lambda c, p: ", ".join(f"{e['owner']}:{e['reason']} {e['per_second']}/s"
                                                              for e in (get(c, "idle", "ledger") or [])[:4]) or "none", ""),
    ]
    for phase in PHASES:
        rows += [
            (phase, "op latency p50 / p99", lambda c, p, ph=phase: pair(get(c, "phases", ph, "latency_ms", "p50"),
                                                                        get(c, "phases", ph, "latency_ms", "p99")), "ms"),
            (phase, "app CPU", lambda c, p, ph=phase: get(c, "phases", ph, "processes", "app", "cpu_percent"), "%"),
            (phase, "daemon CPU", lambda c, p, ph=phase: get(c, "phases", ph, "processes", "daemon", "cpu_percent"), "%"),
            (phase, "main-thread hang total / max", lambda c, p, ph=phase: pair(get(c, "phases", ph, "hangs", "total_ms"),
                                                                                get(c, "phases", ph, "hangs", "max_ms")), "ms"),
            (phase, "frame interval p99 / missed", lambda c, p, ph=phase: pair(get(c, "phases", ph, "frames", "p99_ms"),
                                                                               get(c, "phases", ph, "frames", "missed")), "ms / n"),
            (phase, "pane snapshots per op", lambda c, p, ph=phase: get(c, "phases", ph, "layout", "pane_snapshots_per_op"), ""),
            (phase, "view layout passes per op", lambda c, p, ph=phase: get(c, "phases", ph, "layout_passes", "per_op"), ""),
            (phase, "topology sends per op", lambda c, p, ph=phase: get(c, "phases", ph, "layout", "topology_sends_per_op"), ""),
        ]
    return rows


def pair(a, b):
    if a is None and b is None:
        return None
    return f"{fmt(a)} / {fmt(b)}"


def sum_kinds(cp, section, field, prefix):
    values = [row.get(field) for kind, row in (get(cp, section, "processes") or {}).items() if kind.startswith(prefix)]
    values = [v for v in values if v is not None]
    return round(sum(values), 1) if values else None


def slope(cp, prev, kind):
    if not prev:
        return None
    a, b = proc(prev, "idle", kind, "footprint_mb"), proc(cp, "idle", kind, "footprint_mb")
    dn = (cp.get("panes") or 0) - (prev.get("panes") or 0)
    if a is None or b is None or dn <= 0:
        return None
    return round((b - a) / dn, 2)


def fmt(value):
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.2f}" if abs(value) < 100 else f"{value:.0f}"
    return str(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("results", nargs="+")
    parser.add_argument("--title", default="cmux-next pane scale")
    parser.add_argument("--note", action="append", default=[])
    args = parser.parse_args()
    runs = [json.load(open(path)) for path in args.results]
    targets = sorted({cp["target"] for run in runs for cp in run.get("checkpoints", [])})
    out = [f"<!doctype html><meta charset=utf-8><title>{html.escape(args.title)}</title>",
           "<style>:root{color-scheme:light dark}body{font:13px -apple-system,system-ui,sans-serif;margin:24px}"
           "table{border-collapse:collapse;margin:12px 0}td,th{border:1px solid #8884;padding:3px 8px;text-align:right}"
           "td:first-child,td:nth-child(2),th:first-child{text-align:left}th{background:#8882}"
           "tr.g td{background:#8881;font-weight:600;text-align:left}.skip{color:#b60}</style>",
           f"<h1>{html.escape(args.title)}</h1>"]
    for note in args.note:
        out.append(f"<p>{html.escape(note)}</p>")
    out.append("<h2>Runs</h2><ul>")
    for run in runs:
        out.append(f"<li><b>{html.escape(run.get('label', '?'))}</b>: sha {html.escape(run.get('sha', '?'))}, "
                   f"shape {html.escape(str(run.get('shape')))} rows {run.get('rows')} tabs {run.get('tabs')}, "
                   f"host {html.escape(str(run.get('host')))}, kern.tty.ptmx_max {run.get('ptmx_max')}</li>")
        for cp in run.get("checkpoints", []):
            if cp.get("skipped"):
                out.append(f"<li class=skip>{html.escape(run.get('label', '?'))} N={cp['target']}: "
                           f"{html.escape(cp['skipped'])}</li>")
    out.append("</ul>")
    by_run = []
    for run in runs:
        cps = {cp["target"]: cp for cp in run.get("checkpoints", []) if not cp.get("skipped")}
        ordered = sorted(cps)
        prev = {t: (cps[ordered[i - 1]] if i else None) for i, t in enumerate(ordered)}
        by_run.append((run, cps, prev))
    out.append("<table><tr><th>group</th><th>metric</th>")
    for target in targets:
        for run, _, _ in by_run:
            out.append(f"<th>N={target}<br>{html.escape(run.get('label', '?'))}</th>")
    out.append("</tr>")
    group = None
    for g, label, fn, unit in metrics():
        if g != group:
            group = g
            out.append(f"<tr class=g><td colspan={2 + len(targets) * len(by_run)}>{html.escape(g)}</td></tr>")
        cells = []
        for target in targets:
            for _, cps, prev in by_run:
                cp = cps.get(target)
                try:
                    value = fn(cp, prev.get(target)) if cp else None
                except (TypeError, KeyError):
                    value = None
                cells.append(f"<td>{html.escape(fmt(value))}</td>")
        unit_text = f" ({unit})" if unit else ""
        out.append(f"<tr><td></td><td>{html.escape(label + unit_text)}</td>{''.join(cells)}</tr>")
    out.append("</table>")
    with open(args.out, "w") as handle:
        handle.write("\n".join(out))
    print(args.out)


if __name__ == "__main__":
    main()
