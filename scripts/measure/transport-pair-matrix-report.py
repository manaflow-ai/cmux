#!/usr/bin/env python3
"""The transport pair matrix's table, from the benches' PAIRCELL lines.

Leo (relayed, 2026-11-24): "we need to absolutely slam the sh*t out of our transport protocols and make them
bulletproof. ios to mac to ios to linux to mac to linux to mac to mac to anywhere and everywhere."

Rows: pair x path (ios-mac, ios-linux, mac-mac, mac-linux; direct, relay). Columns: condition x load (loss,
latency, handoff, sleep, failover, long; idle, duress). A cell is four metrics: time to first content
(ttfc_ms), resume after the change (resume_ms), wire bytes from the change to caught up (delta_bytes; long: per
minute) and failures per n (fail). Each value is the p50 over the runs; fail is k/n.

Input lines (any file, any order; other lines are ignored, so whole CI logs can be passed):
  PAIRCELL {"pair":..,"path":..,"condition":..,"load":..,"metric":..,"value":..,"run":..,"host_os":..,"rig":..}
  PAIRCELL-NA {"pair":..,"path":..,"condition":"*"|NAME,"load":"*"|NAME,"metric":"*"|NAME,"reason":".."}

Usage:
  transport-pair-matrix-report.py LINES... [--markdown OUT.md] [--json OUT.json] [--command "how it was run"]
  transport-pair-matrix-report.py --selftest
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import defaultdict

PAIRS = ["ios-mac", "ios-linux", "mac-mac", "mac-linux"]
PATHS = ["direct", "relay"]
CONDITIONS = ["loss", "latency", "handoff", "sleep", "failover", "long"]
LOADS = ["idle", "duress"]
METRICS = [
    ("ttfc_ms", "Time to first content, p50 ms"),
    ("resume_ms", "Resume after the change (network back, address changed, wake, relay killed), p50 ms"),
    ("delta_bytes", "Wire bytes from the change to caught up, p50 (long: bytes per minute)"),
    ("fail", "Failures per n (no content within the bound, or an event lost or doubled)"),
]
LINE = re.compile(r"(PAIRCELL(?:-NA)?) (\{.*\})\s*$")
LONG_HOLDS = set()  # "long-30m" labels folded into the long column (a hold shorter than 60 min)


def parse(paths):
    cells = defaultdict(list)  # (pair, path, cond, load, metric) -> [(value, host_os, error)]
    na = {}  # (pair, path, cond, load, metric) with "*" wildcards -> reason
    hosts = defaultdict(set)  # (pair, path) -> host_os seen
    rigs = defaultdict(set)
    for path in paths:
        with open(path, errors="replace") as f:
            for raw in f:
                m = LINE.search(raw)
                if not m:
                    continue
                try:
                    d = json.loads(m.group(2))
                except json.JSONDecodeError:
                    continue
                key = tuple(str(d.get(k, "*")) for k in ("pair", "path", "condition", "load", "metric"))
                if re.fullmatch(r"long-\d+m", key[2]):
                    LONG_HOLDS.add(f"{key[0]} {key[1]} {key[3]}: {key[2]}")
                    key = key[:2] + ("long",) + key[3:]
                if m.group(1) == "PAIRCELL-NA":
                    na[key] = str(d.get("reason", "no reason given"))
                    continue
                cells[key].append((d.get("value"), d.get("host_os", "?"), d.get("error")))
                hosts[key[:2]].add(str(d.get("host_os", "?")))
                if d.get("rig"):
                    rigs[key[:2]].add(str(d["rig"]))
    return cells, na, hosts, rigs


def na_reason(na, key):
    pair, path, cond, load, metric = key
    for k in [
        key,
        (pair, path, cond, load, "*"),
        (pair, path, cond, "*", metric),
        (pair, path, cond, "*", "*"),
        (pair, path, "*", load, "*"),
        (pair, path, "*", "*", metric),
        (pair, path, "*", "*", "*"),
    ]:
        if k in na:
            return na[k]
    return None


def summarize(cells, na):
    out = {}
    for pair in PAIRS:
        for path in PATHS:
            for cond in CONDITIONS:
                for load in LOADS:
                    for metric, _ in METRICS:
                        key = (pair, path, cond, load, metric)
                        runs = cells.get(key, [])
                        if metric == "fail":
                            vals = [v for v, _, _ in runs if v is not None]
                            cell = {"k": int(sum(1 for v in vals if v)), "n": len(vals)} if vals else None
                        else:
                            vals = [float(v) for v, _, _ in runs if v is not None]
                            errs = [e for v, _, e in runs if v is None and e]
                            cell = {"p50": statistics.median(vals), "n": len(vals)} if vals else None
                            if cell is None and errs:
                                cell = {"error": errs[0], "n": 0}
                        reason = na_reason(na, key)
                        if cell is None and reason:
                            cell = {"na": reason}
                        out[key] = cell
    return out


def fmt(metric, cell):
    if cell is None:
        return "·"
    if "na" in cell:
        return "n/a"
    if "error" in cell:
        return "err"
    if metric == "fail":
        return f"{cell['k']}/{cell['n']}"
    v = cell["p50"]
    if metric == "delta_bytes":
        return f"{v / 1024:,.1f} KiB" if v >= 1024 else f"{v:,.0f} B"
    return f"{v:,.0f}" if v >= 100 else f"{v:,.1f}"


def badness(key, summary):
    """Rank a cell for "worst": failures first, then resume, then first content."""
    pair, path, cond, load = key
    get = lambda m: summary.get((pair, path, cond, load, m))
    fail = get("fail")
    resume = get("resume_ms")
    ttfc = get("ttfc_ms")
    fail_rate = fail["k"] / fail["n"] if fail and "k" in fail and fail["n"] else 0.0
    r = resume["p50"] if resume and "p50" in resume else 0.0
    t = ttfc["p50"] if ttfc and "p50" in ttfc else 0.0
    if not (fail_rate or r or t):
        return None
    return (fail_rate, r, t)


def worst(summary, count=3):
    ranked = []
    for pair in PAIRS:
        for path in PATHS:
            for cond in CONDITIONS:
                for load in LOADS:
                    b = badness((pair, path, cond, load), summary)
                    if b is not None:
                        ranked.append((b, (pair, path, cond, load)))
    ranked.sort(reverse=True)
    return ranked[:count]


def filled(summary):
    total = len(summary)
    done = sum(1 for c in summary.values() if c is not None and "error" not in c)
    return done, total


def markdown(summary, na, hosts, rigs, command):
    lines = []
    lines.append("# Transport pair matrix")
    lines.append("")
    lines.append("Leo (relayed, 2026-11-24): \"we need to absolutely slam the sh\\*t out of our transport protocols and make them")
    lines.append("bulletproof. ios to mac to ios to linux to mac to linux to mac to mac to anywhere and everywhere.\"")
    lines.append("")
    lines.append("Regenerate (one command, from a cmux checkout):")
    lines.append("")
    lines.append("```sh")
    lines.append(command)
    lines.append("```")
    lines.append("")
    done, total = filled(summary)
    lines.append(f"Filled: {done} of {total} metric cells (a number or a named reason). `·` = not measured yet, `n/a` = cannot be")
    lines.append("measured (reason below), `err` = the run produced no value (error below).")
    lines.append("")
    lines.append("Conditions: loss = `lossy-3` (70 ms, 3 % loss, 300 ms jitter); latency = high RTT, no loss; handoff = cell/Wi-Fi")
    lines.append("address change (`5g-lte-handoff`); sleep = client silent 60 s then wakes; failover = the path's relay (or direct")
    lines.append("path) dies mid-session; long = one session held 60 min with a steady chat stream. idle = small host, nothing")
    lines.append("streaming; duress = loaded host (50 sessions, a 10,000-message chat, a chat streaming while measured).")
    lines.append("Link profiles: `cmux-tui/crates/cmux-fault/link-profiles.json`. Every number: shaped link in-process, CI runner,")
    lines.append("no simulator; the host OS per row is in the last section.")
    if LONG_HOLDS:
        lines.append(f"Long cells held shorter than 60 min (label = hold): {'; '.join(sorted(LONG_HOLDS))}.")
    lines.append("")
    head = "| pair | path | " + " | ".join(f"{c} {l}" for c in CONDITIONS for l in LOADS) + " |"
    sep = "|---|---|" + "---|" * (len(CONDITIONS) * len(LOADS))
    for metric, title in METRICS:
        lines.append(f"## {title}")
        lines.append("")
        lines.append(head)
        lines.append(sep)
        for pair in PAIRS:
            for path in PATHS:
                row = [fmt(metric, summary.get((pair, path, c, l, metric))) for c in CONDITIONS for l in LOADS]
                lines.append(f"| {pair} | {path} | " + " | ".join(row) + " |")
        lines.append("")
    lines.append("## Three worst cells")
    lines.append("")
    w = worst(summary)
    if not w:
        lines.append("None measured yet.")
    for (fail_rate, r, t), (pair, path, cond, load) in w:
        lines.append(f"- {pair} {path}, {cond} {load}: fail {fail_rate:.0%}, resume p50 {r:,.0f} ms, first content p50 {t:,.0f} ms")
    lines.append("")
    lines.append("## Cells that cannot be measured, and errors")
    lines.append("")
    reasons = defaultdict(list)
    for key, cell in summary.items():
        if cell and "na" in cell:
            reasons[cell["na"]].append(key)
        elif cell and "error" in cell:
            reasons["error: " + cell["error"]].append(key)
    if not reasons:
        lines.append("None.")
    for reason, keys in sorted(reasons.items()):
        rows = sorted({f"{k[0]} {k[1]}" for k in keys})
        conds = sorted({k[2] for k in keys})
        lines.append(f"- {', '.join(rows)} ({', '.join(conds)}): {reason}")
    lines.append("")
    lines.append("## Rows: host OS and rig")
    lines.append("")
    for pair in PAIRS:
        for path in PATHS:
            h = ", ".join(sorted(hosts.get((pair, path), []))) or "not run"
            r = ", ".join(sorted(rigs.get((pair, path), []))) or "-"
            lines.append(f"- {pair} {path}: host_os {h}; {r}")
    lines.append("")
    return "\n".join(lines)


def selftest():
    import os
    import tempfile

    text = "\n".join(
        [
            'noise PAIRCELL {"pair":"ios-mac","path":"direct","condition":"loss","load":"idle","metric":"ttfc_ms","value":100,"run":0,"host_os":"linux","rig":"x::y"}',
            'PAIRCELL {"pair":"ios-mac","path":"direct","condition":"loss","load":"idle","metric":"ttfc_ms","value":300,"run":1,"host_os":"linux"}',
            'PAIRCELL {"pair":"ios-mac","path":"direct","condition":"loss","load":"idle","metric":"fail","value":1,"run":0}',
            'PAIRCELL {"pair":"ios-mac","path":"direct","condition":"loss","load":"idle","metric":"fail","value":0,"run":1}',
            'PAIRCELL {"pair":"ios-mac","path":"direct","condition":"loss","load":"idle","metric":"resume_ms","value":5000,"run":0}',
            'PAIRCELL-NA {"pair":"ios-linux","path":"direct","condition":"*","load":"*","metric":"*","reason":"no route (x.rs:1)"}',
            'PAIRCELL {"pair":"mac-linux","path":"relay","condition":"long-30m","load":"idle","metric":"delta_bytes","value":2048,"run":0}',
        ]
    )
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt") as f:
        f.write(text)
    try:
        cells, na, hosts, rigs = parse([f.name])
    finally:
        os.unlink(f.name)
    s = summarize(cells, na)
    assert s[("ios-mac", "direct", "loss", "idle", "ttfc_ms")]["p50"] == 200, s
    assert s[("ios-mac", "direct", "loss", "idle", "fail")] == {"k": 1, "n": 2}
    assert s[("ios-linux", "direct", "sleep", "duress", "resume_ms")] == {"na": "no route (x.rs:1)"}
    assert s[("mac-mac", "relay", "long", "idle", "ttfc_ms")] is None
    w = worst(s)
    assert w[0][1] == ("ios-mac", "direct", "loss", "idle"), w
    md = markdown(s, na, hosts, rigs, "cmd")
    assert "| ios-mac | direct | 200 |" in md, md
    assert "1/2" in md and "n/a" in md
    assert s[("mac-linux", "relay", "long", "idle", "delta_bytes")]["p50"] == 2048, s
    assert "mac-linux relay idle: long-30m" in md, md
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lines", nargs="*")
    ap.add_argument("--markdown")
    ap.add_argument("--json")
    ap.add_argument("--command", default="scripts/measure/transport-pair-matrix.sh")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        return 0
    if not a.lines:
        ap.error("give PAIRCELL line files (or --selftest)")
    cells, na, hosts, rigs = parse(a.lines)
    summary = summarize(cells, na)
    md = markdown(summary, na, hosts, rigs, a.command)
    if a.markdown:
        with open(a.markdown, "w") as f:
            f.write(md)
    else:
        sys.stdout.write(md)
    if a.json:
        rows = [
            dict(zip(("pair", "path", "condition", "load", "metric"), k), cell=v) for k, v in summary.items()
        ]
        with open(a.json, "w") as f:
            json.dump({"cells": rows, "worst": [list(k) for _, k in worst(summary)]}, f, indent=1)
    done, total = filled(summary)
    print(f"PAIRMATRIX-FILLED {done}/{total}", file=sys.stderr)
    for (fail_rate, r, t), k in worst(summary):
        print(f"PAIRMATRIX-WORST {' '.join(k)} fail={fail_rate:.2f} resume_ms={r:.0f} ttfc_ms={t:.0f}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
