#!/usr/bin/env python3
"""Summarize relaunch-restore.sh base=SHA head=SHA: the interleaved pairs' L5-PAIR rows.

Each row is `L5-PAIR SIDE ROUND LOAD_1M {L5-ROUND json}`. Prints one L5-PAIRS {json}: per side the medians of
quit_to_usable_ms, launch_to_usable_ms and relaunch_ms, the highest 1-minute load, and per metric how many pairs
head was faster. Exits 1 when a pair has no row or a relaunch did not restore (quit_to_usable_ms null); a round
over the check's budget is still a measured round.
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys

METRICS = ("quit_to_usable_ms", "launch_to_usable_ms", "relaunch_ms")
ROW = re.compile(r"^L5-PAIR (base|head) (\d+) (\S+) (\{.*\})\s*$")


def parse(lines: list[str]) -> dict[str, dict[int, dict]]:
    rows: dict[str, dict[int, dict]] = {"base": {}, "head": {}}
    for line in lines:
        m = ROW.match(line)
        if not m:
            continue
        row = json.loads(m.group(4))
        try:
            row["load_1m"] = float(m.group(3))
        except ValueError:
            row["load_1m"] = None
        rows[m.group(1)][int(m.group(2))] = row
    return rows


def summarize(rows: dict[str, dict[int, dict]], rounds: int) -> tuple[dict, list[str]]:
    problems: list[str] = []
    for side in ("base", "head"):
        for i in range(1, rounds + 1):
            row = rows[side].get(i)
            if row is None:
                problems.append(f"{side} round {i}: no row")
            elif not isinstance(row.get("quit_to_usable_ms"), int):
                problems.append(f"{side} round {i}: did not restore")
    out: dict = {"pairs": 0, "base": {}, "head": {}, "head_faster": {}}
    pairs = [i for i in range(1, rounds + 1) if i in rows["base"] and i in rows["head"]]
    out["pairs"] = len(pairs)
    for side in ("base", "head"):
        loads = [r["load_1m"] for r in rows[side].values() if isinstance(r.get("load_1m"), float)]
        out[side]["max_load_1m"] = max(loads) if loads else None
        for k in METRICS:
            vals = [rows[side][i][k] for i in pairs if isinstance(rows[side][i].get(k), int)]
            out[side][k] = {"median": statistics.median(vals) if vals else None, "values": vals}
    for k in METRICS:
        both = [(rows["base"][i].get(k), rows["head"][i].get(k)) for i in pairs]
        both = [(b, h) for b, h in both if isinstance(b, int) and isinstance(h, int)]
        out["head_faster"][k] = f"{sum(1 for b, h in both if h < b)}/{len(both)}"
    return out, problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="relaunch-restore.sh's pairs.log")
    parser.add_argument("--rounds", type=int, required=True, help="the pair count the step asked for")
    args = parser.parse_args(argv)
    with open(args.log, encoding="utf-8", errors="replace") as fh:
        rows = parse(fh.readlines())
    out, problems = summarize(rows, args.rounds)
    out["problems"] = problems
    print("L5-PAIRS " + json.dumps(out))
    for k in METRICS:
        b, h = out["base"][k]["median"], out["head"][k]["median"]
        diff = f"{h - b:+.0f}" if b is not None and h is not None else "-"
        print(f"L5-PAIRS {k}: base {b} head {h} diff {diff} head faster {out['head_faster'][k]}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
