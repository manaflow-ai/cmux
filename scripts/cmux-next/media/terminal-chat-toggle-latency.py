#!/usr/bin/env python3
"""Toggle Terminal and Chat latency from one capture of the terminal-chat-toggle-* tours (Leo, 2026-11-14: "the whole
terminal switching to GUI and back type thing. How's that going?").

    cmux-ci capture SHA --state tour:terminal-chat-toggle-idle --mac --release      (also -midturn, -handoff)
    terminal-chat-toggle-latency.py ~/.cache/pr-capture/SHA8/tour:terminal-chat-toggle-idle

Reads the capture's result.json and rpc-NN.json files. Each run is one Opt-Cmd-` through the real key path
(`debug.new_tab frame_strip`): its time is the first composited frame after the key whose content area differs from
the frame before the key and is not blank (`content_blank`), so a blank new terminal does not count as shown. Prints
p50/p95 per case, the `debug.tab_switch` rows (apply and commit) by kind, and each chat_state step's rows and newest
lines, which show whether a message was lost or shown twice across the swaps.
"""
import json
import re
import sys
from pathlib import Path

d = Path(sys.argv[1])
tol = 0.002  # the frame strip's own default tolerance
result = json.loads((d / "result.json").read_text())
steps = result["steps"]
cases = {}
bad = []
switch_rows = None
for i, s in enumerate(steps):
    title = s.get("title", "")
    if s.get("status") != "ok":
        bad.append((i, title, s.get("status"), (s.get("detail") or "")[:300]))
    f = s.get("resultFile")
    if not f or not (d / f).exists():
        continue
    data = json.loads((d / f).read_text())
    if title.startswith("debug.tab_switch stop"):
        switch_rows = data.get("switches", [])
        continue
    m = re.match(r"Run (\d+) \((\w)\) ([^:]+):", title)
    if not m:
        if "chat_state" in json.dumps(s.get("rpc", {})) or title.startswith(("Before", "After", "Mid-turn", "The chat",
                                                                                 "Right after", "The hand-off")):
            tr = data.get("transcript") or []
            print(f"[{i}] {title}: rows={data.get('rows')} working={data.get('isWorking')} "
                  f"last={((data.get('lastAssistant') or {}).get('text') or '')[:60]!r} "
                  f"scrollTop={data.get('scrollTop')} conn={data.get('connection')} "
                  f"tail={[t['text'][:28] for t in tr[-4:]]}")
        continue
    frames = data.get("frames") or []
    first = next((r["ms"] for r in frames if r["ms"] > 0 and r["content_vs_before"] > tol and not r["content_blank"]), None)
    blanks = sum(1 for r in frames if r["ms"] > 0 and r["content_blank"])
    key = f"({m.group(2)}) {m.group(3)}"
    cases.setdefault(key, []).append({"run": int(m.group(1)), "first_content_ms": first, "first_change_ms": data.get("first_change_ms"),
                                      "settled_ms": data.get("settled_ms"), "blank": blanks, "error": data.get("error"),
                                      "mean_interval_ms": round(data.get("mean_interval_ms") or 0, 1)})


def pct(values, p):
    v = sorted(values)
    if not v:
        return None
    k = max(0, min(len(v) - 1, round(p / 100 * len(v) + 0.5) - 1))  # nearest rank
    return v[k]


print()
print("| case | n | first content p50 | p95 | max | misses (no change) | blank frames |")
print("|---|---|---|---|---|---|---|")
for key, rows in cases.items():
    got = [r["first_content_ms"] for r in rows if r["first_content_ms"] is not None]
    miss = sum(1 for r in rows if r["first_content_ms"] is None)
    print(f"| {key} | {len(got)} | {pct(got, 50)} | {pct(got, 95)} | {max(got) if got else None} | {miss} | "
          f"{sum(r['blank'] for r in rows)} |")
if switch_rows is not None:
    print()
    by = {}
    for r in switch_rows:
        by.setdefault(r.get("kind", "?"), []).append(r)
    for kind, rows in by.items():
        for col in ("apply_ms", "commit_ms", "commit_end_ms", "input_ms"):
            vals = [r[col] for r in rows if col in r]
            if vals:
                print(f"tab_switch kind={kind} n={len(vals)} {col}: p50 {pct(vals, 50):.1f} p95 {pct(vals, 95):.1f}")
print()
for key, rows in cases.items():
    print(key, [(r["run"], r["first_content_ms"], r["first_change_ms"], r["settled_ms"]) for r in rows])
if bad:
    print("\nnot ok steps:")
    for b in bad:
        print(" ", b)
