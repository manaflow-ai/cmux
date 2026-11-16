#!/usr/bin/env python3
"""Toggle Terminal and Chat latency from captures of the terminal-chat-toggle-* tours (Leo, 2026-11-14: "the whole
terminal switching to GUI and back type thing. How's that going?").

    cmux-ci capture SHA --state tour:terminal-chat-toggle-idle --mac --release      (twice; also -midturn)
    terminal-chat-toggle-latency.py CAPTURE_DIR [CAPTURE_DIR ...]

A tour holds at most 30 steps, so one case's 20 runs come from two captures: give every capture folder
(~/.cache/pr-capture/SHA8/<state>) and the runs are pooled. Each run is one Toggle Terminal and Chat through the real action path
(`debug.new_tab frame_strip`): its time is the first composited frame after the key whose content area differs from
the frame before the key and is not blank (`content_blank`), so a blank new terminal does not count as shown. Prints
p50/p95 per case, the `debug.tab_switch` rows (apply and commit) by kind, each capture's chat open trace
(`debug.chat_open_trace`), and each chat_state step's rows and newest lines, which show whether a message was lost or
shown twice across the swaps.
"""
import json
import re
import sys
from pathlib import Path

TOL = 0.002  # the frame strip's own default tolerance
cases, switch_rows, bad = {}, [], []


def read(d):
    steps = json.loads((d / "result.json").read_text())["steps"]
    print(f"== {d}")
    for i, s in enumerate(steps):
        title = s.get("title", "")
        if s.get("status") != "ok":
            bad.append((d.name, i, title, s.get("status"), (s.get("detail") or "")[:300]))
        f = s.get("resultFile")
        if not f or not (d / f).exists():
            continue
        data = json.loads((d / f).read_text())
        if title.startswith("debug.tab_switch stop"):
            switch_rows.extend(data.get("switches", []))
            continue
        if title.startswith("The chat open trace"):
            marks = data.get("marks_ms") or {}
            print(f"[{i}] open trace: first_content_ms={data.get('first_content_ms')} longest_empty_ms="
                  f"{data.get('longest_empty_ms')} timed_out={data.get('timed_out')} engine={data.get('engine')} "
                  f"marks={ {k: v for k, v in marks.items() if v is not None} }")
            continue
        m = re.match(r"Run (\d+) \((\w)\) ([^:]+):", title)
        if not m:
            if "chat_state" in json.dumps(s.get("rpc", {})):
                tr = data.get("transcript") or []
                print(f"[{i}] {title}: rows={data.get('rows')} working={data.get('isWorking')} "
                      f"last={((data.get('lastAssistant') or {}).get('text') or '')[-60:]!r} "
                      f"tail={[t['text'][:28] for t in tr[-4:]]}")
            continue
        frames = data.get("frames") or []
        first = next((r["ms"] for r in frames if r["ms"] > 0 and r["content_vs_before"] > TOL and not r["content_blank"]),
                     None)
        cases.setdefault(f"({m.group(2)}) {m.group(3)}", []).append({
            "run": f"{d.name[:14]}#{m.group(1)}", "first_content_ms": first, "settled_ms": data.get("settled_ms"),
            "blank": sum(1 for r in frames if r["ms"] > 0 and r["content_blank"])})


def pct(values, p):
    v = sorted(values)
    return v[max(0, min(len(v) - 1, round(p / 100 * len(v) + 0.5) - 1))] if v else None  # nearest rank


for arg in sys.argv[1:]:
    read(Path(arg).expanduser())
# A chat that never showed the seeded transcript (its harness refused the session, the seed failed) makes every swap
# a swap to an empty or error page: its numbers measure nothing about the long chat, so they are not printed.
empty = sorted({b[0] for b in bad if b[2].startswith("Before: the chat painted its newest turn")})
if empty:
    print(f"\nrefused: the chat never showed the seeded transcript in {', '.join(empty)}; its swaps measure an empty "
          "or error page (look at light.png). Not reporting numbers.", file=sys.stderr)
    for b in bad:
        print(" ", b, file=sys.stderr)
    sys.exit(2)
print()
# Settled: the last frame that changed. A page rebuilt behind its last picture shows content at once but settles late.
print("| case | n | first content p50 | p95 | max | misses (no change) | blank frames | settled p50 | settled p95 |")
print("|---|---|---|---|---|---|---|---|---|")
for key, rows in cases.items():
    got = [r["first_content_ms"] for r in rows if r["first_content_ms"] is not None]
    settled = [r["settled_ms"] for r in rows if r["settled_ms"] is not None]
    print(f"| {key} | {len(got)} | {pct(got, 50)} | {pct(got, 95)} | {max(got) if got else None} | "
          f"{len(rows) - len(got)} | {sum(r['blank'] for r in rows)} | {pct(settled, 50)} | {pct(settled, 95)} |")
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
    print(key, [(r["run"], r["first_content_ms"], r["settled_ms"]) for r in rows])
if bad:
    print("\nnot ok steps:")
    for b in bad:
        print(" ", b)
